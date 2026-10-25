//
//  BoardVoiceCommand.swift
//  ClickyCore
//
//  Hands-free board commands, matched on the whole utterance like the other
//  instant commands (filler words like "okay" / "clicky" ignored). With a
//  board open: next, back, repeat, pause, continue, close board, save board.
//  Always: "whiteboard that" (draw the last answer as a board) and "go
//  deeper on <n>" (a new page about section n). While Clicky is speaking
//  the app only acts on one if EchoGuard says Clicky didn't just say its
//  words itself (`echoWords`).
//

import Foundation

public enum BoardVoiceCommand: Equatable, Sendable {
    case next, back, repeatStep, pause, resume, close, save
    case whiteboardThat
    /// 1-based section number among the question sections.
    case goDeeper(sectionNumber: Int)

    /// Commands that only make sense with a board open.
    public var needsOpenBoard: Bool {
        switch self {
        case .whiteboardThat, .goDeeper: return false
        default: return true
        }
    }

    static let nextPhrases: Set<String> = ["next", "next step", "next one", "forward", "go forward", "next slide"]
    static let backPhrases: Set<String> = ["back", "go back", "previous", "previous step", "step back", "last step", "back one"]
    static let repeatPhrases: Set<String> = ["repeat", "repeat that", "repeat this", "again", "say that again", "once more", "replay", "repeat the board"]
    static let pausePhrases: Set<String> = ["pause", "pause it", "pause that", "pause the board", "pause board", "hold on"]
    static let resumePhrases: Set<String> = ["continue", "resume", "go on", "keep going", "carry on", "play", "unpause"]
    static let closePhrases: Set<String> = ["close board", "close the board", "close whiteboard", "close the whiteboard", "close it", "close that",
                                            "close", "hide board", "hide the board", "hide the whiteboard"]
    static let savePhrases: Set<String> = ["save board", "save the board", "save whiteboard", "save the whiteboard", "export board",
                                           "export the board", "save it", "save that"]
    static let whiteboardThatPhrases: Set<String> = ["whiteboard that", "whiteboard this", "whiteboard it", "board that", "draw that",
                                                     "draw that on a whiteboard", "put that on a whiteboard", "put that on the whiteboard",
                                                     "make that a whiteboard", "show that on a whiteboard"]
    static let fillerWords: Set<String> = ["hey", "clicky", "okay", "ok", "please", "now", "um", "uh", "so", "alright", "right", "can", "you"]
    static let numberWords: [String: Int] = [
        "one": 1, "two": 2, "to": 2, "too": 2, "three": 3, "four": 4, "for": 4, "five": 5, "six": 6, "seven": 7, "eight": 8,
        "first": 1, "second": 2, "third": 3, "fourth": 4, "fifth": 5, "sixth": 6, "seventh": 7, "eighth": 8
    ]
    /// Words that don't make a command on their own (EchoGuard checks the rest).
    static let neutralWords: Set<String> = ["the", "a", "go", "on", "that", "it", "this", "step", "board", "whiteboard", "one", "say", "put", "make", "show"]

    public static func parse(_ utterance: String) -> BoardVoiceCommand? {
        let normalizedUtterance = normalize(utterance)
        guard !normalizedUtterance.isEmpty else { return nil }
        if nextPhrases.contains(normalizedUtterance) { return .next }
        if backPhrases.contains(normalizedUtterance) { return .back }
        if repeatPhrases.contains(normalizedUtterance) { return .repeatStep }
        if pausePhrases.contains(normalizedUtterance) { return .pause }
        if resumePhrases.contains(normalizedUtterance) { return .resume }
        if closePhrases.contains(normalizedUtterance) { return .close }
        if savePhrases.contains(normalizedUtterance) { return .save }
        if whiteboardThatPhrases.contains(normalizedUtterance) { return .whiteboardThat }
        if let sectionNumber = goDeeperSectionNumber(normalizedUtterance) { return .goDeeper(sectionNumber: sectionNumber) }
        return nil
    }

    /// "go deeper on two", "go deeper on section 3", "deeper on the second one", "go deeper into 2".
    static func goDeeperSectionNumber(_ normalizedUtterance: String) -> Int? {
        var words = normalizedUtterance.split(separator: " ").map(String.init)
        if words.first == "go" { words.removeFirst() }
        guard words.first == "deeper" else { return nil }
        words.removeFirst()
        guard let preposition = words.first, ["on", "into", "in", "with"].contains(preposition) else { return nil }
        words.removeFirst()
        let meaningfulWords = words.filter { !["the", "section", "part", "number", "one"].contains($0) }
        if !meaningfulWords.isEmpty { words = meaningfulWords }
        guard words.count == 1, let numberWord = words.first else { return nil }
        if let number = Int(numberWord), (1...24).contains(number) { return number }
        return numberWords[numberWord]
    }

    /// The words EchoGuard checks against what Clicky just said.
    public static func echoWords(in utterance: String) -> Set<String> {
        let words = Set(normalize(utterance).split(separator: " ").map(String.init))
        let commandWords = words.subtracting(neutralWords)
        return commandWords.isEmpty ? words : commandWords
    }

    public static func normalize(_ utterance: String) -> String {
        let lowercasedUtterance = utterance.lowercased()
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "’", with: "")
        let lettersDigitsAndSpaces = lowercasedUtterance.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : " "
        }
        return String(lettersDigitsAndSpaces).split(separator: " ").map(String.init).filter { !fillerWords.contains($0) }.joined(separator: " ")
    }
}
