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
        case none, ball, twin, dish, flag, bolt, heart, cursor
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

    public static let shellOrder = ["white", "graphite", "black", "cream", "sky", "mint", "blush"]
    public static let shells: [String: UInt32] = ["white": 0xECECEE, "graphite": 0x3B3B40, "black": 0x161616, "cream": 0xEFE5D3,
                                                  "sky": 0xCFE1FF, "mint": 0xCDEEDD, "blush": 0xF6D2DB]
    public static let glows = ["#ff7a45", "#f5b03c", "#ff6f9f", "#a3e635", "#34d3e6", "#60a5fa", "#a78bfa", "#f87171", "#f4f4f5"]
    public static let hatColors = ["#f5b03c", "#ff6f9f", "#a3e635", "#60a5fa", "#a78bfa", "#f87171", "#1c1c1c", "#f4f4f5"]

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

    public static let theo = CrewLook(shell: "black", glow: "#ff7a45", hat: .none, hatColor: "#ff7a45", antenna: .ball, eyes: .pill, extra: .tie)
    public static let clicky = CrewLook(shell: "white", glow: "#ff9a5c", hat: .none, hatColor: "#ff9a5c", antenna: .cursor, eyes: .round, extra: .none)
    public static let builder = CrewLook(glow: "#f5b03c", hat: .hardhat, hatColor: "#f5b03c")
    public static let designer = CrewLook(glow: "#ff6f9f", hat: .beret, hatColor: "#ff6f9f", eyes: .round, extra: .scarf)
    public static let researcher = CrewLook(glow: "#34d3e6", hatColor: "#34d3e6", antenna: .dish, eyes: .round, extra: .glasses)
    public static let inbox = CrewLook(glow: "#a3e635", hat: .headset, hatColor: "#a3e635", eyes: .pixel)
    public static let copyEditor = CrewLook(glow: "#60a5fa", hat: .beanie, hatColor: "#60a5fa", extra: .pencil)
    public static let release = CrewLook(glow: "#f87171", hatColor: "#f87171", antenna: .flag)
    public static let reviewer = CrewLook(glow: "#a78bfa", hatColor: "#a78bfa", antenna: .twin, eyes: .visor, extra: .badge)

    /// The look a bot wears until someone dresses it: the gear of its job when its name says what that is, otherwise one
    /// picked from its id, so it never changes between launches.
    public static func standard(id: String, name: String, isPrimary: Bool = false) -> CrewLook {
        if isPrimary || id == "theo" { return .theo }
        if id == "clicky" { return .clicky }
        let words = name.lowercased()
        let jobs: [(needles: [String], look: CrewLook)] = [
            (["build", "engineer", "coder", "developer", "runner"], .builder),
            (["design"], .designer),
            (["research", "memory", "analyst"], .researcher),
            (["inbox", "mail", "triage", "support"], .inbox),
            (["copy", "writer", "editor"], .copyEditor),
            (["release", "ship", "deploy"], .release),
            (["review", "qa", "test"], .reviewer),
        ]
        if let job = jobs.first(where: { $0.needles.contains { words.contains($0) } }) { return job.look }
        var generator = SeededGenerator(seed: id)
        return shuffled(using: &generator)
    }

    /// A random tasteful figure: mostly light bodies, one colour family, and only one thing on its head most of the time.
    public static func shuffled<G: RandomNumberGenerator>(using generator: inout G) -> CrewLook {
        let shell = ["white", "white", "white", "white", "graphite", "cream", "sky", "mint", "blush"].randomElement(using: &generator) ?? "white"
        let glow = glows.dropLast().randomElement(using: &generator) ?? "#f5b03c"
        let hat = Hat.allCases.randomElement(using: &generator) ?? .none
        let antenna: Antenna = hat == .none ? (Antenna.pickable.dropFirst().randomElement(using: &generator) ?? .ball) : .none
        // The hat matches the glow when that colour is in the hat row, and is a neighbour otherwise.
        let hatColor = hatColors.contains(glow) ? glow : (hatColors.dropLast(2).randomElement(using: &generator) ?? "#f5b03c")
        return CrewLook(shell: shell, glow: glow, hat: hat, hatColor: hatColor, antenna: antenna,
                        eyes: Eyes.allCases.dropLast().randomElement(using: &generator) ?? .pill,
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
