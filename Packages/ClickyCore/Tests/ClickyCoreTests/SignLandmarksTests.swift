import Foundation
import Testing
@testable import ClickyCore

/// Sign to text landmarks (Tools/signs/SPEC.md sections 1 and 2): the 61-point layout, which hand is the signer's
/// right, and the `.npy` clip file, all with made-up points (picture coordinates, x right, y down).
struct SignLandmarksTests {
    // MARK: Made-up hands

    /// A hand whose 21 joints sit in a small cluster around its wrist, so its place in the picture is its wrist.
    private static func hand(wristX: Float, wristY: Float, sideGuess: SignHandSideGuess) -> SignSeenHand {
        var jointsByName: [HandJoint: SignPicturePoint] = [:]
        for (jointIndex, joint) in HandJoint.allCases.enumerated() {
            let offset = jointIndex == 0 ? 0 : Float(jointIndex) * 0.002
            jointsByName[joint] = SignPicturePoint(x: wristX + offset, y: wristY - offset)
        }
        return SignSeenHand(jointsByName: jointsByName, sideGuess: sideGuess)
    }

    // MARK: Layout

    @Test func layoutRangesCoverAll61PointsInSpecOrder() {
        #expect(SignLandmarkLayout.pointCount == 61)
        #expect(SignLandmarkLayout.valuesPerFrame == 183)
        #expect(SignLandmarkLayout.rightHandPointRange == 0..<21)
        #expect(SignLandmarkLayout.leftHandPointRange == 21..<42)
        #expect(SignBodyPoint.nose.pointIndex == 42)
        #expect(SignBodyPoint.leftShoulder.pointIndex == 47)
        #expect(SignBodyPoint.rightShoulder.pointIndex == 48)
        #expect(SignBodyPoint.rightHip.pointIndex == 54)
        #expect(SignMouthPoint.leftCorner.pointIndex == 55)
        #expect(SignMouthPoint.lowerLipMiddle.pointIndex == 58)
        #expect(SignBrowPoint.leftBrowMiddle.pointIndex == 59)
        #expect(SignBrowPoint.rightBrowMiddle.pointIndex == 60)
        #expect(SignLandmarkLayout.handPointIndex(side: .right, joint: .wrist) == 0)
        #expect(SignLandmarkLayout.handPointIndex(side: .right, joint: .littleTip) == 20)
        #expect(SignLandmarkLayout.handPointIndex(side: .left, joint: .wrist) == 21)
        #expect(SignLandmarkLayout.handPointIndex(side: .left, joint: .middleMCP) == 30)
    }

    @Test func pointNotSeenIsStoredAsAllZeros() {
        var frame = SignLandmarkFrame()
        frame[SignBodyPoint.nose] = SignLandmarkPoint(x: 0.4, y: 0.3, confidence: 0)
        #expect(frame[SignBodyPoint.nose] == .notSeen)
        frame[SignBodyPoint.nose] = SignLandmarkPoint(x: 0.4, y: 0.3, confidence: 0.9)
        #expect(frame.flatValues[42 * 3] == 0.4)
        #expect(frame.flatValues[42 * 3 + 1] == 0.3)
        #expect(frame.flatValues[42 * 3 + 2] == 0.9)
        frame.setHand(side: .left, jointsByName: [.wrist: SignLandmarkPoint(x: 0.6, y: 0.7, confidence: 0.8)])
        #expect(frame.seenJointCount(side: .left) == 1)
        #expect(frame.seenJointCount(side: .right) == 0)
    }

    // MARK: Sides with a body

    @Test func eachHandGoesToTheNearerBodyWrist() {
        // Facing the camera, the signer's right wrist is on the picture's left.
        let bodyRightWrist = SignPicturePoint(x: 0.3, y: 0.7)
        let bodyLeftWrist = SignPicturePoint(x: 0.7, y: 0.7)
        // Vision's guesses are wrong on purpose: with a body they don't count.
        let hands = [
            Self.hand(wristX: 0.72, wristY: 0.68, sideGuess: .signerRight),
            Self.hand(wristX: 0.31, wristY: 0.69, sideGuess: .signerLeft)
        ]
        let sides = SignHandSides.assignSides(seenHands: hands, bodyRightWrist: bodyRightWrist, bodyLeftWrist: bodyLeftWrist)
        #expect(sides == SignHandSideAssignment(rightHandIndex: 1, leftHandIndex: 0))
    }

    @Test func bothHandsNearerTheSameWristStillTakeDifferentSides() {
        // Both hands are near the signer's right wrist (hands crossed in front of the body); the nearer one keeps
        // the right side and the other takes the left.
        let bodyRightWrist = SignPicturePoint(x: 0.3, y: 0.7)
        let bodyLeftWrist = SignPicturePoint(x: 0.8, y: 0.7)
        let hands = [
            Self.hand(wristX: 0.42, wristY: 0.66, sideGuess: .unknown),
            Self.hand(wristX: 0.33, wristY: 0.70, sideGuess: .unknown)
        ]
        let sides = SignHandSides.assignSides(seenHands: hands, bodyRightWrist: bodyRightWrist, bodyLeftWrist: bodyLeftWrist)
        #expect(sides == SignHandSideAssignment(rightHandIndex: 1, leftHandIndex: 0))
    }

    @Test func theNearestPairWinsEvenWhenItIsTheOtherSide() {
        // Hand 0 is a little nearer the right wrist than the left, but hand 1 sits right on the left wrist: that pair
        // is nearest, so hand 1 is the left and hand 0 the right.
        let bodyRightWrist = SignPicturePoint(x: 0.3, y: 0.7)
        let bodyLeftWrist = SignPicturePoint(x: 0.7, y: 0.7)
        let hands = [
            Self.hand(wristX: 0.48, wristY: 0.7, sideGuess: .unknown),
            Self.hand(wristX: 0.7, wristY: 0.7, sideGuess: .unknown)
        ]
        let sides = SignHandSides.assignSides(seenHands: hands, bodyRightWrist: bodyRightWrist, bodyLeftWrist: bodyLeftWrist)
        #expect(sides == SignHandSideAssignment(rightHandIndex: 0, leftHandIndex: 1))
    }

    @Test func oneHandWithABodyGoesToItsNearerWrist() {
        let sides = SignHandSides.assignSides(
            seenHands: [Self.hand(wristX: 0.66, wristY: 0.5, sideGuess: .signerRight)],
            bodyRightWrist: SignPicturePoint(x: 0.3, y: 0.7),
            bodyLeftWrist: SignPicturePoint(x: 0.7, y: 0.6)
        )
        #expect(sides == SignHandSideAssignment(rightHandIndex: nil, leftHandIndex: 0))
    }

    @Test func distancesCountTheWidePictureXAsWider() {
        // In a 16:9 picture a step of 0.1 across is longer than 0.1 down. The hand is 0.1 across from the right wrist
        // and 0.12 down from the left: square, the right is nearer; at 16:9, the left is.
        let bodyRightWrist = SignPicturePoint(x: 0.4, y: 0.5)
        let bodyLeftWrist = SignPicturePoint(x: 0.5, y: 0.38)
        let hands = [Self.hand(wristX: 0.5, wristY: 0.5, sideGuess: .unknown)]
        let squareSides = SignHandSides.assignSides(seenHands: hands, bodyRightWrist: bodyRightWrist, bodyLeftWrist: bodyLeftWrist)
        let wideSides = SignHandSides.assignSides(seenHands: hands, bodyRightWrist: bodyRightWrist, bodyLeftWrist: bodyLeftWrist, pictureWidthOverHeight: 16.0 / 9.0)
        #expect(squareSides.rightHandIndex == 0)
        #expect(wideSides.leftHandIndex == 0)
    }

    @Test func oneBodyWristSendsTheNearerOfTwoHandsToItsSide() {
        let hands = [
            Self.hand(wristX: 0.3, wristY: 0.6, sideGuess: .unknown),
            Self.hand(wristX: 0.7, wristY: 0.6, sideGuess: .unknown)
        ]
        let sides = SignHandSides.assignSides(seenHands: hands, bodyRightWrist: nil, bodyLeftWrist: SignPicturePoint(x: 0.32, y: 0.6))
        #expect(sides == SignHandSideAssignment(rightHandIndex: 1, leftHandIndex: 0))
    }

    // MARK: Sides without a body

    @Test func withoutABodyVisionsDifferingGuessesAreUsed() {
        let hands = [
            Self.hand(wristX: 0.3, wristY: 0.6, sideGuess: .signerLeft),
            Self.hand(wristX: 0.7, wristY: 0.6, sideGuess: .signerRight)
        ]
        let sides = SignHandSides.assignSides(seenHands: hands, bodyRightWrist: nil, bodyLeftWrist: nil)
        #expect(sides == SignHandSideAssignment(rightHandIndex: 1, leftHandIndex: 0))
    }

    @Test func withoutABodyTheSameGuessTwiceFallsBackToThePicture() {
        let hands = [
            Self.hand(wristX: 0.7, wristY: 0.6, sideGuess: .signerRight),
            Self.hand(wristX: 0.3, wristY: 0.6, sideGuess: .signerRight)
        ]
        let sides = SignHandSides.assignSides(seenHands: hands, bodyRightWrist: nil, bodyLeftWrist: nil)
        // The hand further to the picture's left is the signer's right.
        #expect(sides == SignHandSideAssignment(rightHandIndex: 1, leftHandIndex: 0))
    }

    @Test func withoutABodyAnUnknownGuessFallsBackToThePicture() {
        let hands = [
            Self.hand(wristX: 0.25, wristY: 0.6, sideGuess: .unknown),
            Self.hand(wristX: 0.6, wristY: 0.6, sideGuess: .signerRight)
        ]
        let sides = SignHandSides.assignSides(seenHands: hands, bodyRightWrist: nil, bodyLeftWrist: nil)
        #expect(sides == SignHandSideAssignment(rightHandIndex: 0, leftHandIndex: 1))
    }

    @Test func withoutABodyOneHandFollowsItsGuessOrItsHalfOfThePicture() {
        let guessedLeft = SignHandSides.assignSides(seenHands: [Self.hand(wristX: 0.2, wristY: 0.5, sideGuess: .signerLeft)], bodyRightWrist: nil, bodyLeftWrist: nil)
        #expect(guessedLeft == SignHandSideAssignment(rightHandIndex: nil, leftHandIndex: 0))
        let unknownOnPictureLeft = SignHandSides.assignSides(seenHands: [Self.hand(wristX: 0.2, wristY: 0.5, sideGuess: .unknown)], bodyRightWrist: nil, bodyLeftWrist: nil)
        #expect(unknownOnPictureLeft == SignHandSideAssignment(rightHandIndex: 0, leftHandIndex: nil))
        let unknownOnPictureRight = SignHandSides.assignSides(seenHands: [Self.hand(wristX: 0.8, wristY: 0.5, sideGuess: .unknown)], bodyRightWrist: nil, bodyLeftWrist: nil)
        #expect(unknownOnPictureRight == SignHandSideAssignment(rightHandIndex: nil, leftHandIndex: 0))
        let noHands = SignHandSides.assignSides(seenHands: [], bodyRightWrist: nil, bodyLeftWrist: nil)
        #expect(noHands == SignHandSideAssignment(rightHandIndex: nil, leftHandIndex: nil))
    }

    @Test func aHandWithAHiddenWristIsPlacedByItsOtherJoints() {
        var handWithoutWrist = Self.hand(wristX: 0.7, wristY: 0.6, sideGuess: .unknown)
        handWithoutWrist.jointsByName[.wrist] = nil
        let place = handWithoutWrist.placeInPicture
        #expect(abs(place.x - 0.72) < 0.01)
        let sides = SignHandSides.assignSides(
            seenHands: [handWithoutWrist],
            bodyRightWrist: SignPicturePoint(x: 0.3, y: 0.6),
            bodyLeftWrist: SignPicturePoint(x: 0.7, y: 0.6)
        )
        #expect(sides.leftHandIndex == 0)
    }

    // MARK: .npy files

    @Test func headerIsByteForByteWhatNumPyWrites() {
        // np.save(f, np.zeros((2, 61, 3), np.float32)) with NumPy 2.0.2 writes exactly these 128 bytes.
        let dictionaryText = "{'descr': '<f4', 'fortran_order': False, 'shape': (2, 61, 3), }"
        var expectedHeader: [UInt8] = [0x93, 0x4E, 0x55, 0x4D, 0x50, 0x59, 0x01, 0x00, 0x76, 0x00]
        expectedHeader += Array(dictionaryText.utf8)
        expectedHeader += [UInt8](repeating: 0x20, count: 127 - expectedHeader.count)
        expectedHeader.append(0x0A)

        let header = SignLandmarkClipFile.headerBytes(frameCount: 2)
        #expect(header.count == 128)
        #expect(header == expectedHeader)
        for frameCount in [0, 1, 96, 123_456] {
            #expect(SignLandmarkClipFile.headerBytes(frameCount: frameCount).count % 64 == 0)
        }
    }

    @Test func dataIsLittleEndianFloat32InCOrder() {
        var frame = SignLandmarkFrame()
        frame[0] = SignLandmarkPoint(x: 1.0, y: 0.5, confidence: 0.25)
        let data = SignLandmarkClipFile.fileData(frames: [frame])
        #expect(data.count == 128 + 183 * 4)
        // 1.0f = 0x3F800000, 0.5f = 0x3F000000, 0.25f = 0x3E800000, lowest byte first.
        #expect(Array(data[128..<140]) == [0x00, 0x00, 0x80, 0x3F, 0x00, 0x00, 0x00, 0x3F, 0x00, 0x00, 0x80, 0x3E])
    }

    @Test func clipFileRoundTrips() throws {
        var frames: [SignLandmarkFrame] = []
        for frameIndex in 0..<3 {
            var frame = SignLandmarkFrame()
            frame.setHandJoint(side: .right, joint: .indexTip, point: SignLandmarkPoint(x: 0.1 * Float(frameIndex + 1), y: 0.2, confidence: 0.9))
            frame[SignBodyPoint.rightShoulder] = SignLandmarkPoint(x: 0.35, y: 0.55, confidence: 0.75)
            frame[SignBrowPoint.rightBrowMiddle] = SignLandmarkPoint(x: 0.45, y: 0.2, confidence: 1)
            frames.append(frame)
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("sign-landmarks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let fileURL = folder.appendingPathComponent("clip.npy")

        try SignLandmarkClipFile.write(frames: frames, to: fileURL)
        #expect(try SignLandmarkClipFile.read(from: fileURL) == frames)
        // Writing again replaces the file and leaves no partial file behind.
        try SignLandmarkClipFile.write(frames: Array(frames.prefix(1)), to: fileURL)
        #expect(try SignLandmarkClipFile.read(from: fileURL).count == 1)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["clip.npy"])

        let emptyURL = folder.appendingPathComponent("empty.npy")
        try SignLandmarkClipFile.write(frames: [], to: emptyURL)
        #expect(try SignLandmarkClipFile.read(from: emptyURL).isEmpty)
    }

    @Test func readingRejectsTheWrongShapeAndShortData() {
        // The same header with 60 points a frame instead of 61 (same length, so only the shape is wrong).
        var wrongShapeData = SignLandmarkClipFile.fileData(frames: [SignLandmarkFrame()])
        let shapeRange = wrongShapeData.range(of: Data("(1, 61, 3)".utf8))!
        wrongShapeData.replaceSubrange(shapeRange, with: Data("(1, 60, 3)".utf8))
        #expect(throws: SignLandmarkClipFileError.wrongShape("1,60,3")) { try SignLandmarkClipFile.frames(fromFileData: wrongShapeData) }

        let shortData = SignLandmarkClipFile.fileData(frames: [SignLandmarkFrame()]).dropLast(4)
        #expect(throws: SignLandmarkClipFileError.truncatedData(expectedByteCount: 732, actualByteCount: 728)) {
            try SignLandmarkClipFile.frames(fromFileData: Data(shortData))
        }
        #expect(throws: SignLandmarkClipFileError.notAnNpyFile) { try SignLandmarkClipFile.frames(fromFileData: Data("hello world".utf8)) }
    }
}
