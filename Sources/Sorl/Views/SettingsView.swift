import AppKit
import KeyboardShortcuts
import ServiceManagement
import SwiftUI
import SorlCore

/// Settings inside the panel (S1): the mini player stays pinned on top, then "‹ Settings", grouped cards that scroll,
/// and a footer with the version and Quit. ‹, Esc or ⌘, go back to where you came from.
struct SettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(PlayerEngine.self) private var engine
    @Environment(YTDLPService.self) private var service
    @Environment(PanelState.self) private var state
    @Environment(ToastCenter.self) private var toasts
    @Environment(CloudSync.self) private var cloudSync
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var loginRequiresApproval = LaunchAtLogin.status == .requiresApproval
    @State private var loginError: String?
    @State private var confirmingDelete = false
    @State private var scroll = ScrollPosition()

    var body: some View {
        VStack(spacing: 0) {
            if engine.track != nil || engine.isResolving || engine.upNext.current != nil {
                MiniPlayerHeader()
            }
            VStack(spacing: 0) {
                HStack(spacing: 2) {
                    SymbolButton(symbol: "chevron.left", label: "Back", size: 13, weight: .medium, side: 32,
                                 tint: PanelStyle.text) { state.showSettings(false) }
                    Text("Settings")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(PanelStyle.text)
                        .accessibilityAddTraits(.isHeader)
                    Spacer(minLength: 0)
                }
                .padding(.leading, 8)
                .frame(height: 32)
                ScrollingList(accessibilityLabel: "Settings", position: $scroll) {
                    VStack(alignment: .leading, spacing: 0) {
                        if let problem = ToolProblem(service.status) {
                            ToolProblemCard(problem: problem)
                                .padding(.bottom, 4)
                        }
                        general
                        iCloud
                        shortcuts
                        downloads
                    }
                    .padding(EdgeInsets(top: 4, leading: 0, bottom: 16, trailing: 0))
                }
                footer
            }
            .padding(.top, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(DrawerSurface())
            .toasts(toasts, bottomInset: 57)
        }
        .onAppear { refresh() }
        // The demo harness's `hover=scroll-end` shows the Downloads card at the bottom.
        .task(id: "\(state.demoScreen?.rawValue ?? "")|\(state.forcedHover ?? "")") {
            guard state.forcedHover == "scroll-end" else { scroll.scrollTo(edge: .top); return }
            try? await Task.sleep(for: .milliseconds(150))
            scroll.scrollTo(edge: .bottom)
        }
        .onChange(of: state.showCount) { _, _ in refresh() }
    }

    private func refresh() {
        engine.refreshAudioCacheSize()
        launchAtLogin = LaunchAtLogin.isEnabled
        loginRequiresApproval = LaunchAtLogin.status == .requiresApproval
    }

    // MARK: Sections

    @ViewBuilder private var general: some View {
        @Bindable var settings = settings
        SettingsSectionHeader("General")
        SettingsGroup {
            SettingsRow {
                Text("Open at login")
                Spacer(minLength: 10)
                SettingsSwitch(label: "Open at login", isOn: $launchAtLogin)
                    .disabled(!LaunchAtLogin.isAvailable)
            }
            if loginRequiresApproval {
                SettingsRow(divider: true) {
                    Text("Approval needed")
                    Spacer(minLength: 10)
                    TextButton(title: "Approve in System Settings…") { LaunchAtLogin.openSystemSettings() }
                }
            }
            SettingsRow(divider: true) {
                Text("Show the title in the menu bar")
                Spacer(minLength: 10)
                SettingsSwitch(label: "Show the title in the menu bar", isOn: $settings.showTitleInMenuBar)
            }
        }
        .onChange(of: launchAtLogin) { _, enabled in
            guard enabled != LaunchAtLogin.isEnabled else { return }
            do {
                try LaunchAtLogin.set(enabled)
                loginError = nil
                loginRequiresApproval = LaunchAtLogin.status == .requiresApproval
            } catch {
                loginError = error.localizedDescription
                launchAtLogin = LaunchAtLogin.isEnabled
            }
        }
        if let loginError {
            SettingsNote(loginError)
        } else if !LaunchAtLogin.isAvailable {
            SettingsNote("Open at login works once the app is installed (mise run install).")
        }
    }

    @ViewBuilder private var iCloud: some View {
        let sync = cloudSync
        SettingsSectionHeader("iCloud")
        SettingsGroup {
            SettingsRow {
                Text("Sync Saved and shortcuts")
                Spacer(minLength: 10)
                SettingsSwitch(label: "Sync Saved and shortcuts", isOn: Binding(
                    get: { sync.isEnabled },
                    set: { enabled in Task { await sync.setEnabled(enabled) } }
                ))
                .disabled(sync.status == .unavailable)
            }
        }
        if case .upToDate(let date) = sync.status {
            // Refreshes the relative time while Settings is open.
            TimelineView(.periodic(from: .now, by: 30)) { context in
                SettingsNote("Up to date · \(Self.relative(date, now: context.date))")
            }
        } else {
            SettingsNote(Self.syncNote(sync.status))
        }
    }

    static func syncNote(_ status: CloudSync.Status) -> String {
        switch status {
        case .off:
            "Keeps Saved and your shortcuts the same on every Mac signed in to your iCloud account. Turning it on merges this Mac's Saved with iCloud's."
        case .unavailable: "This copy of Sorl can't use iCloud. Install it from Homebrew or a release."
        case .signedOut, .error(.notAuthenticated): "Sign in to iCloud in System Settings to sync."
        case .accountChanged:
            "Your iCloud account changed. Turning sync on again adds this Mac's Saved and shortcuts to the new account."
        case .cloudDataDeleted:
            "Sorl's iCloud data was deleted. Turning sync on again uploads this Mac's Saved and shortcuts."
        case .syncing: "Syncing…"
        case .upToDate: "Up to date"
        case .error(.offline): "You're offline. Sorl will sync when you're back."
        case .error(.quotaExceeded): "Your iCloud storage is full."
        case .error(.other): "Couldn't sync. Sorl will try again."
        }
    }

    /// "just now" under a minute, then "2 minutes ago".
    static func relative(_ date: Date, now: Date) -> String {
        guard now.timeIntervalSince(date) >= 60 else { return "just now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: now)
    }

    @ViewBuilder private var shortcuts: some View {
        SettingsSectionHeader("Keyboard shortcuts")
        SettingsGroup {
            ForEach(Array(Self.hotkeys.enumerated()), id: \.offset) { index, hotkey in
                SettingsRow(divider: index > 0) {
                    Text(hotkey.label)
                    Spacer(minLength: 10)
                    ShortcutRecorder(name: hotkey.name, label: hotkey.label)
                }
            }
        }
        SettingsNote("Click a shortcut to change it. Media keys work too.")
    }

    static let hotkeys: [(label: String, name: KeyboardShortcuts.Name)] = [
        ("Play or pause", .togglePlayPause), ("Next", .nextTrack), ("Previous", .previousTrack),
        ("Change speed", .cycleSpeed), ("Show Sorl", .togglePanel),
    ]

    @ViewBuilder private var downloads: some View {
        let used = engine.audioCacheBytes
        let cap = engine.audioCache.capacity
        SettingsSectionHeader("Downloads")
        SettingsGroup {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    if confirmingDelete {
                        Text("Delete \(Self.bytes(used))? This can't be undone.")
                            .lineLimit(1)
                            .minimumScaleFactor(0.9)
                        Spacer(minLength: 0)
                        TextButton(title: "Delete", tint: Color(nsColor: .systemRed)) {
                            engine.clearAudioCache()
                            confirmingDelete = false
                            toasts.show("Deleted downloads")
                        }
                        TextButton(title: "Cancel", tint: PanelStyle.strong) { confirmingDelete = false }
                    } else {
                        Text(used > 0 ? "\(Self.bytes(used)) of \(Self.bytes(cap))" : "No downloads yet")
                        Spacer(minLength: 0)
                        TextButton(title: "Delete…", help: "Delete downloads") { confirmingDelete = true }
                            .disabled(used == 0)
                            .opacity(used == 0 ? 0.4 : 1)
                    }
                }
                .frame(height: 16)
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.primary.opacity(0.08))
                        Capsule().fill(PanelStyle.accent)
                            .frame(width: cap > 0 ? proxy.size.width * min(1, Double(used) / Double(cap)) : 0)
                    }
                }
                .frame(height: 6)
                .accessibilityHidden(true)
            }
            .font(.system(size: 13))
            .foregroundStyle(PanelStyle.text)
            .padding(.vertical, 7)
            .frame(minHeight: 40)
            SettingsRow(divider: true) {
                Text("Keep up to")
                Spacer(minLength: 10)
                LimitStepper(value: settings.downloadsLimitGB) { gigabytes in
                    if engine.setDownloadsLimit(gigabytes) {
                        toasts.show("Removed the oldest downloads to fit \(gigabytes) GB")
                    }
                }
            }
        }
        SettingsNote("Played videos are kept so replays start instantly and work offline.")
    }

    private var footer: some View {
        HStack {
            Text(versionLabel)
                .font(.system(size: 11))
                .foregroundStyle(PanelStyle.tertiary)
                .help(toolVersions)
                .accessibilityHint(toolVersions)
            Spacer()
            TextButton(title: "Quit Sorl", tint: PanelStyle.strong, help: "Quit Sorl") { NSApp.terminate(nil) }
        }
        .padding(.horizontal, 22)
        .frame(height: 45)
        .overlay(alignment: .top) { Rectangle().fill(.primary.opacity(0.08)).frame(height: 1) }
    }

    /// "Sorl 0.4.0 (183)": the build number (the commit count, from bundle.sh) tells two builds apart.
    private var versionLabel: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "dev"
        guard let build = info?["CFBundleVersion"] as? String, !build.isEmpty else { return "Sorl \(version)" }
        return "Sorl \(version) (\(build))"
    }

    /// "yt-dlp 2026.10.22 · deno found", on hover of the version.
    private var toolVersions: String {
        let ytdlp: String = switch service.status {
        case .ready(let v), .outdated(let v): "yt-dlp \(v)"
        case .checking: "yt-dlp: checking"
        case .missing: "yt-dlp not found"
        case .broken: "yt-dlp not working"
        }
        return "\(ytdlp) · \(service.jsRuntime == nil ? "deno not found" : "deno found")"
    }

    /// Decimal like Finder: "340 MB", "2 GB".
    static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }
}

// MARK: - Pieces

struct SettingsSectionHeader: View {
    let title: String
    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(PanelStyle.secondary)
            .padding(EdgeInsets(top: 16, leading: 4, bottom: 6, trailing: 4))
            .accessibilityAddTraits(.isHeader)
    }
}

struct SettingsGroup<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) { content }
            .padding(.horizontal, 12)
            .background(PanelStyle.panelBackground, in: .rect(cornerRadius: 10))
    }
}

/// A 38pt row: label left in 13pt, its control right; a hairline above every row but the first.
struct SettingsRow<Content: View>: View {
    var divider = false
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 0) { content }
            .font(.system(size: 13))
            .foregroundStyle(PanelStyle.text)
            .frame(minHeight: divider ? 39 : 38)
            .overlay(alignment: .top) {
                if divider { Rectangle().fill(.primary.opacity(0.08)).frame(height: 1) }
            }
            .accessibilityElement(children: .combine)
    }
}

struct SettingsNote: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(PanelStyle.tertiary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(EdgeInsets(top: 6, leading: 4, bottom: 0, trailing: 4))
    }
}

/// A 30×18 switch: accent when on, light gray when off.
struct SettingsSwitch: View {
    let label: String
    @Binding var isOn: Bool
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button { withAnimation(.easeOut(duration: 0.15)) { isOn.toggle() } } label: {
            Capsule()
                .fill(isOn ? PanelStyle.accent : PanelStyle.dynamic(light: 0xD9D9DE, dark: 0x48484C))
                .frame(width: 30, height: 18)
                .overlay(alignment: isOn ? .trailing : .leading) {
                    Circle().fill(.white)
                        .shadow(color: .black.opacity(0.2), radius: 1, y: 0.5)
                        .padding(2)
                }
                .opacity(isEnabled ? 1 : 0.5)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityValue(isOn ? "On" : "Off")
        .accessibilityAddTraits(.isToggle)
    }
}

/// − 2 GB + over 1, 2, 5 and 10 GB.
struct LimitStepper: View {
    let value: Int
    let onChange: (Int) -> Void

    private var index: Int { AppSettings.downloadsLimits.firstIndex(of: value) ?? 1 }

    var body: some View {
        let limits = AppSettings.downloadsLimits
        HStack(spacing: 0) {
            step("−", label: "Smaller limit", enabled: index > 0) { onChange(limits[index - 1]) }
            Text("\(value) GB")
                .font(PanelStyle.smallBold.monospacedDigit())
                .foregroundStyle(PanelStyle.text)
                .frame(width: 40)
            step("+", label: "Bigger limit", enabled: index < limits.count - 1) { onChange(limits[index + 1]) }
        }
        .frame(height: 22)
        .background(PanelStyle.drawerSurface, in: .rect(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.black.opacity(0.14), lineWidth: 0.5))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Downloads limit")
        .accessibilityValue("\(value) gigabytes")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: if index < limits.count - 1 { onChange(limits[index + 1]) }
            case .decrement: if index > 0 { onChange(limits[index - 1]) }
            @unknown default: break
            }
        }
    }

    private func step(_ glyph: String, label: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(glyph)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(PanelStyle.strong)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
        .help(label)
    }
}

/// The shortcut chip: shows "⌃⌥P"; click it and type the new keys. Esc cancels, Delete clears.
struct ShortcutRecorder: View {
    let name: KeyboardShortcuts.Name
    let label: String
    @Environment(PanelState.self) private var state
    @State private var recording = false
    @State private var shortcut: KeyboardShortcuts.Shortcut?
    @State private var monitor: Any?

    var body: some View {
        Button { recording ? stop() : start() } label: {
            Text(recording ? "Type keys…" : shortcut?.description ?? "Record")
                .font(.system(size: 12))
                .foregroundStyle(recording ? PanelStyle.accent : PanelStyle.strong)
                .padding(.horizontal, 8)
                .frame(minWidth: 64, minHeight: 22)
                .background(PanelStyle.drawerSurface, in: .rect(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(recording ? PanelStyle.accent : .black.opacity(0.14), lineWidth: recording ? 1 : 0.5))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(recording ? "Type the new shortcut. Esc cancels, Delete clears." : "Click to change")
        .accessibilityLabel("\(label) shortcut")
        .accessibilityValue(shortcut?.description ?? "None")
        .onAppear { shortcut = KeyboardShortcuts.getShortcut(for: name) }
        .onDisappear { stop() }
    }

    private func start() {
        recording = true
        state.recordingShortcut = true
        KeyboardShortcuts.isEnabled = false   // the old shortcut must not fire while typing the new one
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handle(event)
            return nil
        }
    }

    private func handle(_ event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        switch event.keyCode {
        case 53 where modifiers.isEmpty:   // Esc
            stop()
        case 51 where modifiers.isEmpty, 117 where modifiers.isEmpty:   // Delete, Forward Delete
            KeyboardShortcuts.setShortcut(nil, for: name)
            shortcut = nil
            stop()
        default:
            // A shortcut needs a modifier other than Shift, so typing letters can't take over a key.
            guard !modifiers.subtracting(.shift).isEmpty, let new = KeyboardShortcuts.Shortcut(event: event) else {
                NSSound.beep()
                return
            }
            KeyboardShortcuts.setShortcut(new, for: name)
            shortcut = new
            stop()
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        guard recording else { return }
        recording = false
        state.recordingShortcut = false
        KeyboardShortcuts.isEnabled = true
    }
}

/// yt-dlp missing, broken or out of date: what Settings says first.
enum ToolProblem {
    case missing, outdated, broken(String)

    init?(_ status: ToolStatus) {
        switch status {
        case .missing: self = .missing
        case .outdated: self = .outdated
        case .broken(let message): self = .broken(message)
        case .ready, .checking: return nil
        }
    }

    var reason: String {
        switch self {
        case .missing: return "yt-dlp, the tool that fetches them, isn't installed. To install it:"
        case .outdated: return "yt-dlp, the tool that fetches them, is out of date. To update it:"
        case .broken(let message): return "yt-dlp, the tool that fetches them, isn't working (\(message)). To reinstall it:"
        }
    }
}

/// The orange card on top of Settings: the reason, the brew command with Copy, and Check again.
struct ToolProblemCard: View {
    @Environment(YTDLPService.self) private var service
    @Environment(ToastCenter.self) private var toasts
    let problem: ToolProblem

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text("!")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 16, height: 16)
                .background(Circle().fill(Color(hex: 0xFF8A00)))
                .padding(.top, 1)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Videos can't play right now")
                        .font(PanelStyle.title)
                        .foregroundStyle(PanelStyle.text)
                    Text(problem.reason)
                        .font(.system(size: 11))
                        .foregroundStyle(PanelStyle.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Text(command)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(PanelStyle.text)
                        .textSelection(.enabled)
                    Spacer(minLength: 0)
                    TextButton(title: "Copy", help: "Copy the command") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(command, forType: .string)
                        toasts.show("Copied. Paste it in Terminal.")
                    }
                }
                .padding(.leading, 8)
                .padding(.trailing, 2)
                .frame(height: 24)
                .background(PanelStyle.drawerSurface, in: .rect(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(hex: 0xC45A00, opacity: 0.2), lineWidth: 0.5))
                TextButton(title: "Check again", help: "Check yt-dlp again") { service.recheck() }
                    .padding(.leading, -3)
                    .padding(.vertical, -4)
            }
        }
        .padding(EdgeInsets(top: 8, leading: 12, bottom: 10, trailing: 12))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PanelStyle.warningFill, in: .rect(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color(hex: 0xC45A00, opacity: 0.25), lineWidth: 0.5))
        .accessibilityElement(children: .contain)
    }

    private var command: String { service.installCommand }
}
