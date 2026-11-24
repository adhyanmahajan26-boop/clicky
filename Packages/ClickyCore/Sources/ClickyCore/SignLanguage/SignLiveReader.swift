//
//  SignLiveReader.swift
//  ClickyCore
//
//  Sign to text, the whole reading loop with no camera and no Core ML in it, so every step is tested with made-up
//  frames and a made-up scorer:
//
//  frames with their times → `SignStretchFinder` (where a sign starts and ends) → the stretch brought to 30 frames a
//  second (`SignFrameRate`) → cut to the frames with a hand → 117 features a frame (`SignFeatures`) → fitted to each
//  model's frame count → the models' scores (`SignStretchScoring`: Core ML in the app and the tools, a fake in tests)
//  → a word or a finger-spelled word (`SignStretchReading.token`) → the line (`SignedLine`) → sent by itself once the
//  hands have rested (`SignAutoSend`). Tools/signs/SPEC.md section 3 "Order" is followed step by step.
//
//  Scoring can take a while (a word model on 96 frames, a spelling model on 256), so it is split off: `observe`
//  only finds stretches and hands back a `SignStretchJob`; `SignLiveReader.read(_:scoring:settings:)` is a pure
//  function that can run on any queue; `finishReading(_:)` puts its outcome on the line. Each job carries a
//  sequence number, and outcomes that come back early wait for the ones before them, so the words always land in
//  the order they were signed and no frame waits for a model. `observeAndReadNow` does all three at once, for tests
//  and tools.
//

import Foundation

// MARK: - Scoring

/// What a finger-spelling model reads (Tools/signs/SPEC.md section 4).
public enum SignSpellingModelKind: String, Sendable {
    /// ASL: finger-spelling on the move. Rows of scores, one per 2 frames (CTC): column 0 the blank, column i + 1
    /// character i.
    case movingLetters
    /// ISL: one still letter (two hands) from one frame, a score per letter.
    case stillLetter
}

/// The models, as the live reader sees them. The Core ML runner (`SignCoreMLScorer`) is the real one.
/// Called from one queue at a time (the reader's scoring queue), never from two at once.
public protocol SignStretchScoring: AnyObject {
    /// How many frames the word model reads (96), or nil when there is no word model.
    var wordModelFrameCount: Int? { get }
    /// The word model's labels, one per score.
    var wordLabels: [String] { get }
    /// How many frames the finger-spelling model reads (256 moving, 1 still), or nil when there is none.
    var spellingModelFrameCount: Int? { get }
    var spellingModelKind: SignSpellingModelKind { get }
    /// The spelling model's characters (moving: score i + 1 is character i; still: score i is letter i).
    var spellingCharacters: [String] { get }
    /// A model's own `<name>.reading.json` may say how sure a word must be; nil keeps `SignReadingSettings`'.
    var leastWordProbabilityOverride: Float? { get }

    /// `features` is `frameCount × 117` values (row-major) and `mask` `frameCount` values, 1 for a real frame.
    /// Returns one score per word label.
    func wordScores(features: [Float], mask: [Float]) throws -> [Float]
    /// Moving letters: `rows × (characters + 1)` scores, row-major. Still letter: one score per character.
    func spellingScores(features: [Float], mask: [Float]) throws -> [Float]

    /// How many frames the sentence model reads (384), or nil when there is none (then stretches read as today).
    var sentenceModelFrameCount: Int? { get }
    /// The sentence model's words: score column i + 1 is word i, column 0 the blank.
    var sentenceLabels: [String] { get }
    /// `rows × (sentence labels + 1)` scores, row-major (CTC, a row per 2 frames).
    func sentenceScores(features: [Float], mask: [Float]) throws -> [Float]
}

/// Scorers without a sentence model read every stretch as one sign.
public extension SignStretchScoring {
    var sentenceModelFrameCount: Int? { nil }
    var sentenceLabels: [String] { [] }
    func sentenceScores(features: [Float], mask: [Float]) throws -> [Float] { [] }
}

// MARK: - Jobs and outcomes

/// One stretch to read: its frames and their times, as the camera gave them.
public struct SignStretchJob: Equatable, Sendable {
    /// Which reader asked, so an outcome for a reader that was since replaced (another language) is ignored.
    public let readerIdentifier: UUID
    /// 0, 1, 2 … in the order the stretches ended.
    public let sequenceNumber: Int
    public let frames: [SignLandmarkFrame]
    public let frameTimes: [Double]
    public let pictureWidth: Double
    public let pictureHeight: Double

    public init(
        readerIdentifier: UUID,
        sequenceNumber: Int,
        frames: [SignLandmarkFrame],
        frameTimes: [Double],
        pictureWidth: Double,
        pictureHeight: Double
    ) {
        self.readerIdentifier = readerIdentifier
        self.sequenceNumber = sequenceNumber
        self.frames = frames
        self.frameTimes = frameTimes
        self.pictureWidth = pictureWidth
        self.pictureHeight = pictureHeight
    }

    public var startTime: Double { frameTimes.first ?? 0 }
    public var endTime: Double { frameTimes.last ?? 0 }
}

/// What reading one stretch gave.
public struct SignStretchOutcome: Equatable, Sendable {
    public let readerIdentifier: UUID
    public let sequenceNumber: Int
    public let startTime: Double
    public let endTime: Double
    /// The word or spelled word; nil when the stretch was read but nothing was sure enough (shown as "?").
    public let token: SignToken?
    /// The word model's top guesses and the spelling model's reading, kept for the debug state.
    public let wordGuesses: [SignWordGuess]
    public let spelling: SignSpelledGuess?
    /// How many frames the models saw (after bringing to 30 a second and cutting to the frames with a hand).
    public let framesRead: Int
    /// Set when the stretch couldn't be read at all (no model, a model failed); then nothing goes on the line.
    public let couldNotRead: String?
    /// The sentence model's words when it read a run of two or more signs (they go on the line instead of `token`);
    /// empty otherwise. `sentenceWords` is what it read, kept for the debug state even when the word model's answer
    /// stood.
    public let sentenceTokens: [SignToken]
    public let sentenceWords: [SignWordGuess]

    public init(
        readerIdentifier: UUID,
        sequenceNumber: Int,
        startTime: Double,
        endTime: Double,
        token: SignToken?,
        wordGuesses: [SignWordGuess],
        spelling: SignSpelledGuess?,
        framesRead: Int,
        couldNotRead: String?,
        sentenceTokens: [SignToken] = [],
        sentenceWords: [SignWordGuess] = []
    ) {
        self.readerIdentifier = readerIdentifier
        self.sequenceNumber = sequenceNumber
        self.startTime = startTime
        self.endTime = endTime
        self.token = token
        self.wordGuesses = wordGuesses
        self.spelling = spelling
        self.framesRead = framesRead
        self.couldNotRead = couldNotRead
        self.sentenceTokens = sentenceTokens
        self.sentenceWords = sentenceWords
    }

    /// True when the sentence model's words went on the line.
    public var isReadAsARunOfSigns: Bool { !sentenceTokens.isEmpty }
}

// MARK: - The line as shown

/// One entry of the line on the panel: a word, a spelled word, or a sign that wasn't clear ("?"). Unclear entries
/// are shown so the signer knows a sign was seen, but are never sent.
public struct SignLiveLineEntry: Equatable, Sendable {
    public enum Kind: String, Sendable {
        case word
        case spelled
        case unclear
    }

    public let token: SignToken?
    public let startTime: Double
    public let endTime: Double
    public let wordGuesses: [SignWordGuess]
    public let spelling: SignSpelledGuess?

    public init(token: SignToken?, startTime: Double, endTime: Double, wordGuesses: [SignWordGuess], spelling: SignSpelledGuess?) {
        self.token = token
        self.startTime = startTime
        self.endTime = endTime
        self.wordGuesses = wordGuesses
        self.spelling = spelling
    }

    public var kind: Kind {
        switch token {
        case .word?: return .word
        case .spelled?: return .spelled
        case .unclear?, nil: return .unclear
        }
    }

    /// What the panel shows: the word, the spelled letters, or "?".
    public var displayText: String {
        token?.text ?? SignLiveReader.unclearSignText
    }
}

// MARK: - Events

public enum SignLiveEvent: Equatable, Sendable {
    /// A hand came up: a sign is being made.
    case signStarted(at: Double)
    /// The hand went down too soon to be a sign.
    case tooShortToCount
    /// A sign ended: read this job (off the main thread in the app) and hand the outcome to `finishReading`.
    case readingNeeded(SignStretchJob)
    /// A sign was read and is on the line now (a word, a spelled word, or unclear).
    case read(SignLiveLineEntry)
    /// A sign could not be read at all (no model, or a model failed). Nothing was added.
    case couldNotRead(String)
    /// The hands have rested long enough with words waiting: send the line now (`takeLineForSending`).
    case timeToSend
}

// MARK: - The reader

public struct SignLiveReader {
    /// What an unclear sign shows as.
    public static let unclearSignText = "?"
    /// How many word guesses are kept on each outcome for the debug state.
    public static let wordGuessesKept = 5
    /// A still-letter (ISL) model is read on every this-many-th frame of a stretch at 30 a second: 10 looks a second.
    public static let stillLetterFrameStep = 3

    public let language: SignLanguage
    public let readerIdentifier = UUID()
    public private(set) var pictureWidth: Double
    public private(set) var pictureHeight: Double
    public var readingSettings: SignReadingSettings
    public let stretchSettings: SignStretchSettings

    private var stretchFinder: SignStretchFinder
    private var autoSend: SignAutoSend
    private var nextSequenceNumber = 0
    /// The next outcome to put on the line; later ones wait in `outcomesWaitingForEarlierOnes`.
    private var nextSequenceNumberToAdd = 0
    private var outcomesWaitingForEarlierOnes: [Int: SignStretchOutcome] = [:]
    /// Outcomes for stretches that ended before this number are dropped (the line was cleared while they were read).
    private var firstSequenceNumberStillWanted = 0

    public private(set) var entries: [SignLiveLineEntry] = []
    public private(set) var lastFrameTime: Double?

    public init(
        language: SignLanguage,
        pictureWidth: Double,
        pictureHeight: Double,
        autoSendSeconds: Double,
        stretchSettings: SignStretchSettings = SignStretchSettings(),
        readingSettings: SignReadingSettings = SignReadingSettings()
    ) {
        self.language = language
        self.pictureWidth = pictureWidth
        self.pictureHeight = pictureHeight
        self.stretchSettings = stretchSettings
        self.readingSettings = readingSettings
        stretchFinder = SignStretchFinder(settings: stretchSettings, pictureWidth: pictureWidth, pictureHeight: pictureHeight)
        autoSend = SignAutoSend(restSecondsBeforeSending: autoSendSeconds)
    }

    // MARK: State

    /// The line that will be sent: unclear signs are in it (Vello's brain hears them as unclear, with guesses), but
    /// left out of the plain text typed into the app in front.
    public var line: SignedLine {
        SignedLine(tokens: entries.compactMap { $0.token })
    }

    /// A hand is up and a sign is being collected right now.
    public var isSigning: Bool { stretchFinder.isInStretch }

    /// Stretches handed out for reading whose outcome hasn't been put on the line yet.
    public var readingsInProgress: Int { nextSequenceNumber - nextSequenceNumberToAdd }

    public var autoSendSeconds: Double { autoSend.restSecondsBeforeSending }

    /// 0–1, how far through the wait before sending by itself, for the panel's countdown.
    public func autoSendProgress(at time: Double) -> Double {
        autoSend.progress(at: time)
    }

    public mutating func setAutoSendSeconds(_ seconds: Double) {
        guard seconds != autoSend.restSecondsBeforeSending else { return }
        autoSend = SignAutoSend(restSecondsBeforeSending: seconds)
    }

    /// The camera's picture size changed: the stretch finder measures shoulders with it, so it starts again (a sign
    /// being made right now is lost, which only happens when the camera itself changes).
    public mutating func setPictureSize(width: Double, height: Double) {
        guard width != pictureWidth || height != pictureHeight else { return }
        pictureWidth = width
        pictureHeight = height
        stretchFinder = SignStretchFinder(settings: stretchSettings, pictureWidth: width, pictureHeight: height)
    }

    /// Forgets a sign being made right now (the camera paused mid-sign: after a lock the hands are elsewhere), and
    /// the wait before sending by itself, but keeps the line and any sign already being read.
    public mutating func forgetSignInProgress() {
        stretchFinder.reset()
        autoSend = SignAutoSend(restSecondsBeforeSending: autoSend.restSecondsBeforeSending)
    }

    // MARK: Frames

    /// The next camera frame (times in seconds, rising). Cheap: nothing here runs a model.
    public mutating func observe(_ frame: SignLandmarkFrame, at time: Double) -> [SignLiveEvent] {
        var events: [SignLiveEvent] = []
        lastFrameTime = time
        if let stretchEvent = stretchFinder.observe(frame, at: time) {
            switch stretchEvent {
            case .started:
                events.append(.signStarted(at: time))
            case .droppedTooShort:
                events.append(.tooShortToCount)
            case .ended(let stretch):
                events.append(.readingNeeded(makeJob(for: stretch)))
            }
        }
        // A sign being read counts as still signing, so the line is never sent without its last word.
        let isStillSigningOrReading = stretchFinder.isInStretch || readingsInProgress > 0
        if autoSend.observe(at: time, isInStretch: isStillSigningOrReading, lineIsEmpty: line.isEmpty) {
            events.append(.timeToSend)
        }
        return events
    }

    /// Puts a finished reading on the line, after any earlier ones still being read. Returns what was added, in order.
    public mutating func finishReading(_ outcome: SignStretchOutcome) -> [SignLiveEvent] {
        guard outcome.readerIdentifier == readerIdentifier,
              outcome.sequenceNumber >= nextSequenceNumberToAdd,
              outcome.sequenceNumber < nextSequenceNumber
        else { return [] }
        outcomesWaitingForEarlierOnes[outcome.sequenceNumber] = outcome

        var events: [SignLiveEvent] = []
        while let nextOutcome = outcomesWaitingForEarlierOnes.removeValue(forKey: nextSequenceNumberToAdd) {
            nextSequenceNumberToAdd += 1
            guard nextOutcome.sequenceNumber >= firstSequenceNumberStillWanted else { continue }
            if let reason = nextOutcome.couldNotRead {
                events.append(.couldNotRead(reason))
                continue
            }
            if nextOutcome.isReadAsARunOfSigns {
                // A run of signs read by the sentence model: one entry per word, in order.
                for sentenceToken in nextOutcome.sentenceTokens {
                    let entry = SignLiveLineEntry(token: sentenceToken, startTime: nextOutcome.startTime, endTime: nextOutcome.endTime,
                                                  wordGuesses: [], spelling: nil)
                    entries.append(entry)
                    events.append(.read(entry))
                }
                continue
            }
            let entry = SignLiveLineEntry(
                token: nextOutcome.token,
                startTime: nextOutcome.startTime,
                endTime: nextOutcome.endTime,
                wordGuesses: nextOutcome.wordGuesses,
                spelling: nextOutcome.spelling
            )
            entries.append(entry)
            events.append(.read(entry))
        }
        return events
    }

    /// `observe`, then any stretch that ended is read here and now with `scoring` (tests and tools; the app reads
    /// off the main thread instead). The `.readingNeeded` event is replaced by what the reading gave.
    public mutating func observeAndReadNow(_ frame: SignLandmarkFrame, at time: Double, scoring: SignStretchScoring?) -> [SignLiveEvent] {
        var events: [SignLiveEvent] = []
        for event in observe(frame, at: time) {
            if case .readingNeeded(let job) = event {
                let outcome = Self.read(job, scoring: scoring, settings: readingSettings)
                events.append(contentsOf: finishReading(outcome))
            } else {
                events.append(event)
            }
        }
        return events
    }

    // MARK: Editing the line

    /// Takes the last entry off (a word, a spelled word or a "?"). Nil on an empty line.
    @discardableResult
    public mutating func undoLast() -> SignLiveLineEntry? {
        entries.popLast()
    }

    /// Empties the line, and drops any sign still being read, so nothing lands after the owner cleared it.
    public mutating func clear() {
        entries = []
        firstSequenceNumberStillWanted = nextSequenceNumber
    }

    /// The line to send, and a fresh line after it; nil (and nothing changes) when there are no words to send.
    /// Signs still being read land on the new line.
    public mutating func takeLineForSending() -> SignedLine? {
        let lineToSend = line
        guard !lineToSend.isEmpty else { return nil }
        entries = []
        return lineToSend
    }

    // MARK: Reading one stretch (any queue)

    /// SPEC section 3 "Order": the stretch is brought to 30 frames a second, cut to run from the first frame with a
    /// hand to the last (judged on the landmarks as seen), its features are made over all those frames, then it is
    /// thinned or padded to each model's frame count and scored. Finger-spelling is only scored when the stretch
    /// looks like it (it can't win otherwise, so the slower model isn't run for nothing).
    public static func read(_ job: SignStretchJob, scoring: SignStretchScoring?, settings: SignReadingSettings) -> SignStretchOutcome {
        func outcome(token: SignToken?, wordGuesses: [SignWordGuess] = [], spelling: SignSpelledGuess? = nil, framesRead: Int, couldNotRead: String? = nil,
                     sentenceTokens: [SignToken] = [], sentenceWords: [SignWordGuess] = []) -> SignStretchOutcome {
            SignStretchOutcome(
                readerIdentifier: job.readerIdentifier,
                sequenceNumber: job.sequenceNumber,
                startTime: job.startTime,
                endTime: job.endTime,
                token: token,
                wordGuesses: wordGuesses,
                spelling: spelling,
                framesRead: framesRead,
                couldNotRead: couldNotRead,
                sentenceTokens: sentenceTokens,
                sentenceWords: sentenceWords
            )
        }

        guard let scoring, scoring.wordModelFrameCount != nil || scoring.spellingModelFrameCount != nil else {
            return outcome(token: nil, framesRead: 0, couldNotRead: "no sign models")
        }

        let atModelRate = SignFrameRate.broughtTo30(frames: job.frames, times: job.frameTimes)
        let framesWithAHand = atModelRate.frames.indices.filter { frameIndex in
            SignFeatures.handIsSeen(in: atModelRate.frames[frameIndex], side: .right)
                || SignFeatures.handIsSeen(in: atModelRate.frames[frameIndex], side: .left)
        }
        // A stretch with no hand at all is kept whole, as SignFeatures and Python do.
        let firstKeptFrame = framesWithAHand.first ?? 0
        let lastKeptFrame = framesWithAHand.last ?? max(atModelRate.frames.count - 1, 0)
        guard !atModelRate.frames.isEmpty else { return outcome(token: nil, framesRead: 0) }
        let keptFrames = Array(atModelRate.frames[firstKeptFrame...lastKeptFrame])
        let keptSeconds = atModelRate.times[lastKeptFrame] - atModelRate.times[firstKeptFrame]

        let featureClip = SignFeatures.featureClip(of: keptFrames, pictureWidth: job.pictureWidth, pictureHeight: job.pictureHeight)
        let facts = SignStretchFacts(clip: featureClip, seconds: keptSeconds)
        var effectiveSettings = settings
        if let leastWordProbabilityOverride = scoring.leastWordProbabilityOverride {
            effectiveSettings.leastWordProbability = leastWordProbabilityOverride
        }

        var wordGuesses: [SignWordGuess] = []
        var spelling: SignSpelledGuess?
        do {
            if let wordModelFrameCount = scoring.wordModelFrameCount {
                let fitted = SignFeatures.fitted(featureClip, toFrameCount: wordModelFrameCount)
                let wordScores = try scoring.wordScores(features: fitted.values, mask: fitted.mask)
                wordGuesses = SignWordScores.topGuesses(scores: wordScores, labels: scoring.wordLabels, count: wordGuessesKept)
            }
            if let spellingModelFrameCount = scoring.spellingModelFrameCount, facts.looksLikeFingerSpelling(settings: effectiveSettings) {
                switch scoring.spellingModelKind {
                case .movingLetters:
                    spelling = try readMovingLetters(featureClip: featureClip, frameCount: spellingModelFrameCount, scoring: scoring)
                case .stillLetter:
                    spelling = try readStillLetters(featureClip: featureClip, scoring: scoring)
                }
            }
        } catch {
            return outcome(token: nil, wordGuesses: wordGuesses, spelling: spelling, framesRead: keptFrames.count,
                           couldNotRead: "a sign model failed: \(error)")
        }

        let token = SignStretchReading.token(wordGuesses: wordGuesses, spelling: spelling, facts: facts, settings: effectiveSettings)

        // A stretch that isn't finger-spelling is also read by the sentence model, when there is one: two or more
        // signs found, and its words go on the line instead; one or none, and the word model's answer stands.
        var sentenceWords: [SignWordGuess] = []
        var sentenceTokens: [SignToken] = []
        if let sentenceModelFrameCount = scoring.sentenceModelFrameCount, !scoring.sentenceLabels.isEmpty {
            if case .spelled? = token {} else {
                do {
                    let fitted = SignFeatures.fitted(featureClip, toFrameCount: sentenceModelFrameCount)
                    let sentenceScores = try scoring.sentenceScores(features: fitted.values, mask: fitted.mask)
                    let columnCount = scoring.sentenceLabels.count + 1
                    if sentenceScores.count % columnCount == 0 {
                        sentenceWords = SignSentenceDecoder.words(
                            scores: sentenceScores,
                            rowCount: sentenceScores.count / columnCount,
                            usedRowCount: SignSpellingDecoder.usedRowCount(forRealFrameCount: min(featureClip.frameCount, sentenceModelFrameCount)),
                            labels: scoring.sentenceLabels
                        )
                        sentenceTokens = SignStretchReading.sentenceTokens(sentenceWords: sentenceWords, settings: effectiveSettings)
                    }
                } catch {
                    // The sentence model failing leaves the word model's answer, as with no sentence model.
                }
            }
        }
        return outcome(token: token, wordGuesses: wordGuesses, spelling: spelling, framesRead: keptFrames.count,
                       sentenceTokens: sentenceTokens, sentenceWords: sentenceWords)
    }

    private static func readMovingLetters(featureClip: SignFeatureClip, frameCount: Int, scoring: SignStretchScoring) throws -> SignSpelledGuess {
        let fitted = SignFeatures.fitted(featureClip, toFrameCount: frameCount)
        let spellingScores = try scoring.spellingScores(features: fitted.values, mask: fitted.mask)
        let columnCount = scoring.spellingCharacters.count + 1
        guard columnCount > 1, spellingScores.count % columnCount == 0 else { return .nothing }
        let rowCount = spellingScores.count / columnCount
        let realFrameCount = min(featureClip.frameCount, frameCount)
        return SignSpellingDecoder.greedy(
            scores: spellingScores,
            rowCount: rowCount,
            usedRowCount: SignSpellingDecoder.usedRowCount(forRealFrameCount: realFrameCount),
            characters: scoring.spellingCharacters
        )
    }

    /// A still-letter model reads one frame; the stretch is looked at 10 times a second and the looks are joined
    /// into letters by `SignStillLetterJoiner`.
    private static func readStillLetters(featureClip: SignFeatureClip, scoring: SignStretchScoring) throws -> SignSpelledGuess {
        let featureCount = SignFeatures.featureCount
        let completeFrameCount = min(featureClip.frameCount, featureClip.values.count / featureCount)
        var looks: [SignStillLetterLook] = []
        var frameIndex = 0
        while frameIndex < completeFrameCount {
            let rowStart = frameIndex * featureCount
            let rowValues = Array(featureClip.values[rowStart..<(rowStart + featureCount)])
            let letterScores = try scoring.spellingScores(features: rowValues, mask: [1])
            if letterScores.count == scoring.spellingCharacters.count, !letterScores.isEmpty {
                let probabilities = SignWordScores.probabilities(scores: letterScores)
                if let bestIndex = probabilities.indices.max(by: { probabilities[$0] < probabilities[$1] }) {
                    looks.append(SignStillLetterLook(letter: scoring.spellingCharacters[bestIndex], probability: probabilities[bestIndex]))
                }
            }
            frameIndex += stillLetterFrameStep
        }
        return SignStillLetterJoiner.join(looks)
    }

    // MARK: Private

    private mutating func makeJob(for stretch: SignStretch) -> SignStretchJob {
        let sequenceNumber = nextSequenceNumber
        nextSequenceNumber += 1
        return SignStretchJob(
            readerIdentifier: readerIdentifier,
            sequenceNumber: sequenceNumber,
            frames: stretch.frames,
            frameTimes: stretch.frameTimes,
            pictureWidth: pictureWidth,
            pictureHeight: pictureHeight
        )
    }
}

// MARK: - Still letters (ISL)

/// One look at a still letter: the best letter in one frame and how likely the model said it was.
public struct SignStillLetterLook: Equatable, Sendable {
    public var letter: String
    public var probability: Float

    public init(letter: String, probability: Float) {
        self.letter = letter
        self.probability = probability
    }
}

/// Joins looks at a still-letter model (10 a second) into spelled letters: a letter counts once it is the best
/// letter, sure enough, in `looksToHold` looks in a row; the same letter again needs another reading in between.
public enum SignStillLetterJoiner {
    /// 3 looks at 10 a second: the letter held for about 0.3 s.
    public static let looksToHold = 3
    /// A look under this probability counts as no letter (the hand moving between letters).
    public static let leastLookProbability: Float = 0.5

    public static func join(_ looks: [SignStillLetterLook]) -> SignSpelledGuess {
        var letters: [String] = []
        var letterConfidences: [Float] = []
        var heldLetter: String?
        var heldLookCount = 0
        var heldProbabilityTotal: Float = 0
        var heldLetterWasCounted = false
        for look in looks {
            let lookLetter: String? = look.probability >= leastLookProbability ? look.letter : nil
            if lookLetter != heldLetter {
                heldLetter = lookLetter
                heldLookCount = 0
                heldProbabilityTotal = 0
                heldLetterWasCounted = false
            }
            guard let lookLetter else { continue }
            heldLookCount += 1
            heldProbabilityTotal += look.probability
            if heldLookCount >= looksToHold && !heldLetterWasCounted {
                letters.append(lookLetter)
                letterConfidences.append(heldProbabilityTotal / Float(heldLookCount))
                heldLetterWasCounted = true
            }
        }
        guard !letters.isEmpty else { return .nothing }
        let meanConfidence = letterConfidences.reduce(Float(0), +) / Float(letterConfidences.count)
        return SignSpelledGuess(text: letters.joined(), confidence: meanConfidence)
    }
}
