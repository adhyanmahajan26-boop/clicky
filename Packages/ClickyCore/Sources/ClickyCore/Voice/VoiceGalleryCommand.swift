//
//  VoiceGalleryCommand.swift
//  ClickyCore
//
//  Spoken voice switches, handled in the app without a brain turn (like
//  BoardVoiceCommand): the whole utterance must be the command, filler words
//  ("hey", "clicky", "please") aside, so "your voice is nice" never switches.
//
//    next      "change voice", "change your voice", "next voice", "another voice"…
//    previous  "previous voice", "go back to the old voice", "old voice"…
//    select    "use voice 3", "voice number three", "switch to voice 2", "try the third voice"
//    show      "show voices", "voice gallery", "open the voice gallery"…
//

import Foundation

public enum VoiceGalleryCommand: Equatable, Sendable {
    case next
    case previous
    /// 1-based gallery number, as the gallery shows it.
    case select(number: Int)
    case show

    /// One line for the main system prompt: Claude can't switch voices
    /// itself, so it tells the user the phrases.
    public static let promptLine = "voice: you can't change your own voice. the app switches it when the user says \"next voice\" (or \"change your voice\"), \"use voice 3\", \"previous voice\" or \"show voices\" (the voice gallery). if they ask to change how you sound, tell them one of those phrases in one short line."

    static let nextPhrases: Set<String> = [
        "change voice", "change your voice", "change the voice", "change voices", "change your voices",
        "next voice", "the next voice", "try the next voice", "go to the next voice",
        "switch voice", "switch your voice", "switch the voice", "switch voices",
        "another voice", "try another voice", "try a different voice", "a different voice", "different voice",
        "use another voice", "use a different voice", "new voice", "try a new voice"
    ]
    static let previousPhrases: Set<String> = [
        "previous voice", "the previous voice", "go back to the previous voice", "back to the previous voice",
        "old voice", "the old voice", "go back to the old voice", "back to the old voice", "use the old voice",
        "go back to your old voice", "back to your old voice", "use your old voice", "your old voice",
        "last voice", "the last voice", "go back to the last voice", "back to the last voice",
        "change your voice back", "change the voice back", "change it back to the old voice",
        "switch back to the old voice", "switch back to the previous voice", "voice back"
    ]
    static let showPhrases: Set<String> = [
        "show voices", "show the voices", "show me the voices", "show your voices", "show me your voices",
        "voice gallery", "the voice gallery", "show voice gallery", "show the voice gallery", "show me the voice gallery",
        "open voice gallery", "open the voice gallery", "open voices", "list voices", "list the voices", "list your voices",
        "voice settings", "show voice settings", "open voice settings", "what voices do you have", "which voices do you have"
    ]
    static let fillerWords: Set<String> = ["hey", "clicky", "okay", "ok", "please", "now", "um", "uh", "so", "alright", "can", "you", "could", "would"]
    /// Words that may lead "voice N": "switch to voice 3", "let's try voice two".
    static let leadingSelectWords: Set<String> = ["use", "try", "switch", "change", "to", "pick", "select", "choose", "go", "with",
                                                  "set", "the", "your", "give", "me", "lets", "let", "us", "i", "want", "and", "number"]
    static let numberWords: [String: Int] = [
        "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10,
        "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15, "sixteen": 16, "seventeen": 17,
        "eighteen": 18, "nineteen": 19, "twenty": 20
    ]
    static let ordinalWords: [String: Int] = [
        "first": 1, "second": 2, "third": 3, "fourth": 4, "fifth": 5, "sixth": 6, "seventh": 7, "eighth": 8, "ninth": 9,
        "tenth": 10, "eleventh": 11, "twelfth": 12, "1st": 1, "2nd": 2, "3rd": 3, "4th": 4, "5th": 5, "6th": 6, "7th": 7,
        "8th": 8, "9th": 9, "10th": 10
    ]

    public static func parse(_ utterance: String) -> VoiceGalleryCommand? {
        let normalizedUtterance = normalize(utterance)
        guard !normalizedUtterance.isEmpty, normalizedUtterance.contains("voice") else { return nil }
        if nextPhrases.contains(normalizedUtterance) { return .next }
        if previousPhrases.contains(normalizedUtterance) { return .previous }
        if showPhrases.contains(normalizedUtterance) { return .show }
        if let number = selectedNumber(normalizedUtterance) { return .select(number: number) }
        return nil
    }

    /// "use voice 3", "voice number three", "change voice to 4", "the third voice", "voice #2".
    static func selectedNumber(_ normalizedUtterance: String) -> Int? {
        var words = normalizedUtterance.split(separator: " ").map(String.init)
        while let firstWord = words.first, leadingSelectWords.contains(firstWord) { words.removeFirst() }
        // "the third voice" / "third voice"
        if words.count == 2, words[1] == "voice", let ordinal = ordinalWords[words[0]] { return ordinal }
        guard words.first == "voice" else { return nil }
        words.removeFirst()
        if words.first == "number" || words.first == "no" { words.removeFirst() }
        // "change voice to 4"
        if words.count == 2, words[0] == "to" { words.removeFirst() }
        guard words.count == 1, let numberWord = words.first else { return nil }
        if let number = Int(numberWord), (1...99).contains(number) { return number }
        return numberWords[numberWord] ?? ordinalWords[numberWord]
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
