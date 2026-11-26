import CloudKit
import CryptoKit
import Foundation
import Testing
@testable import SorlCore

@Suite struct SyncRecordsTests {
    let url = URL(string: "https://www.youtube.com/watch?v=aaaaaaaaaaa")!
    let date = Date(timeIntervalSinceReferenceDate: 800_000_000)
    let key = SymmetricKey(size: .bits256)

    @Test func roundTripsWithOptionalsSet() throws {
        let link = SavedLink(url: url, title: "A", savedAt: date, kind: .playlist, duration: 123.5, count: 42)
        let record = SyncRecords.record(for: link, key: key, base: nil)
        #expect(record.recordID.recordName == SyncRecords.savedRecordName(for: url, key: key))
        #expect(record.recordID.zoneID == SyncZone.id)
        let back = try #require(SyncRecords.savedLink(from: record))
        #expect(back == link)
        #expect(back.duration == 123.5)
        #expect(back.count == 42)
        #expect(back.kind == .playlist)
    }

    @Test func roundTripsWithOptionalsNil() throws {
        let link = SavedLink(url: url, title: "A", savedAt: date)
        let back = try #require(SyncRecords.savedLink(from: SyncRecords.record(for: link, key: key, base: nil)))
        #expect(back == link)
        #expect(back.kind == nil && back.duration == nil && back.count == nil)
    }

    @Test func reusesBaseAndClearsOptionals() throws {
        let full = SavedLink(url: url, title: "A", savedAt: date, kind: .mix, duration: 9, count: 3)
        let base = SyncRecords.record(for: full, key: key, base: nil)
        let updated = SyncRecords.record(for: SavedLink(url: url, title: "B", savedAt: date), key: key, base: base)
        #expect(updated === base)
        let back = try #require(SyncRecords.savedLink(from: updated))
        #expect(back.title == "B")
        #expect(back.kind == nil && back.duration == nil && back.count == nil)
    }

    // MARK: Encryption

    static let savedKeys = ["url", "title", "savedAt", "kind", "duration", "count"]

    @Test func everySavedFieldIsEncrypted() {
        let link = SavedLink(url: url, title: "A", savedAt: date, kind: .playlist, duration: 123.5, count: 42)
        let record = SyncRecords.record(for: link, key: key, base: nil)
        for field in Self.savedKeys {
            #expect(record[field] == nil, "plain \(field)")
            #expect(record.encryptedValues[field] != nil, "encrypted \(field)")
        }
    }

    @Test func aReusedBaseLosesItsPlainCopies() throws {
        let base = CKRecord(recordType: SyncRecords.savedLinkType,
                            recordID: CKRecord.ID(recordName: "x", zoneID: SyncZone.id))
        for field in Self.savedKeys { base[field] = "old" as NSString }
        let link = SavedLink(url: url, title: "A", savedAt: date, kind: .playlist, duration: 1, count: 2)
        let record = SyncRecords.record(for: link, key: key, base: base)
        for field in Self.savedKeys {
            #expect(record[field] == nil, "plain \(field)")
        }
        #expect(try #require(SyncRecords.savedLink(from: record)) == link)
    }

    @Test func plainFieldsAreNotRead() {
        let r = CKRecord(recordType: SyncRecords.savedLinkType, recordID: CKRecord.ID(recordName: "x", zoneID: SyncZone.id))
        r["url"] = url.absoluteString as NSString
        r["title"] = "A" as NSString
        r["savedAt"] = date as NSDate
        #expect(SyncRecords.savedLink(from: r) == nil)
    }

    // MARK: Record names

    @Test func sameURLAndKeyGiveTheSameName() {
        #expect(SyncRecords.savedRecordName(for: url, key: key) == SyncRecords.savedRecordName(for: url, key: key))
        let copy = SymmetricKey(data: key.withUnsafeBytes { Data($0) })
        #expect(SyncRecords.savedRecordName(for: url, key: key) == SyncRecords.savedRecordName(for: url, key: copy))
    }

    @Test func differentKeysGiveDifferentNames() {
        let other = SymmetricKey(size: .bits256)
        #expect(SyncRecords.savedRecordName(for: url, key: key) != SyncRecords.savedRecordName(for: url, key: other))
    }

    @Test func nameIsNotThePlainHash() {
        let name = SyncRecords.savedRecordName(for: url, key: key)
        #expect(name != "saved-" + SyncHash.hex(url.absoluteString))
        #expect(name.hasPrefix("saved-"))
        #expect(name.count == "saved-".count + 64)
    }

    @Test func longURLGivesShortStableName() {
        let long = URL(string: "https://example.com/?q=" + String(repeating: "x", count: 2_000))!
        #expect(long.absoluteString.count >= 2_000)
        let name = SyncRecords.savedRecordName(for: long, key: key)
        #expect(name.count <= 255)
        #expect(name == SyncRecords.savedRecordName(for: long, key: key))
    }

    @Test func hashIsStable() {
        #expect(SyncHash.hex("abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        #expect(SyncHash.hex("") == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    @Test func keyedHexMatchesRFC4231() {
        // RFC 4231 test case 2: key "Jefe", data "what do ya want for nothing?".
        let jefe = SymmetricKey(data: Data("Jefe".utf8))
        #expect(SyncHash.keyedHex("what do ya want for nothing?", key: jefe)
            == "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843")
    }

    @Test func malformedRecordGivesNil() {
        func record(_ fields: [String: CKRecordValue]) -> CKRecord {
            let r = CKRecord(recordType: SyncRecords.savedLinkType, recordID: CKRecord.ID(recordName: "x", zoneID: SyncZone.id))
            for (k, v) in fields { r.encryptedValues[k] = v }
            return r
        }
        let ok: [String: CKRecordValue] = ["url": url.absoluteString as NSString, "title": "A" as NSString, "savedAt": date as NSDate]
        #expect(SyncRecords.savedLink(from: record(ok)) != nil)
        for key in ok.keys {
            #expect(SyncRecords.savedLink(from: record(ok.filter { $0.key != key })) == nil)
        }
        #expect(SyncRecords.savedLink(from: record(ok.merging(["url": "" as NSString]) { $1 })) == nil)
        #expect(SyncRecords.savedLink(from: record(ok.merging(["url": "not a url" as NSString]) { $1 })) == nil)
        #expect(SyncRecords.savedLink(from: record(ok.merging(["title": NSNumber(value: 1)]) { $1 })) == nil)
        #expect(SyncRecords.savedLink(from: record(ok.merging(["savedAt": "yesterday" as NSString]) { $1 })) == nil)
    }

    // MARK: Sync key

    @Test func syncKeyRecordRoundTrips() throws {
        let record = SyncRecords.syncKeyRecord(key: key, base: nil)
        #expect(record.recordType == SyncRecords.syncKeyType)
        #expect(record.recordID.recordName == "sync-key")
        #expect(record.recordID.recordName == SyncRecords.syncKeyRecordName)
        #expect(record.recordID.zoneID == SyncZone.id)
        #expect(record["key"] == nil && record["createdAt"] == nil)
        #expect(record.encryptedValues["createdAt"] is Date)
        let back = try #require(SyncRecords.syncKey(from: record))
        #expect(back == key)
        #expect(SyncRecords.savedRecordName(for: url, key: back) == SyncRecords.savedRecordName(for: url, key: key))
    }

    @Test func syncKeyRecordKeepsCreatedAtOnABase() {
        let base = SyncRecords.syncKeyRecord(key: key, base: nil)
        base.encryptedValues["createdAt"] = date
        let again = SyncRecords.syncKeyRecord(key: key, base: base)
        #expect(again === base)
        #expect(again.encryptedValues["createdAt"] as? Date == date)
    }

    @Test func syncKeyOfTheWrongLengthGivesNil() {
        func record(_ bytes: Int?) -> CKRecord {
            let r = CKRecord(recordType: SyncRecords.syncKeyType,
                             recordID: CKRecord.ID(recordName: SyncRecords.syncKeyRecordName, zoneID: SyncZone.id))
            if let bytes { r.encryptedValues["key"] = Data(repeating: 7, count: bytes) }
            return r
        }
        #expect(SyncRecords.syncKey(from: record(32)) != nil)
        #expect(SyncRecords.syncKey(from: record(31)) == nil)
        #expect(SyncRecords.syncKey(from: record(33)) == nil)
        #expect(SyncRecords.syncKey(from: record(0)) == nil)
        #expect(SyncRecords.syncKey(from: record(nil)) == nil)
        let plain = record(nil)
        plain["key"] = Data(repeating: 7, count: 32) as NSData
        #expect(SyncRecords.syncKey(from: plain) == nil)
    }

    @Test func truncDropsSubSecondsAndIsIdempotent() {
        let d = Date(timeIntervalSinceReferenceDate: 800_000_000.789)
        let t = SyncDate.trunc(d)
        #expect(t.timeIntervalSinceReferenceDate == 800_000_000)
        #expect(SyncDate.trunc(t) == t)
        let before = Date(timeIntervalSinceReferenceDate: -10.25)
        #expect(SyncDate.trunc(before).timeIntervalSinceReferenceDate == -11)
    }
}
