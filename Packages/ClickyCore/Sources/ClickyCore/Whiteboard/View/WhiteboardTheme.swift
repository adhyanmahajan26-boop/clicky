//
//  WhiteboardTheme.swift
//  ClickyCore
//
//  The board's three looks (v2.whiteboard.theme): paper (warm off-white,
//  dark ink, the default), chalk (a green chalkboard) and dark. Each theme
//  gives every colour the view uses: background, ink, section frames, the
//  seven element colours (stroke + light fill), the highlight halo, code
//  colours and the subtitle bar. Colours are fixed sRGB values so offscreen
//  renders are identical on every Mac.
//

import AppKit
import SwiftUI

public enum WhiteboardTheme: String, CaseIterable, Sendable {
    case paper, chalk, dark

    public init(settingValue: String?) {
        self = WhiteboardTheme(rawValue: settingValue?.lowercased() ?? "") ?? .paper
    }

    public var palette: WhiteboardPalette {
        switch self {
        case .paper: return .paper
        case .chalk: return .chalk
        case .dark: return .dark
        }
    }
}

public struct WhiteboardPalette: Sendable {
    public let background: Color
    public let ink: Color
    public let mutedInk: Color
    public let sectionStroke: Color
    public let sectionFill: Color
    public let defaultBoxFill: Color
    public let halo: Color
    public let codeBackground: Color
    public let codeHighlightLine: Color
    public let codeKeyword: Color
    public let codeString: Color
    public let codeComment: Color
    public let codeNumber: Color
    public let tableHeaderFill: Color
    public let barBackground: Color
    public let barText: Color
    public let strokeColors: [WBColor: Color]
    public let fillOpacity: Double
    /// The math renderer's ink (SwiftMath draws with an NSColor).
    public let mathInk: NSColor
    public let isDark: Bool

    public func stroke(for color: WBColor?) -> Color { color.flatMap { strokeColors[$0] } ?? ink }
    public func fill(for color: WBColor?) -> Color {
        guard let color, let stroke = strokeColors[color] else { return defaultBoxFill }
        return stroke.opacity(fillOpacity)
    }

    public func calloutColor(_ style: WBCalloutStyle) -> Color {
        switch style {
        case .info: return strokeColors[.blue] ?? ink
        case .tip: return strokeColors[.green] ?? ink
        case .warning: return strokeColors[.orange] ?? ink
        case .error: return strokeColors[.red] ?? ink
        }
    }

    /// Chart series colours, in order.
    public var chartColors: [Color] {
        [WBColor.blue, .orange, .green, .purple, .red, .yellow, .gray].compactMap { strokeColors[$0] }
    }

    static func rgb(_ hex: UInt32, _ alpha: Double = 1) -> Color {
        Color(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255, opacity: alpha)
    }

    static func nsRGB(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }

    public static let paper = WhiteboardPalette(
        background: rgb(0xFAF8F4), ink: rgb(0x23262F), mutedInk: rgb(0x6B6F7B),
        sectionStroke: rgb(0x23262F, 0.12), sectionFill: rgb(0xFFFFFF, 0.55), defaultBoxFill: rgb(0xFFFFFF, 0.9),
        halo: rgb(0xF2B705, 0.45), codeBackground: rgb(0xF1EDE3), codeHighlightLine: rgb(0xF2B705, 0.22),
        codeKeyword: rgb(0xA0369E), codeString: rgb(0x3C8A3B), codeComment: rgb(0x8F8C86), codeNumber: rgb(0xA0640A),
        tableHeaderFill: rgb(0x2D2A26, 0.07), barBackground: rgb(0x2D2A26, 0.9), barText: rgb(0xFAF7F0),
        strokeColors: [.blue: rgb(0x2F6FD6), .green: rgb(0x2E8B57), .orange: rgb(0xD9822B), .red: rgb(0xC8433A),
                       .purple: rgb(0x7B4FC9), .gray: rgb(0x6B6B6B), .yellow: rgb(0xB8961A)],
        fillOpacity: 0.14, mathInk: nsRGB(0x2D2A26), isDark: false)

    public static let chalk = WhiteboardPalette(
        background: rgb(0x263A2F), ink: rgb(0xF1F0E8), mutedInk: rgb(0xC2C8BE),
        sectionStroke: rgb(0xF1F0E8, 0.28), sectionFill: rgb(0x000000, 0.10), defaultBoxFill: rgb(0xF1F0E8, 0.06),
        halo: rgb(0xFFE88A, 0.38), codeBackground: rgb(0x1C2B23), codeHighlightLine: rgb(0xFFE88A, 0.16),
        codeKeyword: rgb(0xE3B5FF), codeString: rgb(0xB7EBA0), codeComment: rgb(0x93A096), codeNumber: rgb(0xFFC27D),
        tableHeaderFill: rgb(0xF1F0E8, 0.10), barBackground: rgb(0x111A15, 0.92), barText: rgb(0xF1F0E8),
        strokeColors: [.blue: rgb(0x9CCBFF), .green: rgb(0xA6EBB6), .orange: rgb(0xFFC27D), .red: rgb(0xFF9D95),
                       .purple: rgb(0xD3BBFF), .gray: rgb(0xCFCFCF), .yellow: rgb(0xFFE88A)],
        fillOpacity: 0.16, mathInk: nsRGB(0xF1F0E8), isDark: true)

    public static let dark = WhiteboardPalette(
        background: rgb(0x15161B), ink: rgb(0xF0F0F5), mutedInk: rgb(0x9C9EAA),
        sectionStroke: rgb(0xFFFFFF, 0.10), sectionFill: rgb(0xFFFFFF, 0.025), defaultBoxFill: rgb(0xFFFFFF, 0.06),
        halo: rgb(0xFFD54A, 0.34), codeBackground: rgb(0x1F2026), codeHighlightLine: rgb(0xFFD54A, 0.14),
        codeKeyword: rgb(0xC792EA), codeString: rgb(0xC3E88D), codeComment: rgb(0x80848E), codeNumber: rgb(0xF78C6C),
        tableHeaderFill: rgb(0xFFFFFF, 0.07), barBackground: rgb(0x0E0F13, 0.96), barText: rgb(0xF0F0F5),
        strokeColors: [.blue: rgb(0x6EA8FF), .green: rgb(0x5FD6A0), .orange: rgb(0xFFA94D), .red: rgb(0xFF7A85),
                       .purple: rgb(0xB794FF), .gray: rgb(0xA3A7B3), .yellow: rgb(0xFFD666)],
        fillOpacity: 0.14, mathInk: nsRGB(0xF0F0F5), isDark: true)
}
