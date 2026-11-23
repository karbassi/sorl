import SwiftUI
import SorlCore

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
        let duration = engine.shownDuration ?? 0
        let shown = dragValue ?? min(engine.shownTime, max(duration, 0))
        let fraction = duration > 0 ? min(1, max(0, shown / duration)) : 0
        VStack(spacing: 4) {
            GeometryReader { proxy in
                let width = proxy.size.width - inset * 2
                // A fraction's spot on the track; the ends stretch to the row's own edges, so a full band is a capsule.
                let x = { (f: Double) -> CGFloat in f <= 0 ? 0 : f >= 1 ? proxy.size.width : inset + width * f }
                ZStack(alignment: .leading) {
                    // The cache band: how much of the video is saved for next time, filled from the start, plus what
                    // AVPlayer has buffered. A faint knob-tall band under the track, like YouTube's buffer bar. Once the
                    // whole file is on disk it would only be a full-width capsule, so it fades out and the ⤓ says it.
                    Group {
                        let cached = engine.cacheState.fraction
                        if cached < 1 {
                            if cached > 0 { band(from: 0, to: x(cached)) }
                            ForEach(Array(engine.bufferedRanges.enumerated()), id: \.offset) { _, range in
                                band(from: x(range.lowerBound), to: x(range.upperBound))
                            }
                        }
                    }
                    .animation(.easeOut(duration: 0.3), value: engine.cacheState)
                    .accessibilityHidden(true)
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
            .disabled(duration <= 0 || engine.isResolving || engine.track == nil)
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

    private func band(from: CGFloat, to: CGFloat) -> some View {
        Capsule().fill(.primary.opacity(0.035))
            .frame(width: max(0, to - from), height: 18)
            .offset(x: from)
    }

    /// "15 minutes 4 seconds of 2 hours 31 minutes", plus "buffering" while stalled.
    private func accessibilityValue(shown: Double, duration: Double) -> String {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .full
        formatter.allowedUnits = [.hour, .minute, .second]
        let position = formatter.string(from: max(0, shown)) ?? ""
        var value = duration > 0 ? "\(position) of \(formatter.string(from: duration) ?? "")" : position
        if engine.isBuffering && !engine.isResolving {
            value += ", buffering"
        } else if let status = CacheGlyph.status(engine) {
            value += ", \(status.label.lowercased())"
        }
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

/// The cache glyph by the time. While the copy for next time downloads, a gray ↓ with the share saved; once the
/// whole video is on disk, the blue ⤓ the rows use for "downloaded". The two differ in shape, not only colour.
struct CacheGlyph: View {
    @Environment(PlayerEngine.self) private var engine

    struct Status: Equatable {
        let label: String
        let symbol: String
        let downloaded: Bool
    }

    /// Nil while nothing is saved yet (the first 20 seconds, another site, a file too large to cache).
    static func status(_ engine: PlayerEngine) -> Status? {
        guard engine.track != nil, !engine.isResolving else { return nil }
        switch engine.cacheState {
        case .cached, .playingFromCache:
            return Status(label: "Downloaded · plays offline", symbol: "arrow.down.to.line", downloaded: true)
        case .caching(let fraction) where fraction > 0:
            return Status(label: "Streaming · \(Int(fraction * 100))% saved for next time", symbol: "arrow.down",
                          downloaded: false)
        case .caching, .none:
            return nil
        }
    }

    var body: some View {
        if let status = Self.status(engine) {
            Image(systemName: status.symbol)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(status.downloaded ? AnyShapeStyle(PanelStyle.accent) : AnyShapeStyle(PanelStyle.secondary))
                .frame(width: 12, height: 12)
                .help(status.label)
                .accessibilityLabel(status.label)
        }
    }
}
