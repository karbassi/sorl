/// Global playback speed, 0.75× to 2× in quarter steps. Raw values are what `sorl://speed?value=` and the saved
/// setting use, so 1.5 and 2 stay valid.
public enum PlaybackSpeed: Double, CaseIterable, Sendable, Identifiable {
    case slower = 0.75
    case normal = 1.0
    case quick = 1.25
    case faster = 1.5
    case fastest = 1.75
    case double = 2.0

    public var id: Double { rawValue }

    public var label: String {
        switch self {
        case .slower: return "0.75×"
        case .normal: return "1×"
        case .quick: return "1.25×"
        case .faster: return "1.5×"
        case .fastest: return "1.75×"
        case .double: return "2×"
        }
    }

    /// A click on the pill: 1 → 1.25 → 1.5 → 1.75 → 2 → 0.75 → 1.
    public var next: PlaybackSpeed {
        let all = Self.allCases
        return all[(all.firstIndex(of: self)! + 1) % all.count]
    }

    /// Option-click or scrolling on the pill: the reverse.
    public var previous: PlaybackSpeed {
        let all = Self.allCases
        return all[(all.firstIndex(of: self)! + all.count - 1) % all.count]
    }
}
