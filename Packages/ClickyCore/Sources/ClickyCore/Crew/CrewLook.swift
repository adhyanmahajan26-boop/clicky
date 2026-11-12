//
//  CrewLook.swift
//  ClickyCore
//
//  What a bot looks like: the parts of its crew figure, saved as a small JSON field on the bot. Values Theo doesn't know
//  (a newer version's hat, say) fall back to a default rather than losing the bot.
//

import Foundation

/// What a figure is doing, from the bot's real state.
public enum CrewPose: String, CaseIterable, Sendable {
    case sleep, awake, working, needs, done, talking
}

public struct CrewLook: Codable, Equatable, Sendable {
    public enum Hat: String, CaseIterable, Codable, Sendable { case none, hardhat, beret, cap, beanie, tophat, crown, headset }
    /// `cursor` is Clicky's alone: `pickable` leaves it out.
    public enum Antenna: String, CaseIterable, Codable, Sendable {
        case none, ball, twin, dish, flag, bolt, heart, cursor, handle
        public static let pickable = allCases.filter { $0 != .cursor }
    }
    public enum Eyes: String, CaseIterable, Codable, Sendable { case pill, round, pixel, visor, hearts }
    public enum Extra: String, CaseIterable, Codable, Sendable { case none, tie, bowtie, scarf, glasses, pencil, badge }

    /// A name from `shells`.
    public var shell: String
    /// "#rrggbb".
    public var glow: String
    public var hat: Hat
    public var hatColor: String
    public var antenna: Antenna
    public var eyes: Eyes
    public var extra: Extra

    public init(shell: String = "white", glow: String = "#f5b03c", hat: Hat = .none, hatColor: String = "#f5b03c",
                antenna: Antenna = .none, eyes: Eyes = .pill, extra: Extra = .none) {
        self.shell = shell
        self.glow = glow
        self.hat = hat
        self.hatColor = hatColor
        self.antenna = antenna
        self.eyes = eyes
        self.extra = extra
    }

    // MARK: Palettes (body, screen glow, hat)

    /// The nine Pixel finishes, by the names a look saves them under (the old names where a finish had one before).
    public static let shellOrder = ["white", "graphite", "black", "cream", "sky", "lilac", "blush", "slate", "cocoa"]
    /// Every body a saved look may name. Mint stays readable for old looks; it draws as slate.
    public static let shells: [String: UInt32] = ["white": 0xECECEE, "graphite": 0x3B3B40, "black": 0x161616, "cream": 0xEFE5D3,
                                                  "sky": 0xCFE1FF, "mint": 0xCDEEDD, "blush": 0xF6D2DB,
                                                  "lilac": 0xCDBFF2, "slate": 0xA8B4C0, "cocoa": 0x8A6656,
                                                  "bone": 0xECECEE, "onyx": 0x161616, "sand": 0xEFE5D3]
    /// The seven Pixel trims. Older looks may hold any of the old glows; `pixel` maps those across.
    public static let glows = ["#ff7a45", "#f06fb0", "#45c8e6", "#5b8def", "#9b7bf0", "#f4f4f5", "#f4d7c4"]
    public static let hatColors = glows

    public var isDarkShell: Bool { shell == "black" || shell == "graphite" }
    public var shellHex: UInt32 { Self.shells[shell] ?? 0xECECEE }
    public static func hex(_ text: String) -> UInt32 { UInt32(text.dropFirst(text.hasPrefix("#") ? 1 : 0), radix: 16) ?? 0xF5B03C }

    /// The tie, bowtie, scarf and pencil take the hat colour; the badge and glasses take the screen glow.
    public var extraColor: String { extra == .badge || extra == .glasses ? glow : hatColor }
    /// How far the antenna rises so it clears the hat, in the figure's 48-unit box.
    public var antennaLift: Double {
        switch hat {
        case .hardhat: return -3.5
        case .beanie: return -4.5
        case .cap: return -1.5
        case .tophat: return -8.5
        case .crown: return -4
        case .beret: return -1.5
        case .none, .headset: return 0
        }
    }

    // MARK: Presets

    // The Pixel crew (pixel-faces.json, "crew"). Eyes and extras keep their old names: pill is tall, pixel is block, visor
    // is wide, glasses is the bezel and badge is the star.
    public static let theo = CrewLook(shell: "black", glow: "#ff7a45", hat: .none, hatColor: "#ff7a45", antenna: .ball, eyes: .pixel, extra: .tie)
    public static let clicky = CrewLook(shell: "white", glow: "#ff9a5c", hat: .none, hatColor: "#ff9a5c", antenna: .cursor, eyes: .round, extra: .none)
    public static let manager = CrewLook(shell: "graphite", glow: "#f4d7c4", hat: .tophat, hatColor: "#f4d7c4", eyes: .pill, extra: .bowtie)
    public static let accountant = CrewLook(shell: "white", glow: "#45c8e6", hatColor: "#45c8e6", eyes: .round, extra: .glasses)
    public static let builder = CrewLook(shell: "white", glow: "#5b8def", hatColor: "#5b8def", antenna: .handle, eyes: .visor)
    public static let designer = CrewLook(shell: "lilac", glow: "#f06fb0", hat: .beret, hatColor: "#f06fb0", eyes: .pill)
    public static let researcher = CrewLook(shell: "sky", glow: "#f4f4f5", hatColor: "#f4f4f5", antenna: .twin, eyes: .round)
    public static let inbox = CrewLook(shell: "cream", glow: "#45c8e6", hat: .headset, hatColor: "#45c8e6", eyes: .round)
    public static let copyEditor = CrewLook(shell: "slate", glow: "#f4f4f5", hatColor: "#f4f4f5", antenna: .handle, eyes: .pill, extra: .pencil)
    public static let release = CrewLook(shell: "cocoa", glow: "#f4d7c4", hatColor: "#f4d7c4", antenna: .flag, eyes: .visor)
    public static let reviewer = CrewLook(shell: "graphite", glow: "#9b7bf0", hatColor: "#9b7bf0", antenna: .twin, eyes: .pixel, extra: .badge)

    /// The look a bot wears until someone dresses it: the gear of its job when its name says what that is, otherwise one
    /// picked from its id, so it never changes between launches.
    /// `role` is the bot's description, used when its name doesn't say what it does.
    public static func standard(id: String, name: String, isPrimary: Bool = false, role: String? = nil) -> CrewLook {
        if isPrimary || id == "theo" { return .theo }
        if id == "clicky" { return .clicky }
        if let look = look(forJob: name) ?? role.flatMap(look(forJob:)) { return look }
        var generator = SeededGenerator(seed: id)
        return shuffled(using: &generator)
    }

    /// The figure for a job, if these words name one.
    private static func look(forJob text: String) -> CrewLook? {
        let words = text.lowercased()
        let jobs: [(needles: [String], look: CrewLook)] = [
            (["build", "engineer", "coder", "developer", "runner"], .builder),
            (["design"], .designer),
            (["research", "memory", "analyst"], .researcher),
            (["inbox", "mail", "triage", "support"], .inbox),
            (["copy", "writer", "editor"], .copyEditor),
            (["release", "ship", "deploy"], .release),
            (["review", "qa", "test"], .reviewer),
            (["account", "finance", "pricing", "invoice", "ledger", "budget"], .accountant),
            (["ceo", "manager", "planner", "lead", "head of"], .manager),
        ]
        return jobs.first(where: { $0.needles.contains { words.contains($0) } })?.look
    }

    /// A random tasteful figure: any finish, one trim, and one thing on its head (an antenna or a hat, never both).
    public static func shuffled<G: RandomNumberGenerator>(using generator: inout G) -> CrewLook {
        let shell = shellOrder.randomElement(using: &generator) ?? "white"
        let trim = glows.randomElement(using: &generator) ?? "#ff7a45"
        // About a third of bots wear a hat.
        let wearsHat = Int.random(in: 0..<3, using: &generator) == 0
        let hat: Hat = wearsHat ? (Hat.allCases.dropFirst().randomElement(using: &generator) ?? .cap) : .none
        let antenna: Antenna = wearsHat ? .none : (Antenna.pickable.randomElement(using: &generator) ?? .ball)
        return CrewLook(shell: shell, glow: trim, hat: hat, hatColor: trim, antenna: antenna,
                        eyes: Eyes.allCases.randomElement(using: &generator) ?? .pixel,
                        extra: Extra.allCases.randomElement(using: &generator) ?? .none)
    }

    public static func shuffled() -> CrewLook {
        var generator = SystemRandomNumberGenerator()
        return shuffled(using: &generator)
    }

    // MARK: Saving

    private enum CodingKeys: String, CodingKey { case shell, glow, hat, hatColor, antenna, eyes, extra }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        func text(_ key: CodingKeys) -> String? { (try? values.decodeIfPresent(String.self, forKey: key)) ?? nil }
        shell = text(.shell).flatMap { Self.shells[$0] == nil ? nil : $0 } ?? "white"
        glow = text(.glow) ?? "#f5b03c"
        hatColor = text(.hatColor) ?? glow
        hat = text(.hat).flatMap(Hat.init(rawValue:)) ?? .none
        antenna = text(.antenna).flatMap(Antenna.init(rawValue:)) ?? .none
        eyes = text(.eyes).flatMap(Eyes.init(rawValue:)) ?? .pill
        extra = text(.extra).flatMap(Extra.init(rawValue:)) ?? .none
    }
}

/// FNV-1a over the seed, then SplitMix64: the same seed always makes the same bot.
public struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    public init(seed: String) {
        var hash: UInt64 = 1469598103934665603
        for byte in seed.utf8 { hash = (hash ^ UInt64(byte)) &* 1099511628211 }
        state = hash
    }

    public mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var mixed = state
        mixed = (mixed ^ (mixed >> 30)) &* 0xBF58476D1CE4E5B9
        mixed = (mixed ^ (mixed >> 27)) &* 0x94D049BB133111EB
        return mixed ^ (mixed >> 31)
    }
}
