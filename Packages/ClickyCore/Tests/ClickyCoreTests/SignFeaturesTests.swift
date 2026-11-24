import Foundation
import Testing
@testable import ClickyCore

/// Sign to text features (Tools/signs/SPEC.md section 3): Swift must make the same 117 numbers a frame as
/// `Tools/signs/signs/features.py`, checked against the golden files Python wrote, plus trimming, thinning and padding.
struct SignFeaturesTests {
    // MARK: Golden files

    /// This file is `<repo>/Packages/ClickyCore/Tests/ClickyCoreTests/SignFeaturesTests.swift`: the repo is four
    /// folders above the one it is in.
    static let goldenFolder = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // ClickyCoreTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // ClickyCore
        .deletingLastPathComponent()  // Packages
        .deletingLastPathComponent()  // the repo
        .appendingPathComponent("Tools/signs/tests/golden")

    /// One golden file, as `signs/make_golden.py` writes it.
    private struct GoldenFeatureFile: Decodable {
        let name: String
        let width: Double
        let height: Double
        let handSize: Double
        let handSizeIsDegenerate: Bool
        let bodySize: Double
        let landmarks: [[[Double]]]
        let features: [[Double]]

        enum CodingKeys: String, CodingKey {
            case name
            case width
            case height
            case handSize = "hand_size"
            case handSizeIsDegenerate = "hand_size_is_degenerate"
            case bodySize = "body_size"
            case landmarks
            case features
        }
    }

    /// The files round sizes to 6 decimals, so up to 5e-7 off is only rounding; past that, 1e-6 of the size.
    private static func sizesAgree(_ swiftSize: Double, _ pythonSize: Double) -> Bool {
        abs(swiftSize - pythonSize) <= 1e-6 + 1e-6 * abs(pythonSize)
    }

    /// A readable name for a feature column, for failure messages.
    private static func featureColumnName(_ featureIndex: Int) -> String {
        switch featureIndex {
        case 0..<42: return "right hand joint \(featureIndex / 2) \(featureIndex % 2 == 0 ? "x" : "y")"
        case 42..<84: return "left hand joint \((featureIndex - 42) / 2) \(featureIndex % 2 == 0 ? "x" : "y")"
        case 84..<86: return "right wrist \(featureIndex == 84 ? "x" : "y")"
        case 86..<88: return "left wrist \(featureIndex == 86 ? "x" : "y")"
        case 88..<114: return "body point \((featureIndex - 88) / 2) \(featureIndex % 2 == 0 ? "x" : "y")"
        case 114: return "right hand seen"
        case 115: return "left hand seen"
        case 116: return "both shoulders seen"
        default: return "column \(featureIndex)"
        }
    }

    @Test func swiftMakesTheSameFeaturesAsPythonForEveryGoldenFile() throws {
        let goldenFileURLs = try FileManager.default
            .contentsOfDirectory(at: Self.goldenFolder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        #expect(goldenFileURLs.count >= 8, "expected the golden files in \(Self.goldenFolder.path)")

        for goldenFileURL in goldenFileURLs {
            let fileName = goldenFileURL.lastPathComponent
            let golden = try JSONDecoder().decode(GoldenFeatureFile.self, from: Data(contentsOf: goldenFileURL))

            var frames: [SignLandmarkFrame] = []
            for (frameIndex, framePoints) in golden.landmarks.enumerated() {
                let flatValues: [Float] = framePoints.flatMap { point in point.map { Float($0) } }
                guard let frame = SignLandmarkFrame(flatValues: flatValues) else {
                    Issue.record("\(fileName) frame \(frameIndex): \(flatValues.count) landmark values, not 183")
                    continue
                }
                frames.append(frame)
            }

            let clip = SignFeatures.featureClip(of: frames, pictureWidth: golden.width, pictureHeight: golden.height)
            #expect(clip.frameCount == golden.features.count, "\(fileName): frame count")
            #expect(clip.values.count == golden.features.count * SignFeatures.featureCount, "\(fileName): value count")
            #expect(clip.handSizeIsDegenerate == golden.handSizeIsDegenerate, "\(fileName): hand size degenerate")
            #expect(Self.sizesAgree(clip.handSize, golden.handSize), "\(fileName): hand size Swift \(clip.handSize), Python \(golden.handSize)")
            #expect(Self.sizesAgree(clip.bodySize, golden.bodySize), "\(fileName): body size Swift \(clip.bodySize), Python \(golden.bodySize)")

            var differences: [String] = []
            for (frameIndex, expectedRow) in golden.features.enumerated() where frameIndex < clip.frameCount {
                if expectedRow.count != SignFeatures.featureCount {
                    differences.append("\(fileName) frame \(frameIndex): the file has \(expectedRow.count) features")
                    continue
                }
                for (featureIndex, expectedValue) in expectedRow.enumerated() {
                    let swiftValue = Double(clip[frame: frameIndex, feature: featureIndex])
                    if !(abs(swiftValue - expectedValue) <= 2e-5) {
                        differences.append(
                            "\(fileName) frame \(frameIndex) feature \(featureIndex) (\(Self.featureColumnName(featureIndex))): Swift \(swiftValue), Python \(expectedValue)"
                        )
                    }
                }
            }
            #expect(differences.isEmpty, "\(differences.count) differences:\n\(differences.prefix(30).joined(separator: "\n"))")
        }
    }

    // MARK: Made-up frames

    /// A right (or left) hand with every joint seen, wrist at the given place, joints spread a little upward.
    private static func frameWithHand(side: SignSide, wristX: Float, wristY: Float, otherJointsSeen: Int = 20, marker: Float = 0) -> SignLandmarkFrame {
        var frame = SignLandmarkFrame()
        for (jointNumber, joint) in HandJoint.allCases.enumerated() {
            let isSeen = jointNumber == 0 || jointNumber <= otherJointsSeen
            guard isSeen else { continue }
            let offset = Float(jointNumber) * 0.003
            frame.setHandJoint(side: side, joint: joint, point: SignLandmarkPoint(x: wristX + offset, y: wristY - offset, confidence: 0.9))
        }
        frame[SignBodyPoint.nose] = SignLandmarkPoint(x: 0.5, y: 0.3, confidence: 0.8 + marker)
        return frame
    }

    private static func frameWithoutHands(marker: Float = 0) -> SignLandmarkFrame {
        var frame = SignLandmarkFrame()
        frame[SignBodyPoint.nose] = SignLandmarkPoint(x: 0.5, y: 0.3, confidence: 0.8 + marker)
        return frame
    }

    // MARK: Seen hands and trimming

    @Test func aHandNeedsItsWristAndElevenOtherJoints() {
        #expect(SignFeatures.handIsSeen(in: Self.frameWithHand(side: .right, wristX: 0.4, wristY: 0.5), side: .right))
        #expect(!SignFeatures.handIsSeen(in: Self.frameWithHand(side: .right, wristX: 0.4, wristY: 0.5), side: .left))
        #expect(SignFeatures.handIsSeen(in: Self.frameWithHand(side: .left, wristX: 0.6, wristY: 0.5, otherJointsSeen: 11), side: .left))
        #expect(!SignFeatures.handIsSeen(in: Self.frameWithHand(side: .left, wristX: 0.6, wristY: 0.5, otherJointsSeen: 10), side: .left))

        // Twenty joints but no wrist is not a seen hand.
        var frameWithoutWrist = Self.frameWithHand(side: .right, wristX: 0.4, wristY: 0.5)
        frameWithoutWrist.setHandJoint(side: .right, joint: .wrist, point: .notSeen)
        #expect(!SignFeatures.handIsSeen(in: frameWithoutWrist, side: .right))
    }

    @Test func trimmingDropsFramesWithoutAHandAtBothEndsOnly() {
        let frames = [
            Self.frameWithoutHands(marker: 0.01),
            Self.frameWithHand(side: .right, wristX: 0.4, wristY: 0.5, otherJointsSeen: 10, marker: 0.02),  // too few joints
            Self.frameWithHand(side: .right, wristX: 0.4, wristY: 0.5, marker: 0.03),
            Self.frameWithoutHands(marker: 0.04),  // inside: kept
            Self.frameWithHand(side: .left, wristX: 0.6, wristY: 0.5, marker: 0.05),
            Self.frameWithoutHands(marker: 0.06),
            Self.frameWithoutHands(marker: 0.07)
        ]
        let trimmedFrames = SignFeatures.trimmingFramesWithoutHands(frames)
        #expect(trimmedFrames == Array(frames[2...4]))
    }

    @Test func trimmingKeepsAStretchWithNoHandWhole() {
        let frames = [Self.frameWithoutHands(marker: 0.01), Self.frameWithoutHands(marker: 0.02)]
        #expect(SignFeatures.trimmingFramesWithoutHands(frames) == frames)
        #expect(SignFeatures.trimmingFramesWithoutHands([]).isEmpty)
    }

    // MARK: Thinning and padding

    @Test func thinningKeepsEvenlySpreadFramesWithTheEndsIncluded() {
        #expect(SignFeatures.evenlyThinnedFrameIndices(frameCount: 10, targetFrameCount: 4) == [0, 3, 6, 9])
        // floor(1 × 3 / 2 + 0.5) = 2: a half rounds up, never to even.
        #expect(SignFeatures.evenlyThinnedFrameIndices(frameCount: 4, targetFrameCount: 3) == [0, 2, 3])
        #expect(SignFeatures.evenlyThinnedFrameIndices(frameCount: 7, targetFrameCount: 2) == [0, 6])
        #expect(SignFeatures.evenlyThinnedFrameIndices(frameCount: 10, targetFrameCount: 1) == [0])
        #expect(Array(SignFeatures.evenlyThinnedFrameIndices(frameCount: 300, targetFrameCount: 96).prefix(5)) == [0, 3, 6, 9, 13])

        let thinnedTo96 = SignFeatures.evenlyThinnedFrameIndices(frameCount: 100, targetFrameCount: 96)
        #expect(thinnedTo96.count == 96)
        #expect(thinnedTo96.first == 0)
        #expect(thinnedTo96.last == 99)
        #expect(zip(thinnedTo96, thinnedTo96.dropFirst()).allSatisfy { $0 < $1 })
    }

    @Test func thinningLeavesAnEqualOrShorterStretchAsItIs() {
        #expect(SignFeatures.evenlyThinnedFrameIndices(frameCount: 5, targetFrameCount: 5) == [0, 1, 2, 3, 4])
        #expect(SignFeatures.evenlyThinnedFrameIndices(frameCount: 3, targetFrameCount: 5) == [0, 1, 2])
        #expect(SignFeatures.evenlyThinnedFrameIndices(frameCount: 0, targetFrameCount: 5) == [])
        #expect(SignFeatures.evenlyThinnedFrameIndices(frameCount: 4, targetFrameCount: 0) == [])
    }

    /// A clip whose every number in frame k is k + 1, so rows can be told apart.
    private static func numberedClip(frameCount: Int) -> SignFeatureClip {
        var values: [Float] = []
        for frameIndex in 0..<frameCount {
            values += [Float](repeating: Float(frameIndex + 1), count: SignFeatures.featureCount)
        }
        return SignFeatureClip(frameCount: frameCount, values: values, handSize: 1, bodySize: 1, handSizeIsDegenerate: false)
    }

    @Test func fittingPadsAShortClipWithZerosAndMasksThePadding() {
        let fitted = SignFeatures.fitted(Self.numberedClip(frameCount: 3), toFrameCount: 5)
        #expect(fitted.values.count == 5 * 117)
        #expect(fitted.mask == [1, 1, 1, 0, 0])
        #expect(fitted.values[0] == 1)
        #expect(fitted.values[116] == 1)
        #expect(fitted.values[117] == 2)
        #expect(fitted.values[2 * 117 + 116] == 3)
        #expect(fitted.values[(3 * 117)...].allSatisfy { $0 == 0 })
    }

    @Test func fittingThinsALongClipToTheChosenRows() {
        let fitted = SignFeatures.fitted(Self.numberedClip(frameCount: 10), toFrameCount: 4)
        #expect(fitted.values.count == 4 * 117)
        #expect(fitted.mask == [1, 1, 1, 1])
        // Rows 0, 3, 6 and 9, numbered 1, 4, 7 and 10.
        #expect(fitted.values[0] == 1)
        #expect(fitted.values[117] == 4)
        #expect(fitted.values[2 * 117 + 50] == 7)
        #expect(fitted.values[3 * 117 + 116] == 10)

        let sameLength = SignFeatures.fitted(Self.numberedClip(frameCount: 4), toFrameCount: 4)
        #expect(sameLength.values == Self.numberedClip(frameCount: 4).values)
        #expect(sameLength.mask == [1, 1, 1, 1])
    }

    // MARK: Features on made-up frames

    @Test func percentileAndMedianFollowNumPy() {
        // Rank 0.9 × 4 = 3.6: 60% of the way from 4 to 5.
        #expect(abs((SignFeatures.linearPercentile(of: [5, 1, 4, 2, 3], percentile: 90) ?? 0) - 4.6) < 1e-12)
        #expect(SignFeatures.linearPercentile(of: [0.2], percentile: 90) == 0.2)
        #expect(SignFeatures.linearPercentile(of: [], percentile: 90) == nil)
        #expect(SignFeatures.median(of: [4, 1, 3, 2]) == 2.5)
        #expect(SignFeatures.median(of: [3, 1, 2]) == 2)
        #expect(SignFeatures.median(of: []) == nil)
    }

    @Test func anEmptyStretchHasNoFeatures() {
        let clip = SignFeatures.featureClip(of: [], pictureWidth: 640, pictureHeight: 480)
        #expect(clip.frameCount == 0)
        #expect(clip.values.isEmpty)
        #expect(clip.handSizeIsDegenerate)
        #expect(clip.handSize == 1)
        #expect(clip.bodySize == 3.5)
    }

    @Test func aHandAloneIsMeasuredFromItsWristAndTheMedianWrist() {
        // One frame, a right hand with its middle knuckle 0.05 above the wrist, no body, unknown picture size.
        var frame = SignLandmarkFrame()
        for joint in HandJoint.allCases {
            frame.setHandJoint(side: .right, joint: joint, point: SignLandmarkPoint(x: 0.4, y: 0.5, confidence: 0.9))
        }
        frame.setHandJoint(side: .right, joint: .middleMCP, point: SignLandmarkPoint(x: 0.4, y: 0.45, confidence: 0.9))
        let clip = SignFeatures.featureClip(of: [frame], pictureWidth: 0, pictureHeight: 0)
        #expect(!clip.handSizeIsDegenerate)
        #expect(abs(clip.handSize - 0.05) < 1e-6)
        #expect(abs(clip.bodySize - 0.175) < 1e-6)
        // The middle knuckle (joint 9) is one hand size straight up.
        #expect(abs(clip[frame: 0, feature: 2 * 9 + 1] + 1) < 1e-5)
        #expect(clip[frame: 0, feature: 2 * 9] == 0)
        // The only wrist is the centre, so the wrist features are zero; the flags say right hand only.
        #expect(clip[frame: 0, feature: SignFeatures.rightWristFeaturesStart] == 0)
        #expect(clip[frame: 0, feature: SignFeatures.rightHandSeenFeature] == 1)
        #expect(clip[frame: 0, feature: SignFeatures.leftHandSeenFeature] == 0)
        #expect(clip[frame: 0, feature: SignFeatures.bothShouldersSeenFeature] == 0)
    }
}
