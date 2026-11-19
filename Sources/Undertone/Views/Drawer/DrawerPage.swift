import SwiftUI
import UndertoneCore

/// The drawer: the mini player pinned on top, then a white surface holding the grabber (click to close), the tabs,
/// the tab's section header and its scrolling list.
struct DrawerPage: View {
    @Environment(PanelState.self) private var state
    @Environment(ToastCenter.self) private var toasts

    var body: some View {
        VStack(spacing: 0) {
            MiniPlayerHeader()
            VStack(spacing: 10) {
                Grabber(label: "Close drawer") { state.setDrawer(false) }
                DrawerTabs()
                tabContent
                    .frame(maxHeight: .infinity, alignment: .top)
            }
            .padding(.top, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(DrawerSurface())
            // Toasts sit just above the bottom pin: Up next's paste field, else the drawer's edge.
            .toasts(toasts, bottomInset: state.tab == .upNext ? 62 : 16)
        }
    }

    @ViewBuilder private var tabContent: some View {
        switch state.tab {
        case .upNext: UpNextTab()
        case .saved: SavedTab()
        case .recent: RecentTab()
        }
    }
}

/// White, 16pt top corners, a hairline and a soft shadow upward.
struct DrawerSurface: View {
    var body: some View {
        UnevenRoundedRectangle(topLeadingRadius: PanelStyle.drawerRadius, topTrailingRadius: PanelStyle.drawerRadius)
            .fill(PanelStyle.drawerSurface)
            .shadow(color: .black.opacity(0.06), radius: 0, y: -1)
            .shadow(color: .black.opacity(0.06), radius: 12, y: -8)
    }
}

/// The 36×5 grabber; the whole 60×16 strip is the button.
struct Grabber: View {
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Capsule()
                .fill(PanelStyle.grabber)
                .frame(width: 36, height: 5)
                .frame(width: 60, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }
}

/// The pinned mini player: 40pt artwork, title, "15:23 of 2:31:24", a 36pt play/pause and next.
struct MiniPlayerHeader: View {
    @Environment(PlayerEngine.self) private var engine

    var body: some View {
        HStack(spacing: 12) {
            Thumbnail(url: Thumbnail.url(videoID: engine.upNext.current?.videoID ?? engine.track?.id), side: 40, radius: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(engine.track?.title ?? engine.resolvingTitle ?? engine.upNext.current?.title ?? "Nothing playing")
                    .font(PanelStyle.title)
                    .foregroundStyle(PanelStyle.text)
                    .lineLimit(1)
                Text(timeText)
                    .font(PanelStyle.meta)
                    .foregroundStyle(PanelStyle.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            PlayPauseButton(diameter: 36, glyph: 11)
            SymbolButton(symbol: "forward.end", label: engine.skipsByChapter ? "Next chapter" : "Next", size: 16,
                         weight: .regular, side: 32, tint: PanelStyle.text) { engine.next() }
                .disabled(!engine.hasNext)
                .opacity(engine.hasNext ? 1 : 0.35)
        }
        .padding(EdgeInsets(top: 14, leading: 20, bottom: 12, trailing: 14))
        .frame(height: 66)
    }

    private var timeText: String {
        if engine.isResolving { return "Loading…" }
        guard let duration = engine.duration else { return TimeFormat.clock(engine.currentTime) }
        return "\(TimeFormat.clock(engine.currentTime)) of \(TimeFormat.clock(duration))"
    }
}

/// The blue play/pause circle (52pt in the player, 36pt in the mini player).
struct PlayPauseButton: View {
    @Environment(PlayerEngine.self) private var engine
    let diameter: CGFloat
    let glyph: CGFloat

    var body: some View {
        Button { engine.togglePlayPause() } label: {
            Image(systemName: engine.isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: glyph, weight: .bold))
                .foregroundStyle(.white)
                .offset(x: engine.isPlaying ? 0 : glyph * 0.08)
                .frame(width: diameter, height: diameter)
                .background(Circle().fill(PanelStyle.accent))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(engine.isPlaying ? "Pause" : "Play")
        .accessibilityLabel(engine.isPlaying ? "Pause" : "Play")
    }
}

/// The segmented control: Up next / Saved / Recent.
struct DrawerTabs: View {
    @Environment(PanelState.self) private var state
    @Namespace private var thumb

    var body: some View {
        HStack(spacing: 2) {
            ForEach(PanelState.Tab.allCases) { tab in
                let selected = state.tab == tab
                Button {
                    state.tab = tab
                } label: {
                    Text(tab.title)
                        .font(PanelStyle.smallBold)
                        .foregroundStyle(PanelStyle.strong)
                        .frame(maxWidth: .infinity, minHeight: 27)
                        .background {
                            if selected {
                                RoundedRectangle(cornerRadius: 7)
                                    .fill(PanelStyle.segmentThumb)
                                    .shadow(color: .black.opacity(0.18), radius: 0.75, y: 0.5)
                                    .matchedGeometryEffect(id: "thumb", in: thumb)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? [.isSelected] : [])
            }
        }
        .padding(2)
        .background(PanelStyle.segmentTrack, in: .rect(cornerRadius: 9))
        .padding(.horizontal, PanelStyle.drawerInset)
        .animation(.snappy(duration: 0.2), value: state.tab)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Drawer tabs")
    }
}

/// A tab's header row: a bold label with a gray count, or a plain hint, and up to two text buttons on the right.
/// The label truncates before the buttons do.
struct SectionHeader<Trailing: View>: View {
    var label: String?
    var detail: String?
    var hint: String?
    /// False inside a scrolling list, which already insets its content.
    var inset = true
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 0) {
            Group {
                if let hint {
                    Text(LocalizedStringKey(hint))
                        .foregroundStyle(PanelStyle.secondary)
                } else {
                    Text("\(Text(label ?? "").fontWeight(.bold).foregroundStyle(PanelStyle.strong))\(Text(detail.map { " · \($0)" } ?? "").foregroundStyle(PanelStyle.secondary))")
                }
            }
            .font(.system(size: 11))
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 0) { trailing() }
                .fixedSize()
        }
        .padding(.leading, 6)
        .frame(height: inset ? 28 : 24)
        .padding(.horizontal, inset ? PanelStyle.drawerInset : 0)
    }
}

extension SectionHeader where Trailing == EmptyView {
    init(label: String? = nil, detail: String? = nil, hint: String? = nil, inset: Bool = true) {
        self.init(label: label, detail: detail, hint: hint, inset: inset) { EmptyView() }
    }
}
