import Foundation

public struct RecentLink: Codable, Equatable, Sendable, Identifiable {
    public var id: String { url.absoluteString }
    public let url: URL
    public var title: String
    public var lastPlayed: Date
    /// Nil for entries recorded before kinds were stored; `resolvedKind` infers it from the URL.
    public var kind: LinkKind?
    public var duration: Double?
    /// Videos in a playlist or Mix.
    public var count: Int?
    /// Played to the end: the row shows a full gray bar and clicking it starts over.
    public var finished: Bool

    public init(url: URL, title: String, lastPlayed: Date, kind: LinkKind? = nil, duration: Double? = nil, count: Int? = nil,
                finished: Bool = false) {
        self.url = url
        self.title = title
        self.lastPlayed = lastPlayed
        self.kind = kind
        self.duration = duration
        self.count = count
        self.finished = finished
    }

    enum CodingKeys: String, CodingKey { case url, title, lastPlayed, kind, duration, count, finished }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        url = try c.decode(URL.self, forKey: .url)
        title = try c.decode(String.self, forKey: .title)
        lastPlayed = try c.decode(Date.self, forKey: .lastPlayed)
        kind = try c.decodeIfPresent(LinkKind.self, forKey: .kind)
        duration = try c.decodeIfPresent(Double.self, forKey: .duration)
        count = try c.decodeIfPresent(Int.self, forKey: .count)
        finished = try c.decodeIfPresent(Bool.self, forKey: .finished) ?? false
    }

    public var resolvedKind: LinkKind { kind ?? .infer(from: url) }
    public var trailingText: String? { LibraryTrailing.text(kind: resolvedKind, duration: duration, count: count) }
}

/// Most-recent-first list of played videos, playlists and Mixes, capped at `limit`.
public struct RecentLinksStore: Equatable, Sendable {
    /// Enough to reach back past "Last week" for a daily listener.
    public static let limit = 100
    public private(set) var items: [RecentLink]

    public init(items: [RecentLink] = []) {
        self.items = Array(items.prefix(Self.limit))
    }

    public init(decoding data: Data) {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.init(items: (try? decoder.decode([RecentLink].self, from: data)) ?? [])
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(items)
    }

    /// Moves `url` to the top with fresh metadata. Playing something again clears its finished mark.
    public mutating func record(url: URL, title: String, kind: LinkKind? = nil, duration: Double? = nil, count: Int? = nil,
                                date: Date = Date()) {
        let old = items.first { $0.url == url }
        items.removeAll { $0.url == url }
        items.insert(RecentLink(url: url, title: title, lastPlayed: date, kind: kind ?? old?.kind,
                                duration: duration ?? old?.duration, count: count ?? old?.count), at: 0)
        if items.count > Self.limit { items.removeLast(items.count - Self.limit) }
    }

    /// Marks `url` as played to the end.
    public mutating func markFinished(_ url: URL) {
        guard let i = items.firstIndex(where: { $0.url == url }) else { return }
        items[i].finished = true
    }

    public mutating func remove(_ url: URL) {
        items.removeAll { $0.url == url }
    }

    public mutating func clear() {
        items.removeAll()
    }

    /// The items in date groups, newest first, skipping empty groups.
    public func grouped(now: Date = Date(), calendar: Calendar = .current) -> [(group: RecentGroup, items: [RecentLink])] {
        let byGroup = Dictionary(grouping: items) { RecentGroup.group(for: $0.lastPlayed, now: now, calendar: calendar) }
        return RecentGroup.allCases.compactMap { g in byGroup[g].map { (g, $0) } }
    }
}
