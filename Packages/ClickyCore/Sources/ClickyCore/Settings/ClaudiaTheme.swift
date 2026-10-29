//
//  ClaudiaTheme.swift
//  ClickyCore
//
//  Colour themes for Claudia's notes panel and her UI page (the T3 Code
//  Claudia section): "system" keeps the Mac's own colours; the others are
//  full palettes. Setup, the UI page and the notes panel all read v2.ui.theme.
//

import SwiftUI

public enum ClaudiaTheme: String, CaseIterable, Sendable {
    case system
    case claude
    case midnight
    case paper
    case neon
    case forest

    public var displayName: String {
        switch self {
        case .system: return "System (light/dark)"
        case .claude: return "Claude (warm dark)"
        case .midnight: return "Midnight (navy + teal)"
        case .paper: return "Paper (light, warm)"
        case .neon: return "Neon (black + magenta)"
        case .forest: return "Forest (deep green)"
        }
    }

    public struct Palette: Sendable {
        public let background: UInt32
        public let panel: UInt32
        public let line: UInt32
        public let text: UInt32
        public let secondary: UInt32
        public let tertiary: UInt32
        public let accent: UInt32
        public let highlighter: UInt32
    }

    /// nil for .system (the notes panel then uses the Mac's colours; the page follows light/dark).
    public var palette: Palette? {
        switch self {
        case .system: return nil
        case .claude: return Palette(background: 0x161412, panel: 0x1E1B18, line: 0x332E29, text: 0xF2EDE7, secondary: 0xB7AEA4, tertiary: 0x7D756C, accent: 0xD97757, highlighter: 0xFFC857)
        case .midnight: return Palette(background: 0x0B1120, panel: 0x111A2E, line: 0x1F2B45, text: 0xE6EDF7, secondary: 0x9FB0C8, tertiary: 0x66758F, accent: 0x4FD1C5, highlighter: 0x7CF7C8)
        case .paper: return Palette(background: 0xF4EFE6, panel: 0xFBF8F2, line: 0xE3DCCF, text: 0x2B2620, secondary: 0x6F675C, tertiary: 0xA39A8E, accent: 0xC2652F, highlighter: 0xFFE066)
        case .neon: return Palette(background: 0x060609, panel: 0x0E0E15, line: 0x24243A, text: 0xF5F5FF, secondary: 0xB9B9D6, tertiary: 0x6E6E8C, accent: 0xFF3DCB, highlighter: 0x3DF5FF)
        case .forest: return Palette(background: 0x0E1813, panel: 0x13201A, line: 0x24382D, text: 0xE8F2EC, secondary: 0xA3BFB0, tertiary: 0x6C8A7A, accent: 0x7BD389, highlighter: 0xD4F27B)
        }
    }

    public static func color(_ hex: UInt32) -> Color {
        Color(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }

    public static func cssHex(_ hex: UInt32) -> String { String(format: "#%06X", hex) }
}
