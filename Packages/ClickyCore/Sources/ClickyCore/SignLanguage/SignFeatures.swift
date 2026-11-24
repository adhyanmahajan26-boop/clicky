//
//  SignFeatures.swift
//  ClickyCore
//
//  Sign to text, step two: a stretch of landmark frames becomes 117 numbers a frame, exactly the way
//  `Tools/signs/signs/features.py` makes them for training (SPEC section 3). The two must agree to the last few
//  decimals, so this file follows features.py step by step, in Double, and rounds to Float once at the end.
//  `SignFeaturesTests` checks it against the golden files Python wrote (`Tools/signs/tests/golden/`).
//
//  Pure Foundation: no Vision, no Core ML.
//

import Foundation

// MARK: - One stretch's features

/// The features of a stretch of frames: `frameCount` rows of `SignFeatures.featureCount` numbers, one row after
/// another. The sizes the numbers were scaled by are kept too, for tests and for finding where a difference starts.
public struct SignFeatureClip: Equatable, Sendable {
    public let frameCount: Int
    /// `frameCount × 117` numbers, row-major: frame 0's 117, then frame 1's, and so on.
    public let values: [Float]
    /// The hand size every hand joint was divided by (1.0 when it couldn't be measured).
    public let handSize: Double
    /// The body size every wrist and body point was divided by.
    public let bodySize: Double
    /// True when no usable hand size was found, so the hand joint features (0–83) are all zero.
    public let handSizeIsDegenerate: Bool

    public init(frameCount: Int, values: [Float], handSize: Double, bodySize: Double, handSizeIsDegenerate: Bool) {
        self.frameCount = frameCount
        self.values = values
        self.handSize = handSize
        self.bodySize = bodySize
        self.handSizeIsDegenerate = handSizeIsDegenerate
    }

    /// One number: feature `featureIndex` (0–116) of frame `frameIndex`.
    public subscript(frame frameIndex: Int, feature featureIndex: Int) -> Float {
        values[frameIndex * SignFeatures.featureCount + featureIndex]
    }
}

// MARK: - Making features

/// SPEC section 3 and `signs/features.py`, in Swift. The constants have the same names as Python's, spelled out.
public enum SignFeatures {
    public static let featureCount = 117
    /// The first 114 numbers are coordinates; the last 3 are seen flags.
    public static let coordinateFeatureCount = 114

    public static let rightHandFeaturesStart = 0
    public static let leftHandFeaturesStart = 42
    public static let rightWristFeaturesStart = 84
    public static let leftWristFeaturesStart = 86
    public static let bodyFeaturesStart = 88
    public static let rightHandSeenFeature = 114
    public static let leftHandSeenFeature = 115
    public static let bothShouldersSeenFeature = 116

    /// A point missing for at most this many frames in a row (seen before and after) is filled in.
    public static let longestFilledGapFrames = 4
    /// The confidence a filled-in point gets, so it counts as seen from then on.
    public static let filledPointConfidence = 0.5
    /// A hand needs its wrist and at least this many of its other 20 joints to count as seen.
    public static let fewestOtherJointsForASeenHand = 11
    public static let handSizePercentile = 90.0
    public static let bodySizePerHandSizeWhenNoShoulders = 3.5
    /// A hand or body size smaller than this is treated as unmeasurable rather than divided by.
    public static let smallestUsableSize = 1e-6

    /// The middle finger's knuckle: wrist to here is the hand's size.
    static let middleKnuckleJointNumber = 9
    static let wristJointNumber = 0
    static let handJointCount = 21
    static let bodyPointCount = 13

    public static func handFeaturesStart(for side: SignSide) -> Int {
        side == .right ? rightHandFeaturesStart : leftHandFeaturesStart
    }

    public static func wristFeaturesStart(for side: SignSide) -> Int {
        side == .right ? rightWristFeaturesStart : leftWristFeaturesStart
    }

    public static func handSeenFeature(for side: SignSide) -> Int {
        side == .right ? rightHandSeenFeature : leftHandSeenFeature
    }

    // MARK: Seen hands and trimming

    /// Whether the signer's `side` hand counts as seen in this frame as it is (no gap filling): its wrist and at
    /// least 11 of its other 20 joints are seen.
    public static func handIsSeen(in frame: SignLandmarkFrame, side: SignSide) -> Bool {
        let handPointRange = SignLandmarkLayout.handPointRange(for: side)
        let wristIsSeen = frame[handPointRange.lowerBound + wristJointNumber].isSeen
        guard wristIsSeen else { return false }
        let otherJointsSeenCount = frame.seenJointCount(side: side) - 1
        return otherJointsSeenCount >= fewestOtherJointsForASeenHand
    }

    /// SPEC "Order": drops the frames before the first frame with a hand and after the last one, judged on the
    /// landmarks as seen (before gaps are filled). A stretch with no hand at all is kept whole, as in Python.
    public static func trimmingFramesWithoutHands(_ frames: [SignLandmarkFrame]) -> [SignLandmarkFrame] {
        let frameHasAHand = frames.map { frame in
            handIsSeen(in: frame, side: .right) || handIsSeen(in: frame, side: .left)
        }
        guard let firstFrameWithAHand = frameHasAHand.firstIndex(of: true),
              let lastFrameWithAHand = frameHasAHand.lastIndex(of: true)
        else { return frames }
        return Array(frames[firstFrameWithAHand...lastFrameWithAHand])
    }

    // MARK: Features

    /// `features.py` `compute_feature_details`, step by step. `pictureWidth` and `pictureHeight` are the camera
    /// picture's size in pixels; 0 (or less) for either means unknown, and then x is used as it is.
    public static func featureClip(of frames: [SignLandmarkFrame], pictureWidth: Double, pictureHeight: Double) -> SignFeatureClip {
        let frameCount = frames.count
        let pointCount = SignLandmarkLayout.pointCount
        let valuesPerPoint = SignLandmarkLayout.valuesPerPoint
        let pictureSizeIsKnown = pictureWidth > 0 && pictureHeight > 0
        let pictureWidthOverHeight = pictureSizeIsKnown ? pictureWidth / pictureHeight : 1.0

        // Every point of every frame, at `frameIndex * pointCount + pointIndex`.
        var pointX = [Double](repeating: 0, count: frameCount * pointCount)
        var pointY = [Double](repeating: 0, count: frameCount * pointCount)
        var pointConfidence = [Double](repeating: 0, count: frameCount * pointCount)

        // Step 0: a point not seen is all zeros; x is multiplied by width / height once, here, when the size is
        // known, so every later distance counts x and y the same.
        for frameIndex in 0..<frameCount {
            let flatValues = frames[frameIndex].flatValues
            for pointIndex in 0..<pointCount {
                let firstValueIndex = pointIndex * valuesPerPoint
                let confidence = Double(flatValues[firstValueIndex + 2])
                guard confidence > 0 else { continue }
                let storageIndex = frameIndex * pointCount + pointIndex
                var correctedX = Double(flatValues[firstValueIndex])
                if pictureSizeIsKnown {
                    correctedX *= pictureWidthOverHeight
                }
                pointX[storageIndex] = correctedX
                pointY[storageIndex] = Double(flatValues[firstValueIndex + 1])
                pointConfidence[storageIndex] = confidence
            }
        }

        // Step 1: short gaps are filled, each point on its own. The line runs between the seen places before and
        // after the gap, so it reads the unfilled copies; only frames that were not seen are written.
        let unfilledX = pointX
        let unfilledY = pointY
        let unfilledConfidence = pointConfidence
        for pointIndex in 0..<pointCount {
            var previousSeenFrame: Int? = nil
            for frameIndex in 0..<frameCount {
                let storageIndex = frameIndex * pointCount + pointIndex
                guard unfilledConfidence[storageIndex] > 0 else { continue }
                if let lastSeenFrame = previousSeenFrame {
                    let gapLength = frameIndex - lastSeenFrame - 1
                    if gapLength >= 1 && gapLength <= longestFilledGapFrames {
                        let lastSeenStorageIndex = lastSeenFrame * pointCount + pointIndex
                        let frameDistance = Double(frameIndex - lastSeenFrame)
                        for missingFrame in (lastSeenFrame + 1)..<frameIndex {
                            let missingStorageIndex = missingFrame * pointCount + pointIndex
                            let fractionOfTheWay = Double(missingFrame - lastSeenFrame) / frameDistance
                            pointX[missingStorageIndex] = unfilledX[lastSeenStorageIndex]
                                + fractionOfTheWay * (unfilledX[storageIndex] - unfilledX[lastSeenStorageIndex])
                            pointY[missingStorageIndex] = unfilledY[lastSeenStorageIndex]
                                + fractionOfTheWay * (unfilledY[storageIndex] - unfilledY[lastSeenStorageIndex])
                            pointConfidence[missingStorageIndex] = filledPointConfidence
                        }
                    }
                }
                previousSeenFrame = frameIndex
            }
        }

        func flatIndex(frame frameIndex: Int, point pointIndex: Int) -> Int {
            frameIndex * pointCount + pointIndex
        }

        func pointIsSeen(frame frameIndex: Int, point pointIndex: Int) -> Bool {
            pointConfidence[flatIndex(frame: frameIndex, point: pointIndex)] > 0
        }

        // Seen flags, after filling.
        func handSeenFlags(side: SignSide) -> [Bool] {
            let handStart = SignLandmarkLayout.handPointRange(for: side).lowerBound
            var handIsSeenInFrame = [Bool](repeating: false, count: frameCount)
            for frameIndex in 0..<frameCount {
                guard pointIsSeen(frame: frameIndex, point: handStart + wristJointNumber) else { continue }
                var otherJointsSeenCount = 0
                for jointNumber in 0..<handJointCount where jointNumber != wristJointNumber {
                    if pointIsSeen(frame: frameIndex, point: handStart + jointNumber) {
                        otherJointsSeenCount += 1
                    }
                }
                handIsSeenInFrame[frameIndex] = otherJointsSeenCount >= fewestOtherJointsForASeenHand
            }
            return handIsSeenInFrame
        }
        let rightHandSeen = handSeenFlags(side: .right)
        let leftHandSeen = handSeenFlags(side: .left)

        let leftShoulderPoint = SignBodyPoint.leftShoulder.pointIndex
        let rightShoulderPoint = SignBodyPoint.rightShoulder.pointIndex
        var bothShouldersSeen = [Bool](repeating: false, count: frameCount)
        for frameIndex in 0..<frameCount {
            bothShouldersSeen[frameIndex] = pointIsSeen(frame: frameIndex, point: leftShoulderPoint)
                && pointIsSeen(frame: frameIndex, point: rightShoulderPoint)
        }

        // Step 2, hand size: the 90th percentile of wrist-to-middle-knuckle distances, both hands pooled, over
        // frames where the hand is seen and its knuckle is seen.
        var pooledWristToKnuckleDistances: [Double] = []
        for (side, handIsSeenInFrame) in [(SignSide.right, rightHandSeen), (SignSide.left, leftHandSeen)] {
            let handStart = SignLandmarkLayout.handPointRange(for: side).lowerBound
            let wristPoint = handStart + wristJointNumber
            let knucklePoint = handStart + middleKnuckleJointNumber
            for frameIndex in 0..<frameCount where handIsSeenInFrame[frameIndex] {
                guard pointIsSeen(frame: frameIndex, point: knucklePoint) else { continue }
                let horizontalOffset = pointX[flatIndex(frame: frameIndex, point: knucklePoint)]
                    - pointX[flatIndex(frame: frameIndex, point: wristPoint)]
                let verticalOffset = pointY[flatIndex(frame: frameIndex, point: knucklePoint)]
                    - pointY[flatIndex(frame: frameIndex, point: wristPoint)]
                pooledWristToKnuckleDistances.append(
                    (horizontalOffset * horizontalOffset + verticalOffset * verticalOffset).squareRoot()
                )
            }
        }
        var handSize = 1.0
        var handSizeIsDegenerate = true
        if let measuredHandSize = linearPercentile(of: pooledWristToKnuckleDistances, percentile: handSizePercentile),
           measuredHandSize >= smallestUsableSize {
            handSize = measuredHandSize
            handSizeIsDegenerate = false
        }

        // Step 2, body size: the median shoulder-to-shoulder distance, else 3.5 × hand size (1.0 when degenerate).
        var shoulderDistances: [Double] = []
        for frameIndex in 0..<frameCount where bothShouldersSeen[frameIndex] {
            let horizontalOffset = pointX[flatIndex(frame: frameIndex, point: leftShoulderPoint)]
                - pointX[flatIndex(frame: frameIndex, point: rightShoulderPoint)]
            let verticalOffset = pointY[flatIndex(frame: frameIndex, point: leftShoulderPoint)]
                - pointY[flatIndex(frame: frameIndex, point: rightShoulderPoint)]
            shoulderDistances.append((horizontalOffset * horizontalOffset + verticalOffset * verticalOffset).squareRoot())
        }
        var bodySize = bodySizePerHandSizeWhenNoShoulders * handSize
        if let medianShoulderDistance = median(of: shoulderDistances), medianShoulderDistance >= smallestUsableSize {
            bodySize = medianShoulderDistance
        }

        // Step 2, centre per frame.
        var centreX = [Double](repeating: 0, count: frameCount)
        var centreY = [Double](repeating: 0, count: frameCount)
        if let firstFrameWithShoulders = bothShouldersSeen.firstIndex(of: true) {
            // Each frame takes the shoulder midpoint of the latest frame (itself included) with both shoulders;
            // frames before the first such frame take the first one.
            var latestFrameWithShoulders = firstFrameWithShoulders
            for frameIndex in 0..<frameCount {
                if bothShouldersSeen[frameIndex] {
                    latestFrameWithShoulders = frameIndex
                }
                let leftShoulderIndex = flatIndex(frame: latestFrameWithShoulders, point: leftShoulderPoint)
                let rightShoulderIndex = flatIndex(frame: latestFrameWithShoulders, point: rightShoulderPoint)
                centreX[frameIndex] = (pointX[leftShoulderIndex] + pointX[rightShoulderIndex]) / 2.0
                centreY[frameIndex] = (pointY[leftShoulderIndex] + pointY[rightShoulderIndex]) / 2.0
            }
        } else {
            // No shoulders in the whole stretch: the median of the seen wrists' places, x and y each on their own.
            var seenWristX: [Double] = []
            var seenWristY: [Double] = []
            for (side, handIsSeenInFrame) in [(SignSide.right, rightHandSeen), (SignSide.left, leftHandSeen)] {
                let wristPoint = SignLandmarkLayout.handPointRange(for: side).lowerBound + wristJointNumber
                for frameIndex in 0..<frameCount where handIsSeenInFrame[frameIndex] {
                    seenWristX.append(pointX[flatIndex(frame: frameIndex, point: wristPoint)])
                    seenWristY.append(pointY[flatIndex(frame: frameIndex, point: wristPoint)])
                }
            }
            var stretchCentreX = 0.5 * pictureWidthOverHeight
            var stretchCentreY = 0.5
            if let medianWristX = median(of: seenWristX), let medianWristY = median(of: seenWristY) {
                stretchCentreX = medianWristX
                stretchCentreY = medianWristY
            }
            for frameIndex in 0..<frameCount {
                centreX[frameIndex] = stretchCentreX
                centreY[frameIndex] = stretchCentreY
            }
        }

        // Step 3, per frame.
        var featureValues = [Double](repeating: 0, count: frameCount * featureCount)
        for (side, handIsSeenInFrame) in [(SignSide.right, rightHandSeen), (SignSide.left, leftHandSeen)] {
            let handStart = SignLandmarkLayout.handPointRange(for: side).lowerBound
            let wristPoint = handStart + wristJointNumber
            let sideHandFeaturesStart = SignFeatures.handFeaturesStart(for: side)
            let sideWristFeaturesStart = SignFeatures.wristFeaturesStart(for: side)
            for frameIndex in 0..<frameCount where handIsSeenInFrame[frameIndex] {
                let rowStart = frameIndex * featureCount
                let wristX = pointX[flatIndex(frame: frameIndex, point: wristPoint)]
                let wristY = pointY[flatIndex(frame: frameIndex, point: wristPoint)]
                // Without a usable hand size the joint shapes can't be scaled, so they stay zero.
                if !handSizeIsDegenerate {
                    for jointNumber in 0..<handJointCount {
                        let jointPoint = handStart + jointNumber
                        guard pointIsSeen(frame: frameIndex, point: jointPoint) else { continue }
                        let featureIndex = rowStart + sideHandFeaturesStart + 2 * jointNumber
                        featureValues[featureIndex] = (pointX[flatIndex(frame: frameIndex, point: jointPoint)] - wristX) / handSize
                        featureValues[featureIndex + 1] = (pointY[flatIndex(frame: frameIndex, point: jointPoint)] - wristY) / handSize
                    }
                }
                featureValues[rowStart + sideWristFeaturesStart] = (wristX - centreX[frameIndex]) / bodySize
                featureValues[rowStart + sideWristFeaturesStart + 1] = (wristY - centreY[frameIndex]) / bodySize
            }
        }

        let bodyStart = SignLandmarkLayout.bodyPointRange.lowerBound
        for frameIndex in 0..<frameCount {
            let rowStart = frameIndex * featureCount
            for bodyNumber in 0..<bodyPointCount {
                let bodyPoint = bodyStart + bodyNumber
                guard pointIsSeen(frame: frameIndex, point: bodyPoint) else { continue }
                let featureIndex = rowStart + bodyFeaturesStart + 2 * bodyNumber
                featureValues[featureIndex] = (pointX[flatIndex(frame: frameIndex, point: bodyPoint)] - centreX[frameIndex]) / bodySize
                featureValues[featureIndex + 1] = (pointY[flatIndex(frame: frameIndex, point: bodyPoint)] - centreY[frameIndex]) / bodySize
            }
            featureValues[rowStart + rightHandSeenFeature] = rightHandSeen[frameIndex] ? 1 : 0
            featureValues[rowStart + leftHandSeenFeature] = leftHandSeen[frameIndex] ? 1 : 0
            featureValues[rowStart + bothShouldersSeenFeature] = bothShouldersSeen[frameIndex] ? 1 : 0
        }

        // Rounded to Float once, at the end, as Python's `astype(np.float32)`.
        let roundedValues = featureValues.map { Float($0) }
        return SignFeatureClip(
            frameCount: frameCount,
            values: roundedValues,
            handSize: handSize,
            bodySize: bodySize,
            handSizeIsDegenerate: handSizeIsDegenerate
        )
    }

    // MARK: Thinning and padding

    /// Which frames to keep when `frameCount` frames are thinned evenly to `targetFrameCount` (SPEC section 3,
    /// "Order"): frame k is `floor(k × (T − 1) / (N − 1) + 0.5)`, done in whole numbers exactly as Python does, so
    /// the first and last frames are always kept. A stretch that already fits keeps every frame.
    public static func evenlyThinnedFrameIndices(frameCount: Int, targetFrameCount: Int) -> [Int] {
        if frameCount <= targetFrameCount {
            return Array(0..<max(frameCount, 0))
        }
        if targetFrameCount <= 0 {
            return []
        }
        if targetFrameCount == 1 {
            return [0]
        }
        let span = targetFrameCount - 1
        var keptFrameIndices: [Int] = []
        keptFrameIndices.reserveCapacity(targetFrameCount)
        for outputPosition in 0..<targetFrameCount {
            keptFrameIndices.append((2 * outputPosition * (frameCount - 1) + span) / (2 * span))
        }
        return keptFrameIndices
    }

    /// SPEC section 4: a longer stretch is thinned evenly, a shorter one padded with zeros at the end. Returns
    /// `targetFrameCount × 117` values (row-major) and a mask of 1 for each real frame and 0 for padding.
    public static func fitted(_ clip: SignFeatureClip, toFrameCount targetFrameCount: Int) -> (values: [Float], mask: [Float]) {
        let safeTargetFrameCount = max(targetFrameCount, 0)
        var fittedValues = [Float](repeating: 0, count: safeTargetFrameCount * featureCount)
        var frameMask = [Float](repeating: 0, count: safeTargetFrameCount)
        // A clip whose values don't hold all its frames is only read as far as it goes.
        let completeFrameCount = min(clip.frameCount, clip.values.count / featureCount)
        let keptFrameIndices = evenlyThinnedFrameIndices(frameCount: completeFrameCount, targetFrameCount: safeTargetFrameCount)
        for (outputPosition, sourceFrame) in keptFrameIndices.enumerated() {
            let sourceStart = sourceFrame * featureCount
            let outputStart = outputPosition * featureCount
            for featureIndex in 0..<featureCount {
                fittedValues[outputStart + featureIndex] = clip.values[sourceStart + featureIndex]
            }
            frameMask[outputPosition] = 1
        }
        return (values: fittedValues, mask: frameMask)
    }

    // MARK: Statistics, as NumPy does them

    /// NumPy's default ("linear") percentile: sort, rank = p/100 × (n − 1), and go that far between the two
    /// neighbouring values. Nil for no values.
    static func linearPercentile(of values: [Double], percentile: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let sortedValues = values.sorted()
        let rank = (percentile / 100.0) * Double(sortedValues.count - 1)
        let lowerIndex = min(max(Int(rank.rounded(.down)), 0), sortedValues.count - 1)
        let upperIndex = min(lowerIndex + 1, sortedValues.count - 1)
        let fractionOfTheWay = rank - Double(lowerIndex)
        return sortedValues[lowerIndex] + fractionOfTheWay * (sortedValues[upperIndex] - sortedValues[lowerIndex])
    }

    /// The median; with an even count, the mean of the two middle values. Nil for no values.
    static func median(of values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sortedValues = values.sorted()
        let middleIndex = sortedValues.count / 2
        if sortedValues.count % 2 == 1 {
            return sortedValues[middleIndex]
        }
        return (sortedValues[middleIndex - 1] + sortedValues[middleIndex]) / 2.0
    }
}
