import Foundation
import Observation
import SorlCore

/// All persisted preferences. Every write lands in UserDefaults immediately.
@Observable
final class AppSettings {
    private enum Keys {
        static let speed = "speed"
        static let volume = "volume"
        static let recent = "recentLinks"
        static let saved = "savedLinks"
        static let ytdlpPath = "ytdlpPath"
        static let lastLink = "lastLink"
        static let repeatMode = "repeatMode"
        static let showTitle = "showTitleInMenuBar"
        /// Bumped when `Track` gains data older entries lack (v2: chapters), so a stale cache hit can't hide it.
        static let streamCache = "streamCacheV2"
        static let legacyStreamCaches = ["streamCache"]
        /// Left behind by the removed appearance settings (tint, glass style, backdrop).
        static let legacyAppearance = ["tintHex", "tintOpacity", "glassStyle", "backdrop"]
        static let ytdlpCachedPath = "ytdlpCachedPath"
        static let ytdlpCachedDeno = "ytdlpCachedDeno"
        static let ytdlpCachedVersion = "ytdlpCachedVersion"
        static let ytdlpProbedAt = "ytdlpProbedAt"
        static let idleUnloadSeconds = "idleUnloadSeconds"
        static let positions = "playbackPositions"
        static let upNext = "upNext"
        static let showTotalTime = "showTotalTime"
        static let downloadsLimit = "downloadsLimitGB"
        static let syncEnabled = "syncEnabled"
    }

    @ObservationIgnored private var defaults: UserDefaults
    @ObservationIgnored private var persistCacheTask: Task<Void, Never>?
    @ObservationIgnored private var persistUpNextTask: Task<Void, Never>?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        speed = PlaybackSpeed(rawValue: defaults.double(forKey: Keys.speed)) ?? .normal
        volume = defaults.object(forKey: Keys.volume) as? Double ?? 1.0
        recent = RecentLinksStore(decoding: defaults.data(forKey: Keys.recent) ?? Data())
        saved = SavedLinksStore(decoding: defaults.data(forKey: Keys.saved) ?? Data())
        ytdlpPathOverride = defaults.string(forKey: Keys.ytdlpPath)
        lastLink = defaults.string(forKey: Keys.lastLink)
        repeatMode = RepeatMode(rawValue: defaults.string(forKey: Keys.repeatMode) ?? "") ?? .off
        showTitleInMenuBar = defaults.bool(forKey: Keys.showTitle)
        Keys.legacyStreamCaches.forEach(defaults.removeObject(forKey:))
        Keys.legacyAppearance.forEach(defaults.removeObject(forKey:))
        streamCache = StreamCache(decoding: defaults.data(forKey: Keys.streamCache) ?? Data())
        ytdlpCachedPath = defaults.string(forKey: Keys.ytdlpCachedPath)
        ytdlpCachedDeno = defaults.string(forKey: Keys.ytdlpCachedDeno)
        ytdlpCachedVersion = defaults.string(forKey: Keys.ytdlpCachedVersion)
        ytdlpProbedAt = defaults.object(forKey: Keys.ytdlpProbedAt) as? Date
        idleUnloadSeconds = defaults.object(forKey: Keys.idleUnloadSeconds) as? Double ?? 10 * 60
        positions = PlaybackPositions(decoding: defaults.data(forKey: Keys.positions) ?? Data())
        upNext = UpNext(decoding: defaults.data(forKey: Keys.upNext) ?? Data())
        showTotalTime = defaults.bool(forKey: Keys.showTotalTime)
        let limit = defaults.integer(forKey: Keys.downloadsLimit)
        downloadsLimitGB = Self.downloadsLimits.contains(limit) ? limit : 2
        syncEnabled = UserDefaults.standard.bool(forKey: Keys.syncEnabled)
    }

    /// iCloud sync on/off. Always in `UserDefaults.standard`, never the swappable `defaults`: demo mode can't
    /// change it (CloudSync's `setEnabled` is a no-op in demo mode).
    var syncEnabled: Bool {
        didSet { UserDefaults.standard.set(syncEnabled, forKey: Keys.syncEnabled) }
    }

    /// True once `enterDemoMode` has swapped in the throwaway defaults (until relaunch).
    private(set) var isDemo = false

    /// Called with (old, new) after a local change to `saved`; not called for `applyRemoteSaved`.
    @ObservationIgnored var onSavedChange: ((SavedLinksStore, SavedLinksStore) -> Void)?
    @ObservationIgnored private var isApplyingRemote = false

    /// Applies a change that came from iCloud: persisted like any edit, but not echoed to `onSavedChange`.
    func applyRemoteSaved(_ body: (inout SavedLinksStore) -> Void) {
        isApplyingRemote = true
        defer { isApplyingRemote = false }
        body(&saved)
    }

    /// "Keep up to" in Settings: 1, 2, 5 or 10 GB of downloads (default 2).
    static let downloadsLimits = [1, 2, 5, 10]
    var downloadsLimitGB: Int {
        didSet { defaults.set(downloadsLimitGB, forKey: Keys.downloadsLimit) }
    }

    /// The player's time toggle: total time instead of time left. Remembered across videos and relaunches.
    var showTotalTime: Bool {
        didSet { defaults.set(showTotalTime, forKey: Keys.showTotalTime) }
    }

    /// What's playing, Up next and Played, so the queue survives relaunch. Written on a short debounce (drags and
    /// pastes come in bursts) and flushed on quit.
    @ObservationIgnored var upNext: UpNext {
        didSet {
            guard upNext != oldValue else { return }
            persistUpNextTask?.cancel()
            persistUpNextTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(500))
                guard let self, !Task.isCancelled else { return }
                self.flushUpNext()
            }
        }
    }

    func flushUpNext() {
        persistUpNextTask?.cancel()
        defaults.set((try? upNext.encoded()) ?? Data(), forKey: Keys.upNext)
    }

    /// The demo harness (`sorl://demo`) is off unless `defaults write com.karbassi.sorl demoHarness -bool YES`.
    var demoHarnessEnabled: Bool { UserDefaults.standard.bool(forKey: "demoHarness") }

    /// Demo fixtures must never overwrite real Saved, Recent or Up next: from here on every write goes to a
    /// throwaway domain (until relaunch).
    func enterDemoMode() {
        guard let demo = UserDefaults(suiteName: "com.karbassi.sorl.demo") else { return }
        persistUpNextTask?.cancel()
        persistCacheTask?.cancel()
        isDemo = true
        onSavedChange = nil
        defaults = demo
    }

    var speed: PlaybackSpeed {
        didSet { defaults.set(speed.rawValue, forKey: Keys.speed) }
    }
    var volume: Double {
        didSet { defaults.set(volume, forKey: Keys.volume) }
    }
    var recent: RecentLinksStore {
        didSet { defaults.set((try? recent.encoded()) ?? Data(), forKey: Keys.recent) }
    }
    var saved: SavedLinksStore {
        didSet {
            defaults.set((try? saved.encoded()) ?? Data(), forKey: Keys.saved)
            if !isApplyingRemote { onSavedChange?(oldValue, saved) }
        }
    }
    /// Where each long track (a mix) was left. Written on pause, seek, track change, quit, and every
    /// `PlayerEngine.positionSaveInterval` while playing.
    var positions: PlaybackPositions {
        didSet {
            guard positions != oldValue else { return }
            defaults.set((try? positions.encoded()) ?? Data(), forKey: Keys.positions)
        }
    }

    var ytdlpPathOverride: String? {
        didSet { defaults.set(ytdlpPathOverride, forKey: Keys.ytdlpPath) }
    }
    var lastLink: String? {
        didSet { defaults.set(lastLink, forKey: Keys.lastLink) }
    }
    var repeatMode: RepeatMode {
        didSet { defaults.set(repeatMode.rawValue, forKey: Keys.repeatMode) }
    }
    var showTitleInMenuBar: Bool {
        didSet { defaults.set(showTitleInMenuBar, forKey: Keys.showTitle) }
    }
    /// Resolved streams survive relaunches (they stay valid for ~6 h), so recent replays are instant.
    /// The blob is re-encoded on a short debounce, not on every mutation (stores come in bursts).
    var streamCache: StreamCache {
        didSet {
            persistCacheTask?.cancel()
            persistCacheTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled else { return }
                self.flushStreamCache()
            }
        }
    }

    /// Writes any pending stream-cache change immediately (called on quit).
    func flushStreamCache() {
        persistCacheTask?.cancel()
        defaults.set((try? streamCache.encoded()) ?? Data(), forKey: Keys.streamCache)
    }
    /// Last successful yt-dlp probe, so a normal launch spawns no processes at all.
    var ytdlpCachedPath: String? {
        didSet { defaults.set(ytdlpCachedPath, forKey: Keys.ytdlpCachedPath) }
    }
    var ytdlpCachedDeno: String? {
        didSet { defaults.set(ytdlpCachedDeno, forKey: Keys.ytdlpCachedDeno) }
    }
    var ytdlpCachedVersion: String? {
        didSet { defaults.set(ytdlpCachedVersion, forKey: Keys.ytdlpCachedVersion) }
    }
    var ytdlpProbedAt: Date? {
        didSet { defaults.set(ytdlpProbedAt, forKey: Keys.ytdlpProbedAt) }
    }
    /// How long a paused track sits before the media pipeline is released (`defaults write … idleUnloadSeconds`).
    var idleUnloadSeconds: Double {
        didSet { defaults.set(idleUnloadSeconds, forKey: Keys.idleUnloadSeconds) }
    }
}
