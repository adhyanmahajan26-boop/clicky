//
//  WakeWordMatcher.swift
//  ClickyCore
//
//  P7 wake word ("hey theo", "hey clicky"). Pure parts only: the words
//  the on-device recognizer heard go in, a match (or nothing) comes out.
//
//  - The phrase counts only at the start of an utterance segment: the first
//    word of the recognition request, or the first word after a pause of at
//    least 0.6 s. "I told theo" or "and then hey clicky" mid-sentence
//    never wake Clicky.
//  - A phrase is a greeting plus a name. "hey" also accepts "hi", "hay",
//    "okay" / "ok"; the name accepts the usual ASR spellings (cloudia,
//    clodia, claudio, klaudia, claudya, clickey, kliki…) through a small
//    sound key plus one edit, and a name split in two ("cloud ia").
//  - Words after the phrase are the start of the turn ("hey claudia, open
//    notes" → "open notes").
//

import Foundation

/// One recognized word and where it sits in the recognition request's
/// audio (seconds from the request's first sample).
public struct WakeTranscriptWord: Equatable, Sendable {
    public var text: String
    public var startSeconds: TimeInterval
    public var endSeconds: TimeInterval

    public init(text: String, startSeconds: TimeInterval, endSeconds: TimeInterval) {
        self.text = text
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
    }
}

public struct WakeWordMatch: Equatable, Sendable {
    /// The configured phrase that matched ("hey theo").
    public let phrase: String
    /// The words (indexes into the transcript) that are the wake phrase.
    public let wordRange: Range<Int>
    /// When the wake phrase's last word ended, in request audio seconds.
    public let phraseEndSeconds: TimeInterval
    /// Everything after the phrase, joined with spaces ("open notes").
    public let remainderText: String

    public init(phrase: String, wordRange: Range<Int>, phraseEndSeconds: TimeInterval, remainderText: String) {
        self.phrase = phrase
        self.wordRange = wordRange
        self.phraseEndSeconds = phraseEndSeconds
        self.remainderText = remainderText
    }
}

public struct WakeWordMatcher: Sendable {
    public static let defaultPhrases = ["hey theo", "hey claudia", "hey clicky"]
    /// A gap this long between two words starts a new utterance segment.
    public static let segmentPauseSeconds: TimeInterval = 0.6

    /// Greetings that stand in for each other ("hey theo" = "hi theo" = "okay theo").
    /// P8: en-IN partials also hear "hai", "he", "hii", "heyy". ("hello" stays its own greeting:
    /// a custom "hello computer" shouldn't answer to "hey computer".)
    static let interchangeableGreetings: Set<String> = ["hey", "hi", "hay", "hei", "heya", "okay", "ok", "hai", "he", "hii", "heyy", "hy"]

    /// Whether a normalized word is one of the greetings (for near-miss counts).
    public static func isGreetingWord(_ word: String) -> Bool { interchangeableGreetings.contains(word) }

    /// P8: the second half of a name the recognizer split ("cloud yeah", "cloud ya"): all read as "ya".
    static let splitNameTailSpellings: [String: String] = ["yeah": "ya", "yah": "ya", "yea": "ya", "iya": "ya", "ia": "ia", "ya": "ya"]
    /// A split never starts with a real name of its own ("hey claude, yeah…" is talking to Claude).
    static let rejectedSplitNameHeads: Set<String> = ["claude", "claudes", "clyde"]

    /// Spellings the recognizer is known to produce for the built-in names
    /// (checked before the fuzzy rule, which also catches most of them).
    static let knownNameSpellings: [String: Set<String>] = [
        "theo": ["theo", "teo", "thio", "tio", "theyo", "theodore"],
        "claudia": ["claudia", "cloudia", "clodia", "claudio", "klaudia", "claudya", "claudiya", "clawdia", "klodia", "glaudia", "claudias"],
        "clicky": ["clicky", "clickey", "kliki", "clicki", "klicky", "kliky", "clickie", "clikki", "cliky", "cliquey", "klickie"]
    ]

    /// Real words one edit away from a name that must not wake Clicky
    /// ("hey claude", "hey click on that").
    static let rejectedNearNames: Set<String> = [
        "claude", "claudes", "click", "clicks", "clicked", "clique", "cliche", "clickers", "clicker"
    ]

    struct ParsedPhrase: Sendable {
        let phraseText: String
        /// Every word but the last; any word from `interchangeableGreetings` accepts the whole group.
        let greetingWords: [String]
        let name: String
    }

    let parsedPhrases: [ParsedPhrase]

    /// `phrases`: "greeting name" pairs from v2.wake.phrases. Blank or
    /// one-word entries are skipped (a bare name would fire on every mention).
    public init(phrases: [String] = WakeWordMatcher.defaultPhrases) {
        parsedPhrases = phrases.compactMap { phrase in
            let phraseWords = Self.normalizedWords(in: phrase)
            guard phraseWords.count >= 2, let name = phraseWords.last else { return nil }
            return ParsedPhrase(phraseText: phraseWords.joined(separator: " "), greetingWords: Array(phraseWords.dropLast()), name: name)
        }
    }

    public var phraseTexts: [String] { parsedPhrases.map(\.phraseText) }
    /// The names (last words) of the configured phrases, for the echo check.
    public var nameWords: [String] { parsedPhrases.map(\.name) }

    // MARK: - Matching

    /// The first wake phrase that starts an utterance segment, if any.
    public func firstMatch(in words: [WakeTranscriptWord]) -> WakeWordMatch? {
        let normalizedTexts = words.map { Self.normalizedWord($0.text) }
        for segmentStartIndex in Self.segmentStartIndexes(in: words) {
            if let match = match(atSegmentStart: segmentStartIndex, words: words, normalizedTexts: normalizedTexts) {
                return match
            }
        }
        return nil
    }

    /// Word indexes that begin an utterance segment: 0, and every word that
    /// follows a pause of `segmentPauseSeconds` or more. Empty words (bare
    /// punctuation) are skipped.
    public static func segmentStartIndexes(in words: [WakeTranscriptWord]) -> [Int] {
        var startIndexes: [Int] = []
        var previousSpokenWord: WakeTranscriptWord?
        for (wordIndex, word) in words.enumerated() where !normalizedWord(word.text).isEmpty {
            if let previousSpokenWord {
                if word.startSeconds - previousSpokenWord.endSeconds >= segmentPauseSeconds { startIndexes.append(wordIndex) }
            } else {
                startIndexes.append(wordIndex)
            }
            previousSpokenWord = word
        }
        return startIndexes
    }

    private func match(atSegmentStart startIndex: Int, words: [WakeTranscriptWord], normalizedTexts: [String]) -> WakeWordMatch? {
        // The spoken words from here on (punctuation-only tokens dropped).
        let spokenIndexes = (startIndex..<words.count).filter { !normalizedTexts[$0].isEmpty }
        for parsedPhrase in parsedPhrases {
            let greetingCount = parsedPhrase.greetingWords.count
            guard spokenIndexes.count > greetingCount else { continue }
            let greetingIndexes = Array(spokenIndexes.prefix(greetingCount))
            guard greetingMatches(greetingIndexes.map { normalizedTexts[$0] }, expected: parsedPhrase.greetingWords) else { continue }

            // The name as one word, or split in two by the recognizer ("cloud ia").
            let firstNameIndex = spokenIndexes[greetingCount]
            var nameEndIndex: Int?
            if isNameVariant(normalizedTexts[firstNameIndex], ofName: parsedPhrase.name) {
                nameEndIndex = firstNameIndex
            } else if spokenIndexes.count > greetingCount + 1, !Self.rejectedSplitNameHeads.contains(normalizedTexts[firstNameIndex]) {
                let secondNameIndex = spokenIndexes[greetingCount + 1]
                let secondPart = normalizedTexts[secondNameIndex]
                let joinedName = normalizedTexts[firstNameIndex] + (Self.splitNameTailSpellings[secondPart] ?? secondPart)
                if isSplitNameVariant(joinedName, ofName: parsedPhrase.name) {
                    nameEndIndex = secondNameIndex
                } else if spokenIndexes.count > greetingCount + 2 {
                    // Three short pieces ("clau di a"): joined, still one name-length word.
                    let thirdNameIndex = spokenIndexes[greetingCount + 2]
                    let pieces = [normalizedTexts[firstNameIndex], secondPart, normalizedTexts[thirdNameIndex]]
                    let threeWayName = pieces.joined()
                    if pieces.allSatisfy({ $0.count <= 5 }), threeWayName.count <= parsedPhrase.name.count + 2,
                       isSplitNameVariant(threeWayName, ofName: parsedPhrase.name) {
                        nameEndIndex = thirdNameIndex
                    }
                }
            }
            guard let nameEndIndex else { continue }

            let remainderText = ((nameEndIndex + 1)..<words.count)
                .map { words[$0].text.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !Self.normalizedWord($0).isEmpty }
                .joined(separator: " ")
            return WakeWordMatch(phrase: parsedPhrase.phraseText, wordRange: startIndex..<(nameEndIndex + 1),
                                 phraseEndSeconds: words[nameEndIndex].endSeconds,
                                 remainderText: Self.trimmedRemainder(remainderText))
        }
        return nil
    }

    private func greetingMatches(_ heardGreeting: [String], expected expectedGreeting: [String]) -> Bool {
        guard heardGreeting.count == expectedGreeting.count else { return false }
        for (heardWord, expectedWord) in zip(heardGreeting, expectedGreeting) {
            if heardWord == expectedWord { continue }
            if Self.interchangeableGreetings.contains(expectedWord) && Self.interchangeableGreetings.contains(heardWord) { continue }
            return false
        }
        return true
    }

    /// Whether a heard (normalized) word is the name: a known spelling, or
    /// one edit from it on the sound key, and not a listed real word.
    public func isNameVariant(_ heardWord: String, ofName name: String) -> Bool {
        let heardWord = Self.normalizedWord(heardWord)
        guard !heardWord.isEmpty, !Self.rejectedNearNames.contains(heardWord) else { return false }
        if heardWord == name || Self.knownNameSpellings[name]?.contains(heardWord) == true { return true }
        // Short names get no fuzz: too many real words sit one edit away.
        guard name.count >= 5, heardWord.count >= 4 else { return false }
        return Self.editDistance(Self.soundKey(heardWord), Self.soundKey(name)) <= 1
    }

    /// A name heard in pieces must also end like the name ("cloud ya" yes, "cloud is" no):
    /// two real words joined are one edit from far too much.
    func isSplitNameVariant(_ joinedWord: String, ofName name: String) -> Bool {
        guard isNameVariant(joinedWord, ofName: name) else { return false }
        if joinedWord == name || Self.knownNameSpellings[name]?.contains(joinedWord) == true { return true }
        return Self.soundKey(joinedWord).last == Self.soundKey(name).last
    }

    /// Whether any of these words is one of the configured names (or a
    /// spelling of one): used to check that Clicky didn't just say them.
    public func containsNameWord(_ words: Set<String>) -> Bool {
        words.contains { word in nameWords.contains { isNameVariant(word, ofName: $0) } }
    }

    // MARK: - Text helpers

    /// Lowercase letters and digits only ("Theo," → "theo", "it's" → "its").
    public static func normalizedWord(_ word: String) -> String {
        String(word.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
    }

    public static func normalizedWords(in text: String) -> [String] {
        text.lowercased()
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "’", with: "")
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
    }

    /// Turns a transcript string into words with no timing (all at 0), for
    /// tests and for text with no segment information. One segment.
    public static func untimedWords(in text: String) -> [WakeTranscriptWord] {
        text.split(whereSeparator: \.isWhitespace).map { WakeTranscriptWord(text: String($0), startSeconds: 0, endSeconds: 0) }
    }

    /// Drops the comma or dash left between the phrase and the request.
    static func trimmedRemainder(_ text: String) -> String {
        text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",.;:-–—!?")))
    }

    /// A rough sound key: spellings that sound alike collapse to the same
    /// letters (k/q/ck → c, au/aw/ou/o → o, y/ie/ey/ee → i).
    static func soundKey(_ word: String) -> String {
        var key = word
        for (spelling, sound) in [("ck", "c"), ("k", "c"), ("q", "c"), ("ph", "f"), ("au", "o"), ("aw", "o"), ("ou", "o"),
                                  ("ie", "i"), ("ey", "i"), ("ee", "i"), ("y", "i")] {
            key = key.replacingOccurrences(of: spelling, with: sound)
        }
        // Doubled letters sound like one ("clikki").
        var collapsedKey = ""
        for character in key where character != collapsedKey.last { collapsedKey.append(character) }
        return collapsedKey
    }

    static func editDistance(_ first: String, _ second: String) -> Int {
        let firstCharacters = Array(first)
        let secondCharacters = Array(second)
        if firstCharacters.isEmpty { return secondCharacters.count }
        if secondCharacters.isEmpty { return firstCharacters.count }
        var previousRow = Array(0...secondCharacters.count)
        for firstIndex in 1...firstCharacters.count {
            var currentRow = [firstIndex] + Array(repeating: 0, count: secondCharacters.count)
            for secondIndex in 1...secondCharacters.count {
                let substitutionCost = firstCharacters[firstIndex - 1] == secondCharacters[secondIndex - 1] ? 0 : 1
                currentRow[secondIndex] = min(previousRow[secondIndex] + 1, currentRow[secondIndex - 1] + 1,
                                              previousRow[secondIndex - 1] + substitutionCost)
            }
            previousRow = currentRow
        }
        return previousRow[secondCharacters.count]
    }
}

// MARK: - When a match may fire

/// Debounce and the "not while Clicky talks" rules. Decides whether a match
/// the recognizer reported becomes a wake.
public struct WakeWordGate: Sendable {
    public static let debounceSeconds: TimeInterval = 2
    /// Matches are ignored until this long after Clicky stops talking.
    public static let afterSpeechSeconds: TimeInterval = 1.5

    public enum Decision: String, Equatable, Sendable {
        case fire
        case ignoredDebounce
        case ignoredWhileSpeaking
        case ignoredJustAfterSpeaking
        /// Clicky itself said the name in the last few seconds (the mic heard the speaker).
        case ignoredEcho
    }

    public private(set) var lastFireDate: Date?

    public init() {}

    /// `recentClickySpokenWords`: every word Clicky said in the EchoGuard window.
    /// `allowsBargeIn` (v2.wake.bargeIn): "Hey Theo" while Clicky talks interrupts it — then only
    /// the echo check guards against Clicky's own voice (it rarely says the name).
    public mutating func decide(at date: Date, isClickySpeaking: Bool, lastClickySpeechEndDate: Date?,
                                recentClickySpokenWords: Set<String>, matcher: WakeWordMatcher, allowsBargeIn: Bool = false) -> Decision {
        if !allowsBargeIn {
            if isClickySpeaking { return .ignoredWhileSpeaking }
            if let lastClickySpeechEndDate, date.timeIntervalSince(lastClickySpeechEndDate) < Self.afterSpeechSeconds {
                return .ignoredJustAfterSpeaking
            }
        }
        if matcher.containsNameWord(recentClickySpokenWords) { return .ignoredEcho }
        if let lastFireDate, date.timeIntervalSince(lastFireDate) < Self.debounceSeconds { return .ignoredDebounce }
        lastFireDate = date
        return .fire
    }
}

// MARK: - "stop listening" / "start listening"

/// The spoken switch for the wake word. Whole utterance only, with the
/// wake phrase and politeness words ignored ("hey theo, stop listening please").
public enum WakeListeningCommand: Equatable, Sendable {
    case stopListening
    case startListening
    /// Keep listening and answering, but show answers instead of speaking them.
    case silentModeOn
    case silentModeOff

    static let stopPhrases: Set<String> = [
        "stop listening", "stop listening for me", "pause listening", "stop the wake word", "turn off the wake word",
        "turn off wake word", "stop listening to me", "dont listen", "stop listening for now"
    ]
    static let startPhrases: Set<String> = [
        "start listening", "resume listening", "start listening again", "listen again", "turn on the wake word",
        "turn on wake word", "start the wake word"
    ]
    static let silentOnPhrases: Set<String> = [
        "silent mode", "silent mode on", "turn on silent mode", "go silent", "be silent", "quiet mode", "quiet mode on",
        "turn on quiet mode", "mute yourself", "dont talk", "stop talking out loud", "just listen", "only listen"
    ]
    static let silentOffPhrases: Set<String> = [
        "silent mode off", "turn off silent mode", "talk again", "speak again", "you can talk again", "unmute yourself",
        "quiet mode off", "turn off quiet mode", "start talking again"
    ]
    static let ignoredWords: Set<String> = ["hey", "hi", "okay", "ok", "theo", "claudia", "clicky", "please", "now", "um", "uh", "so"]

    public static func parse(_ transcript: String) -> WakeListeningCommand? {
        let words = WakeWordMatcher.normalizedWords(in: transcript).filter { !ignoredWords.contains($0) }
        guard !words.isEmpty else { return nil }
        let phrase = words.joined(separator: " ")
        if stopPhrases.contains(phrase) { return .stopListening }
        if startPhrases.contains(phrase) { return .startListening }
        if silentOnPhrases.contains(phrase) { return .silentModeOn }
        if silentOffPhrases.contains(phrase) { return .silentModeOff }
        return nil
    }
}

// MARK: - End of speech

/// The hands-free end-of-speech rule, shared with the wake turn: an
/// utterance is finished once something was heard and the transcript
/// hasn't changed for `silenceSeconds`.
public enum UtteranceEndRule {
    public static let silenceSeconds: TimeInterval = 1.1

    public static func isFinished(heardText: String, secondsSinceLastChange: TimeInterval) -> Bool {
        !heardText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && secondsSinceLastChange >= silenceSeconds
    }
}

/// How long a wake turn waits for words after the phrase, and its cap.
public enum WakeTurnLimits {
    /// "hey theo" and then nothing: give up (counted as a likely false wake).
    public static let noSpeechAfterWakeSeconds: TimeInterval = 5
    public static let maximumTurnSeconds: TimeInterval = 30
}

// MARK: - Barge-in "stop"

/// A short standalone "stop" while Clicky talks or acts ("stop", "wait", "theo stop", "ruko", "bas").
/// The whole utterance segment must be stop words (at most 4 words, a leading "hey theo"/"clicky"
/// ignored), so a "stop" inside a longer sentence never counts; and the stop word must not be one
/// Clicky itself just said (its voice reaches the mic).
public enum WakeStopCommand {
    static let stopWords: Set<String> = ["stop", "wait", "ruko", "ruk", "bas", "enough", "quiet", "shush", "hold", "pause", "cancel"]
    static let fillerWords: Set<String> = ["hey", "hi", "okay", "ok", "theo", "claudia", "clicky", "it", "now", "please", "on", "talking",
                                          "be", "jao", "jaao", "karo", "that", "the"]

    public static func isStopUtterance(_ words: [String], recentClickySpokenWords: Set<String> = []) -> Bool {
        let normalized = words.map { WakeWordMatcher.normalizedWord($0) }.filter { !$0.isEmpty }
        guard !normalized.isEmpty, normalized.count <= 4 else { return false }
        let stopsSaid = normalized.filter { stopWords.contains($0) }
        guard !stopsSaid.isEmpty, normalized.allSatisfy({ stopWords.contains($0) || fillerWords.contains($0) }) else { return false }
        return stopsSaid.allSatisfy { !recentClickySpokenWords.contains($0) }
    }
}
