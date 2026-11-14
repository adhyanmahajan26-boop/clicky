//
//  StudioLayout.swift
//  ClickyCore
//
//  Studio screens' rules, with no windows or displays involved: where tiles sit on a hidden screen, and who is on which tile.
//

import CoreGraphics
import Foundation

public enum StudioGate {
    /// Mac Studio model identifiers so far (2022, 2023, 2025). Any Mac can have hidden screens now; this is only for reading settings
    /// saved by builds that knew a Mac Studio and a MacBook Air and nothing else (`DeviceChoice.fromSaved`).
    public static let studioModels: Set<String> = ["Mac13,1", "Mac13,2", "Mac14,13", "Mac14,14", "Mac15,14", "Mac16,9"]

    /// A newer Studio won't be in the list yet, so the Mac's product name counts too. Old settings only, as above.
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

    /// Tiles go side by side, except 4, which make a square.
    public static func grid(forTiles tiles: Int) -> (columns: Int, rows: Int) {
        tiles == 4 ? (2, 2) : (max(tiles, 1), 1)
    }

    /// Where tile `index` sits on a screen of `size`: the whole screen for one tile, else left and right halves, or quarters
    /// reading from the top left. Bottom-left coordinates.
    public static func tileFrame(index: Int, tilesPerScreen: Int, in size: CGSize = screenSize) -> CGRect {
        guard tilesPerScreen > 1 else { return CGRect(origin: .zero, size: size) }
        if tilesPerScreen == 4 {
            let clamped = min(max(index, 0), 3)
            let width = (size.width / 2).rounded(.down), height = (size.height / 2).rounded(.down)
            return CGRect(x: clamped % 2 == 0 ? 0 : width, y: clamped < 2 ? height : 0,
                          width: clamped % 2 == 0 ? width : size.width - width, height: clamped < 2 ? size.height - height : height)
        }
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

    /// The same, for screens of different sizes.
    public static func origins(forSizes sizes: [CGSize], besides displays: [CGRect]) -> [CGPoint] {
        let anchor = displays.max { ($0.maxX, $0.maxY) < ($1.maxX, $1.maxY) } ?? .zero
        var x = anchor.maxX
        return sizes.map { size in
            defer { x += size.width }
            return CGPoint(x: x, y: anchor.maxY)
        }
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

/// Capturing can black out protected video, so nothing is captured while macOS says something is playing.
public enum StudioCaptureGuard {
    /// macOS's names for "something's playing": Safari's, then Chrome's and everyone else's. Anything keeping the display awake
    /// for another reason (Universal Control, say) doesn't count.
    public static func videoIsPlaying(assertionNames: [String]) -> Bool {
        assertionNames.contains { name in
            let lowered = name.lowercased()
            return ["htmlmediaelement", "media playback", "playing video", "playing audio", "video wake lock", "audio wake lock"].contains { lowered.contains($0) }
        }
    }
}

/// What a tile's agent is reading, from the page itself, with no capture.
public struct StudioTilePage: Codable, Equatable, Sendable {
    public var host: String
    public var title: String?
    public var excerpt: String

    public init(host: String, title: String?, text: String) {
        self.host = host
        self.title = title
        excerpt = String(text.prefix(420))
    }
}

/// The Studio's panel as the other Mac sees it, sent over Theo Link.
public struct StudioRemoteView: Codable, Equatable, Sendable {
    public struct Tile: Codable, Equatable, Sendable {
        public var screen: Int
        public var tile: Int
        public var bot: String
        public var note: String?
        public var page: StudioTilePage?
        public var jpeg: Data?

        public init(screen: Int, tile: Int, bot: String, note: String?, page: StudioTilePage?, jpeg: Data?) {
            self.screen = screen
            self.tile = tile
            self.bot = bot
            self.note = note
            self.page = page
            self.jpeg = jpeg
        }
    }

    public var isOn: Bool
    public var screens: Int
    public var tilesPerScreen: Int
    public var paused: Bool
    public var tiles: [Tile]

    public init(isOn: Bool, screens: Int, tilesPerScreen: Int, paused: Bool, tiles: [Tile]) {
        self.isOn = isOn
        self.screens = screens
        self.tilesPerScreen = tilesPerScreen
        self.paused = paused
        self.tiles = tiles
    }

    /// "Ideas · Reading example.com" as a heading and a line under it.
    public static func headline(note: String?, fallback: String) -> (title: String, detail: String?) {
        guard let note else { return (fallback, nil) }
        let parts = note.components(separatedBy: " · ")
        return parts.count > 1 ? (parts[0], parts.dropFirst().joined(separator: " · ")) : (fallback, note)
    }
}

/// Live views in the panel: when each tile gets a new picture, and what may ever be captured.
public enum StudioPreviewSchedule {
    public static let defaultFPS = 2
    /// The tile the owner is hovering or has opened.
    public static let focusedFPS = 6

    public static func framesPerSecond(for tile: StudioTileID, focused: StudioTileID?, base: Int = defaultFPS) -> Int {
        tile == focused ? max(focusedFPS, base) : max(1, base)
    }

    /// `last` nil means it has no picture yet.
    public static func isDue(_ tile: StudioTileID, last: Double?, now: Double, focused: StudioTileID?, base: Int = defaultFPS) -> Bool {
        guard let last else { return true }
        // A little under the interval, or a timer that's slightly early skips a whole frame.
        return now - last >= 0.9 / Double(framesPerSecond(for: tile, focused: focused, base: base))
    }

    /// Whether a window may be captured: wholly on one of Theo's hidden screens. Nothing on the owner's monitors, ever.
    public static func mayCapture(window: CGRect, hiddenScreens: [CGRect]) -> Bool {
        guard window.width > 0, window.height > 0 else { return false }
        return hiddenScreens.contains { $0.insetBy(dx: -1, dy: -1).contains(window) }
    }

    /// The tile a window sits on, by its centre.
    public static func tile(of window: CGRect, hiddenScreens: [CGRect], tilesPerScreen: Int) -> StudioTileID? {
        let centre = CGPoint(x: window.midX, y: window.midY)
        guard let screen = hiddenScreens.firstIndex(where: { $0.contains(centre) }) else { return nil }
        let box = hiddenScreens[screen]
        let tiles = max(tilesPerScreen, 1)
        let column = min(Int((centre.x - box.minX) / (box.width / CGFloat(tiles))), tiles - 1)
        return StudioTileID(screen: screen, tile: column)
    }
}

/// One real monitor as it stands: where it is and what mode it's in.
public struct RealDisplayState: Equatable, Sendable {
    public let id: UInt32
    public let x: Int
    public let y: Int
    public let width: Int
    public let height: Int
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let refreshRate: Double
    public let rotation: Double

    public init(id: UInt32, x: Int, y: Int, width: Int, height: Int, pixelWidth: Int, pixelHeight: Int, refreshRate: Double, rotation: Double) {
        self.id = id
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.refreshRate = refreshRate
        self.rotation = rotation
    }
}

/// Studio must leave the owner's monitors exactly as it found them. This says what's different from how they were just
/// before it turned on.
public enum StudioDisplayGuard {
    public enum Difference: Equatable, Sendable {
        case moved(UInt32)
        /// Resolution, scale or refresh rate.
        case modeChanged(UInt32)
        case rotated(UInt32)
    }

    /// A monitor that's been unplugged isn't a difference: there's nothing to put back.
    public static func differences(baseline: [RealDisplayState], now: [RealDisplayState]) -> [Difference] {
        baseline.flatMap { before -> [Difference] in
            guard let current = now.first(where: { $0.id == before.id }) else { return [] }
            var found: [Difference] = []
            if current.x != before.x || current.y != before.y { found.append(.moved(before.id)) }
            if current.width != before.width || current.height != before.height || current.pixelWidth != before.pixelWidth
                || current.pixelHeight != before.pixelHeight || abs(current.refreshRate - before.refreshRate) >= 0.5 { found.append(.modeChanged(before.id)) }
            if current.rotation != before.rotation { found.append(.rotated(before.id)) }
            return found
        }
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

    /// Research can have a page on each of several tiles at once.
    public mutating func hold(_ bot: String, tile: StudioTileID) { bots[tile] = bot }

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
