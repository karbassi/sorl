import Foundation

/// What a Saved or Recent row links to, so the row can say "2:31:24" or "50 videos" without resolving it again.
public enum LinkKind: String, Codable, Sendable {
    case video, playlist, mix

    /// The kind a bare URL implies, for entries stored before kinds were recorded.
    public static func infer(from url: URL) -> LinkKind {
        guard let link = LinkParser.parse(url.absoluteString) else { return .video }
        if link.kind.isMix { return .mix }
        return link.isPlaylist ? .playlist : .video
    }
}

/// The trailing text of a library row: a duration for a video, "N videos" for a playlist or Mix.
public enum LibraryTrailing {
    public static func text(kind: LinkKind, duration: Double?, count: Int?) -> String? {
        switch kind {
        case .video:
            return duration.flatMap { $0 > 0 ? TimeFormat.clock($0) : nil }
        case .playlist, .mix:
            guard let count else { return nil }
            return count == 1 ? "1 video" : "\(count) videos"
        }
    }
}

/// Recent's date groups: Today, Yesterday, Earlier this week, Last week, then Earlier.
public enum RecentGroup: Int, CaseIterable, Sendable, Comparable {
    case today, yesterday, earlierThisWeek, lastWeek, earlier

    public var title: String {
        switch self {
        case .today: return "Today"
        case .yesterday: return "Yesterday"
        case .earlierThisWeek: return "Earlier this week"
        case .lastWeek: return "Last week"
        case .earlier: return "Earlier"
        }
    }

    public static func < (a: RecentGroup, b: RecentGroup) -> Bool { a.rawValue < b.rawValue }

    /// Calendar days decide Today and Yesterday; the calendar's week (its first weekday) decides the rest.
    public static func group(for date: Date, now: Date = Date(), calendar: Calendar = .current) -> RecentGroup {
        if calendar.isDate(date, inSameDayAs: now) { return .today }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return .yesterday
        }
        if calendar.isDate(date, equalTo: now, toGranularity: .weekOfYear), date < now { return .earlierThisWeek }
        if let lastWeek = calendar.date(byAdding: .weekOfYear, value: -1, to: now),
           calendar.isDate(date, equalTo: lastWeek, toGranularity: .weekOfYear) {
            return .lastWeek
        }
        return .earlier
    }
}
