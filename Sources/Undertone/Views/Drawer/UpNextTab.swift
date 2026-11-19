import SwiftUI
import UndertoneCore

/// Up next (F2, G1–G5, G9): the current video's chapters when it has them, then the editable queue, with the paste
/// field pinned at the bottom.
struct UpNextTab: View {
    @Environment(PlayerEngine.self) private var engine
    @Environment(AppSettings.self) private var settings
    @Environment(PanelState.self) private var state
    @Environment(ToastCenter.self) private var toasts

    @State private var position = ScrollPosition()
    @State private var metrics = ScrollMetrics()
    @State private var drag: DragState?
    @State private var autoScroll: Task<Void, Never>?

    struct DragState {
        let id: QueueItem.ID
        let startIndex: Int
        let startScroll: CGFloat
        var translation: CGFloat = 0
        var pointerY: CGFloat = 0
    }

    private var queue: UpNext { engine.upNext }
    private var chapters: [Chapter] { engine.track?.chapters ?? [] }

    var body: some View {
        VStack(spacing: 10) {
            if chapters.isEmpty { queueHeader(inScroll: false) }
            ScrollingList(accessibilityLabel: chapters.isEmpty ? "Up next" : "Chapters and up next",
                          position: $position, metrics: $metrics) {
                if !chapters.isEmpty {
                    chapterSection
                    Rectangle().fill(.black.opacity(0.07)).frame(height: 1).padding(.horizontal, 6).padding(.vertical, 10)
                        .accessibilityHidden(true)
                    queueHeader(inScroll: true).padding(.bottom, 10)
                }
                if !queue.played.isEmpty { playedSection }
                if queue.isEmpty {
                    emptyMessage
                } else {
                    queueRows
                }
            }
            .coordinateSpace(.named(ListRow.dragSpace))
            InlineAddField()
                .padding(.horizontal, PanelStyle.drawerInset)
                .padding(.bottom, 16)
        }
        .onChange(of: queue.isEmpty) { _, empty in if !empty { state.queueCleared = false } }
        // A newly added row scrolls into view.
        .onChange(of: state.highlightedItem) { _, id in
            guard let id else { return }
            withAnimation(.snappy) { position.scrollTo(id: id, anchor: .bottom) }
        }
        .onAppear {
            if let id = state.highlightedItem { position.scrollTo(id: id, anchor: .bottom) }
        }
    }

    // MARK: Chapters (F2)

    private var chapterSection: some View {
        let current = engine.chapter.flatMap { c in chapters.firstIndex(of: c) }
        return VStack(alignment: .leading, spacing: 0) {
            SectionHeader(label: "In this video", detail: current.map { "chapter \($0 + 1) of \(chapters.count)" },
                          inset: false)
                .padding(.bottom, 10)
            ForEach(Array(chapters.enumerated()), id: \.offset) { index, chapter in
                ChapterRow(chapter: chapter, isCurrent: index == current) { engine.seek(to: chapter.start) }
            }
        }
    }

    // MARK: Header

    private func queueHeader(inScroll: Bool) -> some View {
        let source = queue.headerSource
        let label: String
        if queue.isEmpty {
            label = "Up next"
        } else if let source {
            label = inScroll ? "Then, from \(source)" : "From \(source)"
        } else {
            label = inScroll ? "Then" : "Up next"
        }
        return SectionHeader(label: label, detail: queue.isEmpty ? nil : "\(queue.upcoming.count) left", inset: !inScroll) {
            if source != nil, let saved = engine.savableQueue {
                let isSaved = engine.isQueueSaved
                TextButton(title: isSaved ? "Saved" : "Save playlist", tint: isSaved ? PanelStyle.secondary : PanelStyle.accent,
                           help: isSaved ? "In Saved. Click to remove" : "Save this \(engine.isMixLoaded ? "Mix" : "playlist")") {
                    toggleSavedPlaylist(saved.title)
                }
            }
            if !queue.isEmpty {
                TextButton(title: "Clear", help: "Clear up next") { clear() }
            }
        }
    }

    // MARK: Played

    private var playedSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                state.playedExpanded.toggle()
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .rotationEffect(.degrees(state.playedExpanded ? 90 : 0))
                        .frame(width: 13, height: 13)
                    Text("Played (\(queue.played.count))")
                        .font(PanelStyle.small)
                }
                .foregroundStyle(PanelStyle.secondary)
                .padding(.vertical, 4)
                .padding(.horizontal, 6)
                .frame(maxWidth: .infinity, minHeight: 23, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Played, \(queue.played.count)")
            .accessibilityValue(state.playedExpanded ? "Expanded" : "Collapsed")
            if state.playedExpanded {
                ForEach(queue.played) { item in
                    PlayedRow(title: item.title) { engine.playNow(item.copy()) }
                }
            }
        }
    }

    // MARK: Queue rows

    private var queueRows: some View {
        let items = queue.upcoming
        let target = dragTarget(count: items.count)
        return ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
            let isDragged = drag?.id == item.id
            ListRow(id: item.id.uuidString, title: item.title, thumbnail: Thumbnail.url(videoID: item.videoID),
                    trailing: item.duration.map { .text(TimeFormat.clock($0)) } ?? .none,
                    downloaded: engine.downloadedKeys.contains(item.cacheKey),
                    hoverActions: [.remove], reorderable: true, removeLabel: "Remove from up next",
                    onTap: { engine.playQueued(item.id) },
                    onRemove: { remove(item) },
                    onMoveUp: index > 0 ? { step(item, by: -1) } : nil,
                    onMoveDown: index < items.count - 1 ? { step(item, by: 1) } : nil,
                    hoverKey: item.cacheKey,
                    onDragChanged: { dragChanged(item, index: index, value: $0) },
                    onDragEnded: { dragEnded() },
                    isDragging: isDragged,
                    isHighlighted: state.highlightedItem == item.id)
                .offset(y: isDragged ? (drag?.translation ?? 0) : shift(for: index, target: target))
                .zIndex(isDragged ? 1 : 0)
                .animation(isDragged ? nil : .snappy(duration: 0.2), value: target)
                .id(item.id)
        }
    }

    @ViewBuilder private var emptyMessage: some View {
        if state.queueCleared {
            EmptyListMessage(title: "Nothing up next", message: "What's playing now keeps going.\nAdd a link, or pick something from Saved.")
        } else if engine.repeatMode == .one {
            EmptyListMessage(title: "Nothing up next", message: "This video repeats when it ends.\nAdd a link below, or pick something from Saved.")
        } else if engine.repeatMode == .all, !queue.played.isEmpty {
            EmptyListMessage(title: "Nothing up next", message: "Played videos start over when this one ends.\nAdd a link below, or pick something from Saved.")
        } else {
            EmptyListMessage(title: "Nothing up next", message: "Playback stops when this video ends.\nAdd a link below, or pick something from Saved.")
        }
    }

    // MARK: Actions

    private func remove(_ item: QueueItem) {
        let snapshot = engine.editQueue { $0.remove(item.id) }
        toasts.showUndo("Removed \(item.title) from up next") { engine.restoreQueue(from: snapshot) }
    }

    private func clear() {
        let count = queue.upcoming.count
        let snapshot = engine.editQueue { $0.clear() }
        state.queueCleared = true
        toasts.showUndo("Cleared \(count) from up next") {
            engine.restoreQueue(from: snapshot)
            state.queueCleared = false
        }
    }

    private func step(_ item: QueueItem, by delta: Int) {
        var landed: Int?
        let snapshot = engine.editQueue { landed = $0.move(item.id, by: delta) }
        if let landed { announceMove(item, to: landed, snapshot: snapshot) }
    }

    private func announceMove(_ item: QueueItem, to index: Int, snapshot: UpNext) {
        let message = index == 0 ? "\(item.title) plays next" : "Moved to \(index + 1) of \(queue.upcoming.count)"
        toasts.showUndo(message) { engine.restoreQueue(from: snapshot) }
    }

    private func toggleSavedPlaylist(_ name: String) {
        let before = settings.saved
        engine.toggleSavedQueue()
        let message = engine.isQueueSaved ? "Saved \(name)" : "Removed \(name) from Saved"
        toasts.showUndo(message) { settings.saved = before }
    }

    // MARK: Drag to reorder

    private func dragChanged(_ item: QueueItem, index: Int, value: DragGesture.Value) {
        if drag == nil {
            drag = DragState(id: item.id, startIndex: index, startScroll: metrics.offset)
            startAutoScroll()
        }
        drag?.pointerY = value.location.y
        updateTranslation(raw: value.location.y - value.startLocation.y)
    }

    @State private var rawTranslation: CGFloat = 0

    private func updateTranslation(raw: CGFloat? = nil) {
        guard var d = drag else { return }
        if let raw { rawTranslation = raw }
        d.translation = rawTranslation + (metrics.offset - d.startScroll)
        drag = d
    }

    private func dragTarget(count: Int) -> Int? {
        guard let d = drag, count > 0 else { return nil }
        let moved = Int((d.translation / PanelStyle.rowHeight).rounded())
        return max(0, min(count - 1, d.startIndex + moved))
    }

    /// Rows between the dragged row's start and its target make room for it.
    private func shift(for index: Int, target: Int?) -> CGFloat {
        guard let d = drag, let target else { return 0 }
        if d.startIndex < target, index > d.startIndex, index <= target { return -PanelStyle.rowHeight }
        if target < d.startIndex, index >= target, index < d.startIndex { return PanelStyle.rowHeight }
        return 0
    }

    private func dragEnded() {
        autoScroll?.cancel()
        autoScroll = nil
        guard let d = drag else { return }
        let target = dragTarget(count: queue.upcoming.count) ?? d.startIndex
        drag = nil
        rawTranslation = 0
        guard target != d.startIndex, let item = queue.upcoming.first(where: { $0.id == d.id }) else { return }
        var landed: Int?
        let snapshot = engine.editQueue { landed = $0.move(d.id, to: target) }
        if let landed { announceMove(item, to: landed, snapshot: snapshot) }
    }

    /// Holding the dragged row near the list's top or bottom edge scrolls the list.
    private func startAutoScroll() {
        autoScroll?.cancel()
        autoScroll = Task { @MainActor in
            while !Task.isCancelled, let d = drag {
                let edge: CGFloat = 36
                var delta: CGFloat = 0
                if d.pointerY < edge { delta = -max(2, (edge - d.pointerY) / 3) }
                if d.pointerY > metrics.viewport - edge { delta = max(2, (d.pointerY - (metrics.viewport - edge)) / 3) }
                let maxOffset = max(0, metrics.content - metrics.viewport)
                let next = max(0, min(maxOffset, metrics.offset + delta))
                if delta != 0, next != metrics.offset {
                    position.scrollTo(y: next)
                    metrics.offset = next
                    updateTranslation()
                }
                try? await Task.sleep(for: .milliseconds(16))
            }
        }
    }
}

/// A chapter: a 40pt timestamp column and the chapter's own name. The current one is highlighted; click seeks.
struct ChapterRow: View {
    let chapter: Chapter
    let isCurrent: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Text(TimeFormat.clock(chapter.start))
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(isCurrent ? PanelStyle.currentText : PanelStyle.secondary)
                    .frame(width: 40, alignment: .leading)
                Text(chapter.title)
                    .font(isCurrent ? PanelStyle.title : PanelStyle.row)
                    .foregroundStyle(isCurrent ? PanelStyle.currentText : PanelStyle.text)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 5)
            .padding(.horizontal, 6)
            .frame(height: 26)
            .background(isCurrent ? PanelStyle.currentRow : (hovering ? PanelStyle.hoverRow : .clear),
                        in: .rect(cornerRadius: PanelStyle.rowRadius))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onPanelHover { hovering = $0 }
        .accessibilityLabel("\(chapter.title), \(TimeFormat.clock(chapter.start))")
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
        .accessibilityHint("Plays from this chapter")
    }
}

/// The paste field pinned under Up next: paste and press Return, and it's added to the end.
struct InlineAddField: View {
    @Environment(PlayerEngine.self) private var engine
    @Environment(PanelState.self) private var state
    @Environment(ToastCenter.self) private var toasts
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "plus")
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(PanelStyle.tertiary)
                .frame(width: 14, height: 14)
                .accessibilityHidden(true)
            TextField("", text: $text, prompt: Text(focused ? "Paste a link, then press Return" : "Paste a link to add it")
                .foregroundStyle(PanelStyle.tertiary))
                .textFieldStyle(.plain)
                .font(PanelStyle.row)
                .focused($focused)
                .onSubmit(submit)
                .accessibilityLabel("Add a link to the end of up next")
            Text("⌘V")
                .font(PanelStyle.meta)
                .foregroundStyle(PanelStyle.quaternary)
                .accessibilityHidden(true)
        }
        .padding(.leading, 10)
        .padding(.trailing, 8)
        .frame(height: 34)
        .background(focused ? PanelStyle.fieldFill : .clear, in: .rect(cornerRadius: PanelStyle.rowRadius))
        .onChange(of: state.focusPasteField) { focused = true }
        .onAppear {
            // The field is the drawer's only text field, so it would take focus on open; only the + asks for that.
            let wanted = state.pendingPasteFocus
            state.pendingPasteFocus = false
            DispatchQueue.main.async { focused = wanted }
        }
    }

    private func submit() {
        let link = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !link.isEmpty else { return }
        text = ""
        UpNextActions.add(link, engine: engine, state: state, toasts: toasts)
    }
}

/// Adding a link to the end of Up next, from the paste field or ⌘V in the drawer: the toast offers Play next instead.
enum UpNextActions {
    static func add(_ link: String, engine: PlayerEngine, state: PanelState, toasts: ToastCenter) {
        engine.open(link, mode: .addToEnd) { result in
            switch result {
            case .queued(let count, let title, let playlist, _, let snapshot):
                let added = Array(engine.upNext.upcoming.suffix(count))
                state.highlight(added.last?.id)
                let message = playlist.map { count == 1 ? "Added 1 video from \($0) to the end" : "Added \(count) videos from \($0) to the end" }
                    ?? (count == 1 ? "Added to the end" : "Added \(title) to the end")
                toasts.show(message, actionTitle: "Play next instead") {
                    engine.restoreQueue(from: snapshot)
                    engine.editQueue { $0.insertNext(added) }
                }
            case .alreadyPlaying:
                toasts.show("Already playing")
            case .failed:
                toasts.show(engine.errorMessage ?? "Couldn't add that link")
                engine.clearError()
            case .playing, .replaced:
                break
            }
        }
    }
}
