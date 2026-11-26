import CloudKit
import CryptoKit
import Foundation

/// The custom zone in the private database that holds every Sorl record.
public enum SyncZone {
    public static let id = CKRecordZone.ID(zoneName: "Sorl")
}

extension CKRecord {
    /// Writes `value` to `encryptedValues[key]` and clears any plain field of the same name, so a reused base
    /// record never keeps a plain copy. The plain field is only touched when present: CloudKit throws if a key
    /// that is already encrypted is also set plain, even to nil.
    func setEncrypted(_ key: String, _ value: (any CKRecordValueProtocol)?) {
        if self[key] != nil { self[key] = nil }
        if let value {
            encryptedValues[key] = value
        } else {
            encryptedValues[key] = nil as String?
        }
    }
}

/// Maps local models to and from CloudKit records. Pure mapping: no network, no database.
/// Every synced field lives in `encryptedValues`; only record names, types and zone stay plain.
public enum SyncRecords {
    public static let savedLinkType = "SavedLink"
    public static let syncKeyType = "SyncKey"
    public static let syncKeyRecordName = "sync-key"

    /// Keyed, so the name reveals nothing about the URL without the account's sync key, and hashed, since URLs
    /// can exceed CloudKit's 255-character record name limit.
    public static func savedRecordName(for url: URL, key: SymmetricKey) -> String {
        "saved-" + SyncHash.keyedHex(url.absoluteString, key: key)
    }

    /// Writes `link` into `base` (keeping its change tag) or into a new record in `SyncZone.id` named with `key`.
    public static func record(for link: SavedLink, key: SymmetricKey, base: CKRecord?) -> CKRecord {
        let record = base ?? CKRecord(
            recordType: savedLinkType,
            recordID: CKRecord.ID(recordName: savedRecordName(for: link.url, key: key), zoneID: SyncZone.id)
        )
        record.setEncrypted("url", link.url.absoluteString)
        record.setEncrypted("title", link.title)
        record.setEncrypted("savedAt", SyncDate.trunc(link.savedAt))
        record.setEncrypted("kind", link.kind?.rawValue)
        record.setEncrypted("duration", link.duration)
        record.setEncrypted("count", link.count.map { Int64($0) })
        return record
    }

    /// Nil when `url`, `title` or `savedAt` is missing or invalid. An unknown `kind` is dropped, not fatal.
    public static func savedLink(from record: CKRecord) -> SavedLink? {
        let values = record.encryptedValues
        guard let urlString = values["url"] as? String, let url = URL(string: urlString), url.scheme != nil,
              let title = values["title"] as? String,
              let savedAt = values["savedAt"] as? Date
        else { return nil }
        let kind = (values["kind"] as? String).flatMap(LinkKind.init(rawValue:))
        let duration = (values["duration"] as? NSNumber)?.doubleValue
        let count = (values["count"] as? NSNumber).map { Int($0.int64Value) }
        return SavedLink(url: url, title: title, savedAt: SyncDate.trunc(savedAt), kind: kind, duration: duration, count: count)
    }

    // MARK: Sync key

    /// The account's sync key as a `SyncKey` record named `syncKeyRecordName` in `SyncZone.id`, written into `base`
    /// when given. `createdAt` is set once: a base that already has one keeps it.
    public static func syncKeyRecord(key: SymmetricKey, base: CKRecord?) -> CKRecord {
        let record = base ?? CKRecord(
            recordType: syncKeyType,
            recordID: CKRecord.ID(recordName: syncKeyRecordName, zoneID: SyncZone.id)
        )
        record.setEncrypted("key", key.withUnsafeBytes { Data($0) })
        let createdAt = (record.encryptedValues["createdAt"] as? Date) ?? SyncDate.trunc(Date())
        record.setEncrypted("createdAt", createdAt)
        return record
    }

    /// Nil unless `encryptedValues["key"]` is exactly 32 bytes.
    public static func syncKey(from record: CKRecord) -> SymmetricKey? {
        guard let data = record.encryptedValues["key"] as? Data, data.count == 32 else { return nil }
        return SymmetricKey(data: data)
    }
}
