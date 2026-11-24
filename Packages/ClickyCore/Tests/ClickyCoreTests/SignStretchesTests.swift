import Foundation
import Testing
@testable import ClickyCore

/// Sign to text, live: where one sign starts and ends in the camera's stream (`SignStretchFinder`).
struct SignStretchesTests {
    // MARK: Made-up frames

    /// 32 frames a second, so every frame time is exact in binary and no test sits on a rounding edge.
    private static let frameInterval = 1.0 / 32.0
    private static let raisedWristY: Float = 0.5
    /// Below the rest line: shoulders at y 0.45 and 0.2 apart give a line at 0.45 + 1.5 × 0.2 = 0.75.
    private static let restingWristY: Float = 0.9

    private static func time(ofFrame frameNumber: Int) -> Double {
        Double(frameNumber) * frameInterval
    }

    /// A frame whose nose x carries its number (number / 1000), with the shoulders (unless left out) and, when
    /// `wristY` is given, a right hand with every joint seen and its wrist at that height. The fingertips bob 0.04 up
    /// and down from frame to frame (a signing hand moves; the finder ignores a hand lying still), unless `stillHand`.
    private static func frame(number frameNumber: Int, wristY: Float?, shoulders: Bool = true, stillHand: Bool = false) -> SignLandmarkFrame {
        var frame = SignLandmarkFrame()
        frame[SignBodyPoint.nose] = SignLandmarkPoint(x: Float(frameNumber) / 1000, y: 0.3, confidence: 0.9)
        if shoulders {
            frame[SignBodyPoint.leftShoulder] = SignLandmarkPoint(x: 0.6, y: 0.45, confidence: 0.9)
            frame[SignBodyPoint.rightShoulder] = SignLandmarkPoint(x: 0.4, y: 0.45, confidence: 0.9)
        }
        if let wristY {
            let fingertips: Set<HandJoint> = [.thumbTip, .indexTip, .middleTip, .ringTip, .littleTip]
            let fingertipBob: Float = (stillHand || frameNumber % 2 == 0) ? 0 : 0.04
            for (jointNumber, joint) in HandJoint.allCases.enumerated() {
                let offset = Float(jointNumber) * 0.002
                let bob = fingertips.contains(joint) ? fingertipBob : 0
                frame.setHandJoint(side: .right, joint: joint, point: SignLandmarkPoint(x: 0.45 + offset, y: wristY - offset - bob, confidence: 0.9))
            }
        }
        return frame
    }

    private static func frameNumber(of frame: SignLandmarkFrame) -> Int {
        Int((frame[SignBodyPoint.nose].x * 1000).rounded())
    }

    private struct ObservedEvent {
        let frameNumber: Int
        let event: SignStretchEvent
    }

    /// Feeds one frame per wrist height (nil: no hand), numbered on from `firstFrameNumber`, and returns the events.
    private static func feed(
        _ wristHeights: [Float?],
        into finder: inout SignStretchFinder,
        firstFrameNumber: Int = 0,
        shoulders: Bool = true
    ) -> [ObservedEvent] {
        var observedEvents: [ObservedEvent] = []
        for (offset, wristY) in wristHeights.enumerated() {
            let frameNumber = firstFrameNumber + offset
            let nextFrame = Self.frame(number: frameNumber, wristY: wristY, shoulders: shoulders)
            if let event = finder.observe(nextFrame, at: Self.time(ofFrame: frameNumber)) {
                observedEvents.append(ObservedEvent(frameNumber: frameNumber, event: event))
            }
        }
        return observedEvents
    }

    private static func repeated(_ wristY: Float?, _ frameCount: Int) -> [Float?] {
        [Float?](repeating: wristY, count: frameCount)
    }

    private static func endedStretch(_ observedEvent: ObservedEvent) -> SignStretch? {
        if case .ended(let stretch) = observedEvent.event { return stretch }
        return nil
    }

    // MARK: Tests

    @Test func noHandsEverGivesNoEvents() {
        var finder = SignStretchFinder()
        let observedEvents = Self.feed(Self.repeated(nil, 200), into: &finder)
        #expect(observedEvents.isEmpty)
        #expect(!finder.isInStretch)
        #expect(finder.secondsSinceLastStretchEnded(at: 10) == nil)
    }

    @Test func aHandRaisedForASecondStartsThenEndsWithLeadInAndLeadOut() {
        var finder = SignStretchFinder()
        // Frames 0–31 no hand, 32–63 raised (one second), 64–99 no hand.
        let wristHeights = Self.repeated(nil, 32) + Self.repeated(Self.raisedWristY, 32) + Self.repeated(nil, 36)
        let observedEvents = Self.feed(wristHeights, into: &finder)

        #expect(observedEvents.count == 2)
        guard observedEvents.count == 2 else { return }
        // Started on the second raised frame in a row.
        #expect(observedEvents[0].frameNumber == 33)
        #expect(observedEvents[0].event == .started)
        // Ended once no hand was raised for 0.4 s: frame 63 + 13 (12 frames is only 0.375 s).
        #expect(observedEvents[1].frameNumber == 76)
        guard let stretch = Self.endedStretch(observedEvents[1]) else {
            Issue.record("expected an ended stretch, got \(observedEvents[1].event)")
            return
        }
        // 6 lead-in frames (26–31), the 32 raised ones, then 2 lead-out frames (64, 65), not the whole gap.
        #expect(stretch.frames.map { Self.frameNumber(of: $0) } == Array(26...65))
        #expect(stretch.startTime == Self.time(ofFrame: 26))
        #expect(stretch.endTime == Self.time(ofFrame: 65))
        #expect(!finder.isInStretch)
        #expect(finder.secondsSinceLastStretchEnded(at: Self.time(ofFrame: 81)) == Self.time(ofFrame: 16))
    }

    @Test func aStretchCarriesTheTimeOfEveryFrameItKept() {
        // Uneven times (a camera that drops frames now and then): each kept frame keeps its own time.
        var finder = SignStretchFinder()
        let wristHeights: [Float?] = Self.repeated(Self.restingWristY, 6) + Self.repeated(Self.raisedWristY, 30) + Self.repeated(Self.restingWristY, 30)
        var times: [Double] = []
        var stretch: SignStretch?
        for (frameNumber, wristY) in wristHeights.enumerated() {
            let time = Double(frameNumber) * Self.frameInterval + (frameNumber % 3 == 0 ? Self.frameInterval / 2 : 0)
            times.append(time)
            if case .ended(let endedStretch)? = finder.observe(Self.frame(number: frameNumber, wristY: wristY), at: time) {
                stretch = endedStretch
            }
        }
        let endedStretch = try! #require(stretch)
        #expect(endedStretch.frameTimes.count == endedStretch.frames.count)
        for (frame, frameTime) in zip(endedStretch.frames, endedStretch.frameTimes) {
            #expect(frameTime == times[Self.frameNumber(of: frame)])
        }
        #expect(endedStretch.startTime == endedStretch.frameTimes.first)
        #expect(endedStretch.endTime == endedStretch.frameTimes.last)
    }

    // MARK: Wrists from the body pose, and hands that aren't signing

    /// Shoulders as usual; the body pose's right wrist at (bodyWristX, bodyWristY) when given; a fully seen right hand
    /// at (handX, handY) with still fingers when given (Vision often misses the hand in a fast sign).
    private static func bodyFrame(
        number frameNumber: Int,
        bodyWrist: (x: Float, y: Float)?,
        hand: (x: Float, y: Float)? = nil
    ) -> SignLandmarkFrame {
        var frame = Self.frame(number: frameNumber, wristY: nil)
        if let bodyWrist {
            frame[SignBodyPoint.rightWrist] = SignLandmarkPoint(x: bodyWrist.x, y: bodyWrist.y, confidence: 0.8)
        }
        if let hand {
            for (jointNumber, joint) in HandJoint.allCases.enumerated() {
                let offset = Float(jointNumber) * 0.002
                frame.setHandJoint(side: .right, joint: joint, point: SignLandmarkPoint(x: hand.x + offset, y: hand.y - offset, confidence: 0.9))
            }
        }
        return frame
    }

    private static func feedFrames(_ frames: [SignLandmarkFrame], into finder: inout SignStretchFinder) -> [ObservedEvent] {
        var observedEvents: [ObservedEvent] = []
        for (frameNumber, frame) in frames.enumerated() {
            if let event = finder.observe(frame, at: Self.time(ofFrame: frameNumber)) {
                observedEvents.append(ObservedEvent(frameNumber: frameNumber, event: event))
            }
        }
        return observedEvents
    }

    @Test func aFastSignSeenMostlyThroughTheBodyWristIsOneStretch() {
        // Rest (wrist low), then a second of signing where the hand itself is seen only every eighth frame but the
        // body pose's wrist is there throughout, swinging between two places, then rest again.
        var frames: [SignLandmarkFrame] = (0..<20).map { Self.bodyFrame(number: $0, bodyWrist: (0.45, 0.9)) }
        for frameNumber in 20..<52 {
            let wristX: Float = frameNumber % 6 < 3 ? 0.40 : 0.52
            let handSeen = frameNumber % 8 == 0
            frames.append(Self.bodyFrame(number: frameNumber, bodyWrist: (wristX, 0.5), hand: handSeen ? (wristX, 0.5) : nil))
        }
        frames += (52..<100).map { Self.bodyFrame(number: $0, bodyWrist: (0.45, 0.9)) }
        var finder = SignStretchFinder()
        let observedEvents = Self.feedFrames(frames, into: &finder)
        let endedStretches = observedEvents.compactMap { Self.endedStretch($0) }
        #expect(endedStretches.count == 1)
        #expect(observedEvents.filter { $0.event == .started }.count == 1)
        let stretchFrameNumbers = endedStretches.first.map { $0.frames.map { Self.frameNumber(of: $0) } } ?? []
        #expect(stretchFrameNumbers.first.map { $0 <= 21 } == true)
        #expect(stretchFrameNumbers.last.map { $0 >= 51 } == true)
    }

    @Test func handsLyingStillOnADeskAboveTheRestLineStartNothing() {
        // Seated at a desk: hands rest above the rest line (y 0.6 < 0.75) for 20 s, with Vision's small jitter.
        var finder = SignStretchFinder()
        var frames: [SignLandmarkFrame] = []
        for frameNumber in 0..<640 {
            let jitter: Float = Float((frameNumber * 7) % 5) * 0.002
            frames.append(Self.bodyFrame(number: frameNumber, bodyWrist: (0.45 + jitter, 0.6), hand: (0.45 + jitter, 0.6 - jitter)))
        }
        let observedEvents = Self.feedFrames(frames, into: &finder)
        #expect(observedEvents.isEmpty)
    }

    @Test func scratchingTheFaceOnceIsAtMostTwoStretchesAndRestingAfterwardsAddsNone() {
        // Hand on the desk 3 s, up to the face and scratching for 1.5 s, back on the desk for 10 s.
        var frames: [SignLandmarkFrame] = []
        for frameNumber in 0..<96 { frames.append(Self.bodyFrame(number: frameNumber, bodyWrist: (0.45, 0.62), hand: (0.45, 0.62))) }
        for frameNumber in 96..<144 {
            let scratch: Float = frameNumber % 4 < 2 ? 0 : 0.03
            frames.append(Self.bodyFrame(number: frameNumber, bodyWrist: (0.5 + scratch, 0.3), hand: (0.5 + scratch, 0.3)))
        }
        for frameNumber in 144..<464 { frames.append(Self.bodyFrame(number: frameNumber, bodyWrist: (0.45, 0.62), hand: (0.45, 0.62))) }
        var finder = SignStretchFinder()
        let observedEvents = Self.feedFrames(frames, into: &finder)
        // At most two: the hand going up and scratching, and perhaps the hand coming back down onto the desk (it
        // moves above the rest line). Then nothing at all for the 10 s it lies there.
        #expect(observedEvents.filter { $0.event == .started }.count <= 2)
        #expect(observedEvents.allSatisfy { $0.frameNumber < 144 + 64 })
        #expect(!finder.isInStretch)
    }

    @Test func aSignHeldWithoutMovingEndsAfterBeingStillForTheStillTime() {
        // Raised and moving for half a second, then held without any movement: the stretch ends once the hand has been
        // still for `stillSeconds` and then the end gap has passed, not at the longest length.
        var finder = SignStretchFinder()
        var frames: [SignLandmarkFrame] = (0..<10).map { Self.frame(number: $0, wristY: Self.restingWristY) }
        frames += (10..<26).map { Self.frame(number: $0, wristY: Self.raisedWristY) }
        frames += (26..<200).map { Self.frame(number: $0, wristY: Self.raisedWristY, stillHand: true) }
        let observedEvents = Self.feedFrames(frames, into: &finder)
        let endedEvent = observedEvents.first { Self.endedStretch($0) != nil }
        let settings = SignStretchSettings()
        let latestEndFrame = 26 + Int(((settings.stillSeconds + settings.endGapSeconds) / Self.frameInterval).rounded(.up)) + 2
        #expect(endedEvent.map { $0.frameNumber <= latestEndFrame } == true)
    }

    @Test func isInStretchFollowsTheStretch() {
        var finder = SignStretchFinder()
        _ = Self.feed(Self.repeated(nil, 10) + Self.repeated(Self.raisedWristY, 1), into: &finder)
        #expect(!finder.isInStretch)
        _ = Self.feed([Self.raisedWristY], into: &finder, firstFrameNumber: 11)
        #expect(finder.isInStretch)
    }

    @Test func aBlipOfThreeFramesIsDroppedAsTooShort() {
        var finder = SignStretchFinder()
        let wristHeights = Self.repeated(nil, 10) + Self.repeated(Self.raisedWristY, 3) + Self.repeated(nil, 30)
        let observedEvents = Self.feed(wristHeights, into: &finder)
        #expect(observedEvents.map(\.frameNumber) == [11, 25])
        #expect(observedEvents.map(\.event) == [.started, .droppedTooShort])
        // A dropped stretch doesn't count as one that ended.
        #expect(finder.secondsSinceLastStretchEnded(at: 5) == nil)
        #expect(!finder.isInStretch)
    }

    @Test func aRaisedPartJustLongEnoughIsKept() {
        // 9 raised frames span 8/32 = 0.25 s: exactly the shortest stretch, so it is kept; 8 frames is dropped.
        var keptFinder = SignStretchFinder()
        let keptEvents = Self.feed(Self.repeated(nil, 5) + Self.repeated(Self.raisedWristY, 9) + Self.repeated(nil, 20), into: &keptFinder)
        #expect(keptEvents.count == 2)
        #expect(keptEvents.last.flatMap { Self.endedStretch($0) } != nil)

        var droppedFinder = SignStretchFinder()
        let droppedEvents = Self.feed(Self.repeated(nil, 5) + Self.repeated(Self.raisedWristY, 8) + Self.repeated(nil, 20), into: &droppedFinder)
        #expect(droppedEvents.map(\.event) == [.started, .droppedTooShort])
    }

    @Test func aShortDipDoesNotEndTheStretch() {
        var finder = SignStretchFinder()
        // Raised 0–31, resting 32–39 (0.25 s, under the 0.4 s gap), raised 40–71, then no hand.
        let wristHeights = Self.repeated(Self.raisedWristY, 32)
            + Self.repeated(Self.restingWristY, 8)
            + Self.repeated(Self.raisedWristY, 32)
            + Self.repeated(nil, 30)
        let observedEvents = Self.feed(wristHeights, into: &finder)
        #expect(observedEvents.count == 2)
        guard observedEvents.count == 2, let stretch = Self.endedStretch(observedEvents[1]) else {
            Issue.record("expected one stretch, got \(observedEvents.map(\.event))")
            return
        }
        #expect(observedEvents[0].frameNumber == 1)
        #expect(observedEvents[1].frameNumber == 71 + 13)
        // No frames before the first one to lead in with; the lead-out is 72 and 73.
        #expect(stretch.frames.map { Self.frameNumber(of: $0) } == Array(0...73))
    }

    @Test func aDipAsLongAsTheGapEndsTheStretch() {
        var finder = SignStretchFinder()
        // Resting for 13 frames (0.406 s) ends it, and the hands coming back up start a new one.
        let wristHeights = Self.repeated(Self.raisedWristY, 32)
            + Self.repeated(Self.restingWristY, 13)
            + Self.repeated(Self.raisedWristY, 32)
        let observedEvents = Self.feed(wristHeights, into: &finder)
        #expect(observedEvents.map(\.frameNumber) == [1, 44, 46])
        #expect(observedEvents.count == 3)
        guard observedEvents.count == 3 else { return }
        #expect(observedEvents[2].event == .started)
    }

    @Test func aStretchIsCutAtTheLongestLength() {
        var finder = SignStretchFinder(settings: SignStretchSettings(longestStretchSeconds: 2))
        let observedEvents = Self.feed(Self.repeated(Self.raisedWristY, 100), into: &finder)
        // Started at frame 1, cut at frame 64 (2 s after frame 0), and started again two raised frames later.
        #expect(observedEvents.map(\.frameNumber) == [1, 64, 66])
        guard observedEvents.count == 3, let stretch = Self.endedStretch(observedEvents[1]) else {
            Issue.record("expected started, ended, started; got \(observedEvents.map(\.event))")
            return
        }
        #expect(stretch.frames.map { Self.frameNumber(of: $0) } == Array(0...64))
        #expect(stretch.seconds == 2)
        #expect(observedEvents[2].event == .started)
        #expect(finder.isInStretch)
    }

    @Test func handsBelowTheRestLineNeverStartAStretch() {
        var finder = SignStretchFinder()
        let observedEvents = Self.feed(Self.repeated(Self.restingWristY, 200), into: &finder)
        #expect(observedEvents.isEmpty)
        // Memory stays bounded while idle: the lead-in ring only (2 frames to start + 6 lead-in).
        #expect(finder.heldFrameCount <= 8)
    }

    @Test func theRestLineCountsAcrossAsWiderInAWidePicture() {
        // A wrist at 0.8: under the 0.75 line with the picture size unknown, above the 0.85 line at 640 × 480
        // (shoulders 0.2 × 4/3 apart).
        let wristHeights = Self.repeated(Float(0.8), 40)
        var unknownSizeFinder = SignStretchFinder()
        let unknownSizeEvents = Self.feed(wristHeights, into: &unknownSizeFinder)
        #expect(unknownSizeEvents.isEmpty)
        var wideFinder = SignStretchFinder(pictureWidth: 640, pictureHeight: 480)
        let wideEvents = Self.feed(wristHeights, into: &wideFinder)
        #expect(wideEvents.map(\.event) == [.started])
    }

    @Test func withoutShouldersEverSeenAnySeenHandStartsAStretch() {
        var finder = SignStretchFinder()
        let observedEvents = Self.feed(Self.repeated(Self.restingWristY, 10), into: &finder, shoulders: false)
        #expect(observedEvents.map(\.frameNumber) == [1])
        #expect(observedEvents.map(\.event) == [.started])
    }

    @Test func theLastKnownRestLineIsKeptWhenTheShouldersAreLost() {
        var finder = SignStretchFinder()
        _ = Self.feed(Self.repeated(nil, 10), into: &finder)
        let observedEvents = Self.feed(Self.repeated(Self.restingWristY, 40), into: &finder, firstFrameNumber: 10, shoulders: false)
        #expect(observedEvents.isEmpty)
    }

    @Test func resetForgetsTheStretchAndTheRestLine() {
        var finder = SignStretchFinder()
        _ = Self.feed(Self.repeated(Self.raisedWristY, 5), into: &finder)
        #expect(finder.isInStretch)
        finder.reset()
        #expect(!finder.isInStretch)
        #expect(finder.heldFrameCount == 0)
        // With the rest line forgotten, a low hand without shoulders counts as raised again.
        let observedEvents = Self.feed(Self.repeated(Self.restingWristY, 3), into: &finder, firstFrameNumber: 5, shoulders: false)
        #expect(observedEvents.map(\.event) == [.started])
    }

    @Test func memoryStaysBoundedDuringALongSigning() {
        var finder = SignStretchFinder()
        var mostFramesHeld = 0
        for frameNumber in 0..<(32 * 30) {
            _ = finder.observe(Self.frame(number: frameNumber, wristY: Self.raisedWristY), at: Self.time(ofFrame: frameNumber))
            mostFramesHeld = max(mostFramesHeld, finder.heldFrameCount)
        }
        // 12 s at 32 frames a second is 384 frames, plus the frame that reaches the limit.
        #expect(mostFramesHeld <= 12 * 32 + 1)
    }
}
