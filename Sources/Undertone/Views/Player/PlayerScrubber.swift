import SwiftUI
import UndertoneCore

/// The scrubber (F1): a 6pt track with the accent fill, the cache band behind it, and a knob that fades in on hover.
/// Under it: elapsed on the left; the rest marks, the cache glyph and the remaining (or total) time on the right.
struct PlayerScrubber: View {
    @Environment(PlayerEngine.self) private var engine
    @Environment(AppSettings.self) private var settings
    let revealed: Bool
    @State private var dragValue: Double?

    /// The track's inset inside the 300pt row, so the knob never leaves it.
    private let inset: CGFloat = 13

    var body: some View {
        let duration = engine.duration ?? 0
        let shown = dragValue ?? min(engine.currentTime, max(duration, 0))
        let fraction = duration > 0 ? min(1, max(0, shown / duration)) : 0
        VStack(spacing: 4) {
            GeometryReader { proxy in
                let width = proxy.size.width - inset * 2
                ZStack(alignment: .leading) {
                    // The cache band: how much of the video is saved for next time. Hidden until the cache state
                    // lands (cache-bar-status); the slot keeps its place.
                    if let cached = cachedFraction {
                        Capsule().fill(.primary.opacity(0.035))
                            .frame(width: proxy.size.width * cached, height: 18)
                    }
                    Capsule().fill(.primary.opacity(0.14))
                        .frame(width: width, height: 6)
                        .offset(x: inset)
                    Capsule().fill(PanelStyle.accent)
                        .frame(width: max(6, width * fraction), height: 6)
                        .offset(x: inset)
                    Capsule().fill(.white)
                        .frame(width: 26, height: 18)
                        .shadow(color: .black.opacity(0.3), radius: 1.5, y: 1)
                        .overlay(Capsule().strokeBorder(.black.opacity(0.12), lineWidth: 0.5))
                        .offset(x: inset + width * fraction - 13)
                        .opacity(revealed || dragValue != nil ? 1 : 0)
                }
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard duration > 0 else { return }
                        dragValue = min(1, max(0, (value.location.x - inset) / width)) * duration
                    }
                    .onEnded { _ in
                        if let value = dragValue { engine.seek(to: value) }
                        dragValue = nil
                    })
            }
            .frame(height: 24)
            .disabled(duration <= 0 || engine.isResolving)
            .accessibilityElement()
            .accessibilityLabel("Playback position")
            .accessibilityValue(accessibilityValue(shown: shown, duration: duration))
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: engine.skip(by: 15)
                case .decrement: engine.skip(by: -15)
                @unknown default: break
                }
            }
            HStack(spacing: 4) {
                Text(TimeFormat.clock(shown))
                    .accessibilityHidden(true)
                if engine.isBuffering && !engine.isResolving {
                    Text("Buffering…").padding(.leading, 6)
                }
                Spacer(minLength: 0)
                RestMarks(revealed: revealed)
                CacheGlyph()
                Button { settings.showTotalTime.toggle() } label: {
                    Text(settings.showTotalTime ? TimeFormat.clock(duration) : TimeFormat.remaining(shown, of: duration))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(settings.showTotalTime ? "Click to show time left" : "Click to show total time")
                .accessibilityLabel(settings.showTotalTime ? "Total time" : "Time left")
                .accessibilityHint(settings.showTotalTime ? "Shows time left" : "Shows total time")
            }
            .font(PanelStyle.meta)
            .foregroundStyle(PanelStyle.secondary)
            .frame(height: 13)
        }
    }

    /// The share of the video saved for next time. Nil until the cache-bar-status API lands.
    private var cachedFraction: Double? { nil }

    /// "15 minutes 4 seconds of 2 hours 31 minutes", plus "buffering" while stalled.
    private func accessibilityValue(shown: Double, duration: Double) -> String {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .full
        formatter.allowedUnits = [.hour, .minute, .second]
        let position = formatter.string(from: max(0, shown)) ?? ""
        var value = duration > 0 ? "\(position) of \(formatter.string(from: duration) ?? "")" : position
        if engine.isBuffering && !engine.isResolving { value += ", buffering" }
        return value
    }
}

/// At rest, a non-default repeat or speed shows as a small blue mark beside the time; on hover the footer shows the
/// real controls, so the marks fade out.
struct RestMarks: View {
    @Environment(PlayerEngine.self) private var engine
    let revealed: Bool

    var body: some View {
        let mode = engine.repeatMode
        let speed = engine.speed
        if mode.isOn || speed != .normal {
            HStack(spacing: 4) {
                if speed != .normal {
                    Text(speed.label).font(.system(size: 11, weight: .semibold).monospacedDigit())
                }
                if mode.isOn {
                    Image(systemName: mode.symbolName)
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 12, height: 12)
                }
            }
            .foregroundStyle(PanelStyle.accent)
            .opacity(revealed ? 0 : 1)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel([mode.isOn ? "Repeat is on" : nil, speed != .normal ? "Speed \(speed.label)" : nil]
                .compactMap { $0 }.joined(separator: ", "))
        }
    }
}

/// The cache glyph by the time: shown once the playing video is downloaded and plays offline. The streaming and
/// caching states come with the cache-bar-status API.
struct CacheGlyph: View {
    @Environment(PlayerEngine.self) private var engine

    var body: some View {
        if let key = engine.upNext.current?.cacheKey ?? engine.track?.id, engine.downloadedKeys.contains(key) {
            Image(systemName: "arrow.down.to.line")
                .font(.system(size: 10, weight: .medium))
                .frame(width: 12, height: 12)
                .help("Downloaded, plays offline")
                .accessibilityLabel("Downloaded, plays offline")
        }
    }
}
