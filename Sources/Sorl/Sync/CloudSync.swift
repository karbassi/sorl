import CloudKit
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

    private static let containerID = "iCloud.com.karbassi.sorl"
    private static let savedPrefix = "saved-"
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
    /// `cloudSyncDirty`: record names with a change not yet confirmed by the server.
    @ObservationIgnored private var journal: Set<String>
    @ObservationIgnored private var times: ShortcutTimes
    /// Last-known system fields by record name; loaded from disk on first use.
    @ObservationIgnored private var loadedFields: [String: Data]?
    @ObservationIgnored private var fieldsDirty = false
    @ObservationIgnored private var saveFieldsTask: Task<Void, Never>?
    @ObservationIgnored private var mapCache: (store: SavedLinksStore, map: [String: URL])?

    init(settings: AppSettings) {
        self.settings = settings
        status = ICloudEntitlement.hasCloudKit ? .off : .unavailable
        journal = Set(UserDefaults.standard.stringArray(forKey: Keys.dirty) ?? [])
        times = ShortcutTimes(decoding: UserDefaults.standard.data(forKey: Keys.times) ?? Data())
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
        guard await accountAvailable(for: engine) else { isStarting = false; return }
        isStarting = false
        // Turned on while signed out: the zone was never queued.
        if !hadState { engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: SyncZone.id))]) }
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
        let ids = allLocalRecordIDs()
        // If the account isn't available yet, the same-user sign-in path re-queues these from the journal.
        addToJournal(ids.map(\.recordName))
        isStarting = true
        let engine = await replaceEngine()
        guard await accountAvailable(for: engine) else { isStarting = false; return }
        isStarting = false
        engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: SyncZone.id))])
        queue(ids.map { .saveRecord($0) })
        await fetch(engine)
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

    // MARK: Local changes

    /// Called by AppSettings with each local change to Saved.
    func savedDidChange(old: SavedLinksStore, new: SavedLinksStore) {
        guard settings.syncEnabled, !settings.isDemo, ICloudEntitlement.hasCloudKit else { return }
        let diff = SavedLinksStore.changes(from: old, to: new)
        let changes: [CKSyncEngine.PendingRecordZoneChange] =
            diff.upserts.map { .saveRecord(Self.savedRecordID($0.url)) } + diff.deletes.map { .deleteRecord(Self.savedRecordID($0)) }
        queue(changes)
    }

    /// Called for every local shortcut change. Stamps it even while sync is off, so a later first enable knows it
    /// was customized.
    func shortcutDidChange(_ name: KeyboardShortcuts.Name) {
        guard !applyingShortcut else { return }
        times[name.rawValue] = ShortcutSync.nextStamp(previous: times[name.rawValue], now: Date())
        saveTimes()
        guard settings.syncEnabled, ICloudEntitlement.hasCloudKit else { return }
        queue([.saveRecord(Self.shortcutRecordID(name.rawValue))])
    }

    /// The only way a pending change is added: drops any pending save or delete for the same record, adds this one,
    /// and journals the record name synchronously. While signed out (or before an engine exists) only the journal
    /// is written.
    private func queue(_ changes: [CKSyncEngine.PendingRecordZoneChange]) {
        guard !changes.isEmpty else { return }
        let ids = changes.compactMap(Self.recordID(of:))
        addToJournal(ids.map(\.recordName))
        guard let engine, !isListening else { return }
        engine.state.remove(pendingRecordZoneChanges: ids.flatMap { [.saveRecord($0), .deleteRecord($0)] })
        engine.state.add(pendingRecordZoneChanges: changes)
    }

    /// Each journal entry as a save if the item exists locally, otherwise a delete. Shortcuts always exist.
    private func requeueJournal() {
        let map = savedRecordNameMap()
        let changes: [CKSyncEngine.PendingRecordZoneChange] = journal.sorted().map { name in
            let id = Self.recordID(name)
            if name.hasPrefix(ShortcutSync.recordPrefix) || map[name] != nil { return .saveRecord(id) }
            return .deleteRecord(id)
        }
        queue(changes)
    }

    private func allLocalRecordIDs() -> [CKRecord.ID] {
        settings.saved.items.map { Self.savedRecordID($0.url) } + Hotkeys.all.map { Self.shortcutRecordID($0.rawValue) }
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
                Task {
                    await self.disable()
                    self.status = .cloudDataDeleted
                }
                return
            case .deleted, .encryptedDataReset:
                recreateZone(engine)
            @unknown default:
                recreateZone(engine)
            }
        }
    }

    /// The zone is gone but sync stays on: upload everything again as new records. Local data is untouched.
    private func recreateZone(_ engine: CKSyncEngine) {
        log.notice("zone deleted; re-creating it")
        loadedFields = [:]
        scheduleFieldsSave()
        engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: SyncZone.id))])
        queue(allLocalRecordIDs().map { .saveRecord($0) })
    }

    private func handleFetched(_ changes: CKSyncEngine.Event.FetchedRecordZoneChanges, engine: CKSyncEngine) {
        let (pendingSaves, pendingDeletes) = Self.pendingNames(engine)
        var links: [(link: SavedLink, id: CKRecord.ID)] = []
        var requeue: [CKRecord.ID] = []

        for modification in changes.modifications {
            let record = modification.record
            cacheSystemFields(record)
            switch record.recordType {
            case SyncRecords.savedLinkType:
                if let link = SyncRecords.savedLink(from: record) {
                    links.append((link, record.recordID))
                } else {
                    log.error("ignoring malformed record \(record.recordID.recordName, privacy: .public)")
                }
            case ShortcutSync.shortcutType:
                guard let remote = ShortcutSync.shortcut(from: record),
                      let name = Hotkeys.all.first(where: { $0.rawValue == remote.name })
                else { continue }
                // A pending local save is sent and settled by serverRecordChanged.
                if pendingSaves.contains(record.recordID.recordName) { continue }
                if ShortcutSync.localWins(local: times[remote.name], remote: remote.modifiedAt) {
                    requeue.append(record.recordID)
                } else {
                    applyShortcut(name, state: remote.state, modifiedAt: remote.modifiedAt)
                }
            default:
                log.notice("ignoring record type \(record.recordType, privacy: .public)")
            }
        }

        let savedDeletes = changes.deletions.filter { $0.recordType == SyncRecords.savedLinkType }
        for deletion in changes.deletions { dropSystemFields(deletion.recordID.recordName) }

        if !links.isEmpty || !savedDeletes.isEmpty {
            let map = settings.saved.recordNameMap()
            settings.applyRemoteSaved { store in
                for (link, id) in links {
                    let applied = store.applyRemote(link, hasPendingDelete: pendingDeletes.contains(id.recordName))
                    if !applied { requeue.append(id) } // local strictly newer
                }
                for deletion in savedDeletes {
                    let name = deletion.recordID.recordName
                    store.applyRemoteDelete(recordName: name, map: map, hasPendingSave: pendingSaves.contains(name))
                }
            }
        }
        queue(requeue.map { .saveRecord($0) })
    }

    private func handleSent(_ sent: CKSyncEngine.Event.SentRecordZoneChanges, engine: CKSyncEngine) {
        for record in sent.savedRecords {
            cacheSystemFields(record)
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
        for failure in sent.failedRecordSaves {
            let id = failure.record.recordID
            switch failure.error.code {
            case .serverRecordChanged:
                resolveConflict(failure.error, id: id, engine: engine)
            case .unknownItem:
                // Deleted on the server since we last saw it: upload again as a new record.
                dropSystemFields(id.recordName)
                queue([.saveRecord(id)])
            case .zoneNotFound:
                engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: id.zoneID))])
                dropSystemFields(id.recordName)
                queue([.saveRecord(id)])
            case .networkFailure, .networkUnavailable, .zoneBusy, .serviceUnavailable, .requestRateLimited,
                 .notAuthenticated, .accountTemporarilyUnavailable, .operationCancelled:
                // The engine retries these itself.
                log.info("saving \(id.recordName, privacy: .public) will retry: \(String(describing: failure.error), privacy: .public)")
                noteProblem(failure.error)
            default:
                log.error("saving \(id.recordName, privacy: .public) failed: \(String(describing: failure.error), privacy: .public)")
                noteProblem(failure.error)
            }
        }
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
                queue([.saveRecord(id)])
                return
            }
            let pendingDelete = Self.pendingNames(engine).deletes.contains(id.recordName)
            var localWins = false
            settings.applyRemoteSaved { localWins = !$0.applyRemote(link, hasPendingDelete: pendingDelete) }
            if localWins { queue([.saveRecord(id)]) } else { prune(id, engine: engine) }
        case ShortcutSync.shortcutType:
            guard let remote = ShortcutSync.shortcut(from: server),
                  let name = Hotkeys.all.first(where: { $0.rawValue == remote.name })
            else {
                prune(id, engine: engine)
                return
            }
            if ShortcutSync.localWins(local: times[remote.name], remote: remote.modifiedAt) {
                queue([.saveRecord(id)])
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
        return syncEngine.state.pendingRecordZoneChanges.filter { scope.contains($0) }
    }

    /// The record to send, built from the current local item on top of the last-known system fields. When the item
    /// is gone, its pending save and journal entry are dropped so the engine stops asking.
    private func recordToSave(_ id: CKRecord.ID, for syncEngine: CKSyncEngine) -> CKRecord? {
        guard syncEngine === engine, !isListening else { return nil }
        let name = id.recordName
        guard let record = localRecord(named: name) else {
            syncEngine.state.remove(pendingRecordZoneChanges: [.saveRecord(id)])
            removeFromJournal(name)
            return nil
        }
        log.notice("saving record \(name, privacy: .public)")
        return record
    }

    private func localRecord(named name: String) -> CKRecord? {
        if name.hasPrefix(Self.savedPrefix) {
            guard let url = savedRecordNameMap()[name], let link = settings.saved.items.first(where: { $0.url == url }) else { return nil }
            return SyncRecords.record(for: link, base: baseRecord(name))
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

    private func savedRecordNameMap() -> [String: URL] {
        if let mapCache, mapCache.store == settings.saved { return mapCache.map }
        let map = settings.saved.recordNameMap()
        mapCache = (settings.saved, map)
        return map
    }

    // MARK: Journal

    private func addToJournal(_ names: [String]) {
        let before = journal.count
        journal.formUnion(names)
        if journal.count != before { saveJournal() }
    }

    private func removeFromJournal(_ name: String) {
        guard journal.remove(name) != nil else { return }
        saveJournal()
    }

    /// A final outcome for `id`: drop it from the journal unless a newer change for it is still pending.
    private func prune(_ id: CKRecord.ID, engine: CKSyncEngine) {
        guard journal.contains(id.recordName) else { return }
        let stillPending = engine.state.pendingRecordZoneChanges.contains { Self.recordID(of: $0)?.recordName == id.recordName }
        guard !stillPending else { return }
        removeFromJournal(id.recordName)
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

    private static func savedRecordID(_ url: URL) -> CKRecord.ID {
        recordID(SyncRecords.savedRecordName(for: url))
    }

    private static func shortcutRecordID(_ rawValue: String) -> CKRecord.ID {
        recordID(ShortcutSync.recordName(for: rawValue))
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
