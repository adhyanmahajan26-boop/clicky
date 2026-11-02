//
//  TheoPalette.swift
//  ClickyCore
//
//  The Hairline tokens, as plain numbers: true black and white. DS.Colors in the app reads every colour from here.
//

import Foundation

public struct TheoInk: Equatable, Sendable {
    public let hex: UInt32
    public let alpha: Double
    public init(_ hex: UInt32, _ alpha: Double = 1) {
        self.hex = hex
        self.alpha = alpha
    }
}

public struct TheoPalette: Equatable, Sendable {
    public let background, sidebar, card, card2, line, line2, text, text2, text3, accent, accentSoft, accentInk, onAccent, selection, hover: TheoInk

    public static let black = TheoPalette(
        background: TheoInk(0x000000), sidebar: TheoInk(0x000000), card: TheoInk(0x0A0A0A), card2: TheoInk(0x141414),
        line: TheoInk(0xFFFFFF, 0.08), line2: TheoInk(0xFFFFFF, 0.15),
        text: TheoInk(0xF4F4F5), text2: TheoInk(0x9A9AA0), text3: TheoInk(0x5C5C63),
        accent: TheoInk(0xFF7A45), accentSoft: TheoInk(0xFF7A45, 0.13), accentInk: TheoInk(0xFF8D5E), onAccent: TheoInk(0x000000),
        selection: TheoInk(0xFFFFFF, 0.065), hover: TheoInk(0xFFFFFF, 0.04))

    public static let light = TheoPalette(
        background: TheoInk(0xFFFFFF), sidebar: TheoInk(0xFAFAFA), card: TheoInk(0xFFFFFF), card2: TheoInk(0xF4F4F4),
        line: TheoInk(0x000000, 0.08), line2: TheoInk(0x000000, 0.16),
        text: TheoInk(0x0B0B0C), text2: TheoInk(0x65656C), text3: TheoInk(0xA3A3A9),
        accent: TheoInk(0xEC622B), accentSoft: TheoInk(0xEC622B, 0.10), accentInk: TheoInk(0xD2511D), onAccent: TheoInk(0xFFFFFF),
        selection: TheoInk(0x000000, 0.05), hover: TheoInk(0x000000, 0.03))

    /// The accent swatches in Settings › Look, as (id, black, light).
    public static let accents: [(id: String, dark: UInt32, light: UInt32)] = [
        ("ember", 0xFF7A45, 0xEC622B), ("indigo", 0x7C8CFF, 0x5B6BE8), ("green", 0x3CC37A, 0x1F9D63),
        ("mono", 0xF5F5F5, 0x161616), ("slate", 0x8B8B95, 0x65656C),
    ]

    /// The swatch for an id, ember for an unknown one.
    public static func accent(_ id: String, dark: Bool) -> UInt32 {
        let swatch = accents.first { $0.id == id } ?? accents[0]
        return dark ? swatch.dark : swatch.light
    }
}

/// Settings › Look › Motion. Off, like macOS's Reduce Motion, stops all animation.
public enum TheoMotionLevel: String, CaseIterable, Sendable {
    case lively, calm, off
    public static let settingKey = "theo.motion"
    public var title: String { rawValue.capitalized }
}
