import AppKit
import SwiftUI

/// Hover tracking that works while Undertone is inactive. The panel is a non-activating `NSPanel`, so SwiftUI's
/// `.onHover` can miss events; an `NSTrackingArea` with `.activeAlways` does not.
struct HoverTracker: NSViewRepresentable {
    let onChange: (Bool) -> Void

    func makeNSView(context: Context) -> TrackingView {
        let view = TrackingView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ view: TrackingView, context: Context) {
        view.onChange = onChange
    }

    final class TrackingView: NSView {
        var onChange: ((Bool) -> Void)?
        private var area: NSTrackingArea?
        private var inside = false

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let area { removeTrackingArea(area) }
            let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                      owner: self, userInfo: nil)
            addTrackingArea(area)
            self.area = area
            // A view that appears under a resting pointer gets no mouseEntered; check where the pointer is now.
            if let window {
                let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
                set(bounds.contains(point))
            }
        }

        override func mouseEntered(with event: NSEvent) { set(true) }
        override func mouseExited(with event: NSEvent) { set(false) }
        // Clicks pass through to the SwiftUI controls on top.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { set(false) }
        }

        private func set(_ value: Bool) {
            guard value != inside else { return }
            inside = value
            onChange?(value)
        }
    }
}

/// Forces hover on, for the demo harness (`undertone://demo?…&hover=…`): "player" or a row's id.
private struct ForcedHoverKey: EnvironmentKey {
    static let defaultValue: String? = nil
}

extension EnvironmentValues {
    var forcedHover: String? {
        get { self[ForcedHoverKey.self] }
        set { self[ForcedHoverKey.self] = newValue }
    }
}

extension View {
    /// Reports whether the pointer is over this view, even while the app is inactive.
    func onPanelHover(_ action: @escaping (Bool) -> Void) -> some View {
        background(HoverTracker(onChange: action))
    }

    /// Shows the view only while `revealed`, by opacity alone so the layout never shifts. No fade under Reduce Motion.
    func revealed(_ revealed: Bool) -> some View {
        modifier(RevealModifier(revealed: revealed))
    }
}

private struct RevealModifier: ViewModifier {
    let revealed: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(revealed ? 1 : 0)
            .allowsHitTesting(revealed)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: revealed)
    }
}
