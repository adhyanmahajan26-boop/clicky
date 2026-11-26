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

/// How the X Space bot sounds, next to its stance: picked in its settings or call window, or switched by its boss.
public enum SpaceTone: String, CaseIterable, Sendable {
    case normal, witty, serious, chill, custom

    public var title: String {
        switch self {
        case .normal: return "Normal"
        case .witty: return "Witty/funny"
        case .serious: return "Serious"
        case .chill: return "Chill"
        case .custom: return "Custom"
        }
    }

    /// What the brain is told each turn. `custom`: the owner's own line, for `.custom`.
    public func instruction(custom: String) -> String? {
        switch self {
        case .normal:
            return nil
        case .witty:
            return "(Tone: witty and funny. Quick jokes, playful lines and light teasing of ideas, never of people, with every claim still true.)"
        case .serious:
            return "(Tone: serious. Calm, precise and thoughtful, no jokes, facts first.)"
        case .chill:
            return "(Tone: chill. Relaxed and easy-going, friendly, never heated, short and warm.)"
        case .custom:
            let line = custom.trimmingCharacters(in: .whitespacesAndNewlines)
            return line.isEmpty ? nil : "(Tone, as the person who runs you put it: \(line) Your other rules still hold.)"
        }
    }

    /// A tone switch the bot wrote for its boss: "[TONE: witty]", "[TONE: custom like a sports commentator]".
    public static func command(in reply: String) -> (tone: SpaceTone, custom: String)? {
        guard let match = reply.range(of: #"\[\s*TONE\s*:\s*([A-Za-z/]+)\s*([^\]]*)\]"#, options: .regularExpression) else { return nil }
        let inside = String(reply[match]).dropFirst().dropLast().split(separator: ":", maxSplits: 1).last.map(String.init) ?? ""
        let parts = inside.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 1).map(String.init)
        guard let first = parts.first?.lowercased() else { return nil }
        let name = first.hasPrefix("witty") || first == "funny" ? "witty" : first
        guard let tone = SpaceTone(rawValue: name) else { return nil }
        return (tone, parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : "")
    }
}

/// The owner's rules for talking over and being talked over in a Space (25 Nov, after a public Space):
/// while the bot speaks it yields only to another voice that keeps going for more than 2 s, and then at once; it never
/// starts over someone, and drops a reply whose moment has passed; and a stop word from anyone stops it at once, and it
/// stays quiet until it's named again or its boss tells it to talk.
public enum SpaceFloor {
    /// Another voice on the Space's audio this long while the bot talks makes it stop. Laughs and "haan" are shorter.
    public static let yieldAfterOtherVoiceSeconds = 2.0
    /// Quiet needed before a reply that waited starts.
    public static let quietBeforeStartingSeconds = 0.4
    /// A reply that couldn't start within this long of being ready is dropped: the moment has passed.
    public static let dropAfterWaitingSeconds = 4.0

    /// Whether the bot stops talking now: another voice has gone on for `otherVoiceSeconds` while it speaks.
    public static func yields(otherVoiceSeconds: Double) -> Bool {
        otherVoiceSeconds > yieldAfterOtherVoiceSeconds
    }

    public enum StartDecision: Equatable, Sendable {
        case start
        case wait
        case drop
    }

    /// Whether a reply that's ready starts now. `someoneIsSpeaking`: a voice on the Space's audio now. `quietSeconds`:
    /// since it stopped. `secondsWaiting`: since the reply was ready. `talkMovedOn`: new words were heard since the turn
    /// this answers.
    /// `requiredQuiet`: the quiet the turn needs before the bot's voice may start (`CallOwnAccount.pauseBeforeAnswering`):
    /// a reply that was started early, on the words so far, still waits for it.
    public static func startDecision(someoneIsSpeaking: Bool, quietSeconds: Double, secondsWaiting: Double, talkMovedOn: Bool,
                                     requiredQuiet: Double = quietBeforeStartingSeconds) -> StartDecision {
        if talkMovedOn || secondsWaiting > dropAfterWaitingSeconds { return .drop }
        if someoneIsSpeaking || quietSeconds < max(quietBeforeStartingSeconds, requiredQuiet) { return .wait }
        return .start
    }
}

public enum SpaceStopWords {
    /// Said alone (a short utterance), any of these stops the bot.
    static let phrases = [
        "stop", "stop it", "stop talking", "please stop", "ruko", "ruk", "ruk jao", "ruko yaar", "bas", "bas karo", "bas kar", "bas bas",
        "chup", "chup karo", "chup kar", "chup ho jao", "shut up", "be quiet", "quiet", "enough", "khamosh",
        "रुको", "रुक जाओ", "बस", "बस करो", "चुप", "चुप करो", "चुप हो जाओ", "ख़ामोश", "खामोश",
        "ਰੁਕੋ", "ਰੁਕ ਜਾ", "ਬੱਸ", "ਬਸ ਕਰ", "ਚੁੱਪ", "ਚੁੱਪ ਕਰ", "ਚੁੱਪ ਕਰੋ",
    ]
    /// Words longer than this are talk that happens to hold a stop word ("bas yahi baat hai"), unless the bot is named.
    static let longestStopUtteranceWords = 4

    /// Whether words heard (a partial is enough) tell the bot to stop: a stop phrase said on its own, or anywhere when the
    /// bot is named in them ("Chotta Tirri, stop").
    public static func isStop(_ words: String, isAddressed: Bool) -> Bool {
        let simplified = " " + CallTurnEnd.simplifiedWords(words).joined(separator: " ") + " "
        let count = simplified.split(separator: " ").count
        guard count > 0 else { return false }
        let hasPhrase = phrases.contains { simplified.contains(" " + CallTurnEnd.simplifiedWords($0).joined(separator: " ") + " ") }
        guard hasPhrase else { return false }
        return isAddressed || count <= longestStopUtteranceWords
    }
}

/// Text for the Space bot's voice. Sent clause by clause with a flush after each, every fragment came out with its own
/// tone, sometimes mid-word, and stretched letters ("haaaa", "mmm") came out as long odd sounds (a public Space, 25 Nov).
/// So the voice gets whole sentences, cleaned of what makes it vocalise oddly.
public enum SpaceVoiceText {
    /// What the voice shouldn't try to say: emoji, *stage directions*, (laughs), [anything], letters held for effect
    /// ("haaaa" → "haa", "nooo" → "noo"), and humming ("mmm", "hmm").
    public static func sanitized(_ text: String) -> String {
        var cleaned = text
        for pattern in [#"\*[^*]{1,40}\*"#, #"\((?:laughs?|laughing|sighs?|chuckles?|smiles?|pause|haha)[^)]{0,20}\)"#, #"\[[^\]]{0,40}\]"#] {
            cleaned = cleaned.replacingOccurrences(of: pattern, with: " ", options: [.regularExpression, .caseInsensitive])
        }
        cleaned = String(cleaned.unicodeScalars.filter { scalar in
            !(scalar.properties.isEmojiPresentation || (scalar.properties.isEmoji && scalar.value > 0x238C) || scalar.value == 0xFE0F || scalar.value == 0x200D)
        }.map(Character.init))
        // A letter three or more times in a row is held: two is enough ("haaaa" → "haa", "sooo" → "soo").
        cleaned = cleaned.replacingOccurrences(of: #"(\p{L})\1{2,}"#, with: "$1$1", options: .regularExpression)
        // Humming on its own.
        cleaned = cleaned.replacingOccurrences(of: #"(?i)(?<![\p{L}])(?:m{2,}|h+m+|u+h+m*)(?![\p{L}])[,.!…]*"#, with: " ", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return cleaned.trimmingCharacters(in: .whitespaces)
    }
}

/// Gathers streamed reply text into whole sentences for the voice, still one sentence at a time.
public struct SpaceSentenceGatherer: Sendable {
    private var held = ""
    /// A sentence this long with no end in sight goes anyway, at its last comma or space, so a run-on doesn't keep
    /// the Space waiting.
    public static let longestSentence = 220

    public init() {}

    /// The sentences finished by this piece of text.
    public mutating func add(_ piece: String) -> [String] {
        held += piece
        var sentences: [String] = []
        while let end = held.firstIndex(where: { ".?!।\n".contains($0) }) {
            var cut = held.index(after: end)
            // "3.5" or "Mr." mid-sentence: a stop with a letter or digit right after isn't an end.
            if held[end] == ".", cut < held.endIndex, held[cut].isLetter || held[cut].isNumber {
                guard let next = held[cut...].firstIndex(where: { ".?!।\n".contains($0) }) else { break }
                cut = held.index(after: next)
            }
            let sentence = String(held[..<cut]).trimmingCharacters(in: .whitespacesAndNewlines)
            held = String(held[cut...])
            if !sentence.isEmpty { sentences.append(sentence) }
        }
        if held.count > Self.longestSentence {
            let window = held.prefix(Self.longestSentence)
            let cut = window.lastIndex(of: ",") ?? window.lastIndex(of: " ") ?? window.endIndex
            sentences.append(String(held[..<cut]).trimmingCharacters(in: .whitespaces))
            held = String(held[cut...]).trimmingCharacters(in: CharacterSet(charactersIn: ", "))
        }
        return sentences
    }

    /// What's left at the end of the reply.
    public mutating func finish() -> String? {
        let rest = held.trimmingCharacters(in: .whitespacesAndNewlines)
        held = ""
        return rest.isEmpty ? nil : rest
    }
}
