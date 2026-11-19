import AVFoundation
import Combine
import Foundation
import Observation
import UndertoneCore
import os

/// Owns the AVPlayer and the current track/queue. Audio only: no AVPlayerLayer is ever attached.
@Observable
final class PlayerEngine {
    private(set) var track: Track?
    /// What's playing, Up next and Played. Persisted on every change so the queue survives relaunch.
    private(set) var upNext: UpNext {
        didSet { settings.upNext = upNext }
    }
    private(set) var isResolving = false
    private(set) var resolvingTitle: String?
    private(set) var isPlaying = false
    private(set) var isBuffering = false
    private(set) var hasEnded = false
    private(set) var currentTime: Double = 0
    /// The chapter playing now (a DJ mix's current track). Kept fresh even while the panel is hidden, without a timer.
    private(set) var chapter: Chapter?
    /// Bumped on every seek so observers (Now Playing) resync their elapsed time.
    private(set) var seekGeneration = 0
    private(set) var speed: PlaybackSpeed
    private(set) var repeatMode: RepeatMode
    private(set) var isMuted = false
    private(set) var errorMessage: String?
    private(set) var errorSuggestion: String?
    private(set) var notice: String?
    /// Bytes in the on-disk audio cache; refreshed after each download and by `refreshAudioCacheSize()`.
    private(set) var audioCacheBytes: Int64 = 0
    /// Cache keys fully downloaded (rows show the download glyph). Refreshed with `audioCacheBytes`.
    private(set) var downloadedKeys: Set<String> = []

    var volume: Float {
        didSet {
            player.volume = isMuted ? 0 : volume
            persistVolumeTask?.cancel()
            persistVolumeTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(300))
                guard let self, !Task.isCancelled else { return }
                self.settings.volume = Double(self.volume)
            }
        }
    }

    /// The player's real position right now. `currentTime` is only kept fresh while the panel is visible.
    var livePosition: Double {
        guard player.currentItem != nil else { return currentTime }
        let t = player.currentTime()
        return t.isNumeric ? t.seconds : currentTime
    }

    /// What the slider shows: 0 while muted.
    var effectiveVolume: Float { isMuted ? 0 : volume }

    var volumeSymbol: String {
        if isMuted || volume == 0 { return "speaker.slash.fill" }
        if volume < 0.34 { return "speaker.wave.1.fill" }
        if volume < 0.67 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }

    /// yt-dlp's duration wins: AVFoundation reports double the real length for a YouTube m4a opened as a file
    /// (the chunked fallback, or a file from the audio cache). Played as HLS it gets the length right.
    var duration: Double? {
        if let d = track?.duration, d > 0 { return d }
        guard let t = player.currentItem?.duration, t.isNumeric, t.seconds.isFinite, t.seconds > 0 else { return nil }
        return t.seconds
    }

    /// What the player shows before anything loads (after a relaunch): the saved item's length.
    var shownDuration: Double? { duration ?? (track == nil ? upNext.current?.duration : nil) }

    /// The position to show: the live one, or the saved one for an item restored on relaunch.
    var shownTime: Double {
        guard track == nil, !isResolving, let current = upNext.current else { return currentTime }
        return settings.positions.position(for: current.url)?.seconds ?? 0
    }

    @ObservationIgnored let player = AVPlayer()
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let service: YTDLPService
    @ObservationIgnored private let log = Logger(subsystem: "com.jverissimo.undertone", category: "player")
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var playerStateTask: Task<Void, Never>?
    @ObservationIgnored private var itemStatusTask: Task<Void, Never>?
    @ObservationIgnored private var endObserver: NSObjectProtocol?
    @ObservationIgnored private var resolveTask: Task<Void, Never>?
    /// Speculative resolves (clipboard warm-up, next playlist entry) keyed by cache key. A user resolve
    /// for the same link joins the in-flight task instead of spawning a second yt-dlp.
    @ObservationIgnored private var backgroundResolves: [String: Task<Track?, Never>] = [:]
    @ObservationIgnored private var backgroundOwners: [String: Int] = [:]
    @ObservationIgnored private var backgroundGeneration = 0
    /// How `upNext` changes once the link being resolved loads. Committed in `load`, so a failed or cancelled
    /// navigation leaves the queue and the playing track untouched.
    @ObservationIgnored private var pendingCommit: ((inout UpNext, Track) -> Void)?
    /// The Up next entry a Next is heading for while it resolves, so a second Next goes one further.
    @ObservationIgnored private var pendingTargetID: QueueItem.ID?
    @ObservationIgnored private var consecutiveQueueSkips = 0
    @ObservationIgnored private var currentLink: MediaLink?
    @ObservationIgnored private var pastedLink: MediaLink?
    @ObservationIgnored private var recoveryAttempts = 0
    @ObservationIgnored private var lastLoadedKey: String?
    @ObservationIgnored private var progressTracking = false
    @ObservationIgnored private var idleUnloadTask: Task<Void, Never>?
    @ObservationIgnored private var isIdleUnloaded = false
    @ObservationIgnored private var persistVolumeTask: Task<Void, Never>?
    @ObservationIgnored private var stateSyncTask: Task<Void, Never>?
    @ObservationIgnored private var failedWarmKeys: [String: Date] = [:]
    /// Feeds the current YouTube item (its playlist, or bounded ranges); held here because AVAssetResourceLoader keeps it weakly.
    @ObservationIgnored private var streamLoader: (any AVAssetResourceLoaderDelegate)?
    @ObservationIgnored private var positionObserver: Any?
    /// Where an in-flight seek (the resume seek on load, or a user seek) is heading; until it lands the player clock
    /// still reads the old time (or 0), so this stands in for it.
    @ObservationIgnored private var pendingSeekTarget: Double?
    @ObservationIgnored private var seekCount = 0
    @ObservationIgnored let audioCache = AudioCache.standard(bundleIdentifier: Bundle.main.bundleIdentifier)
    /// The background download filling `audioCache` for `downloadKey` (only ever the loaded track).
    @ObservationIgnored private var downloadTask: Task<Void, Never>?
    @ObservationIgnored private var downloadKey: String?
    /// The loaded item plays from `audioCache` rather than the network.
    @ObservationIgnored private var playingCachedFile = false
    /// A track is downloaded for the cache only after it has been loaded this long, so a skipped track costs nothing.
    static let audioCacheDelay: Duration = .seconds(20)
    /// Fires at each chapter start of the loaded item.
    @ObservationIgnored private var chapterObserver: Any?
    /// How often the position is saved while playing (it is also saved on every pause, seek and track change).
    static let positionSaveInterval: Double = 15
    /// Unavailable playlist entries skipped in a row before giving up (avoids marching through a dead playlist).
    static let maxConsecutiveSkips = 5
    /// Automatic re-resolves (expired URL, failed item) allowed per loaded track before giving up.
    static let maxRecoveries = 2
    // After `settings.idleUnloadSeconds` paused (default 10 min), the media pipeline is released so a
    // forgotten Undertone costs nothing.

    init(settings: AppSettings, service: YTDLPService) {
        self.settings = settings
        self.service = service
        speed = settings.speed
        upNext = settings.upNext
        repeatMode = settings.repeatMode
        volume = Float(settings.volume)
        player.volume = volume
        player.defaultRate = Float(speed.rawValue)
        player.actionAtItemEnd = .pause
        player.automaticallyWaitsToMinimizeStalling = true

        playerStateTask = Task { [weak self] in
            guard let player = self?.player else { return }
            for await _ in player.publisher(for: \.timeControlStatus).values {
                guard let self else { return }
                self.syncPlaybackState()
            }
        }

        // Fires every interval while playing; pause and seek save explicitly.
        let interval = CMTime(seconds: Self.positionSaveInterval, preferredTimescale: 1)
        positionObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.savePosition() }
        }

        // No download is running yet, so leftovers from a quit mid-download can go.
        let cache = audioCache
        Task { [weak self] in
            let (bytes, keys) = await Self.sweep(cache)
            self?.audioCacheBytes = bytes
            self?.downloadedKeys = keys
        }
    }

    @concurrent private static func sweep(_ cache: AudioCache) async -> (Int64, Set<String>) {
        cache.sweep()
        cache.evict()
        return (cache.totalSize, Set(cache.usage().map(\.key)))
    }

    @concurrent private static func measure(_ cache: AudioCache) async -> (Int64, Set<String>) {
        (cache.totalSize, Set(cache.usage().map(\.key)))
    }

    // MARK: - Audio cache

    func refreshAudioCacheSize() {
        let cache = audioCache
        Task { [weak self] in
            let (bytes, keys) = await Self.measure(cache)
            guard let self, !self.isDemo else { return }
            self.audioCacheBytes = bytes
            self.downloadedKeys = keys
        }
    }

    /// Empties the audio cache. A track playing from it keeps playing: the open file outlives its directory entry.
    func clearAudioCache() {
        downloadTask?.cancel()
        downloadTask = nil
        downloadKey = nil
        audioCache.removeAll()
        audioCacheBytes = 0
        downloadedKeys = []
    }

    /// Downloads the loaded track into the audio cache once it has stayed loaded for `audioCacheDelay`.
    private func scheduleAudioDownload(_ track: Track, key: String) {
        if downloadKey == key, downloadTask != nil { return }   // already fetching this one (a reload or recovery)
        downloadTask?.cancel()
        downloadTask = nil
        downloadKey = nil
        guard track.isYouTube, !track.isExpired(margin: 15 * 60) else { return }
        downloadKey = key
        let cache = audioCache
        downloadTask = Task { [weak self] in
            defer {
                if self?.downloadKey == key {
                    self?.downloadTask = nil
                    self?.downloadKey = nil
                }
            }
            try? await Task.sleep(for: Self.audioCacheDelay)
            guard !Task.isCancelled, !cache.contains(key) else { return }
            do {
                try await AudioDownloader.download(track, key: key, into: cache)
                self?.refreshAudioCacheSize()
            } catch is CancellationError {
            } catch let error as URLError where error.code == .cancelled {
            } catch {
                self?.log.notice("audio cache download of \(key, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    // MARK: - Resume

    /// Remembers where the current track is, so opening it again picks up there.
    /// - Parameter seconds: a known position (a seek target), saved as is; nil uses the pending seek's
    ///   target, or else the player clock.
    func savePosition(at seconds: Double? = nil) {
        guard track != nil, let key = currentLink?.cacheKey else { return }
        if let position = seconds ?? pendingSeekTarget {
            settings.positions.record(position, duration: duration, forKey: key)
            return
        }
        // A replaced item reports time 0 until it is ready; with no item (idle unload) livePosition is the saved clock.
        if let item = player.currentItem, item.status != .readyToPlay { return }
        settings.positions.record(livePosition, duration: duration, forKey: key)
    }

    /// Seeks the player, keeping `target` as the position to save until this seek lands or a newer one replaces it.
    private func seekPlayer(to target: Double, toleranceAfter: CMTime) {
        seekCount += 1
        let id = seekCount
        pendingSeekTarget = target
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: toleranceAfter) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.seekCount == id else { return }   // a newer seek owns the target
                self.pendingSeekTarget = nil
            }
        }
    }

    // MARK: - Saved links

    /// The playing track as a plain video link, so a song heard in a Mix or playlist can be kept on its own.
    var savableTrack: (url: URL, title: String)? {
        guard let track else { return nil }
        let url = track.webpageURL ?? URL(string: "https://www.youtube.com/watch?v=\(track.id)")!
        return (url, track.title)
    }

    /// The pasted playlist or Mix, while one is loaded.
    var savableQueue: (url: URL, title: String)? {
        guard let url = upNext.sourceURL else { return nil }
        return (url, upNext.sourceTitle ?? (upNext.sourceIsMix ? "Mix" : "Playlist"))
    }

    var isMixLoaded: Bool { upNext.sourceURL != nil && upNext.sourceIsMix }

    var isTrackSaved: Bool { savableTrack.map { settings.saved.contains($0.url) } ?? false }
    var isQueueSaved: Bool { savableQueue.map { settings.saved.contains($0.url) } ?? false }

    func toggleSavedTrack() {
        guard let item = savableTrack else { return }
        settings.saved.toggle(url: item.url, title: item.title, kind: .video, duration: duration)
    }

    func toggleSavedQueue() {
        guard let item = savableQueue else { return }
        let count = upNext.played.count + (upNext.current == nil ? 0 : 1) + upNext.upcoming.count
        settings.saved.toggle(url: item.url, title: item.title, kind: isMixLoaded ? .mix : .playlist, count: count)
    }

    // MARK: - Opening links

    /// How a link joins what's playing: Play now replaces (a playlist or Mix replaces Up next), the others queue it.
    enum OpenMode { case playNow, playNext, addToEnd }

    /// What opening a link did, for the toast.
    enum OpenResult {
        /// A single video now plays; Up next is kept.
        case playing
        /// A playlist or Mix replaced Up next. `snapshot` undoes it.
        case replaced(count: Int, snapshot: UpNext)
        /// Videos were queued. `snapshot` undoes it.
        case queued(count: Int, title: String, playlist: String?, mode: OpenMode, snapshot: UpNext)
        case alreadyPlaying
        case failed
    }

    func open(_ text: String, mode: OpenMode = .playNow, completion: ((OpenResult) -> Void)? = nil) {
        guard let link = LinkParser.parse(text) else {
            fail("That doesn't look like a link.", suggestion: "Paste a YouTube video or playlist URL.")
            completion?(.failed)
            return
        }
        open(link, mode: mode, completion: completion)
    }

    func open(_ link: MediaLink, mode: OpenMode = .playNow, completion: ((OpenResult) -> Void)? = nil) {
        if mode != .playNow {
            enqueue(link, mode: mode, completion: completion)
            return
        }
        if !link.isPlaylist, link.kind.isMix == false, track != nil, currentLink?.cacheKey == link.cacheKey {
            completion?(.alreadyPlaying)
            return
        }
        resolveTask?.cancel()
        cancelBackgroundResolves(except: link.cacheKey)   // a warm-up/prefetch for anything else is wasted work now
        clearError()
        notice = nil
        pastedLink = link
        settings.lastLink = link.original.absoluteString
        log.notice("open \(link.original.absoluteString, privacy: .public)")

        if case .mix = link.kind {
            openPlaylist(link, limit: Self.mixLimit, completion: completion)
        } else if link.isPlaylist {
            openPlaylist(link, completion: completion)
        } else {
            // A single video plays now and Up next stays as it is (the old code dropped the whole queue here).
            playSingle(link, startAt: settings.positions.start(forKey: link.cacheKey, linkStart: link.startTime))
            completion?(.playing)
        }
    }

    /// Plays one video now: what was playing moves to Played and Up next is kept.
    private func playSingle(_ link: MediaLink, startAt: Double?) {
        resolveAndPlay(link, startAt: startAt) { q, track in
            q.playNow(QueueItem(videoID: link.videoID, url: link.resolvedURL, title: track.title, duration: track.duration))
        }
    }

    /// A Mix is endless; this many entries become the queue (about three hours, listed in a few seconds).
    static let mixLimit = 50

    private func openPlaylist(_ link: MediaLink, limit: Int = UpNext.limit, completion: ((OpenResult) -> Void)?) {
        let isMix = link.kind.isMix
        isResolving = true
        resolvingTitle = isMix ? "Loading mix…" : "Loading playlist…"
        resolveTask = Task { [weak self] in
            guard let self else { return }
            do {
                guard let client = await self.service.readyClient() else { self.handle(YTDLPFailure.notInstalled); return }
                let entries: [PlaylistEntry]
                do {
                    entries = try await client.playlistEntries(link, limit: limit)
                } catch where isMix && !Task.isCancelled {
                    // Listing a Mix can fail where the video itself plays fine; keep the music going. The video plays
                    // on its own and Up next is kept (it used to keep acting on the previous playlist).
                    self.notice = "Couldn't load the Mix, so just this video plays."
                    let video = MediaLink(original: link.original, kind: .video(id: link.videoID ?? ""))
                    self.playSingle(video, startAt: self.settings.positions.start(forKey: video.cacheKey, linkStart: link.startTime))
                    completion?(.playing)
                    return
                }
                guard !Task.isCancelled else { return }
                // YouTube has Mixes only for some videos (mostly music). Without one, yt-dlp hands back the video itself.
                if isMix, entries.count <= 1, let seed = link.videoID {
                    self.notice = "YouTube has no Mix for this video, so just this video plays."
                    let video = MediaLink(original: link.original, kind: .video(id: seed))
                    self.playSingle(video, startAt: self.settings.positions.start(forKey: video.cacheKey, linkStart: link.startTime))
                    completion?(.playing)
                    return
                }
                var startVideo = link.videoID   // a Mix starts from the video it was built on
                var startIndex: Int?
                if case .playlist(_, let v, let i) = link.kind {
                    startVideo = v
                    startIndex = i
                }
                var preview = UpNext()
                guard let first = preview.replace(with: entries, title: nil, sourceURL: link.resolvedURL, isMix: isMix,
                                                  startVideoID: startVideo, startIndex: startIndex) else {
                    throw YTDLPFailure.unavailable(message: "No playable videos in that playlist.")
                }
                let title = preview.sourceTitle ?? (isMix ? "Mix" : "Playlist")
                self.settings.recent.record(url: link.resolvedURL, title: title, kind: isMix ? .mix : .playlist,
                                            count: entries.filter(\.isAvailable).count)
                let snapshot = self.upNext
                let replacedCount = snapshot.upcoming.count
                self.resolveAndPlay(first.link, startAt: self.settings.positions.start(forKey: first.cacheKey, linkStart: link.startTime)) { q, _ in
                    q.replace(with: entries, title: nil, sourceURL: link.resolvedURL, isMix: isMix,
                              startVideoID: startVideo, startIndex: startIndex)
                }
                self.resolvingTitle = first.title
                completion?(.replaced(count: replacedCount, snapshot: snapshot))
            } catch {
                self.handle(error)
                completion?(.failed)
            }
        }
    }

    /// Play next / Add to end: lists or resolves the link without touching what's playing, then queues it.
    private func enqueue(_ link: MediaLink, mode: OpenMode, completion: ((OpenResult) -> Void)?) {
        if !link.isPlaylist, !link.kind.isMix, track != nil, currentLink?.cacheKey == link.cacheKey {
            completion?(.alreadyPlaying)
            return
        }
        Task { [weak self] in
            guard let self else { return }
            do {
                guard let client = await self.service.readyClient() else { throw YTDLPFailure.notInstalled }
                var items: [QueueItem]
                var playlist: String?
                if link.isPlaylist || link.kind.isMix {
                    let entries = try await client.playlistEntries(link, limit: link.kind.isMix ? Self.mixLimit : UpNext.limit)
                    playlist = entries.first?.playlistTitle ?? (link.kind.isMix ? "Mix" : "Playlist")
                    items = entries.filter(\.isAvailable).map { QueueItem($0, source: playlist) }
                } else {
                    let key = link.cacheKey
                    var track = self.settings.streamCache.track(forKey: key) ?? self.audioCache.entry(forKey: key)?.track
                    if track == nil {
                        let resolved = try await client.resolve(link)
                        self.settings.streamCache.store(resolved, forKey: key)   // playing it later is instant
                        track = resolved
                    }
                    guard let track else { throw YTDLPFailure.unavailable(message: "That video isn't available.") }
                    items = [QueueItem(videoID: link.videoID, url: link.resolvedURL, title: track.title, duration: track.duration)]
                }
                guard !items.isEmpty else { throw YTDLPFailure.unavailable(message: "No playable videos in that playlist.") }
                let snapshot = self.upNext
                let count = mode == .playNext ? self.upNext.insertNext(items) : self.upNext.append(items)
                self.prefetchNext()
                completion?(.queued(count: count, title: items[0].title, playlist: playlist, mode: mode, snapshot: snapshot))
            } catch {
                self.handle(error)
                completion?(.failed)
            }
        }
    }

    /// What is already known about a link, without yt-dlp: the caches, then Saved and Recent.
    func knownTitle(for link: MediaLink) -> (title: String, duration: Double?)? {
        let key = link.cacheKey
        if !link.isPlaylist, !link.kind.isMix,
           let track = settings.streamCache.track(forKey: key) ?? audioCache.entry(forKey: key)?.track {
            return (track.title, track.duration)
        }
        func matches(_ url: URL) -> Bool { LinkParser.parse(url.absoluteString)?.cacheKey == key }
        if let saved = settings.saved.items.first(where: { matches($0.url) }) { return (saved.title, saved.duration) }
        if let recent = settings.recent.items.first(where: { matches($0.url) }) { return (recent.title, recent.duration) }
        return nil
    }

    /// A video's title and length for the F6 prompt: from the caches, else one yt-dlp resolve (cached for Play).
    func lookup(_ link: MediaLink) async -> (title: String, duration: Double?)? {
        guard !link.isPlaylist, !link.kind.isMix else { return nil }
        let key = link.cacheKey
        if let track = settings.streamCache.track(forKey: key) ?? audioCache.entry(forKey: key)?.track {
            return (track.title, track.duration)
        }
        guard let client = await service.readyClient(), let track = try? await client.resolve(link) else { return nil }
        settings.streamCache.store(track, forKey: key)
        return (track.title, track.duration)
    }

    // MARK: - Editing Up next

    /// Plays one queue row now; the rows above it stay queued.
    func playQueued(_ id: QueueItem.ID) {
        guard let i = upNext.index(of: id) else { return }
        let item = upNext.upcoming[i]
        resolveAndPlay(item.link) { q, _ in q.jump(to: id) }
    }

    /// Plays a video from Saved or Recent now: what's playing moves to Played and Up next is kept.
    func playNow(_ item: QueueItem, startAt: Double? = nil) {
        resolveAndPlay(item.link, startAt: startAt) { q, track in
            var item = item
            item.title = track.title
            item.duration = track.duration
            q.playNow(item)
        }
    }

    /// Edits Up next and returns the state before, for Undo.
    @discardableResult
    func editQueue(_ change: (inout UpNext) -> Void) -> UpNext {
        let snapshot = upNext
        change(&upNext)
        if upNext.next?.id != snapshot.next?.id { prefetchNext() }
        return snapshot
    }

    /// Undo for an edit of Up next: puts the queue back; what's playing keeps going.
    func restoreQueue(from snapshot: UpNext) {
        upNext.restoreQueue(from: snapshot)
    }

    /// - Parameters:
    ///   - target: the Up next entry a Next is heading for, so pressing Next again goes one further.
    ///   - commit: how Up next changes once this link loads. Applied only then, so a failed or cancelled navigation
    ///     leaves the queue and the playing track untouched. Nil for a reload of the current item.
    private func resolveAndPlay(_ link: MediaLink, startAt: Double? = nil, target: QueueItem.ID? = nil,
                                commit: ((inout UpNext, Track) -> Void)? = nil) {
        resolveTask?.cancel()
        let key = link.cacheKey
        pendingCommit = commit
        pendingTargetID = target

        // Played before and kept on disk: no yt-dlp, no segment index, no network.
        if let hit = audioCache.entry(forKey: key) {
            log.notice("audio cache hit \(key, privacy: .public)")
            audioCache.touch(key)
            var track = hit.track
            track.expiresAt = nil   // the file does not expire, so Play must never re-resolve it
            load(track, source: StreamSource(asset: AVURLAsset(url: hit.file), loader: nil),
                 link: link, startAt: startAt, fromCache: true)
            return
        }

        let cached = settings.streamCache.track(forKey: key)
        if cached != nil { log.notice("cache hit \(key, privacy: .public)") }
        // A cache hit still waits on the network for its segment index, so it resolves visibly too: Cancel shows,
        // and Play with nothing loaded does not restart it.
        isResolving = true
        if let target, let i = upNext.index(of: target) {
            resolvingTitle = upNext.upcoming[i].title
        } else {
            resolvingTitle = cached?.title ?? upNext.current?.title ?? "Resolving…"
        }
        let inFlight = cached == nil ? backgroundResolves[key] : nil
        resolveTask = Task { [weak self] in
            guard let self else { return }
            do {
                var track = cached
                if let inFlight {
                    track = await inFlight.value   // a warm-up or prefetch is already fetching this one
                }
                if track == nil {
                    guard let client = await self.service.readyClient() else { self.handle(YTDLPFailure.notInstalled); return }
                    track = try await client.resolve(link)
                }
                guard var track, !Task.isCancelled else { return }
                if cached == nil { self.settings.streamCache.store(track, forKey: key) }
                // The current track keeps playing while the new one's stream is prepared (its segment index fetched).
                let source: StreamSource
                do {
                    guard let prepared = try await self.streamSource(for: track), !Task.isCancelled else { return }
                    source = prepared
                } catch let refused as StreamRefused {
                    // YouTube turned this URL away (a stale cache entry, or a fresh URL it just refused): get a new one, once.
                    guard !Task.isCancelled else { return }
                    self.log.notice("stream refused (HTTP \(refused.statusCode)); re-resolving")
                    self.settings.streamCache.remove(forKey: key)
                    guard let client = await self.service.readyClient() else { self.handle(YTDLPFailure.notInstalled); return }
                    track = try await client.resolve(link)
                    guard !Task.isCancelled else { return }
                    self.settings.streamCache.store(track, forKey: key)
                    guard let prepared = try await self.streamSource(for: track), !Task.isCancelled else { return }
                    source = prepared
                }
                self.load(track, source: source, link: link, startAt: startAt)
            } catch {
                self.handle(error)
            }
        }
    }

    /// What AVPlayer gets for `track`. A YouTube stream plays as HLS built from the file's segment index, so only what
    /// is about to play gets downloaded; without a usable index it goes through the chunked loader instead.
    /// - Returns: nil only if the task was cancelled meanwhile.
    /// - Throws: `StreamRefused` when YouTube refuses the stream URL before anything is loaded.
    private func streamSource(for track: Track) async throws -> StreamSource? {
        var options: [String: Any] = [:]
        if let userAgent = track.userAgent { options[AVURLAssetHTTPUserAgentKey] = userAgent }
        guard track.isYouTube else {
            return StreamSource(asset: AVURLAsset(url: track.streamURL, options: options), loader: nil)
        }
        if let loader = try await SegmentedStreamLoader.load(streamURL: track.streamURL, headers: track.httpHeaders) {
            // Only the playlist goes through the loader; AVFoundation fetches the segments from YouTube itself.
            let asset = AVURLAsset(url: loader.assetURL, options: options)
            asset.resourceLoader.setDelegate(loader, queue: loader.queue)
            return StreamSource(asset: asset, loader: loader)
        }
        guard !Task.isCancelled else { return nil }
        // YouTube throttles AVPlayer's open-ended range requests; a long mix would never start.
        let loader = ChunkedStreamLoader(streamURL: track.streamURL, headers: track.httpHeaders, fileExtension: track.streamExtension) { [weak self] loader, refused in
            let id = ObjectIdentifier(loader)
            Task { @MainActor in self?.streamRefused(refused, by: id) }
        }
        let asset = AVURLAsset(url: loader.assetURL)
        asset.resourceLoader.setDelegate(loader, queue: loader.queue)
        return StreamSource(asset: asset, loader: loader)
    }

    /// Resolves a pasted/clipboard link in the background so pressing Play afterwards is instant.
    /// Debounced, deduplicated by cache key, and invisible to the UI.
    func warm(_ text: String) {
        // Only complete YouTube video links: a partially typed URL must not spawn yt-dlp on every pause.
        guard let link = LinkParser.parse(text), link.videoID != nil, !link.isPlaylist else { return }
        let key = link.cacheKey
        guard key != track?.id else { return }
        // A link that just failed (a private video on the clipboard) is not retried on every panel open.
        if let failedAt = failedWarmKeys[key], Date().timeIntervalSince(failedAt) < 10 * 60 { return }
        backgroundResolve(link, delay: .milliseconds(700), isWarmUp: true)
    }

    /// One speculative yt-dlp at a time, never started beside a user resolve, cached on success.
    private func backgroundResolve(_ link: MediaLink, delay: Duration, isWarmUp: Bool) {
        let key = link.cacheKey
        guard backgroundResolves[key] == nil, backgroundResolves.isEmpty, !isResolving,
              !settings.streamCache.contains(key), let client = service.client else { return }
        backgroundGeneration += 1
        let generation = backgroundGeneration
        backgroundOwners[key] = generation
        backgroundResolves[key] = Task { [weak self] in
            defer {
                if self?.backgroundOwners[key] == generation {
                    self?.backgroundResolves[key] = nil
                    self?.backgroundOwners[key] = nil
                }
            }
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, self?.isResolving == false else { return nil }
            guard let track = try? await client.resolve(link), !Task.isCancelled else {
                if !Task.isCancelled, isWarmUp { self?.failedWarmKeys[key] = Date() }
                return nil
            }
            self?.settings.streamCache.store(track, forKey: key)
            self?.log.notice("\(isWarmUp ? "warmed" : "prefetched", privacy: .public) \(key, privacy: .public)")
            return track
        }
    }

    private func cancelBackgroundResolves(except keep: String? = nil) {
        for (key, task) in backgroundResolves where key != keep {
            task.cancel()
            backgroundResolves[key] = nil
            backgroundOwners[key] = nil
        }
    }

    private func load(_ track: Track, source: StreamSource, link: MediaLink, startAt: Double?, fromCache: Bool = false) {
        if let current = currentLink, current.cacheKey != link.cacheKey { savePosition() }
        // An explicit start (a recovery, an idle reload, or a link's `t=` with no saved position) wins; nil picks up the saved position.
        let startAt = startAt ?? settings.positions[link.cacheKey]?.seconds
        teardownItem()
        idleUnloadTask?.cancel()
        isIdleUnloaded = false
        let isNewTrack = lastLoadedKey != link.cacheKey
        if isNewTrack {
            recoveryAttempts = 0            // a genuinely new track gets a fresh recovery budget
            lastLoadedKey = link.cacheKey
        }
        currentLink = link
        playingCachedFile = fromCache
        consecutiveQueueSkips = 0
        if let commit = pendingCommit {
            commit(&upNext, track)
        } else if let current = upNext.current, current.cacheKey == link.cacheKey {
            upNext.update(current.id, title: track.title, duration: track.duration)
        }
        pendingCommit = nil
        pendingTargetID = nil
        self.track = track
        hasEnded = false
        isResolving = false
        resolvingTitle = nil
        currentTime = startAt ?? 0
        log.notice("loaded \(track.title, privacy: .public) [\(track.streamExtension ?? "?", privacy: .public) \(track.audioCodec ?? "?", privacy: .public)] duration \(track.duration ?? -1) start \(startAt ?? 0)")

        streamLoader = source.loader
        let item = AVPlayerItem(asset: source.asset)
        // Measured on an M1: the pitch algorithm makes no CPU difference at 2× (spectral 4.5% vs timeDomain
        // 4.4% of one core; decoding twice the samples dominates), so keep the higher-quality one.
        item.audioTimePitchAlgorithm = .spectral
        if source.loader is SegmentedStreamLoader {
            item.preferredForwardBufferDuration = SegmentedStreamLoader.forwardBufferDuration
        }
        if let d = track.duration, d > 0 {
            item.forwardPlaybackEndTime = CMTime(seconds: d, preferredTimescale: 600)
        }
        observe(item)
        player.replaceCurrentItem(with: item)
        if let startAt, startAt > 0 { seekPlayer(to: startAt, toleranceAfter: .positiveInfinity) }
        play()

        // Recent tracks every video that plays, so it can show progress and a finished mark per video.
        if isNewTrack { recordInRecent() }
        prefetchNext()
        if fromCache {
            if downloadKey != link.cacheKey { downloadTask?.cancel(); downloadTask = nil; downloadKey = nil }
        } else {
            scheduleAudioDownload(track, key: link.cacheKey)
        }
    }

    private func observe(_ item: AVPlayerItem) {
        itemStatusTask = Task { [weak self] in
            for await status in item.publisher(for: \.status).values {
                guard let self else { return }
                if status == .failed { self.itemFailed(item.error) }
            }
        }
        endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.trackEnded() }
        }
        observeChapters()
    }

    private func teardownItem() {
        itemStatusTask?.cancel()
        itemStatusTask = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        (streamLoader as? ChunkedStreamLoader)?.cancelAll()   // the segmented loader has nothing in flight
        streamLoader = nil
        pendingSeekTarget = nil
        if let chapterObserver { player.removeTimeObserver(chapterObserver) }
        chapterObserver = nil
    }

    /// Derives the published flags from the player. Called from KVO and from the periodic timer as a safety net.
    private func syncPlaybackState() {
        guard !isDemo else { return }
        let status = player.timeControlStatus
        let playing = status != .paused
        let buffering = status == .waitingToPlayAtSpecifiedRate
        if playing != isPlaying {
            isPlaying = playing
            log.notice("playback \(playing ? "playing" : "paused", privacy: .public) rate \(self.player.rate)")
            if playing {
                idleUnloadTask?.cancel()
                idleUnloadTask = nil
            } else if track != nil, !isIdleUnloaded {
                scheduleIdleUnload()
            }
        }
        if buffering != isBuffering { isBuffering = buffering }
    }

    /// KVO on `timeControlStatus` is the primary signal; this catches up shortly after our own transport
    /// calls in case a change is coalesced, without any periodic timer.
    private func scheduleStateSync() {
        stateSyncTask?.cancel()
        stateSyncTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            self?.syncPlaybackState()
        }
    }

    /// The scrubber needs a 2 Hz clock only while the panel is visible. Hidden (the usual state for a
    /// background player) nothing ticks and nothing re-renders.
    func setProgressTracking(_ enabled: Bool) {
        guard enabled != progressTracking else { return }
        progressTracking = enabled
        if enabled {
            currentTime = livePosition
            timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 2), queue: .main) { [weak self] time in
                MainActor.assumeIsolated {
                    guard let self, time.isNumeric else { return }
                    self.currentTime = time.seconds
                    self.syncPlaybackState()
                }
            }
        } else if let timeObserver {
            player.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
    }

    private func scheduleIdleUnload() {
        idleUnloadTask?.cancel()
        let delay = max(30, settings.idleUnloadSeconds)
        idleUnloadTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self, !self.isPlaying, self.track != nil, !self.isIdleUnloaded else { return }
            self.unloadForIdle()
        }
    }

    /// Releases the AVPlayerItem after a long pause: no buffering, no media pipeline, back to idle memory.
    /// Track, queue and position stay; Play rebuilds it (instant on a cache hit).
    private func unloadForIdle() {
        savePosition()
        let position = livePosition
        teardownItem()
        player.replaceCurrentItem(with: nil)
        currentTime = position
        isIdleUnloaded = true
        log.notice("idle: released the player item after a long pause at \(Int(position))s")
    }

    // MARK: - Chapters

    /// ⏮ and ⏭ step through chapters first when the video has them (and are labelled "chapter").
    var skipsByChapter: Bool { track?.chapters.isEmpty == false }

    /// Whether Next goes anywhere: the next chapter, else the next entry in Up next.
    var hasNext: Bool { (skipsByChapter && chapter != track?.chapters.last) || !upNext.isEmpty }

    /// Whether Previous has an earlier chapter or played video to go to (it can always restart the current one).
    var hasPrevious: Bool { skipsByChapter || !upNext.played.isEmpty }

    /// Where playback is heading: an in-flight seek's target (so a second Next goes one further), else the player clock.
    private var targetPosition: Double { pendingSeekTarget ?? livePosition }

    /// Follows the item being loaded from where `load` put `currentTime`. A boundary observer at each chapter start
    /// keeps `chapter` current during playback, so nothing ticks in between; seeks update it themselves.
    private func observeChapters() {
        updateChapter(at: currentTime)
        let starts = track?.chapters.map(\.start).filter { $0 > 0 } ?? []
        guard !starts.isEmpty else { return }
        let times = starts.map { NSValue(time: CMTime(seconds: $0, preferredTimescale: 600)) }
        chapterObserver = player.addBoundaryTimeObserver(forTimes: times, queue: .main) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.updateChapter(at: self.livePosition)
            }
        }
    }

    private func updateChapter(at seconds: Double) {
        let current = track?.chapter(at: seconds)
        if current != chapter { chapter = current }
    }

    // MARK: - Transport

    func play() {
        guard let track else {
            // Nothing loaded: resume the saved current item (a relaunch), else replay the last link, unless a
            // resolve is already in flight (a media-key Play during the first resolve must not re-spawn yt-dlp).
            guard !isResolving else { return }
            if let current = upNext.current {
                resolveAndPlay(current.link)
            } else if let last = settings.lastLink {
                open(last)
            }
            return
        }
        if isIdleUnloaded, let link = currentLink {
            isIdleUnloaded = false
            if hasEnded { hasEnded = false; currentTime = 0 }
            resolveAndPlay(link, startAt: currentTime)   // cache hit → instant; expired → re-resolve
            return
        }
        if track.isExpired(), let link = currentLink {
            guard recoveryAttempts < Self.maxRecoveries else {
                fail("The stream expired and could not be refreshed.", suggestion: "Paste the link again.")
                return
            }
            recoveryAttempts += 1
            log.notice("stream expired; re-resolving")
            settings.streamCache.remove(forKey: link.cacheKey)
            resolveAndPlay(link, startAt: livePosition)
            return
        }
        if hasEnded {
            hasEnded = false
            currentTime = 0
            recordInRecent()
            if replayFromAudioCache() { return }
            updateChapter(at: 0)
            player.seek(to: .zero)
        }
        player.defaultRate = Float(speed.rawValue)
        player.play()
        scheduleStateSync()
    }

    func pause() {
        player.pause()
        savePosition()
        scheduleStateSync()
    }

    func togglePlayPause() {
        if isPlaying { pause() } else { play() }
    }

    func setSpeed(_ newSpeed: PlaybackSpeed) {
        speed = newSpeed
        settings.speed = newSpeed
        player.defaultRate = Float(newSpeed.rawValue)
        if isPlaying { player.rate = Float(newSpeed.rawValue) }
        scheduleStateSync()
    }

    func cycleSpeed() {
        setSpeed(speed.next)
    }

    func cycleSpeedDown() {
        setSpeed(speed.previous)
    }

    func setRepeatMode(_ mode: RepeatMode) {
        repeatMode = mode
        settings.repeatMode = mode
    }

    func cycleRepeatMode() {
        setRepeatMode(repeatMode.next)
    }

    func setVolume(_ value: Float) {
        let clamped = max(0, min(1, value))
        if isMuted, clamped > 0 { isMuted = false }
        volume = clamped
    }

    func toggleMute() {
        isMuted.toggle()
        player.volume = isMuted ? 0 : volume
    }

    func seek(to seconds: Double) {
        guard track != nil else { return }
        let upper = (duration ?? .infinity) - 0.25
        let target = max(0, min(seconds, upper))
        currentTime = target
        updateChapter(at: target)
        savePosition(at: target)
        hasEnded = false
        if !isIdleUnloaded { seekPlayer(to: target, toleranceAfter: .zero) }
        seekGeneration += 1
    }

    func skip(by delta: Double) {
        seek(to: livePosition + delta)
    }

    /// Chapters first: the next chapter, and after the last one the next video in Up next.
    func next() {
        if pendingTargetID == nil, let start = track?.nextChapterStart(after: targetPosition) {
            seek(to: start)
            return
        }
        // Step from the entry we are heading for, so Next after a failed or still-resolving entry moves on.
        let from = pendingTargetID.flatMap { upNext.index(of: $0) }.map { $0 + 1 } ?? 0
        guard upNext.upcoming.indices.contains(from) else { return }
        playFromQueue(upNext.upcoming[from])
    }

    /// Back a chapter (or to the start of this one, more than 3 s in). At the very start, back into Played.
    func previous() {
        if pendingTargetID != nil { cancelResolving() }
        let position = targetPosition
        if let start = track?.previousChapterStart(from: position), start > 0 || position > 3 {
            seek(to: start)
            return
        }
        guard position <= 3, let back = upNext.played.last else {
            seek(to: 0)
            return
        }
        resolveAndPlay(back.link, startAt: 0) { q, _ in q.goBack() }
    }

    /// Plays `item`, the first entry of Up next or one further along after repeated Next presses.
    private func playFromQueue(_ item: QueueItem) {
        let id = item.id
        resolveAndPlay(item.link, target: id) { q, _ in q.advance(through: id) }
    }

    func cancelResolving() {
        resolveTask?.cancel()
        resolveTask = nil
        pendingCommit = nil
        pendingTargetID = nil
        isResolving = false
        resolvingTitle = nil
    }

    func stop() {
        savePosition()
        resolveTask?.cancel()
        cancelBackgroundResolves()
        pendingCommit = nil
        pendingTargetID = nil
        idleUnloadTask?.cancel()
        isIdleUnloaded = false
        failedWarmKeys.removeAll()
        downloadTask?.cancel()
        downloadTask = nil
        downloadKey = nil
        playingCachedFile = false
        teardownItem()
        player.pause()
        player.replaceCurrentItem(with: nil)
        track = nil
        chapter = nil
        currentLink = nil   // Up next is kept: it is persisted and comes back on relaunch
        isResolving = false
        resolvingTitle = nil
        hasEnded = false
        currentTime = 0
    }

    // MARK: - Demo harness

    /// Set once fixtures are loaded: nothing real plays until relaunch.
    @ObservationIgnored private(set) var isDemo = false

    /// Shows fixture data exactly as the design screens draw it (see `DemoFixtures`). No audio plays.
    func loadDemo(track: Track?, upNext: UpNext, position: Double, playing: Bool, downloaded: Set<String>, cacheBytes: Int64) {
        stop()
        isDemo = true
        self.track = track
        self.upNext = upNext
        currentLink = track.map { MediaLink(original: $0.webpageURL ?? $0.streamURL, kind: .video(id: $0.id)) }
        currentTime = position
        updateChapter(at: position)
        isPlaying = playing
        downloadedKeys = downloaded
        audioCacheBytes = cacheBytes
        clearError()
        notice = nil
    }

    /// The demo's "video failed to load" state for the F7 banner.
    func showDemoFailure() {
        fail("Couldn't load this video", suggestion: nil)
    }

    func shutdown() {
        stop()
        playerStateTask?.cancel()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        if let positionObserver { player.removeTimeObserver(positionObserver) }
        positionObserver = nil
    }

    func clearError() {
        errorMessage = nil
        errorSuggestion = nil
    }

    func clearNotice() {
        notice = nil
    }

    // MARK: - Events

    private func trackEnded() {
        log.notice("ended \(self.track?.title ?? "", privacy: .public) repeat=\(self.repeatMode.rawValue, privacy: .public)")
        if let link = currentLink {
            settings.positions.forget(link.cacheKey)   // finished: next time starts over
            settings.recent.markFinished(link.resolvedURL)
        }
        if repeatMode == .one {
            restartCurrentTrack()
        } else if let next = upNext.next {
            playFromQueue(next)
        } else if repeatMode == .all, let first = upNext.played.first {
            resolveAndPlay(first.link, startAt: 0) { q, _ in q.wrapAround() }
        } else if repeatMode == .all {
            restartCurrentTrack()
        } else {
            // The last item finished: back to Nothing playing (F5). It moves to Played, so ⏮ can still go back.
            upNext.finish()
            stop()
        }
    }

    /// Puts the loaded video at the top of Recent (and clears its finished mark).
    private func recordInRecent() {
        guard let track, let link = currentLink else { return }
        settings.recent.record(url: link.resolvedURL, title: track.title, kind: .video, duration: track.duration)
    }

    private func restartCurrentTrack() {
        recordInRecent()
        hasEnded = false
        currentTime = 0
        if replayFromAudioCache() { return }
        updateChapter(at: 0)
        player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
        player.defaultRate = Float(speed.rawValue)
        player.play()
        seekGeneration += 1
        scheduleStateSync()
    }

    /// A streamed track that has since been downloaded starts over from the file rather than re-streaming
    /// (repeat-one, or Play after it ended). False when it is not cached yet, or already plays from the cache.
    private func replayFromAudioCache() -> Bool {
        guard !playingCachedFile, let link = currentLink, audioCache.contains(link.cacheKey) else { return false }
        resolveAndPlay(link, startAt: 0)
        return true
    }

    /// The chunked loader's stream URL was refused mid-load. AVFoundation would wait on it forever, so treat it as
    /// a failed item, unless that loader has since been replaced.
    private func streamRefused(_ refused: StreamRefused, by loader: ObjectIdentifier) {
        guard let current = streamLoader, ObjectIdentifier(current) == loader else { return }
        itemFailed(refused)
    }

    private func itemFailed(_ error: Error?) {
        // A recovery (or another link) is already resolving: the same failure reported twice
        // (refused fetch, then item status) must not spend the recovery budget twice.
        guard !isResolving else { return }
        let description = error?.localizedDescription ?? "unknown error"
        log.error("item failed: \(description, privacy: .public)")
        if playingCachedFile, let link = currentLink {
            // A cached file that will not play is dropped, recovery or not; otherwise every later play loads it again.
            audioCache.remove(forKey: link.cacheKey)
            playingCachedFile = false
            refreshAudioCacheSize()
        }
        if recoveryAttempts < Self.maxRecoveries, let link = currentLink {
            recoveryAttempts += 1
            settings.streamCache.remove(forKey: link.cacheKey)
            let position = livePosition
            resolveAndPlay(link, startAt: position > 1 ? position : nil)
        } else {
            fail("Playback failed: \(description)", suggestion: "Try again. If it keeps failing: brew upgrade yt-dlp")
        }
    }

    private func prefetchNext() {
        guard let nextEntry = upNext.next else { return }
        backgroundResolve(nextEntry.link, delay: .seconds(2), isWarmUp: false)
    }

    private func handle(_ error: Error) {
        // A resolve cancelled by a newer one (Next pressed twice, a new link pasted) must not touch the
        // state the newer one just set. cancelResolving() resets the flags itself for the explicit case.
        if error is CancellationError || (error as? YTDLPFailure) == .cancelled { return }
        isResolving = false
        resolvingTitle = nil
        // A removed/private video mid-playlist must not stop the playlist: skip forward (bounded).
        if let failed = pendingTargetID, case .unavailable? = error as? YTDLPFailure,
           consecutiveQueueSkips < Self.maxConsecutiveSkips, let i = upNext.index(of: failed) {
            consecutiveQueueSkips += 1
            upNext.remove(failed)
            pendingCommit = nil
            pendingTargetID = nil
            if upNext.upcoming.indices.contains(i) {
                notice = "Skipped an unavailable video in up next."
                log.notice("skipping unavailable queue entry")
                playFromQueue(upNext.upcoming[i])
                return
            }
        }
        pendingCommit = nil
        pendingTargetID = nil
        if case .unsupported? = error as? YTDLPFailure, let link = pastedLink,
           settings.lastLink == link.original.absoluteString {
            settings.lastLink = nil   // don't offer to reopen a link that can never play
        }
        if let failure = error as? YTDLPFailure {
            fail(failure.message, suggestion: failure.suggestion)
        } else {
            fail(error.localizedDescription, suggestion: nil)
        }
    }

    private func fail(_ message: String, suggestion: String?) {
        errorMessage = message
        errorSuggestion = suggestion
        log.error("\(message, privacy: .public)")
    }
}

/// An asset for AVPlayer and the resource loader feeding it, if any.
private struct StreamSource {
    let asset: AVURLAsset
    let loader: (any AVAssetResourceLoaderDelegate)?
}
