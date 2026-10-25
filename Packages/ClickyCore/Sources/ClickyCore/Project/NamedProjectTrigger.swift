//
//  NamedProjectTrigger.swift
//  ClickyCore
//
//  "update it to the Claude Code project called Mahajan Motor Work",
//  "send this to the scratch helpers project": the owner names a SPECIFIC
//  project as the destination. The plain bridge ("send this to my project")
//  only reaches the one project coordinator (ProjectSendTrigger); a named
//  destination is matched against his local projects instead
//  (ProjectDestinationMatcher) and, when nothing matches, Clicky offers to
//  put the message into the Claude app for him to send.
//
//  Like ProjectSendTrigger it reads ONLY the owner's speech transcript,
//  never the screen or the model's answer; anything in [...] is removed
//  first, and "don't / never / not" right before the phrase (or before its
//  verb) cancels it. The phrases (ASR spellings of "Claude" included):
//    "<verb> it to/in/into/on/for the (claude code) project(s) called|named X"
//       (needs one of send/update/tell/ask/pass/forward/give/post/share/put/
//        paste/hand somewhere before it)
//    "send (this|it|that) to (the|my) X project(s)" / "send to X project"
//    "tell|ask (the|my) X project"
//    "in my X project … (send|update|tell|put|paste)"
//  X is 1-6 words (any length after "called", cut at "so / and / then /
//  to / that / which / please …" and at punctuation), at most 60
//  characters, title-cased where it was all lower case. An X that is
//  empty, "my", "the", or "clicky" is the normal bridge: no match here.
//  The task text is the transcript without the destination phrase.
//

import Foundation

public enum NamedProjectTrigger {
    public struct Match: Equatable, Sendable {
        /// The named project, title-ish ("Mahajan Motor Work").
        public let projectName: String
        /// The transcript without the destination phrase, trimmed. May be empty.
        public let taskText: String
        /// The words that named the destination, as heard.
        public let destinationPhrase: String
    }

    public static let maximumNameLength = 60

    /// Verbs that make "… to the project called X" a hand-off.
    static let destinationVerbs: Set<String> = [
        "send", "sent", "sends", "sending", "update", "updates", "updating", "tell", "ask", "pass", "forward",
        "give", "post", "share", "put", "paste", "hand"
    ]

    private static let nameWord = #"(?:(?!projects?\b)[\p{L}\p{N}'&-]+)"#
    private static var nameWords: String { "(?<name>\(nameWord)(?:\\s+\(nameWord)){0,5}?)" }
    /// "claude code", "claud", "cloud code", "clawed code": the app's name as heard.
    private static let claudeWords = #"(?:(?:claude?(?:'?s)?|cloud|clawed|clod)\s+(?:code\s+)?)"#

    private enum Kind { case called, sendTo, tellAsk, inMy }

    private static var patterns: [(Kind, String)] {
        [
            (.called, #"(?:\b(?:send|sent|sends|sending|pass|passing|forward|give|post|share|hand)(?:\s+(?:this|it|that|these|them))?\s+(?:over\s+)?)?\b(?:to|in|into|on|for)\s+(?:the\s+|my\s+)?"# + claudeWords + #"?projects?\s+(?:called|named|titled)\s+(?<name>[^.,;:!?\n]+)"#),
            (.sendTo, #"\b(?:send|sent|sends|sending|pass|forward|hand)(?:\s+(?:this|it|that|these|them))?\s+(?:over\s+)?(?:to|into)\s+(?:the\s+|my\s+)?"# + nameWords + #"\s+projects?\b"#),
            (.tellAsk, #"\b(?:tell|ask)\s+(?:the|my)\s+"# + nameWords + #"\s+projects?\b"#),
            (.inMy, #"\bin\s+my\s+"# + nameWords + #"\s+projects?\b"#)
        ]
    }

    /// Words that end a name heard after "called" ("called X so it can …").
    private static let nameStopPattern = #"\s+(?:so|and|then|to|that|which|please|because|where|with|but|now|for|okay|ok)\b.*$"#
    /// A name holding one of these is a sentence, not a project name.
    static let nonNameWords: Set<String> = [
        "me", "you", "him", "her", "them", "us", "about", "what", "how", "why", "when", "where", "which", "who", "is", "are",
        "was", "were", "i", "it", "this", "that", "to", "for", "with", "from", "at", "if", "so", "then", "please", "can",
        "could", "would", "should", "will", "do", "does", "did", "not", "don't", "dont"
    ]
    /// Leading words dropped from a name.
    private static let leadingFillerWords: Set<String> = ["the", "my", "a", "an", "our", "claude", "claud", "claudes", "cloud", "clawed", "clod", "code"]
    /// Names that mean the normal bridge (this Claude Code project, "Clicky").
    static let plainBridgeNames: Set<String> = ["", "my", "the", "clicky", "clickys", "clicky's", "clickie", "clicki"]

    public static func match(transcript: String) -> Match? {
        let spokenText = ProjectSendTrigger.withoutBracketedText(transcript).replacingOccurrences(of: "\u{2019}", with: "'")
        let fullRange = NSRange(spokenText.startIndex..., in: spokenText)

        struct Candidate { var range: Range<String.Index>; var name: String }
        var candidates: [Candidate] = []
        for (kind, pattern) in patterns {
            guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            for phraseMatch in expression.matches(in: spokenText, range: fullRange) {
                guard var phraseRange = Range(phraseMatch.range, in: spokenText),
                      let nameRange = Range(phraseMatch.range(withName: "name"), in: spokenText) else { continue }
                var rawName = String(spokenText[nameRange])
                if kind == .called {
                    // "called Mahajan motor work so it can update it": the name ends at "so".
                    if let stopRange = rawName.range(of: nameStopPattern, options: [.regularExpression, .caseInsensitive]) {
                        rawName = String(rawName[..<stopRange.lowerBound])
                    }
                    let trimmedName = rawName.trimmingCharacters(in: .whitespaces)
                    guard let nameStart = spokenText.range(of: trimmedName, range: nameRange)?.lowerBound else { continue }
                    phraseRange = phraseRange.lowerBound..<spokenText.index(nameStart, offsetBy: trimmedName.count)
                    guard containsDestinationVerb(String(spokenText[..<phraseRange.upperBound])) else { continue }
                }
                if kind == .inMy {
                    guard containsDestinationVerb(String(spokenText[phraseRange.upperBound...])) else { continue }
                }
                guard !isNegated(spokenText: spokenText, phraseRange: phraseRange, kind: kind) else { continue }
                guard let projectName = cleanedName(rawName, allowsLongName: kind == .called) else { continue }
                candidates.append(Candidate(range: phraseRange, name: projectName))
            }
        }
        guard let chosen = candidates.min(by: { $0.range.lowerBound < $1.range.lowerBound }) else { return nil }
        var remainingText = spokenText
        let destinationPhrase = String(spokenText[chosen.range]).trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        remainingText.replaceSubrange(chosen.range, with: " ")
        return Match(projectName: chosen.name, taskText: ProjectSendTrigger.cleanedTaskText(remainingText), destinationPhrase: destinationPhrase)
    }

    /// Lowercased words (letters, digits and apostrophes).
    static func words(_ text: String) -> [String] {
        text.lowercased().split { !($0.isLetter || $0.isNumber || $0 == "'") }.map(String.init)
    }

    static func containsDestinationVerb(_ text: String) -> Bool {
        words(text).contains(where: destinationVerbs.contains)
    }

    /// "don't send this to the X project", "never update it to the project called X".
    private static func isNegated(spokenText: String, phraseRange: Range<String.Index>, kind: Kind) -> Bool {
        if ProjectSendTrigger.isNegated(textBefore: String(spokenText[..<phraseRange.lowerBound])) { return true }
        let wordsBefore = words(String(spokenText[..<phraseRange.lowerBound]))
        let wordsAfter = words(String(spokenText[phraseRange.upperBound...]))
        switch kind {
        case .called:
            // The verb the phrase hangs off: "don't update it to …".
            guard let verbIndex = wordsBefore.lastIndex(where: destinationVerbs.contains), verbIndex > 0 else { return false }
            return ProjectSendTrigger.isNegated(textBefore: wordsBefore[..<verbIndex].joined(separator: " "))
        case .inMy:
            guard let verbIndex = wordsAfter.firstIndex(where: destinationVerbs.contains) else { return false }
            let beforeVerb = Array(wordsBefore) + Array(wordsAfter[..<verbIndex])
            return ProjectSendTrigger.isNegated(textBefore: beforeVerb.joined(separator: " "))
        case .sendTo, .tellAsk:
            return false
        }
    }

    /// The project name, or nil when it's the plain bridge or not a name.
    static func cleanedName(_ rawName: String, allowsLongName: Bool) -> String? {
        var nameWords = rawName.split { $0 == " " || $0 == "\t" || $0 == "\n" }.map(String.init)
            .map { $0.trimmingCharacters(in: .punctuationCharacters.subtracting(CharacterSet(charactersIn: "&'"))) }
            .filter { !$0.isEmpty }
        while let first = nameWords.first, leadingFillerWords.contains(first.lowercased()) { nameWords.removeFirst() }
        while let last = nameWords.last, ["project", "projects"].contains(last.lowercased()) { nameWords.removeLast() }
        guard !nameWords.isEmpty else { return nil }
        guard !nameWords.contains(where: { nonNameWords.contains($0.lowercased()) }) else { return nil }
        let lowercasedName = nameWords.joined(separator: " ").lowercased()
        guard !plainBridgeNames.contains(lowercasedName) else { return nil }
        if !allowsLongName, nameWords.count > 6 { return nil }
        var titledWords: [String] = []
        var length = 0
        for word in nameWords {
            let titled = word == word.lowercased() ? word.prefix(1).uppercased() + word.dropFirst() : word
            let addedLength = (titledWords.isEmpty ? 0 : 1) + titled.count
            guard length + addedLength <= maximumNameLength else { break }
            titledWords.append(titled)
            length += addedLength
        }
        guard !titledWords.isEmpty else { return nil }
        return titledWords.joined(separator: " ")
    }
}

// MARK: - The spoken yes / no after an offer

public enum SpokenConfirmation: Equatable, Sendable {
    case yes
    case no
    /// Anything else: the offer is dropped and the turn is handled normally.
    case other

    private static let fillerWords: Set<String> = ["please", "clicky", "thanks", "thank", "um", "uh", "oh", "hey", "just", "then", "well", "hmm"]
    private static let yesUnits: [[String]] = [
        ["yes"], ["yeah"], ["yep"], ["yup"], ["ya"], ["yea"], ["sure"], ["okay"], ["ok"], ["alright"], ["all", "right"],
        ["do", "it"], ["go", "ahead"], ["sounds", "good"], ["of", "course"], ["that's", "fine"], ["you"]
    ]
    private static let noUnits: [[String]] = [
        ["no"], ["nope"], ["nah"], ["cancel"], ["cancel", "it"], ["cancel", "that"], ["don't", "do", "it"], ["dont", "do", "it"],
        ["don't"], ["dont"], ["never", "mind"], ["nevermind"], ["forget", "it"], ["stop"], ["no", "thanks"], ["not", "now"], ["you"]
    ]

    /// The owner's whole answer must be made of yes words (or of no words).
    public static func parse(_ transcript: String) -> SpokenConfirmation {
        let spokenWords = NamedProjectTrigger.words(ProjectSendTrigger.withoutBracketedText(transcript).replacingOccurrences(of: "\u{2019}", with: "'"))
            .filter { !fillerWords.contains($0) }
        guard !spokenWords.isEmpty, spokenWords.count <= 8 else { return .other }
        if isCovered(spokenWords, by: yesUnits), !spokenWords.allSatisfy({ $0 == "you" }) { return .yes }
        if isCovered(spokenWords, by: noUnits), !spokenWords.allSatisfy({ $0 == "you" }) { return .no }
        return .other
    }

    /// True when the words split into a sequence of the units.
    static func isCovered(_ words: [String], by units: [[String]]) -> Bool {
        if words.isEmpty { return true }
        for unit in units.sorted(by: { $0.count > $1.count }) where words.starts(with: unit) {
            if isCovered(Array(words.dropFirst(unit.count)), by: units) { return true }
        }
        return false
    }
}

// MARK: - The pending offer

/// "Want me to open Claude at X and put your message in the box?" — kept 60 s.
public struct NamedProjectOffer: Equatable, Sendable {
    public static let lifetime: TimeInterval = 60

    public var projectName: String
    public var taskText: String
    public var createdAt: Date

    public init(projectName: String, taskText: String, createdAt: Date) {
        self.projectName = projectName
        self.taskText = taskText
        self.createdAt = createdAt
    }

    public func isExpired(at now: Date) -> Bool { now.timeIntervalSince(createdAt) > Self.lifetime || now < createdAt }

    public enum Resolution: Equatable, Sendable {
        /// "yes": put the message in Claude (the paste fallback).
        case accept(NamedProjectOffer)
        /// "no": dropped, "Okay, I won't."
        case decline
        /// No offer, an expired one, or another request: the turn goes on as usual (the offer is dropped).
        case notAnAnswer
    }

    /// What the owner's next transcript does with a pending offer.
    public static func resolve(_ offer: NamedProjectOffer?, transcript: String, now: Date) -> Resolution {
        guard let offer, !offer.isExpired(at: now) else { return .notAnAnswer }
        switch SpokenConfirmation.parse(transcript) {
        case .yes: return .accept(offer)
        case .no: return .decline
        case .other: return .notAnAnswer
        }
    }
}

// MARK: - What Clicky says

public enum NamedProjectSpeech {
    public static func offerLine(projectName: String) -> String {
        "I can only send to the Clicky project right now. Want me to open Claude at \(projectName) and put your message in the box for you to send?"
    }

    public static let declineLine = "Okay, I won't."

    public static func pasteFallbackLine(projectName: String) -> String {
        "I've copied it and brought Claude up — open \(projectName) and paste it."
    }

    public static let claudeNotRunningLine = "I've copied it, but I couldn't bring Claude up. Open it and paste it."

    public static func askForTaskLine(projectName: String) -> String {
        "What should I send to \(projectName)?"
    }

    public static func turningOnCodeModeLine(repositoryName: String) -> String {
        "Turning on code mode for \(repositoryName)."
    }

    public static func whichProjectLine(_ names: [String]) -> String {
        switch names.count {
        case 0: return "Which project?"
        case 1: return "Which project — \(names[0])?"
        default: return "Which project — \(names[0]) or \(names[1])?"
        }
    }

    public static func notAGitRepositoryLine(folderName: String) -> String {
        "\(folderName) isn't a git repo, so code mode can't work there."
    }

    /// The clipboard text: the task, then the screenshot's path on its own line.
    public static func clipboardText(taskText: String, screenshotPath: String?) -> String {
        guard let screenshotPath, !screenshotPath.isEmpty else { return taskText }
        return taskText + "\nScreenshot: " + screenshotPath
    }
}
