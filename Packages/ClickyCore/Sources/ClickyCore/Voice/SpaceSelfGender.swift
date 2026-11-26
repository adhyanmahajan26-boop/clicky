//
//  SpaceSelfGender.swift
//  ClickyCore
//
//  How the X Space bot speaks about itself in Hindi and Hinglish. Hindi verbs agree with the speaker: a girl says
//  "main karti hun", "main gayi thi", "main karungi". The bot is told which forms to use, and what it writes is fixed on
//  its way to the voice when it slips into the other forms anyway (a feminine voice saying "main thak gaya", 26 Nov).
//

import Foundation

public enum SpaceSelfGender: String, Sendable, CaseIterable {
    case feminine
    case masculine
    /// No rule: the bot is told nothing and nothing is changed.
    case unset

    /// Sarvam voices that are women's voices, by the first part of the speaker id ("simran_enhi_customer").
    static let feminineSarvamNames: Set<String> = [
        "ritu", "priya", "neha", "pooja", "simran", "kavya", "ishita", "shreya", "roopa", "tanya", "shruti", "suhani",
        "kavitha", "rupali", "sanchita", "shalini", "anushka", "manisha", "vidya", "arya", "diya", "maya", "meera",
    ]
    static let masculineSarvamNames: Set<String> = [
        "shubh", "aditya", "rahul", "rohan", "amit", "dev", "ratan", "varun", "manan", "sumit", "kabir", "aayan",
        "ashutosh", "advait", "anand", "tarun", "sunny", "mani", "gokul", "vijay", "mohit", "rehan", "soham", "abhilash",
        "karun", "hitesh", "arvind", "vian",
    ]

    /// The setting ("feminine", "masculine", or anything else for "follow the voice"), else the voice's own.
    public static func resolved(setting: String?, sarvamSpeaker: String?) -> SpaceSelfGender {
        switch setting?.lowercased() {
        case "feminine", "female": return .feminine
        case "masculine", "male": return .masculine
        case "none", "unset": return .unset
        default: return forSarvamSpeaker(sarvamSpeaker)
        }
    }

    public static func forSarvamSpeaker(_ speaker: String?) -> SpaceSelfGender {
        guard let first = speaker?.lowercased().split(separator: "_").first.map(String.init) else { return .unset }
        if feminineSarvamNames.contains(first) { return .feminine }
        if masculineSarvamNames.contains(first) { return .masculine }
        return .unset
    }

    /// The line for the brain, or "" for none.
    public var instruction: String {
        switch self {
        case .feminine:
            return "You speak as a girl. In Hindi or Hinglish always use feminine forms for yourself, never masculine ones: \"main aati hun\", \"main karti hun\", \"main soch rahi hun\", \"main gayi thi\", \"main bolti hun\", \"main thak gayi\", \"main karungi\" (never \"aata hun\", \"karta hun\", \"raha hun\", \"gaya tha\", \"karunga\")."
        case .masculine:
            return "You speak as a boy. In Hindi or Hinglish always use masculine forms for yourself: \"main aata hun\", \"main karta hun\", \"main soch raha hun\", \"main gaya tha\", \"main karunga\"."
        case .unset:
            return ""
        }
    }

    /// The bot's own words, for the voice: masculine forms it used for itself made feminine. Only forms that can only be
    /// first person ("… hun", "-unga") are changed anywhere; past forms ("gaya", "tha") only in a clause whose subject is
    /// "main"/"mai"/"मैं"/"I", and never after "main ne" or once someone else becomes the subject.
    public func applied(to text: String) -> String {
        guard self == .feminine else { return text }
        return SpaceFeminineSelf.feminized(text)
    }
}

enum SpaceFeminineSelf {
    private struct Token {
        var range: Range<String.Index>
        var word: String
        var lower: String
        var replacement: String?
    }

    /// Words that end in "ta" but aren't verbs ("main beta hun", "mujhe pata hai").
    static let notVerbsEndingInTa: Set<String> = ["beta", "pata", "data", "meta", "sita", "gita", "geeta", "ata", "ta", "kota", "lota", "mota", "kata", "bata"]
    /// Masculine participles and adjectives a girl says differently about herself.
    static let romanForms: [String: String] = [
        "raha": "rahi", "rha": "rhi", "reha": "rahi", "chuka": "chuki", "gaya": "gayi", "gya": "gyi", "aaya": "aayi", "aya": "aayi",
        "hua": "hui", "huwa": "hui", "baitha": "baithi", "betha": "bethi", "khada": "khadi", "khara": "khari", "thaka": "thaki",
        "pada": "padi", "soya": "soyi", "roya": "royi", "akela": "akeli", "chhota": "chhoti", "chota": "choti", "bada": "badi",
        "accha": "acchi", "achha": "achhi", "acha": "achi", "bhookha": "bhookhi", "bhukha": "bhukhi", "pyaasa": "pyaasi",
        "dukhi": "dukhi", "pagal": "pagal", "lagaa": "lagi", "laga": "lagi", "mila": "mili", "nikla": "nikli", "pahuncha": "pahunchi",
        "pohcha": "pohchi", "sunaa": "suni", "dekha": "dekhi", "socha": "sochi", "samjha": "samjhi", "bola": "boli", "gaaya": "gaayi",
    ]
    /// The past forms above that only change after "main" with "tha"/"hun" or at the clause's end: "maine dekha" and
    /// "kya socha" are about something else.
    static let romanPastNeedsAux: Set<String> = ["dekha", "socha", "samjha", "bola", "sunaa", "mila", "laga", "lagaa", "nikla", "pahuncha", "pohcha", "gaaya"]
    static let devanagariForms: [String: String] = [
        "रहा": "रही", "चुका": "चुकी", "गया": "गई", "आया": "आई", "हुआ": "हुई", "बैठा": "बैठी", "थका": "थकी", "खड़ा": "खड़ी",
        "पड़ा": "पड़ी", "सोया": "सोई", "अकेला": "अकेली", "छोटा": "छोटी", "बड़ा": "बड़ी", "अच्छा": "अच्छी", "भूखा": "भूखी",
    ]
    static let hun: Set<String> = ["hun", "hoon", "hu", "hoo", "hūn", "हूँ", "हूं", "हू", "हुं", "हूॅं"]
    static let tha: Set<String> = ["tha", "thaa", "था"]
    static let firstPerson: Set<String> = ["main", "मैं", "मै", "i"]
    /// "mai" is also how some people write "mein" (in), so it's taken as "I" only near the clause's start.
    static let firstPersonNearStart: Set<String> = ["mai"]
    static let ergative: Set<String> = ["ne", "ने"]
    static let otherSubjects: Set<String> = [
        "wo", "woh", "vo", "voh", "tum", "tu", "aap", "hum", "unhone", "usne", "isne", "inhone", "maine", "mene",
        "वो", "वह", "तुम", "तू", "आप", "हम", "उसने", "मैंने", "he", "she", "they", "we", "you",
    ]
    static let clauseWords: Set<String> = [
        "aur", "lekin", "par", "magar", "but", "and", "ki", "kyunki", "kyonki", "jab", "to", "toh", "jo", "agar", "ya", "phir",
        "fir", "so", "और", "लेकिन", "पर", "मगर", "कि", "क्योंकि", "जब", "तो", "जो", "अगर", "या", "फिर",
    ]
    static let questionWords: Set<String> = ["kya", "kuch", "sab", "jo", "aisa", "kaisa", "jaisa", "kya?", "क्या", "कुछ", "सब"]

    static func feminized(_ text: String) -> String {
        var tokens = tokenize(text)
        guard !tokens.isEmpty else { return text }
        let clauseStarts = clauseStartFlags(text, tokens)

        // 1. Forms that are first person by themselves: "-ta hun", "raha hun", "gaya hun", "-unga".
        for index in tokens.indices {
            let lower = tokens[index].lower
            let next = index + 1 < tokens.count && !clauseStarts[index + 1] ? tokens[index + 1].lower : nil
            if let next, hun.contains(next) {
                if let feminine = feminineBeforeAux(lower) { tokens[index].replacement = matchCase(feminine, tokens[index].word) }
            }
            if let future = feminineFuture(lower) { tokens[index].replacement = matchCase(future, tokens[index].word) }
        }

        // 2. In a clause about "main": "tha" → "thi", "gaya" → "gayi", "karta tha" → "karti thi".
        var subjectIsMe = false
        var clauseIndex = 0
        for index in tokens.indices {
            if clauseStarts[index] { subjectIsMe = false; clauseIndex = 0 }
            let lower = tokens[index].lower
            defer { clauseIndex += 1 }
            if clauseWords.contains(lower) && index > 0 { subjectIsMe = false; clauseIndex = 0; continue }
            let isMe = firstPerson.contains(lower) || (firstPersonNearStart.contains(lower) && clauseIndex <= 1)
            if isMe {
                let next = index + 1 < tokens.count ? tokens[index + 1].lower : ""
                subjectIsMe = !ergative.contains(next)
                continue
            }
            if otherSubjects.contains(lower) { subjectIsMe = false; continue }
            guard subjectIsMe else { continue }
            let next = index + 1 < tokens.count && !clauseStarts[index + 1] ? tokens[index + 1].lower : nil
            let previous = index > 0 ? tokens[index - 1].lower : ""
            let nextIsAux = next.map { tha.contains($0) || hun.contains($0) } ?? false
            let clauseEnds = next == nil
            if tha.contains(lower) {
                tokens[index].replacement = lower == "था" ? "थी" : matchCase("thi", tokens[index].word)
            } else if nextIsAux, let feminine = feminineBeforeAux(lower) {
                tokens[index].replacement = matchCase(feminine, tokens[index].word)
            } else if let feminine = romanForms[lower], !questionWords.contains(previous),
                      !romanPastNeedsAux.contains(lower) || nextIsAux || clauseEnds {
                tokens[index].replacement = matchCase(feminine, tokens[index].word)
            } else if let feminine = devanagariForms[lower], !questionWords.contains(previous) {
                tokens[index].replacement = feminine
            }
        }

        var result = ""
        var cursor = text.startIndex
        for token in tokens {
            result += text[cursor..<token.range.lowerBound]
            result += token.replacement ?? token.word
            cursor = token.range.upperBound
        }
        result += text[cursor...]
        return result
    }

    /// The feminine of a word just before "hun"/"tha": "karta" → "karti", "raha" → "rahi", "करता" → "करती".
    static func feminineBeforeAux(_ lower: String) -> String? {
        if let roman = romanForms[lower] { return roman }
        if let devanagari = devanagariForms[lower] { return devanagari }
        if lower.count >= 3, lower.hasSuffix("ta"), !notVerbsEndingInTa.contains(lower), lower.allSatisfy({ $0.isASCII }) {
            return String(lower.dropLast()) + "i"
        }
        if lower.hasSuffix("ता"), lower.count >= 2 { return String(lower.dropLast()) + "ती" }
        return nil
    }

    /// "karunga" → "karungi", "jaaoonga" → "jaaoongi", "करूँगा" → "करूँगी". Only "main" says these.
    static func feminineFuture(_ lower: String) -> String? {
        for suffix in ["unga", "oonga", "ungaa", "oongaa"] where lower.hasSuffix(suffix) && lower.count > suffix.count && lower != "punga" {
            return String(lower.dropLast(suffix.hasSuffix("aa") ? 2 : 1)) + "i"
        }
        // Devanagari vowel signs are inside the letter they follow, so the ending is matched scalar by scalar.
        let scalars = Array(lower.unicodeScalars)
        for suffix in ["ूँगा", "ूंगा", "ऊँगा", "ऊंगा"] {
            let ending = Array(suffix.unicodeScalars)
            if scalars.count > ending.count, Array(scalars.suffix(ending.count)) == ending {
                var feminine = String.UnicodeScalarView(scalars.dropLast())
                feminine.append("ी")
                return String(feminine)
            }
        }
        return nil
    }

    private static func matchCase(_ replacement: String, _ original: String) -> String {
        guard let first = original.first, first.isUppercase else { return replacement }
        return replacement.prefix(1).uppercased() + replacement.dropFirst()
    }

    private static func tokenize(_ text: String) -> [Token] {
        var tokens: [Token] = []
        var start: String.Index?
        var index = text.startIndex
        func isWordCharacter(_ character: Character) -> Bool {
            character.unicodeScalars.allSatisfy { CharacterSet.letters.contains($0) || CharacterSet.nonBaseCharacters.contains($0) || $0 == "\u{200D}" || $0 == "\u{200C}" }
        }
        while index < text.endIndex {
            if isWordCharacter(text[index]) {
                if start == nil { start = index }
            } else if let wordStart = start {
                let word = String(text[wordStart..<index])
                tokens.append(Token(range: wordStart..<index, word: word, lower: word.lowercased()))
                start = nil
            }
            index = text.index(after: index)
        }
        if let wordStart = start {
            let word = String(text[wordStart...])
            tokens.append(Token(range: wordStart..<text.endIndex, word: word, lower: word.lowercased()))
        }
        return tokens
    }

    /// Whether punctuation that ends a clause comes between each token and the one before it.
    private static func clauseStartFlags(_ text: String, _ tokens: [Token]) -> [Bool] {
        var flags = [Bool](repeating: false, count: tokens.count)
        guard !tokens.isEmpty else { return flags }
        flags[0] = true
        for index in tokens.indices.dropFirst() {
            let between = text[tokens[index - 1].range.upperBound..<tokens[index].range.lowerBound]
            flags[index] = between.contains { ".,!?;:।—–\n\"“”()".contains($0) }
        }
        return flags
    }
}

/// A clip the owner set to play into the Space when someone says a phrase ("para kaisey karta hai"): the phrase's words
/// in order, each heard in any of its spellings, Roman or Devanagari.
public struct SpaceClipPhrase: Sendable, Equatable {
    public let name: String
    public let words: [Set<String>]
    /// Words that may come between the phrase's words ("para ye kaise karta hai"), at most `mostFillers` of them.
    public let fillers: Set<String>
    public let mostFillers: Int

    public init(name: String, words: [Set<String>], fillers: Set<String> = [], mostFillers: Int = 1) {
        self.name = name
        self.words = words.map { Set($0.map { SpaceClipTrigger.normalizedWords($0).joined(separator: " ") }) }
        self.fillers = fillers
        self.mostFillers = mostFillers
    }

    /// Addy's clip (26 Nov).
    public static let paraKaiseyKartaHai = SpaceClipPhrase(
        name: "para-kaisey-karta-hai",
        words: [["para", "paraa", "parra", "पैरा", "पारा", "परा"],
                ["kaisey", "kaise", "kese", "kaisay", "कैसे"],
                ["karta", "kartha", "krta", "करता"],
                ["hai", "he", "hain", "है", "हैं"]],
        fillers: ["ye", "yeh", "bhai"])
}

public enum SpaceClipTrigger {
    /// Played at most once in this long.
    public static let cooldownSeconds: TimeInterval = 20
    /// It waits for this much quiet before playing, and plays anyway after `longestWaitForQuiet`.
    public static let quietBeforePlaying: TimeInterval = 0.7
    public static let longestWaitForQuiet: TimeInterval = 3
    /// The clips peak at full scale: played a little down so nothing clips.
    public static let gainDecibels: Double = -3

    /// Lowercase words, punctuation gone, Devanagari kept whole (its vowel signs are part of the word).
    public static func normalizedWords(_ text: String) -> [String] {
        let lowered = text.precomposedStringWithCanonicalMapping.lowercased()
        var words: [String] = []
        var current = ""
        for scalar in lowered.unicodeScalars {
            if CharacterSet.letters.contains(scalar) || CharacterSet.nonBaseCharacters.contains(scalar) || CharacterSet.decimalDigits.contains(scalar) {
                current.unicodeScalars.append(scalar)
            } else if !current.isEmpty {
                words.append(current)
                current = ""
            }
        }
        if !current.isEmpty { words.append(current) }
        return words
    }

    /// The whole phrase, its words in order and next to each other, with at most `mostFillers` filler words between.
    public static func matches(_ text: String, phrase: SpaceClipPhrase) -> Bool {
        let words = normalizedWords(text)
        guard let first = phrase.words.first else { return false }
        for start in words.indices where first.contains(words[start]) {
            var position = start + 1
            var fillersUsed = 0
            var matched = true
            for expected in phrase.words.dropFirst() {
                while position < words.count, !expected.contains(words[position]), phrase.fillers.contains(words[position]), fillersUsed < phrase.mostFillers {
                    fillersUsed += 1
                    position += 1
                }
                guard position < words.count, expected.contains(words[position]) else { matched = false; break }
                position += 1
            }
            if matched { return true }
        }
        return false
    }
}

/// When a clip last played, so it plays at most once per `SpaceClipTrigger.cooldownSeconds`.
public struct SpaceClipCooldown: Sendable {
    public private(set) var lastPlayedAt: Date?
    public init() {}
    public func allows(at now: Date) -> Bool {
        guard let lastPlayedAt else { return true }
        return now.timeIntervalSince(lastPlayedAt) >= SpaceClipTrigger.cooldownSeconds
    }
    public mutating func played(at now: Date) { lastPlayedAt = now }
}
