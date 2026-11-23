import Foundation
import Testing
@testable import ClickyCore

/// Finger-spelling: shapes measured from made-up joints (a palm one unit long, y up, a right hand with its palm
/// to the camera), the built-in ASL letters, taught signs with one and two hands, frames to events, and events to text.
struct FingerspellingTests {
    // MARK: Made-up hands

    private static let knuckles: [String: HandPoint] = [
        "index": HandPoint(x: -0.25, y: 0.95), "middle": HandPoint(x: 0, y: 1),
        "ring": HandPoint(x: 0.22, y: 0.95), "little": HandPoint(x: 0.42, y: 0.88)
    ]
    private static let fingerJoints: [String: [HandJoint]] = [
        "index": [.indexMCP, .indexPIP, .indexDIP, .indexTip], "middle": [.middleMCP, .middlePIP, .middleDIP, .middleTip],
        "ring": [.ringMCP, .ringPIP, .ringDIP, .ringTip], "little": [.littleMCP, .littlePIP, .littleDIP, .littleTip]
    ]

    private enum Thumb { case outToTheSide, tucked, down }

    private static func thumbChain(_ thumb: Thumb) -> [HandPoint] {
        switch thumb {
        case .outToTheSide: return [HandPoint(x: -0.3, y: 0.25), HandPoint(x: -0.55, y: 0.5), HandPoint(x: -0.75, y: 0.7), HandPoint(x: -0.95, y: 0.9)]
        case .tucked: return [HandPoint(x: -0.3, y: 0.3), HandPoint(x: -0.4, y: 0.6), HandPoint(x: -0.25, y: 0.85), HandPoint(x: 0, y: 0.9)]
        case .down: return [HandPoint(x: -0.3, y: 0.3), HandPoint(x: -0.35, y: 0), HandPoint(x: -0.38, y: -0.35), HandPoint(x: -0.4, y: -0.7)]
        }
    }

    /// Fingers in `extendedFingers` stand up from their knuckle, leaning apart by `spread`; the rest fold into the palm.
    private static func hand(_ extendedFingers: Set<String>, thumb: Thumb, spread: Double = 0) -> HandPose {
        var joints: [HandJoint: HandPoint] = [.wrist: HandPoint(x: 0, y: 0)]
        let lean: [String: Double] = ["index": -spread, "middle": 0, "ring": spread * 0.7, "little": spread * 1.2]
        for (fingerName, jointNames) in fingerJoints {
            let knuckle = knuckles[fingerName]!
            let isExtended = extendedFingers.contains(fingerName)
            let offsets: [Double] = isExtended ? [0, 0.45, 0.75, 1.0] : [0, 0.35, 0.05, -0.15]
            let fingerLean = isExtended ? lean[fingerName]! : 0
            for (jointName, offset) in zip(jointNames, offsets) {
                joints[jointName] = HandPoint(x: knuckle.x + fingerLean * offset, y: knuckle.y + offset)
            }
        }
        for (jointName, point) in zip([HandJoint.thumbCMC, .thumbMP, .thumbIP, .thumbTip], thumbChain(thumb)) { joints[jointName] = point }
        return HandPose(joints: joints)
    }

    private static func transformed(_ pose: HandPose, scale: Double = 1, shiftX: Double = 0, shiftY: Double = 0, mirrored: Bool = false, turnedBy angle: Double = 0) -> HandPose {
        var joints: [HandJoint: HandPoint] = [:]
        for (joint, point) in pose.joints {
            let x = mirrored ? -point.x : point.x
            let turnedX = x * cos(angle) - point.y * sin(angle)
            let turnedY = x * sin(angle) + point.y * cos(angle)
            joints[joint] = HandPoint(x: turnedX * scale + shiftX, y: turnedY * scale + shiftY)
        }
        return HandPose(joints: joints)
    }

    private static let allFour: Set<String> = ["index", "middle", "ring", "little"]

    // MARK: Measuring

    @Test func measuresSixteenNumbersTheSameForAnyHandSizeOrSide() throws {
        let pose = Self.hand(["index", "little"], thumb: .outToTheSide)
        let shape = try #require(HandShapeMeasure.measure(pose))
        #expect(shape.count == 16)
        #expect(HandShapeMeasure.measureNames.count == 16)
        #expect(HandShapeMeasure.usualSpread.count == 16)
        // A bigger hand further across the picture, and a left hand (mirrored), measure the same.
        let bigger = try #require(HandShapeMeasure.measure(Self.transformed(pose, scale: 240, shiftX: 300, shiftY: 120)))
        let leftHand = try #require(HandShapeMeasure.measure(Self.transformed(pose, mirrored: true)))
        for index in shape.indices {
            #expect(abs(shape[index] - bigger[index]) < 0.000_1)
            #expect(abs(shape[index] - leftHand[index]) < 0.000_1)
        }
    }

    @Test func measuresWhichWayTheHandPoints() throws {
        let upright = try #require(HandShapeMeasure.measure(Self.hand(["index"], thumb: .tucked)))
        #expect(abs(upright[10]) < 0.000_1)
        #expect(abs(upright[11] - 1) < 0.000_1)
        // Turned a quarter toward the thumb side (the hand lies sideways, like G or H): the shape stays, the tilt changes.
        let sideways = try #require(HandShapeMeasure.measure(Self.transformed(Self.hand(["index"], thumb: .tucked), turnedBy: .pi / 2)))
        #expect(abs(sideways[10] + 1) < 0.000_1)
        #expect(abs(sideways[11]) < 0.000_1)
        for index in 0..<10 { #expect(abs(sideways[index] - upright[index]) < 0.000_1) }
    }

    @Test func fillsInAFewHiddenJointsButNotTheFrameOfTheHand() throws {
        let wholeHand = Self.hand(Self.allFour, thumb: .tucked)
        let wholeShape = try #require(HandShapeMeasure.measure(wholeHand))
        // A thumb tip hidden under the fingers (M, N) is placed on from the joints before it, so the hand still reads.
        var hiddenThumbTip = wholeHand
        hiddenThumbTip.joints[.thumbTip] = nil
        #expect(HandShapeMeasure.measure(hiddenThumbTip)?.count == 16)
        // A middle joint between two seen ones is put halfway, close to where it was.
        var hiddenJoint = wholeHand
        hiddenJoint.joints[.indexDIP] = nil
        let filledShape = try #require(HandShapeMeasure.measure(hiddenJoint))
        #expect(abs(filledShape[12] - wholeShape[12]) < 0.05)
        // No wrist or knuckle: no frame to measure against.
        var noWrist = wholeHand
        noWrist.joints[.wrist] = nil
        #expect(HandShapeMeasure.measure(noWrist) == nil)
        var noLittleKnuckle = wholeHand
        noLittleKnuckle.joints[.littleMCP] = nil
        #expect(HandShapeMeasure.measure(noLittleKnuckle) == nil)
        // Too much hidden to guess.
        var mostlyHidden = wholeHand
        for joint in [HandJoint.thumbTip, .indexTip, .middleTip, .ringTip] { mostlyHidden.joints[joint] = nil }
        #expect(HandShapeMeasure.measure(mostlyHidden) == nil)
    }

    // MARK: Built-in ASL letters

    @Test func everyBuiltInShapeHasSixteenNumbersAndNoLetterIsTwice() {
        #expect(ASLFingerspelling.letterShapes.count == 24)
        #expect(Set(ASLFingerspelling.letterShapes.map { $0.letter }).count == 24)
        #expect(!ASLFingerspelling.letterShapes.contains { $0.letter == "j" || $0.letter == "z" })
        for (_, shape) in ASLFingerspelling.letterShapes { #expect(shape.count == 16) }
        #expect(ASLFingerspelling.sendShape.count == 16)
        // Each letter's own shape reads as itself.
        for (letter, shape) in ASLFingerspelling.letterShapes { #expect(ASLFingerspelling.read(shape: shape)?.label == letter) }
    }

    @Test func readsClearLettersFromMadeUpHands() {
        #expect(ASLFingerspelling.read(Self.hand(Self.allFour, thumb: .tucked))?.label == "b")
        #expect(ASLFingerspelling.read(Self.hand(["little"], thumb: .tucked))?.label == "i")
        #expect(ASLFingerspelling.read(Self.hand(["little"], thumb: .outToTheSide))?.label == "y")
        #expect(ASLFingerspelling.read(Self.hand(["index", "middle", "ring"], thumb: .tucked, spread: 0.25))?.label == "w")
        // A left hand, bigger and elsewhere in the picture, spells the same.
        #expect(ASLFingerspelling.read(Self.transformed(Self.hand(["little"], thumb: .tucked), scale: 200, shiftX: 50, mirrored: true))?.label == "i")
    }

    @Test func theSpreadOpenHandSends() {
        #expect(ASLFingerspelling.read(Self.hand(Self.allFour, thumb: .outToTheSide, spread: 0.3))?.label == FingerspellingReading.sendLabel)
    }

    @Test func leavesAShapeFarFromEveryLetterUnread() {
        var farShape = ASLFingerspelling.sendShape
        farShape[0] = 6
        farShape[5] = -4
        #expect(ASLFingerspelling.read(shape: farShape) == nil)
    }

    // MARK: Reading a frame

    @Test func thumbsDownDeletesAndISLReadsOnlyWhatWasTaught() {
        let thumbsDown = Self.hand([], thumb: .down)
        #expect(FingerspellingReader.read(hands: [thumbsDown], alphabet: .asl, taughtSigns: TaughtSignBook())?.label == FingerspellingReading.deleteLabel)
        let letterI = Self.hand(["little"], thumb: .tucked)
        #expect(FingerspellingReader.read(hands: [letterI], alphabet: .asl, taughtSigns: TaughtSignBook())?.label == "i")
        #expect(FingerspellingReader.read(hands: [letterI], alphabet: .isl, taughtSigns: TaughtSignBook()) == nil)
        #expect(FingerspellingReader.read(hands: [], alphabet: .asl, taughtSigns: TaughtSignBook()) == nil)
    }

    // MARK: Taught signs

    @Test func readsATaughtOneHandSignAndPrefersItWhenNearer() {
        var book = TaughtSignBook()
        let shape = Self.hand(["index", "little"], thumb: .tucked)
        let addedRock = book.addExample(label: "  Rock ", hands: [shape])
        #expect(addedRock)
        #expect(book.signs == [TaughtSign(label: "rock", handCount: 1, examples: [HandShapeMeasure.measure(shape)!])])
        let reading = FingerspellingReader.read(hands: [Self.transformed(shape, scale: 3, mirrored: true)], alphabet: .asl, taughtSigns: book)
        #expect(reading?.label == "rock")
        #expect(reading?.isTaught == true)
        // Taught under a letter's own name, the owner's example wins over the built-in one.
        var ownLetter = TaughtSignBook()
        ownLetter.addExample(label: "e", hands: [Self.hand(["little"], thumb: .tucked)])
        #expect(FingerspellingReader.read(hands: [Self.hand(["little"], thumb: .tucked)], alphabet: .asl, taughtSigns: ownLetter)?.label == "e")
    }

    @Test func readsATaughtTwoHandSignAlsoInAMirror() {
        let leftHand = Self.transformed(Self.hand(["index"], thumb: .outToTheSide), mirrored: true)
        let rightHand = Self.transformed(Self.hand(Self.allFour, thumb: .tucked), shiftX: 1.6)
        var book = TaughtSignBook()
        let addedA = book.addExample(label: "A", hands: [leftHand, rightHand])
        #expect(addedA)
        #expect(book.signs.first?.handCount == 2)
        #expect(book.signs.first?.examples.first?.count == 35)
        #expect(book.read(hands: [rightHand, leftHand])?.label == "a")
        // The same two hands in a mirrored picture.
        let mirroredLeft = Self.transformed(leftHand, mirrored: true)
        let mirroredRight = Self.transformed(rightHand, mirrored: true)
        #expect(book.read(hands: [mirroredLeft, mirroredRight])?.label == "a")
        // One hand alone never matches a two-hand sign.
        #expect(book.read(hands: [leftHand]) == nil)
    }

    @Test func keepsTheNewestExamplesAndForgets() {
        var book = TaughtSignBook()
        let pose = Self.hand(["index"], thumb: .tucked)
        for _ in 0..<(TaughtSignBook.mostExamplesPerSign + 5) { book.addExample(label: "d", hands: [pose]) }
        #expect(book.signs.first?.examples.count == TaughtSignBook.mostExamplesPerSign)
        let addedEmptyLabel = book.addExample(label: "   ", hands: [pose])
        let addedNoHands = book.addExample(label: "x", hands: [])
        #expect(!addedEmptyLabel)
        #expect(!addedNoHands)
        book.forget(label: "D")
        #expect(book.signs.isEmpty)
    }

    @Test func taughtSignsSurviveSaving() {
        var book = TaughtSignBook()
        book.addExample(label: "thank you", hands: [Self.hand(Self.allFour, thumb: .tucked)])
        #expect(TaughtSignBook.decode(book.encode()) == book)
        #expect(TaughtSignBook.decode("not json") == TaughtSignBook())
        #expect(TaughtSignBook.decode(nil) == TaughtSignBook())
    }

    // MARK: Frames to events

    @Test func aHeldLetterCountsOnceAndTwiceOnlyAfterLettingGo() {
        var session = FingerspellingSession()
        #expect(session.observe(label: "h", handIsVisible: true, at: 0) == nil)
        #expect(session.observe(label: "h", handIsVisible: true, at: 0.3) == nil)
        #expect(session.holdProgress(at: 0.3) > 0.5)
        #expect(session.observe(label: "h", handIsVisible: true, at: 0.55) == .letter("h"))
        #expect(session.observe(label: "h", handIsVisible: true, at: 1.5) == nil)
        // A bounce (a frame or two of no shape) lets go, so a double letter counts.
        #expect(session.observe(label: nil, handIsVisible: true, at: 1.6) == nil)
        #expect(session.observe(label: nil, handIsVisible: true, at: 1.85) == nil)
        #expect(session.observe(label: "h", handIsVisible: true, at: 1.9) == nil)
        #expect(session.observe(label: "h", handIsVisible: true, at: 2.45) == .letter("h"))
    }

    @Test func passingThroughALetterDoesNotCountIt() {
        var session = FingerspellingSession()
        #expect(session.observe(label: "a", handIsVisible: true, at: 0) == nil)
        #expect(session.observe(label: "s", handIsVisible: true, at: 0.2) == nil)
        #expect(session.observe(label: "e", handIsVisible: true, at: 0.4) == nil)
        #expect(session.observe(label: "e", handIsVisible: true, at: 0.95) == .letter("e"))
    }

    @Test func theHandLeavingEndsTheWordOnce() {
        var session = FingerspellingSession()
        _ = session.observe(label: "o", handIsVisible: true, at: 0)
        #expect(session.observe(label: "o", handIsVisible: true, at: 0.5) == .letter("o"))
        #expect(session.observe(label: nil, handIsVisible: false, at: 0.9) == nil)
        #expect(session.observe(label: nil, handIsVisible: false, at: 1.6) == .wordBreak)
        #expect(session.observe(label: nil, handIsVisible: false, at: 2.5) == nil)
        // No letters yet: the hand leaving is nothing.
        var emptySession = FingerspellingSession()
        #expect(emptySession.observe(label: nil, handIsVisible: false, at: 0) == nil)
        #expect(emptySession.observe(label: nil, handIsVisible: false, at: 3) == nil)
    }

    @Test func sendAndDeleteAreHeldLonger() {
        var session = FingerspellingSession()
        let send = FingerspellingReading.sendLabel
        #expect(session.observe(label: send, handIsVisible: true, at: 0) == nil)
        #expect(session.observe(label: send, handIsVisible: true, at: 0.6) == nil)
        #expect(session.observe(label: send, handIsVisible: true, at: 1.0) == .send)
        let delete = FingerspellingReading.deleteLabel
        #expect(session.observe(label: delete, handIsVisible: true, at: 2) == nil)
        #expect(session.observe(label: delete, handIsVisible: true, at: 2.5) == nil)
        #expect(session.observe(label: delete, handIsVisible: true, at: 2.85) == .deleteLast)
    }

    // MARK: Events to text

    @Test func spelledTextJoinsLettersAndWords() {
        var spelled = SpelledText()
        for event: FingerspellingEvent in [.letter("h"), .letter("i"), .wordBreak, .wordBreak, .letter("t"), .letter("o"), .letter("m"), .deleteLast, .letter("p")] {
            spelled.apply(event)
        }
        #expect(spelled.text == "hi top")
        spelled.add("thank you")
        #expect(spelled.text == "hi top thank you ")
        #expect(spelled.textToSend == "hi top thank you")
        spelled.deleteLast()
        #expect(spelled.text == "hi top thank yo")
        spelled.clear()
        #expect(spelled.textToSend.isEmpty)
        spelled.deleteLast()
        #expect(spelled.text.isEmpty)
    }

    @Test func spellModeLeavesTheOtherSignsAlone() {
        for sign in HandSign.allCases { #expect(HandSignActions.action(for: sign, mode: .spell, phrases: [:]) == .nothing) }
        #expect(HandSignMode.spell.shortName == "Spell")
    }

    @Test func velloIsToldTheWordsWereSpelled() {
        let message = SpelledTextMessage.forVello("helo wrld")
        #expect(message.hasPrefix("helo wrld"))
        #expect(message.contains("Finger-spelled"))
    }
}
