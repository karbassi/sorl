import CloudKit
import Foundation
import Testing
@testable import SorlCore

@Suite struct ShortcutSyncTests {
    let date = Date(timeIntervalSinceReferenceDate: 800_000_000)

    /// Stands in for `KeyboardShortcuts.Shortcut`, which SorlCore can't import.
    struct Combo: Codable, Equatable {
        let carbonKeyCode: Int
        let carbonModifiers: Int
    }

    // MARK: Stored values

    @Test func storedValueRoundTripsEachState() throws {
        let json = #"{"carbonKeyCode":1,"carbonModifiers":256}"#
        let set = try #require(ShortcutState(storedValue: ShortcutState.set(json).storedValue))
        guard case .set(let back) = set else { Issue.record("expected .set"); return }
        #expect(back == json)

        let disabledValue = ShortcutState.disabled.storedValue
        #expect(disabledValue as? Bool == false)
        let disabled = try #require(ShortcutState(storedValue: disabledValue))
        guard case .disabled = disabled else { Issue.record("expected .disabled"); return }
    }

    @Test func storedValueThroughUserDefaults() throws {
        let suite = "ShortcutSyncTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = ShortcutState.defaultsKey("togglePlay")
        #expect(key == "KeyboardShortcuts_togglePlay")

        defaults.set(ShortcutState.disabled.storedValue, forKey: key)
        guard case .disabled? = ShortcutState(storedValue: defaults.object(forKey: key)) else {
            Issue.record("expected .disabled"); return
        }
        defaults.set(ShortcutState.set("{}").storedValue, forKey: key)
        guard case .set("{}")? = ShortcutState(storedValue: defaults.object(forKey: key)) else {
            Issue.record("expected .set"); return
        }
        defaults.set(0, forKey: key)
        #expect(ShortcutState(storedValue: defaults.object(forKey: key)) == nil)
    }

    @Test func nilAndGarbageGiveNil() {
        #expect(ShortcutState(storedValue: nil) == nil)
        #expect(ShortcutState(storedValue: true) == nil)
        #expect(ShortcutState(storedValue: 0) == nil)
        #expect(ShortcutState(storedValue: 1) == nil)
        #expect(ShortcutState(storedValue: NSNumber(value: 0)) == nil)
        #expect(ShortcutState(storedValue: 1.5) == nil)
        #expect(ShortcutState(storedValue: Data()) == nil)
        #expect(ShortcutState(storedValue: ["a": 1]) == nil)
    }

    @Test func sameComparesDecodedValuesNotStrings() {
        let a = ShortcutState.set(#"{"carbonKeyCode":1,"carbonModifiers":256}"#)
        let b = ShortcutState.set(#"{"carbonModifiers":256,"carbonKeyCode":1}"#)
        let c = ShortcutState.set(#"{"carbonKeyCode":2,"carbonModifiers":256}"#)
        #expect(ShortcutState.same(a, b, as: Combo.self))
        #expect(!ShortcutState.same(a, c, as: Combo.self))
        #expect(ShortcutState.same(.disabled, .disabled, as: Combo.self))
        #expect(!ShortcutState.same(a, .disabled, as: Combo.self))
        #expect(!ShortcutState.same(.disabled, a, as: Combo.self))
        #expect(!ShortcutState.same(.set("garbage"), .set("garbage"), as: Combo.self))
    }

    // MARK: Records

    @Test func recordRoundTripsEachState() throws {
        let json = #"{"carbonKeyCode":1,"carbonModifiers":256}"#
        let setRecord = ShortcutSync.record(name: "togglePlay", state: .set(json), modifiedAt: date.addingTimeInterval(0.7), base: nil)
        #expect(setRecord.recordType == ShortcutSync.shortcutType)
        #expect(setRecord.recordID.recordName == "shortcut-togglePlay")
        #expect(setRecord.recordID.zoneID == SyncZone.id)
        #expect(setRecord.encryptedValues["modifiedAt"] as? Date == date)
        let set = try #require(ShortcutSync.shortcut(from: setRecord))
        #expect(set.name == "togglePlay")
        #expect(set.modifiedAt == date)
        guard case .set(json) = set.state else { Issue.record("expected .set"); return }

        let disabledRecord = ShortcutSync.record(name: "togglePlay", state: .disabled, modifiedAt: date, base: setRecord)
        #expect(disabledRecord === setRecord)
        #expect(disabledRecord.encryptedValues["value"] == nil)
        let disabled = try #require(ShortcutSync.shortcut(from: disabledRecord))
        guard case .disabled = disabled.state else { Issue.record("expected .disabled"); return }
    }

    @Test func everyShortcutFieldIsEncrypted() {
        let keys = ["state", "value", "modifiedAt"]
        let record = ShortcutSync.record(name: "togglePlay", state: .set("{}"), modifiedAt: date, base: nil)
        for field in keys {
            #expect(record[field] == nil, "plain \(field)")
            #expect(record.encryptedValues[field] != nil, "encrypted \(field)")
        }
        // A reused base with old plain fields keeps no plain copy.
        let base = CKRecord(recordType: ShortcutSync.shortcutType,
                            recordID: CKRecord.ID(recordName: "shortcut-togglePlay", zoneID: SyncZone.id))
        for field in keys { base[field] = "old" as NSString }
        let disabled = ShortcutSync.record(name: "togglePlay", state: .disabled, modifiedAt: date, base: base)
        for field in keys {
            #expect(disabled[field] == nil, "plain \(field)")
        }
        guard case .disabled? = ShortcutSync.shortcut(from: disabled)?.state else { Issue.record("expected .disabled"); return }
    }

    @Test func plainFieldsAreNotRead() {
        let r = CKRecord(recordType: ShortcutSync.shortcutType, recordID: CKRecord.ID(recordName: "shortcut-x", zoneID: SyncZone.id))
        r["state"] = "disabled" as NSString
        r["modifiedAt"] = date as NSDate
        #expect(ShortcutSync.shortcut(from: r) == nil)
    }

    @Test func malformedRecordGivesNil() {
        func record(_ fields: [String: CKRecordValue], name: String = "shortcut-x") -> CKRecord {
            let r = CKRecord(recordType: ShortcutSync.shortcutType, recordID: CKRecord.ID(recordName: name, zoneID: SyncZone.id))
            for (k, v) in fields { r.encryptedValues[k] = v }
            return r
        }
        let ok: [String: CKRecordValue] = ["state": "set" as NSString, "value": "{}" as NSString, "modifiedAt": date as NSDate]
        #expect(ShortcutSync.shortcut(from: record(ok)) != nil)
        #expect(ShortcutSync.shortcut(from: record(ok, name: "saved-x")) == nil)
        #expect(ShortcutSync.shortcut(from: record(ok, name: "shortcut-")) == nil)
        for key in ok.keys {
            #expect(ShortcutSync.shortcut(from: record(ok.filter { $0.key != key })) == nil)
        }
        #expect(ShortcutSync.shortcut(from: record(ok.merging(["state": "on" as NSString]) { $1 })) == nil)
        #expect(ShortcutSync.shortcut(from: record(ok.merging(["state": NSNumber(value: 1)]) { $1 })) == nil)
        #expect(ShortcutSync.shortcut(from: record(ok.merging(["modifiedAt": "now" as NSString]) { $1 })) == nil)
        #expect(ShortcutSync.shortcut(from: record(["state": "disabled" as NSString, "modifiedAt": date as NSDate])) != nil)
    }

    // MARK: Decisions

    @Test func localWinsOnlyWhenStrictlyNewer() {
        #expect(!ShortcutSync.localWins(local: nil, remote: date))
        #expect(!ShortcutSync.localWins(local: date, remote: date))
        #expect(ShortcutSync.localWins(local: date + 1, remote: date))
        #expect(!ShortcutSync.localWins(local: date - 1, remote: date))
    }

    @Test func nextStampIsStrictlyIncreasing() {
        #expect(ShortcutSync.nextStamp(previous: nil, now: date + 0.4) == date)
        #expect(ShortcutSync.nextStamp(previous: date - 5, now: date + 0.4) == date)
        #expect(ShortcutSync.nextStamp(previous: date, now: date + 0.4) == date + 1)
        #expect(ShortcutSync.nextStamp(previous: date + 10, now: date) == date + 11)
    }

    @Test func firstEnableStampBranches() {
        let now = date + 0.6
        #expect(ShortcutSync.firstEnableStamp(isInitial: true, existing: date + 50, now: now) == .distantPast)
        #expect(ShortcutSync.firstEnableStamp(isInitial: true, existing: nil, now: now) == .distantPast)
        #expect(ShortcutSync.firstEnableStamp(isInitial: false, existing: nil, now: now) == date)
        #expect(ShortcutSync.firstEnableStamp(isInitial: false, existing: date - 100, now: now) == date - 100)
    }

    // MARK: Times

    @Test func timesRoundTrip() throws {
        var times = ShortcutTimes()
        times["a"] = date
        times["b"] = .distantPast
        let back = ShortcutTimes(decoding: try times.encoded())
        #expect(back == times)
        #expect(back["a"] == date)
        #expect(back["b"] == .distantPast)
    }

    @Test func badBlobGivesEmpty() {
        #expect(ShortcutTimes(decoding: Data("not json".utf8)).entries.isEmpty)
        #expect(ShortcutTimes(decoding: Data(#"{"a":"yesterday"}"#.utf8)).entries.isEmpty)
        #expect(ShortcutTimes(decoding: Data()).entries.isEmpty)
    }
}
