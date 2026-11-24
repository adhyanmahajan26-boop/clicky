import Foundation
import Testing
@testable import ClickyCore

/// Sign to text: landmarks at another frame rate are brought to 30 a second (Tools/signs/SPEC.md section 3,
/// "Frame rate"), checked against the examples Python wrote and with small cases worked out by hand.
struct SignFrameRateTests {
    // MARK: Golden files

    /// This file is `<repo>/Packages/ClickyCore/Tests/ClickyCoreTests/SignFrameRateTests.swift`: the repo is four
    /// folders above the one it is in.
    static let goldenFolder = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // ClickyCoreTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // ClickyCore
        .deletingLastPathComponent()  // Packages
        .deletingLastPathComponent()  // the repo
        .appendingPathComponent("Tools/signs/tests/golden/frame_rate")

    /// One example, as the Python side writes it.
    private struct GoldenFrameRateFile: Decodable {
        let name: String
        let description: String
        let times: [Double]
        let landmarks: [[[Double]]]
        let resampled: [[[Double]]]
    }

    private static func frames(from landmarkValues: [[[Double]]], fileName: String) -> [SignLandmarkFrame] {
        var frames: [SignLandmarkFrame] = []
        for (frameIndex, framePoints) in landmarkValues.enumerated() {
            let flatValues: [Float] = framePoints.flatMap { point in point.map { Float($0) } }
            guard let frame = SignLandmarkFrame(flatValues: flatValues) else {
                Issue.record("\(fileName) frame \(frameIndex): \(flatValues.count) landmark values, not 183")
                continue
            }
            frames.append(frame)
        }
        return frames
    }

    @Test func swiftBringsFramesTo30TheSameWayAsPythonForEveryGoldenFile() throws {
        let goldenFileURLs: [URL]
        do {
            goldenFileURLs = try FileManager.default
                .contentsOfDirectory(at: Self.goldenFolder, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "json" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
        } catch {
            Issue.record("No frame-rate golden folder at \(Self.goldenFolder.path): the Python side writes its examples there (SPEC section 3, \"Frame rate\"). \(error)")
            return
        }
        guard !goldenFileURLs.isEmpty else {
            Issue.record("No frame-rate golden files in \(Self.goldenFolder.path): the Python side writes its examples there (SPEC section 3, \"Frame rate\"), and this test has nothing to check until it does.")
            return
        }

        for goldenFileURL in goldenFileURLs {
            let fileName = goldenFileURL.lastPathComponent
            let golden = try JSONDecoder().decode(GoldenFrameRateFile.self, from: Data(contentsOf: goldenFileURL))
            let inputFrames = Self.frames(from: golden.landmarks, fileName: fileName)
            let expectedFrames = Self.frames(from: golden.resampled, fileName: fileName)
            #expect(inputFrames.count == golden.times.count, "\(fileName): \(golden.times.count) times for \(inputFrames.count) frames")

            let swiftResult = SignFrameRate.broughtTo30(frames: inputFrames, times: golden.times)
            guard swiftResult.frames.count == expectedFrames.count else {
                Issue.record("\(fileName) (\(golden.description)): Swift made \(swiftResult.frames.count) frames, Python \(expectedFrames.count)")
                continue
            }

            var firstDifference: String?
            var differenceCount = 0
            for frameIndex in expectedFrames.indices {
                let swiftValues = swiftResult.frames[frameIndex].flatValues
                let pythonValues = expectedFrames[frameIndex].flatValues
                for valueIndex in pythonValues.indices where abs(swiftValues[valueIndex] - pythonValues[valueIndex]) > 1e-4 {
                    differenceCount += 1
                    if firstDifference == nil {
                        let pointIndex = valueIndex / SignLandmarkLayout.valuesPerPoint
                        let valueName = ["x", "y", "confidence"][valueIndex % SignLandmarkLayout.valuesPerPoint]
                        firstDifference = "frame \(frameIndex) point \(pointIndex) \(valueName): Swift \(swiftValues[valueIndex]), Python \(pythonValues[valueIndex])"
                    }
                }
            }
            #expect(differenceCount == 0, "\(fileName) (\(golden.description)): \(differenceCount) values differ by more than 1e-4, first at \(firstDifference ?? "-")")
        }
    }

    // MARK: Worked by hand

    private static func frame(points: [Int: SignLandmarkPoint]) -> SignLandmarkFrame {
        var frame = SignLandmarkFrame()
        for (pointIndex, point) in points {
            frame[pointIndex] = point
        }
        return frame
    }

    @Test func theRateIsFramesLessOneOverTheTimeTheyTake() {
        #expect(SignFrameRate.framesPerSecond(times: [0, 0.04, 0.08]) == 25)
        #expect(SignFrameRate.framesPerSecond(times: [1]) == nil)
        #expect(SignFrameRate.framesPerSecond(times: [1, 1]) == nil)
        #expect(SignFrameRate.needsBringingTo30(times: (0..<10).map { Double($0) / 30 }) == false)
        #expect(SignFrameRate.needsBringingTo30(times: (0..<10).map { Double($0) / 28 }) == false)
        #expect(SignFrameRate.needsBringingTo30(times: (0..<10).map { Double($0) / 25 }) == true)
        #expect(SignFrameRate.needsBringingTo30(times: (0..<10).map { Double($0) / 60 }) == true)
    }

    @Test func framesBetween27And33ASecondComeBackUnchanged() {
        let frames = (0..<5).map { frameNumber in
            Self.frame(points: [0: SignLandmarkPoint(x: Float(frameNumber) / 10, y: 0.5, confidence: 0.9)])
        }
        let times = (0..<5).map { Double($0) / 31 }
        let result = SignFrameRate.broughtTo30(frames: frames, times: times)
        #expect(result.frames == frames)
        #expect(result.times == times)
    }

    @Test func aPointSeenInBothFramesMovesAlongTheLineWithTheSmallerConfidence() {
        // 25 a second: frames at 0, 0.04 and 0.08 s become frames at 0, 1/30 and 2/30 s (3/30 is past the end).
        let frames = [
            Self.frame(points: [
                0: SignLandmarkPoint(x: 0.0, y: 0.2, confidence: 0.9),
                1: SignLandmarkPoint(x: 0.3, y: 0.3, confidence: 0.8)
            ]),
            Self.frame(points: [
                0: SignLandmarkPoint(x: 0.6, y: 0.8, confidence: 0.7)
            ]),
            Self.frame(points: [
                0: SignLandmarkPoint(x: 0.6, y: 0.8, confidence: 0.7)
            ])
        ]
        let result = SignFrameRate.broughtTo30(frames: frames, times: [0, 0.04, 0.08])
        #expect(result.frames.count == 3)
        #expect(result.times.count == 3)
        guard result.frames.count == 3 else { return }
        #expect(result.frames[0] == frames[0])
        // 1/30 s is 5/6 of the way from frame 0 to frame 1.
        let movedPoint = result.frames[1][0]
        #expect(abs(movedPoint.x - 0.5) < 1e-6)
        #expect(abs(movedPoint.y - 0.7) < 1e-6)
        #expect(movedPoint.confidence == 0.7)
        // Point 1 is seen only in frame 0; frame 1 is nearer, so it is copied from there: not seen.
        #expect(result.frames[1][1] == .notSeen)
    }

    @Test func aPointSeenInOneFrameIsCopiedFromTheNearerFrame() {
        // 20 a second: frames at 0 and 0.05 s; new frames at 0, 1/30 (2/3 of the way) and nothing past 0.05.
        let frames = [
            Self.frame(points: [5: SignLandmarkPoint(x: 0.1, y: 0.1, confidence: 0.9)]),
            Self.frame(points: [6: SignLandmarkPoint(x: 0.4, y: 0.4, confidence: 0.6)])
        ]
        let result = SignFrameRate.broughtTo30(frames: frames, times: [0, 0.05])
        #expect(result.frames.count == 2)
        guard result.frames.count == 2 else { return }
        #expect(result.frames[1][5] == .notSeen)
        #expect(result.frames[1][6] == SignLandmarkPoint(x: 0.4, y: 0.4, confidence: 0.6))
    }

    @Test func aSlowStretchBecomesThirtyFramesASecondUpToItsLastFrame() {
        // 15 frames a second for one second (frames 0…15): 31 frames at 30 a second, the last exactly on the last frame.
        let frames = (0...15).map { frameNumber in
            Self.frame(points: [0: SignLandmarkPoint(x: Float(frameNumber) / 15, y: 0.5, confidence: 1)])
        }
        let times = (0...15).map { Double($0) / 15 }
        let result = SignFrameRate.broughtTo30(frames: frames, times: times)
        #expect(result.frames.count == 31)
        #expect(abs((result.times.last ?? 0) - 1) < 1e-9)
        #expect(abs((result.frames.last?[0].x ?? 0) - 1) < 1e-6)
        // Halfway between frames 0 and 1.
        #expect(abs(result.frames[1][0].x - 0.5 / 15) < 1e-6)
    }

    @Test func tooFewFramesOrMismatchedTimesComeBackAsTheyAre() {
        let oneFrame = [Self.frame(points: [0: SignLandmarkPoint(x: 0.1, y: 0.1, confidence: 1)])]
        #expect(SignFrameRate.broughtTo30(frames: oneFrame, times: [3]).frames == oneFrame)
        #expect(SignFrameRate.broughtTo30(frames: [], times: []).frames.isEmpty)
        let mismatched = SignFrameRate.broughtTo30(frames: oneFrame + oneFrame, times: [0])
        #expect(mismatched.frames.count == 2)
        #expect(mismatched.times.count == 2)
    }
}
