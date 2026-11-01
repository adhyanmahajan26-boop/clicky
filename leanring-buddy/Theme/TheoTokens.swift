//
//  TheoTokens.swift
//  leanring-buddy
//
//  Theo's colours and corner sizes for its dark floating surfaces (the menu-bar
//  panel, diagnostics, small indicators), plus the pointing-hand cursor modifier.
//  `DS` is the short name the views use.
//

import AppKit
import SwiftUI

enum DS {
    /// The palette from docs/DESIGN.md: two surfaces, three text tiers, one accent (ember), adaptive to
    /// light and dark.
    enum Colors {
        static let background = adaptive(dark: 0x0E0E10, light: 0xFAFAF9)
        /// Cards and the composer.
        static let surface1 = adaptive(dark: 0x17171A, light: 0xFFFFFF)
        /// Popovers, panels, the user's bubble, code blocks.
        static let surface = adaptive(dark: 0x1E1E22, light: 0xF5F5F3)
        static let surface3 = surface
        static let sidebar = adaptive(dark: 0x121214, light: 0xF1F0EE)
        static let hover = adaptive(dark: 0xFFFFFF, light: 0x000000, darkAlpha: 0.05, lightAlpha: 0.04)
        static let selected = adaptive(dark: 0xFFFFFF, light: 0x000000, darkAlpha: 0.12, lightAlpha: 0.09)
        static let borderSubtle = adaptive(dark: 0xFFFFFF, light: 0x000000, darkAlpha: 0.08, lightAlpha: 0.10)
        static let borderStrong = adaptive(dark: 0xFFFFFF, light: 0x000000, darkAlpha: 0.14, lightAlpha: 0.16)
        static let textPrimary = adaptive(dark: 0xF2F2F4, light: 0x17171A)
        static let textSecondary = adaptive(dark: 0xA1A1AA, light: 0x5C5C66)
        static let textTertiary = adaptive(dark: 0x83838D, light: 0x72727C)
        static let textDisabled = adaptive(dark: 0x4A4A52, light: 0xB4B4BC)
        static let textOnAccent = Color.white
        /// Ember: the primary button, focus ring, send and the selection dot. Nothing else.
        static let accent = adaptive(dark: 0xE8704F, light: 0xD9532F)
        /// Ember as words and small marks, dark enough to read on a light page.
        static let accentText = adaptive(dark: 0xE8704F, light: 0xB8431F)
        /// Ember behind white text.
        static let accentFill = Color(hex: 0xC8502F)
        /// The leader's crown and label.
        static let gold = adaptive(dark: 0xF5B13D, light: 0x9A6400)
        /// A neutral tile behind a logo.
        static let logoTile = adaptive(dark: 0xFFFFFF, light: 0x000000, darkAlpha: 0.07, lightAlpha: 0.04)
        static let overlayCompanionOrange = Color(red: 0.85, green: 0.47, blue: 0.34)
        static let blue = adaptive(dark: 0x5B8DEF, light: 0x3B6FD4)
        static let blue400 = blue
        static let success = adaptive(dark: 0x3FB87A, light: 0x1F9D63)
        static let successText = adaptive(dark: 0x3FB87A, light: 0x15794B)
        static let warningText = adaptive(dark: 0xE5A94B, light: 0x8F5E12)
        static let warning = adaptive(dark: 0xE5A94B, light: 0xB7791F)
        static let destructiveText = adaptive(dark: 0xE5594F, light: 0xD1453B)

        static func adaptive(dark: UInt32, light: UInt32, darkAlpha: CGFloat = 1, lightAlpha: CGFloat = 1) -> Color {
            Color(nsColor: NSColor(name: nil) { appearance in
                let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                return NSColor(hex: isDark ? dark : light, alpha: isDark ? darkAlpha : lightAlpha)
            })
        }
    }

    enum CornerRadius {
        static let small: CGFloat = 6
        static let medium: CGFloat = 8
        static let large: CGFloat = 12
        static let panel: CGFloat = 16
    }

    enum Motion {
        static var isReduced: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
        static var hover: Animation { isReduced ? .linear(duration: 0) : .snappy(duration: 0.18) }
        static var panel: Animation { isReduced ? .linear(duration: 0) : .spring(response: 0.35, dampingFraction: 0.86) }
    }
}

/// Light, dark or follow the Mac. Dark is Theo's own look, so it's the default.
enum TheoAppearance: String, CaseIterable, Identifiable {
    case dark, light, system
    static let settingKey = "theo.appearance"
    var id: String { rawValue }
    var title: String { self == .dark ? "Dark" : self == .light ? "Light" : "Match my Mac" }
    var symbol: String { self == .dark ? "moon.fill" : self == .light ? "sun.max.fill" : "circle.lefthalf.filled" }
    var colorScheme: ColorScheme? { self == .dark ? .dark : self == .light ? .light : nil }
    /// For AppKit surfaces such as the terminal's window.
    static var current: TheoAppearance { TheoAppearance(rawValue: UserDefaults.standard.string(forKey: settingKey) ?? "") ?? .dark }
}

/// Applies the appearance setting to a window's root view.
struct TheoAppearanceRoot: ViewModifier {
    @AppStorage(TheoAppearance.settingKey) private var appearance = TheoAppearance.dark.rawValue
    func body(content: Content) -> some View {
        content.preferredColorScheme(TheoAppearance(rawValue: appearance)?.colorScheme)
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
