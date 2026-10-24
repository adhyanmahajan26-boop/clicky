//
//  HandsFreeVoiceCommand.swift
//  leanring-buddy
//
//  Instant voice commands for hands-free sessions. These are matched locally
//  so "wait" or "capture" act immediately instead of waiting a few seconds
//  for Claude. Anything that isn't a command goes to Claude as a question.
//
//  Matching is whole-utterance only: "stop" is a command, but "stop the
//  music from playing" is a question for Claude. Filler words like "hey",
//  "clicky", "okay", and "please" are ignored so "okay clicky, wait" still
//  counts as "wait".
//

import Foundation

enum HandsFreeVoiceCommand: Equatable {
    /// "wait", "stop", "hold on" — stop talking and pause any autopilot work.
    case pause
    /// "go", "keep going", "continue" — resume after a pause.
    case resume
    /// "capture", "screenshot", "capture these two" — save screenshot(s) now.
    case capture(requestedCaptureCount: Int)
    /// "slower" / "faster" — change autopilot scroll speed.
    case slower
    case faster
    /// "clear", "clear marks", "erase" — remove the circles, arrows, and
    /// numbered steps Claude drew on screen.
    case clearMarks
    /// "done", "end session", "stop listening" — end the hands-free session.
    case endSession

    /// Pause must feel instant, so it's also checked against partial
    /// transcripts while the user is still mid-utterance.
    var shouldTriggerOnPartialTranscript: Bool {
        self == .pause
    }

    // MARK: - Phrase Tables

    private static let pausePhrases: Set<String> = [
        "wait", "wait wait", "stop", "stop stop", "hold on", "hold up", "pause",
        "one sec", "one second", "quiet", "be quiet", "shh", "shush", "shut up",
        "stop talking", "wait a second", "wait a sec", "hang on"
    ]

    private static let resumePhrases: Set<String> = [
        "go", "go on", "go ahead", "keep going", "continue", "resume",
        "carry on", "next", "ok go", "okay go", "you can continue"
    ]

    private static let slowerPhrases: Set<String> = [
        "slower", "slow down", "go slower", "slow", "too fast", "scroll slower"
    ]

    private static let fasterPhrases: Set<String> = [
        "faster", "speed up", "go faster", "too slow", "scroll faster", "quicker"
    ]

    private static let clearMarksPhrases: Set<String> = [
        "clear", "clear it", "clear that", "clear marks", "clear the marks",
        "clear the screen", "clear screen", "erase", "erase that", "erase marks",
        "remove marks", "remove the marks", "hide marks", "hide the marks"
    ]

    private static let endSessionPhrases: Set<String> = [
        "done", "im done", "we are done", "were done", "all done", "thats it",
        "end session", "end the session", "stop listening", "stop session",
        "goodbye", "bye", "finish", "finish session", "thats all"
    ]

    /// Base phrases that mean "take a screenshot". A count word may follow,
    /// e.g. "capture two" or "capture these two".
    private static let captureBasePhrases: Set<String> = [
        "capture", "capture this", "capture that", "capture these", "capture it",
        "screenshot", "screenshot this", "take a screenshot", "take screenshot",
        "snap", "snap this", "grab", "grab this", "save this", "capture the screen",
        "capture these screens", "screenshot these"
    ]

    private static let fillerWords: Set<String> = [
        "hey", "clicky", "okay", "ok", "please", "now", "um", "uh", "so", "alright", "right"
    ]

    private static let spokenCountWords: [String: Int] = [
        "one": 1, "two": 2, "to": 2, "too": 2, "three": 3, "four": 4, "five": 5,
        "1": 1, "2": 2, "3": 3, "4": 4, "5": 5
    ]

    // MARK: - Parsing

    /// Returns the command if the whole utterance is a command, otherwise nil.
    static func parse(_ utterance: String) -> HandsFreeVoiceCommand? {
        let normalizedUtterance = normalize(utterance)
        guard !normalizedUtterance.isEmpty else { return nil }

        if pausePhrases.contains(normalizedUtterance) { return .pause }
        if resumePhrases.contains(normalizedUtterance) { return .resume }
        if slowerPhrases.contains(normalizedUtterance) { return .slower }
        if fasterPhrases.contains(normalizedUtterance) { return .faster }
        if clearMarksPhrases.contains(normalizedUtterance) { return .clearMarks }
        if endSessionPhrases.contains(normalizedUtterance) { return .endSession }

        if let requestedCaptureCount = parseCaptureCount(from: normalizedUtterance) {
            return .capture(requestedCaptureCount: requestedCaptureCount)
        }

        return nil
    }

    /// Matches "capture", "capture two", "capture these two", "take two screenshots".
    private static func parseCaptureCount(from normalizedUtterance: String) -> Int? {
        if captureBasePhrases.contains(normalizedUtterance) {
            return 1
        }

        var utteranceWords = normalizedUtterance.split(separator: " ").map(String.init)

        // "capture two" / "capture these two" — count word at the end.
        if let lastWord = utteranceWords.last, let trailingCount = spokenCountWords[lastWord] {
            utteranceWords.removeLast()
            let phraseWithoutCount = utteranceWords.joined(separator: " ")
            if captureBasePhrases.contains(phraseWithoutCount) {
                return trailingCount
            }
        }

        // "take two screenshots" / "capture two screens".
        let countInMiddlePatterns = ["take {count} screenshots", "capture {count} screens", "capture {count} screenshots"]
        for (countWord, count) in spokenCountWords {
            for pattern in countInMiddlePatterns {
                if normalizedUtterance == pattern.replacingOccurrences(of: "{count}", with: countWord) {
                    return count
                }
            }
        }

        return nil
    }

    /// Lowercases, strips punctuation and apostrophes, collapses spaces,
    /// and drops filler words.
    static func normalize(_ utterance: String) -> String {
        let lowercasedUtterance = utterance.lowercased()
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "’", with: "")

        let lettersDigitsAndSpaces = lowercasedUtterance.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : " "
        }

        let utteranceWords = String(lettersDigitsAndSpaces)
            .split(separator: " ")
            .map(String.init)
            .filter { !fillerWords.contains($0) }

        return utteranceWords.joined(separator: " ")
    }
}
