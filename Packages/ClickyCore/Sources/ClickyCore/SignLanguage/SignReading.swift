//
//  SignReading.swift
//  ClickyCore
//
//  Sign to text, last step: from one stretch's model outputs to a word (or a finger-spelled word), from those to
//  the line being signed, and from the line to the message Vello is sent. Also when to send it by itself once the
//  hands have rested. Pure Foundation.
//

import Foundation

// MARK: - Languages

public enum SignLanguage: String, CaseIterable, Codable, Sendable {
    case asl
    case isl

    /// Short, for pickers.
    public var displayName: String {
        switch self {
        case .asl: return "ASL (American)"
        case .isl: return "ISL (Indian)"
        }
    }

    /// In full, for sentences.
    public var fullName: String {
        switch self {
        case .asl: return "American Sign Language"
        case .isl: return "Indian Sign Language"
        }
    }

    /// What Sign to text says when this build has no models for the language.
    public var notInThisBuildLine: String {
        "\(rawValue.uppercased()) isn't in this build yet. It arrives in an update."
    }

    /// The language Sign to text starts with when nobody has chosen one (a saved choice always wins). With models for
    /// both, it follows the computer: ISL on a Mac set to an Indian region or to Hindi (`ComputerLanguage.isIndian`),
    /// otherwise ASL. With models for one, that one; with none, ASL.
    public static func defaultChoice(hasModels: (SignLanguage) -> Bool, computerIsIndian: Bool) -> SignLanguage {
        let withModels = allCases.filter(hasModels)
        if withModels.count > 1 { return computerIsIndian ? .isl : .asl }
        return withModels.first ?? .asl
    }
}

// MARK: - Word names

/// Dataset labels are lower case with no spaces ("thankyou"); these turn them into words a person reads.
public enum SignWordNames {
    /// Labels the datasets wrote as one joined word, and how they read.
    public static let readableTextByJoinedLabel: [String: String] = [
        "callonphone": "call on phone",
        "frenchfries": "french fries",
        "glasswindow": "glass window",
        "haveto": "have to",
        "hesheit": "he she it",
        "icecream": "ice cream",
        "minemy": "mine my",
        "thankyou": "thank you",
        "weus": "we us",
        "tv": "TV"
    ]

    /// The known joined labels read as their words; underscores and hyphens become spaces; anything else is
    /// returned as it is.
    public static func displayText(for label: String) -> String {
        if let readableText = readableTextByJoinedLabel[label] {
            return readableText
        }
        return label
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
    }
}

// MARK: - Settings

/// The thresholds for what counts as read, and for telling finger-spelling from a sign.
public struct SignReadingSettings: Equatable, Sendable {
    /// The top word needs at least this probability to be read at all; under it the stretch is not read.
    public var leastWordProbability: Float
    /// Finger-spelling needs at least this confidence to be used. 0.7, tuned on PopSign and FSboard validation signers:
    /// at 0.5 the ASL spelling model read some one-handed signs as spelled words.
    public var leastSpellingConfidence: Float
    /// A top word at least this likely is used even when the stretch looks like finger-spelling.
    public var wordProbabilityThatBeatsSpelling: Float
    /// How many guesses a read word keeps, the top one included (the rest are told to Vello as alternatives).
    public var alternativesKept: Int
    /// A guess under this probability is never kept as an alternative.
    public var leastAlternativeProbability: Float

    /// Finger-spelling looks like one hand held up in one place: that hand is seen in at least this share of frames…
    public var leastShareOfFramesWithTheSpellingHand: Double
    /// …the other hand in at most this share…
    public var mostShareOfFramesWithTheOtherHand: Double
    /// …the spelling hand's wrist moves at most this far (in body sizes, the larger of across and up-down)…
    public var mostSpellingWristTravelInBodySizes: Double
    /// …and it lasts at least this long (a short one-handed stretch is more likely a sign; 1.0 s, tuned with the
    /// confidence above: no spelled phrase on FSboard's validation signers was lost, ISL unchanged).
    public var shortestSpellingSeconds: Double

    /// An unclear sign keeps this many of the model's guesses, and mentions them to Vello's brain only when the top
    /// one is at least this likely (under it the guesses say nothing useful).
    public static let unclearGuessesKept = 2
    public static let leastUnclearGuessProbabilityToMention: Float = 0.3

    /// A word the sentence model reads in a run of signs counts only at this confidence (the highest probability its
    /// rows reached); under it the word becomes an unclear sign. 0.7 is the lowest where 95% of the words it lets through were right on INCLUDE's validation streams (150 streams, 2–5 signs, no rests).
    public var leastSentenceWordConfidence: Float = 0.7

    public init(
        leastWordProbability: Float = 0.25,
        leastSpellingConfidence: Float = 0.7,
        wordProbabilityThatBeatsSpelling: Float = 0.6,
        alternativesKept: Int = 3,
        leastAlternativeProbability: Float = 0.08,
        leastShareOfFramesWithTheSpellingHand: Double = 0.8,
        mostShareOfFramesWithTheOtherHand: Double = 0.15,
        mostSpellingWristTravelInBodySizes: Double = 0.6,
        shortestSpellingSeconds: Double = 1.0
    ) {
        self.leastWordProbability = leastWordProbability
        self.leastSpellingConfidence = leastSpellingConfidence
        self.wordProbabilityThatBeatsSpelling = wordProbabilityThatBeatsSpelling
        self.alternativesKept = alternativesKept
        self.leastAlternativeProbability = leastAlternativeProbability
        self.leastShareOfFramesWithTheSpellingHand = leastShareOfFramesWithTheSpellingHand
        self.mostShareOfFramesWithTheOtherHand = mostShareOfFramesWithTheOtherHand
        self.mostSpellingWristTravelInBodySizes = mostSpellingWristTravelInBodySizes
        self.shortestSpellingSeconds = shortestSpellingSeconds
    }
}

// MARK: - What a stretch looked like

/// Facts about one stretch, measured on its features, that tell finger-spelling from a sign.
public struct SignStretchFacts: Equatable, Sendable {
    public var seconds: Double
    /// 0–1: the share of frames where the signer's right (left) hand is seen.
    public var shareOfFramesWithRightHand: Double
    public var shareOfFramesWithLeftHand: Double
    /// How far the wrist of the hand seen in more frames travelled: the larger of its across range and its
    /// up-down range, in body sizes, over the frames where that hand is seen.
    public var busierHandWristTravelInBodySizes: Double

    public init(
        seconds: Double,
        shareOfFramesWithRightHand: Double,
        shareOfFramesWithLeftHand: Double,
        busierHandWristTravelInBodySizes: Double
    ) {
        self.seconds = seconds
        self.shareOfFramesWithRightHand = shareOfFramesWithRightHand
        self.shareOfFramesWithLeftHand = shareOfFramesWithLeftHand
        self.busierHandWristTravelInBodySizes = busierHandWristTravelInBodySizes
    }

    /// Measured from a stretch's features (the seen flags and the wrist-from-centre columns, which are already in
    /// body sizes). The right hand counts as the busier one when both are seen equally often.
    public init(clip: SignFeatureClip, seconds: Double) {
        self.seconds = seconds
        let completeFrameCount = min(clip.frameCount, clip.values.count / SignFeatures.featureCount)
        guard completeFrameCount > 0 else {
            shareOfFramesWithRightHand = 0
            shareOfFramesWithLeftHand = 0
            busierHandWristTravelInBodySizes = 0
            return
        }

        var rightHandFrameCount = 0
        var leftHandFrameCount = 0
        for frameIndex in 0..<completeFrameCount {
            if clip[frame: frameIndex, feature: SignFeatures.rightHandSeenFeature] > 0.5 { rightHandFrameCount += 1 }
            if clip[frame: frameIndex, feature: SignFeatures.leftHandSeenFeature] > 0.5 { leftHandFrameCount += 1 }
        }
        shareOfFramesWithRightHand = Double(rightHandFrameCount) / Double(completeFrameCount)
        shareOfFramesWithLeftHand = Double(leftHandFrameCount) / Double(completeFrameCount)

        let busierSide: SignSide = leftHandFrameCount > rightHandFrameCount ? .left : .right
        let seenFeature = SignFeatures.handSeenFeature(for: busierSide)
        let wristFeaturesStart = SignFeatures.wristFeaturesStart(for: busierSide)
        var smallestX = Double.infinity
        var largestX = -Double.infinity
        var smallestY = Double.infinity
        var largestY = -Double.infinity
        for frameIndex in 0..<completeFrameCount where clip[frame: frameIndex, feature: seenFeature] > 0.5 {
            let wristX = Double(clip[frame: frameIndex, feature: wristFeaturesStart])
            let wristY = Double(clip[frame: frameIndex, feature: wristFeaturesStart + 1])
            smallestX = min(smallestX, wristX)
            largestX = max(largestX, wristX)
            smallestY = min(smallestY, wristY)
            largestY = max(largestY, wristY)
        }
        if smallestX <= largestX {
            busierHandWristTravelInBodySizes = max(largestX - smallestX, largestY - smallestY)
        } else {
            // The busier hand was never seen (no hand at all).
            busierHandWristTravelInBodySizes = 0
        }
    }

    /// One hand held up in about one place for long enough, the other hand mostly down: finger-spelling.
    public func looksLikeFingerSpelling(settings: SignReadingSettings) -> Bool {
        let rightHandSpells = shareOfFramesWithRightHand >= settings.leastShareOfFramesWithTheSpellingHand
            && shareOfFramesWithLeftHand <= settings.mostShareOfFramesWithTheOtherHand
        let leftHandSpells = shareOfFramesWithLeftHand >= settings.leastShareOfFramesWithTheSpellingHand
            && shareOfFramesWithRightHand <= settings.mostShareOfFramesWithTheOtherHand
        guard rightHandSpells || leftHandSpells else { return false }
        return busierHandWristTravelInBodySizes <= settings.mostSpellingWristTravelInBodySizes
            && seconds >= settings.shortestSpellingSeconds
    }
}

// MARK: - Tokens

/// One read stretch: a signed word (with the other words it may have been), a finger-spelled word, or a sign that
/// wasn't clear enough to be a word (with the model's best guesses, which are only guesses).
public enum SignToken: Equatable, Sendable {
    /// Most likely first; never empty when made by `SignStretchReading`.
    case word(guesses: [SignWordGuess])
    case spelled(text: String, confidence: Float)
    /// Most likely first, at most `unclearGuessesKept`; may be empty.
    case unclear(guesses: [SignWordGuess])

    /// What an unclear sign shows as on the panel.
    public static let unclearText = "?"

    /// What the line shows: the top word's readable text, the spelled text, or "?".
    public var text: String {
        switch self {
        case .word(guesses: let guesses):
            guard let topGuess = guesses.first else { return "" }
            return SignWordNames.displayText(for: topGuess.label)
        case .spelled(text: let spelledText, confidence: _):
            return spelledText
        case .unclear:
            return Self.unclearText
        }
    }

    public var isUnclear: Bool {
        if case .unclear = self { return true }
        return false
    }

    /// The other words a signed word may have been, readable; none for finger-spelling or an unclear sign.
    public var alternativeTexts: [String] {
        switch self {
        case .word(guesses: let guesses):
            return guesses.dropFirst().map { guess in SignWordNames.displayText(for: guess.label) }
        case .spelled, .unclear:
            return []
        }
    }

    /// How Vello's brain is told about an unclear sign: in words, with the model's best one or two guesses when the
    /// top one is at least `leastGuessProbabilityToMention` likely.
    public func unclearDescription(leastGuessProbabilityToMention: Float = SignReadingSettings.leastUnclearGuessProbabilityToMention) -> String? {
        guard case .unclear(guesses: let guesses) = self else { return nil }
        guard let topGuess = guesses.first, topGuess.probability >= leastGuessProbabilityToMention else {
            return "(a sign I couldn't read)"
        }
        let guessTexts = guesses.prefix(2).map { "'\(SignWordNames.displayText(for: $0.label))'" }
        return "(a sign I couldn't read, possibly \(guessTexts.joined(separator: " or ")))"
    }
}

public enum SignStretchReading {
    /// Decides what one stretch was.
    ///
    /// Finger-spelling wins when the stretch looks like finger-spelling, the spelled text has at least 2
    /// characters, its confidence is at least `leastSpellingConfidence`, and the top word is under
    /// `wordProbabilityThatBeatsSpelling`. Otherwise the top word, when it is at least `leastWordProbability`,
    /// keeping up to `alternativesKept` guesses (the top one included) that are each at least
    /// `leastAlternativeProbability`. Otherwise nil: the stretch is not read.
    public static func token(
        wordGuesses: [SignWordGuess],
        spelling: SignSpelledGuess?,
        facts: SignStretchFacts,
        settings: SignReadingSettings = SignReadingSettings()
    ) -> SignToken? {
        // Most likely first, whatever order they came in; equal ones keep their order.
        let orderedGuesses = wordGuesses.enumerated().sorted { first, second in
            if first.element.probability != second.element.probability {
                return first.element.probability > second.element.probability
            }
            return first.offset < second.offset
        }.map { $0.element }
        let topWordProbability = orderedGuesses.first?.probability ?? 0

        if let spelling {
            let spelledText = spelling.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let spellingWins = facts.looksLikeFingerSpelling(settings: settings)
                && spelledText.count >= 2
                && spelling.confidence >= settings.leastSpellingConfidence
                && topWordProbability < settings.wordProbabilityThatBeatsSpelling
            if spellingWins {
                return .spelled(text: spelledText, confidence: spelling.confidence)
            }
        }

        guard let topGuess = orderedGuesses.first else {
            return spelling == nil ? nil : .unclear(guesses: [])
        }
        guard topGuess.probability >= settings.leastWordProbability else {
            return .unclear(guesses: Array(orderedGuesses.prefix(SignReadingSettings.unclearGuessesKept)))
        }
        let guessesToKeep = max(settings.alternativesKept, 1)
        var keptGuesses: [SignWordGuess] = [topGuess]
        for guess in orderedGuesses.dropFirst() {
            if keptGuesses.count >= guessesToKeep { break }
            if guess.probability >= settings.leastAlternativeProbability {
                keptGuesses.append(guess)
            }
        }
        return .word(guesses: keptGuesses)
    }
}

extension SignStretchReading {
    /// The sentence model's reading of a stretch, when it found a run of two or more signs: each word with its own
    /// confidence, an unclear sign under `leastSentenceWordConfidence`. Empty when it found one sign or none: then
    /// the word model's answer stands (it reads a lone sign better, and has the "not sure" threshold).
    public static func sentenceTokens(sentenceWords: [SignWordGuess], settings: SignReadingSettings = SignReadingSettings()) -> [SignToken] {
        guard sentenceWords.count >= 2 else { return [] }
        return sentenceWords.map { word in
            word.probability >= settings.leastSentenceWordConfidence ? .word(guesses: [word]) : .unclear(guesses: [word])
        }
    }
}

// MARK: - The line being signed

/// The words signed so far, waiting to be sent.
public struct SignedLine: Equatable, Sendable {
    public private(set) var tokens: [SignToken]

    public init(tokens: [SignToken] = []) {
        self.tokens = tokens
    }

    /// True when there is no word to send: unclear signs alone don't make a line worth sending.
    public var isEmpty: Bool { !tokens.contains { !$0.isUnclear } }

    public mutating func add(_ token: SignToken) {
        tokens.append(token)
    }

    /// Takes the last word off (nothing happens on an empty line).
    @discardableResult
    public mutating func removeLast() -> SignToken? {
        tokens.popLast()
    }

    public mutating func clear() {
        tokens = []
    }

    /// The words as typed into the app in front: each read token's text, joined by single spaces; unclear signs are
    /// left out.
    public var plainText: String {
        tokens.filter { !$0.isUnclear }.map { $0.text }.filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// What Vello is sent: the words, a blank line, then a note saying how they were read, so it reads them
    /// kindly (signing order is not English order, and a sign may have been misread). "Word N" counts the
    /// line's signs from 1. Empty for an empty line.
    public func messageForBrain(language: SignLanguage) -> String {
        guard !isEmpty else { return "" }
        var noteSentences: [String] = [
            "Signed to the camera in \(language.fullName) and read sign by sign, so the words follow signing order rather than English grammar and a sign may have been misread."
        ]
        if tokens.contains(where: { $0.isUnclear }) {
            noteSentences.append("A part in brackets is a sign that couldn't be read; any words given there are only the reader's guesses, not what was signed.")
        }
        for (tokenIndex, token) in tokens.enumerated() {
            let alternativeTexts = token.alternativeTexts
            guard !alternativeTexts.isEmpty else { continue }
            noteSentences.append("Word \(tokenIndex + 1) may also be: \(alternativeTexts.joined(separator: ", ")).")
        }
        noteSentences.append("Read it as the most sensible meaning.")
        let wordsWithUnclearSigns = tokens.map { token in token.unclearDescription() ?? token.text }.filter { !$0.isEmpty }.joined(separator: " ")
        return "\(wordsWithUnclearSigns)\n\n(\(noteSentences.joined(separator: " ")))"
    }
}

// MARK: - Sending by itself

/// Sends the line once the hands have rested for a while: true exactly once per rest with words waiting. A new
/// stretch, or the line being emptied, starts the wait again.
public struct SignAutoSend: Equatable, Sendable {
    /// 0 or less: never sends by itself.
    public let restSecondsBeforeSending: Double
    private var restStartTime: Double? = nil
    private var hasSentDuringThisRest = false

    public init(restSecondsBeforeSending: Double) {
        self.restSecondsBeforeSending = restSecondsBeforeSending
    }

    public var isEnabled: Bool { restSecondsBeforeSending > 0 }

    /// Call on every frame (or tick). Returns true when the line should be sent now.
    public mutating func observe(at time: Double, isInStretch: Bool, lineIsEmpty: Bool) -> Bool {
        if isInStretch || lineIsEmpty || !isEnabled {
            restStartTime = nil
            hasSentDuringThisRest = false
            return false
        }
        if hasSentDuringThisRest {
            return false
        }
        guard let waitStartTime = restStartTime else {
            // The first moment at rest with words waiting: the wait starts now.
            restStartTime = time
            return false
        }
        if time - waitStartTime >= restSecondsBeforeSending {
            hasSentDuringThisRest = true
            return true
        }
        return false
    }

    /// 0–1, how far through the wait it is, for the panel's ring. 0 while not waiting, and once sent.
    public func progress(at time: Double) -> Double {
        guard isEnabled, !hasSentDuringThisRest, let waitStartTime = restStartTime else { return 0 }
        let fractionWaited = (time - waitStartTime) / restSecondsBeforeSending
        return min(max(fractionWaited, 0), 1)
    }
}
