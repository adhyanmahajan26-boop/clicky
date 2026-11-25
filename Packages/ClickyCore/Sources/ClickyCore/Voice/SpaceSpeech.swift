//
//  SpaceSpeech.swift
//  ClickyCore
//
//  What the X Space bot says, made sayable, and how it behaves while talking. In a public Space on 25 Nov it wrote Punjabi
//  in Gurmukhi, which Sarvam's voice can't read, so people heard nothing while the bot thought it had spoken; it said names
//  as the screen shows them ("token-t…"); and the crowd talking over it cut its answers off halfway.
//

import Foundation

public enum SpeakableText {
    /// Whether the voice can read every letter: Latin and Devanagari only (Sarvam's Bulbul and Apple's Hindi voices).
    public static func isSpeakable(_ text: String) -> Bool {
        text.unicodeScalars.allSatisfy { scalar in
            guard CharacterSet.letters.contains(scalar) || CharacterSet.nonBaseCharacters.contains(scalar) else { return true }
            return isLatin(scalar) || isDevanagari(scalar)
        }
    }

    /// The text the voice can read: anything in another script (Gurmukhi, Tamil, Arabic…) written in Roman letters, with
    /// the accents taken off. Text it can already read comes back as it was.
    public static func speakable(_ text: String) -> String {
        guard !isSpeakable(text) else { return text }
        let latin = text.applyingTransform(.toLatin, reverse: false) ?? text
        return latin.applyingTransform(.stripDiacritics, reverse: false) ?? latin
    }

    static func isLatin(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value < 0x0250 || (0x1E00...0x1EFF).contains(scalar.value)
    }

    static func isDevanagari(_ scalar: Unicode.Scalar) -> Bool {
        (0x0900...0x097F).contains(scalar.value) || (0xA8E0...0xA8FF).contains(scalar.value)
    }

    /// A name as it's said: no emoji or "…", underscores and hyphens as spaces, and a name the Space shortened
    /// ("token-t…") written out from a full one that's known ("token-tirri" → "Token Tirri").
    public static func spokenName(_ name: String, knownFullNames: [String] = []) -> String {
        var shown = name.trimmingCharacters(in: .whitespaces)
        let wasShortened = shown.hasSuffix("…") || shown.hasSuffix("...")
        shown = shown.replacingOccurrences(of: "…", with: "").replacingOccurrences(of: "...", with: "")
        let shownKey = SpaceSpeakerName.skeleton(shown)
        if shownKey.count >= 3, let full = knownFullNames.first(where: { full in
            let fullKey = SpaceSpeakerName.skeleton(full)
            return fullKey.count > shownKey.count && fullKey.hasPrefix(shownKey) && (wasShortened || shownKey.count >= 5)
        }) {
            shown = full
        }
        var words: [String] = []
        var current = ""
        for character in shown {
            if character.isLetter || character.isNumber {
                current.append(character)
            } else if !current.isEmpty {
                words.append(current)
                current = ""
            }
        }
        if !current.isEmpty { words.append(current) }
        let said = words.map { word -> String in
            // "tirri" and "TIRRI" are said "Tirri"; "McKay" and "iPhone" stay as they are.
            guard word.first?.isLetter == true, word == word.lowercased() || word == word.uppercased(), word.count > 1 else { return word }
            return word.prefix(1).uppercased() + word.dropFirst().lowercased()
        }.joined(separator: " ")
        return said.isEmpty ? name : said
    }
}

/// How the X Space bot takes part, picked in its settings or call window, or switched by its boss in the Space.
public enum SpaceStance: String, CaseIterable, Sendable {
    case normal, debate, arguing, agreeing

    public var title: String {
        switch self {
        case .normal: return "Normal"
        case .debate: return "Debate"
        case .arguing: return "Arguing"
        case .agreeing: return "Agreeing"
        }
    }

    /// What the brain is told each turn. `target`: the one speaker it's for, as the Space names them; empty, everyone.
    public func instruction(target: String) -> String? {
        let who = target.trimmingCharacters(in: .whitespaces).isEmpty ? "anyone" : target.trimmingCharacters(in: .whitespaces)
        let whose = who == "anyone" ? "someone's" : "\(who)'s"
        let onlyThem = who == "anyone" ? "" : " Only lines labelled \(who) count; with everyone else, take part as usual."
        let decency = " Argue against ideas, never the person: no insults, slurs, profanity at anyone, or mocking their looks, identity or voice, and no piling on. If they or a host ask you to stop, stop."
        switch self {
        case .normal:
            return nil
        case .debate:
            return "(Stance for this Space: when \(who) makes a point, take the other side and debate it. Be sharp, witty and confident, with real arguments, facts and examples, and concede good points. Two to four short sentences, then let them answer." + decency + onlyThem + ")"
        case .arguing:
            return "(Stance for this Space: push back on \(whose) points hard and keep at it: challenge their claims, ask for evidence, and don't let a weak point go. Stay sharp and witty, two to four short sentences at a time." + decency + onlyThem + ")"
        case .agreeing:
            return "(Stance for this Space: back \(who) up. Agree with their points, add a reason, example or fact that builds on them, and keep the energy up, two or three short sentences at a time." + onlyThem + ")"
        }
    }

    /// A stance switch the bot wrote for its boss: "[STANCE: debate PEW]", "[STANCE: normal]". The stance, and the target
    /// after it (empty for everyone).
    public static func command(in reply: String) -> (stance: SpaceStance, target: String)? {
        guard let match = reply.range(of: #"\[\s*STANCE\s*:\s*([A-Za-z]+)\s*([^\]]*)\]"#, options: .regularExpression) else { return nil }
        let inside = String(reply[match]).dropFirst().dropLast().split(separator: ":", maxSplits: 1).last.map(String.init) ?? ""
        let parts = inside.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 1).map(String.init)
        guard let first = parts.first, let stance = SpaceStance(rawValue: first.lowercased()) else { return nil }
        let target = parts.count > 1 ? parts[1].trimmingCharacters(in: CharacterSet(charactersIn: " @")) : ""
        return (stance, target)
    }
}

/// Whether someone talking over the bot in a Space stops it mid-sentence. In a busy Space people talk over each other all
/// the time, and stopping for every few words left half its answers unsaid. Only its boss, or someone who calls it by
/// name and keeps talking, stops it at once; anyone else lets it finish the sentence it's on, then it stops.
public enum SpaceInterruption {
    /// New words, from someone who called it by name, that stop it at once.
    public static let wordsToStopForSomeoneAddressingIt = 4

    public enum Decision: Equatable, Sendable {
        case stopNow
        case finishTheSentence
        case carryOn
    }

    public static func decision(newWords: Int, isAddressed: Bool, byBoss: Bool) -> Decision {
        if byBoss && newWords >= 2 { return .stopNow }
        if isAddressed && newWords >= wordsToStopForSomeoneAddressingIt { return .stopNow }
        return newWords >= CallGroupMode.partialWordsToCutIn ? .finishTheSentence : .carryOn
    }
}
