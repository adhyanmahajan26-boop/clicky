import Foundation
import Testing
@testable import ClickyCore

/// Sign to text, live: frames in, words on the line out (`SignLiveReader`), with a made-up scorer in place of the
/// Core ML models.
struct SignLiveReaderTests {
    // MARK: A made-up scorer

    /// Stands in for the models. The word it gives is chosen from where the right wrist is (left of the shoulders'
    /// middle is one word, right of it another), so different made-up signs read as different words; it also
    /// remembers how many real frames each model was shown.
    final class FakeSignScorer: SignStretchScoring {
        var wordModelFrameCount: Int? = 96
        var wordLabels = ["hello", "thankyou", "yes", "no", "please", "sorry", "help", "more", "stop", "go"]
        var spellingModelFrameCount: Int? = 256
        var spellingModelKind: SignSpellingModelKind = .movingLetters
        var spellingCharacters = ["h", "i", "a"]
        var leastWordProbabilityOverride: Float?

        /// The word for a sign made with the right wrist left of the middle, and right of it; nil gives flat scores
        /// (no word sure enough).
        var wordWhenWristIsLeftOfMiddle: String? = "hello"
        var wordWhenWristIsRightOfMiddle: String? = "thankyou"
        /// When set, the spelling model reads these letters; otherwise it reads only blanks.
        var spelledLetters: String?

        private(set) var realFrameCountsShownToTheWordModel: [Int] = []
        private(set) var spellingModelRuns = 0

        func wordScores(features: [Float], mask: [Float]) throws -> [Float] {
            let realFrameCount = Int(mask.reduce(0, +))
            realFrameCountsShownToTheWordModel.append(realFrameCount)
            var scores = [Float](repeating: 0, count: wordLabels.count)
            // Feature 84 is the right wrist's place across, from the shoulders' middle, in body sizes.
            let rightWristAcross = features[SignFeatures.rightWristFeaturesStart]
            let chosenWord = rightWristAcross < 0 ? wordWhenWristIsLeftOfMiddle : wordWhenWristIsRightOfMiddle
            if let chosenWord, let wordIndex = wordLabels.firstIndex(of: chosenWord) {
                scores[wordIndex] = 10
            }
            return scores
        }

        func spellingScores(features: [Float], mask: [Float]) throws -> [Float] {
            spellingModelRuns += 1
            let rowCount = mask.count / 2
            let columnCount = spellingCharacters.count + 1
            var bestColumnOfEachRow = [Int](repeating: SignSpellingDecoder.blankColumn, count: rowCount)
            if let spelledLetters {
                // Each letter for two rows, then a blank row, from the first row on.
                var rowIndex = 0
                for letter in spelledLetters {
                    guard let characterIndex = spellingCharacters.firstIndex(of: String(letter)), rowIndex + 1 < rowCount else { continue }
                    bestColumnOfEachRow[rowIndex] = characterIndex + 1
                    bestColumnOfEachRow[rowIndex + 1] = characterIndex + 1
                    rowIndex += 3
                }
            }
            var scores = [Float](repeating: 0, count: rowCount * columnCount)
            for (rowIndex, bestColumn) in bestColumnOfEachRow.enumerated() {
                scores[rowIndex * columnCount + bestColumn] = 10
            }
            return scores
        }
    }

    // MARK: Made-up frames

    private static let raisedWristY: Float = 0.5
    private static let leftOfMiddleWristX: Float = 0.3
    private static let rightOfMiddleWristX: Float = 0.7

    /// Shoulders at y 0.45, 0.2 apart (the rest line is at 0.75) and, when `wristX` is given, a right hand with
    /// every joint seen, raised, its wrist at that x.
    private static func frame(wristX: Float?) -> SignLandmarkFrame {
        var frame = SignLandmarkFrame()
        frame[SignBodyPoint.leftShoulder] = SignLandmarkPoint(x: 0.6, y: 0.45, confidence: 0.9)
        frame[SignBodyPoint.rightShoulder] = SignLandmarkPoint(x: 0.4, y: 0.45, confidence: 0.9)
        if let wristX {
            for (jointNumber, joint) in HandJoint.allCases.enumerated() {
                let offset = Float(jointNumber) * 0.002
                frame.setHandJoint(side: .right, joint: joint, point: SignLandmarkPoint(x: wristX + offset, y: raisedWristY - offset, confidence: 0.9))
            }
        }
        return frame
    }

    /// A plan of frames: `count` frames, each with a raised hand at `wristX` or no hand (nil).
    private struct FramePlanPart {
        let wristX: Float?
        let count: Int
    }

    private static func rest(_ count: Int) -> FramePlanPart { FramePlanPart(wristX: nil, count: count) }
    private static func sign(at wristX: Float, _ count: Int) -> FramePlanPart { FramePlanPart(wristX: wristX, count: count) }

    /// Feeds the plan at `framesPerSecond`, from frame number `firstFrameNumber`, reading each stretch at once.
    @discardableResult
    private static func feed(
        _ plan: [FramePlanPart],
        into reader: inout SignLiveReader,
        scoring: SignStretchScoring?,
        framesPerSecond: Double = 30,
        firstFrameNumber: Int = 0
    ) -> (events: [SignLiveEvent], nextFrameNumber: Int) {
        var events: [SignLiveEvent] = []
        var frameNumber = firstFrameNumber
        for part in plan {
            for _ in 0..<part.count {
                let time = Double(frameNumber) / framesPerSecond
                events += reader.observeAndReadNow(frame(wristX: part.wristX), at: time, scoring: scoring)
                frameNumber += 1
            }
        }
        return (events, frameNumber)
    }

    private static func readEntries(_ events: [SignLiveEvent]) -> [SignLiveLineEntry] {
        events.compactMap { event in
            if case .read(let entry) = event { return entry }
            return nil
        }
    }

    private static func newReader(autoSendSeconds: Double = 0) -> SignLiveReader {
        SignLiveReader(language: .asl, pictureWidth: 0, pictureHeight: 0, autoSendSeconds: autoSendSeconds)
    }

    // MARK: Tests

    @Test func aSignIsReadAsAWord() {
        var reader = Self.newReader()
        let scorer = FakeSignScorer()
        let fed = Self.feed([Self.rest(15), Self.sign(at: Self.leftOfMiddleWristX, 30), Self.rest(30)], into: &reader, scoring: scorer)

        #expect(fed.events.contains { if case .signStarted = $0 { return true }; return false })
        let entries = Self.readEntries(fed.events)
        #expect(entries.count == 1)
        #expect(entries.first?.kind == .word)
        #expect(entries.first?.displayText == "hello")
        #expect(reader.line.plainText == "hello")
        #expect(!reader.isSigning)
        #expect(reader.readingsInProgress == 0)
    }

    @Test func aStillOneHandedStretchWithNoSureWordIsReadAsASpelledWord() {
        var reader = Self.newReader()
        let scorer = FakeSignScorer()
        scorer.wordWhenWristIsLeftOfMiddle = nil
        scorer.spelledLetters = "hi"
        let fed = Self.feed([Self.rest(15), Self.sign(at: Self.leftOfMiddleWristX, 30), Self.rest(30)], into: &reader, scoring: scorer)

        let entries = Self.readEntries(fed.events)
        #expect(entries.count == 1)
        #expect(entries.first?.kind == .spelled)
        #expect(entries.first?.displayText == "hi")
        #expect(reader.line.tokens.first == .spelled(text: "hi", confidence: entries.first?.spelling?.confidence ?? 0))
    }

    @Test func aSignNothingIsSureOfShowsAsUnclearAndIsNeverSent() {
        var reader = Self.newReader()
        let scorer = FakeSignScorer()
        scorer.wordWhenWristIsLeftOfMiddle = nil
        let fed = Self.feed([Self.rest(15), Self.sign(at: Self.leftOfMiddleWristX, 30), Self.rest(30)], into: &reader, scoring: scorer)

        let entries = Self.readEntries(fed.events)
        #expect(entries.count == 1)
        #expect(entries.first?.kind == .unclear)
        #expect(entries.first?.displayText == "?")
        #expect(reader.entries.count == 1)
        #expect(reader.line.isEmpty)
        #expect(reader.takeLineForSending() == nil)
    }

    @Test func twoSignsLandInTheOrderTheyWereMade() {
        var reader = Self.newReader()
        let scorer = FakeSignScorer()
        Self.feed([
            Self.rest(15),
            Self.sign(at: Self.leftOfMiddleWristX, 30),
            Self.rest(25),
            Self.sign(at: Self.rightOfMiddleWristX, 30),
            Self.rest(30)
        ], into: &reader, scoring: scorer)
        #expect(reader.entries.map { $0.displayText } == ["hello", "thank you"])
        #expect(reader.line.plainText == "hello thank you")
    }

    @Test func readingsThatFinishOutOfOrderStillLandInOrder() {
        var reader = Self.newReader()
        let scorer = FakeSignScorer()
        // Observe only (the app's way): collect the jobs without reading them.
        var jobs: [SignStretchJob] = []
        var frameNumber = 0
        let plan = [Self.rest(15), Self.sign(at: Self.leftOfMiddleWristX, 30), Self.rest(25), Self.sign(at: Self.rightOfMiddleWristX, 30), Self.rest(30)]
        for part in plan {
            for _ in 0..<part.count {
                for event in reader.observe(Self.frame(wristX: part.wristX), at: Double(frameNumber) / 30) {
                    if case .readingNeeded(let job) = event { jobs.append(job) }
                }
                frameNumber += 1
            }
        }
        #expect(jobs.map { $0.sequenceNumber } == [0, 1])
        #expect(reader.readingsInProgress == 2)
        guard jobs.count == 2 else { return }

        let secondOutcome = SignLiveReader.read(jobs[1], scoring: scorer, settings: reader.readingSettings)
        let firstOutcome = SignLiveReader.read(jobs[0], scoring: scorer, settings: reader.readingSettings)
        // The second sign's reading is back first: it waits for the first.
        #expect(reader.finishReading(secondOutcome).isEmpty)
        #expect(reader.entries.isEmpty)
        let landed = Self.readEntries(reader.finishReading(firstOutcome))
        #expect(landed.map { $0.displayText } == ["hello", "thank you"])
        #expect(reader.readingsInProgress == 0)
        // The same outcome again is ignored.
        #expect(reader.finishReading(firstOutcome).isEmpty)
    }

    @Test func aReadingFromAnotherReaderIsIgnored() {
        var reader = Self.newReader()
        var otherReader = Self.newReader()
        let scorer = FakeSignScorer()
        var otherJobs: [SignStretchJob] = []
        var frameNumber = 0
        for part in [Self.rest(15), Self.sign(at: Self.leftOfMiddleWristX, 30), Self.rest(30)] {
            for _ in 0..<part.count {
                for event in otherReader.observe(Self.frame(wristX: part.wristX), at: Double(frameNumber) / 30) {
                    if case .readingNeeded(let job) = event { otherJobs.append(job) }
                }
                frameNumber += 1
            }
        }
        guard let otherJob = otherJobs.first else {
            Issue.record("expected a job from the other reader")
            return
        }
        #expect(reader.finishReading(SignLiveReader.read(otherJob, scoring: scorer, settings: reader.readingSettings)).isEmpty)
        #expect(reader.entries.isEmpty)
    }

    @Test func theLineIsSentByItselfOnceTheHandsHaveRested() {
        var reader = Self.newReader(autoSendSeconds: 1.0)
        let scorer = FakeSignScorer()
        let fed = Self.feed([Self.rest(15), Self.sign(at: Self.leftOfMiddleWristX, 30), Self.rest(90)], into: &reader, scoring: scorer)

        let timeToSendCount = fed.events.filter { $0 == .timeToSend }.count
        #expect(timeToSendCount == 1)
        // Nothing is sent before the word was read.
        if let readIndex = fed.events.firstIndex(where: { if case .read = $0 { return true }; return false }),
           let sendIndex = fed.events.firstIndex(of: .timeToSend) {
            #expect(readIndex < sendIndex)
        } else {
            Issue.record("expected a read word and then a time to send")
        }
        let sentLine = reader.takeLineForSending()
        #expect(sentLine?.plainText == "hello")
        #expect(sentLine?.messageForBrain(language: .asl).hasPrefix("hello\n\n(Signed to the camera in American Sign Language") == true)
        #expect(reader.entries.isEmpty)

        // With the line empty, resting longer sends nothing more.
        let afterSending = Self.feed([Self.rest(60)], into: &reader, scoring: scorer, firstFrameNumber: fed.nextFrameNumber)
        #expect(!afterSending.events.contains(.timeToSend))
    }

    @Test func autoSendOffNeverSends() {
        var reader = Self.newReader(autoSendSeconds: 0)
        let fed = Self.feed([Self.rest(15), Self.sign(at: Self.leftOfMiddleWristX, 30), Self.rest(120)], into: &reader, scoring: FakeSignScorer())
        #expect(!fed.events.contains(.timeToSend))
        #expect(reader.autoSendProgress(at: 10) == 0)
    }

    @Test func undoTakesOffTheLastEntryAndClearEmptiesTheLine() {
        var reader = Self.newReader()
        let scorer = FakeSignScorer()
        Self.feed([
            Self.rest(15),
            Self.sign(at: Self.leftOfMiddleWristX, 30),
            Self.rest(25),
            Self.sign(at: Self.rightOfMiddleWristX, 30),
            Self.rest(30)
        ], into: &reader, scoring: scorer)
        #expect(reader.entries.count == 2)

        #expect(reader.undoLast()?.displayText == "thank you")
        #expect(reader.line.plainText == "hello")
        #expect(reader.undoLast()?.displayText == "hello")
        #expect(reader.undoLast() == nil)
        #expect(reader.line.isEmpty)

        Self.feed([Self.sign(at: Self.leftOfMiddleWristX, 30), Self.rest(30)], into: &reader, scoring: scorer, firstFrameNumber: 1000)
        #expect(reader.entries.count == 1)
        reader.clear()
        #expect(reader.entries.isEmpty)
    }

    @Test func clearingWhileASignIsBeingReadDropsThatSign() {
        var reader = Self.newReader()
        var jobs: [SignStretchJob] = []
        var frameNumber = 0
        for part in [Self.rest(15), Self.sign(at: Self.leftOfMiddleWristX, 30), Self.rest(30)] {
            for _ in 0..<part.count {
                for event in reader.observe(Self.frame(wristX: part.wristX), at: Double(frameNumber) / 30) {
                    if case .readingNeeded(let job) = event { jobs.append(job) }
                }
                frameNumber += 1
            }
        }
        guard let job = jobs.first else {
            Issue.record("expected a job")
            return
        }
        reader.clear()
        #expect(reader.finishReading(SignLiveReader.read(job, scoring: FakeSignScorer(), settings: reader.readingSettings)).isEmpty)
        #expect(reader.entries.isEmpty)
        #expect(reader.readingsInProgress == 0)
    }

    @Test func aSlowCameraGivesTheSameWordAsAThirtyFrameOne() {
        // The fake reads "hello" only when it is shown about a second of frames at 30 a second (24 or more real
        // frames); 15 frames a second not brought to 30 would show it about 15.
        let scorerAt30 = FakeSignScorer()
        let scorerAt15 = FakeSignScorer()
        var readerAt30 = Self.newReader()
        var readerAt15 = Self.newReader()

        Self.feed([Self.rest(15), Self.sign(at: Self.leftOfMiddleWristX, 30), Self.rest(30)], into: &readerAt30, scoring: scorerAt30, framesPerSecond: 30)
        Self.feed([Self.rest(8), Self.sign(at: Self.leftOfMiddleWristX, 15), Self.rest(15)], into: &readerAt15, scoring: scorerAt15, framesPerSecond: 15)

        #expect(readerAt30.entries.map { $0.displayText } == ["hello"])
        #expect(readerAt15.entries.map { $0.displayText } == ["hello"])
        let framesAt30 = scorerAt30.realFrameCountsShownToTheWordModel.first ?? 0
        let framesAt15 = scorerAt15.realFrameCountsShownToTheWordModel.first ?? 0
        #expect(framesAt30 >= 24)
        #expect(framesAt15 >= 24)
        #expect(abs(framesAt30 - framesAt15) <= 3, "30 a second showed \(framesAt30) frames, 15 a second \(framesAt15)")
    }

    @Test func aBlipTooShortToBeASignIsSaidSoAndNothingIsRead() {
        var reader = Self.newReader()
        let scorer = FakeSignScorer()
        let fed = Self.feed([Self.rest(15), Self.sign(at: Self.leftOfMiddleWristX, 3), Self.rest(30)], into: &reader, scoring: scorer)
        #expect(fed.events.contains(.tooShortToCount))
        #expect(Self.readEntries(fed.events).isEmpty)
        #expect(scorer.realFrameCountsShownToTheWordModel.isEmpty)
    }

    @Test func withNoModelsASignIsSeenButNotRead() {
        var reader = Self.newReader()
        let fed = Self.feed([Self.rest(15), Self.sign(at: Self.leftOfMiddleWristX, 30), Self.rest(30)], into: &reader, scoring: nil)
        #expect(fed.events.contains { if case .couldNotRead = $0 { return true }; return false })
        #expect(reader.entries.isEmpty)
        #expect(reader.readingsInProgress == 0)
    }

    @Test func theSpellingModelIsOnlyRunWhenTheStretchLooksLikeSpelling() {
        // A sign that travels across the picture can't be finger-spelling.
        var reader = Self.newReader()
        let scorer = FakeSignScorer()
        var frameNumber = 0
        for _ in 0..<15 {
            _ = reader.observeAndReadNow(Self.frame(wristX: nil), at: Double(frameNumber) / 30, scoring: scorer)
            frameNumber += 1
        }
        for step in 0..<30 {
            let travellingWristX = 0.2 + Float(step) * 0.01
            _ = reader.observeAndReadNow(Self.frame(wristX: travellingWristX), at: Double(frameNumber) / 30, scoring: scorer)
            frameNumber += 1
        }
        for _ in 0..<30 {
            _ = reader.observeAndReadNow(Self.frame(wristX: nil), at: Double(frameNumber) / 30, scoring: scorer)
            frameNumber += 1
        }
        #expect(reader.entries.count == 1)
        #expect(scorer.spellingModelRuns == 0)
    }

    @Test func stillLetterLooksJoinIntoLetters() {
        func looks(_ letters: String, probability: Float = 0.9) -> [SignStillLetterLook] {
            letters.map { SignStillLetterLook(letter: String($0), probability: probability) }
        }
        // Each letter held for 3 looks counts once; a held letter counts only once however long it is held.
        #expect(SignStillLetterJoiner.join(looks("aaaaaabbb")).text == "ab")
        // The same letter twice needs something else in between.
        #expect(SignStillLetterJoiner.join(looks("aaa") + looks("x", probability: 0.1) + looks("aaa")).text == "aa")
        // Too short a hold, or unsure looks, are nothing.
        #expect(SignStillLetterJoiner.join(looks("aab")).text == "")
        #expect(SignStillLetterJoiner.join(looks("aaaa", probability: 0.3)) == .nothing)
    }
}
