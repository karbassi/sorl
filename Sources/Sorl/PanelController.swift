import AppKit
import KeyboardShortcuts
import os
import SwiftUI
import SorlCore

/// Borderless, non-activating panel that can still take keyboard focus (needed for the URL field).
final class GlassPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// UI state shared between the AppKit panel and its SwiftUI content.
@Observable
final class PanelState {
    var showingSettings = false
    var urlText = ""
    /// Incremented on each show so views can react (focus the field, refresh clipboard).
    var showCount = 0
    /// The tallest the content may be on the current screen; taller pages scroll inside the panel.
    var maxContentHeight: CGFloat = .infinity
    /// The demo harness screen on show (`sorl://demo`), or nil for the real panel.
    var demoScreen: DemoFixtures.Screen?
    /// Forces hover on, for screenshots of hover states: "player" or a row's title.
    var forcedHover: String?
    /// A toast for the demo harness to show (message, action title).
    var demoToast: (message: String, action: String?, id: UUID)?
    @ObservationIgnored weak var controller: PanelController?

    /// The drawer's tabs.
    enum Tab: String, CaseIterable, Identifiable {
        case upNext = "up-next", saved, recent
        var id: String { rawValue }
        var title: String {
            switch self {
            case .upNext: return "Up next"
            case .saved: return "Saved"
            case .recent: return "Recent"
            }
        }
    }

    /// The drawer (mini player + tabs) is open over the player.
    var drawerOpen = false
    var tab: Tab = .upNext
    /// Bumped to focus Up next's paste field (the + on the Up next bar).
    var focusPasteField = 0
    /// "Played (n)" expanded in Up next.
    var playedExpanded = false
    /// Up next was emptied with Clear (G4's copy), until something is queued again.
    var queueCleared = false
    /// The row just added, marked briefly (G3).
    var highlightedItem: QueueItem.ID?
    /// Focus the paste field once the drawer appears.
    var pendingPasteFocus = false
    /// A Settings shortcut chip is listening for keys; the panel's own keys stand aside.
    var recordingShortcut = false
    /// The F6 card on the player: what should this link do?
    var pastePrompt: PastePrompt?
    /// A ⌘V (mode nil: decided by where you are) or an F6 choice, for `PasteRouter` to carry out.
    var pasteRequest: PasteRequest?
    @ObservationIgnored private var highlightTask: Task<Void, Never>?

    func highlight(_ id: QueueItem.ID?) {
        highlightedItem = id
        highlightTask?.cancel()
        highlightTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.3)) { self?.highlightedItem = nil }
        }
    }

    /// The + on the Up next bar: opens the drawer on Up next with the paste field focused.
    func openPasteField() {
        pendingPasteFocus = true
        setDrawer(true, tab: .upNext)
        tab = .upNext
        focusPasteField += 1
    }

    func hide() { controller?.hide() }

    /// Switches pages with the slide, telling the controller when the exiting page is really gone.
    func showSettings(_ flag: Bool) {
        guard flag != showingSettings else { return }
        transition { showingSettings = flag }
    }

    /// Opens or closes the drawer; it grows the panel to the drawer height.
    func setDrawer(_ open: Bool, tab: Tab? = nil) {
        if let tab { self.tab = tab }
        guard open != drawerOpen else { return }
        transition { drawerOpen = open }
    }

    private func transition(_ change: () -> Void) {
        controller?.pageTransitionWillStart()
        withAnimation(.spring(PanelController.pageSpring), completionCriteria: .removed) {
            change()
        } completion: { [weak controller] in
            controller?.pageTransitionEnded()
        }
    }
}

/// The link F6 asks about, with what is known of it so far.
struct PastePrompt: Equatable, Identifiable {
    let id = UUID()
    let text: String
    let kind: LinkKind
    var videoID: String?
    var title: String?
    var duration: Double?
}

struct PasteRequest: Equatable {
    let id = UUID()
    let text: String
    let mode: PlayerEngine.OpenMode?
}

final class PanelController {
    static let width: CGFloat = 340
    static let cornerRadius: CGFloat = 22
    /// Transparent margin around the glass that holds the soft shadow; the window is that much larger than the content.
    static let shadowInsets = NSEdgeInsets(top: 20, left: 30, bottom: 40, right: 30)

    let state = PanelState()
    private(set) var isVisible = false
    weak var statusButton: NSStatusBarButton?

    private let panel: GlassPanel
    private let hosting: NSHostingView<PanelRoot>
    private let settings: AppSettings
    private let engine: PlayerEngine
    private let cloudSync: CloudSync
    private var contentSize = CGSize(width: PanelController.width, height: 220)
    private var globalMonitor: Any?
    private var localMouseMonitor: Any?
    private var localKeyMonitor: Any?
    private var spaceObserver: NSObjectProtocol?
    private let log = Logger(subsystem: "com.karbassi.sorl", category: "panel")
    private var resizeObserver: NSObjectProtocol?
    private var lastSetFrame = NSRect.zero
    private var reapplyingFrame = false
    /// Holds the shadow, surface and SwiftUI views (laid out with constraints). Sized by hand, never by Auto Layout.
    private weak var container: NSView?
    private var frameAnimation: Timer?
    private var pageTransitionActive = false
    private var transitionFallback: DispatchWorkItem?
    /// Duration of the page slide.
    static let pageTransition: TimeInterval = 0.25
    /// The page slide's curve. The window's shrink follows it too, so its bottom edge moves with the sheet.
    static let pageSpring = Spring.snappy(duration: pageTransition)

    init(settings: AppSettings, engine: PlayerEngine, service: YTDLPService, cloudSync: CloudSync) {
        self.settings = settings
        self.engine = engine
        self.cloudSync = cloudSync
        panel = GlassPanel(
            contentRect: NSRect(origin: .zero, size: Self.windowSize(for: contentSize)),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.isFloatingPanel = true          // must precede `level`: it resets the level to .floating
        panel.level = .popUpMenu
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.isMovable = true
        panel.isMovableByWindowBackground = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // The window-server shadow hugs the window's rectangle, not the rounded glass, which showed as a thin box
        // around the corners. PanelShadowView draws one that follows the glass instead.
        panel.hasShadow = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.titleVisibility = .hidden

        hosting = NSHostingView(rootView: PanelRoot(engine: engine, settings: settings, service: service, state: state, cloudSync: cloudSync))
        hosting.sizingOptions = []
        state.controller = self
        rebuildBackdrop()
        // AppKit may resize the window itself from Auto Layout (`_changeWindowFrameFromConstraintsIfNecessary`) when
        // some required constraint in the content view disagrees with the frame. Nothing here should, but if it ever
        // happens, put the frame back once instead of leaving the panel misplaced.
        resizeObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: panel, queue: nil) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.lastSetFrame != .zero, !self.reapplyingFrame else { return }
                let frame = self.panel.frame
                guard abs(frame.width - self.lastSetFrame.width) > 1 || abs(frame.height - self.lastSetFrame.height) > 1 else { return }
                self.log.debug("window resized by Auto Layout to \(NSStringFromRect(frame), privacy: .public); restoring \(NSStringFromRect(self.lastSetFrame), privacy: .public)")
                self.reapplyingFrame = true
                DispatchQueue.main.async {
                    self.panel.setFrame(self.lastSetFrame, display: true)
                    self.reapplyingFrame = false
                }
            }
        }
    }

    private func setPanelFrame(_ frame: NSRect) {
        lastSetFrame = frame
        container?.frame = NSRect(origin: .zero, size: frame.size)
        panel.setFrame(frame, display: true)
    }

    // MARK: - Show / hide

    func toggle() {
        if isVisible { hide() } else { show() }
    }

    func show(settings showSettings: Bool = false) {
        let button = statusButton ?? NSStatusBarButton()
        let wasVisible = isVisible
        isVisible = true
        rebuildBackdrop()   // works around a stale-glass bug seen on 26.2
        if wasVisible {
            state.showSettings(showSettings)   // slides, like tapping the gear or Back
        } else {
            // The panel is fading in anyway: switch pages without the slide so the size is right from the first frame.
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { state.showingSettings = showSettings }
        }
        // A link on the clipboard is resolved in the background, so ⌘V or Play plays it at once.
        if let link = Self.clipboardLink() { engine.warm(link) }
        cloudSync.fetchNow()   // throttled to once a minute; a no-op with sync off
        state.showCount += 1
        cancelFrameAnimation()
        position(relativeTo: button)
        if wasVisible {
            panel.makeKeyAndOrderFront(nil)
            return
        }
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.14
            panel.animator().alphaValue = 1
        }
        installMonitors()
        engine.setProgressTracking(true)
    }

    /// Shows the panel on a demo harness screen.
    func showDemo(_ screen: DemoFixtures.Screen, hover: String?) {
        state.demoScreen = screen
        state.forcedHover = hover
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            switch screen {
            case .f2, .g1, .g2, .g3, .g4, .g5, .g6, .g9, .f7drawer: state.drawerOpen = true; state.tab = .upNext
            case .g7: state.drawerOpen = true; state.tab = .saved
            case .g8: state.drawerOpen = true; state.tab = .recent
            default: state.drawerOpen = false
            }
            state.playedExpanded = false
            state.pastePrompt = screen == .f6 ? DemoFixtures.pastePrompt : nil
            state.queueCleared = screen == .g4
            state.highlightedItem = nil
        }
        if screen == .g3 { state.highlight(engine.upNext.upcoming.last?.id) }
        let toast: (String, String?)? = switch screen {
        case .g3: ("Added to the end", "Play next instead")
        case .g4: ("Cleared 21 from up next", "Undo")
        case .g6: ("Replaced 21 in up next", "Undo")
        default: nil
        }
        state.demoToast = toast.map { ($0.0, $0.1, UUID()) }
        show(settings: screen == .s1 || screen == .s1problem)
    }

    /// The clipboard, when it holds exactly one link (no spaces or line breaks).
    static func clipboardLink() -> String? {
        guard let raw = NSPasteboard.general.string(forType: .string) else { return nil }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 400, !text.contains(where: { $0 == " " || $0.isNewline || $0 == "\t" }),
              LinkParser.parse(text) != nil else { return nil }
        return text
    }

    /// `sorl://drawer?tab=saved`: opens the drawer on a tab.
    func showDrawer(tab: PanelState.Tab) {
        if !isVisible { show() }
        state.setDrawer(true, tab: tab)
        state.tab = tab
    }

    func hide() {
        guard isVisible else { return }
        isVisible = false
        engine.setProgressTracking(false)
        removeMonitors()
        cancelFrameAnimation()
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.1
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                // A show() during the fade-out must win; otherwise this would hide the freshly shown panel.
                guard let self, !self.isVisible else { return }
                self.panel.orderOut(nil)
            }
        })
    }

    /// Called by the SwiftUI root whenever a page's size changes; keeps the top edge anchored under the icon.
    func contentSizeChanged(_ size: CGSize) {
        guard size.width > 0, size.height > 0, size != contentSize else { return }
        let shrinking = size.height < contentSize.height
        contentSize = size
        cancelFrameAnimation()
        // Growing happens at once so an entering page has room to slide in. Shrinking during a page switch starts with
        // it, on the slide's own curve, so the bottom edge comes down with the sheet instead of after it. The exiting
        // sheet keeps its fixed height, top-anchored and clipped by the glass, while the window contracts around it.
        applyContentSize(animated: shrinking && isVisible && pageTransitionActive)
    }

    func pageTransitionWillStart() {
        pageTransitionActive = true
        transitionFallback?.cancel()
        let fallback = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.pageTransitionEnded() }
        }
        transitionFallback = fallback
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.pageTransition + 0.5, execute: fallback)
    }

    func pageTransitionEnded() {
        guard pageTransitionActive else { return }
        pageTransitionActive = false
        transitionFallback?.cancel()
        transitionFallback = nil
    }

    private func cancelFrameAnimation() {
        frameAnimation?.invalidate()
        frameAnimation = nil
    }

    private func applyContentSize(animated: Bool) {
        let target: NSRect
        if let button = statusButton, isVisible, let frame = targetFrame(relativeTo: button) {
            target = frame
        } else {
            let frame = panel.frame
            let windowSize = Self.windowSize(for: contentSize)
            target = NSRect(x: frame.minX, y: frame.maxY - windowSize.height, width: windowSize.width, height: windowSize.height)
        }
        if animated { animateFrame(to: target) } else { setPanelFrame(target) }
    }

    private func animateFrame(to target: NSRect) {
        frameAnimation?.invalidate()
        let start = panel.frame
        guard start != target else { return }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            setPanelFrame(target)
            return
        }
        let spring = Self.pageSpring
        let began = CACurrentMediaTime()
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let elapsed = CACurrentMediaTime() - began
                // Stops at the target rather than following the spring's overshoot, which would clip the page below.
                let eased = min(1, spring.value(target: 1.0, time: elapsed))
                let done = eased >= 1 || elapsed >= spring.settlingDuration
                func mix(_ a: CGFloat, _ b: CGFloat) -> CGFloat { (a + (b - a) * eased).rounded() }
                let frame = NSRect(x: mix(start.minX, target.minX), y: mix(start.minY, target.minY),
                                   width: mix(start.width, target.width), height: mix(start.height, target.height))
                self.setPanelFrame(done ? target : frame)
                if done { self.cancelFrameAnimation() }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        frameAnimation = timer
    }

    /// Places the glass under the status item, entirely on that screen. Pages taller than the space scroll.
    private func position(relativeTo button: NSStatusBarButton) {
        if let frame = targetFrame(relativeTo: button) { setPanelFrame(frame) }
    }

    private func targetFrame(relativeTo button: NSStatusBarButton) -> NSRect? {
        // A status item hidden by a crowded menu bar (or a menu bar manager) has no window or sits off every screen.
        // The panel then opens at the top right of the main screen instead of off-screen.
        var buttonRect = NSRect.null
        if let window = button.window, window.isVisible {
            buttonRect = window.convertToScreen(button.convert(button.bounds, to: nil))
        }
        if buttonRect.isNull || !NSScreen.screens.contains(where: { $0.frame.intersects(buttonRect) }) {
            guard let main = NSScreen.main ?? NSScreen.screens.first else { return nil }
            let width = PanelStyle.width
            buttonRect = NSRect(x: main.visibleFrame.maxX - width / 2 - 8, y: main.frame.maxY - 1, width: 1, height: 1)
        }
        guard let screen = Self.screen(nearest: buttonRect) ?? NSScreen.main else { return nil }
        let visible = screen.visibleFrame
        let margin: CGFloat = 8
        let gap: CGFloat = 6
        // With "Automatically hide and show the menu bar" the status item sits above the screen while the bar is
        // hidden, and visibleFrame then spans the whole screen; keep the glass below where the bar lives either way.
        let barHeight = max(NSApp.mainMenu?.menuBarHeight ?? 0, NSStatusBar.system.thickness)
        let ceiling = min(visible.maxY, screen.frame.maxY - barHeight) - gap
        let top = min(buttonRect.minY - gap, ceiling).rounded(.down)
        let floor = visible.minY + margin
        let maxHeight = max(160, top - floor)
        if state.maxContentHeight != maxHeight { state.maxContentHeight = maxHeight }
        let height = min(contentSize.height, maxHeight).rounded(.up)
        var x = (buttonRect.midX - contentSize.width / 2).rounded()
        x = max(visible.minX + margin, min(x, visible.maxX - contentSize.width - margin))
        let glass = NSRect(x: x, y: top - height, width: contentSize.width, height: height)
        return Self.windowFrame(around: glass)
    }

    private static func screen(nearest rect: NSRect) -> NSScreen? {
        let point = NSPoint(x: rect.midX, y: rect.midY)
        func distance(to frame: NSRect) -> CGFloat {
            let dx = max(frame.minX - point.x, 0, point.x - frame.maxX)
            let dy = max(frame.minY - point.y, 0, point.y - frame.maxY)
            return dx * dx + dy * dy
        }
        return NSScreen.screens.min { distance(to: $0.frame) < distance(to: $1.frame) }
    }

    // MARK: - Geometry

    static func windowSize(for content: CGSize) -> CGSize {
        CGSize(width: content.width.rounded(.up) + shadowInsets.left + shadowInsets.right,
               height: content.height.rounded(.up) + shadowInsets.top + shadowInsets.bottom)
    }

    static func windowFrame(around glass: NSRect) -> NSRect {
        NSRect(x: glass.minX - shadowInsets.left, y: glass.minY - shadowInsets.bottom,
               width: glass.width + shadowInsets.left + shadowInsets.right,
               height: glass.height + shadowInsets.top + shadowInsets.bottom)
    }

    /// The glass rectangle inside a window-sized bounds rect.
    static func glassRect(in bounds: NSRect) -> NSRect {
        NSRect(x: bounds.minX + shadowInsets.left, y: bounds.minY + shadowInsets.bottom,
               width: bounds.width - shadowInsets.left - shadowInsets.right,
               height: bounds.height - shadowInsets.top - shadowInsets.bottom)
    }

    // MARK: - Backdrop

    private func rebuildBackdrop() {
        hosting.removeFromSuperview()
        // Both NSGlassEffectView and SwiftUI bring Auto Layout into the window, and with it two problems: autoresizing
        // masks get applied twice on every resize, and the glass view's internal content demands (priority 750)
        // outrank the window's size-keeping priority (500), so AppKit resizes the window on its own. So: the window's
        // content view is a plain view with no constraints at all, and the constrained hierarchy lives in a container
        // whose frame we set by hand. Nothing required ever reaches the content view, and the window stays where put.
        let root = NSView(frame: NSRect(origin: .zero, size: panel.frame.size))
        root.autoresizesSubviews = false
        let container = NSView(frame: root.bounds)
        container.autoresizingMask = []
        root.addSubview(container)
        self.container = container
        let shadow = PanelShadowView(frame: container.bounds, cornerRadius: Self.cornerRadius)
        // The SwiftUI view sits beside the surface, not inside it: `NSGlassEffectView.contentView` takes over its
        // content's layout.
        // Stock Liquid Glass: default style, no tint. It follows light/dark, Increase Contrast and Reduce Transparency.
        let surface = Self.makeSurface(frame: Self.glassRect(in: container.bounds))
        for view in [shadow, surface, hosting] {
            view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(view)
        }
        let insets = Self.shadowInsets
        NSLayoutConstraint.activate([
            shadow.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            shadow.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            shadow.topAnchor.constraint(equalTo: container.topAnchor),
            shadow.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            surface.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: insets.left),
            surface.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -insets.right),
            surface.topAnchor.constraint(equalTo: container.topAnchor, constant: insets.top),
            surface.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -insets.bottom),
            hosting.leadingAnchor.constraint(equalTo: surface.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: surface.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: surface.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: surface.bottomAnchor),
        ])
        panel.contentView = root
    }

    /// Liquid Glass on macOS 26. On macOS 15 there is no glass view, so the panel uses the popover material,
    /// which also follows light/dark, Increase Contrast and Reduce Transparency.
    private static func makeSurface(frame: NSRect) -> NSView {
        if #available(macOS 26, *) {
            let glass = NSGlassEffectView(frame: frame)
            glass.cornerRadius = cornerRadius
            return glass
        }
        let material = NSVisualEffectView(frame: frame)
        material.material = .popover
        material.blendingMode = .behindWindow
        material.state = .active
        material.wantsLayer = true
        material.layer?.cornerRadius = cornerRadius
        material.layer?.cornerCurve = .continuous
        material.layer?.masksToBounds = true
        return material
    }

    // MARK: - Dismissal and keys

    private func installMonitors() {
        removeMonitors()
        let clicks: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: clicks) { [weak self] _ in
            self?.hide()
        }
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: clicks) { [weak self] event in
            guard let self else { return event }
            if let window = event.window {
                if window == self.panel {
                    // The transparent shadow margin belongs to the window but not to the panel.
                    let bounds = self.panel.contentView?.bounds ?? .zero
                    if !Self.glassRect(in: bounds).contains(event.locationInWindow) { self.hide() }
                    return event
                }
                if window == self.statusButton?.window || window is NSColorPanel { return event }
            }
            self.hide()
            return event
        }
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKey(event) ?? event
        }
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.hide() }
        }
    }

    private func removeMonitors() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMouseMonitor { NSEvent.removeMonitor(localMouseMonitor) }
        if let localKeyMonitor { NSEvent.removeMonitor(localKeyMonitor) }
        if let spaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(spaceObserver) }
        globalMonitor = nil
        localMouseMonitor = nil
        localKeyMonitor = nil
        spaceObserver = nil
    }

    /// Esc goes back from Settings, else closes; Space plays/pauses; ←/→ skip 15 s; ↑/↓ change volume; ⌘Q quits;
    /// ⌘V/⌘C/⌘X/⌘A/⌘Z reach the focused text field even though the app is not active.
    private func handleKey(_ event: NSEvent) -> NSEvent? {
        guard event.window == panel, !state.recordingShortcut else { return event }
        // Esc steps back one level: Settings, then the drawer, then the panel.
        if let prompt = state.pastePrompt, !state.showingSettings, !state.drawerOpen {
            if event.keyCode == 53 { state.pastePrompt = nil; return nil }
            if event.keyCode == 36 || event.keyCode == 76 {
                state.pastePrompt = nil
                state.pasteRequest = PasteRequest(text: prompt.text, mode: .playNow)
                return nil
            }
        }
        if event.keyCode == 53 {
            if state.showingSettings {
                state.showSettings(false)
            } else if state.drawerOpen {
                state.setDrawer(false)
            } else {
                hide()
            }
            return nil
        }
        // The playback keys never apply while typing in a text field, and stay off with Full Keyboard Access, where
        // Space presses the focused control and the arrows move within it.
        let plain = event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty
        if plain, !(panel.firstResponder is NSTextView), !NSApp.isFullKeyboardAccessEnabled, !isRecorderFocused {
            switch event.keyCode {
            case 49:
                engine.togglePlayPause()
                return nil
            case 123 where !state.showingSettings && engine.track != nil,
                 124 where !state.showingSettings && engine.track != nil:
                engine.skip(by: event.keyCode == 123 ? -15 : 15)
                return nil
            case 125 where !state.showingSettings, 126 where !state.showingSettings:
                engine.setVolume(min(1, max(0, engine.volume + (event.keyCode == 126 ? 0.1 : -0.1))))
                return nil
            default:
                break
            }
        }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags == .command || flags == [.command, .shift], let key = event.charactersIgnoringModifiers?.lowercased() else { return event }
        if key == "q" && flags == .command {
            NSApp.terminate(nil)
            return nil
        }
        // ⌘, opens Settings, and closes it again.
        if key == "," && flags == .command {
            state.showSettings(!state.showingSettings)
            return nil
        }
        if isRecorderFocused { return event }
        let selector: Selector? = switch (key, flags) {
        case ("v", .command): #selector(NSText.paste(_:))
        case ("c", .command): #selector(NSText.copy(_:))
        case ("x", .command): #selector(NSText.cut(_:))
        case ("a", .command): #selector(NSText.selectAll(_:))
        case ("z", .command): Selector(("undo:"))
        case ("z", [.command, .shift]): Selector(("redo:"))
        default: nil
        }
        guard let selector else { return event }
        // ⌘V outside a text field: what a link does depends on where you are (see PasteRouter).
        if key == "v", flags == .command, !(panel.firstResponder is NSTextView), let text = PanelController.clipboardLink() {
            state.pasteRequest = PasteRequest(text: text, mode: nil)
            return nil
        }
        if panel.firstResponder?.tryToPerform(selector, with: nil) == true { return nil }
        return event
    }

    private var isRecorderFocused: Bool {
        if let textView = panel.firstResponder as? NSTextView, let delegate = textView.delegate as AnyObject?, delegate is KeyboardShortcuts.RecorderCocoa { return true }
        return panel.firstResponder is KeyboardShortcuts.RecorderCocoa
    }
}

/// A soft shadow that follows the rounded glass. It is cut out under the glass so the backdrop does not sample it,
/// and it never takes clicks.
final class PanelShadowView: NSView {
    private let cornerRadius: CGFloat
    private let maskLayer = CAShapeLayer()
    private var shapedRect = NSRect.null

    init(frame: NSRect, cornerRadius: CGFloat) {
        self.cornerRadius = cornerRadius
        super.init(frame: frame)
        wantsLayer = true
        if let layer {
            layer.shadowColor = NSColor.black.cgColor
            layer.shadowOpacity = 0.42
            layer.shadowRadius = 18
            layer.shadowOffset = CGSize(width: 0, height: -8)
            maskLayer.fillRule = .evenOdd
            layer.mask = maskLayer
        }
        updatePaths()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updatePaths()
    }

    override func layout() {
        super.layout()
        updatePaths()
    }

    private func updatePaths() {
        let glass = PanelController.glassRect(in: bounds)
        guard glass != shapedRect, glass.width > 0, glass.height > 0, let layer else { return }
        shapedRect = glass
        let rounded = CGPath(roundedRect: glass, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
        let outside = CGMutablePath()
        outside.addRect(bounds)
        outside.addPath(rounded)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.shadowPath = rounded
        maskLayer.frame = bounds
        maskLayer.path = outside
        CATransaction.commit()
    }
}
