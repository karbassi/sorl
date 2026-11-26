import CryptoKit
import Foundation
import Testing
@testable import SorlCore

@Suite struct SavedLinksTests {
    @Test func savesNewestFirstDedupedAndToggles() throws {
        var store = SavedLinksStore()
        let a = URL(string: "https://www.youtube.com/watch?v=aaaaaaaaaaa")!
        let b = URL(string: "https://www.youtube.com/watch?v=bbbbbbbbbbb")!
        store.save(url: a, title: "A", date: Date(timeIntervalSince1970: 1))
        store.save(url: b, title: "B", date: Date(timeIntervalSince1970: 2))
        #expect(store.items.map(\.title) == ["B", "A"])
        #expect(store.contains(a))

        store.save(url: a, title: "A again", date: Date(timeIntervalSince1970: 3))
        #expect(store.items.map(\.title) == ["A again", "B"])

        #expect(store.toggle(url: b, title: "B", date: Date(timeIntervalSince1970: 4)) == false)
        #expect(!store.contains(b))
        #expect(store.toggle(url: b, title: "B back", date: Date(timeIntervalSince1970: 5)) == true)
        #expect(store.items.first?.title == "B back")

        let decoded = SavedLinksStore(decoding: try store.encoded())
        #expect(decoded == store)
        #expect(SavedLinksStore(decoding: Data("nope".utf8)).items.isEmpty)
    }

    @Test func capsAtTheLimit() {
        var store = SavedLinksStore()
        for i in 0..<(SavedLinksStore.limit + 5) {
            store.save(url: URL(string: "https://youtu.be/v\(i)")!, title: "\(i)", date: Date(timeIntervalSince1970: Double(i)))
        }
        #expect(store.items.count == SavedLinksStore.limit)
        #expect(store.items.first?.title == "\(SavedLinksStore.limit + 4)")
        #expect(!store.contains(URL(string: "https://youtu.be/v0")!))
    }

    // MARK: Sync

    /// A whole second, so `t + 0.7` and `t + 0.2` share it.
    private static let t = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private static func url(_ n: Int) -> URL { URL(string: "https://youtu.be/s\(n)")! }
    private static func link(_ n: Int, _ seconds: Double, title: String? = nil) -> SavedLink {
        SavedLink(url: url(n), title: title ?? "\(n)", savedAt: t.addingTimeInterval(seconds))
    }
    /// A full store: item `n` saved at `t + n`, newest first.
    private static func fullStore() -> SavedLinksStore {
        SavedLinksStore(items: (0..<SavedLinksStore.limit).reversed().map { link($0, Double($0)) })
    }

    @Test func saveWithAnOldDateInsertsInSortedPosition() {
        var store = SavedLinksStore()
        store.save(url: Self.url(1), title: "1", date: Self.t.addingTimeInterval(10))
        store.save(url: Self.url(2), title: "2", date: Self.t.addingTimeInterval(30))
        store.save(url: Self.url(3), title: "3", date: Self.t.addingTimeInterval(20.6))
        #expect(store.items.map(\.title) == ["2", "3", "1"])
        #expect(store.items[1].savedAt == Self.t.addingTimeInterval(20))
        store.save(url: Self.url(4), title: "4", date: Self.t)
        #expect(store.items.map(\.title) == ["2", "3", "1", "4"])
    }

    @Test func twoSavesInTheSameSecondPutTheSecondFirst() {
        var store = SavedLinksStore()
        store.save(url: Self.url(1), title: "1", date: Self.t.addingTimeInterval(0.1))
        store.save(url: Self.url(2), title: "2", date: Self.t.addingTimeInterval(0.9))
        #expect(store.items.map(\.title) == ["2", "1"])
        store.save(url: Self.url(3), title: "3", date: Self.t.addingTimeInterval(0.5))
        #expect(store.items.map(\.title) == ["3", "2", "1"])
    }

    @Test func diffFindsAddsRemovesResavesAndTitleChanges() {
        let old = SavedLinksStore(items: [Self.link(3, 3), Self.link(2, 2), Self.link(1, 1)])

        var added = old
        added.save(url: Self.url(4), title: "4", date: Self.t.addingTimeInterval(4))
        var diff = SavedLinksStore.changes(from: old, to: added)
        #expect(diff.upserts.map(\.url) == [Self.url(4)])
        #expect(diff.deletes.isEmpty)

        var removed = old
        removed.remove(Self.url(2))
        diff = SavedLinksStore.changes(from: old, to: removed)
        #expect(diff.upserts.isEmpty)
        #expect(diff.deletes == [Self.url(2)])

        var resaved = old
        resaved.save(url: Self.url(1), title: "1", date: Self.t.addingTimeInterval(9))
        diff = SavedLinksStore.changes(from: old, to: resaved)
        #expect(diff.upserts.map(\.url) == [Self.url(1)])
        #expect(diff.deletes.isEmpty)

        var retitled = old
        retitled.save(url: Self.url(2), title: "Two", date: Self.t.addingTimeInterval(2))
        diff = SavedLinksStore.changes(from: old, to: retitled)
        #expect(diff.upserts.map(\.title) == ["Two"])
        #expect(diff.deletes.isEmpty)

        #expect(SavedLinksStore.changes(from: old, to: old).upserts.isEmpty)
        // A sub-second difference alone is not a change.
        let jittered = SavedLinksStore(items: [Self.link(3, 3.4), Self.link(2, 2.9), Self.link(1, 1.1)])
        #expect(SavedLinksStore.changes(from: old, to: jittered).upserts.isEmpty)
    }

    @Test func aCapEvictionIsNotADelete() {
        let old = Self.fullStore()
        var new = old
        new.save(url: Self.url(9999), title: "new", date: Self.t.addingTimeInterval(10_000))
        #expect(new.items.count == SavedLinksStore.limit)
        #expect(!new.contains(Self.url(0)))
        let diff = SavedLinksStore.changes(from: old, to: new)
        #expect(diff.upserts.map(\.url) == [Self.url(9999)])
        #expect(diff.deletes.isEmpty)
    }

    @Test func aUserRemoveFromAFullStoreIsADelete() {
        let old = Self.fullStore()
        var new = old
        new.remove(Self.url(0))
        #expect(SavedLinksStore.changes(from: old, to: new).deletes == [Self.url(0)])
        var middle = old
        middle.remove(Self.url(250))
        #expect(SavedLinksStore.changes(from: old, to: middle).deletes == [Self.url(250)])
    }

    @Test func remoteCopyWithinTheSameSecondIsNeitherNewerNorOlder() {
        // Raw dates would call local (t + 0.7) newer than remote (t + 0.2) and re-queue forever.
        var store = SavedLinksStore(items: [Self.link(1, 0.7, title: "local")])
        let remote = Self.link(1, 0.2, title: "remote")
        var applied = store.applyRemote(remote)
        #expect(applied)
        #expect(store.items.count == 1)
        #expect(store.items.first?.title == "remote")
        #expect(store.items.first?.savedAt == Self.t)
        // Applying the same record again changes nothing that would upload.
        let before = store
        applied = store.applyRemote(remote)
        #expect(applied)
        #expect(SavedLinksStore.changes(from: before, to: store).upserts.isEmpty)
    }

    @Test func applyRemoteKeepsNewerLocalAndTakesNewerRemote() {
        var store = SavedLinksStore(items: [Self.link(1, 10, title: "local")])
        var applied = store.applyRemote(Self.link(1, 5, title: "older remote"))
        #expect(!applied)
        #expect(store.items.map(\.title) == ["local"])
        applied = store.applyRemote(Self.link(1, 20, title: "newer remote"))
        #expect(applied)
        #expect(store.items.map(\.title) == ["newer remote"])
        #expect(store.items.first?.savedAt == Self.t.addingTimeInterval(20))
    }

    @Test func applyRemoteUnionsOutOfOrderInSavedAtOrder() {
        var store = SavedLinksStore(items: [Self.link(10, 15)])
        store.applyRemote(Self.link(1, 1))
        store.applyRemote(Self.link(3, 30))
        store.applyRemote(Self.link(2, 20))
        #expect(store.items.map(\.url) == [Self.url(3), Self.url(2), Self.url(10), Self.url(1)])
        // A newer remote copy moves an existing item up.
        store.applyRemote(Self.link(1, 40))
        #expect(store.items.map(\.url) == [Self.url(1), Self.url(3), Self.url(2), Self.url(10)])
    }

    @Test func applyRemoteRespectsTheCap() {
        var store = Self.fullStore()
        store.applyRemote(Self.link(9999, 10_000))
        #expect(store.items.count == SavedLinksStore.limit)
        #expect(store.items.first?.url == Self.url(9999))
        #expect(!store.contains(Self.url(0)))
        // Older than everything: lands past the end and falls off.
        store.applyRemote(Self.link(8888, -5))
        #expect(store.items.count == SavedLinksStore.limit)
        #expect(!store.contains(Self.url(8888)))
    }

    @Test func pendingDeleteBlocksARemoteUpsert() {
        var store = SavedLinksStore(items: [Self.link(1, 1)])
        let before = store
        var applied = store.applyRemote(Self.link(2, 50), hasPendingDelete: true)
        #expect(applied)
        applied = store.applyRemote(Self.link(1, 50, title: "newer"), hasPendingDelete: true)
        #expect(applied)
        #expect(store == before)
    }

    @Test func remoteDeleteGoesThroughTheRecordNameMap() {
        var store = SavedLinksStore(items: [Self.link(2, 2), Self.link(1, 1)])
        let key = SymmetricKey(size: .bits256)
        let map = store.recordNameMap(key: key)
        #expect(map.count == 2)
        #expect(map[SyncRecords.savedRecordName(for: Self.url(1), key: key)] == Self.url(1))

        store.applyRemoteDelete(recordName: "saved-" + String(repeating: "0", count: 64), map: map)
        #expect(store.items.count == 2)

        // A name made with another key matches nothing.
        let otherName = SyncRecords.savedRecordName(for: Self.url(1), key: SymmetricKey(size: .bits256))
        store.applyRemoteDelete(recordName: otherName, map: map)
        #expect(store.items.count == 2)

        store.applyRemoteDelete(recordName: SyncRecords.savedRecordName(for: Self.url(1), key: key), map: map, hasPendingSave: true)
        #expect(store.contains(Self.url(1)))

        store.applyRemoteDelete(recordName: SyncRecords.savedRecordName(for: Self.url(1), key: key), map: map)
        #expect(store.items.map(\.url) == [Self.url(2)])
    }
}
