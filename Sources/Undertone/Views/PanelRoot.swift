import SwiftUI
import UndertoneCore

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
            PanelStyle.panelBackground
            if state.showingSettings {
                page(height: PanelStyle.drawerHeight) { SettingsView() }
                    .transition(pageTransition(from: .trailing))
            } else if state.drawerOpen {
                page(height: PanelStyle.drawerHeight) { DrawerPage() }
                    .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
            } else {
                page(height: nil) { MainView() }
                    .transition(pageTransition(from: .leading))
            }
        }
        // The window is sized to the page; pinning it to the top keeps any transient mismatch at the bottom.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .clipShape(.rect(cornerRadius: PanelController.cornerRadius))
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
        .onChange(of: state.drawerOpen) { toasts.dismiss() }
        .onChange(of: state.showingSettings) { toasts.dismiss() }
    }

    /// Pages slide in from the side; with Reduce Motion they only cross-fade.
    private func pageTransition(from edge: Edge) -> AnyTransition {
        reduceMotion ? .opacity : .move(edge: edge).combined(with: .opacity)
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
