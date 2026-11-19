import AppKit
import SwiftUI
import UndertoneCore

/// Nothing playing (F5): the first screen people see, and what comes back after the last item finishes.
/// A paste field with Play, then "Pick up where you left off" with the two most recent items.
struct NothingPlayingView: View {
    @Environment(PlayerEngine.self) private var engine
    @Environment(AppSettings.self) private var settings
    @Environment(PanelState.self) private var state
    @Environment(ToastCenter.self) private var toasts

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 0) {
                    Text("Play something from YouTube")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(PanelStyle.text)
                        .accessibilityAddTraits(.isHeader)
                    Spacer(minLength: 0)
                    SymbolButton(symbol: "gearshape", label: "Settings", size: 15, weight: .regular, side: 32) {
                        state.showSettings(true)
                    }
                    .padding(.trailing, -8)
                }
                .frame(height: 32)
                VStack(alignment: .leading, spacing: 8) {
                    PasteField()
                    Text("Or press ⌘V anywhere in the panel.")
                        .font(.system(size: 11))
                        .foregroundStyle(PanelStyle.secondary)
                }
            }
            let recent = Array(settings.recent.items.prefix(2))
            if !recent.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Pick up where you left off")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(PanelStyle.secondary)
                        .accessibilityAddTraits(.isHeader)
                    VStack(spacing: 0) {
                        ForEach(recent) { item in
                            row(item)
                        }
                    }
                    .padding(.horizontal, -8)
                }
            }
        }
        .padding(20)
        .frame(width: PanelStyle.width, alignment: .leading)
    }

    private func row(_ item: RecentLink) -> some View {
        let entry = LibraryEntry(item)
        let saved = settings.positions.position(for: item.url)
        let progress: ListRow.Progress = item.finished ? .finished
            : .position(saved.map { $0.duration > 0 ? $0.seconds / $0.duration : 0 } ?? 0)
        return ListRow(id: item.id, title: item.title, thumbnail: Thumbnail.url(for: item.url),
                       trailing: item.trailingText.map { .text($0) } ?? .none,
                       downloaded: entry.isDownloaded(in: engine), progress: progress,
                       onTap: {
                           LibraryActions.play(entry, engine: engine, toasts: toasts, resume: saved?.seconds,
                                               finished: item.finished)
                       },
                       roomy: true)
    }
}

/// "Paste a video, playlist or Mix link" and Play. Play with an empty field plays the link on the clipboard.
/// A playlist or Mix replaces Up next (with Undo).
struct PasteField: View {
    @Environment(PlayerEngine.self) private var engine
    @Environment(YTDLPService.self) private var service
    @Environment(PanelState.self) private var state
    @Environment(ToastCenter.self) private var toasts
    @FocusState private var focused: Bool

    var body: some View {
        @Bindable var state = state
        HStack(spacing: 6) {
            TextField("Link", text: $state.urlText, prompt: Text("Paste a video, playlist or Mix link"))
                .labelsHidden()
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($focused)
                .onSubmit(submit)
            Button(action: submit) {
                Text("Play")
                    .font(PanelStyle.smallBold)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .frame(height: 28)
                    .background(PanelStyle.accent, in: .rect(cornerRadius: 7))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!service.status.isUsable)
            .opacity(service.status.isUsable ? 1 : 0.5)
            .help(state.urlText.isEmpty ? "Play the link on the clipboard" : "Play this link")
        }
        .padding(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 6))
        .frame(height: 44)
        .background(PanelStyle.drawerSurface, in: .rect(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.primary.opacity(0.08)))
        .onChange(of: state.urlText) { _, text in engine.warm(text) }
    }

    private func submit() {
        var text = state.urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            text = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        guard !text.isEmpty else { return }
        state.urlText = ""
        focused = false
        PasteRouter.perform(.playNow, text: text, engine: engine, toasts: toasts)
    }
}
