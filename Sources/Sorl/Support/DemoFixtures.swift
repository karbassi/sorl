import Foundation
import SorlCore

/// The design screens' data (`docs/design/panel-v2`), so each state can be reproduced and screenshotted next to its
/// PNG. Driven by `sorl://demo?screen=G2&hover=…`, which works only with the hidden `demoHarness` default on.
enum DemoFixtures {
    static let idPrefix = "demo-"

    enum Screen: String, CaseIterable {
        case f1, f1b, f2, f5, f6, f7, g1, g2, g3, g4, g5, g6, g7, g8, g9, s1
        /// F7 variants: the banner on the drawer (playback failed) and on F5.
        case f7drawer = "f7-drawer", f7f5 = "f7-f5", s1problem = "s1-problem"
    }

    static func item(_ title: String, _ duration: String? = nil, source: String? = "SOUND ISLAND sets") -> QueueItem {
        let id = demoID(title)
        return QueueItem(videoID: id, url: URL(string: "https://www.youtube.com/watch?v=\(id)")!, title: title,
                         duration: duration.map(seconds), source: source)
    }

    /// An 11-character id (what LinkParser accepts), stable per title: "demo-" plus a 6-character hash.
    static func demoID(_ title: String) -> String {
        var hash: UInt64 = 5381
        for byte in title.utf8 { hash = (hash &* 33) &+ UInt64(byte) }
        let digits = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        var out = ""
        for _ in 0..<6 { out.append(digits[Int(hash % 36)]); hash /= 36 }
        return idPrefix + out
    }

    static func seconds(_ clock: String) -> Double {
        clock.split(separator: ":").reduce(0) { $0 * 60 + (Double($1) ?? 0) }
    }

    static let current = item("Brothers Vibe - Guy J", "2:31:24")

    static let chapters = [
        Chapter(start: 0, end: seconds("6:12"), title: "Intro"),
        Chapter(start: seconds("6:12"), end: seconds("12:41"), title: "Afterglow"),
        Chapter(start: seconds("12:41"), end: seconds("21:05"), title: "Lost in the deep"),
        Chapter(start: seconds("21:05"), title: "Night swim"),
    ]

    static let played = [item("Warm-up at the pier", "1:02:10"), item("Sunset on the water", "1:20:45")]

    /// SOUND ISLAND sets, as G9 lists it (21 left).
    static let queue: [QueueItem] = [
        ("Target Demographic - Atmosphere", "1:58:02"), ("Sunday sessions vol. 4", "2:04:40"),
        ("Deep house at the lighthouse", "1:12:18"), ("Melodic set, sunrise edition", "2:31:09"),
        ("Afterhours, slow burn", "1:45:30"), ("Harbor lights, live", "1:33:12"), ("Rooftop session, part 2", "2:10:44"),
        ("Low tide", "58:20"), ("Coastline, extended", "1:21:05"), ("Warehouse at dawn", "2:02:51"),
        ("Slow mornings", "1:04:33"), ("Night market", "1:49:10"), ("Island time, vol. 2", "2:20:00"),
        ("Saltwater", "1:15:47"), ("Deep blue, after dark", "1:38:26"), ("Second wind", "1:27:03"),
        ("Lantern festival set", "2:12:39"), ("Northern pier", "1:09:58"), ("Last ferry home", "1:51:14"),
        ("Golden hour reprise", "1:44:02"), ("Closing set, SOUND ISLAND", "2:28:45"),
    ].map { item($0.0, $0.1) }

    static let downloadedTitles: Set<String> = [
        "Target Demographic - Atmosphere", "Deep house at the lighthouse", "Rooftop session, part 2", "Slow mornings",
        "How the transistor changed everything", "Deep focus, binaural",
    ]

    static var downloadedKeys: Set<String> {
        Set(downloadedTitles.map { item($0).cacheKey })
    }

    static func track(_ item: QueueItem, chapters: [Chapter] = []) -> Track {
        Track(id: item.videoID ?? "", title: item.title, channel: "Guy J", duration: item.duration,
              webpageURL: item.url, streamURL: URL(string: "https://example.invalid/\(item.videoID ?? "")")!,
              extractor: "youtube", chapters: chapters)
    }

    static let soundIsland = URL(string: "https://www.youtube.com/playlist?list=PLdemoSOUNDISLAND")!
    static let focusPlaylist = URL(string: "https://www.youtube.com/playlist?list=PLdemoFOCUS")!

    static func upNext(queue: [QueueItem] = queue, played: [QueueItem] = played, current: QueueItem? = current) -> UpNext {
        UpNext(current: current, upcoming: queue, played: played, sourceTitle: "SOUND ISLAND sets", sourceURL: soundIsland)
    }

    static func link(_ title: String, kind: LinkKind, _ trailing: String) -> (url: URL, title: String, kind: LinkKind, duration: Double?, count: Int?) {
        let i = item(title)
        let url: URL
        switch kind {
        case .video: url = i.url
        case .playlist: url = URL(string: "https://www.youtube.com/playlist?list=PL\(i.videoID ?? "")")!
        case .mix: url = URL(string: "https://www.youtube.com/watch?v=\(i.videoID ?? "")&list=RD\(i.videoID ?? "")")!
        }
        let count = trailing.hasSuffix("videos") ? Int(trailing.split(separator: " ")[0]) : nil
        return (url, title, kind, count == nil ? seconds(trailing) : nil, count)
    }

    /// G7, top to bottom. "no vocals deep house mix" is what's playing in G7, so its row is current.
    static var saved: SavedLinksStore {
        let rows = [
            link("Late night deep house", kind: .mix, "50 videos"), link("no vocals deep house mix", kind: .video, "2:31:24"),
            link("SOUND ISLAND sets", kind: .playlist, "21 videos"), link("Focus, no vocals", kind: .playlist, "112 videos"),
            link("How the transistor changed everything", kind: .video, "1:48:10"),
            link("Rainy day jazz", kind: .playlist, "64 videos"),
            link("Lecture: a short history of the internet", kind: .video, "1:12:40"),
            link("Ambient for reading", kind: .mix, "50 videos"), link("Deep focus, binaural", kind: .video, "3:00:00"),
            link("Coastline, extended", kind: .video, "1:21:05"), link("Weekend house classics", kind: .playlist, "88 videos"),
        ]
        var store = SavedLinksStore()
        let now = Date()
        for (i, row) in rows.enumerated().reversed() {
            // The SOUND ISLAND row is the playlist Up next came from, so its header says "Saved".
            store.save(url: row.title == "SOUND ISLAND sets" ? soundIsland : row.title == "Focus, no vocals" ? focusPlaylist : row.url, title: row.title, kind: row.kind, duration: row.duration, count: row.count,
                       date: now.addingTimeInterval(Double(-i)))
        }
        return store
    }

    /// G8: Today, Yesterday, Earlier this week, Last week, with the thumbnail bars.
    /// F6: "Piano for deep work" on the clipboard.
    static var pastePrompt: PastePrompt {
        let row = link("Piano for deep work", kind: .video, "58:12")
        return PastePrompt(text: row.url.absoluteString, kind: .video, videoID: demoID("Piano for deep work"),
                           title: row.title, duration: row.duration)
    }

    /// F5 shows "no vocals deep house mix" and "Late night deep house" on top (`pickUp`).
    static func recent(now: Date = Date(), pickUp: Bool = false) -> (store: RecentLinksStore, positions: [String: SavedPosition]) {
        let cal = Calendar.current
        func daysAgo(_ d: Int) -> Date { cal.date(byAdding: .day, value: -d, to: now)! }
        let week = cal.component(.weekday, from: now)
        let daysIntoWeek = (week - cal.firstWeekday + 7) % 7
        let earlierThisWeek = daysIntoWeek >= 2 ? daysAgo(2) : daysAgo(1)
        var rows: [((url: URL, title: String, kind: LinkKind, duration: Double?, count: Int?), Date, Double?, Bool)] = [
            (link("Brothers Vibe - Guy J", kind: .video, "2:31:24"), now, 923, false),
            (link("How the transistor changed everything", kind: .video, "1:48:10"), now.addingTimeInterval(-3600), 0.62, false),
            (link("Late night deep house", kind: .mix, "50 videos"), daysAgo(1), 0.12, false),
            (link("Sunday sessions vol. 4", kind: .video, "2:04:40"), daysAgo(1).addingTimeInterval(-60), nil, true),
            (link("Focus, no vocals", kind: .playlist, "112 videos"), earlierThisWeek, 0.3, false),
            (link("Piano for deep work", kind: .video, "58:12"), earlierThisWeek.addingTimeInterval(-60), nil, false),
            (link("Lecture: a short history of the internet", kind: .video, "1:12:40"), daysAgo(daysIntoWeek + 2), 0.45, false),
            (link("Rainy day jazz", kind: .playlist, "64 videos"), daysAgo(daysIntoWeek + 3), 0.2, false),
            (link("Harbor lights, live", kind: .video, "1:33:12"), daysAgo(daysIntoWeek + 4), 0.7, false),
        ]
        if pickUp {
            rows = [(link("no vocals deep house mix", kind: .video, "2:31:24"), now.addingTimeInterval(60), 0.09, false),
                    (link("Late night deep house", kind: .mix, "50 videos"), now.addingTimeInterval(30), 0.12, false)]
                + rows.filter { $0.0.title != "Late night deep house" }
        }
        var store = RecentLinksStore()
        var positions: [String: SavedPosition] = [:]
        for (row, date, progress, finished) in rows.reversed() {
            store.record(url: row.url, title: row.title, kind: row.kind, duration: row.duration, count: row.count, date: date)
            if finished { store.markFinished(row.url) }
            if let progress, let key = LinkParser.parse(row.url.absoluteString)?.cacheKey {
                let duration = row.duration ?? 3600
                let seconds = progress > 1 ? progress : progress * duration
                positions[key] = SavedPosition(seconds: seconds, duration: duration, updatedAt: date)
            }
        }
        return (store, positions)
    }

    /// The `sorl://demo` URL's screens and what each loads.
    struct State {
        var screen: Screen
        var track: Track?
        var upNext: UpNext
        var position: Double = seconds("15:23")
        var playing = true
        var ytdlpBroken = false
        var playbackFailed = false
    }

    static func state(for screen: Screen) -> State {
        let withChapters = track(current, chapters: chapters)
        let noChapters = track(current)
        switch screen {
        case .f1, .f1b, .f6, .f7, .s1, .s1problem, .f2:
            return State(screen: screen, track: withChapters, upNext: upNext(), ytdlpBroken: screen == .f7 || screen == .s1problem)
        case .g1, .g2, .g8, .g9:
            return State(screen: screen, track: noChapters, upNext: upNext())
        case .g7:
            // G7 marks "no vocals deep house mix" as playing while its mini player shows Brothers Vibe (AUDIT E3).
            return State(screen: screen, track: noChapters, upNext: upNext(current: item("no vocals deep house mix", "2:31:24")))
        case .f7drawer:
            return State(screen: screen, track: noChapters, upNext: upNext(), playbackFailed: true)
        case .g3:
            let added = item("How the transistor changed everything", "1:48:10", source: nil)
            return State(screen: screen, track: noChapters, upNext: upNext(queue: queue + [added]))
        case .g4:
            return State(screen: screen, track: noChapters, upNext: upNext(queue: []))
        case .g5:
            let now = item("How the transistor changed everything", "1:48:10", source: nil)
            return State(screen: screen, track: track(now), upNext: UpNext(current: now), position: seconds("4:02"))
        case .g6:
            let opening = item("Focus, no vocals: Opening", "47:10", source: "Focus, no vocals")
            let focus = [("Rain on the window, ambient", "58:12"), ("Slow mornings", "1:03:40"),
                         ("Piano for deep work", "2:00:00"), ("Low light, soft keys", "1:15:22")]
                .map { item($0.0, $0.1, source: "Focus, no vocals") }
            let more = (5...111).map { item("Focus track \($0)", "4:00", source: "Focus, no vocals") }
            let q = UpNext(current: opening, upcoming: focus + more, played: [current], sourceTitle: "Focus, no vocals",
                           sourceURL: focusPlaylist)
            return State(screen: screen, track: track(opening), upNext: q, position: 4)
        case .f5, .f7f5:
            return State(screen: screen, track: nil, upNext: UpNext(), position: 0, playing: false, ytdlpBroken: screen == .f7f5)
        }
    }
}
