import Foundation
import Testing
@testable import UndertoneCore

@Suite struct UpNextTests {
    static func item(_ name: String, source: String? = "Sets") -> QueueItem {
        QueueItem(videoID: name, url: URL(string: "https://www.youtube.com/watch?v=\(name)")!, title: name, duration: 60, source: source)
    }

    static func queue(_ names: [String], current: String = "now") -> UpNext {
        UpNext(current: item(current), upcoming: names.map { item($0) }, sourceTitle: "Sets")
    }

    @Test func duplicatesGetTheirOwnIDs() {
        let a = Self.item("a")
        var q = UpNext(current: Self.item("now"))
        q.append([a.copy(), a.copy()])
        #expect(q.upcoming.count == 2)
        #expect(q.upcoming[0].id != q.upcoming[1].id)
        #expect(q.upcoming.allSatisfy { $0.videoID == "a" })
    }

    @Test func advanceMovesCurrentToPlayed() {
        var q = Self.queue(["a", "b"])
        #expect(q.advance()?.title == "a")
        #expect(q.played.map(\.title) == ["now"])
        #expect(q.upcoming.map(\.title) == ["b"])
    }

    @Test func advanceThroughRetiresSkippedRows() {
        var q = Self.queue(["a", "b", "c"])
        #expect(q.advance(through: q.upcoming[1].id)?.title == "b")
        #expect(q.played.map(\.title) == ["now", "a"])
        #expect(q.upcoming.map(\.title) == ["c"])
    }

    @Test func jumpKeepsRowsAboveQueued() {
        var q = Self.queue(["a", "b", "c"])
        let c = q.upcoming[2].id
        #expect(q.jump(to: c)?.title == "c")
        #expect(q.upcoming.map(\.title) == ["a", "b"])
        #expect(q.played.map(\.title) == ["now"])
    }

    @Test func playNowKeepsUpNext() {
        var q = Self.queue(["a"])
        q.playNow(Self.item("saved", source: nil))
        #expect(q.current?.title == "saved")
        #expect(q.upcoming.map(\.title) == ["a"])
        #expect(q.played.map(\.title) == ["now"])
    }

    @Test func goBackReturnsCurrentToTheFront() {
        var q = Self.queue(["a"])
        q.advance()
        #expect(q.goBack()?.title == "now")
        #expect(q.upcoming.map(\.title) == ["a"])
        #expect(q.played.isEmpty)
        #expect(q.goBack() == nil)
    }

    @Test func insertNextKeepsOrder() {
        var q = Self.queue(["a"])
        q.insertNext([Self.item("x"), Self.item("y")])
        #expect(q.upcoming.map(\.title) == ["x", "y", "a"])
    }

    @Test func removeMoveAndClearWithUndo() {
        var q = Self.queue(["a", "b", "c"])
        let snapshot = q
        let b = q.upcoming[1].id
        #expect(q.remove(b)?.index == 1)
        #expect(q.upcoming.map(\.title) == ["a", "c"])
        q.restoreQueue(from: snapshot)
        #expect(q == snapshot)

        let c = q.upcoming[2].id
        #expect(q.move(c, to: 0) == 0)
        #expect(q.upcoming.map(\.title) == ["c", "a", "b"])
        #expect(q.move(c, by: -1) == nil)
        #expect(q.move(c, by: 1) == 1)
        #expect(q.upcoming.map(\.title) == ["a", "c", "b"])

        let before = q
        #expect(q.clear() == 3)
        #expect(q.isEmpty)
        #expect(q.current?.title == "now")   // what's playing keeps going
        q.restoreQueue(from: before)
        #expect(q.upcoming.count == 3)
    }

    @Test func replaceAndUndoKeepTheNewCurrent() {
        var q = Self.queue(["a", "b"])
        let snapshot = q
        let entries = (1...3).map { PlaylistEntry(id: "p\($0)", title: "P\($0)", url: URL(string: "https://www.youtube.com/watch?v=p\($0)")!) }
        q.replace(with: entries, title: "Focus", sourceURL: nil, isMix: true)
        #expect(q.current?.title == "P1")
        #expect(q.upcoming.map(\.title) == ["P2", "P3"])
        #expect(q.played.map(\.title) == ["now"])
        #expect(q.headerSource == "Focus")
        q.restoreQueue(from: snapshot)
        #expect(q.current?.title == "P1")
        #expect(q.upcoming.map(\.title) == ["a", "b"])
        #expect(q.sourceTitle == "Sets")
    }

    @Test func headerSourceLastsWhileAnyEntryIsFromIt() {
        var q = Self.queue(["a"])
        #expect(q.headerSource == "Sets")
        q.append([Self.item("other", source: nil)])
        #expect(q.headerSource == "Sets")
        q.remove(q.upcoming[0].id)
        #expect(q.headerSource == nil)
    }

    @Test func wrapAroundRequeuesPlayed() {
        var q = Self.queue(["a"])
        q.advance()
        #expect(q.wrapAround()?.title == "now")
        #expect(q.upcoming.map(\.title) == ["a"])
        #expect(q.played.isEmpty)
    }

    @Test func limitsAreKept() {
        var q = UpNext(upcoming: (0..<UpNext.limit).map { Self.item("\($0)") })
        #expect(q.append([Self.item("over")]) == 0)
        for i in 0..<(UpNext.playedLimit + 5) { q.playNow(Self.item("p\(i)")) }
        #expect(q.played.count == UpNext.playedLimit)
    }

    @Test func roundTripsThroughJSON() throws {
        var q = Self.queue(["a", "b"])
        q.advance()
        let decoded = UpNext(decoding: try q.encoded())
        #expect(decoded == q)
        #expect(UpNext(decoding: Data("junk".utf8)) == UpNext())
    }
}
