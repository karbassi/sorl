import Foundation

public struct SavedLink: Codable, Equatable, Sendable, Identifiable {
    public var id: String { url.absoluteString }
    public let url: URL
    public var title: String
    public var savedAt: Date
    /// Nil for entries saved before kinds were stored; `resolvedKind` infers it from the URL.
    public var kind: LinkKind?
    public var duration: Double?
    /// Videos in a playlist or Mix.
    public var count: Int?

    public init(url: URL, title: String, savedAt: Date, kind: LinkKind? = nil, duration: Double? = nil, count: Int? = nil) {
        self.url = url
        self.title = title
        self.savedAt = savedAt
        self.kind = kind
        self.duration = duration
        self.count = count
    }

    public var resolvedKind: LinkKind { kind ?? .infer(from: url) }
    public var trailingText: String? { LibraryTrailing.text(kind: resolvedKind, duration: duration, count: count) }
}

/// Links the user chose to keep, newest first. Unlike recents these never expire; only the user removes them.
public struct SavedLinksStore: Equatable, Sendable {
    public static let limit = 500
    public private(set) var items: [SavedLink]

    public init(items: [SavedLink] = []) {
        self.items = Array(items.prefix(Self.limit))
    }

    public init(decoding data: Data) {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.init(items: (try? decoder.decode([SavedLink].self, from: data)) ?? [])
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(items)
    }

    public func contains(_ url: URL) -> Bool {
        items.contains { $0.url == url }
    }

    /// Saves (or re-saves, with a fresh title) a link, stamped `date` cut to whole seconds and placed in `savedAt`
    /// order: a plain save lands at the top, while an Undo with the original date lands where other Macs put it.
    /// On a same-second tie the newer save goes first.
    public mutating func save(url: URL, title: String, kind: LinkKind? = nil, duration: Double? = nil, count: Int? = nil,
                              date: Date = Date()) {
        let savedAt = SyncDate.trunc(date)
        items.removeAll { $0.url == url }
        let link = SavedLink(url: url, title: title, savedAt: savedAt, kind: kind, duration: duration, count: count)
        items.insert(link, at: items.firstIndex { $0.savedAt <= savedAt } ?? items.endIndex)
        if items.count > Self.limit { items.removeLast(items.count - Self.limit) }
    }

    public mutating func remove(_ url: URL) {
        items.removeAll { $0.url == url }
    }

    /// Saves the link when it is not saved yet, removes it otherwise. Returns whether it is saved afterwards.
    @discardableResult
    public mutating func toggle(url: URL, title: String, kind: LinkKind? = nil, duration: Double? = nil, count: Int? = nil,
                                date: Date = Date()) -> Bool {
        if contains(url) {
            remove(url)
            return false
        }
        save(url: url, title: title, kind: kind, duration: duration, count: count, date: date)
        return true
    }

    // MARK: Sync

    /// What changed between two snapshots of the store, for upload. An upsert is a link that is new in `new` or whose
    /// title, kind, duration, count or (whole-second) `savedAt` differs. A delete is a link missing from `new`, except
    /// cap evictions: when `new` is full, a missing link no newer than its oldest item fell off the end, and other
    /// Macs may still keep it.
    public static func changes(from old: Self, to new: Self) -> (upserts: [SavedLink], deletes: [URL]) {
        let oldByURL = Dictionary(old.items.map { ($0.url, $0) }, uniquingKeysWith: { first, _ in first })
        let upserts = new.items.filter { link in
            guard let before = oldByURL[link.url] else { return true }
            return !sameContent(before, link)
        }
        let newURLs = Set(new.items.map(\.url))
        let full = new.items.count == Self.limit
        let oldest = new.items.map { SyncDate.trunc($0.savedAt) }.min() ?? .distantPast
        let deletes = old.items
            .filter { !newURLs.contains($0.url) }
            .filter { !(full && SyncDate.trunc($0.savedAt) <= oldest) }
            .map(\.url)
        return (upserts: upserts, deletes: deletes)
    }

    private static func sameContent(_ a: SavedLink, _ b: SavedLink) -> Bool {
        a.title == b.title && a.kind == b.kind && a.duration == b.duration && a.count == b.count
            && SyncDate.trunc(a.savedAt) == SyncDate.trunc(b.savedAt)
    }

    /// Record name to URL for every local link, built once per sync event so deletes need no hashing per lookup.
    public func recordNameMap() -> [String: URL] {
        Dictionary(items.map { (SyncRecords.savedRecordName(for: $0.url), $0.url) }, uniquingKeysWith: { first, _ in first })
    }

    /// Applies a link fetched from iCloud. Returns false when the local copy is strictly newer (whole seconds), so the
    /// caller re-queues a save; otherwise the link replaces or joins the list in `savedAt` order, then the cap applies.
    /// With a pending local delete the store is left alone and true is returned: the removal wins on the server.
    @discardableResult
    public mutating func applyRemote(_ link: SavedLink, hasPendingDelete: Bool = false) -> Bool {
        if hasPendingDelete { return true }
        let savedAt = SyncDate.trunc(link.savedAt)
        if let local = items.first(where: { $0.url == link.url }), SyncDate.trunc(local.savedAt) > savedAt { return false }
        items.removeAll { $0.url == link.url }
        var incoming = link
        incoming.savedAt = savedAt
        items.insert(incoming, at: items.firstIndex { $0.savedAt <= savedAt } ?? items.endIndex)
        if items.count > Self.limit { items.removeLast(items.count - Self.limit) }
        return true
    }

    /// Removes the link a deleted record named, via `recordNameMap()`. Unknown names are ignored, and so is the delete
    /// when a local save of that link is still pending, so the re-save wins.
    public mutating func applyRemoteDelete(recordName: String, map: [String: URL], hasPendingSave: Bool = false) {
        guard !hasPendingSave, let url = map[recordName] else { return }
        remove(url)
    }
}
