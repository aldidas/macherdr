import AppKit
import HerdrKit
import SwiftUI

/// Settings → Appearance: how the window chrome relates to the terminal background.
enum WindowBackgroundMode: String, CaseIterable, Identifiable {
    case off, match, darker
    var id: String { rawValue }
}

/// Design tokens from the MacHerdr design canvas (waku-derived), light/dark adaptive.
enum Theme {
    /// Settings → Appearance: tint the window chrome with the terminal theme's background.
    static let windowBackgroundKey = "appearance.windowBackground"
    static let defaultWindowBackgroundMode = WindowBackgroundMode.match.rawValue
    /// Pre-3-mode Bool key: true → `.match`, false → `.off`.
    private static let legacyMatchWindowKey = "appearance.matchWindowToTheme"
    static var windowBackgroundMode: WindowBackgroundMode {
        let defaults = UserDefaults.standard
        if let raw = defaults.string(forKey: windowBackgroundKey),
           let mode = WindowBackgroundMode(rawValue: raw) {
            return mode
        }
        if let legacy = defaults.object(forKey: legacyMatchWindowKey) as? Bool {
            return legacy ? .match : .off
        }
        return .match
    }

    /// Settings → Appearance: an image drawn behind the window, covered by the chrome colors.
    static let backgroundImagePathKey = "appearance.backgroundImagePath"
    /// How opaque the chrome colors are over the image (1 = image hidden).
    static let backgroundOverlayKey = "appearance.backgroundOverlay"
    static let defaultBackgroundOverlay = 0.85
    private static var imageCache: (path: String, image: NSImage?)?
    static var backgroundImage: NSImage? {
        guard let path = UserDefaults.standard.string(forKey: backgroundImagePathKey), !path.isEmpty else {
            return nil
        }
        if let cached = imageCache, cached.path == path { return cached.image }
        let image = NSImage(contentsOfFile: path)
        imageCache = (path, image)
        return image
    }
    private static var backgroundOverlay: Double {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: backgroundOverlayKey) != nil else { return defaultBackgroundOverlay }
        return min(max(defaults.double(forKey: backgroundOverlayKey), 0), 1)
    }
    /// Chrome colors sit on top of the image at the overlay opacity.
    private static func overImage(_ color: Color) -> Color {
        backgroundImage == nil ? color : color.opacity(backgroundOverlay)
    }

    private static func dynamic(_ light: NSColor, _ dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }

    private static func hex(_ value: UInt32, alpha: CGFloat = 1) -> NSColor {
        NSColor(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: alpha
        )
    }

    // text ramp
    static let text = dynamic(hex(0x242424), hex(0xE2E2E2))
    static let textSecondary = dynamic(hex(0x666666), hex(0xA3A3A3))
    static let textTertiary = dynamic(hex(0x858585), hex(0x7D7D7D))
    static let textGhost = dynamic(hex(0xA4A4A4), hex(0x575757))

    // accent + status
    /// Follows the macOS accent color (System Settings → Appearance).
    static let accent = Color(nsColor: .controlAccentColor)
    static let accentWash = Color(nsColor: NSColor(name: nil) { appearance in
        let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return NSColor.controlAccentColor.withAlphaComponent(dark ? 0.14 : 0.12)
    })
    static let working = dynamic(hex(0x2563EB), hex(0x3B82F6))
    static let success = dynamic(hex(0x2FA35F), hex(0x62C987))
    static let warning = dynamic(hex(0xB8862E), hex(0xE0B36A))
    /// grazr's account line, matching the mint the Herdr TUI row uses (#b5ead7).
    static let statsAccount = dynamic(hex(0x3F9A7A), hex(0xB5EAD7))
    static let danger = dynamic(hex(0xC94F44), hex(0xE2726A))

    // surfaces
    static let itemWash = dynamic(hex(0x141414, alpha: 0.06), hex(0xF0F0F0, alpha: 0.06))
    static let itemWashSelected = dynamic(hex(0x141414, alpha: 0.07), hex(0xF0F0F0, alpha: 0.07))
    /// Follows the chosen Ghostty theme's background; callers re-render when
    /// `terminal.theme` changes, which re-resolves this.
    static var terminalBackground: Color {
        if let themed = TerminalThemeSetting.backgroundColor() {
            return Color(nsColor: themed)
        }
        return builtInTerminalBackground
    }
    /// Window chrome (titlebar, sidebar, gutters around the terminal) matches the
    /// terminal background so the window reads as one surface.
    static var contentBackground: Color { overImage(solidContentBackground) }
    private static var solidContentBackground: Color {
        switch windowBackgroundMode {
        case .off: return defaultContentBackground
        case .match: return terminalBackground
        case .darker:
            guard let base = windowBase else { return defaultContentBackground }
            return Color(nsColor: base)
        }
    }
    /// Window appearance that keeps system text/controls legible on the chrome: a
    /// light terminal theme under a dark app (or the reverse) would otherwise leave
    /// white titles on a light surface. nil = follow the app appearance.
    static var chromeAppearance: NSAppearance? {
        guard windowBackgroundMode != .off,
              let base = TerminalThemeSetting.backgroundColor() else { return nil }
        let rgb = base.usingColorSpace(.sRGB) ?? base
        let luma = 0.299 * rgb.redComponent + 0.587 * rgb.greenComponent + 0.114 * rgb.blueComponent
        return NSAppearance(named: luma < 0.5 ? .darkAqua : .aqua)
    }
    /// Terminal background for the chrome, darkened in `.darker` mode (more on dark
    /// themes, where a small shift is invisible); nil when the chrome doesn't follow it.
    private static var windowBase: NSColor? {
        let mode = windowBackgroundMode
        guard mode != .off else { return nil }
        let base = TerminalThemeSetting.backgroundColor()
            ?? NSColor(name: nil) { appearance in
                appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                    ? hex(0x101012) : hex(0xFFFFFF)
            }
        guard mode == .darker else { return base }
        let rgb = base.usingColorSpace(.sRGB) ?? base
        let luma = 0.299 * rgb.redComponent + 0.587 * rgb.greenComponent + 0.114 * rgb.blueComponent
        return rgb.blended(withFraction: luma < 0.5 ? 0.25 : 0.06, of: .black) ?? rgb
    }
    private static let defaultContentBackground = dynamic(hex(0xF6F6F6), hex(0x181818))
    private static let builtInTerminalBackground = dynamic(hex(0xFFFFFF), hex(0x101012))
    /// Solid (not vibrancy) so the sidebar never shows the desktop through it.
    /// Same surface as the titlebar, so the sidebar and titlebar read as one.
    static var sidebarBackground: Color { contentBackground }
    /// Sticky sidebar headers sit on top of the sidebar surface, so a full-strength
    /// layer here stacks with it and hides the background image; keep a light tint
    /// that still dims rows scrolling under the header.
    static var sidebarHeaderBackground: Color {
        backgroundImage == nil ? sidebarBackground : solidContentBackground.opacity(0.4)
    }
    /// Titlebar tab strip: lighter than `contentBackground` (the titlebar) in dark mode,
    /// darker in light mode.
    /// Derived from the terminal background so it tracks the theme: nudged toward
    /// white on dark backgrounds, toward black on light ones.
    static var tabStripBackground: Color {
        let base = windowBase
        guard let base else { return dynamic(hex(0xE6E6E8), hex(0x262628)) }
        let rgb = base.usingColorSpace(.sRGB) ?? base
        let luma = 0.299 * rgb.redComponent + 0.587 * rgb.greenComponent + 0.114 * rgb.blueComponent
        let target: NSColor = luma < 0.5 ? .white : .black
        return Color(nsColor: base.blended(withFraction: luma < 0.5 ? 0.07 : 0.06, of: target) ?? base)
    }
    static let statusBarBackground = dynamic(hex(0xF1F1F2), hex(0x141416))
    static let sidebarBorder = dynamic(hex(0xD9D9D9), hex(0x292929))
    static let hairline = dynamic(hex(0x000000, alpha: 0.08), hex(0xFFFFFF, alpha: 0.06))

    /// Distinct tints for device chips (deliberately avoids the status colors).
    static let devicePalette: [Color] = [
        dynamic(hex(0x7C3AED), hex(0x8B5CF6)),  // violet
        dynamic(hex(0x0D9488), hex(0x14B8A6)),  // teal
        dynamic(hex(0xBE185D), hex(0xEC4899)),  // magenta
        dynamic(hex(0x4338CA), hex(0x818CF8)),  // indigo
        dynamic(hex(0x92640C), hex(0xC9964A)),  // bronze
    ]

    /// Stable per-device tint; Local stays neutral.
    static func deviceTint(_ device: Device) -> Color {
        if device.isLocal { return textSecondary }
        let sum = device.id.uuidString.utf8.reduce(0) { $0 &+ Int($1) }
        return devicePalette[sum % devicePalette.count]
    }

    static func statusColor(_ status: AgentStatus) -> Color {
        switch status {
        case .working: return working
        case .blocked: return warning
        case .done: return success
        case .idle, .unknown: return textGhost
        }
    }
}

/// Codex-style conversation marks: spinner while running, a filled unread
/// dot after a finish you have not opened, nothing once you have looked.
struct AgentStatusGlyph: View {
    let status: AgentStatus
    var unreadDone: Bool = false

    var body: some View {
        switch status {
        case .working:
            EmptyView()
        case .blocked:
            Image(systemName: "exclamationmark.circle")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.warning)
        case .done:
            if unreadDone {
                Circle()
                    .fill(Theme.working)
                    .frame(width: 7, height: 7)
            }
        case .idle, .unknown:
            EmptyView()
        }
    }
}

/// Space row uses the same glyph as an agent, for the strongest state inside.
struct SpaceAttentionGlyph: View {
    let attention: SpaceAttention

    var body: some View {
        switch attention {
        case .blocked:
            AgentStatusGlyph(status: .blocked)
        case .unreadDone:
            AgentStatusGlyph(status: .done, unreadDone: true)
        case .working:
            AgentStatusGlyph(status: .working)
        case .none:
            EmptyView()
        }
    }
}
