import AppKit
import Observation
import SwiftUI

/// One-off notices: dark, one at a time, with at most one action (Undo, or Play next instead). A new toast replaces
/// the current one. They auto-dismiss, later under VoiceOver, and are announced.
@Observable
final class ToastCenter {
    struct Toast: Identifiable, Equatable {
        let id = UUID()
        let message: String
        let actionTitle: String?
        let action: (() -> Void)?

        static func == (a: Toast, b: Toast) -> Bool { a.id == b.id }
    }

    private(set) var current: Toast?
    @ObservationIgnored private var dismissTask: Task<Void, Never>?

    static let duration: Duration = .seconds(4)
    static let voiceOverDuration: Duration = .seconds(10)

    func show(_ message: String, actionTitle: String? = nil, action: (() -> Void)? = nil) {
        let toast = Toast(message: message, actionTitle: action == nil ? nil : actionTitle, action: action)
        current = toast
        let announcement = [message, toast.actionTitle].compactMap { $0 }.joined(separator: ". ")
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: announcement, .priority: NSAccessibilityPriorityLevel.high.rawValue])
        dismissTask?.cancel()
        let delay = NSWorkspace.shared.isVoiceOverEnabled ? Self.voiceOverDuration : Self.duration
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, self?.current?.id == toast.id else { return }
            self?.current = nil
        }
    }

    /// "… · Undo": the action runs, and a short confirmation is not shown (the change itself is the feedback).
    func showUndo(_ message: String, undo: @escaping () -> Void) {
        show(message, actionTitle: "Undo", action: undo)
    }

    func dismiss() {
        dismissTask?.cancel()
        current = nil
    }

    /// Runs the current toast's action and dismisses it (the button, and ⌘Z).
    func performAction() {
        guard let action = current?.action else { return }
        dismiss()
        action()
    }
}

/// The toast itself: 12pt white on #1d1d1f, 10pt radius, a soft shadow.
struct ToastView: View {
    let toast: ToastCenter.Toast
    let perform: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text(toast.message)
                .font(PanelStyle.small)
                .foregroundStyle(.white)
                .lineLimit(2)
            if let title = toast.actionTitle {
                Button(action: perform) {
                    Text(title)
                        .font(PanelStyle.smallBold)
                        .foregroundStyle(PanelStyle.toastAction)
                        .padding(.vertical, 4)
                        .padding(.horizontal, 6)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 8)
        .padding(.leading, 14)
        .padding(.trailing, toast.actionTitle == nil ? 14 : 8)
        .frame(minHeight: 39)
        .background(PanelStyle.toast, in: .rect(cornerRadius: 10))
        .shadow(color: .black.opacity(0.25), radius: 10, y: 6)
        .accessibilityElement(children: .contain)
    }
}

/// Places the current toast at the bottom of the view it modifies (just above a bottom pin, via `bottomInset`).
struct ToastHost: ViewModifier {
    let center: ToastCenter
    var bottomInset: CGFloat = 12
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.overlay(alignment: .bottom) {
            ZStack {
                if let toast = center.current {
                    ToastView(toast: toast) { center.performAction() }
                        .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                        .id(toast.id)
                }
            }
            .padding(.bottom, bottomInset)
            .animation(reduceMotion ? nil : .spring(duration: 0.25), value: center.current)
        }
    }
}

extension View {
    func toasts(_ center: ToastCenter, bottomInset: CGFloat = 12) -> some View {
        modifier(ToastHost(center: center, bottomInset: bottomInset))
    }
}
