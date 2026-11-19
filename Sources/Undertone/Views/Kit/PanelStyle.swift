import AppKit
import SwiftUI

/// The Panel v2 tokens (README "Tokens"). Light mode is as designed; dark mode is derived from system colors.
enum PanelStyle {
    // MARK: Metrics

    static let width: CGFloat = 340
    /// The player (F1) at rest; it grows by `bannerHeight + 8` while the F7 banner shows.
    static let playerHeight: CGFloat = 304
    /// The drawer, Settings and every tab.
    static let drawerHeight: CGFloat = 560
    static let panelRadius: CGFloat = 22
    static let drawerRadius: CGFloat = 16
    static let rowRadius: CGFloat = 8
    static let thumbRadius: CGFloat = 7
    static let rowHeight: CGFloat = 42
    static let thumbSide: CGFloat = 32
    /// The drawer's side inset; rows sit inside it with their own 6pt padding.
    static let drawerInset: CGFloat = 16
    static let bannerHeight: CGFloat = 36
    static let topFade: CGFloat = 28
    static let bottomFade: CGFloat = 36

    // MARK: Colors

    static let panelBackground = dynamic(light: 0xF6F6F8, dark: 0x1E1E20)
    static let drawerSurface = dynamic(light: 0xFFFFFF, dark: 0x2A2A2D)
    static let accent = dynamic(light: 0x0A64D8, dark: 0x2F8CFF)
    static let currentText = dynamic(light: 0x0A4FAE, dark: 0x6CB0FF)
    static let currentRow = dynamic(light: 0xEAF2FD, dark: 0x173556)
    static let text = dynamic(light: 0x1D1D1F, dark: 0xF5F5F7)
    static let secondary = dynamic(light: 0x6E6E73, dark: 0xA1A1A6)
    static let tertiary = dynamic(light: 0x8E8E93, dark: 0x8E8E93)
    static let quaternary = dynamic(light: 0xAEAEB2, dark: 0x636366)
    /// Bold header labels and tab titles.
    static let strong = dynamic(light: 0x3A3A3C, dark: 0xD1D1D6)
    static let hoverRow = dynamic(light: 0xF2F2F5, dark: 0x38383C)
    static let segmentTrack = dynamic(light: 0xEBEBEF, dark: 0x1C1C1E)
    static let segmentThumb = dynamic(light: 0xFFFFFF, dark: 0x48484C)
    static let grabber = dynamic(light: 0xC7C7CC, dark: 0x5A5A5E)
    static let separator = dynamic(light: 0xE5E5EA, dark: 0x3A3A3C)
    static let artPlaceholder = dynamic(light: 0x2C2C34, dark: 0x3A3A42)
    static let track = dynamic(light: 0xDCDCE0, dark: 0x48484C)
    static let toast = dynamic(light: 0x1D1D1F, dark: 0x3A3A3E)
    static let toastAction = Color(hex: 0x6CB0FF)
    static let warning = Color(hex: 0xF0890A)
    static let warningFill = dynamic(light: 0xFFF4E6, dark: 0x3A2A14)
    static let warningStroke = dynamic(light: 0xFBDDB5, dark: 0x5C4120)
    static let fieldFill = dynamic(light: 0xF2F2F5, dark: 0x38383C)

    // MARK: Type

    static let title = Font.system(size: 13, weight: .semibold)
    static let playerTitle = Font.system(size: 14, weight: .semibold)
    static let row = Font.system(size: 13)
    static let meta = Font.system(size: 11).monospacedDigit()
    static let small = Font.system(size: 12)
    static let smallBold = Font.system(size: 12, weight: .semibold)

    /// A color that follows the appearance. Built on NSColor so it resolves per view, not per process.
    static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(hex: dark) : NSColor(hex: light)
        })
    }
}

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(nsColor: NSColor(hex: hex, alpha: opacity))
    }
}

/// A borderless symbol button with a fixed hit area, used by every icon-only control in the panel.
struct SymbolButton: View {
    let symbol: String
    let label: String
    var size: CGFloat = 14
    var weight: Font.Weight = .medium
    var side: CGFloat = 24
    var tint: Color = PanelStyle.secondary
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: weight))
                .foregroundStyle(tint)
                .frame(width: side, height: side)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }
}

/// A text button in the accent (Clear, Undo, Try again): 12pt semibold.
struct TextButton: View {
    let title: String
    var tint: Color = PanelStyle.accent
    var help: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(PanelStyle.smallBold)
                .foregroundStyle(tint)
                .padding(.vertical, 6)
                .padding(.horizontal, 3)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help ?? title)
        .accessibilityHint(help ?? "")
    }
}
