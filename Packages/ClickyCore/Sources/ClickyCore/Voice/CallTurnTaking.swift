//
//  CallTurnTaking.swift
//  ClickyCore
//
//  When the owner has finished talking on a voice call, and what Listen mode does.
//
//  The ears hand over their words after about half a second of quiet. People pause far longer than that in the middle of
//  a thought, so a call holds those words and waits for a real pause before Vello answers: the owner's Patience setting
//  (a second and a half unless changed), longer when the words sound unfinished ("and…", "so…", "matlab…"), shorter for a clear
//  question or a plain "yes". Talking again during the wait just carries on the same turn.
//
//  Listen mode: "listen mode" makes Vello only listen, keeping everything it hears; it answers when spoken to ("Vello,
//  what do you think?", "speak about the budget"), with all it heard, and keeps listening after. "Talk normally" ends it.
//

import Foundation

/// How long a call waits after the owner's voice stops before Vello answers.
public enum CallTurnPatience {
    public static let settingKey = "v4.call.patienceSeconds"
    /// Two seconds made every answer feel slow on top of the ears' own wait, so the default is a second and a half.
    public static let defaultSeconds = 1.5
    public static let range: ClosedRange<Double> = 0.5...4.0

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
    public static let unfinishedExtraSeconds = 1.0
    /// The shortest wait, even for a clear question.
    public static let shortestSeconds = 0.6
    /// The longest wait, however unfinished it sounds.
    public static let longestSeconds = 4.0

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

/// Words the ears heard while Vello's own voice was playing. Echo cancelling never takes all of it out, and the ears
/// write down whatever is left, so those words are usually Vello hearing itself rather than the owner talking.
public enum CallEcho {
    /// How much of what was heard has to be in what Vello just said for it to count as its own voice coming back.
    public static let sharedWordsShare = 0.6

    /// Whether `heard` is mostly words from `vellosRecentWords` (what Vello's voice said in the last few seconds).
    public static func soundsLikeVello(_ heard: String, vellosRecentWords: String) -> Bool {
        let heardWords = CallTurnEnd.simplifiedWords(heard)
        guard !heardWords.isEmpty else { return false }
        let spoken = Set(CallTurnEnd.simplifiedWords(vellosRecentWords))
        guard !spoken.isEmpty else { return false }
        let shared = heardWords.filter(spoken.contains).count
        return Double(shared) / Double(heardWords.count) >= sharedWordsShare
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

    /// Start phrases that name the mode itself, so they count anywhere in a short utterance.
    static let namedStartPhrases = ["listen mode", "listening mode"]
    /// Words that may follow a start phrase and still leave it a switch ("just listen for a bit", "listen only please").
    static let trailingFillerWords: Set<String> = ["please", "now", "okay", "ok", "for", "a", "bit", "while", "vello", "yaar", "abhi", "thoda"]

    public static func command(in utterance: String) -> CallListenModeCommand? {
        let words = CallTurnEnd.simplifiedWords(utterance)
        guard !words.isEmpty, words.count <= longestCommandWords else { return nil }
        let joined = " " + words.joined(separator: " ") + " "
        // "stop listen mode" holds "listen mode", so stopping is checked first.
        if stopPhrases.contains(where: { joined.contains(" \($0) ") }) { return .stop }
        if namedStartPhrases.contains(where: { joined.contains(" \($0) ") }) { return .start }
        // "just listen", "only listen": only when that's how the utterance ends. "Just listen to me, open Safari" is an
        // ordinary turn, and taking it as the switch left Vello silent for the rest of the call.
        for phrase in startPhrases where !namedStartPhrases.contains(phrase) {
            let phraseWords = CallTurnEnd.simplifiedWords(phrase)
            guard let start = words.indices.first(where: { index in
                index + phraseWords.count <= words.count && Array(words[index..<(index + phraseWords.count)]) == phraseWords
            }) else { continue }
            let after = words[(start + phraseWords.count)...]
            if after.allSatisfy({ trailingFillerWords.contains($0) }) { return .start }
        }
        return nil
    }

    /// Whether Vello's name is said near the start or the end ("Vello, …", "hey Vello …", "… right, Vello?"). In Listen
    /// mode that brings Vello back to talking: the owner calling it by name wants it back, and kept in Listen mode it
    /// answered once and went quiet again, so it seemed stuck there.
    public static func callsVelloByName(_ utterance: String, assistantNames: [String] = defaultAssistantNames) -> Bool {
        let words = CallTurnEnd.simplifiedWords(utterance)
        guard !words.isEmpty else { return false }
        let names = Set(assistantNames.map { $0.lowercased() })
        return words.prefix(3).contains(where: names.contains) || words.suffix(2).contains(where: names.contains)
    }

    /// The names a call answers to in Listen mode. Vello's own call: its usual names. Another bot's call: those too, plus
    /// its whole name and each word of it the ears can catch on its own ("Observer" for "Super Neutral Observer"). A
    /// short word or an everyday one ("super", "the") is left out, since people say it all the time.
    public static func names(forBotNamed botName: String?) -> [String] {
        var names = defaultAssistantNames
        guard let botName else { return names }
        let whole = botName.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !whole.isEmpty else { return names }
        names.append(whole)
        let everydayWords: Set<String> = ["super", "the", "bot", "mister", "miss", "doctor", "agent", "assistant", "helper", "buddy", "hello"]
        for word in CallTurnEnd.simplifiedWords(whole) where word.count >= 4 && !everydayWords.contains(word) && !names.contains(word) {
            names.append(word)
        }
        return names
    }

    /// Whether something heard in Listen mode is meant for Vello: its name near the start or the end ("Vello, …",
    /// "hey Vello …", "… right, Vello?"), or a phrase asking it to speak up.
    public static func isAddressed(_ utterance: String, assistantNames: [String] = defaultAssistantNames) -> Bool {
        if callsVelloByName(utterance, assistantNames: assistantNames) { return true }
        let words = CallTurnEnd.simplifiedWords(utterance)
        guard !words.isEmpty else { return false }
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
        message += "(Answer from what you heard and what was said earlier on this call. If they don't say which part, it's the latest topic. Keep it short unless they ask for more. If they ask you to do something, do it the usual way, with your lines at the end."
        message += staysInListenMode ? " You stay in listen mode afterwards.)" : " Listen mode is over now, so talk as usual.)"
        return message
    }
}

/// Only the voice near the Mac counts on a call. Someone talking two metres away reaches the mic about 10 dB quieter
/// than the owner a little way from it, so a stretch of speech counts only when it is close to how loud the owner's
/// own recent speech was. Before anything is learned every voice counts, and the first ones teach it. The owner's
/// level is the middle of the last few near stretches, so one shout doesn't lock out normal talking, and when nothing
/// near has been heard for a while the rule slowly loosens, so an owner who moved back from the Mac isn't shut out.
public struct CallNearVoice: Equatable, Sendable {
    public static let settingKey = "v4.call.nearVoiceOnly"
    /// How much quieter than the owner's usual level a voice may be and still count as theirs.
    public static let nearMarginDecibels = 9.0
    /// After this long with nothing near, the margin widens by one decibel every `looseningSecondsPerDecibel`.
    public static let looseningStartsAfterSeconds = 15.0
    public static let looseningSecondsPerDecibel = 3.0
    public static let widestMarginDecibels = 14.0
    /// Stretches of near speech remembered for the owner's level.
    public static let rememberedStretches = 12
    /// Only a stretch at most this much quieter than the owner's level (or louder) teaches the owner's level.
    ///
    /// Every stretch let through used to be learned, so a voice across the room that just made it past the margin pulled
    /// the owner's level down, which let the next, quieter one through, and so on (Air, 23 Nov: the owner's level slid
    /// from -20 dB to -32 dB in one call, and voices at -41 dB were the only ones still turned away).
    public static let learnsWithinDecibels = 4.0
    /// Anything quieter than this is never taken as speech to learn from.
    public static let quietestLearnableDecibels = -65.0

    public private(set) var recentNearLevels: [Double] = []
    public private(set) var lastNearSpeechAt: Date?

    public init() {}

    /// Whether the setting is on: on unless the owner switched it off.
    public static func isOn(saved: Bool?) -> Bool { saved ?? true }

    /// The owner's usual level, nil until a near stretch was heard.
    public var ownerLevelDecibels: Double? {
        guard !recentNearLevels.isEmpty else { return nil }
        let sorted = recentNearLevels.sorted()
        return sorted[sorted.count / 2]
    }

    /// How far below the owner's level a voice may be right now.
    public func marginDecibels(now: Date) -> Double {
        guard let lastNearSpeechAt else { return Self.nearMarginDecibels }
        let quietFor = now.timeIntervalSince(lastNearSpeechAt) - Self.looseningStartsAfterSeconds
        guard quietFor > 0 else { return Self.nearMarginDecibels }
        return min(Self.widestMarginDecibels, Self.nearMarginDecibels + quietFor / Self.looseningSecondsPerDecibel)
    }

    /// Whether speech this loud (the loudest part of it) counts as the owner's.
    public func isNear(levelDecibels: Double, now: Date) -> Bool {
        guard let ownerLevelDecibels else { return true }
        return levelDecibels >= ownerLevelDecibels - marginDecibels(now: now)
    }

    /// Near speech is going on now.
    public mutating func heardNearSpeech(at now: Date) {
        lastNearSpeechAt = now
    }

    /// A stretch of near speech ended; `levelDecibels` is its loud level (`loudLevel(of:)`). It's learned only when it's
    /// about as loud as the owner already is, or louder (`learnsWithinDecibels`).
    public mutating func learn(nearStretchLevelDecibels levelDecibels: Double, at now: Date) {
        lastNearSpeechAt = now
        guard levelDecibels > Self.quietestLearnableDecibels else { return }
        if let ownerLevelDecibels, levelDecibels < ownerLevelDecibels - Self.learnsWithinDecibels { return }
        recentNearLevels.append(levelDecibels)
        if recentNearLevels.count > Self.rememberedStretches { recentNearLevels.removeFirst(recentNearLevels.count - Self.rememberedStretches) }
    }

    /// The loud level of a stretch of speech: the 80th percentile of its blocks' levels, so the gaps between words don't
    /// pull it down and one click doesn't push it up.
    public static func loudLevel(of blockLevelsDecibels: [Double]) -> Double? {
        guard !blockLevelsDecibels.isEmpty else { return nil }
        let sorted = blockLevelsDecibels.sorted()
        let index = min(sorted.count - 1, Int(Double(sorted.count) * 0.8))
        return sorted[index]
    }
}

/// When words heard while Vello is still writing its answer stop that answer.
///
/// The ears hand over the same words again (a partial repeating what was just said, a final for words already taken), and
/// each one used to count as the owner cutting in: the answer was thrown away before a word of it was heard, the turn was
/// let go again at once, and the next repeat threw that answer away too (Air, 23 Nov: 232 answers in a row dropped in
/// three minutes, none heard, and the owner's last 189 words never answered). Now only new words cut in, and an answer
/// that hasn't been heard yet is started over at most twice; after that, more words wait for it and are answered next.
public enum CallCutIn {
    /// Times one answer, not yet heard, may be dropped and started over with the owner's added words.
    public static let mostRestartsPerAnswer = 2

    /// Whether `heard` holds at least `atLeast` words that aren't in `alreadyHeard` (the turn being answered and any words
    /// held since), so it's the owner saying something more rather than the ears repeating themselves.
    public static func bringsNewWords(_ heard: String, alreadyHeard: String, atLeast: Int = 1) -> Bool {
        let known = Set(CallTurnEnd.simplifiedWords(alreadyHeard))
        let newWords = CallTurnEnd.simplifiedWords(heard).filter { !known.contains($0) }
        return newWords.count >= max(1, atLeast)
    }

    /// Whether an answer still being written, and not heard yet, is dropped and started over with the new words.
    /// `restartsSoFar`: how many times this answer was already started over.
    public static func restartsTheAnswer(restartsSoFar: Int) -> Bool {
        restartsSoFar < mostRestartsPerAnswer
    }
}

/// Words the ears hand over for a turn that's still being held. Sarvam's socket can hand over the same stretch of speech
/// more than once (a partial that turned final, then the final again after a reconnect), and joining them as they came
/// made turns like "देखो राम भाई मैं कह रहा था तुम्हें सपोर्ट" three times over (Air, 24 Nov), which the model then
/// answered as nonsense.
public enum CallHeldWords {
    /// `held` with `heard` added: nothing when `heard` is already in it word for word, only the new end when `heard`
    /// starts with what `held` ends with, else the whole of it.
    public static func adding(_ heard: String, to held: String) -> String {
        let heardText = heard.trimmingCharacters(in: .whitespacesAndNewlines)
        let heldText = held.trimmingCharacters(in: .whitespacesAndNewlines)
        if heardText.isEmpty { return heldText }
        if heldText.isEmpty { return heardText }
        let heardWords = heardText.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
        let heldWords = heldText.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
        let heardKeys = heardWords.map(comparisonKey)
        let heldKeys = heldWords.map(comparisonKey)
        // Said already: the whole stretch is somewhere in what's held.
        if heardKeys.count <= heldKeys.count {
            for start in 0...(heldKeys.count - heardKeys.count) where Array(heldKeys[start..<(start + heardKeys.count)]) == heardKeys {
                return heldText
            }
        }
        // Carries on from where the held words end: only the rest is new.
        let longestOverlap = min(heldKeys.count, heardKeys.count - 1)
        if longestOverlap > 0 {
            for overlap in stride(from: longestOverlap, through: 1, by: -1)
            where Array(heldKeys.suffix(overlap)) == Array(heardKeys.prefix(overlap)) {
                // One shared word is often chance ("the", "है"); two or more is the same speech again.
                guard overlap >= 2 else { break }
                return heldText + " " + heardWords.dropFirst(overlap).joined(separator: " ")
            }
        }
        return heldText + " " + heardText
    }

    /// A word for comparing: lower case, without the punctuation around it.
    static func comparisonKey(_ word: String) -> String {
        CallTurnEnd.simplifiedWords(word).first ?? word.lowercased()
    }
}

/// How long Vello may stay quiet on a call. Waiting for the owner to finish is right, but other people talking near the Mac
/// keep the ears' partial words coming, and those alone must never hold the answer back for good (Air, 23 Nov: Vello sat
/// quiet for half a minute with people talking round the owner).
public enum CallQuietLimit {
    /// The ears' partial words keep a turn open for at most this long after the owner's voice stopped, on top of the wait.
    public static let longestPartialsHoldSeconds = 1.5

    /// Whether a held turn is let go now. `secondsSinceVoiceStopped`: since the owner's own voice ended (the gate).
    /// `secondsSincePartialWords`: since the ears last gave partial words, nil if they gave none. `waitSeconds`: what
    /// `CallTurnEnd.waitSeconds` says for the words held.
    public static func releasesTurn(secondsSinceVoiceStopped: Double, secondsSincePartialWords: Double?, waitSeconds: Double) -> Bool {
        let quietSoFar = min(secondsSinceVoiceStopped, secondsSincePartialWords ?? .infinity)
        if quietSoFar >= waitSeconds { return true }
        // Partials still coming, but the owner's voice stopped long enough ago: someone else is talking. Answer.
        return secondsSinceVoiceStopped >= waitSeconds + longestPartialsHoldSeconds
    }

    /// Once the owner's turn is let go, Vello says a few words of its own if none of its answer has sounded by then, so
    /// there's never a silence that sounds like it didn't hear.
    public static let acknowledgeAfterSeconds = 2.5

    /// The few words: short, so the answer follows straight on. `speaksHindi`: the call is in Hindi or Hinglish.
    /// `readsDevanagari`: the voice reads Devanagari (Sarvam); Apple's voices read Hindi best in Roman letters.
    public static func acknowledgement(speaksHindi: Bool, readsDevanagari: Bool, turnNumber: Int) -> String {
        let english = ["One sec.", "Hmm, let me think.", "Okay, give me a second."]
        let hindiRoman = ["Haan, ek second.", "Hmm, sochne do.", "Achha, ek second."]
        let hindiDevanagari = ["हाँ, एक सेकंड।", "हम्म, सोचने दो।", "अच्छा, एक सेकंड।"]
        let lines = speaksHindi ? (readsDevanagari ? hindiDevanagari : hindiRoman) : english
        return lines[abs(turnNumber) % lines.count]
    }
}
