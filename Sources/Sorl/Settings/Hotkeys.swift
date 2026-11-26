import Foundation
import KeyboardShortcuts

/// Next and previous are left to the media keys, which reach Sorl through Now Playing.
extension KeyboardShortcuts.Name {
    static let togglePanel = Self("togglePanel", initial: .init(.y, modifiers: [.control, .option]))
    static let togglePlayPause = Self("togglePlayPause", initial: .init(.p, modifiers: [.control, .option]))
    static let cycleSpeed = Self("cycleSpeed", initial: .init(.s, modifiers: [.control, .option]))
}

enum Hotkeys {
    /// Every shortcut name, in Settings order (what iCloud sync mirrors).
    static var all: [KeyboardShortcuts.Name] { SettingsView.hotkeys.map(\.name) }

    static func install(engine: PlayerEngine, panel: PanelController) {
        KeyboardShortcuts.onKeyUp(for: .togglePanel) { panel.toggle() }
        KeyboardShortcuts.onKeyUp(for: .togglePlayPause) { engine.togglePlayPause() }
        KeyboardShortcuts.onKeyUp(for: .cycleSpeed) { engine.cycleSpeed() }
    }
}
