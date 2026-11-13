//
//  TheoTokens.swift
//  leanring-buddy
//
//  Theo's colours and corner sizes for its dark floating surfaces (the menu-bar
//  panel, diagnostics, small indicators), plus the pointing-hand cursor modifier.
//  `DS` is the short name the views use.
//

import AppKit
import ClickyCore
import SwiftUI

enum DS {
    /// The Hairline palette (TheoPalette in ClickyCore): true black or white, one accent, hairlines. Every view gets its
    /// colours here; the values adapt to the window's appearance.
    enum Colors {
        static let background = ink(\.background)
        /// Cards and the composer.
        static let surface1 = ink(\.card)
        /// Popovers, panels, the user's bubble, code blocks.
        static let surface = ink(\.card2)
        static let surface3 = surface
        static let sidebar = ink(\.sidebar)
        static let hover = ink(\.hover)
        static let selected = ink(\.selection)
        static let borderSubtle = ink(\.line)
        static let borderStrong = ink(\.line2)
        static let textPrimary = ink(\.text)
        static let textSecondary = ink(\.text2)
        static let textTertiary = ink(\.text3)
        static let textDisabled = ink(\.text3)
        static let textOnAccent = dynamic { dark in
            let accent = TheoPalette.accent(accentID, dark: dark)
            // Black on a bright accent, white on a dark one, whichever the swatch needs.
            return NSColor(hex: luminance(accent) > 0.32 ? 0x000000 : 0xFFFFFF)
        }
        /// The accent: the primary button, focus ring, send, live dots and the one detail on an icon.
        static let accent = dynamic { NSColor(hex: TheoPalette.accent(accentID, dark: $0)) }
        /// The accent as words and small marks, dark enough to read on a light page.
        static let accentText = dynamic { dark in
            guard accentID == "ember" else { return NSColor(hex: TheoPalette.accent(accentID, dark: dark)) }
            let palette = dark ? TheoPalette.black : TheoPalette.light
            return NSColor(hex: palette.accentInk.hex)
        }
        /// The accent behind text.
        static let accentFill = accent
        /// The accent as a soft wash.
        static let accentSoft = dynamic { NSColor(hex: TheoPalette.accent(accentID, dark: $0), alpha: $0 ? 0.13 : 0.10) }
        /// The leader's crown and label.
        static let gold = adaptive(dark: 0xF5B13D, light: 0x9A6400)
        /// A neutral tile behind a logo.
        static let logoTile = adaptive(dark: 0xFFFFFF, light: 0x000000, darkAlpha: 0.07, lightAlpha: 0.04)
        static let overlayCompanionOrange = Color(red: 0.85, green: 0.47, blue: 0.34)
        static let blue = adaptive(dark: 0x5B8DEF, light: 0x3B6FD4)
        static let blue400 = blue
        // Status colours belong to status alone (kit/tokens.json): green working, yellow needs you, red failed. Fills are the
        // same on both themes; words get a darker shade on white so they stay readable. The accent is never a status.
        static let success = adaptive(dark: 0x22D391, light: 0x22D391)
        static let successText = adaptive(dark: 0x22D391, light: 0x0A7F54)
        static let warningText = adaptive(dark: 0xFFD938, light: 0x7A5B00)
        static let warning = adaptive(dark: 0xFFD938, light: 0xFFD938)
        static let destructiveText = adaptive(dark: 0xFF6B7C, light: 0xC7283B)
        /// Red as a fill (a failed step, a badge).
        static let destructive = adaptive(dark: 0xFF4A5E, light: 0xFF4A5E)

        static func adaptive(dark: UInt32, light: UInt32, darkAlpha: CGFloat = 1, lightAlpha: CGFloat = 1) -> Color {
            dynamic { NSColor(hex: $0 ? dark : light, alpha: $0 ? darkAlpha : lightAlpha) }
        }

        private static func ink(_ token: KeyPath<TheoPalette, TheoInk>) -> Color {
            dynamic { dark in
                let value = (dark ? TheoPalette.black : TheoPalette.light)[keyPath: token]
                return NSColor(hex: value.hex, alpha: value.alpha)
            }
        }

        /// A colour that's worked out per theme, dark first.
        static func dynamicColor(_ make: @escaping (Bool) -> NSColor) -> Color { dynamic(make) }

        private static func dynamic(_ make: @escaping (Bool) -> NSColor) -> Color {
            Color(nsColor: NSColor(name: nil) { make($0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua) })
        }

        private static var accentID: String { UserDefaults.standard.string(forKey: TheoAccent.settingKey) ?? "ember" }

        private static func luminance(_ hex: UInt32) -> Double {
            0.2126 * Double((hex >> 16) & 0xFF) / 255 + 0.7152 * Double((hex >> 8) & 0xFF) / 255 + 0.0722 * Double(hex & 0xFF) / 255
        }
    }

    enum CornerRadius {
        static let small: CGFloat = 6
        static let medium: CGFloat = 8
        static let large: CGFloat = 12
        static let panel: CGFloat = 16
    }

    enum Motion {
        /// Settings › Look › Motion, with macOS's Reduce Motion counting as Off.
        static var level: TheoMotionLevel {
            if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { return .off }
            return TheoMotionLevel(rawValue: UserDefaults.standard.string(forKey: TheoMotionLevel.settingKey) ?? "") ?? .calm
        }
        static var isReduced: Bool { level == .off }
        static var hover: Animation { isReduced ? .linear(duration: 0) : .snappy(duration: 0.18) }
        static var panel: Animation { isReduced ? .linear(duration: 0) : .spring(response: 0.35, dampingFraction: 0.86) }
    }
}

/// The accent swatch in Settings › Look.
enum TheoAccent {
    static let settingKey = "theo.accent"
}

/// Black, Light or follow the Mac. True black is Theo's own look, so it's the default.
enum TheoAppearance: String, CaseIterable, Identifiable {
    case dark, light, system
    static let settingKey = "theo.appearance"
    var id: String { rawValue }
    var title: String { self == .dark ? "Black" : self == .light ? "Light" : "Match Mac" }
    var symbol: String { self == .dark ? "moon.fill" : self == .light ? "sun.max.fill" : "circle.lefthalf.filled" }
    var colorScheme: ColorScheme? { self == .dark ? .dark : self == .light ? .light : nil }
    /// For AppKit surfaces such as the terminal's window.
    static var current: TheoAppearance { TheoAppearance(rawValue: UserDefaults.standard.string(forKey: settingKey) ?? "") ?? .dark }
}

/// Applies the appearance setting to a window's root view.
struct TheoAppearanceRoot: ViewModifier {
    @AppStorage(TheoAppearance.settingKey) private var appearance = TheoAppearance.dark.rawValue
    @AppStorage(TheoAccent.settingKey) private var accent = "ember"
    func body(content: Content) -> some View {
        // The accent is read when a colour draws, so a new swatch redraws the tree.
        content.id(accent).preferredColorScheme(TheoAppearance(rawValue: appearance)?.colorScheme)
    }
}

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
}

extension Color {
    init(hex: UInt32) { self.init(nsColor: NSColor(hex: hex)) }
}

extension View {
    /// Shows the pointing hand while the pointer is over this view.
    func pointerCursor(isEnabled: Bool = true) -> some View {
        onHover { isInside in
            guard isEnabled else { return }
            if isInside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
    }
}
