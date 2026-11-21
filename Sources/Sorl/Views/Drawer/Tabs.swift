import SwiftUI
import SorlCore

/// Saved (G7): one flat list of videos, playlists and Mixes. Click plays now, + adds to Up next, × removes.
struct SavedTab: View {
    @Environment(AppSettings.self) private var settings
    @Environment(PlayerEngine.self) private var engine
    @Environment(ToastCenter.self) private var toasts

    var body: some View {
        VStack(spacing: 10) {
            SectionHeader(hint: "Click to play. **+** adds to up next.")
            if settings.saved.items.isEmpty {
                EmptyListMessage(title: "Nothing saved yet", message: "Click the star on what's playing to keep it here.")
                Spacer()
            } else {
                ScrollingList(accessibilityLabel: "Saved, \(settings.saved.items.count) items") {
                    ForEach(settings.saved.items) { item in
                        let entry = LibraryEntry(item)
                        let current = entry.isPlaying(in: engine)
                        ListRow(id: item.id, title: item.title, thumbnail: Thumbnail.url(for: item.url),
                                trailing: current ? .nowPlaying : (item.trailingText.map { .text($0) } ?? .none),
                                downloaded: entry.isDownloaded(in: engine), isCurrent: current,
                                hoverActions: [.add, .remove], removeLabel: "Remove from Saved",
                                onTap: { LibraryActions.play(entry, engine: engine, toasts: toasts) },
                                onAdd: { LibraryActions.add(entry, engine: engine, toasts: toasts) },
                                onRemove: { remove(item) },
                                hoverKey: entry.key)
                    }
                }
            }
        }
    }

    private func remove(_ item: SavedLink) {
        let before = settings.saved
        settings.saved.remove(item.url)
        toasts.showUndo("Removed \(item.title) from Saved") { settings.saved = before }
    }
}

/// Recent (G8): what played, in date groups, with a progress bar on each thumbnail. Click resumes.
struct RecentTab: View {
    @Environment(AppSettings.self) private var settings
    @Environment(PlayerEngine.self) private var engine
    @Environment(ToastCenter.self) private var toasts

    var body: some View {
        VStack(spacing: 10) {
            SectionHeader(hint: "Click to resume. **+** adds to up next.") {
                if !settings.recent.items.isEmpty {
                    TextButton(title: "Clear", help: "Clear recent history") { clear() }
                }
            }
            if settings.recent.items.isEmpty {
                EmptyListMessage(title: "Nothing played yet", message: "Videos you play show up here,\nso you can pick up where you left off.")
                Spacer()
            } else {
                ScrollingList(accessibilityLabel: "Recent, \(settings.recent.items.count) items") {
                    ForEach(settings.recent.grouped(), id: \.group) { group in
                        Text(group.group.title)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(PanelStyle.tertiary)
                            .padding(EdgeInsets(top: 8, leading: 6, bottom: 2, trailing: 6))
                            .frame(height: 23, alignment: .bottomLeading)
                            .accessibilityAddTraits(.isHeader)
                        ForEach(group.items) { item in
                            row(item)
                        }
                    }
                }
            }
        }
    }

    private func row(_ item: RecentLink) -> some View {
        let entry = LibraryEntry(item)
        let current = entry.isPlaying(in: engine)
        return ListRow(id: item.id, title: item.title, thumbnail: Thumbnail.url(for: item.url),
                       trailing: current ? .nowPlaying : (item.trailingText.map { .text($0) } ?? .none),
                       downloaded: entry.isDownloaded(in: engine), progress: progress(item, current: current),
                       isCurrent: current, hoverActions: [.add, .remove], removeLabel: "Remove from Recent",
                       onTap: {
                           LibraryActions.play(entry, engine: engine, toasts: toasts,
                                               resume: settings.positions.position(for: item.url)?.seconds, finished: item.finished)
                       },
                       onAdd: { LibraryActions.add(entry, engine: engine, toasts: toasts) },
                       onRemove: { remove(item) },
                       hoverKey: entry.key)
    }

    /// The thumbnail bar: the live position for what's playing, the saved one otherwise, full gray once finished.
    private func progress(_ item: RecentLink, current: Bool) -> ListRow.Progress? {
        if item.finished && !current { return .finished }
        if current, let duration = engine.duration, duration > 0 { return .position(engine.currentTime / duration) }
        guard let saved = settings.positions.position(for: item.url), saved.duration > 0 else { return .position(0) }
        return .position(saved.seconds / saved.duration)
    }

    private func remove(_ item: RecentLink) {
        let before = settings.recent
        settings.recent.remove(item.url)
        toasts.showUndo("Removed \(item.title) from Recent") { settings.recent = before }
    }

    private func clear() {
        let before = settings.recent
        settings.recent.clear()
        toasts.showUndo("Cleared recent history") { settings.recent = before }
    }
}

/// A Saved or Recent row's link, whatever it is.
struct LibraryEntry {
    let url: URL
    let title: String
    let kind: LinkKind
    let duration: Double?
    let count: Int?

    init(_ saved: SavedLink) {
        url = saved.url; title = saved.title; kind = saved.resolvedKind; duration = saved.duration; count = saved.count
    }

    init(_ recent: RecentLink) {
        url = recent.url; title = recent.title; kind = recent.resolvedKind; duration = recent.duration; count = recent.count
    }

    var link: MediaLink? { LinkParser.parse(url.absoluteString) }
    var key: String? { link?.cacheKey }

    /// "Now playing": a video that is the current item.
    func isPlaying(in engine: PlayerEngine) -> Bool {
        guard kind == .video, let key, let current = engine.upNext.current?.cacheKey ?? engine.track?.id else { return false }
        return key == current
    }

    func isDownloaded(in engine: PlayerEngine) -> Bool {
        kind == .video && key.map { engine.downloadedKeys.contains($0) } == true
    }

    var queueItem: QueueItem? {
        guard let link else { return nil }
        return QueueItem(videoID: link.videoID, url: link.resolvedURL, title: title, duration: duration)
    }
}

/// What a click or + does on a Saved or Recent row.
enum LibraryActions {
    /// A video plays now and the interrupted one moves to Played; Up next is kept. A playlist or Mix replaces Up next.
    /// Recent resumes at the saved position, and a finished video starts over.
    static func play(_ entry: LibraryEntry, engine: PlayerEngine, toasts: ToastCenter, resume: Double? = nil, finished: Bool = false) {
        guard !entry.isPlaying(in: engine) else { return }
        if entry.kind == .video, let item = entry.queueItem {
            engine.playNow(item, startAt: finished ? 0 : resume)
            if finished { toasts.show("Playing \(entry.title) from the start") }
            return
        }
        engine.open(entry.url.absoluteString, mode: .playNow) { result in
            if case .replaced(let count, let snapshot) = result, count > 0 {
                toasts.showUndo("Replaced \(count) in up next") { engine.restoreQueue(from: snapshot) }
            } else if case .failed = result {
                toasts.show(engine.errorMessage ?? "Couldn't play that")
                engine.clearError()
            }
        }
    }

    /// + : adds the video, or every video of the playlist or Mix, to the end of Up next.
    static func add(_ entry: LibraryEntry, engine: PlayerEngine, toasts: ToastCenter) {
        engine.open(entry.url.absoluteString, mode: .addToEnd) { result in
            switch result {
            case .queued(let count, let title, let playlist, _, let snapshot):
                let message = playlist.map { "Added \(count) videos from \($0) to up next" } ?? "Added \(title) to up next"
                toasts.showUndo(message) { engine.restoreQueue(from: snapshot) }
            case .alreadyPlaying:
                toasts.show("Already playing")
            case .failed:
                toasts.show(engine.errorMessage ?? "Couldn't add that")
                engine.clearError()
            case .playing, .replaced:
                break
            }
        }
    }
}
