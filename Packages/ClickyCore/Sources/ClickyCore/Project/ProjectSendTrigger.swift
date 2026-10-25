//
//  ProjectSendTrigger.swift
//  ClickyCore
//
//  The spoken "send this to my project …" hand-off. The owner's Claude Code
//  project coordinator (a separate session) watches ~/.clicky/project-outbox;
//  Clicky only writes one small JSON file there and reads replies.
//
//  The trigger reads ONLY the owner's own speech transcript for the turn,
//  never the screen and never the model's answer, so text on screen or a
//  model tag can't send anything. Anything in [...] is removed first (speech
//  never contains brackets, so a bracketed phrase can only be pasted or
//  injected text). The phrases (with a few ASR near misses):
//    "send this to my project", "send to my project", "send it to the project"
//      (send / sent / sends / sending; this / it / that; my / the; project / projects)
//    "tell my project", "ask my project"
//    "ask the coordinator", "tell the coordinator" (the / my; co-ordinator,
//      co ordinator, coordinater, cordinator)
//    a transcript starting with "project," or "project:"
//  "don't / never / not" right before a phrase cancels it.
//  The task text is the transcript verbatim without the phrase, trimmed of
//  whitespace and punctuation; empty means Clicky asks what to send.
//

import Foundation

public enum ProjectSendTrigger {
    public struct Match: Equatable, Sendable {
        /// The task as the owner said it, without the trigger phrase. May be empty.
        public let taskText: String
        /// The words that triggered it, as heard ("send this to my project").
        public let triggerPhrase: String
    }

    /// The prompt line: Claude can't send anything itself, so it tells the
    /// owner the words that do.
    public static let promptLine = "project hand-off: you can't send anything to the user's project or project coordinator yourself. if they ask you to hand a task to their project but didn't say the phrase, tell them to say \"send this to my project\" followed by the task."

    /// Phrases anywhere in the transcript.
    private static let phrasePatterns: [String] = [
        // send this to my project / send to my project / send it to the project
        #"\b(?:send|sent|sends|sending)(?:\s+(?:this|it|that))?\s+(?:over\s+)?to\s+(?:my|the)\s+projects?\b"#,
        // tell my project / ask my project
        #"\b(?:tell|ask)\s+my\s+projects?\b"#,
        // ask the coordinator / tell the coordinator (+ co-ordinator, coordinater, cordinator)
        #"\b(?:tell|ask)\s+(?:the|my)\s+(?:co[\s-]?ordinat(?:or|er)s?|cordinat(?:or|er)s?)\b"#
    ]
    /// "project, fix the login page" / "project: …" at the very start.
    private static let leadingAddressPattern = #"^\s*projects?\s*[,:]"#

    /// Words that, right before a phrase, mean the owner does NOT want it sent.
    private static let negatingWords: Set<String> = ["dont", "don't", "never", "not", "didnt", "didn't", "doesnt", "doesn't", "shouldnt", "shouldn't"]

    /// The transcript without anything in square brackets.
    static func withoutBracketedText(_ transcript: String) -> String {
        transcript.replacingOccurrences(of: #"\[[^\]]*\]?"#, with: " ", options: .regularExpression)
    }

    /// The match for the owner's own words this turn, or nil when no trigger
    /// phrase is there. Only the speech transcript is ever passed here.
    public static func match(transcript: String) -> Match? {
        let spokenText = withoutBracketedText(transcript).replacingOccurrences(of: "\u{2019}", with: "'")
        let fullRange = NSRange(spokenText.startIndex..., in: spokenText)

        var candidateRanges: [NSRange] = []
        if let leadingExpression = try? NSRegularExpression(pattern: leadingAddressPattern, options: [.caseInsensitive]),
           let leadingMatch = leadingExpression.firstMatch(in: spokenText, range: fullRange) {
            candidateRanges.append(leadingMatch.range)
        }
        for pattern in phrasePatterns {
            guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            for phraseMatch in expression.matches(in: spokenText, range: fullRange) {
                candidateRanges.append(phraseMatch.range)
            }
        }
        // The earliest phrase that isn't negated ("don't send this to my project").
        let usableRange = candidateRanges
            .sorted { $0.location < $1.location }
            .first { candidateRange in
                guard let swiftRange = Range(candidateRange, in: spokenText) else { return false }
                return !isNegated(textBefore: String(spokenText[..<swiftRange.lowerBound]))
            }
        guard let usableRange, let phraseRange = Range(usableRange, in: spokenText) else { return nil }

        let triggerPhrase = String(spokenText[phraseRange]).trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        var remainingText = spokenText
        remainingText.replaceSubrange(phraseRange, with: " ")
        return Match(taskText: cleanedTaskText(remainingText), triggerPhrase: triggerPhrase)
    }

    /// True when the owner's words fire the hand-off.
    public static func transcriptAsksToSendToProject(_ transcript: String) -> Bool {
        match(transcript: transcript) != nil
    }

    static func isNegated(textBefore: String) -> Bool {
        let wordsBefore = textBefore.lowercased().split { !($0.isLetter || $0 == "'") }
        guard let lastWord = wordsBefore.last else { return false }
        return negatingWords.contains(String(lastWord))
    }

    /// Whitespace runs collapsed, then whitespace and punctuation trimmed from both ends.
    static func cleanedTaskText(_ text: String) -> String {
        let collapsedText = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return collapsedText.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
    }
}
