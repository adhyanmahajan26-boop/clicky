//
//  SignStretches.swift
//  ClickyCore
//
//  Sign to text, live: where one sign (or one finger-spelled word) starts and ends in the camera's stream of
//  frames. Signing happens with the hands up in front of the body; between signs the hands drop to rest, below
//  the chest. So a stretch starts once a hand has been raised for a couple of frames, and ends once no hand has
//  been raised for a short while. Each stretch is then read on its own (SignFeatures, the models, SignReading).
//
//  Pure Foundation: the app feeds frames and their times in.
//

import Foundation

// MARK: - Settings

/// Every number that decides where a stretch starts and ends, so they can be tuned in one place.
public struct SignStretchSettings: Equatable, Sendable {
    /// How far below the middle of the shoulders the rest line is, in shoulder widths. A wrist above the line is a
    /// raised (signing) hand; below it, a hand at rest. 1.5 sits around the waist, under where signs are made.
    public var restLineBelowShouldersInShoulderWidths: Double
    /// How many frames in a row need a raised hand before a stretch starts, so a single noisy frame never does.
    public var framesToStart: Int
    /// How long no hand may be raised before the stretch ends. Shorter than a pause between signs, longer than the
    /// moment a hand dips while signing.
    public var endGapSeconds: Double
    /// How many frames from just before the start are kept, so the model sees the hand coming up into the sign.
    public var leadInFrames: Int
    /// How many frames after the last raised frame are kept (not the whole gap), so the end of the sign is there
    /// without a long tail of resting hands.
    public var leadOutFrames: Int
    /// A stretch whose raised part is shorter than this is a hand passing by, not a sign, and is dropped.
    public var shortestStretchSeconds: Double
    /// A stretch is cut here even with the hands still up, so one reading never waits forever (and memory stays
    /// bounded); the finger-spelling model reads at most about 8.5 s anyway.
    public var longestStretchSeconds: Double

    public init(
        restLineBelowShouldersInShoulderWidths: Double = 1.5,
        framesToStart: Int = 2,
        endGapSeconds: Double = 0.4,
        leadInFrames: Int = 4,
        leadOutFrames: Int = 2,
        shortestStretchSeconds: Double = 0.25,
        longestStretchSeconds: Double = 12
    ) {
        self.restLineBelowShouldersInShoulderWidths = restLineBelowShouldersInShoulderWidths
        self.framesToStart = framesToStart
        self.endGapSeconds = endGapSeconds
        self.leadInFrames = leadInFrames
        self.leadOutFrames = leadOutFrames
        self.shortestStretchSeconds = shortestStretchSeconds
        self.longestStretchSeconds = longestStretchSeconds
    }
}

// MARK: - Stretches and events

/// One sign's frames, lead-in and lead-out included, each with the time the camera gave it (`frameTimes`, the same
/// count as `frames`), so a stretch can be brought to 30 frames a second from its own times.
public struct SignStretch: Equatable, Sendable {
    public var frames: [SignLandmarkFrame]
    public var frameTimes: [Double]

    public init(frames: [SignLandmarkFrame], frameTimes: [Double]) {
        precondition(frames.count == frameTimes.count, "a stretch needs one time per frame")
        self.frames = frames
        self.frameTimes = frameTimes
    }

    /// The times of the first and last frame kept.
    public var startTime: Double { frameTimes.first ?? 0 }
    public var endTime: Double { frameTimes.last ?? 0 }
    public var seconds: Double { endTime - startTime }
}

public enum SignStretchEvent: Equatable, Sendable {
    /// A hand came up: a stretch is being collected.
    case started
    /// The stretch is over and ready to read.
    case ended(SignStretch)
    /// The stretch was too short to be a sign and was thrown away.
    case droppedTooShort
}

// MARK: - Finder

/// Watches frames one by one and says when a stretch starts and ends.
public struct SignStretchFinder: Sendable {
    public let settings: SignStretchSettings
    /// The camera picture's size in pixels; 0 when unknown. Only used to measure the shoulder width.
    public let pictureWidth: Double
    public let pictureHeight: Double

    /// A guard for a stream whose times stop moving (the time limit would never be reached): no stretch holds more
    /// frames than this. 60 s at 30 frames a second.
    static let mostFramesInOneStretch = 1800

    private struct TimedFrame: Equatable, Sendable {
        var frame: SignLandmarkFrame
        var time: Double
        var hasARaisedHand: Bool
    }

    /// While idle: the last few frames, for the lead-in. Never longer than `idleFrameCapacity`.
    private var recentIdleFrames: [TimedFrame] = []
    private var raisedFramesInARow = 0

    /// While in a stretch: its frames so far.
    private var stretchFrames: [TimedFrame] = []
    private var stretchIsRunning = false
    /// Index into `stretchFrames` of the last frame with a raised hand, and of the first one.
    private var lastRaisedFrameIndex = 0
    private var firstRaisedFrameIndex = 0

    /// Where the rest line was last measured (picture y, down), nil before shoulders were ever seen.
    private var lastKnownRestLineY: Double? = nil
    private var lastStretchEndTime: Double? = nil

    public init(settings: SignStretchSettings = SignStretchSettings(), pictureWidth: Double = 0, pictureHeight: Double = 0) {
        self.settings = settings
        self.pictureWidth = pictureWidth
        self.pictureHeight = pictureHeight
    }

    public var isInStretch: Bool { stretchIsRunning }

    /// Seconds from the end of the last stretch that was read (not one dropped as too short) to `time`; nil before any.
    public func secondsSinceLastStretchEnded(at time: Double) -> Double? {
        guard let lastStretchEndTime else { return nil }
        return time - lastStretchEndTime
    }

    /// Forgets everything: any stretch in progress, the recent frames, the rest line and the last stretch's end.
    public mutating func reset() {
        recentIdleFrames = []
        raisedFramesInARow = 0
        stretchFrames = []
        stretchIsRunning = false
        lastRaisedFrameIndex = 0
        firstRaisedFrameIndex = 0
        lastKnownRestLineY = nil
        lastStretchEndTime = nil
    }

    /// How many frames are held right now (for tests: it must stay bounded).
    var heldFrameCount: Int { recentIdleFrames.count + stretchFrames.count }

    private var framesNeededToStart: Int { max(settings.framesToStart, 1) }
    private var leadInFrameCount: Int { max(settings.leadInFrames, 0) }
    private var leadOutFrameCount: Int { max(settings.leadOutFrames, 0) }
    private var idleFrameCapacity: Int { framesNeededToStart + leadInFrameCount }

    /// Takes the next frame (times in seconds, rising) and says what happened, if anything.
    public mutating func observe(_ frame: SignLandmarkFrame, at time: Double) -> SignStretchEvent? {
        updateRestLine(from: frame)
        let timedFrame = TimedFrame(frame: frame, time: time, hasARaisedHand: hasARaisedHand(in: frame))

        if !stretchIsRunning {
            recentIdleFrames.append(timedFrame)
            if recentIdleFrames.count > idleFrameCapacity {
                recentIdleFrames.removeFirst(recentIdleFrames.count - idleFrameCapacity)
            }
            raisedFramesInARow = timedFrame.hasARaisedHand ? raisedFramesInARow + 1 : 0
            guard raisedFramesInARow >= framesNeededToStart else { return nil }

            // Start: the run of raised frames plus up to `leadInFrames` frames from just before it, which is all
            // the idle ring holds.
            stretchFrames = recentIdleFrames
            recentIdleFrames = []
            raisedFramesInARow = 0
            stretchIsRunning = true
            lastRaisedFrameIndex = stretchFrames.count - 1
            firstRaisedFrameIndex = max(stretchFrames.count - framesNeededToStart, 0)
            return .started
        }

        stretchFrames.append(timedFrame)
        if timedFrame.hasARaisedHand {
            lastRaisedFrameIndex = stretchFrames.count - 1
        }

        let lastRaisedTime = stretchFrames[lastRaisedFrameIndex].time
        let firstFrameTime = stretchFrames[0].time
        let handsHaveRestedLongEnough = time - lastRaisedTime >= settings.endGapSeconds
        let stretchIsAsLongAsAllowed = time - firstFrameTime >= settings.longestStretchSeconds
            || stretchFrames.count >= Self.mostFramesInOneStretch
        guard handsHaveRestedLongEnough || stretchIsAsLongAsAllowed else { return nil }
        return finishStretch()
    }

    // MARK: Private

    private mutating func finishStretch() -> SignStretchEvent {
        // Keep up to `leadOutFrames` after the last raised frame, not the whole resting gap.
        let lastKeptFrameIndex = min(lastRaisedFrameIndex + leadOutFrameCount, stretchFrames.count - 1)
        let keptFrames = Array(stretchFrames[0...lastKeptFrameIndex])
        // The frames after the kept part were hands at rest: they can be the next stretch's lead-in.
        let leftoverFrames = Array(stretchFrames[(lastKeptFrameIndex + 1)...])
        let raisedSeconds = stretchFrames[lastRaisedFrameIndex].time - stretchFrames[firstRaisedFrameIndex].time

        stretchFrames = []
        stretchIsRunning = false
        lastRaisedFrameIndex = 0
        firstRaisedFrameIndex = 0
        raisedFramesInARow = 0
        recentIdleFrames = Array(leftoverFrames.suffix(idleFrameCapacity))

        guard raisedSeconds >= settings.shortestStretchSeconds, let lastKeptFrame = keptFrames.last else { return .droppedTooShort }

        lastStretchEndTime = lastKeptFrame.time
        return .ended(SignStretch(frames: keptFrames.map { $0.frame }, frameTimes: keptFrames.map { $0.time }))
    }

    /// The rest line is `shoulder midpoint y + restLineBelowShouldersInShoulderWidths × shoulder width`, the width
    /// measured in picture heights (x counts width / height times more when the picture's size is known).
    private mutating func updateRestLine(from frame: SignLandmarkFrame) {
        let leftShoulder = frame[SignBodyPoint.leftShoulder]
        let rightShoulder = frame[SignBodyPoint.rightShoulder]
        guard leftShoulder.isSeen && rightShoulder.isSeen else { return }
        let pictureWidthOverHeight = (pictureWidth > 0 && pictureHeight > 0) ? pictureWidth / pictureHeight : 1.0
        let horizontalDistance = (Double(leftShoulder.x) - Double(rightShoulder.x)) * pictureWidthOverHeight
        let verticalDistance = Double(leftShoulder.y) - Double(rightShoulder.y)
        let shoulderWidth = (horizontalDistance * horizontalDistance + verticalDistance * verticalDistance).squareRoot()
        let shoulderMidpointY = (Double(leftShoulder.y) + Double(rightShoulder.y)) / 2
        lastKnownRestLineY = shoulderMidpointY + settings.restLineBelowShouldersInShoulderWidths * shoulderWidth
    }

    /// A hand is raised when it counts as seen and its wrist is above the rest line (y is down, so above is a
    /// smaller y). Before any shoulders were seen there is no line, so every seen hand counts.
    private func hasARaisedHand(in frame: SignLandmarkFrame) -> Bool {
        for side in SignSide.allCases {
            guard SignFeatures.handIsSeen(in: frame, side: side) else { continue }
            guard let restLineY = lastKnownRestLineY else { return true }
            let wristY = Double(frame.handJoint(side: side, joint: .wrist).y)
            if wristY < restLineY {
                return true
            }
        }
        return false
    }
}
