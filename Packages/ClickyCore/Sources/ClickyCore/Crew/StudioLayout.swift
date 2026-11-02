//
//  StudioLayout.swift
//  ClickyCore
//
//  Studio screens' rules, with no windows or displays involved: which Macs get them, where tiles sit on a hidden screen,
//  and who is on which tile.
//

import CoreGraphics
import Foundation

public enum StudioGate {
    /// Mac Studio model identifiers so far (2022, 2023, 2025).
    public static let studioModels: Set<String> = ["Mac13,1", "Mac13,2", "Mac14,13", "Mac14,14", "Mac15,14", "Mac16,9"]

    /// A newer Studio won't be in the list yet, so the Mac's product name counts too.
    public static func isMacStudio(model: String, productName: String? = nil) -> Bool {
        studioModels.contains(model) || productName?.localizedCaseInsensitiveContains("Mac Studio") == true
    }

    /// This Mac's `hw.model`.
    public static var currentModel: String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        guard size > 0 else { return "" }
        var bytes = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &bytes, &size, nil, 0)
        return String(cString: bytes)
    }
}

public enum StudioLayout {
    public static let screenSize = CGSize(width: 1440, height: 900)

    /// Where tile `index` sits on a screen of `size`: the whole screen for one tile, else left and right halves.
    public static func tileFrame(index: Int, tilesPerScreen: Int, in size: CGSize = screenSize) -> CGRect {
        guard tilesPerScreen > 1 else { return CGRect(origin: .zero, size: size) }
        let width = (size.width / CGFloat(tilesPerScreen)).rounded(.down)
        let clamped = min(max(index, 0), tilesPerScreen - 1)
        let lastWidth = size.width - width * CGFloat(tilesPerScreen - 1)
        return CGRect(x: width * CGFloat(clamped), y: 0, width: clamped == tilesPerScreen - 1 ? lastWidth : width, height: size.height)
    }

    /// Hidden screens start at the bottom-right corner of the rightmost display, touching it only at that point, so the
    /// pointer has no edge to cross and macOS doesn't send new windows there. They run on along the same row after that.
    /// Top-left coordinates.
    public static func origins(forScreens count: Int, besides displays: [CGRect], size: CGSize = screenSize) -> [CGPoint] {
        let anchor = displays.max { ($0.maxX, $0.maxY) < ($1.maxX, $1.maxY) } ?? .zero
        return (0..<count).map { CGPoint(x: anchor.maxX + CGFloat($0) * size.width, y: anchor.maxY) }
    }

    /// Whether two displays meet along an edge the pointer could cross. A shared corner doesn't count.
    public static func shareAnEdge(_ a: CGRect, _ b: CGRect) -> Bool {
        let verticalOverlap = min(a.maxY, b.maxY) - max(a.minY, b.minY)
        let horizontalOverlap = min(a.maxX, b.maxX) - max(a.minX, b.minX)
        if (a.maxX == b.minX || b.maxX == a.minX) && verticalOverlap > 0 { return true }
        if (a.maxY == b.minY || b.maxY == a.minY) && horizontalOverlap > 0 { return true }
        return false
    }
}

/// One tile's address: screen and tile, both from 0.
public struct StudioTileID: Hashable, Codable, Sendable {
    public let screen: Int
    public let tile: Int
    public init(screen: Int, tile: Int) {
        self.screen = screen
        self.tile = tile
    }

    /// Every tile, screen by screen.
    public static func all(screens: Int, tilesPerScreen: Int) -> [StudioTileID] {
        (0..<max(screens, 0)).flatMap { screen in (0..<max(tilesPerScreen, 0)).map { StudioTileID(screen: screen, tile: $0) } }
    }
}

/// Who holds which tile. A bot has at most one; assigning it again moves it.
public struct StudioRoster: Equatable, Sendable {
    public private(set) var bots: [StudioTileID: String] = [:]
    public init() {}

    public mutating func assign(_ bot: String, to tile: StudioTileID) {
        bots = bots.filter { $0.value != bot }
        bots[tile] = bot
    }

    public mutating func clear(_ tile: StudioTileID) { bots[tile] = nil }

    /// Assignments that no longer fit (fewer tiles per screen) come off.
    public mutating func trim(screens: Int, tilesPerScreen: Int) {
        let valid = Set(StudioTileID.all(screens: screens, tilesPerScreen: tilesPerScreen))
        bots = bots.filter { valid.contains($0.key) }
    }

    public func tile(of bot: String) -> StudioTileID? { bots.first { $0.value == bot }?.key }

    /// The first free tile, if there's one.
    public func firstFree(screens: Int, tilesPerScreen: Int) -> StudioTileID? {
        StudioTileID.all(screens: screens, tilesPerScreen: tilesPerScreen).first { bots[$0] == nil }
    }
}

/// Displays that are Theo's own hidden screens. Everything that works on "the screens" (Clicky's overlay and captures,
/// "move to screen 2", the monitor picker) leaves these out.
public enum StudioDisplays {
    nonisolated(unsafe) public static var virtualIDs: Set<CGDirectDisplayID> = []
}
