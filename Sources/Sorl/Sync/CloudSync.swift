import CloudKit
import CryptoKit
import Foundation
import KeyboardShortcuts
import Observation
import OSLog
import SorlCore

/// Syncs Saved and the keyboard shortcuts through the user's private CloudKit database with `CKSyncEngine`.
///
/// Without the CloudKit entitlement (ad-hoc builds) nothing here creates a CloudKit object other than `CKRecord`,
/// and with sync off no `CKContainer` is ever created. All local sync state lives in `UserDefaults.standard` and
/// one file in Application Support, never in AppSettings' swappable demo defaults.
@MainActor
@Observable
final class CloudSync {
    enum Problem: Equatable, Sendable {
        case offline, quotaExceeded, notAuthenticated, other
    }

    enum Status: Equatable, Sendable {
        case off, unavailable, signedOut, accountChanged, cloudDataDeleted, syncing
        case upToDate(Date)
        case error(Problem)
    }

    private(set) var status: Status

    /// The single source of truth for the Settings switch.
    var isEnabled: Bool { settings.syncEnabled }

    /// Set while a fetched shortcut is being written, so the change notification isn't treated as a local edit.
    @ObservationIgnored private(set) var applyingShortcut = false

    private enum Keys {
        static let state = "cloudSyncState"
        static let user = "cloudSyncUser"
        static let times = "shortcutsModifiedAt"
        static let dirty = "cloudSyncDirty"
    }

    /// The account's sync key, which names Saved records. Until it is `.ready`, local changes are only journaled and
    /// the engine is given nothing but the zone and the `sync-key` record.
    private enum KeyState {
        /// Not known yet; the first-sync ordering (`establishKey`) hasn't run or must run again.
        case unknown
        /// Fetching iCloud to see whether another Mac already made a key.
        case fetching
        /// None was found: this key is being uploaded, and becomes ready once iCloud confirms it.
        case creating(SymmetricKey)
        case ready(SymmetricKey)
    }

    /// A synced item, independent of the key. The journal stores `saved:<url>` and `shortcut-<name>`.
    private enum SyncItem: Hashable {
        case saved(URL)
        case shortcut(String)

        static let savedJournalPrefix = "saved:"

        init?(journalEntry entry: String) {
            if entry.hasPrefix(Self.savedJournalPrefix) {
                guard let url = URL(string: String(entry.dropFirst(Self.savedJournalPrefix.count))) else { return nil }
                self = .saved(url)
            } else if entry.hasPrefix(ShortcutSync.recordPrefix) {
                self = .shortcut(String(entry.dropFirst(ShortcutSync.recordPrefix.count)))
            } else {
                return nil
            }
        }

        var journalEntry: String {
            switch self {
            case .saved(let url): Self.savedJournalPrefix + url.absoluteString
            case .shortcut(let name): ShortcutSync.recordName(for: name)
            }
        }

        func recordName(key: SymmetricKey) -> String {
            switch self {
            case .saved(let url): SyncRecords.savedRecordName(for: url, key: key)
            case .shortcut(let name): ShortcutSync.recordName(for: name)
            }
        }
    }

    private enum ItemChange {
        case save(SyncItem)
        case delete(SyncItem)

        var item: SyncItem {
            switch self {
            case .save(let item), .delete(let item): item
            }
        }
    }

    private static let containerID = "iCloud.com.karbassi.sorl"
    private static let savedPrefix = "saved-"
    private static let syncKeyID = CKRecord.ID(recordName: SyncRecords.syncKeyRecordName, zoneID: SyncZone.id)
    private static let fetchThrottle: TimeInterval = 60
    private static let fieldsURL = URL.applicationSupportDirectory
        .appending(path: "com.karbassi.sorl", directoryHint: .isDirectory)
        .appending(path: "CloudSyncRecords.plist", directoryHint: .notDirectory)

    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let log = Logger(subsystem: "com.karbassi.sorl", category: "sync")
    @ObservationIgnored private var container: CKContainer?
    @ObservationIgnored private var engine: CKSyncEngine?
    /// Signed out: the engine stays alive only to report account changes; every other event is ignored.
    @ObservationIgnored private var isListening = false
    @ObservationIgnored private var isStarting = false
    /// The last `start()` couldn't determine the account; the next `fetchNow`/`syncNow` retries it.
    @ObservationIgnored private var needsStart = false
    @ObservationIgnored private var lastFetchRequest: Date?
    /// The worst problem seen since the last will-fetch/will-send, reported when the cycle ends.
    @ObservationIgnored private var cycleProblem: Problem?
    /// `cloudSyncDirty`: items (`saved:<url>`, `shortcut-<name>`) with a change not yet confirmed by the server.
    @ObservationIgnored private var journal: Set<String>
    /// Record name → journal entry under the current key; built on first use, dropped when the key changes.
    @ObservationIgnored private var journalIndexCache: [String: String]?
    @ObservationIgnored private var times: ShortcutTimes
    /// Last-known system fields by record name; loaded from disk on first use.
    @ObservationIgnored private var loadedFields: [String: Data]?
    @ObservationIgnored private var fieldsDirty = false
    @ObservationIgnored private var saveFieldsTask: Task<Void, Never>?
    @ObservationIgnored private var mapCache: (store: SavedLinksStore, map: [String: URL])?
    @ObservationIgnored private var keyState = KeyState.unknown
    /// The iCloud user record name: the Keychain account the key is stored under.
    @ObservationIgnored private var keyUser: String?
    /// Saved deletions fetched before the key was known; mapped once it is adopted, dropped if a new key is made.
    @ObservationIgnored private var deferredDeletes: [String] = []

    init(settings: AppSettings) {
        self.settings = settings
        status = ICloudEntitlement.hasCloudKit ? .off : .unavailable
        let stored = UserDefaults.standard.stringArray(forKey: Keys.dirty) ?? []
        // Entries from before the sync key (`saved-<hash>`) can't be mapped back to a link; drop them.
        let valid = stored.filter { SyncItem(journalEntry: $0) != nil }
        journal = Set(valid)
        times = ShortcutTimes(decoding: UserDefaults.standard.data(forKey: Keys.times) ?? Data())
        if valid.count != stored.count { saveJournal() }
    }

    // MARK: Enable, launch and disable

    /// At launch when sync is on: engine from the saved state, account check, re-queue the journal, fetch.
    /// Also how a signed-out engine resumes after the same user signs back in.
    func start() async {
        guard settings.syncEnabled, !settings.isDemo else { return }
        guard ICloudEntitlement.hasCloudKit else { status = .unavailable; return }
        guard !isStarting else { return }
        isStarting = true
        needsStart = false
        let hadState = savedState() != nil
        let engine = await replaceEngine()
        guard await accountAvailable(for: engine), await resolveUser(for: engine) else { isStarting = false; return }
        isStarting = false
        keyState = .unknown
        // Turned on while signed out: the zone was never queued, and this is the first sync, so ask iCloud for
        // the key even if the Keychain has one from an earlier enable.
        guard hadState, let user = keyUser, let key = SyncKeyStore.read(user: user) else {
            engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: SyncZone.id))])
            await establishKey(engine)
            return
        }
        keyState = .ready(key)
        keyChanged()
        log.notice("sync key ready")
        requeueJournal()
        await fetch(engine)
    }

    /// The Settings switch. Turning on merges this Mac's Saved and shortcuts with iCloud; turning off keeps local
    /// and cloud data and forgets the sync state.
    func setEnabled(_ enabled: Bool) async {
        guard !settings.isDemo else { return }
        guard enabled else {
            guard settings.syncEnabled else { return }
            await disable()
            status = ICloudEntitlement.hasCloudKit ? .off : .unavailable
            return
        }
        guard ICloudEntitlement.hasCloudKit else { status = .unavailable; return }
        guard !settings.syncEnabled, !isStarting else { return }
        settings.syncEnabled = true
        stampShortcutsForFirstEnable()
        // Everything goes in the journal now; it is queued once the key is known. If the account isn't available
        // yet, the same-user sign-in path picks it up from the journal.
        addToJournal(allLocalItems().map(\.journalEntry))
        isStarting = true
        let engine = await replaceEngine()
        guard await accountAvailable(for: engine), await resolveUser(for: engine) else { isStarting = false; return }
        isStarting = false
        keyState = .unknown
        engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: SyncZone.id))])
        await establishKey(engine)
    }

    /// Cancels the engine and drops it; late callbacks from it are ignored. Keeps `syncEnabled` and all saved state.
    func stop() async {
        isListening = false
        guard let old = engine else { flush(); return }
        engine = nil
        await old.cancelOperations()
        flush()
    }

    /// Writes the system-fields file now (quit).
    func flush() {
        saveFieldsTask?.cancel()
        saveFieldsTask = nil
        guard fieldsDirty, let fields = loadedFields else { return }
        fieldsDirty = false
        do {
            try FileManager.default.createDirectory(at: Self.fieldsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            try encoder.encode(fields).write(to: Self.fieldsURL, options: .atomic)
        } catch {
            log.error("writing system fields failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Fetch when the panel opens, at most once a minute.
    func fetchNow() {
        guard canRun else { return }
        if let last = lastFetchRequest, Date().timeIntervalSince(last) < Self.fetchThrottle { return }
        lastFetchRequest = Date()
        Task { await self.run(send: false) }
    }

    /// `sorl://sync`: send, then fetch.
    func syncNow() {
        guard canRun else { return }
        lastFetchRequest = Date()
        Task { await self.run(send: true) }
    }

    private var canRun: Bool {
        !settings.isDemo && settings.syncEnabled && ICloudEntitlement.hasCloudKit
    }

    private func run(send: Bool) async {
        guard let engine, !isListening, !needsStart else {
            await start()
            return
        }
        if case .unknown = keyState {
            // The first-sync ordering didn't finish (offline, say): fetch first again.
            await establishKey(engine)
            return
        }
        do {
            if send { try await engine.sendChanges() }
            try await engine.fetchChanges()
        } catch {
            report(error, from: engine)
        }
    }

    private func fetch(_ engine: CKSyncEngine) async {
        lastFetchRequest = Date()
        do {
            try await engine.fetchChanges()
        } catch {
            report(error, from: engine)
        }
    }

    private func report(_ error: Error, from engine: CKSyncEngine) {
        guard engine === self.engine, !isListening else { return }
        if error is CancellationError || (error as? CKError)?.code == .operationCancelled { return }
        log.error("sync failed: \(String(describing: error), privacy: .public)")
        status = .error(Self.problem(for: error))
    }

    private func disable() async {
        await stop()
        settings.syncEnabled = false
        let defaults = UserDefaults.standard
        [Keys.state, Keys.dirty, Keys.user].forEach(defaults.removeObject(forKey:))
        journal = []
        // The Keychain key stays: it is the account's, and is used again if the same account turns sync back on.
        keyState = .unknown
        keyUser = nil
        deferredDeletes = []
        journalIndexCache = nil
        mapCache = nil
        loadedFields = [:]
        fieldsDirty = false
        try? FileManager.default.removeItem(at: Self.fieldsURL)
        needsStart = false
        lastFetchRequest = nil
        cycleProblem = nil
    }

    // MARK: Container and engine

    /// The single place a `CKContainer` is created. Callers have checked `ICloudEntitlement.hasCloudKit`.
    private func cloudContainer() -> CKContainer {
        if let container { return container }
        log.notice("creating CKContainer")
        let created = CKContainer(identifier: Self.containerID)
        container = created
        return created
    }

    private func replaceEngine() async -> CKSyncEngine {
        if let old = engine {
            engine = nil
            await old.cancelOperations()
        }
        let configuration = CKSyncEngine.Configuration(
            database: cloudContainer().privateCloudDatabase,
            stateSerialization: savedState(),
            delegate: self
        )
        let created = CKSyncEngine(configuration)
        engine = created
        isListening = false
        return created
    }

    /// True when the account can sync. Otherwise sets the status and, when signed out, leaves the engine listening.
    private func accountAvailable(for engine: CKSyncEngine) async -> Bool {
        let accountStatus: CKAccountStatus
        do {
            accountStatus = try await cloudContainer().accountStatus()
        } catch {
            guard engine === self.engine else { return false }
            log.error("account status failed: \(String(describing: error), privacy: .public)")
            status = .error(.other)
            needsStart = true
            return false
        }
        guard engine === self.engine, settings.syncEnabled else { return false }
        switch accountStatus {
        case .available:
            return true
        case .noAccount, .restricted, .temporarilyUnavailable:
            status = .signedOut
            isListening = true
            return false
        case .couldNotDetermine:
            status = .error(.other)
            needsStart = true
            return false
        @unknown default:
            status = .error(.other)
            needsStart = true
            return false
        }
    }

    /// Looks up the signed-in iCloud user, the Keychain account the key is stored under. If the lookup fails the
    /// last known user is used. A different user than the one sync last ran with means the account was switched
    /// while Sorl wasn't running: that turns sync off, as an account change does.
    private func resolveUser(for engine: CKSyncEngine) async -> Bool {
        let previous = UserDefaults.standard.string(forKey: Keys.user)
        let user: String
        do {
            user = try await cloudContainer().userRecordID().recordName
        } catch {
            guard engine === self.engine else { return false }
            guard let previous else {
                log.error("user lookup failed: \(String(describing: error), privacy: .public)")
                status = .error(.other)
                needsStart = true
                return false
            }
            user = previous
        }
        guard engine === self.engine, settings.syncEnabled else { return false }
        if let previous, previous != user {
            log.notice("account changed; turning sync off")
            isListening = true
            await disable()
            status = .accountChanged
            return false
        }
        keyUser = user
        return true
    }

    // MARK: Sync key

    private var readyKey: SymmetricKey? {
        if case .ready(let key) = keyState { return key }
        return nil
    }

    /// The first-sync ordering. Fetches first; a `SyncKey` that arrives is adopted in `handleFetched`. If none does,
    /// the record is also looked up directly, since an engine with a saved change token won't fetch it again. Only
    /// when iCloud has none is a key made, and then only the zone and `sync-key` are sent until iCloud confirms it.
    /// A failure leaves the state `.unknown`, so the next `fetchNow` or `sorl://sync` runs this again.
    private func establishKey(_ engine: CKSyncEngine) async {
        guard engine === self.engine, !isListening, case .unknown = keyState else { return }
        keyState = .fetching
        lastFetchRequest = Date()
        do {
            try await engine.fetchChanges()
        } catch {
            keyFetchFailed(error, engine: engine)
            return
        }
        guard engine === self.engine, !isListening, case .fetching = keyState else { return }
        let record: CKRecord?
        do {
            record = try await cloudContainer().privateCloudDatabase.record(for: Self.syncKeyID)
        } catch let error as CKError where Self.isMissing(error) {
            record = nil
        } catch {
            keyFetchFailed(error, engine: engine)
            return
        }
        guard engine === self.engine, !isListening, case .fetching = keyState else { return }
        if let record {
            adoptKey(from: record, engine: engine)
            return
        }
        createKey(engine)
        do {
            try await engine.sendChanges()
        } catch {
            report(error, from: engine)
        }
    }

    private func keyFetchFailed(_ error: Error, engine: CKSyncEngine) {
        guard engine === self.engine, case .fetching = keyState else { return }
        keyState = .unknown
        report(error, from: engine)
    }

    /// iCloud has no key: make one and send only the zone and `sync-key`. Everything else stays in the journal
    /// until `sentRecordZoneChanges` confirms the key, so nothing is ever named with a key that loses a race.
    private func createKey(_ engine: CKSyncEngine) {
        keyState = .creating(SymmetricKey(size: .bits256))
        // Deletions fetched so far, and fields cached so far, were named with no key this Mac will use.
        deferredDeletes = []
        fields = fields.filter { !$0.key.hasPrefix(Self.savedPrefix) }
        engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: SyncZone.id))])
        queueSyncKeySave(engine)
    }

    private func queueSyncKeySave(_ engine: CKSyncEngine) {
        engine.state.remove(pendingRecordZoneChanges: [.saveRecord(Self.syncKeyID), .deleteRecord(Self.syncKeyID)])
        engine.state.add(pendingRecordZoneChanges: [.saveRecord(Self.syncKeyID)])
    }

    /// Adopts the key in a `SyncKey` record from iCloud (fetched, looked up, or the server copy in a conflict): the
    /// server's key always wins. Nothing happens when it is the key already in use.
    private func adoptKey(from record: CKRecord, engine: CKSyncEngine) {
        cacheSystemFields(record)
        guard let key = SyncRecords.syncKey(from: record) else {
            log.error("ignoring malformed sync key record")
            if case .fetching = keyState { keyState = .unknown }
            status = .error(.other)
            return
        }
        var wasReady = false
        if case .ready(let current) = keyState {
            if Self.sameKey(current, key) { return }
            wasReady = true
        }
        // A key of ours that was still being created lost the race: drop its pending save.
        engine.state.remove(pendingRecordZoneChanges: [.saveRecord(Self.syncKeyID)])
        becomeReady(key, engine: engine, dropSavedFields: wasReady)
        log.notice("sync key adopted from iCloud")
    }

    /// The key is known and agreed with iCloud. Stores it, then re-derives every pending record change from the
    /// journal under the new names, with every local item added to it: nothing in iCloud was named with this key
    /// by this Mac yet. Fetched deletions held back while the key was unknown are applied first, so a link still
    /// journaled here wins, as with any pending save.
    private func becomeReady(_ key: SymmetricKey, engine: CKSyncEngine, dropSavedFields: Bool) {
        keyState = .ready(key)
        if let keyUser { SyncKeyStore.write(key, user: keyUser) }
        keyChanged()
        if dropSavedFields { fields = fields.filter { !$0.key.hasPrefix(Self.savedPrefix) } }
        let stale = engine.state.pendingRecordZoneChanges.filter {
            Self.recordID(of: $0)?.recordName != SyncRecords.syncKeyRecordName
        }
        engine.state.remove(pendingRecordZoneChanges: stale)
        applyDeferredDeletes(key)
        addToJournal(allLocalItems().map(\.journalEntry))
        requeueJournal()
    }

    private func applyDeferredDeletes(_ key: SymmetricKey) {
        guard !deferredDeletes.isEmpty else { return }
        let names = deferredDeletes
        deferredDeletes = []
        let map = settings.saved.recordNameMap(key: key)
        let journal = journal
        settings.applyRemoteSaved { store in
            for name in names {
                let pendingSave = map[name].map { journal.contains(SyncItem.saved($0).journalEntry) } ?? false
                store.applyRemoteDelete(recordName: name, map: map, hasPendingSave: pendingSave)
            }
        }
    }

    /// Record names depend on the key: anything cached by name is rebuilt.
    private func keyChanged() {
        journalIndexCache = nil
        mapCache = nil
    }

    /// The zone, and the `SyncKey` in it, is gone but sync stays on: drop the key and redo the first-sync ordering.
    /// Every local item goes back in the journal, to be uploaded under whichever key wins. Local data is untouched.
    private func zoneLost(_ engine: CKSyncEngine) {
        log.notice("zone deleted; re-creating it")
        if let keyUser { SyncKeyStore.delete(user: keyUser) }
        deferredDeletes = []
        loadedFields = [:]
        scheduleFieldsSave()
        engine.state.remove(pendingRecordZoneChanges: engine.state.pendingRecordZoneChanges)
        engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: SyncZone.id))])
        addToJournal(allLocalItems().map(\.journalEntry))
        // A first-sync ordering already fetching carries on: its lookup will find the new zone's key, or none.
        if case .fetching = keyState { return }
        keyState = .unknown
        keyChanged()
        Task { await self.establishKey(engine) }
    }

    // MARK: Local changes

    /// Called by AppSettings with each local change to Saved.
    func savedDidChange(old: SavedLinksStore, new: SavedLinksStore) {
        guard settings.syncEnabled, !settings.isDemo, ICloudEntitlement.hasCloudKit else { return }
        let diff = SavedLinksStore.changes(from: old, to: new)
        queue(diff.upserts.map { .save(.saved($0.url)) } + diff.deletes.map { .delete(.saved($0)) })
    }

    /// Called for every local shortcut change. Stamps it even while sync is off, so a later first enable knows it
    /// was customized.
    func shortcutDidChange(_ name: KeyboardShortcuts.Name) {
        guard !applyingShortcut else { return }
        times[name.rawValue] = ShortcutSync.nextStamp(previous: times[name.rawValue], now: Date())
        saveTimes()
        guard settings.syncEnabled, ICloudEntitlement.hasCloudKit else { return }
        queue([.save(.shortcut(name.rawValue))])
    }

    /// The only way a pending change is added: journals the item synchronously, then, once the key is ready, drops
    /// any pending save or delete for the same record and adds this one. While signed out, before an engine
    /// exists, or while the key is unknown, only the journal is written; `becomeReady` queues it later.
    private func queue(_ changes: [ItemChange]) {
        guard !changes.isEmpty else { return }
        addToJournal(changes.map(\.item.journalEntry))
        guard let engine, !isListening, let key = readyKey else { return }
        var pending: [CKSyncEngine.PendingRecordZoneChange] = []
        var ids: [CKRecord.ID] = []
        for change in changes {
            let id = Self.recordID(change.item.recordName(key: key))
            ids.append(id)
            switch change {
            case .save: pending.append(.saveRecord(id))
            case .delete: pending.append(.deleteRecord(id))
            }
        }
        engine.state.remove(pendingRecordZoneChanges: ids.flatMap { [.saveRecord($0), .deleteRecord($0)] })
        engine.state.add(pendingRecordZoneChanges: pending)
    }

    /// Each journal entry as a save if the item exists locally, otherwise a delete. Shortcuts always exist.
    private func requeueJournal() {
        let local = Set(settings.saved.items.map(\.url.absoluteString))
        let changes: [ItemChange] = journal.sorted().compactMap { entry in
            guard let item = SyncItem(journalEntry: entry) else { return nil }
            if case .saved(let url) = item, !local.contains(url.absoluteString) { return .delete(item) }
            return .save(item)
        }
        queue(changes)
    }

    private func allLocalItems() -> [SyncItem] {
        settings.saved.items.map { .saved($0.url) } + Hotkeys.all.map { .shortcut($0.rawValue) }
    }

    /// First enable only: a shortcut showing its initial value must lose to a customization already in iCloud.
    private func stampShortcutsForFirstEnable() {
        let now = Date()
        for name in Hotkeys.all {
            let stored = ShortcutState(storedValue: UserDefaults.standard.object(forKey: ShortcutState.defaultsKey(name.rawValue)))
            times[name.rawValue] = ShortcutSync.firstEnableStamp(isInitial: isInitial(stored, for: name), existing: times[name.rawValue], now: now)
        }
        saveTimes()
    }

    /// Absent or unreadable counts as initial (nothing customized to protect); disabled never does.
    private func isInitial(_ state: ShortcutState?, for name: KeyboardShortcuts.Name) -> Bool {
        guard let state else { return true }
        switch state {
        case .disabled:
            return false
        case .set(let json):
            guard let shortcut = Self.decodeShortcut(json) else { return true }
            return shortcut == name.initialShortcut
        }
    }

    // MARK: Events

    private func handle(_ event: CKSyncEngine.Event, from syncEngine: CKSyncEngine) {
        guard syncEngine === engine else { return }
        if case .accountChange(let change) = event {
            handleAccountChange(change)
            return
        }
        guard !isListening else { return }
        switch event {
        case .stateUpdate(let update):
            saveState(update.stateSerialization)
        case .fetchedDatabaseChanges(let changes):
            handleDatabaseChanges(changes, engine: syncEngine)
        case .fetchedRecordZoneChanges(let changes):
            handleFetched(changes, engine: syncEngine)
        case .sentDatabaseChanges(let sent):
            for failure in sent.failedZoneSaves {
                log.error("saving zone failed: \(String(describing: failure.error), privacy: .public)")
                noteProblem(failure.error)
            }
        case .sentRecordZoneChanges(let sent):
            handleSent(sent, engine: syncEngine)
        case .willFetchChanges, .willSendChanges:
            status = .syncing
        case .didFetchRecordZoneChanges(let done):
            if let error = done.error {
                log.error("fetching zone failed: \(String(describing: error), privacy: .public)")
                noteProblem(error)
            }
        case .didFetchChanges, .didSendChanges:
            status = cycleProblem.map { .error($0) } ?? .upToDate(Date())
            cycleProblem = nil
        case .accountChange, .willFetchRecordZoneChanges:
            break
        @unknown default:
            break
        }
    }

    private func handleAccountChange(_ change: CKSyncEngine.Event.AccountChange) {
        switch change.changeType {
        case .signIn(let currentUser):
            let previous = UserDefaults.standard.string(forKey: Keys.user)
            if previous == nil || previous == currentUser.recordName {
                UserDefaults.standard.set(currentUser.recordName, forKey: Keys.user)
                log.notice("account signed in")
                // Same user back while listening: a fresh engine from the kept state, journal re-queued, fetch.
                if isListening { Task { await self.start() } }
            } else {
                log.notice("account changed; turning sync off")
                isListening = true
                Task {
                    await self.disable()
                    self.status = .accountChanged
                }
            }
        case .signOut:
            // The engine reset itself; keep everything on disk and wait for the same user.
            log.notice("account signed out; listening")
            isListening = true
            status = .signedOut
        case .switchAccounts:
            log.notice("account switched; turning sync off")
            isListening = true
            Task {
                await self.disable()
                self.status = .accountChanged
            }
        @unknown default:
            break
        }
    }

    private func handleDatabaseChanges(_ changes: CKSyncEngine.Event.FetchedDatabaseChanges, engine: CKSyncEngine) {
        for deletion in changes.deletions where deletion.zoneID == SyncZone.id {
            switch deletion.reason {
            case .purged:
                // The user deleted Sorl's iCloud data in System Settings: respect it, don't re-upload.
                log.notice("zone purged; turning sync off")
                isListening = true
                // The zone and its SyncKey are gone: so is this Mac's copy of the key.
                if let keyUser { SyncKeyStore.delete(user: keyUser) }
                Task {
                    await self.disable()
                    self.status = .cloudDataDeleted
                }
                return
            case .deleted, .encryptedDataReset:
                zoneLost(engine)
            @unknown default:
                zoneLost(engine)
            }
        }
    }

    /// While the key is unknown, fetched Saved and Shortcut modifications are applied anyway (they carry their
    /// data, and a re-queue only journals), with pending changes read from the journal. Saved deletions name a
    /// record by its keyed hash, so they wait in `deferredDeletes` until the key is adopted.
    private func handleFetched(_ changes: CKSyncEngine.Event.FetchedRecordZoneChanges, engine: CKSyncEngine) {
        // The key first: the rest of this batch may need it.
        for modification in changes.modifications where modification.record.recordType == SyncRecords.syncKeyType {
            adoptKey(from: modification.record, engine: engine)
        }
        let key = readyKey
        let (pendingSaves, pendingDeletes) = Self.pendingNames(engine)
        let local = Set(settings.saved.items.map(\.url.absoluteString))
        let journal = journal
        // Once the key is ready the engine's pending changes say what is pending; before that, only the journal.
        func hasPendingSave(_ item: SyncItem, _ id: CKRecord.ID) -> Bool {
            if key != nil { return pendingSaves.contains(id.recordName) }
            guard journal.contains(item.journalEntry) else { return false }
            if case .saved(let url) = item { return local.contains(url.absoluteString) }
            return true
        }
        func hasPendingDelete(_ item: SyncItem, _ id: CKRecord.ID) -> Bool {
            if key != nil { return pendingDeletes.contains(id.recordName) }
            guard case .saved(let url) = item, journal.contains(item.journalEntry) else { return false }
            return !local.contains(url.absoluteString)
        }

        var links: [(link: SavedLink, id: CKRecord.ID)] = []
        var requeue: [SyncItem] = []

        for modification in changes.modifications {
            let record = modification.record
            switch record.recordType {
            case SyncRecords.syncKeyType:
                continue
            case SyncRecords.savedLinkType:
                cacheSystemFields(record)
                if let link = SyncRecords.savedLink(from: record) {
                    links.append((link, record.recordID))
                } else {
                    log.error("ignoring malformed record \(record.recordID.recordName, privacy: .public)")
                }
            case ShortcutSync.shortcutType:
                cacheSystemFields(record)
                guard let remote = ShortcutSync.shortcut(from: record),
                      let name = Hotkeys.all.first(where: { $0.rawValue == remote.name })
                else { continue }
                // A pending local save is sent and settled by serverRecordChanged.
                if hasPendingSave(.shortcut(remote.name), record.recordID) { continue }
                if ShortcutSync.localWins(local: times[remote.name], remote: remote.modifiedAt) {
                    requeue.append(.shortcut(remote.name))
                } else {
                    applyShortcut(name, state: remote.state, modifiedAt: remote.modifiedAt)
                }
            default:
                cacheSystemFields(record)
                log.notice("ignoring record type \(record.recordType, privacy: .public)")
            }
        }

        let savedDeletes = changes.deletions.filter { $0.recordType == SyncRecords.savedLinkType }.map(\.recordID.recordName)
        for deletion in changes.deletions { dropSystemFields(deletion.recordID.recordName) }
        var deletesNow: [String] = []
        if key != nil { deletesNow = savedDeletes } else { deferredDeletes += savedDeletes }

        if !links.isEmpty || !deletesNow.isEmpty {
            let map = key.map { settings.saved.recordNameMap(key: $0) } ?? [:]
            settings.applyRemoteSaved { store in
                for (link, id) in links {
                    let applied = store.applyRemote(link, hasPendingDelete: hasPendingDelete(.saved(link.url), id))
                    if !applied { requeue.append(.saved(link.url)) } // local strictly newer
                }
                for name in deletesNow {
                    store.applyRemoteDelete(recordName: name, map: map, hasPendingSave: pendingSaves.contains(name))
                }
            }
        }
        queue(requeue.map { .save($0) })
    }

    private func handleSent(_ sent: CKSyncEngine.Event.SentRecordZoneChanges, engine: CKSyncEngine) {
        for record in sent.savedRecords {
            cacheSystemFields(record)
            if record.recordID.recordName == SyncRecords.syncKeyRecordName {
                // Our new key is in iCloud: it is the account's key now, and the held-back changes can go.
                if case .creating(let key) = keyState {
                    becomeReady(key, engine: engine, dropSavedFields: false)
                    log.notice("sync key created")
                }
                continue
            }
            prune(record.recordID, engine: engine)
        }
        for id in sent.deletedRecordIDs {
            dropSystemFields(id.recordName)
            prune(id, engine: engine)
        }
        for (id, error) in sent.failedRecordDeletes {
            if error.code == .unknownItem {
                // Already gone on the server: that's the outcome we wanted.
                dropSystemFields(id.recordName)
                prune(id, engine: engine)
            } else {
                log.error("deleting \(id.recordName, privacy: .public) failed: \(String(describing: error), privacy: .public)")
                noteProblem(error)
            }
        }
        var lostZone = false
        for failure in sent.failedRecordSaves {
            let id = failure.record.recordID
            let isKey = id.recordName == SyncRecords.syncKeyRecordName
            switch failure.error.code {
            case .serverRecordChanged where isKey:
                // Two Macs raced to create the key, or it changed: the server's key wins.
                guard let server = failure.error.serverRecord else {
                    log.error("conflict on \(id.recordName, privacy: .public) without a server record")
                    continue
                }
                adoptKey(from: server, engine: engine)
            case .serverRecordChanged:
                resolveConflict(failure.error, id: id, engine: engine)
            case .unknownItem:
                // Deleted on the server since we last saw it: upload again as a new record.
                dropSystemFields(id.recordName)
                if isKey {
                    queueSyncKeySave(engine)
                } else if let item = item(for: id) {
                    queue([.save(item)])
                }
            case .zoneNotFound where readyKey != nil:
                // The zone, and the key in it, is gone: redo the first-sync ordering.
                lostZone = true
            case .zoneNotFound:
                engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: id.zoneID))])
                dropSystemFields(id.recordName)
                if isKey { queueSyncKeySave(engine) }
            case .networkFailure, .networkUnavailable, .zoneBusy, .serviceUnavailable, .requestRateLimited,
                 .notAuthenticated, .accountTemporarilyUnavailable, .operationCancelled:
                // The engine retries these itself.
                log.info("saving \(id.recordName, privacy: .public) will retry: \(Self.describe(failure.error, isKey: isKey), privacy: .public)")
                noteProblem(failure.error)
            default:
                log.error("saving \(id.recordName, privacy: .public) failed: \(Self.describe(failure.error, isKey: isKey), privacy: .public)")
                noteProblem(failure.error)
            }
        }
        if lostZone { zoneLost(engine) }
    }

    /// Local strictly newer re-queues the save (now carrying the server's change tag); otherwise, equal included,
    /// the server copy is applied locally.
    private func resolveConflict(_ error: CKError, id: CKRecord.ID, engine: CKSyncEngine) {
        guard let server = error.serverRecord else {
            log.error("conflict on \(id.recordName, privacy: .public) without a server record")
            return
        }
        cacheSystemFields(server)
        switch server.recordType {
        case SyncRecords.savedLinkType:
            guard let link = SyncRecords.savedLink(from: server) else {
                if let item = item(for: id) { queue([.save(item)]) }
                return
            }
            let pendingDelete = Self.pendingNames(engine).deletes.contains(id.recordName)
            var localWins = false
            settings.applyRemoteSaved { localWins = !$0.applyRemote(link, hasPendingDelete: pendingDelete) }
            if localWins { queue([.save(.saved(link.url))]) } else { prune(id, engine: engine) }
        case ShortcutSync.shortcutType:
            guard let remote = ShortcutSync.shortcut(from: server),
                  let name = Hotkeys.all.first(where: { $0.rawValue == remote.name })
            else {
                prune(id, engine: engine)
                return
            }
            if ShortcutSync.localWins(local: times[remote.name], remote: remote.modifiedAt) {
                queue([.save(.shortcut(remote.name))])
            } else {
                applyShortcut(name, state: remote.state, modifiedAt: remote.modifiedAt)
                prune(id, engine: engine)
            }
        default:
            prune(id, engine: engine)
        }
    }

    private func applyShortcut(_ name: KeyboardShortcuts.Name, state: ShortcutState, modifiedAt: Date) {
        let stored = ShortcutState(storedValue: UserDefaults.standard.object(forKey: ShortcutState.defaultsKey(name.rawValue)))
        let unchanged = stored.map { ShortcutState.same($0, state, as: KeyboardShortcuts.Shortcut.self) } ?? false
        if !unchanged {
            let shortcut: KeyboardShortcuts.Shortcut?
            switch state {
            case .set(let json):
                guard let decoded = Self.decodeShortcut(json) else {
                    log.error("ignoring undecodable shortcut \(name.rawValue, privacy: .public)")
                    return
                }
                shortcut = decoded
            case .disabled:
                shortcut = nil
            }
            applyingShortcut = true
            KeyboardShortcuts.setShortcut(shortcut, for: name)
            applyingShortcut = false
        }
        times[name.rawValue] = modifiedAt
        saveTimes()
    }

    private func noteProblem(_ error: CKError) {
        guard error.code != .operationCancelled else { return }
        cycleProblem = Self.problem(for: error)
    }

    /// Only the mapped case reaches the UI; the raw error is logged by the caller.
    static func problem(for error: Error) -> Problem {
        guard let error = error as? CKError else { return .other }
        switch error.code {
        case .networkUnavailable, .networkFailure: return .offline
        case .quotaExceeded: return .quotaExceeded
        case .notAuthenticated: return .notAuthenticated
        default: return .other
        }
    }

    // MARK: Batches

    private func pendingChanges(in scope: CKSyncEngine.SendChangesOptions.Scope,
                                for syncEngine: CKSyncEngine) -> [CKSyncEngine.PendingRecordZoneChange] {
        guard syncEngine === engine, !isListening else { return [] }
        let changes = syncEngine.state.pendingRecordZoneChanges.filter { scope.contains($0) }
        guard readyKey == nil else { return changes }
        // Until the key is ready only `sync-key` goes out (the zone is a database change, sent first anyway).
        return changes.filter {
            if case .saveRecord(let id) = $0 { return id.recordName == SyncRecords.syncKeyRecordName }
            return false
        }
    }

    /// The record to send, built from the current local item on top of the last-known system fields. When the item
    /// is gone, its pending save and journal entry are dropped so the engine stops asking.
    private func recordToSave(_ id: CKRecord.ID, for syncEngine: CKSyncEngine) -> CKRecord? {
        guard syncEngine === engine, !isListening else { return nil }
        let name = id.recordName
        if name == SyncRecords.syncKeyRecordName {
            let key: SymmetricKey
            switch keyState {
            case .creating(let k), .ready(let k):
                key = k
            case .unknown, .fetching:
                syncEngine.state.remove(pendingRecordZoneChanges: [.saveRecord(id)])
                return nil
            }
            log.notice("saving record \(name, privacy: .public)")
            return SyncRecords.syncKeyRecord(key: key, base: baseRecord(name))
        }
        // Held back until the key is ready; `pendingChanges` doesn't offer these before then.
        guard let key = readyKey else { return nil }
        guard let record = localRecord(named: name, key: key) else {
            syncEngine.state.remove(pendingRecordZoneChanges: [.saveRecord(id)])
            if let entry = journalIndex(key)[name] { removeFromJournal(entry, key: key) }
            return nil
        }
        log.notice("saving record \(name, privacy: .public)")
        return record
    }

    private func localRecord(named name: String, key: SymmetricKey) -> CKRecord? {
        if name.hasPrefix(Self.savedPrefix) {
            guard let url = savedRecordNameMap(key)[name], let link = settings.saved.items.first(where: { $0.url == url }) else { return nil }
            return SyncRecords.record(for: link, key: key, base: baseRecord(name))
        }
        if name.hasPrefix(ShortcutSync.recordPrefix) {
            let rawValue = String(name.dropFirst(ShortcutSync.recordPrefix.count))
            guard Hotkeys.all.contains(where: { $0.rawValue == rawValue }),
                  let state = ShortcutState(storedValue: UserDefaults.standard.object(forKey: ShortcutState.defaultsKey(rawValue)))
            else { return nil }
            return ShortcutSync.record(name: rawValue, state: state, modifiedAt: times[rawValue] ?? .distantPast, base: baseRecord(name))
        }
        return nil
    }

    /// Record name → URL for the local items under `key`, the current key. `keyChanged` drops the cache.
    private func savedRecordNameMap(_ key: SymmetricKey) -> [String: URL] {
        if let mapCache, mapCache.store == settings.saved { return mapCache.map }
        let map = settings.saved.recordNameMap(key: key)
        mapCache = (settings.saved, map)
        return map
    }

    /// The local item a record name stands for, under the current key: a shortcut by its name, a link through
    /// the local items, or a journaled link that is gone locally.
    private func item(for id: CKRecord.ID) -> SyncItem? {
        let name = id.recordName
        if name.hasPrefix(ShortcutSync.recordPrefix) { return .shortcut(String(name.dropFirst(ShortcutSync.recordPrefix.count))) }
        guard let key = readyKey else { return nil }
        if let url = savedRecordNameMap(key)[name] { return .saved(url) }
        return journalIndex(key)[name].flatMap(SyncItem.init(journalEntry:))
    }

    // MARK: Journal

    private func addToJournal(_ entries: [String]) {
        var added = false
        for entry in entries where journal.insert(entry).inserted {
            added = true
            if let key = readyKey, journalIndexCache != nil, let item = SyncItem(journalEntry: entry) {
                journalIndexCache?[item.recordName(key: key)] = entry
            }
        }
        if added { saveJournal() }
    }

    private func removeFromJournal(_ entry: String, key: SymmetricKey) {
        guard journal.remove(entry) != nil else { return }
        if let item = SyncItem(journalEntry: entry) { journalIndexCache?[item.recordName(key: key)] = nil }
        saveJournal()
    }

    /// Record name → journal entry under `key`, the current key; kept up to date by add and remove.
    private func journalIndex(_ key: SymmetricKey) -> [String: String] {
        if let journalIndexCache { return journalIndexCache }
        var index: [String: String] = [:]
        for entry in journal {
            guard let item = SyncItem(journalEntry: entry) else { continue }
            index[item.recordName(key: key)] = entry
        }
        journalIndexCache = index
        return index
    }

    /// A final outcome for `id`: drop it from the journal unless a newer change for it is still pending.
    private func prune(_ id: CKRecord.ID, engine: CKSyncEngine) {
        guard let key = readyKey, let entry = journalIndex(key)[id.recordName] else { return }
        let stillPending = engine.state.pendingRecordZoneChanges.contains { Self.recordID(of: $0)?.recordName == id.recordName }
        guard !stillPending else { return }
        removeFromJournal(entry, key: key)
    }

    private func saveJournal() {
        UserDefaults.standard.set(journal.sorted(), forKey: Keys.dirty)
    }

    // MARK: Persistence

    private func savedState() -> CKSyncEngine.State.Serialization? {
        guard let data = UserDefaults.standard.data(forKey: Keys.state) else { return nil }
        return try? JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: data)
    }

    private func saveState(_ state: CKSyncEngine.State.Serialization) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        UserDefaults.standard.set(data, forKey: Keys.state)
    }

    private func saveTimes() {
        guard let data = try? times.encoded() else { return }
        UserDefaults.standard.set(data, forKey: Keys.times)
    }

    private var fields: [String: Data] {
        get {
            if let loadedFields { return loadedFields }
            let loaded = (try? Data(contentsOf: Self.fieldsURL))
                .flatMap { try? PropertyListDecoder().decode([String: Data].self, from: $0) } ?? [:]
            loadedFields = loaded
            return loaded
        }
        set {
            loadedFields = newValue
            scheduleFieldsSave()
        }
    }

    private func cacheSystemFields(_ record: CKRecord) {
        let coder = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: coder)
        coder.finishEncoding()
        fields[record.recordID.recordName] = coder.encodedData
    }

    private func dropSystemFields(_ name: String) {
        guard fields[name] != nil else { return }
        fields[name] = nil
    }

    private func baseRecord(_ name: String) -> CKRecord? {
        guard let data = fields[name], let coder = try? NSKeyedUnarchiver(forReadingFrom: data) else { return nil }
        coder.requiresSecureCoding = true
        defer { coder.finishDecoding() }
        return CKRecord(coder: coder)
    }

    private func scheduleFieldsSave() {
        fieldsDirty = true
        saveFieldsTask?.cancel()
        saveFieldsTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard let self, !Task.isCancelled else { return }
            self.flush()
        }
    }

    // MARK: Helpers

    private static func recordID(_ name: String) -> CKRecord.ID {
        CKRecord.ID(recordName: name, zoneID: SyncZone.id)
    }

    /// No such record or zone, possibly wrapped in a partial failure.
    private static func isMissing(_ error: CKError) -> Bool {
        if error.code == .unknownItem || error.code == .zoneNotFound { return true }
        guard error.code == .partialFailure, let inner = error.partialErrorsByItemID?.values, !inner.isEmpty else { return false }
        return inner.allSatisfy { ($0 as? CKError).map(isMissing) ?? false }
    }

    private static func sameKey(_ a: SymmetricKey, _ b: SymmetricKey) -> Bool {
        a.withUnsafeBytes { Data($0) } == b.withUnsafeBytes { Data($0) }
    }

    /// A failed save as text for the log. For `sync-key` only the code: the error's description can carry the
    /// client or server record, and with it the key.
    private static func describe(_ error: CKError, isKey: Bool) -> String {
        isKey ? "CKError \(error.code.rawValue)" : String(describing: error)
    }

    private static func recordID(of change: CKSyncEngine.PendingRecordZoneChange) -> CKRecord.ID? {
        switch change {
        case .saveRecord(let id), .deleteRecord(let id): return id
        @unknown default: return nil
        }
    }

    private static func pendingNames(_ engine: CKSyncEngine) -> (saves: Set<String>, deletes: Set<String>) {
        var saves = Set<String>(), deletes = Set<String>()
        for change in engine.state.pendingRecordZoneChanges {
            switch change {
            case .saveRecord(let id): saves.insert(id.recordName)
            case .deleteRecord(let id): deletes.insert(id.recordName)
            @unknown default: break
            }
        }
        return (saves, deletes)
    }

    private static func decodeShortcut(_ json: String) -> KeyboardShortcuts.Shortcut? {
        try? JSONDecoder().decode(KeyboardShortcuts.Shortcut.self, from: Data(json.utf8))
    }
}

// MARK: - CKSyncEngineDelegate

extension CloudSync: CKSyncEngineDelegate {
    nonisolated func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        await handle(event, from: syncEngine)
    }

    nonisolated func nextRecordZoneChangeBatch(_ context: CKSyncEngine.SendChangesContext,
                                               syncEngine: CKSyncEngine) async -> CKSyncEngine.RecordZoneChangeBatch? {
        let changes = await pendingChanges(in: context.options.scope, for: syncEngine)
        guard !changes.isEmpty else { return nil }
        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: changes) { id in
            await self.recordToSave(id, for: syncEngine)
        }
    }
}
