import CloudKit
import Foundation

/// A keyboard shortcut's stored value, as the vendor KeyboardShortcuts package keeps it in UserDefaults:
/// a JSON string when set, `false` when disabled.
///
/// Deliberately not `Equatable`: the vendor encodes JSON without sorted keys, so two equal shortcuts can
/// have different strings. Compare with `same(_:_:as:)`, which decodes them.
public enum ShortcutState: Sendable {
    case set(String)
    case disabled

    /// The vendor's private UserDefaults prefix, hardcoded since SorlCore can't import it.
    public static func defaultsKey(_ rawValue: String) -> String {
        "KeyboardShortcuts_" + rawValue
    }

    /// A String gives `.set`, the Bool `false` gives `.disabled`. Anything else (absent, `true`, a number)
    /// gives nil, meaning leave the local value alone.
    public init?(storedValue: Any?) {
        guard let storedValue else { return nil }
        if let string = storedValue as? String {
            self = .set(string)
            return
        }
        // `as? Bool` alone would also accept an NSNumber 0, so require a real CFBoolean.
        guard CFGetTypeID(storedValue as CFTypeRef) == CFBooleanGetTypeID(),
              let bool = storedValue as? Bool, !bool
        else { return nil }
        self = .disabled
    }

    public var storedValue: Any {
        switch self {
        case .set(let json): json
        case .disabled: false
        }
    }

    /// Equal when both are disabled, or both are set and their JSON decodes to equal `S` values.
    /// A `.set` that doesn't decode is never equal to anything.
    public static func same<S: Decodable & Equatable>(_ a: Self, _ b: Self, as type: S.Type) -> Bool {
        switch (a, b) {
        case (.disabled, .disabled):
            return true
        case (.set(let x), .set(let y)):
            let decoder = JSONDecoder()
            guard let dx = try? decoder.decode(S.self, from: Data(x.utf8)),
                  let dy = try? decoder.decode(S.self, from: Data(y.utf8))
            else { return false }
            return dx == dy
        default:
            return false
        }
    }
}

/// Sync decisions and the `Shortcut` record mapping. Pure: no network, no database, no UserDefaults.
public enum ShortcutSync {
    public static let shortcutType = "Shortcut"
    public static let recordPrefix = "shortcut-"

    public static func recordName(for rawValue: String) -> String {
        recordPrefix + rawValue
    }

    /// Writes the shortcut into `base` (keeping its change tag) or into a new record in `SyncZone.id`.
    public static func record(name rawValue: String, state: ShortcutState, modifiedAt: Date, base: CKRecord?) -> CKRecord {
        let record = base ?? CKRecord(
            recordType: shortcutType,
            recordID: CKRecord.ID(recordName: recordName(for: rawValue), zoneID: SyncZone.id)
        )
        switch state {
        case .set(let json):
            record["state"] = "set" as NSString
            record["value"] = json as NSString
        case .disabled:
            record["state"] = "disabled" as NSString
            record["value"] = nil
        }
        record["modifiedAt"] = SyncDate.trunc(modifiedAt) as NSDate
        return record
    }

    /// Nil when the record name lacks the prefix, `state` is missing or unknown, `"set"` has no `value`,
    /// or `modifiedAt` is missing.
    public static func shortcut(from record: CKRecord) -> (name: String, state: ShortcutState, modifiedAt: Date)? {
        let recordName = record.recordID.recordName
        guard recordName.hasPrefix(recordPrefix) else { return nil }
        let name = String(recordName.dropFirst(recordPrefix.count))
        guard !name.isEmpty,
              let stateString = record["state"] as? String,
              let modifiedAt = record["modifiedAt"] as? Date
        else { return nil }
        let state: ShortcutState
        switch stateString {
        case "set":
            guard let json = record["value"] as? String else { return nil }
            state = .set(json)
        case "disabled":
            state = .disabled
        default:
            return nil
        }
        return (name, state, SyncDate.trunc(modifiedAt))
    }

    /// True only when the local stamp is strictly newer; equal goes to the server. Shared by fetch-apply
    /// and `serverRecordChanged` so both paths agree.
    public static func localWins(local: Date?, remote: Date) -> Bool {
        (local ?? .distantPast) > remote
    }

    /// The stamp for a local change: strictly after `previous`, so two edits in the same second never tie.
    public static func nextStamp(previous: Date?, now: Date) -> Date {
        max(SyncDate.trunc(now), (previous ?? .distantPast) + 1)
    }

    /// On first enable: a shortcut equal to its initial value gets `distantPast` (even over an existing
    /// stamp), a customized unstamped one gets `now`, and a customized stamped one keeps its stamp.
    public static func firstEnableStamp(isInitial: Bool, existing: Date?, now: Date) -> Date {
        if isInitial { return .distantPast }
        return existing ?? SyncDate.trunc(now)
    }
}

/// `shortcutsModifiedAt`: when each shortcut last changed, keyed by `name.rawValue`.
public struct ShortcutTimes: Equatable, Sendable {
    public var entries: [String: Date]

    public init(entries: [String: Date] = [:]) {
        self.entries = entries
    }

    /// A bad blob gives empty.
    public init(decoding data: Data) {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.init(entries: (try? decoder.decode([String: Date].self, from: data)) ?? [:])
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(entries)
    }

    public subscript(name: String) -> Date? {
        get { entries[name] }
        set { entries[name] = newValue }
    }
}
