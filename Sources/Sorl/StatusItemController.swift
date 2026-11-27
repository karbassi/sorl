import AppKit
import SorlCore

/// The menu bar icon. Left click toggles the panel, right click shows a small menu.
final class StatusItemController: NSObject {
    private let statusItem: NSStatusItem
    private let engine: PlayerEngine
    private let panel: PanelController
    private let settings: AppSettings
    private let updater: Updater
    private var scrollMonitor: Any?
    private var flashTask: Task<Void, Never>?
    private var flashText: String?
    private var iconCache: [String: NSImage] = [:]
    /// The playable link on the drag currently over the icon, if any.
    private var dragLink: MediaLink?

    init(engine: PlayerEngine, panel: PanelController, settings: AppSettings, updater: Updater) {
        self.engine = engine
        self.panel = panel
        self.settings = settings
        self.updater = updater
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        if let button = statusItem.button {
            button.imagePosition = .imageOnly
            button.target = self
            button.action = #selector(clicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.toolTip = "Sorl"
            button.font = NSFont.menuBarFont(ofSize: 0)
        }
        panel.statusButton = statusItem.button
        updateIcon()
        observe()
        installScrollVolume()
        installLinkDrop()
    }

    // MARK: - Dropping a link on the icon

    /// Dragging a link onto the menu bar icon plays it; holding Option adds it to the end of Up next instead. The
    /// status item's window takes the drag and hands it to its delegate (NSWindow forwards NSDraggingDestination).
    private func installLinkDrop() {
        guard let window = statusItem.button?.window else { return }
        window.registerForDraggedTypes([.URL, .fileURL, .string])
        window.delegate = self
    }

    /// The playable link on a drag's pasteboard: web URLs first, then `.webloc` files, then plain text.
    private func droppedLink(_ sender: NSDraggingInfo) -> MediaLink? {
        let pasteboard = sender.draggingPasteboard
        var candidates: [String] = []
        for url in pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] ?? [] {
            if url.isFileURL {
                guard url.pathExtension.lowercased() == "webloc", let data = try? Data(contentsOf: url),
                      let target = DroppedLink.weblocURL(from: data) else { continue }
                candidates.append(target)
            } else {
                candidates.append(url.absoluteString)
            }
        }
        if let text = pasteboard.string(forType: .string) { candidates.append(text) }
        return DroppedLink.link(from: candidates)
    }

    /// Called once per drag, on entry: reading the pasteboard (and a `.webloc` off disk) on every mouse move is waste.
    private func beginDrag(_ sender: NSDraggingInfo) -> NSDragOperation {
        dragLink = droppedLink(sender)
        return dragOperation(sender)
    }

    private func dragOperation(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard dragLink != nil else { return [] }
        let allowed = sender.draggingSourceOperationMask
        return [NSDragOperation.copy, .link, .generic].first(where: allowed.contains) ?? []
    }

    private func endDrag() {
        dragLink = nil
        statusItem.button?.highlight(false)
    }

    /// Scrolling over the menu bar icon adjusts the volume; swipe/roll up = louder, regardless of the
    /// "natural scrolling" setting. Shows the level briefly next to the icon.
    private func installScrollVolume() {
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, let button = self.statusItem.button, event.window == button.window else { return event }
            // Trackpad momentum would keep changing the volume after the fingers lift.
            guard event.momentumPhase.isEmpty else { return nil }
            let raw = event.scrollingDeltaY
            guard raw != 0 else { return event }
            let up = event.isDirectionInvertedFromDevice ? -raw : raw
            let step = event.hasPreciseScrollingDeltas ? up / 100 : up / 8
            self.engine.setVolume(self.engine.volume + Float(step))
            self.flash("\(Int((self.engine.volume * 100).rounded()))%")
            return nil
        }
    }

    private func flash(_ text: String) {
        flashText = text
        updateIcon()
        flashTask?.cancel()
        flashTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let self else { return }
            self.flashText = nil
            self.updateIcon()
        }
    }

    @objc private func clicked(_ sender: Any?) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            showMenu()
        } else {
            panel.toggle()
        }
    }

    private func showMenu() {
        panel.hide()
        let menu = NSMenu()
        menu.autoenablesItems = false   // otherwise AppKit ignores the isEnabled set below
        if let track = engine.track {
            let title = NSMenuItem(title: track.title, action: nil, keyEquivalent: "")
            title.isEnabled = false
            menu.addItem(title)
            menu.addItem(.separator())
        }
        let playPause = NSMenuItem(title: engine.isPlaying ? "Pause" : "Play", action: #selector(togglePlayPause), keyEquivalent: "")
        playPause.target = self
        playPause.isEnabled = engine.track != nil || settings.lastLink != nil
        menu.addItem(playPause)
        // Same rule as the panel's previous button: enabled with somewhere to go back to, or to restart the current one.
        if engine.track != nil {
            let noun = engine.skipsByChapter ? " Chapter" : ""
            let previous = NSMenuItem(title: "Previous\(noun)", action: #selector(previousTrack), keyEquivalent: "")
            previous.target = self
            previous.isEnabled = engine.hasPrevious || engine.currentTime >= 3
            menu.addItem(previous)
            let next = NSMenuItem(title: "Next\(noun)", action: #selector(nextTrack), keyEquivalent: "")
            next.target = self
            next.isEnabled = engine.hasNext
            menu.addItem(next)
        }
        let open = NSMenuItem(title: "Open Sorl", action: #selector(openPanel), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        if updater.isAvailable {
            let update = NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")
            update.target = self
            update.isEnabled = updater.canCheck
            menu.addItem(update)
        }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Sorl", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func togglePlayPause() { engine.togglePlayPause() }
    @objc private func nextTrack() { engine.next() }
    @objc private func previousTrack() { engine.previous() }
    @objc private func openPanel() { panel.show() }
    @objc private func openSettings() { panel.show(settings: true) }
    @objc private func checkForUpdates() { updater.checkNow() }

    private func observe() {
        withObservationTracking {
            _ = engine.isPlaying
            _ = engine.isResolving
            _ = engine.track
            _ = engine.chapter
            _ = settings.showTitleInMenuBar
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.updateIcon()
                self.observe()
            }
        }
    }

    private func updateIcon() {
        // The four brand glyphs differ by shape: idle (bump), loading (dots), playing (wave), paused (broken wave).
        let name: String
        if engine.isResolving {
            name = "loading"
        } else if engine.isPlaying {
            name = "playing"
        } else if engine.track != nil {
            name = "paused"
        } else {
            name = "idle"
        }
        let image = icon(named: name)
        if statusItem.button?.image !== image { statusItem.button?.image = image }

        var title = ""
        if let flashText {
            title = flashText
        } else if settings.showTitleInMenuBar, let track = engine.track {
            // In a DJ mix the chapter is the song playing, which says more than the mix's title.
            title = Self.truncated(engine.chapter?.title ?? track.title, to: 30)
        }
        // Setting these unconditionally relayouts the whole menu bar; only touch them on a real change.
        let newTitle = title.isEmpty ? "" : " " + title
        let newLength = title.isEmpty ? NSStatusItem.squareLength : NSStatusItem.variableLength
        if statusItem.length != newLength { statusItem.length = newLength }
        if statusItem.button?.title != newTitle {
            statusItem.button?.imagePosition = title.isEmpty ? .imageOnly : .imageLeading
            statusItem.button?.title = newTitle
        }
        // The tooltip and VoiceOver get the full, untruncated title and the state the icon shows.
        let playing = engine.chapter?.title ?? engine.track?.title
        let state = engine.isResolving ? "Loading" : engine.isPlaying ? "Playing" : engine.track != nil ? "Paused" : nil
        let description = ["Sorl", state, playing].compactMap { $0 }.joined(separator: ", ")
        if statusItem.button?.toolTip != description {
            statusItem.button?.toolTip = description
            statusItem.button?.setAccessibilityLabel(description)
        }
    }

    /// Glyphs are loaded once; the scroll-wheel volume readout would otherwise load one per tick. They ship as
    /// 18 pt template SVGs in Contents/Resources/MenuBar (see docs/brand). A bare `swift run` has no bundle, so it
    /// falls back to a system symbol.
    private func icon(named name: String) -> NSImage? {
        if let cached = iconCache[name] { return cached }
        let image = Bundle.main.url(forResource: "sorl-glyph-\(name)", withExtension: "svg", subdirectory: "MenuBar")
            .flatMap(NSImage.init(contentsOf:))
            ?? NSImage(systemSymbolName: "waveform", accessibilityDescription: "Sorl")
        image?.size = NSSize(width: 18, height: 18)
        image?.isTemplate = true
        iconCache[name] = image
        return image
    }

    private static func truncated(_ text: String, to limit: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed }
        return String(trimmed.prefix(limit - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }
}

extension StatusItemController: NSWindowDelegate, NSDraggingDestination {
    func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let operation = beginDrag(sender)
        statusItem.button?.highlight(!operation.isEmpty)
        return operation
    }

    func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        dragOperation(sender)
    }

    func draggingExited(_ sender: NSDraggingInfo?) {
        endDrag()
    }

    func draggingEnded(_ sender: NSDraggingInfo) {
        endDrag()
    }

    func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let link = dragLink ?? droppedLink(sender)
        endDrag()
        guard let link else { return false }
        let addToEnd = NSEvent.modifierFlags.contains(.option)
        engine.open(link, mode: addToEnd ? .addToEnd : .playNow)
        return true
    }
}
