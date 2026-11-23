import Foundation
import Testing
@testable import SorlCore

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

    @Test func offsetsCountFromWhatsPlaying() {
        var q = UpNext(current: Self.item("p1"), upcoming: ["p2", "now", "a", "b"].map { Self.item($0) })
        _ = q.advance()
        _ = q.advance()
        #expect(q.item(atOffset: 0)?.title == "now")
        #expect(q.item(atOffset: 1)?.title == "a")
        #expect(q.item(atOffset: 2)?.title == "b")
        #expect(q.item(atOffset: 3) == nil)
        #expect(q.item(atOffset: -1)?.title == "p2")
        #expect(q.item(atOffset: -2)?.title == "p1")
        #expect(q.item(atOffset: -3) == nil)
        #expect(UpNext(upcoming: [Self.item("a")]).item(atOffset: 1) == nil)
    }

    @Test func offsetRangesClampToTheQueue() {
        var q = UpNext(current: Self.item("p"), upcoming: ["now", "a", "b"].map { Self.item($0) })
        _ = q.advance()
        let all = q.items(fromOffset: -5, toOffset: 20)
        #expect(all.items.map(\.title) == ["p", "now", "a", "b"])
        #expect(all.currentIndex == 1)
        let ahead = q.items(fromOffset: 1, toOffset: 1)
        #expect(ahead.items.map(\.title) == ["a"])
        #expect(ahead.currentIndex == nil)
        #expect(q.items(fromOffset: 3, toOffset: 9).items.isEmpty)
        #expect(UpNext().items(fromOffset: 0, toOffset: 5).items.isEmpty)
    }

    @Test func nowPlayingPositionMatchesOffsets() {
        #expect(UpNext(current: Self.item("now")).nowPlayingPosition == nil)
        var q = UpNext(current: Self.item("p"), upcoming: ["now", "a", "b"].map { Self.item($0) })
        _ = q.advance()
        let position = try! #require(q.nowPlayingPosition)
        #expect(position.index == 1 && position.count == 4)
        #expect(q.item(atOffset: -position.index)?.title == "p")
        #expect(q.item(atOffset: position.count - 1 - position.index)?.title == "b")
        #expect(q.item(atOffset: position.count - position.index) == nil)
        // Up next items without a current one still report a position, as before.
        #expect(UpNext(upcoming: [Self.item("a")]).nowPlayingPosition?.count == 2)
    }

    @Test func findsItemsAnywhere() {
        var q = UpNext(current: Self.item("p"), upcoming: ["now", "a"].map { Self.item($0) })
        _ = q.advance()
        for item in [q.played[0], q.current!, q.upcoming[0]] { #expect(q.item(withID: item.id) == item) }
        #expect(q.item(withID: UUID()) == nil)
    }
}
