import Foundation
import Testing
@testable import SorlCore

@Suite struct RecentLinksTests {
    @Test func recordsMostRecentFirstDedupedAndCapped() throws {
        var store = RecentLinksStore()
        let n = RecentLinksStore.limit + 2
        for i in 0..<n {
            store.record(url: URL(string: "https://youtu.be/v\(i)")!, title: "Video \(i)", date: Date(timeIntervalSince1970: Double(i)))
        }
        #expect(store.items.count == RecentLinksStore.limit)
        #expect(store.items.first?.title == "Video \(n - 1)")
        #expect(store.items.last?.title == "Video 2")

        store.record(url: URL(string: "https://youtu.be/v5")!, title: "Video 5 again", date: Date(timeIntervalSince1970: 100))
        #expect(store.items.count == RecentLinksStore.limit)
        #expect(store.items.first?.title == "Video 5 again")
        #expect(store.items.filter { $0.url.absoluteString == "https://youtu.be/v5" }.count == 1)

        let data = try store.encoded()
        let decoded = RecentLinksStore(decoding: data)
        #expect(decoded == store)

        store.remove(URL(string: "https://youtu.be/v5")!)
        #expect(store.items.first?.title == "Video \(n - 1)")
        store.clear()
        #expect(store.items.isEmpty)
        #expect(RecentLinksStore(decoding: Data("garbage".utf8)).items.isEmpty)
    }
}

@Suite struct LibraryMetadataTests {
    @Test func finishedIsClearedByPlayingAgain() {
        var store = RecentLinksStore()
        let url = URL(string: "https://www.youtube.com/watch?v=abc")!
        store.record(url: url, title: "A", kind: .video, duration: 3600)
        store.markFinished(url)
        #expect(store.items[0].finished)
        store.record(url: url, title: "A")
        #expect(store.items[0].finished == false)
        #expect(store.items[0].duration == 3600)   // metadata survives a bare re-record
    }

    @Test func oldEntriesDecodeAndInferTheirKind() throws {
        let json = #"[{"url":"https://www.youtube.com/playlist?list=PL1","title":"P","lastPlayed":"2026-01-01T00:00:00Z"}]"#
        let store = RecentLinksStore(decoding: Data(json.utf8))
        #expect(store.items.count == 1)
        #expect(store.items[0].finished == false)
        #expect(store.items[0].resolvedKind == .playlist)
    }

    @Test func trailingText() {
        #expect(LibraryTrailing.text(kind: .video, duration: 9084, count: nil) == "2:31:24")
        #expect(LibraryTrailing.text(kind: .mix, duration: nil, count: 50) == "50 videos")
        #expect(LibraryTrailing.text(kind: .playlist, duration: nil, count: 1) == "1 video")
        #expect(LibraryTrailing.text(kind: .video, duration: nil, count: nil) == nil)
    }

    @Test func savedStoresMetadata() {
        var saved = SavedLinksStore()
        saved.save(url: URL(string: "https://www.youtube.com/watch?v=x")!, title: "X", kind: .video, duration: 58 * 60 + 12)
        #expect(saved.items[0].trailingText == "58:12")
    }

    @Test func dateGroups() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        cal.firstWeekday = 2   // Monday
        let now = cal.date(from: DateComponents(year: 2026, month: 11, day: 19, hour: 12))!   // a Thursday
        func day(_ d: Int) -> Date { cal.date(from: DateComponents(year: 2026, month: 11, day: d, hour: 9))! }
        #expect(RecentGroup.group(for: day(19), now: now, calendar: cal) == .today)
        #expect(RecentGroup.group(for: day(18), now: now, calendar: cal) == .yesterday)
        #expect(RecentGroup.group(for: day(16), now: now, calendar: cal) == .earlierThisWeek)
        #expect(RecentGroup.group(for: day(12), now: now, calendar: cal) == .lastWeek)
        #expect(RecentGroup.group(for: day(1), now: now, calendar: cal) == .earlier)
    }

    @Test func speedSteps() {
        #expect(PlaybackSpeed.normal.next == .quick)
        #expect(PlaybackSpeed.double.next == .slower)
        #expect(PlaybackSpeed.slower.next == .normal)
        #expect(PlaybackSpeed.normal.previous == .slower)
        #expect(PlaybackSpeed(rawValue: 1.5) == .faster)
        #expect(PlaybackSpeed(rawValue: 2) == .double)
    }
}
