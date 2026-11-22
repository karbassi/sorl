import Foundation
import Testing
@testable import SorlCore

@Suite struct PlaylistTests {
    @Test func decodesLinesAndSkipsGarbage() {
        let entries = PlaylistEntry.decodeLines(Data(Fixtures.playlistLines.utf8))
        #expect(entries.count == 4)
        #expect(entries[0].title == "Keynote — Blender Conference 2025")
        #expect(entries[0].duration == 1508)
        #expect(entries[0].playlistTitle == "Blender Conference 2025")
        #expect(entries[2].isAvailable == false)
        #expect(entries[3].url.absoluteString == "https://www.youtube.com/watch?v=thirdVideo1")
    }

    @Test func replaceSkipsUnavailableAndStartsAtVideo() {
        let entries = PlaylistEntry.decodeLines(Data(Fixtures.playlistLines.utf8))
        var q = UpNext()
        let first = q.replace(with: entries, title: nil, sourceURL: nil, isMix: false, startVideoID: "hFzg41j68hg")
        #expect(first?.videoID == "hFzg41j68hg")
        #expect(q.sourceTitle == "Blender Conference 2025")
        #expect(q.upcoming.map(\.videoID) == ["thirdVideo1"])   // entries before the start are left out
        #expect(q.advance()?.videoID == "thirdVideo1")
        #expect(q.advance() == nil)
        #expect(q.goBack()?.videoID == "hFzg41j68hg")
    }

    @Test func replaceStartsAtIndexWhenNoVideo() {
        let entries = PlaylistEntry.decodeLines(Data(Fixtures.playlistLines.utf8))
        func start(_ v: String?, _ i: Int?) -> String? {
            var q = UpNext()
            return q.replace(with: entries, title: nil, sourceURL: nil, isMix: false, startVideoID: v, startIndex: i)?.videoID
        }
        #expect(start(nil, 42) == entries[0].id)
        #expect(start("missing", 2) == "hFzg41j68hg")
        var empty = UpNext()
        #expect(empty.replace(with: [], title: nil, sourceURL: nil, isMix: false) == nil)
    }

    @Test func indexCountsTheFullPlaylistNotJustPlayableEntries() {
        // Fixture order: available, available, [Private video], available. `index=4` must land on the 4th
        // entry (the one after the private video); `index=3` points at the private video itself: the next playable.
        let entries = PlaylistEntry.decodeLines(Data(Fixtures.playlistLines.utf8))
        var q = UpNext()
        #expect(q.replace(with: entries, title: nil, sourceURL: nil, isMix: false, startIndex: 4)?.videoID == "thirdVideo1")
        #expect(q.replace(with: entries, title: nil, sourceURL: nil, isMix: false, startIndex: 3)?.videoID == "thirdVideo1")
    }
}
