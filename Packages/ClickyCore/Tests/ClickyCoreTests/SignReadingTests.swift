import Foundation
import Testing
@testable import ClickyCore

/// Sign to text, last step: what a stretch was read as, the signed line, the message Vello is sent and sending by itself.
struct SignReadingTests {
    // MARK: Languages and word names

    @Test func languagesHaveShortAndFullNames() {
        #expect(SignLanguage.allCases == [.asl, .isl])
        #expect(SignLanguage.asl.displayName == "ASL (American)")
        #expect(SignLanguage.isl.displayName == "ISL (Indian)")
        #expect(SignLanguage.asl.fullName == "American Sign Language")
        #expect(SignLanguage.isl.fullName == "Indian Sign Language")
        #expect(SignLanguage(rawValue: "isl") == .isl)
    }

    @Test func joinedLabelsReadAsWords() {
        let expectedTextByLabel = [
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
        for (label, expectedText) in expectedTextByLabel {
            #expect(SignWordNames.displayText(for: label) == expectedText, "\(label)")
        }
        #expect(SignWordNames.displayText(for: "good_morning") == "good morning")
        #expect(SignWordNames.displayText(for: "x-ray") == "x ray")
        #expect(SignWordNames.displayText(for: "hello") == "hello")
        #expect(SignWordNames.displayText(for: "") == "")
    }

    // MARK: Stretch facts

    /// A clip of `frameCount` frames where `rightWristPlaces` / `leftWristPlaces` give, per frame, the wrist's
    /// place from the centre (body sizes) when that hand is seen, nil when not.
    private static func clip(rightWristPlaces: [(Float, Float)?], leftWristPlaces: [(Float, Float)?]) -> SignFeatureClip {
        let frameCount = rightWristPlaces.count
        var values = [Float](repeating: 0, count: frameCount * SignFeatures.featureCount)
        for frameIndex in 0..<frameCount {
            let rowStart = frameIndex * SignFeatures.featureCount
            if let rightWristPlace = rightWristPlaces[frameIndex] {
                values[rowStart + SignFeatures.rightWristFeaturesStart] = rightWristPlace.0
                values[rowStart + SignFeatures.rightWristFeaturesStart + 1] = rightWristPlace.1
                values[rowStart + SignFeatures.rightHandSeenFeature] = 1
            }
            if frameIndex < leftWristPlaces.count, let leftWristPlace = leftWristPlaces[frameIndex] {
                values[rowStart + SignFeatures.leftWristFeaturesStart] = leftWristPlace.0
                values[rowStart + SignFeatures.leftWristFeaturesStart + 1] = leftWristPlace.1
                values[rowStart + SignFeatures.leftHandSeenFeature] = 1
            }
        }
        return SignFeatureClip(frameCount: frameCount, values: values, handSize: 0.05, bodySize: 0.2, handSizeIsDegenerate: false)
    }

    @Test func factsMeasureSharesAndTheBusierWristsTravel() {
        // Right hand in all 10 frames, its wrist moving 0.25 across and 0.5 up-down; left hand in 1 frame far away.
        var rightWristPlaces: [(Float, Float)?] = []
        var leftWristPlaces: [(Float, Float)?] = []
        for frameIndex in 0..<10 {
            rightWristPlaces.append((0.25 * Float(frameIndex) / 9, -0.5 * Float(frameIndex) / 9))
            let leftWristPlace: (Float, Float)? = frameIndex == 4 ? (3, 3) : nil
            leftWristPlaces.append(leftWristPlace)
        }
        let facts = SignStretchFacts(clip: Self.clip(rightWristPlaces: rightWristPlaces, leftWristPlaces: leftWristPlaces), seconds: 1.5)
        #expect(facts.seconds == 1.5)
        #expect(facts.shareOfFramesWithRightHand == 1)
        #expect(facts.shareOfFramesWithLeftHand == 0.1)
        #expect(abs(facts.busierHandWristTravelInBodySizes - 0.5) < 1e-6)
    }

    @Test func factsFollowTheLeftHandWhenItIsTheBusierOne() {
        // Left hand in 4 frames (across 0.1 to 0.4), right in 1; frames without the hand don't count toward travel.
        let leftWristPlaces: [(Float, Float)?] = [(0.1, 0), (0.2, 0), nil, (0.3, 0.05), (0.4, 0)]
        let rightWristPlaces: [(Float, Float)?] = [nil, nil, (2, 2), nil, nil]
        let facts = SignStretchFacts(clip: Self.clip(rightWristPlaces: rightWristPlaces, leftWristPlaces: leftWristPlaces), seconds: 1)
        #expect(facts.shareOfFramesWithLeftHand == 0.8)
        #expect(facts.shareOfFramesWithRightHand == 0.2)
        #expect(abs(facts.busierHandWristTravelInBodySizes - 0.3) < 1e-6)
    }

    @Test func factsOfAnEmptyClipAreZero() {
        let facts = SignStretchFacts(clip: Self.clip(rightWristPlaces: [], leftWristPlaces: []), seconds: 0)
        #expect(facts == SignStretchFacts(seconds: 0, shareOfFramesWithRightHand: 0, shareOfFramesWithLeftHand: 0, busierHandWristTravelInBodySizes: 0))
        let noHands = SignStretchFacts(clip: Self.clip(rightWristPlaces: [nil, nil], leftWristPlaces: [nil, nil]), seconds: 1)
        #expect(noHands.busierHandWristTravelInBodySizes == 0)
        #expect(!noHands.looksLikeFingerSpelling(settings: SignReadingSettings()))
    }

    /// One hand up the whole time, the other never, hardly moving, for a second: finger-spelling.
    private static let spellingFacts = SignStretchFacts(
        seconds: 1,
        shareOfFramesWithRightHand: 0.95,
        shareOfFramesWithLeftHand: 0,
        busierHandWristTravelInBodySizes: 0.2
    )

    @Test func fingerSpellingNeedsOneHandUpInOnePlaceForLongEnough() {
        let settings = SignReadingSettings()
        #expect(Self.spellingFacts.looksLikeFingerSpelling(settings: settings))

        var facts = Self.spellingFacts
        facts.shareOfFramesWithRightHand = 0.8
        #expect(facts.looksLikeFingerSpelling(settings: settings))
        facts.shareOfFramesWithRightHand = 0.79
        #expect(!facts.looksLikeFingerSpelling(settings: settings))

        facts = Self.spellingFacts
        facts.shareOfFramesWithLeftHand = 0.15
        #expect(facts.looksLikeFingerSpelling(settings: settings))
        facts.shareOfFramesWithLeftHand = 0.16
        #expect(!facts.looksLikeFingerSpelling(settings: settings))

        facts = Self.spellingFacts
        facts.busierHandWristTravelInBodySizes = 0.6
        #expect(facts.looksLikeFingerSpelling(settings: settings))
        facts.busierHandWristTravelInBodySizes = 0.61
        #expect(!facts.looksLikeFingerSpelling(settings: settings))

        facts = Self.spellingFacts
        facts.seconds = 0.6
        #expect(facts.looksLikeFingerSpelling(settings: settings))
        facts.seconds = 0.59
        #expect(!facts.looksLikeFingerSpelling(settings: settings))
    }

    @Test func fingerSpellingWorksWithEitherHandButNotBoth() {
        let settings = SignReadingSettings()
        let leftHanded = SignStretchFacts(seconds: 1, shareOfFramesWithRightHand: 0.1, shareOfFramesWithLeftHand: 0.9, busierHandWristTravelInBodySizes: 0.1)
        #expect(leftHanded.looksLikeFingerSpelling(settings: settings))
        let bothHands = SignStretchFacts(seconds: 1, shareOfFramesWithRightHand: 0.9, shareOfFramesWithLeftHand: 0.9, busierHandWristTravelInBodySizes: 0.1)
        #expect(!bothHands.looksLikeFingerSpelling(settings: settings))
    }

    // MARK: Tokens

    private static func guesses(_ labelsAndProbabilities: [(String, Float)]) -> [SignWordGuess] {
        labelsAndProbabilities.map { SignWordGuess(label: $0.0, probability: $0.1) }
    }

    private static let confidentSpelling = SignSpelledGuess(text: "bob", confidence: 0.7)

    @Test func fingerSpellingWinsWhenEverythingPointsToIt() {
        let token = SignStretchReading.token(
            wordGuesses: Self.guesses([("hello", 0.4)]),
            spelling: Self.confidentSpelling,
            facts: Self.spellingFacts
        )
        #expect(token == .spelled(text: "bob", confidence: 0.7))
        #expect(token?.text == "bob")
    }

    @Test func fingerSpellingNeedsTwoCharacters() {
        let oneLetter = SignStretchReading.token(
            wordGuesses: Self.guesses([("hello", 0.4)]),
            spelling: SignSpelledGuess(text: "b", confidence: 0.9),
            facts: Self.spellingFacts
        )
        #expect(oneLetter == .word(guesses: Self.guesses([("hello", 0.4)])))
        let twoLetters = SignStretchReading.token(
            wordGuesses: Self.guesses([("hello", 0.4)]),
            spelling: SignSpelledGuess(text: "bo", confidence: 0.9),
            facts: Self.spellingFacts
        )
        #expect(twoLetters == .spelled(text: "bo", confidence: 0.9))
    }

    @Test func fingerSpellingNeedsEnoughConfidence() {
        let atTheLeast = SignStretchReading.token(
            wordGuesses: Self.guesses([("hello", 0.4)]),
            spelling: SignSpelledGuess(text: "bob", confidence: 0.5),
            facts: Self.spellingFacts
        )
        #expect(atTheLeast == .spelled(text: "bob", confidence: 0.5))
        let underIt = SignStretchReading.token(
            wordGuesses: Self.guesses([("hello", 0.4)]),
            spelling: SignSpelledGuess(text: "bob", confidence: 0.49),
            facts: Self.spellingFacts
        )
        #expect(underIt?.text == "hello")
    }

    @Test func aConfidentWordBeatsFingerSpelling() {
        let wordAtTheLimit = SignStretchReading.token(
            wordGuesses: Self.guesses([("hello", 0.6)]),
            spelling: Self.confidentSpelling,
            facts: Self.spellingFacts
        )
        #expect(wordAtTheLimit?.text == "hello")
        let wordJustUnder = SignStretchReading.token(
            wordGuesses: Self.guesses([("hello", 0.59)]),
            spelling: Self.confidentSpelling,
            facts: Self.spellingFacts
        )
        #expect(wordJustUnder?.text == "bob")
    }

    @Test func aStretchThatDoesNotLookLikeSpellingIsReadAsAWord() {
        var signingFacts = Self.spellingFacts
        signingFacts.shareOfFramesWithLeftHand = 0.9
        let token = SignStretchReading.token(
            wordGuesses: Self.guesses([("hello", 0.3)]),
            spelling: Self.confidentSpelling,
            facts: signingFacts
        )
        #expect(token?.text == "hello")
        let withoutSpelling = SignStretchReading.token(wordGuesses: Self.guesses([("hello", 0.3)]), spelling: nil, facts: Self.spellingFacts)
        #expect(withoutSpelling?.text == "hello")
    }

    @Test func aWordNeedsEnoughProbabilityToBeRead() {
        let atTheLeast = SignStretchReading.token(wordGuesses: Self.guesses([("hello", 0.25)]), spelling: nil, facts: Self.spellingFacts)
        #expect(atTheLeast == .word(guesses: Self.guesses([("hello", 0.25)])))
        let underIt = SignStretchReading.token(wordGuesses: Self.guesses([("hello", 0.24)]), spelling: nil, facts: Self.spellingFacts)
        #expect(underIt == nil)
        let noGuesses = SignStretchReading.token(wordGuesses: [], spelling: SignSpelledGuess(text: "b", confidence: 0.9), facts: Self.spellingFacts)
        #expect(noGuesses == nil)
    }

    @Test func alternativesAreCappedAndMustBeLikelyEnough() {
        let capped = SignStretchReading.token(
            wordGuesses: Self.guesses([("hello", 0.5), ("thankyou", 0.2), ("help", 0.1), ("home", 0.09), ("house", 0.07)]),
            spelling: nil,
            facts: Self.spellingFacts
        )
        #expect(capped == .word(guesses: Self.guesses([("hello", 0.5), ("thankyou", 0.2), ("help", 0.1)])))
        #expect(capped?.alternativeTexts == ["thank you", "help"])

        let atTheLeast = SignStretchReading.token(
            wordGuesses: Self.guesses([("hello", 0.5), ("help", 0.08), ("home", 0.079)]),
            spelling: nil,
            facts: Self.spellingFacts
        )
        #expect(atTheLeast == .word(guesses: Self.guesses([("hello", 0.5), ("help", 0.08)])))

        var topOnlySettings = SignReadingSettings()
        topOnlySettings.alternativesKept = 1
        let topOnly = SignStretchReading.token(
            wordGuesses: Self.guesses([("hello", 0.5), ("help", 0.3)]),
            spelling: nil,
            facts: Self.spellingFacts,
            settings: topOnlySettings
        )
        #expect(topOnly == .word(guesses: Self.guesses([("hello", 0.5)])))
    }

    @Test func guessesInAnyOrderAreReadLikeliestFirst() {
        let token = SignStretchReading.token(
            wordGuesses: Self.guesses([("help", 0.1), ("icecream", 0.7), ("home", 0.2)]),
            spelling: nil,
            facts: Self.spellingFacts
        )
        #expect(token?.text == "ice cream")
        #expect(token?.alternativeTexts == ["home", "help"])
    }

    // MARK: The signed line

    @Test func theLineAddsRemovesAndClears() {
        var line = SignedLine()
        #expect(line.isEmpty)
        #expect(line.plainText == "")
        let removedFromAnEmptyLine = line.removeLast()
        #expect(removedFromAnEmptyLine == nil)

        line.add(.word(guesses: Self.guesses([("thankyou", 0.8)])))
        line.add(.spelled(text: "bob", confidence: 0.7))
        line.add(.word(guesses: Self.guesses([("tv", 0.5)])))
        #expect(!line.isEmpty)
        #expect(line.plainText == "thank you bob TV")

        let removedToken = line.removeLast()
        #expect(removedToken?.text == "TV")
        #expect(line.plainText == "thank you bob")
        #expect(line.tokens.count == 2)

        line.clear()
        #expect(line.isEmpty)
        #expect(line.tokens.isEmpty)
    }

    @Test func theMessageWithNoAlternativesIsTheWordsAndTheNote() {
        var line = SignedLine()
        line.add(.word(guesses: Self.guesses([("hello", 0.9)])))
        line.add(.word(guesses: Self.guesses([("thankyou", 0.8)])))
        let expectedMessage = "hello thank you\n\n(Signed to the camera in American Sign Language and read sign by sign, so the words follow signing order rather than English grammar and a sign may have been misread. Read it as the most sensible meaning.)"
        #expect(line.messageForBrain(language: .asl) == expectedMessage)
    }

    @Test func theMessageListsEachWordsAlternatives() {
        var line = SignedLine()
        line.add(.word(guesses: Self.guesses([("thankyou", 0.6), ("haveto", 0.2), ("icecream", 0.1)])))
        line.add(.spelled(text: "bob", confidence: 0.7))
        line.add(.word(guesses: Self.guesses([("tv", 0.7), ("weus", 0.1)])))
        line.add(.word(guesses: Self.guesses([("hello", 0.9)])))
        let expectedMessage = "thank you bob TV hello\n\n(Signed to the camera in Indian Sign Language and read sign by sign, so the words follow signing order rather than English grammar and a sign may have been misread. Word 1 may also be: have to, ice cream. Word 3 may also be: we us. Read it as the most sensible meaning.)"
        let message = line.messageForBrain(language: .isl)
        #expect(message == expectedMessage)
        #expect(!message.contains("\u{2014}"))
    }

    @Test func anEmptyLineHasNoMessage() {
        #expect(SignedLine().messageForBrain(language: .asl) == "")
    }

    // MARK: Sending by itself

    /// One moment for `SignAutoSend.observe`.
    private struct RestStep {
        let time: Double
        var isInStretch = false
        var lineIsEmpty = false
    }

    /// Feeds the steps in order and returns what `observe` said at each. (Mutating calls are kept out of
    /// `#expect` itself.)
    private static func sendDecisions(_ autoSend: inout SignAutoSend, _ steps: [RestStep]) -> [Bool] {
        steps.map { step in
            autoSend.observe(at: step.time, isInStretch: step.isInStretch, lineIsEmpty: step.lineIsEmpty)
        }
    }

    @Test func autoSendFiresOnceAfterTheRest() {
        var autoSend = SignAutoSend(restSecondsBeforeSending: 2)
        let beforeWords = Self.sendDecisions(&autoSend, [RestStep(time: 0, lineIsEmpty: true)])
        #expect(beforeWords == [false])
        #expect(autoSend.progress(at: 0.5) == 0)

        // Words waiting and the hands at rest from 1 s on.
        let waitStarts = Self.sendDecisions(&autoSend, [RestStep(time: 1)])
        #expect(waitStarts == [false])
        #expect(autoSend.progress(at: 2) == 0.5)

        // Sends at 3 s, and only once however long the rest goes on.
        let restGoesOn = Self.sendDecisions(&autoSend, [RestStep(time: 2.9), RestStep(time: 3), RestStep(time: 3.1), RestStep(time: 30)])
        #expect(restGoesOn == [false, true, false, false])
        #expect(autoSend.progress(at: 30) == 0)

        // A new stretch starts the wait again.
        let afterANewStretch = Self.sendDecisions(&autoSend, [
            RestStep(time: 31, isInStretch: true),
            RestStep(time: 32),
            RestStep(time: 33.9),
            RestStep(time: 34)
        ])
        #expect(afterANewStretch == [false, false, false, true])
    }

    @Test func aStretchOrAnEmptiedLineDuringTheWaitStartsItOver() {
        var autoSend = SignAutoSend(restSecondsBeforeSending: 2)
        let interruptedByAStretch = Self.sendDecisions(&autoSend, [RestStep(time: 0), RestStep(time: 1.5, isInStretch: true)])
        #expect(interruptedByAStretch == [false, false])
        #expect(autoSend.progress(at: 1.5) == 0)

        let interruptedByAnEmptyLine = Self.sendDecisions(&autoSend, [
            RestStep(time: 2),
            RestStep(time: 3.9),
            RestStep(time: 3.95, lineIsEmpty: true)
        ])
        #expect(interruptedByAnEmptyLine == [false, false, false])

        let waitedInFull = Self.sendDecisions(&autoSend, [RestStep(time: 4), RestStep(time: 5.9), RestStep(time: 6)])
        #expect(waitedInFull == [false, false, true])
    }

    @Test func autoSendProgressStaysBetweenZeroAndOne() {
        var autoSend = SignAutoSend(restSecondsBeforeSending: 4)
        _ = autoSend.observe(at: 10, isInStretch: false, lineIsEmpty: false)
        #expect(autoSend.progress(at: 9) == 0)
        #expect(autoSend.progress(at: 11) == 0.25)
        #expect(autoSend.progress(at: 100) == 1)
    }

    @Test func autoSendOfZeroOrLessNeverSends() {
        for restSeconds in [0.0, -1.0] {
            var autoSend = SignAutoSend(restSecondsBeforeSending: restSeconds)
            var sentAtAnyPoint = false
            for tick in 0..<100 {
                if autoSend.observe(at: Double(tick) * 0.5, isInStretch: false, lineIsEmpty: false) {
                    sentAtAnyPoint = true
                }
            }
            #expect(!sentAtAnyPoint)
            #expect(autoSend.progress(at: 1000) == 0)
        }
    }
}
