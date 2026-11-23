import SwiftUI
import SorlCore

/// The SwiftUI content of the panel: one page at a time, each at a fixed height.
///
/// - Settings and the drawer are 560pt (less on a short screen).
/// - The player is 304pt.
/// - Nothing playing (F5) takes its natural height.
struct PanelRoot: View {
    let engine: PlayerEngine
    let settings: AppSettings
    let service: YTDLPService
    let state: PanelState
    @State private var toasts = ToastCenter()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .top) {
            if state.showingSettings {
                page(height: PanelStyle.drawerHeight) { SettingsView() }
                    .transition(sheetTransition)
                    .zIndex(1)   // above the player as it fades in, so the drop back down shows
            } else if state.drawerOpen {
                page(height: PanelStyle.drawerHeight) { DrawerPage() }
                    .transition(sheetTransition)
                    .zIndex(1)   // above the player as it fades in, so the drop back down shows
            } else if engine.track != nil || engine.isResolving || engine.upNext.current != nil {
                page(height: PanelStyle.playerHeight + (ProblemBanner.isShowing(engine: engine, service: service) ? PanelStyle.bannerHeight + 8 : 0)) {
                    PlayerView().toasts(toasts, bottomInset: 60)
                }
                    .transition(.opacity)
            } else {
                page(height: nil) { NothingPlayingView().toasts(toasts) }
                    .transition(.opacity)
            }
        }
        // The window is sized to the page; pinning it to the top keeps any transient mismatch at the bottom.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // The background sits behind the ZStack, not in it: as a sibling it was drawn over the outgoing page, blanking
        // the panel as a sheet opened. It and the mask follow the window at once rather than on the page spring, so
        // the window growing for a sheet shows no bare glass at the bottom while the sheet rises.
        .background { PanelStyle.panelBackground.transaction { $0.animation = nil } }
        .mask {
            RoundedRectangle(cornerRadius: PanelController.cornerRadius, style: .continuous)
                .transaction { $0.animation = nil }
        }
        .environment(engine)
        .environment(settings)
        .environment(service)
        .environment(state)
        .environment(toasts)
        .environment(\.forcedHover, state.forcedHover)
        .onChange(of: state.demoToast?.id) {
            guard let toast = state.demoToast else { return }
            toasts.show(toast.message, actionTitle: toast.action, action: toast.action == nil ? nil : {})
        }
        // One-off notices (a skipped video, no Mix found) are toasts.
        .onChange(of: engine.notice) {
            guard let notice = engine.notice else { return }
            toasts.show(notice)
            engine.clearNotice()
        }
        .onChange(of: state.pasteRequest) {
            guard let request = state.pasteRequest else { return }
            state.pasteRequest = nil
            PasteRouter.handle(request, engine: engine, state: state, toasts: toasts)
        }
        .onChange(of: state.drawerOpen) {
            if state.demoScreen == nil { toasts.dismiss() }   // the demo harness shows its toast with the drawer
            if state.drawerOpen { state.pastePrompt = nil }
        }
        .onChange(of: state.showingSettings) { toasts.dismiss() }
    }

    /// Settings and the drawer rise from the bottom, solid, and drop back down as they fade; the player and Nothing
    /// playing beneath them only cross-fade. With Reduce Motion everything cross-fades.
    private var sheetTransition: AnyTransition {
        reduceMotion ? .opacity : .asymmetric(
            insertion: .move(edge: .bottom),
            removal: .move(edge: .bottom).combined(with: .opacity)
        )
    }

    /// A page at a fixed `height` (capped to what fits on the screen), or its natural height when nil. Reports its
    /// size so the window follows.
    @ViewBuilder
    private func page<Content: View>(height: CGFloat?, @ViewBuilder _ content: () -> Content) -> some View {
        Group {
            if let height {
                content()
                    .frame(width: PanelStyle.width, height: min(height, state.maxContentHeight), alignment: .top)
            } else {
                ScrollView(.vertical) {
                    content().frame(width: PanelStyle.width)
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(width: PanelStyle.width)
                .frame(maxHeight: state.maxContentHeight)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .background(PanelStyle.panelBackground)
        .onGeometryChange(for: CGSize.self) { proxy in
            proxy.size
        } action: { size in
            state.controller?.contentSizeChanged(size)
        }
    }
}
