//
//  SignFrameRate.swift
//  ClickyCore
//
//  Sign to text: the models read 30 frames a second, so landmarks that came slower or faster (a dataset filmed at
//  25 or 60, a Mac camera that slows down in dim light, Vision falling behind and late frames being dropped) are
//  brought to 30 first. `Tools/signs/SPEC.md` section 3, "Frame rate", is the rule, word for word; the examples in
//  `Tools/signs/tests/golden/frame_rate/` are checked against it by `SignFrameRateTests`.
//
//  Pure Foundation.
//

import Foundation

/// Frames and the times they were taken, brought to the models' rate.
public struct SignTimedFrames: Equatable, Sendable {
    public var frames: [SignLandmarkFrame]
    /// One time per frame, in seconds, rising.
    public var times: [Double]

    public init(frames: [SignLandmarkFrame], times: [Double]) {
        self.frames = frames
        self.times = times
    }
}

public enum SignFrameRate {
    /// The rate every model reads.
    public static let modelFramesPerSecond = 30.0
    /// Between these two rates a stretch is read as it is: close enough to 30 that bringing it there would only blur it.
    public static let slowestRateReadAsItIs = 27.0
    public static let fastestRateReadAsItIs = 33.0
    /// Added to the last frame's time so rounding can't drop the last new frame (SPEC: "plus a millionth of a second").
    static let lastFrameTimeAllowance = 1e-6

    /// SPEC: the rate is `(T − 1) / (τlast − τ0)` over the stretch. Nil with fewer than two frames or times that
    /// don't move forward, since then there is no rate to speak of.
    public static func framesPerSecond(times: [Double]) -> Double? {
        guard times.count >= 2, let firstTime = times.first, let lastTime = times.last, lastTime > firstTime else { return nil }
        return Double(times.count - 1) / (lastTime - firstTime)
    }

    /// True when the stretch's rate is outside 27 to 33 frames a second and has to be brought to 30.
    public static func needsBringingTo30(times: [Double]) -> Bool {
        guard let rate = framesPerSecond(times: times) else { return false }
        return rate < slowestRateReadAsItIs || rate > fastestRateReadAsItIs
    }

    /// The SPEC rule in full: frames between 27 and 33 a second (or too few to have a rate) come back unchanged,
    /// anything else comes back at 30 a second. `times` must have one entry per frame; when it doesn't, the frames
    /// come back unchanged (with times made up at 30 a second), since there is nothing safe to do with them.
    public static func broughtTo30(frames: [SignLandmarkFrame], times: [Double]) -> SignTimedFrames {
        guard frames.count == times.count else {
            let madeUpTimes = frames.indices.map { frameIndex in (times.first ?? 0) + Double(frameIndex) / modelFramesPerSecond }
            return SignTimedFrames(frames: frames, times: madeUpTimes)
        }
        guard needsBringingTo30(times: times) else {
            return SignTimedFrames(frames: frames, times: times)
        }
        return resampled(frames: frames, times: times, toFramesPerSecond: modelFramesPerSecond)
    }

    /// Always resamples, whatever the rate. New frame `j` is at `τ0 + j / rate`, for every such time up to `τlast`
    /// (plus a millionth of a second). With `i` the last frame at or before that time and `f` how far the time is
    /// from frame `i` to frame `i + 1` (0 to 1): a point seen in both takes the place that far along the line
    /// between them and the smaller of the two confidences; any other point is copied as it is from the nearer
    /// frame (`i` when `f < 0.5`, else `i + 1`).
    public static func resampled(frames: [SignLandmarkFrame], times: [Double], toFramesPerSecond targetRate: Double) -> SignTimedFrames {
        guard frames.count == times.count, frames.count >= 2, targetRate > 0,
              let firstTime = times.first, let lastTime = times.last, lastTime > firstTime
        else { return SignTimedFrames(frames: frames, times: times) }

        var newFrames: [SignLandmarkFrame] = []
        var newTimes: [Double] = []
        let lastNewTimeAllowed = lastTime + lastFrameTimeAllowance
        newFrames.reserveCapacity(Int((lastTime - firstTime) * targetRate) + 2)

        // `earlierFrameIndex` only moves forward, since the new times rise.
        var earlierFrameIndex = 0
        var newFrameNumber = 0
        while true {
            let newTime = firstTime + Double(newFrameNumber) / targetRate
            guard newTime <= lastNewTimeAllowed else { break }
            while earlierFrameIndex + 1 < times.count && times[earlierFrameIndex + 1] <= newTime {
                earlierFrameIndex += 1
            }
            newFrames.append(frameBetween(
                frames: frames,
                times: times,
                earlierFrameIndex: earlierFrameIndex,
                time: newTime
            ))
            newTimes.append(newTime)
            newFrameNumber += 1
        }
        return SignTimedFrames(frames: newFrames, times: newTimes)
    }

    /// One new frame at `time`, from frame `earlierFrameIndex` (the last at or before it) and the one after it.
    private static func frameBetween(frames: [SignLandmarkFrame], times: [Double], earlierFrameIndex: Int, time: Double) -> SignLandmarkFrame {
        let laterFrameIndex = earlierFrameIndex + 1
        // At (or past) the last frame there is nothing after it: the last frame is copied as it is.
        guard laterFrameIndex < frames.count else { return frames[earlierFrameIndex] }
        let earlierTime = times[earlierFrameIndex]
        let laterTime = times[laterFrameIndex]
        let timeBetweenFrames = laterTime - earlierTime
        var fractionOfTheWay = timeBetweenFrames > 0 ? (time - earlierTime) / timeBetweenFrames : 0
        fractionOfTheWay = min(max(fractionOfTheWay, 0), 1)
        // Rounded to a millionth so a time that lands on a frame, or exactly half way, can't fall either side by
        // one bit (Python rounds the same way, halves to even).
        fractionOfTheWay = (fractionOfTheWay * 1_000_000).rounded(.toNearestOrEven) / 1_000_000
        if fractionOfTheWay <= 0 { return frames[earlierFrameIndex] }
        if fractionOfTheWay >= 1 { return frames[laterFrameIndex] }

        let earlierValues = frames[earlierFrameIndex].flatValues
        let laterValues = frames[laterFrameIndex].flatValues
        let nearerValues = fractionOfTheWay < 0.5 ? earlierValues : laterValues
        var newValues = [Float](repeating: 0, count: SignLandmarkLayout.valuesPerFrame)
        for pointIndex in 0..<SignLandmarkLayout.pointCount {
            let firstValueIndex = pointIndex * SignLandmarkLayout.valuesPerPoint
            let earlierConfidence = earlierValues[firstValueIndex + 2]
            let laterConfidence = laterValues[firstValueIndex + 2]
            if earlierConfidence > 0 && laterConfidence > 0 {
                // In Double, then rounded to Float once, as NumPy does it before `astype(np.float32)`.
                let earlierX = Double(earlierValues[firstValueIndex])
                let earlierY = Double(earlierValues[firstValueIndex + 1])
                let laterX = Double(laterValues[firstValueIndex])
                let laterY = Double(laterValues[firstValueIndex + 1])
                newValues[firstValueIndex] = Float(earlierX + fractionOfTheWay * (laterX - earlierX))
                newValues[firstValueIndex + 1] = Float(earlierY + fractionOfTheWay * (laterY - earlierY))
                newValues[firstValueIndex + 2] = min(earlierConfidence, laterConfidence)
            } else {
                newValues[firstValueIndex] = nearerValues[firstValueIndex]
                newValues[firstValueIndex + 1] = nearerValues[firstValueIndex + 1]
                newValues[firstValueIndex + 2] = nearerValues[firstValueIndex + 2]
            }
        }
        // 183 values always make a frame.
        return SignLandmarkFrame(flatValues: newValues) ?? SignLandmarkFrame()
    }
}
