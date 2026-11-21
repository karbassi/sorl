public enum RepeatMode: String, CaseIterable, Sendable, Codable {
    case off, all, one

    /// A click on the repeat button: off → all → one → off.
    public var next: RepeatMode {
        switch self {
        case .off: return .all
        case .all: return .one
        case .one: return .off
        }
    }

    public var isOn: Bool { self != .off }

    public var label: String {
        switch self {
        case .off: return "Repeat off"
        case .all: return "Repeat all"
        case .one: return "Repeat one"
        }
    }

    /// What VoiceOver reads after "Repeat".
    public var accessibilityValue: String {
        switch self {
        case .off: return "Off"
        case .all: return "All"
        case .one: return "One"
        }
    }

    public var symbolName: String { self == .one ? "repeat.1" : "repeat" }
}
