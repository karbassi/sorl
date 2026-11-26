import CloudKit
import Foundation

/// The custom zone in the private database that holds every Sorl record.
public enum SyncZone {
    public static let id = CKRecordZone.ID(zoneName: "Sorl")
}

/// Maps local models to and from CloudKit records. Pure mapping: no network, no database.
public enum SyncRecords {
    public static let savedLinkType = "SavedLink"

    /// Hashed, since URLs can exceed CloudKit's 255-character record name limit.
    public static func savedRecordName(for url: URL) -> String {
        "saved-" + SyncHash.hex(url.absoluteString)
    }

    /// Writes `link` into `base` (keeping its change tag) or into a new record in `SyncZone.id`.
    public static func record(for link: SavedLink, base: CKRecord?) -> CKRecord {
        let record = base ?? CKRecord(
            recordType: savedLinkType,
            recordID: CKRecord.ID(recordName: savedRecordName(for: link.url), zoneID: SyncZone.id)
        )
        record["url"] = link.url.absoluteString as NSString
        record["title"] = link.title as NSString
        record["savedAt"] = SyncDate.trunc(link.savedAt) as NSDate
        record["kind"] = link.kind.map { $0.rawValue as NSString }
        record["duration"] = link.duration.map { NSNumber(value: $0) }
        record["count"] = link.count.map { NSNumber(value: Int64($0)) }
        return record
    }

    /// Nil when `url`, `title` or `savedAt` is missing or invalid. An unknown `kind` is dropped, not fatal.
    public static func savedLink(from record: CKRecord) -> SavedLink? {
        guard let urlString = record["url"] as? String, let url = URL(string: urlString), url.scheme != nil,
              let title = record["title"] as? String,
              let savedAt = record["savedAt"] as? Date
        else { return nil }
        let kind = (record["kind"] as? String).flatMap(LinkKind.init(rawValue:))
        let duration = (record["duration"] as? NSNumber)?.doubleValue
        let count = (record["count"] as? NSNumber).map { Int($0.int64Value) }
        return SavedLink(url: url, title: title, savedAt: SyncDate.trunc(savedAt), kind: kind, duration: duration, count: count)
    }
}
