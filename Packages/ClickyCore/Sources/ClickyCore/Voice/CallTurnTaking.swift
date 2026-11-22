//
//  CallTurnTaking.swift
//  ClickyCore
//
//  When the owner has finished talking on a voice call, and what Listen mode does.
//
//  The ears hand over their words after about half a second of quiet. People pause far longer than that in the middle of
//  a thought, so a call holds those words and waits for a real pause before Vello answers: the owner's Patience setting
//  (two seconds unless changed), longer when the words sound unfinished ("and…", "so…", "matlab…"), shorter for a clear
//  question or a plain "yes". Talking again during the wait just carries on the same turn.
//
//  Listen mode: "listen mode" makes Vello only listen, keeping everything it hears; it answers when spoken to ("Vello,
//  what do you think?", "speak about the budget"), with all it heard, and keeps listening after. "Talk normally" ends it.
//

import Foundation

/// How long a call waits after the owner's voice stops before Vello answers.
public enum CallTurnPatience {
    public static let settingKey = "v4.call.patienceSeconds"
    public static let defaultSeconds = 2.0
    public static let range: ClosedRange<Double> = 1.0...4.0

    /// The saved value, kept inside the range; nothing saved is the default.
    public static func seconds(saved: Double?) -> Double {
        guard let saved, saved > 0 else { return defaultSeconds }
        return min(range.upperBound, max(range.lowerBound, saved))
    }
}

/// How the words heard so far end, which says how long to wait for more.
public enum CallTurnEnding: Equatable, Sendable {
    /// "and", "so", "the", "umm", a trailing comma: more is coming.
    case soundsUnfinished
    /// A question, or a short complete answer ("yes", "thanks", "stop"): nothing more is likely.
    case soundsComplete
    case plain
}

public enum CallTurnEnd {
    /// Added to the patience when the words sound unfinished.
    public static let unfinishedExtraSeconds = 1.5
    /// The shortest wait, even for a clear question.
    public static let shortestSeconds = 0.8
    /// The longest wait, however unfinished it sounds.
    public static let longestSeconds = 5.5

    /// Words a thought never ends on, in English and Hinglish: joining words, fillers and words that need a noun after them.
    /// Said last, the owner is still thinking or about to go on, even if the ears put a question mark after it.
    static let joiningLastWords: Set<String> = [
        "and", "but", "or", "so", "because", "cause", "cuz", "like", "um", "umm", "uh", "uhh", "uhm", "hmm", "er", "erm",
        "then", "also", "plus", "if", "when", "while", "that", "which", "whether", "although", "though", "unless", "until",
        "since", "than", "actually", "basically", "the", "a", "an", "my", "your", "our", "their", "of", "for", "with",
        "from", "about", "into", "aur", "toh", "matlab", "ki", "ke", "ka", "ko", "lekin", "magar", "kyunki", "jaise",
        "phir", "agar", "mera", "meri", "mere",
        "और", "तो", "कि", "की", "के", "का", "को", "लेकिन", "क्योंकि", "जैसे", "फिर", "अगर", "मतलब",
    ]

    /// Words a thought rarely ends on, though a question can ("how about you?", "is it on?"): unfinished only without a
    /// question mark.
    static let weakLastWords: Set<String> = [
        "to", "in", "on", "at", "by", "is", "are", "was", "were", "am", "be", "can", "could", "should", "would", "will",
        "i", "we", "you", "it's", "i'm", "let's", "maybe", "very", "this", "these", "those", "some", "any", "his", "her",
        "its", "who", "where", "as", "well", "anyway", "par", "ya", "na", "woh", "wo", "yeh", "ye", "bhi", "पर", "या", "भी",
    ]

    /// Short whole answers that are a complete turn by themselves.
    static let completeShortAnswers: Set<String> = [
        "yes", "yeah", "yep", "yup", "no", "nope", "nah", "ok", "okay", "sure", "thanks", "thank you", "thanks a lot",
        "stop", "go on", "continue", "go ahead", "do it", "that's it", "that's all", "never mind", "got it", "perfect",
        "great", "cool", "nice", "right", "exactly", "correct", "haan", "nahi", "nahin", "theek hai", "thik hai", "ho gaya",
        "bas", "chalo", "shukriya", "dhanyavaad", "हाँ", "नहीं", "ठीक है", "बस",
    ]

    public static func ending(of words: String) -> CallTurnEnding {
        let trimmed = words.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .plain }
        if trimmed.hasSuffix("...") || trimmed.hasSuffix("…") || trimmed.hasSuffix(",") || trimmed.hasSuffix("-") || trimmed.hasSuffix("—") {
            return .soundsUnfinished
        }
        let simplified = simplifiedWords(trimmed)
        guard let lastWord = simplified.last else { return .plain }
        if completeShortAnswers.contains(simplified.joined(separator: " ")) { return .soundsComplete }
        if joiningLastWords.contains(lastWord) { return .soundsUnfinished }
        if trimmed.hasSuffix("?") || trimmed.hasSuffix("？") { return .soundsComplete }
        if weakLastWords.contains(lastWord) { return .soundsUnfinished }
        return .plain
    }

    /// Seconds of quiet, counted from the end of the owner's voice, before Vello answers.
    public static func waitSeconds(after words: String, patienceSeconds: Double) -> Double {
        switch ending(of: words) {
        case .soundsUnfinished: return min(longestSeconds, patienceSeconds + unfinishedExtraSeconds)
        case .soundsComplete: return max(shortestSeconds, patienceSeconds * 0.5)
        case .plain: return patienceSeconds
        }
    }

    /// Lowercased words without the punctuation around them ("Yes!" → "yes"); apostrophes stay ("that's").
    static func simplifiedWords(_ text: String) -> [String] {
        text.lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .components(separatedBy: CharacterSet.whitespacesAndNewlines)
            .map { $0.trimmingCharacters(in: CharacterSet.punctuationCharacters.subtracting(CharacterSet(charactersIn: "'")).union(.symbols)) }
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "'")) }
            .filter { !$0.isEmpty }
    }
}

/// What the owner said about Listen mode, if anything.
public enum CallListenModeCommand: Equatable, Sendable {
    case start
    case stop
}

public enum CallListenMode {
    /// The longest utterance that can still be a switch; a long sentence that mentions "listen mode" is just talk.
    static let longestCommandWords = 9

    static let stopPhrases = [
        "stop listen mode", "stop listening mode", "exit listen mode", "end listen mode", "leave listen mode",
        "listen mode off", "turn off listen mode", "no more listen mode", "talk normally", "talk normal", "back to normal",
        "normal mode", "talk mode", "conversation mode", "you can talk now", "you can talk again", "start talking again",
    ]
    static let startPhrases = [
        "listen mode", "listening mode", "listen only", "only listen", "just listen", "listen quietly", "sirf suno",
        "bas suno", "chup chap suno", "चुपचाप सुनो", "सिर्फ सुनो", "बस सुनो",
    ]

    /// Names the ears hear for Vello, including how they often mishear it.
    public static let defaultAssistantNames = ["vello", "wello", "bello", "velo", "vellow", "vallo", "theo", "वेलो", "वैलो"]

    /// Phrases that ask Vello to speak up in Listen mode, with or without its name.
    static let speakUpPhrases = [
        "what do you think", "what you think", "what's your take", "what is your take", "your take on", "your opinion",
        "your thoughts", "speak about", "speak on", "speak up", "sum it up", "sum that up", "summarize", "summarise",
        "answer that", "answer this", "answer the question", "your turn", "kya lagta hai", "kya sochte ho",
        "tum kya sochte", "aap kya sochte", "kya khayal hai", "tumhara kya", "aapka kya", "क्या लगता है", "क्या सोचते",
    ]

    public static func command(in utterance: String) -> CallListenModeCommand? {
        let words = CallTurnEnd.simplifiedWords(utterance)
        guard !words.isEmpty, words.count <= longestCommandWords else { return nil }
        let joined = " " + words.joined(separator: " ") + " "
        // "stop listen mode" holds "listen mode", so stopping is checked first.
        if stopPhrases.contains(where: { joined.contains(" \($0) ") }) { return .stop }
        if startPhrases.contains(where: { joined.contains(" \($0) ") }) { return .start }
        return nil
    }

    /// Whether something heard in Listen mode is meant for Vello: its name near the start or the end ("Vello, …",
    /// "hey Vello …", "… right, Vello?"), or a phrase asking it to speak up.
    public static func isAddressed(_ utterance: String, assistantNames: [String] = defaultAssistantNames) -> Bool {
        let words = CallTurnEnd.simplifiedWords(utterance)
        guard !words.isEmpty else { return false }
        let names = Set(assistantNames.map { $0.lowercased() })
        let nearTheStart = words.prefix(3)
        let nearTheEnd = words.suffix(2)
        if nearTheStart.contains(where: names.contains) || nearTheEnd.contains(where: names.contains) { return true }
        let joined = " " + words.joined(separator: " ") + " "
        return speakUpPhrases.contains { joined.contains(" \($0) ") }
    }
}

/// What a call heard in Listen mode, and which of it Vello hasn't been given yet.
public struct CallListenTranscript: Sendable {
    public private(set) var heard: [String] = []
    private var sentCount = 0
    /// The most of what's new that goes in one turn; older lines are left out with a note.
    public static let longestUnsentCharacters = 16_000

    public init() {}

    public var hasUnsent: Bool { sentCount < heard.count }

    public mutating func add(_ words: String) {
        let trimmed = words.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        heard.append(trimmed)
    }

    /// The message for Vello when it's spoken to in Listen mode: everything heard since it last got some, then the ask.
    /// Earlier parts are already in the call's conversation, so they aren't sent twice.
    /// `staysInListenMode` false: the owner just ended Listen mode and this is their first ordinary turn.
    public mutating func messageForVello(asking question: String, owner: String, staysInListenMode: Bool = true) -> String {
        var unsent = Array(heard[sentCount...])
        sentCount = heard.count
        var leftOut = 0
        while unsent.count > 1 && unsent.joined(separator: "\n").count > Self.longestUnsentCharacters {
            unsent.removeFirst()
            leftOut += 1
        }
        let ownerWord = OwnerName.isUnset(owner) ? "the owner" : owner
        var message = staysInListenMode
            ? "(Listen mode: you've been quietly listening on this call without replying. "
            : "(You were just in listen mode on this call, quietly listening without replying. "
        if unsent.isEmpty {
            message += "Nothing new was heard since you last spoke.)"
        } else {
            message += "Here is what you heard since you last spoke, in order. It may be \(ownerWord), other people in the room, or a TV, video or meeting, so don't assume who said what.\n"
            if leftOut > 0 { message += "[\(leftOut) earlier lines left out]\n" }
            message += unsent.map { "- " + $0 }.joined(separator: "\n")
            message += ")"
        }
        message += "\n\(OwnerName.startingSentence(owner)) is now asking you: \(question)\n"
        message += "(Answer from what you heard and what was said earlier on this call. If they don't say which part, it's the latest topic. Keep it short unless they ask for more."
        message += staysInListenMode ? " You stay in listen mode afterwards.)" : " Listen mode is over now, so talk as usual.)"
        return message
    }
}
