import AppKit
import KeyboardShortcuts
import SorlCore
import os

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var settings: AppSettings!
    private var service: YTDLPService!
    private var engine: PlayerEngine!
    private var nowPlaying: NowPlayingBridge!
    private var outputDevice: OutputDeviceWatcher!
    private var panel: PanelController!
    private var statusItem: StatusItemController!
    private var cloudSync: CloudSync!
    private var updater: Updater!
    private var shortcutObserver: NSObjectProtocol?
    private let log = Logger(subsystem: "com.karbassi.sorl", category: "app")

    private var pendingURLs: [URL] = []
    private var isReady = false

    // Set up in *will*FinishLaunching: Launch Services can deliver `application(_:open:)` before didFinishLaunching.
    func applicationWillFinishLaunching(_ notification: Notification) {
        MainMenu.install()
        if let bundleID = Bundle.main.bundleIdentifier {
            let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            let outcome = LegacyMigration.run(defaults: .standard, bundleID: bundleID, cachesDirectory: caches)
            if outcome != LegacyMigration.Outcome() {
                log.notice("migrated from Undertone: \(outcome.copiedKeys) settings, audio moved: \(outcome.movedAudio)")
            }
        }
        settings = AppSettings()
        let cloudSync = CloudSync(settings: settings)
        self.cloudSync = cloudSync
        settings.onSavedChange = { [weak cloudSync] old, new in cloudSync?.savedDidChange(old: old, new: new) }
        // The vendor's own constant is internal. CloudSync owns the modified-at stamp; this only forwards local edits.
        shortcutObserver = NotificationCenter.default.addObserver(
            forName: Notification.Name("KeyboardShortcuts_shortcutByNameDidChange"), object: nil, queue: .main
        ) { [weak cloudSync] notification in
            let name = notification.userInfo?["name"] as? KeyboardShortcuts.Name
            MainActor.assumeIsolated {
                guard let cloudSync, let name, Hotkeys.all.contains(name), !cloudSync.applyingShortcut else { return }
                cloudSync.shortcutDidChange(name)
            }
        }
        service = YTDLPService(settings: settings)
        engine = PlayerEngine(settings: settings, service: service)
        nowPlaying = NowPlayingBridge(engine: engine)
        outputDevice = OutputDeviceWatcher(engine: engine)
        updater = Updater()
        panel = PanelController(settings: settings, engine: engine, service: service, cloudSync: cloudSync, updater: updater)
        statusItem = StatusItemController(engine: engine, panel: panel, settings: settings, updater: updater)
        Hotkeys.install(engine: engine, panel: panel)
        service.start()
        if settings.syncEnabled { Task { await cloudSync.start() } }
        isReady = true
        log.notice("launched from \(Bundle.main.bundleURL.path, privacy: .public)")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // CKSyncEngine doesn't require it, but silent pushes make other Macs' changes arrive sooner.
        if ICloudEntitlement.hasCloudKit && settings.syncEnabled && !settings.isDemo {
            NSApp.registerForRemoteNotifications()
        }
        let queued = pendingURLs
        pendingURLs.removeAll()
        for url in queued { handle(url) }
    }

    /// `sorl://play?url=…` `add?url=…&mode=next|end` `clear` `drawer?tab=saved` `play` `pause` `toggle` `next` `previous` `seek?to=90` `speed?value=2`
    /// `volume?value=0.5` `mute` `repeat?mode=one` `save` `sync` `update` `open` `settings` `close` `quit`
    func application(_ application: NSApplication, open urls: [URL]) {
        guard isReady else {
            pendingURLs.append(contentsOf: urls)
            return
        }
        for url in urls { handle(url) }
    }

    private func handle(_ url: URL) {
        guard url.scheme == "sorl", let engine, let panel else { return }
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
            // Same as ⌘V in the panel: the clipboard's link (or `url=`, for testing), handled for the page showing.
            if let text = query.first(where: { $0.name == "url" })?.value ?? PanelController.clipboardLink() {
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
        case "sync": cloudSync.syncNow()
        case "update": updater.checkNow()
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

    /// `sorl://demo?screen=g2&hover=<title>&appearance=light`: loads the design screens' fixtures (see `DemoFixtures`) and shows the
    /// panel on that screen. Off unless the hidden `demoHarness` default is set; never touches real Saved/Recent/Up next.
    private func showDemo(_ query: [URLQueryItem]) {
        guard settings.demoHarnessEnabled else {
            log.notice("demo harness is off (defaults write com.karbassi.sorl demoHarness -bool YES)")
            return
        }
        let raw = query.first(where: { $0.name == "screen" })?.value?.lowercased() ?? "f1"
        guard let screen = DemoFixtures.Screen(rawValue: raw) else { return }
        // The sync engine is cancelled before the defaults swap; enterDemoMode drops onSavedChange, so the fixtures
        // written below never reach CloudSync.
        Task {
            await cloudSync.stop()
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
    }

    func applicationWillTerminate(_ notification: Notification) {
        outputDevice.stop()
        engine.shutdown()
        settings.flushStreamCache()
        settings.flushUpNext()
        cloudSync.flush()
    }
}
