//
//  SignLandmarks.swift
//  ClickyCore
//
//  Sign to text, step one: the landmarks of one camera frame (61 points), which hand is the signer's right,
//  and the `.npy` file a clip of frames is kept in. `Tools/signs/SPEC.md` sections 1 and 2 are the contract;
//  the training code (Python) reads exactly what is written here.
//
//  Pure Foundation on purpose: no Vision here, so every rule is tested with made-up points. The Vision side is
//  `Sources/sign-extract` (and later the app's camera).
//

import Foundation

// MARK: - Layout

/// Where each point lives in a frame's 61 points (SPEC section 1).
public enum SignLandmarkLayout {
    public static let pointCount = 61
    /// x, y and confidence.
    public static let valuesPerPoint = 3
    public static let valuesPerFrame = pointCount * valuesPerPoint

    /// The 21 hand joints in `HandJoint.allCases` order (wrist, thumb CMC … little tip), the same as MediaPipe's 0–20.
    public static let rightHandPointRange = 0..<21
    public static let leftHandPointRange = 21..<42
    public static let bodyPointRange = 42..<55
    public static let mouthPointRange = 55..<59
    public static let browPointRange = 59..<61

    public static func handPointRange(for side: SignSide) -> Range<Int> {
        side == .right ? rightHandPointRange : leftHandPointRange
    }

    /// The point index of one joint of the signer's `side` hand.
    public static func handPointIndex(side: SignSide, joint: HandJoint) -> Int {
        handPointRange(for: side).lowerBound + handJointOrder.firstIndex(of: joint)!
    }

    /// The hand joints in the order they are stored.
    public static let handJointOrder: [HandJoint] = HandJoint.allCases
}

/// The signer's own right or left (never the picture's).
public enum SignSide: String, CaseIterable, Sendable {
    case right
    case left

    public var other: SignSide { self == .right ? .left : .right }
}

/// The 13 body points, in stored order (points 42–54). Left and right are the signer's own.
public enum SignBodyPoint: Int, CaseIterable, Sendable {
    case nose
    case leftEye, rightEye
    case leftEar, rightEar
    case leftShoulder, rightShoulder
    case leftElbow, rightElbow
    case leftWrist, rightWrist
    case leftHip, rightHip

    public var pointIndex: Int { SignLandmarkLayout.bodyPointRange.lowerBound + rawValue }
}

/// The 4 mouth points (55–58): the signer's left and right corner, then the middle of the upper and lower lip's outer edge.
public enum SignMouthPoint: Int, CaseIterable, Sendable {
    case leftCorner
    case rightCorner
    case upperLipMiddle
    case lowerLipMiddle

    public var pointIndex: Int { SignLandmarkLayout.mouthPointRange.lowerBound + rawValue }
}

/// The 2 brow points (59–60): the middle of the signer's left brow, then of the right brow.
public enum SignBrowPoint: Int, CaseIterable, Sendable {
    case leftBrowMiddle
    case rightBrowMiddle

    public var pointIndex: Int { SignLandmarkLayout.browPointRange.lowerBound + rawValue }
}

// MARK: - Points and frames

/// One landmark: x to the right and y DOWN, both 0–1 of the picture. Confidence 0 means not seen (and then x = y = 0).
public struct SignLandmarkPoint: Equatable, Sendable {
    public var x: Float
    public var y: Float
    public var confidence: Float

    public init(x: Float, y: Float, confidence: Float) {
        self.x = x
        self.y = y
        self.confidence = confidence
    }

    public static let notSeen = SignLandmarkPoint(x: 0, y: 0, confidence: 0)

    public var isSeen: Bool { confidence > 0 }
}

/// One frame's 61 points as a flat `[Float]` of 183 (x, y, confidence per point), the same bytes the `.npy` holds.
public struct SignLandmarkFrame: Equatable, Sendable {
    public private(set) var flatValues: [Float]

    /// A frame where nothing was seen.
    public init() {
        flatValues = [Float](repeating: 0, count: SignLandmarkLayout.valuesPerFrame)
    }

    /// A frame from 183 stored values; nil when the count is wrong.
    public init?(flatValues: [Float]) {
        guard flatValues.count == SignLandmarkLayout.valuesPerFrame else { return nil }
        self.flatValues = flatValues
    }

    /// Reading gives the stored point; writing a point that isn't seen stores 0, 0, 0 so "not seen" is always all zeros.
    public subscript(pointIndex: Int) -> SignLandmarkPoint {
        get {
            let firstValueIndex = pointIndex * SignLandmarkLayout.valuesPerPoint
            return SignLandmarkPoint(
                x: flatValues[firstValueIndex],
                y: flatValues[firstValueIndex + 1],
                confidence: flatValues[firstValueIndex + 2]
            )
        }
        set {
            let firstValueIndex = pointIndex * SignLandmarkLayout.valuesPerPoint
            let storedPoint = newValue.isSeen ? newValue : .notSeen
            flatValues[firstValueIndex] = storedPoint.x
            flatValues[firstValueIndex + 1] = storedPoint.y
            flatValues[firstValueIndex + 2] = storedPoint.confidence
        }
    }

    public func handJoint(side: SignSide, joint: HandJoint) -> SignLandmarkPoint {
        self[SignLandmarkLayout.handPointIndex(side: side, joint: joint)]
    }

    public mutating func setHandJoint(side: SignSide, joint: HandJoint, point: SignLandmarkPoint) {
        self[SignLandmarkLayout.handPointIndex(side: side, joint: joint)] = point
    }

    /// Stores a whole hand: joints missing from `jointsByName` are stored as not seen.
    public mutating func setHand(side: SignSide, jointsByName: [HandJoint: SignLandmarkPoint]) {
        for joint in SignLandmarkLayout.handJointOrder {
            setHandJoint(side: side, joint: joint, point: jointsByName[joint] ?? .notSeen)
        }
    }

    public func seenJointCount(side: SignSide) -> Int {
        SignLandmarkLayout.handPointRange(for: side).filter { self[$0].isSeen }.count
    }

    public subscript(bodyPoint: SignBodyPoint) -> SignLandmarkPoint {
        get { self[bodyPoint.pointIndex] }
        set { self[bodyPoint.pointIndex] = newValue }
    }

    public subscript(mouthPoint: SignMouthPoint) -> SignLandmarkPoint {
        get { self[mouthPoint.pointIndex] }
        set { self[mouthPoint.pointIndex] = newValue }
    }

    public subscript(browPoint: SignBrowPoint) -> SignLandmarkPoint {
        get { self[browPoint.pointIndex] }
        set { self[browPoint.pointIndex] = newValue }
    }
}

// MARK: - Which hand is which

/// Vision's own guess at a hand's side, already turned into the signer's terms by whoever called Vision.
public enum SignHandSideGuess: Sendable {
    case signerRight
    case signerLeft
    case unknown
}

/// A point in picture coordinates, 0–1, x right, y down.
public struct SignPicturePoint: Equatable, Sendable {
    public var x: Float
    public var y: Float

    public init(x: Float, y: Float) {
        self.x = x
        self.y = y
    }
}

/// One hand Vision found: its seen joints (picture coordinates) and Vision's guess at its side.
public struct SignSeenHand: Equatable, Sendable {
    public var jointsByName: [HandJoint: SignPicturePoint]
    public var sideGuess: SignHandSideGuess

    public init(jointsByName: [HandJoint: SignPicturePoint], sideGuess: SignHandSideGuess) {
        self.jointsByName = jointsByName
        self.sideGuess = sideGuess
    }

    /// Where the hand is: its wrist, or (when the wrist itself wasn't seen) the middle of the joints that were,
    /// so a hand with a hidden wrist can still be matched to a body wrist.
    public var placeInPicture: SignPicturePoint {
        if let wrist = jointsByName[.wrist] { return wrist }
        let seenJoints = Array(jointsByName.values)
        guard !seenJoints.isEmpty else { return SignPicturePoint(x: 0.5, y: 0.5) }
        let totalX = seenJoints.reduce(Float(0)) { $0 + $1.x }
        let totalY = seenJoints.reduce(Float(0)) { $0 + $1.y }
        return SignPicturePoint(x: totalX / Float(seenJoints.count), y: totalY / Float(seenJoints.count))
    }
}

/// Which of the seen hands (by index into the input) is the signer's right and which the left; nil for a side no hand took.
public struct SignHandSideAssignment: Equatable, Sendable {
    public var rightHandIndex: Int?
    public var leftHandIndex: Int?

    public init(rightHandIndex: Int?, leftHandIndex: Int?) {
        self.rightHandIndex = rightHandIndex
        self.leftHandIndex = leftHandIndex
    }

    public func handIndex(for side: SignSide) -> Int? {
        side == .right ? rightHandIndex : leftHandIndex
    }
}

/// SPEC section 2: decides which hand is the signer's right. The app and the extractor both call this, so the
/// landmarks the models were trained on and the ones the camera makes always agree.
public enum SignHandSides {
    /// - Parameters:
    ///   - seenHands: up to two hands (more are ignored past the first two).
    ///   - bodyRightWrist / bodyLeftWrist: the body's wrists (signer's sides) when the body pose saw them.
    ///   - pictureWidthOverHeight: so distances count x and y the same in a picture that isn't square.
    public static func assignSides(
        seenHands: [SignSeenHand],
        bodyRightWrist: SignPicturePoint?,
        bodyLeftWrist: SignPicturePoint?,
        pictureWidthOverHeight: Float = 1
    ) -> SignHandSideAssignment {
        let handsToPlace = Array(seenHands.prefix(2))
        if handsToPlace.isEmpty { return SignHandSideAssignment(rightHandIndex: nil, leftHandIndex: nil) }

        func distanceInPicture(_ firstPoint: SignPicturePoint, _ secondPoint: SignPicturePoint) -> Float {
            let horizontalDistance = (firstPoint.x - secondPoint.x) * pictureWidthOverHeight
            let verticalDistance = firstPoint.y - secondPoint.y
            return (horizontalDistance * horizontalDistance + verticalDistance * verticalDistance).squareRoot()
        }

        // With both body wrists: every (hand, side) pair has a distance; the nearest pair wins and the other hand
        // (if any) takes the side left over, so two hands both nearer one wrist still end up on different sides.
        if let bodyRightWrist, let bodyLeftWrist {
            var nearestPair: (handIndex: Int, side: SignSide, distance: Float)?
            for (handIndex, hand) in handsToPlace.enumerated() {
                for (side, bodyWrist) in [(SignSide.right, bodyRightWrist), (SignSide.left, bodyLeftWrist)] {
                    let distance = distanceInPicture(hand.placeInPicture, bodyWrist)
                    if nearestPair == nil || distance < nearestPair!.distance {
                        nearestPair = (handIndex, side, distance)
                    }
                }
            }
            let winningPair = nearestPair!
            let otherHandIndex: Int? = handsToPlace.count == 2 ? 1 - winningPair.handIndex : nil
            return assignment(winningHandIndex: winningPair.handIndex, winningSide: winningPair.side, otherHandIndex: otherHandIndex)
        }

        // With one body wrist and two hands: the hand nearer that wrist takes its side, the other hand the other side.
        // (With one body wrist and one hand there is nothing to compare against, so Vision's guess decides below.)
        if handsToPlace.count == 2, let onlyBodyWrist = bodyRightWrist ?? bodyLeftWrist {
            let onlyBodyWristSide: SignSide = bodyRightWrist != nil ? .right : .left
            let firstHandDistance = distanceInPicture(handsToPlace[0].placeInPicture, onlyBodyWrist)
            let secondHandDistance = distanceInPicture(handsToPlace[1].placeInPicture, onlyBodyWrist)
            let nearerHandIndex = firstHandDistance <= secondHandDistance ? 0 : 1
            return assignment(winningHandIndex: nearerHandIndex, winningSide: onlyBodyWristSide, otherHandIndex: 1 - nearerHandIndex)
        }

        // No body: Vision's own guess, unless it is unknown or gives both hands the same side. Then the picture
        // decides: facing an unmirrored camera, the signer's right hand is on the picture's left.
        if handsToPlace.count == 1 {
            switch handsToPlace[0].sideGuess {
            case .signerRight: return SignHandSideAssignment(rightHandIndex: 0, leftHandIndex: nil)
            case .signerLeft: return SignHandSideAssignment(rightHandIndex: nil, leftHandIndex: 0)
            case .unknown:
                // One hand and no other clue: the picture's left half is the signer's right.
                let isOnPictureLeft = handsToPlace[0].placeInPicture.x < 0.5
                return isOnPictureLeft
                    ? SignHandSideAssignment(rightHandIndex: 0, leftHandIndex: nil)
                    : SignHandSideAssignment(rightHandIndex: nil, leftHandIndex: 0)
            }
        }

        let firstGuess = handsToPlace[0].sideGuess
        let secondGuess = handsToPlace[1].sideGuess
        let guessesAreUsable = firstGuess != .unknown && secondGuess != .unknown && firstGuess != secondGuess
        if guessesAreUsable {
            return firstGuess == .signerRight
                ? SignHandSideAssignment(rightHandIndex: 0, leftHandIndex: 1)
                : SignHandSideAssignment(rightHandIndex: 1, leftHandIndex: 0)
        }
        let firstHandIsFurtherLeftInPicture = handsToPlace[0].placeInPicture.x <= handsToPlace[1].placeInPicture.x
        return firstHandIsFurtherLeftInPicture
            ? SignHandSideAssignment(rightHandIndex: 0, leftHandIndex: 1)
            : SignHandSideAssignment(rightHandIndex: 1, leftHandIndex: 0)
    }

    private static func assignment(winningHandIndex: Int, winningSide: SignSide, otherHandIndex: Int?) -> SignHandSideAssignment {
        var result = SignHandSideAssignment(rightHandIndex: nil, leftHandIndex: nil)
        if winningSide == .right {
            result.rightHandIndex = winningHandIndex
            result.leftHandIndex = otherHandIndex
        } else {
            result.leftHandIndex = winningHandIndex
            result.rightHandIndex = otherHandIndex
        }
        return result
    }
}

// MARK: - Clip files

public enum SignLandmarkClipFileError: Error, Equatable {
    case notAnNpyFile
    case unsupportedVersion(major: UInt8)
    case unreadableHeader(String)
    case wrongShape(String)
    case truncatedData(expectedByteCount: Int, actualByteCount: Int)
}

/// A clip on disk: `[T, 61, 3]` float32 as a NumPy `.npy` file (format 1.0, little-endian, C order). The header is
/// written byte for byte the way NumPy 2's `np.save` writes it (including its spare room after the frame count),
/// so a file from here and one from Python can be compared with `cmp`.
public enum SignLandmarkClipFile {
    private static let magicBytes: [UInt8] = [0x93, 0x4E, 0x55, 0x4D, 0x50, 0x59]  // "\x93NUMPY"
    /// NumPy lines the data up on 64 bytes.
    private static let headerAlignment = 64
    /// NumPy leaves room for the first dimension to grow to 21 digits without rewriting the header.
    private static let spareDigitsForFrameCount = 21

    /// The full header (magic, version, length and the padded dictionary) for a clip of `frameCount` frames.
    public static func headerBytes(frameCount: Int) -> [UInt8] {
        var dictionaryText = "{'descr': '<f4', 'fortran_order': False, 'shape': (\(frameCount), \(SignLandmarkLayout.pointCount), \(SignLandmarkLayout.valuesPerPoint)), }"
        dictionaryText += String(repeating: " ", count: max(0, spareDigitsForFrameCount - String(frameCount).count))
        // 6 magic + 2 version + 2 length bytes come first; the dictionary ends with a newline.
        let bytesBeforeDictionary = magicBytes.count + 2 + 2
        let unpaddedLength = dictionaryText.utf8.count + 1
        let paddingLength = headerAlignment - ((bytesBeforeDictionary + unpaddedLength) % headerAlignment)
        let dictionaryLength = unpaddedLength + paddingLength

        var header = magicBytes
        header += [1, 0]
        header += [UInt8(dictionaryLength & 0xFF), UInt8((dictionaryLength >> 8) & 0xFF)]
        header += Array(dictionaryText.utf8)
        header += [UInt8](repeating: 0x20, count: paddingLength)
        header.append(0x0A)
        return header
    }

    /// The whole file's bytes.
    public static func fileData(frames: [SignLandmarkFrame]) -> Data {
        var data = Data(headerBytes(frameCount: frames.count))
        data.reserveCapacity(data.count + frames.count * SignLandmarkLayout.valuesPerFrame * 4)
        for frame in frames {
            // Float32 bits written little-endian explicitly, so the file is the same on any machine.
            for value in frame.flatValues {
                var littleEndianBits = value.bitPattern.littleEndian
                withUnsafeBytes(of: &littleEndianBits) { data.append(contentsOf: $0) }
            }
        }
        return data
    }

    /// Writes the clip through a temporary file and a rename, so a half-written clip never looks finished
    /// (the extractor skips clips whose `.npy` exists).
    public static func write(frames: [SignLandmarkFrame], to fileURL: URL) throws {
        let temporaryURL = fileURL.deletingLastPathComponent()
            .appendingPathComponent(".\(fileURL.lastPathComponent).\(UUID().uuidString).partial")
        try fileData(frames: frames).write(to: temporaryURL)
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try FileManager.default.removeItem(at: fileURL)
        }
        try FileManager.default.moveItem(at: temporaryURL, to: fileURL)
    }

    public static func read(from fileURL: URL) throws -> [SignLandmarkFrame] {
        try frames(fromFileData: Data(contentsOf: fileURL))
    }

    /// Reads format 1.0 (and 2.0, which only has a longer length field) `<f4` C-order `[T, 61, 3]` files.
    public static func frames(fromFileData fileData: Data) throws -> [SignLandmarkFrame] {
        let bytes = [UInt8](fileData)
        guard bytes.count >= 10, Array(bytes[0..<6]) == magicBytes else { throw SignLandmarkClipFileError.notAnNpyFile }
        let majorVersion = bytes[6]
        let dictionaryStart: Int
        let dictionaryLength: Int
        switch majorVersion {
        case 1:
            dictionaryStart = 10
            dictionaryLength = Int(bytes[8]) | Int(bytes[9]) << 8
        case 2, 3:
            guard bytes.count >= 12 else { throw SignLandmarkClipFileError.notAnNpyFile }
            dictionaryStart = 12
            dictionaryLength = Int(bytes[8]) | Int(bytes[9]) << 8 | Int(bytes[10]) << 16 | Int(bytes[11]) << 24
        default:
            throw SignLandmarkClipFileError.unsupportedVersion(major: majorVersion)
        }
        guard bytes.count >= dictionaryStart + dictionaryLength,
              let dictionaryText = String(bytes: bytes[dictionaryStart..<(dictionaryStart + dictionaryLength)], encoding: .isoLatin1)
        else { throw SignLandmarkClipFileError.unreadableHeader("header runs past the end") }

        let compactText = dictionaryText.replacingOccurrences(of: " ", with: "")
        guard compactText.contains("'descr':'<f4'") else { throw SignLandmarkClipFileError.unreadableHeader("not little-endian float32: \(dictionaryText)") }
        guard compactText.contains("'fortran_order':False") else { throw SignLandmarkClipFileError.unreadableHeader("not C order: \(dictionaryText)") }
        guard let shapeStart = compactText.range(of: "'shape':("),
              let shapeEnd = compactText[shapeStart.upperBound...].firstIndex(of: ")")
        else { throw SignLandmarkClipFileError.unreadableHeader("no shape: \(dictionaryText)") }
        let shapeSizes = compactText[shapeStart.upperBound..<shapeEnd].split(separator: ",").compactMap { Int($0) }
        guard shapeSizes.count == 3, shapeSizes[1] == SignLandmarkLayout.pointCount, shapeSizes[2] == SignLandmarkLayout.valuesPerPoint
        else { throw SignLandmarkClipFileError.wrongShape(String(compactText[shapeStart.upperBound..<shapeEnd])) }

        let frameCount = shapeSizes[0]
        let dataStart = dictionaryStart + dictionaryLength
        let expectedByteCount = frameCount * SignLandmarkLayout.valuesPerFrame * 4
        guard bytes.count - dataStart >= expectedByteCount else {
            throw SignLandmarkClipFileError.truncatedData(expectedByteCount: expectedByteCount, actualByteCount: bytes.count - dataStart)
        }

        var frames: [SignLandmarkFrame] = []
        frames.reserveCapacity(frameCount)
        for frameIndex in 0..<frameCount {
            let frameByteStart = dataStart + frameIndex * SignLandmarkLayout.valuesPerFrame * 4
            var frameValues = [Float](repeating: 0, count: SignLandmarkLayout.valuesPerFrame)
            for valueIndex in 0..<SignLandmarkLayout.valuesPerFrame {
                let valueByteStart = frameByteStart + valueIndex * 4
                let littleEndianBits = UInt32(bytes[valueByteStart])
                    | UInt32(bytes[valueByteStart + 1]) << 8
                    | UInt32(bytes[valueByteStart + 2]) << 16
                    | UInt32(bytes[valueByteStart + 3]) << 24
                frameValues[valueIndex] = Float(bitPattern: littleEndianBits)
            }
            frames.append(SignLandmarkFrame(flatValues: frameValues)!)
        }
        return frames
    }
}
