import Foundation

/// One entry in Up next. Each entry has its own `id`, so the same video can be queued twice.
public struct QueueItem: Codable, Equatable, Hashable, Sendable, Identifiable {
    public let id: UUID
    /// The YouTube video id; nil for other sites.
    public var videoID: String?
    public var url: URL
    public var title: String
    public var duration: Double?
    /// The playlist or Mix this entry came from, for the section header.
    public var source: String?

    public init(id: UUID = UUID(), videoID: String?, url: URL, title: String, duration: Double? = nil, source: String? = nil) {
        self.id = id
        self.videoID = videoID
        self.url = url
        self.title = title
        self.duration = duration
        self.source = source
    }

    public init(_ entry: PlaylistEntry, source: String? = nil) {
        self.init(videoID: entry.id, url: entry.url, title: entry.title, duration: entry.duration,
                  source: source ?? entry.playlistTitle)
    }

    /// The same video under a new id: what Play next / Add to end queue, so the copy is independent.
    public func copy() -> QueueItem {
        QueueItem(videoID: videoID, url: url, title: title, duration: duration, source: source)
    }

    public var link: MediaLink {
        if let videoID { return MediaLink(original: url, kind: .video(id: videoID)) }
        return LinkParser.parse(url.absoluteString) ?? MediaLink(original: url, kind: .other)
    }

    /// The stream/position/audio cache key, the same as `MediaLink.cacheKey`.
    public var cacheKey: String { link.cacheKey }
}

/// What's playing, what's coming and what has played. An editable queue that survives relaunch.
///
/// - `current` is the item loaded in the player (nil before anything plays).
/// - `upcoming` is Up next, in play order. A pasted playlist or Mix is copied into it.
/// - `played` is the history behind the current item, newest last, shown collapsed as "Played (n)".
public struct UpNext: Codable, Equatable, Sendable {
    /// Up next holds at most this many entries; a longer playlist is cut.
    public static let limit = 500
    /// Played keeps this many items.
    public static let playedLimit = 50

    public private(set) var current: QueueItem?
    public private(set) var upcoming: [QueueItem]
    public private(set) var played: [QueueItem]
    /// The playlist or Mix the queue was filled from ("SOUND ISLAND sets"), and its canonical URL for Save playlist.
    public private(set) var sourceTitle: String?
    public private(set) var sourceURL: URL?
    public private(set) var sourceIsMix: Bool

    public init(current: QueueItem? = nil, upcoming: [QueueItem] = [], played: [QueueItem] = [],
                sourceTitle: String? = nil, sourceURL: URL? = nil, sourceIsMix: Bool = false) {
        self.current = current
        self.upcoming = Array(upcoming.prefix(Self.limit))
        self.played = Array(played.suffix(Self.playedLimit))
        self.sourceTitle = sourceTitle
        self.sourceURL = sourceURL
        self.sourceIsMix = sourceIsMix
    }

    public init(decoding data: Data) {
        self = (try? JSONDecoder().decode(UpNext.self, from: data)) ?? UpNext()
    }

    public func encoded() throws -> Data { try JSONEncoder().encode(self) }

    public var isEmpty: Bool { upcoming.isEmpty }
    public var next: QueueItem? { upcoming.first }

    /// The section header's source: the playlist name while any queued entry still comes from it (G3 keeps
    /// "From SOUND ISLAND sets" after a link is added to the end).
    public var headerSource: String? {
        guard let sourceTitle, upcoming.contains(where: { $0.source == sourceTitle }) else { return nil }
        return sourceTitle
    }

    public func index(of id: QueueItem.ID) -> Int? { upcoming.firstIndex { $0.id == id } }

    // MARK: - Offsets

    /// The whole queue by offset from what's playing, as the system Now Playing queue counts it: 0 is the current item,
    /// -1 the newest played, 1 the first of Up next. Nil off either end, or with nothing current.
    public func item(atOffset offset: Int) -> QueueItem? {
        guard let current else { return nil }
        if offset == 0 { return current }
        if offset > 0 { return offset <= upcoming.count ? upcoming[offset - 1] : nil }
        return -offset <= played.count ? played[played.count + offset] : nil
    }

    /// The offsets `from...to` that exist, in order, and where the current item sits among them (nil if outside).
    public func items(fromOffset from: Int, toOffset to: Int) -> (items: [QueueItem], currentIndex: Int?) {
        guard current != nil, from <= to else { return ([], nil) }
        let lower = max(from, -played.count), upper = min(to, upcoming.count)
        guard lower <= upper else { return ([], nil) }
        let items = (lower...upper).compactMap { item(atOffset: $0) }
        return (items, (lower...upper).contains(0) ? -lower : nil)
    }

    /// The current item's place in the whole queue, as Now Playing's queue index and count: nil with nothing queued or
    /// played. The index is the current item's offset counted from the oldest played one, matching `item(atOffset:)`.
    public var nowPlayingPosition: (index: Int, count: Int)? {
        guard !upcoming.isEmpty || !played.isEmpty else { return nil }
        return (played.count, played.count + 1 + upcoming.count)
    }

    /// Finds an item anywhere in the queue: current, Up next or Played.
    public func item(withID id: QueueItem.ID) -> QueueItem? {
        if current?.id == id { return current }
        return upcoming.first { $0.id == id } ?? played.first { $0.id == id }
    }

    // MARK: - Playing

    /// `item` becomes the current one; what was playing moves to Played. Up next is untouched.
    /// Used for a single video played now (F6, a Saved or Recent row) and for the Mix fallback.
    public mutating func playNow(_ item: QueueItem) {
        retireCurrent()
        current = item
    }

    /// Plays the first entry of Up next. Returns it, or nil when nothing is queued.
    @discardableResult
    public mutating func advance() -> QueueItem? {
        guard !upcoming.isEmpty else { return nil }
        retireCurrent()
        current = upcoming.removeFirst()
        return current
    }

    /// Next, possibly pressed several times while resolving: plays `id`, and the rows before it move to Played.
    @discardableResult
    public mutating func advance(through id: QueueItem.ID) -> QueueItem? {
        guard let i = index(of: id) else { return nil }
        retireCurrent()
        played.append(contentsOf: upcoming[..<i])
        upcoming.removeFirst(i)
        current = upcoming.removeFirst()
        trim()
        return current
    }

    /// Plays one queue row; the rows above it stay queued.
    @discardableResult
    public mutating func jump(to id: QueueItem.ID) -> QueueItem? {
        guard let i = index(of: id) else { return nil }
        retireCurrent()
        current = upcoming.remove(at: i)
        return current
    }

    /// Steps back into Played: the newest played item becomes current and the current one goes back to the front of
    /// Up next. Returns the item now current, or nil with nothing played.
    @discardableResult
    public mutating func goBack() -> QueueItem? {
        guard let previous = played.popLast() else { return nil }
        if let current { upcoming.insert(current, at: 0) }
        current = previous
        trim()
        return current
    }

    /// Repeat all at the end of the queue: Played and the current item queue up again, in order, and the first plays.
    @discardableResult
    public mutating func wrapAround() -> QueueItem? {
        var all = played
        if let current { all.append(current) }
        guard !all.isEmpty else { return nil }
        played = []
        current = nil
        upcoming = Array((all + upcoming).prefix(Self.limit))
        return advance()
    }

    /// Ends playback of the current item: it moves to Played, and nothing is current (F5).
    public mutating func finish() {
        retireCurrent()
        current = nil
    }

    // MARK: - Editing

    /// Play now with a playlist or Mix: its entries replace Up next and the start entry plays.
    /// The entries before the start entry are left out. Returns the start entry, or nil if none is playable.
    @discardableResult
    public mutating func replace(with entries: [PlaylistEntry], title: String?, sourceURL: URL?, isMix: Bool,
                                 startVideoID: String? = nil, startIndex: Int? = nil) -> QueueItem? {
        let playable = entries.filter(\.isAvailable)
        let title = title ?? entries.first?.playlistTitle
        guard !playable.isEmpty else { return nil }
        let start = Self.startPosition(in: entries, playable: playable, startVideoID: startVideoID, startIndex: startIndex)
        let items = playable[start...].map { QueueItem($0, source: title) }
        retireCurrent()
        current = items.first
        upcoming = Array(items.dropFirst().prefix(Self.limit))
        sourceTitle = title
        self.sourceURL = sourceURL
        sourceIsMix = isMix
        return current
    }

    /// Adds to the end of Up next. Returns how many were added (fewer than given once the queue is full).
    @discardableResult
    public mutating func append(_ items: [QueueItem]) -> Int {
        let room = max(0, Self.limit - upcoming.count)
        let added = Array(items.prefix(room))
        upcoming.append(contentsOf: added)
        return added.count
    }

    /// Adds to the front of Up next, keeping the given order (several Play next items play in the order added).
    @discardableResult
    public mutating func insertNext(_ items: [QueueItem]) -> Int {
        let room = max(0, Self.limit - upcoming.count)
        let added = Array(items.prefix(room))
        upcoming.insert(contentsOf: added, at: 0)
        return added.count
    }

    /// Removes one queue row. Returns it and where it was.
    @discardableResult
    public mutating func remove(_ id: QueueItem.ID) -> (item: QueueItem, index: Int)? {
        guard let i = index(of: id) else { return nil }
        return (upcoming.remove(at: i), i)
    }

    /// Moves one queue row to `destination` (0-based, in the list without the row). Returns the new index.
    @discardableResult
    public mutating func move(_ id: QueueItem.ID, to destination: Int) -> Int? {
        guard let i = index(of: id) else { return nil }
        let item = upcoming.remove(at: i)
        let target = max(0, min(destination, upcoming.count))
        upcoming.insert(item, at: target)
        return target
    }

    /// Option-↑ / Option-↓: one step. Returns the new index, or nil at the edge.
    @discardableResult
    public mutating func move(_ id: QueueItem.ID, by delta: Int) -> Int? {
        guard let i = index(of: id) else { return nil }
        let target = i + delta
        guard upcoming.indices.contains(target) else { return nil }
        return move(id, to: target)
    }

    /// Empties Up next. What's playing keeps going. Returns how many were removed.
    @discardableResult
    public mutating func clear() -> Int {
        let n = upcoming.count
        upcoming.removeAll()
        return n
    }

    /// Undo for Clear, Remove, Move and Replace: puts back Up next and its source as they were in `snapshot`.
    /// What's playing and Played stay as they are now.
    public mutating func restoreQueue(from snapshot: UpNext) {
        upcoming = snapshot.upcoming
        sourceTitle = snapshot.sourceTitle
        sourceURL = snapshot.sourceURL
        sourceIsMix = snapshot.sourceIsMix
    }

    /// Updates an entry's metadata once it is known (a title or duration resolved later), wherever it is.
    public mutating func update(_ id: QueueItem.ID, title: String? = nil, duration: Double? = nil) {
        func apply(_ item: inout QueueItem) {
            if let title { item.title = title }
            if let duration { item.duration = duration }
        }
        if current?.id == id, var c = current { apply(&c); current = c }
        if let i = upcoming.firstIndex(where: { $0.id == id }) { apply(&upcoming[i]) }
        if let i = played.firstIndex(where: { $0.id == id }) { apply(&played[i]) }
    }

    // MARK: - Helpers

    private mutating func retireCurrent() {
        if let current { played.append(current) }
        trim()
    }

    private mutating func trim() {
        if played.count > Self.playedLimit { played.removeFirst(played.count - Self.playedLimit) }
    }

    /// Where a pasted playlist starts: its `v=` when present, else its 1-based `index=` (counted in the full playlist,
    /// private and deleted entries included), else the top.
    static func startPosition(in entries: [PlaylistEntry], playable: [PlaylistEntry], startVideoID: String?, startIndex: Int?) -> Int {
        if let startVideoID, let i = playable.firstIndex(where: { $0.id == startVideoID }) { return i }
        if let startIndex, startIndex >= 1, startIndex <= entries.count {
            let playableBefore = entries[..<(startIndex - 1)].filter(\.isAvailable).count
            return min(playableBefore, playable.count - 1)
        }
        return 0
    }
}
