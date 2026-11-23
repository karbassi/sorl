import Foundation
import Testing
@testable import SorlCore

@Suite struct DroppedLinkTests {
    @Test func takesAURLFromTheAddressBar() {
        let link = DroppedLink.link(from: ["https://www.youtube.com/watch?v=dQw4w9WgXcQ"])
        #expect(link?.videoID == "dQw4w9WgXcQ")
    }

    @Test func takesPlainTextThatIsALink() {
        #expect(DroppedLink.link(from: ["  youtu.be/dQw4w9WgXcQ\n"])?.videoID == "dQw4w9WgXcQ")
        #expect(DroppedLink.link(from: ["https://soundcloud.com/artist/track"])?.kind == .other)
    }

    @Test func refusesWhatSorlCannotPlay() {
        #expect(DroppedLink.link(from: []) == nil)
        #expect(DroppedLink.link(from: ["", "   "]) == nil)
        #expect(DroppedLink.link(from: ["just some words"]) == nil)
        #expect(DroppedLink.link(from: ["file:///Users/someone/song.mp3"]) == nil)
        #expect(DroppedLink.link(from: ["mailto:someone@example.com"]) == nil)
        // A paragraph that mentions a link is not a link.
        #expect(DroppedLink.link(from: ["watch this https://youtu.be/dQw4w9WgXcQ later"]) == nil)
    }

    @Test func skipsUnplayableCandidatesForALaterOne() {
        let link = DroppedLink.link(from: ["file:///tmp/a.txt", "https://youtu.be/dQw4w9WgXcQ"])
        #expect(link?.videoID == "dQw4w9WgXcQ")
    }

    @Test func readsWeblocFiles() throws {
        let plist = ["URL": "https://www.youtube.com/watch?v=dQw4w9WgXcQ"]
        for format in [PropertyListSerialization.PropertyListFormat.xml, .binary] {
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: format, options: 0)
            let url = DroppedLink.weblocURL(from: data)
            #expect(url == "https://www.youtube.com/watch?v=dQw4w9WgXcQ")
            #expect(DroppedLink.link(from: [try #require(url)])?.videoID == "dQw4w9WgXcQ")
        }
        #expect(DroppedLink.weblocURL(from: Data("not a plist".utf8)) == nil)
        let noURL = try PropertyListSerialization.data(fromPropertyList: ["Other": "x"], format: .xml, options: 0)
        #expect(DroppedLink.weblocURL(from: noURL) == nil)
    }
}
