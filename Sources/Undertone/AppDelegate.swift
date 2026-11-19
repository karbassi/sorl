import AppKit
import UndertoneCore
import os

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var settings: AppSettings!
    private var service: YTDLPService!
    private var engine: PlayerEngine!
    private var nowPlaying: NowPlayingBridge!
    private var panel: PanelController!
    private var statusItem: StatusItemController!
    private let log = Logger(subsystem: "com.jverissimo.undertone", category: "app")

    private var pendingURLs: [URL] = []
    private var isReady = false

    // Set up in *will*FinishLaunching: Launch Services can deliver `application(_:open:)` before didFinishLaunching.
    func applicationWillFinishLaunching(_ notification: Notification) {
        MainMenu.install()
        settings = AppSettings()
        service = YTDLPService(settings: settings)
        engine = PlayerEngine(settings: settings, service: service)
        nowPlaying = NowPlayingBridge(engine: engine)
        panel = PanelController(settings: settings, engine: engine, service: service)
        statusItem = StatusItemController(engine: engine, panel: panel, settings: settings)
        Hotkeys.install(engine: engine, panel: panel)
        service.start()
        isReady = true
        log.notice("launched from \(Bundle.main.bundleURL.path, privacy: .public)")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let queued = pendingURLs
        pendingURLs.removeAll()
        for url in queued { handle(url) }
    }

    /// `undertone://play?url=…` `add?url=…&mode=next|end` `clear` `drawer?tab=saved` `play` `pause` `toggle` `next` `previous` `seek?to=90` `speed?value=2`
    /// `volume?value=0.5` `mute` `repeat?mode=one` `save` `open` `settings` `close` `quit`
    func application(_ application: NSApplication, open urls: [URL]) {
        guard isReady else {
            pendingURLs.append(contentsOf: urls)
            return
        }
        for url in urls { handle(url) }
    }

    private func handle(_ url: URL) {
        guard url.scheme == "undertone", let engine, let panel else { return }
        log.notice("url \(url.absoluteString, privacy: .public)")
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        switch url.host() {
        case "play":
            if let target = query.first(where: { $0.name == "url" })?.value, !target.isEmpty {
                engine.open(target)
            } else {
                engine.play()
            }
        case "add":
            // `add?url=…&mode=next|end`: queues a link without touching what's playing.
            if let target = query.first(where: { $0.name == "url" })?.value, !target.isEmpty {
                let next = query.first(where: { $0.name == "mode" })?.value == "next"
                engine.open(target, mode: next ? .playNext : .addToEnd)
            }
        case "clear": engine.editQueue { $0.clear() }
        case "paste":
            // Same as ⌘V in the panel: the clipboard's link, handled for the page that is showing.
            if let text = PanelController.clipboardLink() {
                panel.show()
                panel.state.pasteRequest = PasteRequest(text: text, mode: nil)
            }
        case "pause": engine.pause()
        case "toggle": engine.togglePlayPause()
        case "next": engine.next()
        case "previous": engine.previous()
        case "speed":
            if let raw = query.first(where: { $0.name == "value" })?.value, let value = Double(raw), let speed = PlaybackSpeed(rawValue: value) {
                engine.setSpeed(speed)
            } else {
                engine.cycleSpeed()
            }
        case "seek":
            if let raw = query.first(where: { $0.name == "to" })?.value, let seconds = Double(raw) { engine.seek(to: seconds) }
        case "volume":
            if let raw = query.first(where: { $0.name == "value" })?.value, let value = Float(raw) { engine.setVolume(value) }
        case "mute": engine.toggleMute()
        case "repeat":
            if let raw = query.first(where: { $0.name == "mode" })?.value, let mode = RepeatMode(rawValue: raw) {
                engine.setRepeatMode(mode)
            } else {
                engine.cycleRepeatMode()
            }
        case "save": engine.toggleSavedTrack()
        case "demo": showDemo(query)
        case "drawer":
            let raw = query.first(where: { $0.name == "tab" })?.value ?? PanelState.Tab.upNext.rawValue
            panel.showDrawer(tab: PanelState.Tab(rawValue: raw) ?? .upNext)
        case "open": panel.show()
        case "settings": panel.show(settings: true)
        case "close": panel.hide()
        case "quit": NSApp.terminate(nil)
        default: log.notice("unknown URL \(url.absoluteString, privacy: .public)")
        }
    }

    /// `undertone://demo?screen=g2&hover=<title>&appearance=light`: loads the design screens' fixtures (see `DemoFixtures`) and shows the
    /// panel on that screen. Off unless the hidden `demoHarness` default is set; never touches real Saved/Recent/Up next.
    private func showDemo(_ query: [URLQueryItem]) {
        guard settings.demoHarnessEnabled else {
            log.notice("demo harness is off (defaults write com.jverissimo.undertone demoHarness -bool YES)")
            return
        }
        let raw = query.first(where: { $0.name == "screen" })?.value?.lowercased() ?? "f1"
        guard let screen = DemoFixtures.Screen(rawValue: raw) else { return }
        settings.enterDemoMode()
        let demo = DemoFixtures.state(for: screen)
        settings.saved = DemoFixtures.saved
        let recent = DemoFixtures.recent(pickUp: screen == .f5 || screen == .f7f5)
        settings.recent = recent.store
        settings.positions = PlaybackPositions(entries: recent.positions)
        settings.speed = .normal
        engine.setSpeed(.normal)
        engine.setRepeatMode(screen == .f1 || screen == .f1b || screen == .f6 || screen == .f7 ? .all : .off)
        engine.loadDemo(track: demo.track, upNext: demo.upNext, position: demo.position, playing: demo.playing,
                        downloaded: DemoFixtures.downloadedKeys, cacheBytes: 340 * 1_000_000)
        if demo.playbackFailed { engine.showDemoFailure() }
        service.simulate(demo.ytdlpBroken ? .outdated(YTDLPVersion(2025, 6, 30)) : .ready(YTDLPVersion(2026, 10, 22)))
        // Screenshots in both modes without touching the system setting.
        switch query.first(where: { $0.name == "appearance" })?.value {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: NSApp.appearance = nil
        }
        let hover = query.first(where: { $0.name == "hover" })?.value
        panel.showDemo(screen, hover: hover)
    }

    func applicationWillTerminate(_ notification: Notification) {
        engine.shutdown()
        settings.flushStreamCache()
        settings.flushUpNext()
    }
}
