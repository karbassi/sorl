import CloudKit
import Foundation
import Testing
@testable import SorlCore

@Suite struct SyncRecordsTests {
    let url = URL(string: "https://www.youtube.com/watch?v=aaaaaaaaaaa")!
    let date = Date(timeIntervalSinceReferenceDate: 800_000_000)

    @Test func roundTripsWithOptionalsSet() throws {
        let link = SavedLink(url: url, title: "A", savedAt: date, kind: .playlist, duration: 123.5, count: 42)
        let record = SyncRecords.record(for: link, base: nil)
        #expect(record.recordID.recordName == SyncRecords.savedRecordName(for: url))
        #expect(record.recordID.zoneID == SyncZone.id)
        let back = try #require(SyncRecords.savedLink(from: record))
        #expect(back == link)
        #expect(back.duration == 123.5)
        #expect(back.count == 42)
        #expect(back.kind == .playlist)
    }

    @Test func roundTripsWithOptionalsNil() throws {
        let link = SavedLink(url: url, title: "A", savedAt: date)
        let back = try #require(SyncRecords.savedLink(from: SyncRecords.record(for: link, base: nil)))
        #expect(back == link)
        #expect(back.kind == nil && back.duration == nil && back.count == nil)
    }

    @Test func reusesBaseAndClearsOptionals() throws {
        let full = SavedLink(url: url, title: "A", savedAt: date, kind: .mix, duration: 9, count: 3)
        let base = SyncRecords.record(for: full, base: nil)
        let updated = SyncRecords.record(for: SavedLink(url: url, title: "B", savedAt: date), base: base)
        #expect(updated === base)
        let back = try #require(SyncRecords.savedLink(from: updated))
        #expect(back.title == "B")
        #expect(back.kind == nil && back.duration == nil && back.count == nil)
    }

    @Test func longURLGivesShortStableName() {
        let long = URL(string: "https://example.com/?q=" + String(repeating: "x", count: 2_000))!
        #expect(long.absoluteString.count >= 2_000)
        let name = SyncRecords.savedRecordName(for: long)
        #expect(name.count <= 255)
        #expect(name == SyncRecords.savedRecordName(for: long))
    }

    @Test func hashIsStable() {
        #expect(SyncHash.hex("abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        #expect(SyncHash.hex("") == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        #expect(SyncRecords.savedRecordName(for: url) == "saved-" + SyncHash.hex(url.absoluteString))
    }

    @Test func malformedRecordGivesNil() {
        func record(_ fields: [String: CKRecordValue]) -> CKRecord {
            let r = CKRecord(recordType: SyncRecords.savedLinkType, recordID: CKRecord.ID(recordName: "x", zoneID: SyncZone.id))
            for (k, v) in fields { r[k] = v }
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

    @Test func truncDropsSubSecondsAndIsIdempotent() {
        let d = Date(timeIntervalSinceReferenceDate: 800_000_000.789)
        let t = SyncDate.trunc(d)
        #expect(t.timeIntervalSinceReferenceDate == 800_000_000)
        #expect(SyncDate.trunc(t) == t)
        let before = Date(timeIntervalSinceReferenceDate: -10.25)
        #expect(SyncDate.trunc(before).timeIntervalSinceReferenceDate == -11)
    }
}
