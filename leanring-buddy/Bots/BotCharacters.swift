//
//  BotCharacters.swift
//  leanring-buddy
//
//  The old character ids a bot may still have in `NativeBot.avatar`. Bots are drawn as crew figures now
//  (Crew/CrewFigure.swift); these only remain as names a stencil starts from.
//

import SwiftUI

enum BotCharacter: String, CaseIterable, Identifiable {
    case pebble, bolt, orbit, moth, tank, sprout, spark, cloud, ghost, owl, cube, drop, shield, cat, gem, tube

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pebble: return "Pebble"
        case .bolt: return "Bolt"
        case .orbit: return "Orbit"
        case .moth: return "Moth"
        case .tank: return "Tread"
        case .sprout: return "Sprout"
        case .spark: return "Spark"
        case .cloud: return "Cloud"
        case .ghost: return "Boo"
        case .owl: return "Owl"
        case .cube: return "Cube"
        case .drop: return "Drop"
        case .shield: return "Guard"
        case .cat: return "Ginger"
        case .gem: return "Gem"
        case .tube: return "Tube"
        }
    }

    /// The gradient of its body, light to dark. Accents around the avatar (the working ring) use these too.
    var colors: (UInt32, UInt32) {
        switch self {
        case .pebble: return (0x6EEBD6, 0x0E8F86)
        case .bolt: return (0xFCC93A, 0xE85D10)
        case .orbit: return (0x8E97FA, 0x6226D3)
        case .moth: return (0xFC7F93, 0xB9165A)
        case .tank: return (0x9FAEC2, 0x465468)
        case .sprout: return (0xD8F99B, 0x5E9E0C)
        case .spark: return (0xFFD166, 0xEE3F8F)
        case .cloud: return (0xEAF6FF, 0x45B5F5)
        case .ghost: return (0xEEDCFF, 0x8E5EF7)
        case .owl: return (0xD9A671, 0x8A3E0F)
        case .cube: return (0x7FB5FB, 0x1D4ED8)
        case .drop: return (0x7BEAFB, 0x0A6AA6)
        case .shield: return (0xF97A7A, 0x971A1A)
        case .cat: return (0xFFB76B, 0xD6480C)
        case .gem: return (0x27D6EE, 0xA74CF5)
        case .tube: return (0xF4F1EC, 0xA29C94)
        }
    }

    /// The character a bot wears: its pick, else one chosen from its id so it never changes.
    static func of(_ bot: NativeBot) -> BotCharacter {
        if let picked = bot.avatar.flatMap(BotCharacter.init(rawValue:)) { return picked }
        return fromSeed(bot.id)
    }

    static func fromSeed(_ seed: String) -> BotCharacter {
        var hash: UInt64 = 1469598103934665603
        for byte in seed.utf8 { hash = (hash ^ UInt64(byte)) &* 1099511628211 }
        return allCases[Int(hash % UInt64(allCases.count))]
    }

    /// A look nobody else has yet, starting from `preferred`, so a team doesn't end up with twins.
    static func firstFree(preferring preferred: BotCharacter?, among bots: [NativeBot]) -> BotCharacter {
        let taken = Set(bots.compactMap(\.avatar))
        let order = (preferred.map { [$0] } ?? []) + allCases
        return order.first { !taken.contains($0.rawValue) } ?? preferred ?? .pebble
    }
}
