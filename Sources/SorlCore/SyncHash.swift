import CryptoKit
import Foundation

/// Stable, length-bounded identifiers for sync records.
public enum SyncHash {
    /// SHA-256 of `s` (UTF-8) as 64 lowercase hex characters.
    public static func hex(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// Dates that sync stamps or compares are cut to whole seconds, since local stores persist ISO 8601 (whole
/// seconds) while CloudKit keeps milliseconds. Without this a fetched record would always look older than local.
public enum SyncDate {
    public static func trunc(_ d: Date) -> Date {
        Date(timeIntervalSinceReferenceDate: floor(d.timeIntervalSinceReferenceDate))
    }
}
