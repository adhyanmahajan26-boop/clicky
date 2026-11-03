//
//  ScreenConfig.swift
//  ClickyCore
//
//  The hidden screens the owner has set up: what each one is, who it belongs to, which free tile a bot may take, and a rough
//  idea of what each one costs. Nothing here touches a display.
//

import CoreGraphics
import Foundation

public struct StudioScreenSpec: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var width: Int
    public var height: Int
    public var hiDPI: Bool
    public var refresh: Int
    public var tiles: Int
    public var previewFPS: Int
    /// Bots whose screen this is. Empty means the shared pool.
    public var owners: [String]

    public static let presets: [(width: Int, height: Int)] = [(1280, 800), (1440, 900), (1920, 1080), (2560, 1440)]
    public static let refreshRates = [30, 60, 120]
    public static let tileChoices = [1, 2, 4]
    public static let previewFPSRange = 1...15

    public init(id: String, name: String, width: Int = 1440, height: Int = 900, hiDPI: Bool = false, refresh: Int = 60, tiles: Int = 2,
                previewFPS: Int = StudioPreviewSchedule.defaultFPS, owners: [String] = []) {
        self.id = id
        self.name = name
        self.width = width
        self.height = height
        self.hiDPI = hiDPI
        self.refresh = refresh
        self.tiles = tiles
        self.previewFPS = previewFPS
        self.owners = owners
    }

    public var size: CGSize { CGSize(width: width, height: height) }
    public var sizeLabel: String { "\(width)×\(height)" }

    /// What a display needs to be made again for. Names, tiles, fps and owners change without touching it.
    func sameDisplay(as other: StudioScreenSpec) -> Bool {
        width == other.width && height == other.height && hiDPI == other.hiDPI && refresh == other.refresh
    }

    func sanitized() -> StudioScreenSpec {
        var spec = self
        spec.width = min(max(width, 640), 3840)
        spec.height = min(max(height, 480), 2160)
        spec.refresh = Self.refreshRates.contains(refresh) ? refresh : 60
        spec.tiles = Self.tileChoices.contains(tiles) ? tiles : 2
        spec.previewFPS = min(max(previewFPS, Self.previewFPSRange.lowerBound), Self.previewFPSRange.upperBound)
        return spec
    }
}

/// A bot's place on the screens.
public enum StudioScreenChoice: Equatable, Sendable {
    case none
    case sharedPool
    case screen(String)

    public var tag: String {
        switch self {
        case .none: return "none"
        case .sharedPool: return "shared"
        case .screen(let id): return id
        }
    }

    public init(tag: String) {
        switch tag {
        case "none": self = .none
        case "shared": self = .sharedPool
        default: self = .screen(tag)
        }
    }
}

public struct StudioScreensConfig: Codable, Equatable, Sendable {
    public var screens: [StudioScreenSpec]
    /// Bots the owner has said get no screen at all.
    public var noScreen: [String]

    public static let maximumScreens = 8

    public init(screens: [StudioScreenSpec], noScreen: [String] = []) {
        self.screens = screens
        self.noScreen = noScreen
    }

    /// What was there before screens could be set up: the same count, tiles and speed, and any owner the owner picked by hand.
    public static func migrated(screenCount: Int, tilesPerScreen: Int, previewFPS: Int, savedOwner: (Int) -> String?) -> StudioScreensConfig {
        let count = screenCount == 1 ? 1 : 2
        return StudioScreensConfig(screens: (0..<count).map { index in
            StudioScreenSpec(id: "screen-\(index + 1)", name: "Screen \(index + 1)", tiles: tilesPerScreen == 1 ? 1 : 2,
                             previewFPS: previewFPS > 0 ? previewFPS : StudioPreviewSchedule.defaultFPS,
                             owners: savedOwner(index).flatMap { $0.isEmpty ? nil : [$0] } ?? [])
        })
    }

    public func encoded() -> Data? { try? JSONEncoder().encode(self) }

    /// Nil when it can't be read, so the caller falls back rather than losing the screens.
    public static func decoded(_ data: Data) -> StudioScreensConfig? {
        guard let config = try? JSONDecoder().decode(StudioScreensConfig.self, from: data), !config.screens.isEmpty else { return nil }
        return StudioScreensConfig(screens: Array(config.screens.prefix(maximumScreens)).map { $0.sanitized() }, noScreen: config.noScreen)
    }

    public func needsRebuild(from old: StudioScreensConfig) -> Bool {
        guard screens.count == old.screens.count else { return true }
        return zip(screens, old.screens).contains { !$0.sameDisplay(as: $1) }
    }

    public mutating func addScreen() {
        guard screens.count < Self.maximumScreens else { return }
        var number = screens.count + 1
        while screens.contains(where: { $0.id == "screen-\(number)" }) { number += 1 }
        screens.append(StudioScreenSpec(id: "screen-\(number)", name: "Screen \(number)"))
    }

    public mutating func removeScreen(_ id: String) {
        guard screens.count > 1 else { return }
        screens.removeAll { $0.id == id }
    }

    public func choice(for bot: String) -> StudioScreenChoice {
        if noScreen.contains(bot) { return .none }
        if let own = screens.first(where: { $0.owners.contains(bot) }) { return .screen(own.id) }
        return .sharedPool
    }

    public mutating func set(_ choice: StudioScreenChoice, for bot: String) {
        noScreen.removeAll { $0 == bot }
        for index in screens.indices { screens[index].owners.removeAll { $0 == bot } }
        switch choice {
        case .none: noScreen.append(bot)
        case .sharedPool: break
        case .screen(let id):
            if let index = screens.firstIndex(where: { $0.id == id }) { screens[index].owners.append(bot) }
        }
    }

    public var allTiles: [StudioTileID] {
        screens.enumerated().flatMap { index, spec in (0..<spec.tiles).map { StudioTileID(screen: index, tile: $0) } }
    }

    /// A bot's own screens first, then the shared pool, never another bot's. Empty sends it to the queue.
    public func freeTiles(for bot: String, roster: StudioRoster) -> [StudioTileID] {
        guard !noScreen.contains(bot) else { return [] }
        let free = allTiles.filter { roster.bots[$0] == nil }
        let own = free.filter { screens[$0.screen].owners.contains(bot) }
        let shared = free.filter { screens[$0.screen].owners.isEmpty }
        return own + shared
    }
}

/// A rough idea, shown before Apply. Graphics memory can't be read back for one display, so that part stays an estimate.
public struct StudioScreenCost: Equatable, Sendable {
    public var graphicsMB: Int
    public var cpuPercent: Double
    public var memoryMB: Int

    public init(graphicsMB: Int, cpuPercent: Double, memoryMB: Int) {
        self.graphicsMB = graphicsMB
        self.cpuPercent = cpuPercent
        self.memoryMB = memoryMB
    }

    /// Three 4-byte frames of the display. About 0.6% CPU a picture, from measuring two screens at 4 fps; a faster refresh adds a
    /// little, since the window server draws to it more often. Memory is a few of the small pictures kept for the panel.
    public static func estimate(_ spec: StudioScreenSpec) -> StudioScreenCost {
        let scale = spec.hiDPI ? 4 : 1
        let graphics = spec.width * spec.height * scale * 4 * 3 / 1_048_576
        let cpu = Double(spec.previewFPS) * 0.6 * (spec.hiDPI ? 1.5 : 1) + Double(spec.refresh) / 60 * 0.4
        let pictureWidth = 360 * StudioLayout.grid(forTiles: spec.tiles).columns
        let pictureHeight = pictureWidth * spec.height / max(spec.width, 1)
        return StudioScreenCost(graphicsMB: graphics, cpuPercent: cpu, memoryMB: max(1, pictureWidth * pictureHeight * 4 * 3 / 1_048_576))
    }

    public static func total(_ specs: [StudioScreenSpec]) -> StudioScreenCost {
        specs.map(estimate).reduce(StudioScreenCost(graphicsMB: 0, cpuPercent: 0, memoryMB: 0)) {
            StudioScreenCost(graphicsMB: $0.graphicsMB + $1.graphicsMB, cpuPercent: $0.cpuPercent + $1.cpuPercent, memoryMB: $0.memoryMB + $1.memoryMB)
        }
    }

    public var label: String { "~\(graphicsMB) MB graphics · ~\(String(format: "%.1f", cpuPercent))% CPU · ~\(memoryMB) MB memory" }
}
