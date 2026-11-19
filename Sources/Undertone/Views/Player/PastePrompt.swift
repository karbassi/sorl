import SwiftUI
import UndertoneCore

/// What ⌘V does depends on where you are:
/// - Player (F1): the F6 prompt.
/// - Up next: adds to the end; the toast offers "Play next instead".
/// - Saved or Recent: switches to Up next and adds to the end.
/// - Nothing playing (F5): plays now.
@MainActor
enum PasteRouter {
    static func handle(_ request: PasteRequest, engine: PlayerEngine, state: PanelState, toasts: ToastCenter) {
        if let mode = request.mode {
            perform(mode, text: request.text, engine: engine, toasts: toasts)
            return
        }
        guard !state.showingSettings else { return }
        if state.drawerOpen {
            if state.tab != .upNext { state.setDrawer(true, tab: .upNext) }
            UpNextActions.add(request.text, engine: engine, state: state, toasts: toasts)
        } else if engine.track != nil || engine.isResolving || engine.upNext.current != nil {
            prompt(request.text, engine: engine, state: state)
        } else {
            perform(.playNow, text: request.text, engine: engine, toasts: toasts)
        }
    }

    /// Shows F6 at once with what's known, then fills in the title and length.
    private static func prompt(_ text: String, engine: PlayerEngine, state: PanelState) {
        guard let link = LinkParser.parse(text) else { return }
        let kind: LinkKind = link.kind.isMix ? .mix : link.isPlaylist ? .playlist : .video
        let known = engine.knownTitle(for: link)
        let prompt = PastePrompt(text: text, kind: kind, videoID: link.videoID, title: known?.title, duration: known?.duration)
        state.pastePrompt = prompt
        guard known == nil, kind == .video else { return }
        Task {
            guard let found = await engine.lookup(link), state.pastePrompt?.id == prompt.id else { return }
            state.pastePrompt?.title = found.title
            state.pastePrompt?.duration = found.duration
        }
    }

    static func perform(_ mode: PlayerEngine.OpenMode, text: String, engine: PlayerEngine, toasts: ToastCenter) {
        engine.open(text, mode: mode) { result in
            switch result {
            case .replaced(let count, let snapshot) where count > 0:
                toasts.showUndo("Replaced \(count) in up next") { engine.restoreQueue(from: snapshot) }
            case .queued(let count, let title, let playlist, let mode, let snapshot):
                let message: String
                if let playlist {
                    message = mode == .playNext ? "\(count) videos from \(playlist) play next" : "Added \(count) videos from \(playlist) to the end"
                } else {
                    message = mode == .playNext ? "\(title) plays next" : "Added \(title) to the end"
                }
                toasts.showUndo(message) { engine.restoreQueue(from: snapshot) }
            case .alreadyPlaying:
                toasts.show("Already playing")
            case .failed:
                toasts.show(engine.errorMessage ?? "Couldn't play that")
                engine.clearError()
            case .playing, .replaced:
                break
            }
        }
    }
}

/// F6: the card over the player. Play now (Return), Play next, Add to end, Cancel (Esc or a click outside).
struct PastePromptCard: View {
    @Environment(PanelState.self) private var state
    let prompt: PastePrompt

    var body: some View {
        ZStack(alignment: .bottom) {
            Color(red: 20 / 255, green: 20 / 255, blue: 24 / 255).opacity(0.22)
                .contentShape(Rectangle())
                .onTapGesture { state.pastePrompt = nil }
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Thumbnail(url: Thumbnail.url(videoID: prompt.videoID), side: 40, radius: 8)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(prompt.title ?? "Looking up the link…")
                            .font(PanelStyle.title)
                            .foregroundStyle(PanelStyle.text)
                            .lineLimit(1)
                        Text(detail)
                            .font(.system(size: 11))
                            .foregroundStyle(PanelStyle.secondary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    SymbolButton(symbol: "xmark", label: "Cancel", size: 11, weight: .semibold, side: 26) {
                        state.pastePrompt = nil
                    }
                }
                HStack(spacing: 6) {
                    choice("Play now", primary: true, mode: .playNow)
                    choice("Play next", primary: false, mode: .playNext)
                    choice("Add to end", primary: false, mode: .addToEnd)
                }
                Text("Return plays now · Esc cancels")
                    .font(.system(size: 11))
                    .foregroundStyle(PanelStyle.tertiary)
            }
            .padding(12)
            .background(PanelStyle.drawerSurface, in: .rect(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.black.opacity(0.12), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.25), radius: 16, y: 12)
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("What should this link do?")
            .accessibilityAddTraits(.isModal)
        }
    }

    /// "Video · 58:12 · from your clipboard"
    private var detail: String {
        let kind = switch prompt.kind {
        case .video: "Video"
        case .playlist: "Playlist"
        case .mix: "Mix"
        }
        let length = prompt.duration.map { TimeFormat.clock($0) }
        return ([kind, length, "from your clipboard"] as [String?]).compactMap { $0 }.joined(separator: " · ")
    }

    private func choice(_ title: String, primary: Bool, mode: PlayerEngine.OpenMode) -> some View {
        Button {
            state.pastePrompt = nil
            state.pasteRequest = PasteRequest(text: prompt.text, mode: mode)
        } label: {
            Text(title)
                .font(PanelStyle.smallBold)
                .foregroundStyle(primary ? .white : PanelStyle.text)
                .frame(maxWidth: .infinity)
                .frame(height: 30)
                .background(primary ? PanelStyle.accent : PanelStyle.segmentTrack, in: .rect(cornerRadius: 8))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
