import SwiftUI
import UndertoneCore

/// The player (F1, F1b), 304pt. Calm at rest: artwork, title, subtitle, the scrubber, the time and previous,
/// play/pause and next. The star, ±15, the knob, the footer and the bar's + fade in on hover or keyboard focus,
/// by opacity only, so nothing moves.
struct PlayerView: View {
    @Environment(PlayerEngine.self) private var engine
    @Environment(PanelState.self) private var state
    @Environment(YTDLPService.self) private var service
    @State private var hovering = false

    private var revealed: Bool { hovering || state.forcedHover == "player" }
    private var banner: Bool { ProblemBanner.isShowing(engine: engine, service: service) }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 18) {
                NowPlayingHeader(revealed: revealed)
                PlayerScrubber(revealed: revealed)
                TransportControls(revealed: revealed)
            }
            .padding(EdgeInsets(top: 18, leading: 20, bottom: 0, trailing: 20))
            .frame(height: 211, alignment: .top)
            PlaybackFooter(revealed: revealed)
                .frame(height: 40)
            ProblemBanner()
            Spacer(minLength: 0)
            UpNextBar(revealed: revealed)
        }
        .frame(width: PanelStyle.width, height: PanelStyle.playerHeight + (banner ? PanelStyle.bannerHeight + 8 : 0))
        .contentShape(Rectangle())
        .onPanelHover { hovering = $0 }
        .overlay {
            if let prompt = state.pastePrompt {
                PastePromptCard(prompt: prompt)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: state.pastePrompt?.id)
    }
}

/// 64pt artwork, the video title (14pt semibold), the subtitle, and the star (revealed).
struct NowPlayingHeader: View {
    @Environment(PlayerEngine.self) private var engine
    @Environment(AppSettings.self) private var settings
    @Environment(ToastCenter.self) private var toasts
    let revealed: Bool

    var body: some View {
        HStack(spacing: 14) {
            Thumbnail(url: Thumbnail.url(videoID: engine.upNext.current?.videoID ?? engine.track?.id) ?? engine.track?.artworkURL,
                      side: 64, radius: 12)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(PanelStyle.playerTitle)
                    .foregroundStyle(PanelStyle.text)
                    .lineLimit(1)
                Text(subtitle)
                    .font(PanelStyle.small)
                    .foregroundStyle(PanelStyle.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            let saved = engine.isTrackSaved
            SymbolButton(symbol: saved ? "star.fill" : "star", label: saved ? "Remove from Saved" : "Save", size: 17,
                         weight: .regular, side: 24, tint: saved ? PanelStyle.accent : PanelStyle.text) { toggleSaved() }
                .frame(height: 32)
                .revealed(revealed || saved)
                .disabled(engine.track == nil)
        }
        .frame(height: 64)
        .accessibilityElement(children: .contain)
    }

    private var title: String {
        engine.track?.title ?? engine.resolvingTitle ?? engine.upNext.current?.title ?? "Nothing playing"
    }

    /// The current chapter when the video has chapters, otherwise the playlist or source, otherwise the channel.
    private var subtitle: String {
        if engine.isResolving { return "Loading…" }
        if let chapter = engine.chapter, engine.skipsByChapter { return chapter.title }
        if let source = engine.upNext.current?.source { return source }
        return engine.track?.channel ?? ""
    }

    /// The star always saves the video playing, even inside a playlist.
    private func toggleSaved() {
        let before = settings.saved
        engine.toggleSavedTrack()
        let message = engine.isTrackSaved ? "Added to Saved" : "Removed from Saved"
        toasts.showUndo(message) { settings.saved = before }
    }
}

/// ⏮ (−15) ▶︎ (+15) ⏭: ±15 are revealed. ⏮/⏭ step through chapters first.
struct TransportControls: View {
    @Environment(PlayerEngine.self) private var engine
    let revealed: Bool

    var body: some View {
        let chapters = engine.skipsByChapter
        HStack(spacing: 22) {
            SymbolButton(symbol: "backward.end", label: chapters ? "Previous chapter" : "Previous", size: 17,
                         weight: .regular, side: 32, tint: PanelStyle.text) { engine.previous() }
            SymbolButton(symbol: "arrow.counterclockwise", label: "Back 15 seconds", size: 16, weight: .regular, side: 32,
                         tint: PanelStyle.text) { engine.skip(by: -15) }
                .revealed(revealed)
            PlayPauseButton(diameter: 52, glyph: 20)
            SymbolButton(symbol: "arrow.clockwise", label: "Forward 15 seconds", size: 16, weight: .regular, side: 32,
                         tint: PanelStyle.text) { engine.skip(by: 15) }
                .revealed(revealed)
            SymbolButton(symbol: "forward.end", label: chapters ? "Next chapter" : "Next", size: 17, weight: .regular,
                         side: 32, tint: PanelStyle.text) { engine.next() }
                .disabled(!engine.hasNext)
                .opacity(engine.hasNext ? 1 : 0.35)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 52)
        .disabled(engine.track == nil && engine.upNext.current == nil)
    }
}

/// Speed, repeat, volume and the Settings gear, all revealed.
struct PlaybackFooter: View {
    @Environment(PlayerEngine.self) private var engine
    @Environment(PanelState.self) private var state
    let revealed: Bool

    var body: some View {
        HStack(spacing: 8) {
            SpeedPill()
            RepeatToggle()
            Spacer(minLength: 0)
            PlayerVolume()
            SymbolButton(symbol: "gearshape", label: "Settings", size: 15, weight: .regular, side: 28) {
                state.showSettings(true)
            }
        }
        .padding(.leading, 20)
        .padding(.trailing, 14)
        .revealed(revealed)
    }
}

/// Click steps up (1, 1.25, 1.5, 1.75, 2, 0.75), Option-click or scrolling steps down, double-click resets to 1×.
struct SpeedPill: View {
    @Environment(PlayerEngine.self) private var engine

    var body: some View {
        let normal = engine.speed == .normal
        Text(engine.speed.label)
            .font(PanelStyle.smallBold.monospacedDigit())
            .foregroundStyle(.white)
            .padding(.horizontal, 9)
            .frame(minWidth: 40, minHeight: 26)
            .background(Capsule().fill(normal ? Color(hex: 0x6B6B6B) : PanelStyle.accent))
            .contentShape(Capsule())
            .gesture(TapGesture(count: 2).onEnded { engine.setSpeed(.normal) }
                .exclusively(before: TapGesture().modifiers(.option).onEnded { engine.cycleSpeedDown() }
                    .exclusively(before: TapGesture().onEnded { engine.cycleSpeed() })))
            .onScrollWheel { delta in delta > 0 ? engine.cycleSpeed() : engine.cycleSpeedDown() }
            .help("Speed. Click for faster, Option-click for slower, double-click for 1×")
            .accessibilityElement()
            .accessibilityLabel("Playback speed")
            .accessibilityValue(engine.speed.label)
            .accessibilityAddTraits(.isButton)
            .accessibilityAdjustableAction { direction in
                direction == .increment ? engine.cycleSpeed() : engine.cycleSpeedDown()
            }
            .accessibilityAction { engine.cycleSpeed() }
    }
}

/// Off → all → one; the tooltip names the mode, and it's tinted while on.
struct RepeatToggle: View {
    @Environment(PlayerEngine.self) private var engine

    var body: some View {
        let mode = engine.repeatMode
        SymbolButton(symbol: mode.symbolName, label: mode.label, size: 15, weight: .medium, side: 32,
                     tint: mode.isOn ? PanelStyle.accent : PanelStyle.secondary) { engine.cycleRepeatMode() }
            .accessibilityLabel("Repeat")
            .accessibilityValue(mode.accessibilityValue)
    }
}

struct PlayerVolume: View {
    @Environment(PlayerEngine.self) private var engine

    var body: some View {
        HStack(spacing: 8) {
            SymbolButton(symbol: engine.isMuted || engine.volume == 0 ? "speaker.slash" : "speaker.wave.1", label: engine.isMuted ? "Unmute" : "Mute",
                         size: 13, weight: .regular, side: 16) { engine.toggleMute() }
            ThinSlider(value: Double(engine.effectiveVolume)) { engine.setVolume(Float($0)) }
                .frame(width: 72)
                .accessibilityLabel("Volume")
        }
    }
}

/// A 4pt track with a gray fill; click or drag anywhere on it.
struct ThinSlider: View {
    let value: Double
    let onChange: (Double) -> Void

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.primary.opacity(0.12))
                Capsule().fill(PanelStyle.secondary).frame(width: proxy.size.width * min(1, max(0, value)))
            }
            .frame(height: 4)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { onChange(min(1, max(0, $0.location.x / proxy.size.width))) })
        }
        .frame(height: 16)
        .accessibilityValue("\(Int(value * 100)) percent")
        .accessibilityAdjustableAction { direction in onChange(min(1, max(0, value + (direction == .increment ? 0.1 : -0.1)))) }
    }
}

/// The bar under the player: a grabber, "Up next" and the next title. Click opens the drawer; + (revealed) opens it
/// with the paste field focused.
struct UpNextBar: View {
    @Environment(PlayerEngine.self) private var engine
    @Environment(PanelState.self) private var state
    let revealed: Bool

    var body: some View {
        ZStack(alignment: .trailing) {
            Button { state.setDrawer(true, tab: .upNext) } label: {
                VStack(spacing: 6) {
                    Capsule().fill(PanelStyle.grabber).frame(width: 36, height: 5)
                    HStack(spacing: 8) {
                        Text("Up next")
                            .font(PanelStyle.smallBold)
                            .foregroundStyle(PanelStyle.strong)
                        Text(engine.upNext.next?.title ?? "Nothing")
                            .font(PanelStyle.small)
                            .foregroundStyle(PanelStyle.secondary)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.up")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(PanelStyle.secondary)
                            .frame(width: 14, height: 14)
                    }
                    .padding(.trailing, 30)
                }
                .padding(EdgeInsets(top: 6, leading: 20, bottom: 10, trailing: 20))
                .frame(maxWidth: .infinity, minHeight: 52)
                .background(UnevenRoundedRectangle(topLeadingRadius: 16, topTrailingRadius: 16).fill(PanelStyle.segmentTrack))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open up next")
            .accessibilityValue(engine.upNext.next.map { "Next: \($0.title)" } ?? "Nothing up next")
            SymbolButton(symbol: "plus", label: "Add a link", size: 14, weight: .medium, side: 28, tint: PanelStyle.text) {
                state.openPasteField()
            }
            .padding(.trailing, 12)
            .padding(.top, 6)
            .revealed(revealed)
        }
        .frame(height: 52)
    }
}

extension View {
    /// Scroll-wheel steps: positive is up. One step per gesture tick, ignoring momentum.
    func onScrollWheel(_ action: @escaping (CGFloat) -> Void) -> some View {
        background(ScrollWheelCatcher(action: action))
    }
}

private struct ScrollWheelCatcher: NSViewRepresentable {
    let action: (CGFloat) -> Void

    func makeNSView(context: Context) -> WheelView {
        let view = WheelView()
        view.action = action
        return view
    }

    func updateNSView(_ view: WheelView, context: Context) { view.action = action }

    final class WheelView: NSView {
        var action: ((CGFloat) -> Void)?
        private var accumulated: CGFloat = 0

        override func scrollWheel(with event: NSEvent) {
            guard event.momentumPhase == [] else { return }
            accumulated += event.scrollingDeltaY
            let threshold: CGFloat = event.hasPreciseScrollingDeltas ? 12 : 1
            guard abs(accumulated) >= threshold else { return }
            action?(accumulated)
            accumulated = 0
        }
    }
}
