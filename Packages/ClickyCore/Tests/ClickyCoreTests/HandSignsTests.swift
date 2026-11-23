import Foundation
import Testing
@testable import ClickyCore

/// Hand signs: shapes read from made-up joints (a palm one unit long, y up), the hold tracker on a
/// made-up clock, what each sign does in each mode, and the saved phrases.
struct HandSignsTests {
    // MARK: Made-up hands

    private static let knuckles: [String: HandPoint] = [
        "index": HandPoint(x: -0.25, y: 0.95), "middle": HandPoint(x: 0, y: 1),
        "ring": HandPoint(x: 0.22, y: 0.95), "little": HandPoint(x: 0.42, y: 0.88)
    ]

    private enum Thumb { case outToTheSide, tucked, up, down, flatSideways }

    private static func thumbChain(_ thumb: Thumb) -> [HandPoint] {
        switch thumb {
        case .outToTheSide: return [HandPoint(x: -0.3, y: 0.25), HandPoint(x: -0.55, y: 0.5), HandPoint(x: -0.75, y: 0.7), HandPoint(x: -0.95, y: 0.9)]
        case .tucked: return [HandPoint(x: -0.3, y: 0.3), HandPoint(x: -0.4, y: 0.6), HandPoint(x: -0.25, y: 0.85), HandPoint(x: 0, y: 0.9)]
        case .up: return [HandPoint(x: -0.3, y: 0.3), HandPoint(x: -0.38, y: 0.65), HandPoint(x: -0.42, y: 1.05), HandPoint(x: -0.47, y: 1.5)]
        case .down: return [HandPoint(x: -0.3, y: 0.3), HandPoint(x: -0.35, y: 0), HandPoint(x: -0.38, y: -0.35), HandPoint(x: -0.4, y: -0.7)]
        case .flatSideways: return [HandPoint(x: -0.3, y: 0.3), HandPoint(x: -0.6, y: 0.35), HandPoint(x: -0.9, y: 0.4), HandPoint(x: -1.2, y: 0.45)]
        }
    }

    /// Fingers listed in `extendedFingers` stand straight up from their knuckle; the rest fold back into the palm.
    private static func hand(extendedFingers: Set<String>, thumb: Thumb) -> HandPose {
        var joints: [HandJoint: HandPoint] = [.wrist: HandPoint(x: 0, y: 0)]
        let fingerJoints: [String: [HandJoint]] = [
            "index": [.indexMCP, .indexPIP, .indexDIP, .indexTip], "middle": [.middleMCP, .middlePIP, .middleDIP, .middleTip],
            "ring": [.ringMCP, .ringPIP, .ringDIP, .ringTip], "little": [.littleMCP, .littlePIP, .littleDIP, .littleTip]
        ]
        for (fingerName, jointNames) in fingerJoints {
            let knuckle = knuckles[fingerName]!
            let offsets: [Double] = extendedFingers.contains(fingerName) ? [0, 0.45, 0.75, 1.0] : [0, 0.35, 0.05, -0.15]
            for (jointName, offset) in zip(jointNames, offsets) { joints[jointName] = HandPoint(x: knuckle.x, y: knuckle.y + offset) }
        }
        for (jointName, point) in zip([HandJoint.thumbCMC, .thumbMP, .thumbIP, .thumbTip], thumbChain(thumb)) { joints[jointName] = point }
        return HandPose(joints: joints)
    }

    private static let allFour: Set<String> = ["index", "middle", "ring", "little"]

    // MARK: Shapes

    @Test func readsEachSign() {
        #expect(HandSignClassifier.classify(Self.hand(extendedFingers: Self.allFour, thumb: .outToTheSide)) == .openPalm)
        #expect(HandSignClassifier.classify(Self.hand(extendedFingers: Self.allFour, thumb: .tucked)) == .openPalm)
        #expect(HandSignClassifier.classify(Self.hand(extendedFingers: [], thumb: .tucked)) == .fist)
        #expect(HandSignClassifier.classify(Self.hand(extendedFingers: [], thumb: .up)) == .thumbsUp)
        #expect(HandSignClassifier.classify(Self.hand(extendedFingers: [], thumb: .down)) == .thumbsDown)
        #expect(HandSignClassifier.classify(Self.hand(extendedFingers: ["index"], thumb: .tucked)) == .pointingUp)
        #expect(HandSignClassifier.classify(Self.hand(extendedFingers: ["index", "middle"], thumb: .tucked)) == .peace)
        #expect(HandSignClassifier.classify(Self.hand(extendedFingers: ["index", "little"], thumb: .outToTheSide)) == .loveYou)
        #expect(HandSignClassifier.classify(Self.hand(extendedFingers: ["little"], thumb: .outToTheSide)) == .callMe)
    }

    @Test func readsOkayWithTheIndexBentToTheThumb() {
        var pose = Self.hand(extendedFingers: Self.allFour, thumb: .outToTheSide)
        pose.joints[.indexPIP] = HandPoint(x: -0.4, y: 1.3)
        pose.joints[.indexDIP] = HandPoint(x: -0.55, y: 1.25)
        pose.joints[.indexTip] = HandPoint(x: -0.6, y: 1.1)
        pose.joints[.thumbMP] = HandPoint(x: -0.5, y: 0.55)
        pose.joints[.thumbIP] = HandPoint(x: -0.6, y: 0.8)
        pose.joints[.thumbTip] = HandPoint(x: -0.62, y: 1.05)
        #expect(HandSignClassifier.classify(pose) == .okay)
    }

    @Test func leavesUnknownShapesUnread() {
        // A fist with the thumb flat out sideways is neither up nor down.
        #expect(HandSignClassifier.classify(Self.hand(extendedFingers: [], thumb: .flatSideways)) == nil)
        // Index and ring up: no sign.
        #expect(HandSignClassifier.classify(Self.hand(extendedFingers: ["index", "ring"], thumb: .tucked)) == nil)
        // No wrist, no reading.
        var pose = Self.hand(extendedFingers: Self.allFour, thumb: .outToTheSide)
        pose.joints[.wrist] = nil
        #expect(HandSignClassifier.classify(pose) == nil)
    }

    @Test func sizeAndPlaceInThePictureDontMatter() {
        let pose = Self.hand(extendedFingers: ["index", "middle"], thumb: .tucked)
        var movedAndScaled = HandPose(joints: [:])
        for (joint, point) in pose.joints { movedAndScaled.joints[joint] = HandPoint(x: 300 + point.x * 140, y: 200 + point.y * 140) }
        #expect(HandSignClassifier.classify(movedAndScaled) == .peace)
    }

    // MARK: Holding

    @Test func firesOnceAfterTheHold() {
        var tracker = HandSignHoldTracker()
        var fired: [HandSign] = []
        var time = 0.0
        while time <= 3 {
            if let sign = tracker.observe(.thumbsUp, at: time) { fired.append(sign) }
            time += 1.0 / 15
        }
        #expect(fired == [.thumbsUp])
    }

    @Test func doesNotFireBeforeTheHold() {
        var tracker = HandSignHoldTracker()
        #expect(tracker.observe(.openPalm, at: 0) == nil)
        #expect(tracker.observe(.openPalm, at: 0.5) == nil)
        #expect(tracker.observe(.openPalm, at: 0.9) == nil)
        #expect(tracker.holdProgress(at: 0.5) == 0.5)
        #expect(tracker.observe(.openPalm, at: 1.0) == .openPalm)
    }

    @Test func aShortGapDoesNotBreakTheHold() {
        var tracker = HandSignHoldTracker()
        #expect(tracker.observe(.peace, at: 0) == nil)
        #expect(tracker.observe(nil, at: 0.2) == nil)
        #expect(tracker.observe(.peace, at: 0.4) == nil)
        #expect(tracker.observe(.peace, at: 0.6) == .peace)
    }

    @Test func aLongGapStartsTheHoldAgain() {
        var tracker = HandSignHoldTracker()
        #expect(tracker.observe(.peace, at: 0) == nil)
        #expect(tracker.observe(nil, at: 0.5) == nil)
        #expect(tracker.observe(.peace, at: 0.6) == nil)
        #expect(tracker.observe(.peace, at: 1.0) == nil)
        #expect(tracker.observe(.peace, at: 1.25) == .peace)
    }

    @Test func firesAgainOnlyAfterTheHandLetsGo() {
        var tracker = HandSignHoldTracker()
        _ = tracker.observe(.thumbsUp, at: 0)
        #expect(tracker.observe(.thumbsUp, at: 0.6) == .thumbsUp)
        // Hand down for long enough, then the same sign again.
        #expect(tracker.observe(nil, at: 1.2) == nil)
        #expect(tracker.observe(.thumbsUp, at: 1.3) == nil)
        #expect(tracker.observe(.thumbsUp, at: 1.95) == .thumbsUp)
    }

    @Test func aNewSignRightAfterOneWaitsForTheCooldown() {
        var tracker = HandSignHoldTracker()
        _ = tracker.observe(.okay, at: 0)
        #expect(tracker.observe(.okay, at: 0.6) == .okay)
        _ = tracker.observe(.peace, at: 0.61)
        #expect(tracker.observe(.peace, at: 1.0) == nil)
        // Peace has been held long enough at 1.25, but the last sign was only 0.65 s ago.
        #expect(tracker.observe(.peace, at: 1.25) == nil)
        #expect(tracker.observe(.peace, at: 1.45) == .peace)
    }

    // MARK: Actions

    @Test func controlModeDrivesPointerAssistant() {
        #expect(HandSignActions.action(for: .openPalm, mode: .control, phrases: [:]) == .startListening)
        #expect(HandSignActions.action(for: .fist, mode: .control, phrases: [:]) == .stopEverything)
        #expect(HandSignActions.action(for: .thumbsUp, mode: .control, phrases: [:]) == .answer(yes: true))
        #expect(HandSignActions.action(for: .thumbsDown, mode: .control, phrases: [:]) == .answer(yes: false))
        #expect(HandSignActions.action(for: .pointingUp, mode: .control, phrases: [:]) == .ask(HandSignActions.whatIsOnMyScreen))
        #expect(HandSignActions.action(for: .loveYou, mode: .control, phrases: [:]) == .speak("I love you."))
    }

    @Test func speakForMeSaysEveryPhrase() {
        for sign in HandSign.allCases {
            #expect(HandSignActions.action(for: sign, mode: .speakForMe, phrases: [:]) == .speak(sign.defaultPhrase))
        }
        #expect(HandSignActions.action(for: .peace, mode: .speakForMe, phrases: [.peace: "  Thanks a lot  "]) == .speak("Thanks a lot"))
        #expect(HandSignActions.action(for: .peace, mode: .speakForMe, phrases: [.peace: ""]) == .nothing)
    }

    @Test func phrasesRoundTrip() {
        let phrases: [HandSign: String] = [.peace: "Thanks a lot", .callMe: ""]
        let json = HandSignPhrases.encode(phrases)
        #expect(json == #"{"callMe":"","peace":"Thanks a lot"}"#)
        #expect(HandSignPhrases.decode(json) == phrases)
        #expect(HandSignPhrases.decode(#"{"wave":"hi","okay":"Fine"}"#) == [.okay: "Fine"])
        #expect(HandSignPhrases.decode(nil).isEmpty)
        #expect(HandSignPhrases.decode("not json").isEmpty)
    }
}
