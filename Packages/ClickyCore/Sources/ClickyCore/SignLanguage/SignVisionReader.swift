//
//  SignVisionReader.swift
//  ClickyCore
//
//  Sign to text, step one with a real picture: one upright picture in, one `SignLandmarkFrame` out
//  (Tools/signs/SPEC.md sections 1 and 2), with Apple Vision. The app's camera and the tools (`sign-eval`, and later
//  `sign-extract`) all use this one reader, so the models train on exactly what the app sees.
//
//  Made from `sign-extract`'s VisionLandmarkReader, with the body pose always on the padded canvas, as SPEC section
//  1 says the app does. Which side is which, checked on a Mac (macOS 27) with five real signing videos (Wikimedia
//  Commons, people facing an unmirrored camera, 1,713 frames):
//  - Body joints are named for the PERSON: `.leftShoulder` was on the picture's right in 100% of frames. They map
//    straight across to the signer's sides.
//  - Face landmarks are named by the PICTURE: `leftEyebrow` and `leftEye` were on the picture's left (the signer's
//    right) in 100% of frames. They are swapped to the signer's sides below.
//  - A hand's `chirality` is named for the person: `.left` matched the hand the body wrists made the signer's left
//    on 2,093 of 2,138 hands (98%). It is only a guess for `SignHandSides`, which uses it when no body wrist is seen.
//
//  Also here: reading a video file frame by frame into landmarks with their times (`SignVideoLandmarks`), for
//  `sign-eval video` and the debug inbox's `handSigns {action: signsFeed}`.
//

import AVFoundation
import CoreGraphics
import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import ImageIO
import Vision

// MARK: - One picture

/// Holds its own Vision requests (they keep state), so one reader is used from one queue at a time and never
/// shared between threads. Not tied to the main actor: the camera calls it on its own frame queue.
public final class SignVisionReader {
    /// A Vision joint (hand, body) under this confidence counts as not seen (SPEC section 1).
    public static let leastSeenJointConfidence: Float = 0.3
    /// A hand with fewer seen joints than this is dropped: too little of it to be useful, and often a false hand.
    public static let fewestSeenJointsForAHand = 12
    /// The padded canvas for the body pose (SPEC section 1): the picture shrunk to at most this many pixels on its
    /// long side, at the top middle of a mid-grey canvas this many times as wide and as tall.
    public static let longestSideForBodyPose: CGFloat = 640
    public static let canvasWidthPerPictureWidth: CGFloat = 2
    public static let canvasHeightPerPictureHeight: CGFloat = 1.6

    /// Whether the mouth and brows are read too (points 55–60). They are kept in the landmarks but are not features yet.
    public let readsFace: Bool

    private let handPoseRequest: VNDetectHumanHandPoseRequest
    private let bodyPoseRequest: VNDetectHumanBodyPoseRequest
    private let faceLandmarksRequest: VNDetectFaceLandmarksRequest?

    public init(readsFace: Bool) {
        self.readsFace = readsFace
        handPoseRequest = VNDetectHumanHandPoseRequest()
        handPoseRequest.maximumHandCount = 2
        bodyPoseRequest = VNDetectHumanBodyPoseRequest()
        faceLandmarksRequest = readsFace ? VNDetectFaceLandmarksRequest() : nil
    }

    /// The upright picture's size for a stored picture of `storedWidth × storedHeight` shown with `orientation`.
    public static func uprightSize(storedWidth: Int, storedHeight: Int, orientation: CGImagePropertyOrientation) -> (width: Int, height: Int) {
        let quarterTurnOrientations: [CGImagePropertyOrientation] = [.left, .right, .leftMirrored, .rightMirrored]
        return quarterTurnOrientations.contains(orientation)
            ? (width: storedHeight, height: storedWidth)
            : (width: storedWidth, height: storedHeight)
    }

    /// A camera or video frame. `orientation` is the one that makes the picture upright (`.up` for a Mac camera);
    /// the camera picture must not be mirrored (SPEC: "from an unmirrored picture").
    public func readLandmarks(pixelBuffer: CVPixelBuffer, orientation: CGImagePropertyOrientation) throws -> SignLandmarkFrame {
        let requestHandler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: orientation, options: [:])
        let uprightPicture = CIImage(cvPixelBuffer: pixelBuffer).oriented(orientation)
        return try readLandmarks(requestHandler: requestHandler, uprightPicture: uprightPicture)
    }

    /// A still picture (tools, tests).
    public func readLandmarks(cgImage: CGImage, orientation: CGImagePropertyOrientation = .up) throws -> SignLandmarkFrame {
        let requestHandler = VNImageRequestHandler(cgImage: cgImage, orientation: orientation, options: [:])
        let uprightPicture = CIImage(cgImage: cgImage).oriented(orientation)
        return try readLandmarks(requestHandler: requestHandler, uprightPicture: uprightPicture)
    }

    /// A picture already in Core Image (tools, tests).
    public func readLandmarks(ciImage: CIImage, orientation: CGImagePropertyOrientation = .up) throws -> SignLandmarkFrame {
        let requestHandler = VNImageRequestHandler(ciImage: ciImage, orientation: orientation, options: [:])
        let uprightPicture = ciImage.oriented(orientation)
        return try readLandmarks(requestHandler: requestHandler, uprightPicture: uprightPicture)
    }

    /// Hands and face from the picture itself (the handler carries the orientation, so points come back in the
    /// upright picture); the body from the padded canvas.
    private func readLandmarks(requestHandler: VNImageRequestHandler, uprightPicture: CIImage) throws -> SignLandmarkFrame {
        let uprightWidth = uprightPicture.extent.width
        let uprightHeight = uprightPicture.extent.height
        let pictureWidthOverHeight = uprightHeight > 0 ? Float(uprightWidth / uprightHeight) : 1

        var requests: [VNRequest] = [handPoseRequest]
        if let faceLandmarksRequest { requests.append(faceLandmarksRequest) }
        try requestHandler.perform(requests)

        let pictureLocationFromCanvasLocation = try runBodyPoseOnPaddedCanvas(uprightPicture: uprightPicture)

        var frame = SignLandmarkFrame()
        let bodyPoints = biggestPersonBodyPoints(pictureLocationFromCanvasLocation: pictureLocationFromCanvasLocation)
        for (bodyPoint, landmarkPoint) in bodyPoints {
            frame[bodyPoint] = landmarkPoint
        }

        let seenHands = seenHandsWithConfidences()
        let bodyRightWrist = bodyPoints[.rightWrist].map { SignPicturePoint(x: $0.x, y: $0.y) }
        let bodyLeftWrist = bodyPoints[.leftWrist].map { SignPicturePoint(x: $0.x, y: $0.y) }
        let sides = SignHandSides.assignSides(
            seenHands: seenHands.map { $0.seenHand },
            bodyRightWrist: bodyRightWrist,
            bodyLeftWrist: bodyLeftWrist,
            pictureWidthOverHeight: pictureWidthOverHeight
        )
        for side in SignSide.allCases {
            guard let handIndex = sides.handIndex(for: side) else { continue }
            frame.setHand(side: side, jointsByName: seenHands[handIndex].landmarkPointsByJoint)
        }

        if faceLandmarksRequest != nil {
            writeMouthAndBrows(into: &frame)
        }
        return frame
    }

    // MARK: Hands

    private struct SeenHandWithConfidences {
        var seenHand: SignSeenHand
        var landmarkPointsByJoint: [HandJoint: SignLandmarkPoint]
    }

    private func seenHandsWithConfidences() -> [SeenHandWithConfidences] {
        let observations = handPoseRequest.results ?? []
        return observations.compactMap { observation in
            guard let recognizedPoints = try? observation.recognizedPoints(.all) else { return nil }
            var picturePointsByJoint: [HandJoint: SignPicturePoint] = [:]
            var landmarkPointsByJoint: [HandJoint: SignLandmarkPoint] = [:]
            for (joint, visionJointName) in SignVisionJointNames.hand {
                guard let recognizedPoint = recognizedPoints[visionJointName],
                      recognizedPoint.confidence >= Self.leastSeenJointConfidence
                else { continue }
                let point = SignVisionGeometry.picturePoint(fromVisionLocation: recognizedPoint.location)
                picturePointsByJoint[joint] = point
                landmarkPointsByJoint[joint] = SignLandmarkPoint(x: point.x, y: point.y, confidence: recognizedPoint.confidence)
            }
            guard picturePointsByJoint.count >= Self.fewestSeenJointsForAHand else { return nil }
            let sideGuess: SignHandSideGuess
            switch observation.chirality {
            case .left: sideGuess = .signerLeft
            case .right: sideGuess = .signerRight
            default: sideGuess = .unknown
            }
            return SeenHandWithConfidences(
                seenHand: SignSeenHand(jointsByName: picturePointsByJoint, sideGuess: sideGuess),
                landmarkPointsByJoint: landmarkPointsByJoint
            )
        }
    }

    // MARK: Body

    /// SPEC section 1: Vision's body pose finds nobody in a close head-and-shoulders picture (a laptop camera at arm's
    /// length), but finds the same person once they look smaller in a bigger picture. So the upright picture is
    /// shrunk to at most 640 pixels on its long side and put at the top middle of a mid-grey canvas twice as wide and
    /// 1.6 times as tall. Returns how to turn a Vision location on the canvas back into one on the picture (both
    /// 0–1, y up).
    private func runBodyPoseOnPaddedCanvas(uprightPicture: CIImage) throws -> (CGPoint) -> CGPoint {
        let longestSide = max(uprightPicture.extent.width, uprightPicture.extent.height)
        let shrinkScale = min(1, Self.longestSideForBodyPose / max(longestSide, 1))
        let picture = uprightPicture
            .transformed(by: CGAffineTransform(translationX: -uprightPicture.extent.minX, y: -uprightPicture.extent.minY))
            .transformed(by: CGAffineTransform(scaleX: shrinkScale, y: shrinkScale))
        let pictureWidth = picture.extent.width
        let pictureHeight = picture.extent.height
        let canvasWidth = (pictureWidth * Self.canvasWidthPerPictureWidth).rounded()
        let canvasHeight = (pictureHeight * Self.canvasHeightPerPictureHeight).rounded()
        let pictureOffsetX = ((canvasWidth - pictureWidth) / 2).rounded()
        // Core Image's y is up, so this puts the picture at the top of the canvas (the lower body would be below it).
        let pictureOffsetY = canvasHeight - pictureHeight
        let canvasRectangle = CGRect(x: 0, y: 0, width: canvasWidth, height: canvasHeight)
        let greyCanvas = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5)).cropped(to: canvasRectangle)
        let paddedPicture = picture
            .transformed(by: CGAffineTransform(translationX: pictureOffsetX, y: pictureOffsetY))
            .composited(over: greyCanvas)
        try VNImageRequestHandler(ciImage: paddedPicture, options: [:]).perform([bodyPoseRequest])
        let safePictureWidth = max(pictureWidth, 1)
        let safePictureHeight = max(pictureHeight, 1)
        return { canvasLocation in
            CGPoint(
                x: (canvasLocation.x * canvasWidth - pictureOffsetX) / safePictureWidth,
                y: (canvasLocation.y * canvasHeight - pictureOffsetY) / safePictureHeight
            )
        }
    }

    /// The body points of the person whose seen points cover the most picture (the signer is nearly always the
    /// biggest person; a small one in the background is ignored). A point that lands outside the picture (possible
    /// with the padded canvas) counts as not seen, since landmarks are 0–1 of the picture.
    private func biggestPersonBodyPoints(pictureLocationFromCanvasLocation: (CGPoint) -> CGPoint) -> [SignBodyPoint: SignLandmarkPoint] {
        var biggestPersonPoints: [SignBodyPoint: SignLandmarkPoint] = [:]
        var biggestPersonArea: Float = -1
        for observation in bodyPoseRequest.results ?? [] {
            guard let recognizedPoints = try? observation.recognizedPoints(.all) else { continue }
            // The person's size is measured over all their seen joints (knees and ankles too), not only the 13 kept.
            let seenLocations = recognizedPoints.values
                .filter { $0.confidence >= Self.leastSeenJointConfidence }
                .map { $0.location }
            guard !seenLocations.isEmpty else { continue }
            let seenXs = seenLocations.map { $0.x }
            let seenYs = seenLocations.map { $0.y }
            let personWidth = Float((seenXs.max() ?? 0) - (seenXs.min() ?? 0))
            let personHeight = Float((seenYs.max() ?? 0) - (seenYs.min() ?? 0))
            let personArea = personWidth * personHeight
            guard personArea > biggestPersonArea else { continue }
            biggestPersonArea = personArea
            var personPoints: [SignBodyPoint: SignLandmarkPoint] = [:]
            for (bodyPoint, visionJointName) in SignVisionJointNames.body {
                guard let recognizedPoint = recognizedPoints[visionJointName],
                      recognizedPoint.confidence >= Self.leastSeenJointConfidence
                else { continue }
                let pictureLocation = pictureLocationFromCanvasLocation(recognizedPoint.location)
                guard (0...1).contains(pictureLocation.x), (0...1).contains(pictureLocation.y) else { continue }
                let point = SignVisionGeometry.picturePoint(fromVisionLocation: pictureLocation)
                personPoints[bodyPoint] = SignLandmarkPoint(x: point.x, y: point.y, confidence: recognizedPoint.confidence)
            }
            biggestPersonPoints = personPoints
        }
        return biggestPersonPoints
    }

    // MARK: Face

    /// Mouth corners, the middle of each lip's outer edge, and the middle of each brow, from the biggest face
    /// (SPEC section 2's last paragraph). Face points need confidence 0.3 too.
    private func writeMouthAndBrows(into frame: inout SignLandmarkFrame) {
        guard let faceObservations = faceLandmarksRequest?.results, !faceObservations.isEmpty else { return }
        let biggestFace = faceObservations.max { firstFace, secondFace in
            firstFace.boundingBox.width * firstFace.boundingBox.height < secondFace.boundingBox.width * secondFace.boundingBox.height
        }
        guard let biggestFace, let landmarks = biggestFace.landmarks else { return }
        let faceConfidence = biggestFace.confidence
        guard faceConfidence >= Self.leastSeenJointConfidence else { return }

        // Passing a 1 × 1 picture gives each landmark in 0–1 picture coordinates (y up, flipped here).
        func picturePoints(of region: VNFaceLandmarkRegion2D?) -> [SignPicturePoint] {
            guard let region, region.pointCount > 0 else { return [] }
            return region.pointsInImage(imageSize: CGSize(width: 1, height: 1)).map { location in
                SignVisionGeometry.picturePoint(fromVisionLocation: location)
            }
        }

        // Brows and eyes: Vision names the face's parts by the PICTURE (`leftEyebrow` is on the picture's left, which
        // is the signer's right), so they are swapped here. "Middle" of a brow is the average of its points.
        let signerLeftBrowPoints = picturePoints(of: landmarks.rightEyebrow)
        let signerRightBrowPoints = picturePoints(of: landmarks.leftEyebrow)
        if let browMiddle = SignVisionGeometry.averagePoint(of: signerLeftBrowPoints) {
            frame[SignBrowPoint.leftBrowMiddle] = SignLandmarkPoint(x: browMiddle.x, y: browMiddle.y, confidence: faceConfidence)
        }
        if let browMiddle = SignVisionGeometry.averagePoint(of: signerRightBrowPoints) {
            frame[SignBrowPoint.rightBrowMiddle] = SignLandmarkPoint(x: browMiddle.x, y: browMiddle.y, confidence: faceConfidence)
        }

        // Mouth: `outerLips` is one loop with no named corners, so the corners are the two points furthest apart. The
        // corner nearer the signer's right eye is their right corner (this still holds with the head tilted). The lip
        // middles are the loop points nearest the corners' midpoint along the mouth, on the eyes' side (upper) and the
        // chin's side (lower).
        let outerLipPoints = picturePoints(of: landmarks.outerLips)
        guard outerLipPoints.count >= 4,
              let signerRightEye = SignVisionGeometry.averagePoint(of: picturePoints(of: landmarks.leftEye)),
              let signerLeftEye = SignVisionGeometry.averagePoint(of: picturePoints(of: landmarks.rightEye))
        else { return }

        var firstCornerIndex = 0
        var secondCornerIndex = 1
        var largestSquaredDistance: Float = -1
        for firstIndex in outerLipPoints.indices {
            for secondIndex in outerLipPoints.indices where secondIndex > firstIndex {
                let squaredDistance = SignVisionGeometry.squaredDistance(outerLipPoints[firstIndex], outerLipPoints[secondIndex])
                if squaredDistance > largestSquaredDistance {
                    largestSquaredDistance = squaredDistance
                    firstCornerIndex = firstIndex
                    secondCornerIndex = secondIndex
                }
            }
        }
        var signerRightCorner = outerLipPoints[firstCornerIndex]
        var signerLeftCorner = outerLipPoints[secondCornerIndex]
        if SignVisionGeometry.squaredDistance(signerLeftCorner, signerRightEye) < SignVisionGeometry.squaredDistance(signerRightCorner, signerRightEye) {
            swap(&signerRightCorner, &signerLeftCorner)
        }

        let mouthAxisX = signerLeftCorner.x - signerRightCorner.x
        let mouthAxisY = signerLeftCorner.y - signerRightCorner.y
        let mouthAxisSquaredLength = max(mouthAxisX * mouthAxisX + mouthAxisY * mouthAxisY, 1e-12)
        let eyesMiddle = SignPicturePoint(x: (signerRightEye.x + signerLeftEye.x) / 2, y: (signerRightEye.y + signerLeftEye.y) / 2)
        // Which side of the corner-to-corner line the eyes are on: points on that side are the upper lip.
        let eyesSideSign = SignVisionGeometry.sideOfLine(axisStart: signerRightCorner, axisX: mouthAxisX, axisY: mouthAxisY, point: eyesMiddle)

        var upperLipMiddle: SignPicturePoint?
        var lowerLipMiddle: SignPicturePoint?
        var upperLipBestOffset = Float.greatestFiniteMagnitude
        var lowerLipBestOffset = Float.greatestFiniteMagnitude
        for (pointIndex, point) in outerLipPoints.enumerated() where pointIndex != firstCornerIndex && pointIndex != secondCornerIndex {
            // 0 at the right corner, 1 at the left corner; the middle of the lip is nearest 0.5.
            let placeAlongMouth = ((point.x - signerRightCorner.x) * mouthAxisX + (point.y - signerRightCorner.y) * mouthAxisY) / mouthAxisSquaredLength
            let offsetFromMiddle = abs(placeAlongMouth - 0.5)
            let isOnEyesSide = SignVisionGeometry.sideOfLine(axisStart: signerRightCorner, axisX: mouthAxisX, axisY: mouthAxisY, point: point) == eyesSideSign
            if isOnEyesSide, offsetFromMiddle < upperLipBestOffset {
                upperLipBestOffset = offsetFromMiddle
                upperLipMiddle = point
            } else if !isOnEyesSide, offsetFromMiddle < lowerLipBestOffset {
                lowerLipBestOffset = offsetFromMiddle
                lowerLipMiddle = point
            }
        }

        frame[SignMouthPoint.rightCorner] = SignLandmarkPoint(x: signerRightCorner.x, y: signerRightCorner.y, confidence: faceConfidence)
        frame[SignMouthPoint.leftCorner] = SignLandmarkPoint(x: signerLeftCorner.x, y: signerLeftCorner.y, confidence: faceConfidence)
        if let upperLipMiddle {
            frame[SignMouthPoint.upperLipMiddle] = SignLandmarkPoint(x: upperLipMiddle.x, y: upperLipMiddle.y, confidence: faceConfidence)
        }
        if let lowerLipMiddle {
            frame[SignMouthPoint.lowerLipMiddle] = SignLandmarkPoint(x: lowerLipMiddle.x, y: lowerLipMiddle.y, confidence: faceConfidence)
        }
    }
}

// MARK: - Vision's names

enum SignVisionJointNames {
    /// Vision's hand joint names, in stored order (`SignLandmarkLayout.handJointOrder`).
    static let hand: [(HandJoint, VNHumanHandPoseObservation.JointName)] = [
        (.wrist, .wrist),
        (.thumbCMC, .thumbCMC), (.thumbMP, .thumbMP), (.thumbIP, .thumbIP), (.thumbTip, .thumbTip),
        (.indexMCP, .indexMCP), (.indexPIP, .indexPIP), (.indexDIP, .indexDIP), (.indexTip, .indexTip),
        (.middleMCP, .middleMCP), (.middlePIP, .middlePIP), (.middleDIP, .middleDIP), (.middleTip, .middleTip),
        (.ringMCP, .ringMCP), (.ringPIP, .ringPIP), (.ringDIP, .ringDIP), (.ringTip, .ringTip),
        (.littleMCP, .littleMCP), (.littlePIP, .littlePIP), (.littleDIP, .littleDIP), (.littleTip, .littleTip)
    ]

    /// Vision's body joint names for the 13 stored body points. Apple names them for the person, the same as SPEC.
    static let body: [(SignBodyPoint, VNHumanBodyPoseObservation.JointName)] = [
        (.nose, .nose),
        (.leftEye, .leftEye), (.rightEye, .rightEye),
        (.leftEar, .leftEar), (.rightEar, .rightEar),
        (.leftShoulder, .leftShoulder), (.rightShoulder, .rightShoulder),
        (.leftElbow, .leftElbow), (.rightElbow, .rightElbow),
        (.leftWrist, .leftWrist), (.rightWrist, .rightWrist),
        (.leftHip, .leftHip), (.rightHip, .rightHip)
    ]
}

// MARK: - Small geometry

enum SignVisionGeometry {
    /// Vision gives 0–1 with y UP; the landmark files are y DOWN.
    static func picturePoint(fromVisionLocation visionLocation: CGPoint) -> SignPicturePoint {
        SignPicturePoint(x: Float(visionLocation.x), y: Float(1 - visionLocation.y))
    }

    static func averagePoint(of points: [SignPicturePoint]) -> SignPicturePoint? {
        guard !points.isEmpty else { return nil }
        let totalX = points.reduce(Float(0)) { runningTotal, point in runningTotal + point.x }
        let totalY = points.reduce(Float(0)) { runningTotal, point in runningTotal + point.y }
        return SignPicturePoint(x: totalX / Float(points.count), y: totalY / Float(points.count))
    }

    static func squaredDistance(_ firstPoint: SignPicturePoint, _ secondPoint: SignPicturePoint) -> Float {
        let horizontalDistance = firstPoint.x - secondPoint.x
        let verticalDistance = firstPoint.y - secondPoint.y
        return horizontalDistance * horizontalDistance + verticalDistance * verticalDistance
    }

    /// Which side of the line through `axisStart` along (axisX, axisY) a point is on: +1 or -1 (0 on the line).
    static func sideOfLine(axisStart: SignPicturePoint, axisX: Float, axisY: Float, point: SignPicturePoint) -> Int {
        let crossProduct = axisX * (point.y - axisStart.y) - axisY * (point.x - axisStart.x)
        return crossProduct > 0 ? 1 : (crossProduct < 0 ? -1 : 0)
    }
}

// MARK: - A video file

public struct SignVideoLandmarksError: Error, CustomStringConvertible {
    public var description: String
    public init(_ description: String) { self.description = description }
}

/// What a video file is, read before its frames: how to turn it upright, its upright size and its rate. Holds the
/// loaded asset and track, so reading the frames needs no second (deprecated, synchronous) load.
public struct SignVideoTrackInfo {
    public var videoURL: URL
    public var asset: AVURLAsset
    public var videoTrack: AVAssetTrack
    public var uprightOrientation: CGImagePropertyOrientation
    public var uprightWidth: Int
    public var uprightHeight: Int
    /// The rate the file says (0 when it doesn't).
    public var nominalFramesPerSecond: Double
}

/// Reads a video file into landmark frames with their times, as the camera would give them: upright, at most about
/// 30 frames a second (a 60 a second file has every other frame skipped, the way the camera drops late frames).
public enum SignVideoLandmarks {
    /// Frames closer together than this are skipped (a little under 1/30 s, so a 30 a second file keeps every frame).
    public static let shortestGapBetweenReadFrames = 0.8 / 30.0

    /// Loads the track's facts. Async because AVFoundation's loading is.
    public static func loadTrackInfo(videoURL: URL) async throws -> SignVideoTrackInfo {
        let asset = AVURLAsset(url: videoURL)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        guard let videoTrack = videoTracks.first else { throw SignVideoLandmarksError("no video track in \(videoURL.lastPathComponent)") }
        let (naturalSize, preferredTransform, nominalFrameRate) = try await videoTrack.load(.naturalSize, .preferredTransform, .nominalFrameRate)
        let orientation = uprightOrientation(forVideoTransform: preferredTransform)
        let storedWidth = Int(abs(naturalSize.width).rounded())
        let storedHeight = Int(abs(naturalSize.height).rounded())
        let uprightSize = SignVisionReader.uprightSize(storedWidth: storedWidth, storedHeight: storedHeight, orientation: orientation)
        guard uprightSize.width > 0, uprightSize.height > 0 else { throw SignVideoLandmarksError("the video has no picture size") }
        return SignVideoTrackInfo(
            videoURL: videoURL,
            asset: asset,
            videoTrack: videoTrack,
            uprightOrientation: orientation,
            uprightWidth: uprightSize.width,
            uprightHeight: uprightSize.height,
            nominalFramesPerSecond: Double(nominalFrameRate)
        )
    }

    /// Reads every frame (thinned to about 30 a second) through `visionReader` and hands each frame and its time
    /// (seconds from the video's start) to `handleFrame`, in order. Blocks while it reads: call it off the main
    /// thread. Returns how many frames were read.
    @discardableResult
    public static func readFrames(
        trackInfo: SignVideoTrackInfo,
        visionReader: SignVisionReader,
        handleFrame: (SignLandmarkFrame, Double) throws -> Void
    ) throws -> Int {
        let assetReader = try AVAssetReader(asset: trackInfo.asset)
        // Bi-planar 4:2:0 is what the decoder makes anyway and Vision reads it directly, so no colour conversion is paid.
        let trackOutput = AVAssetReaderTrackOutput(track: trackInfo.videoTrack, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        ])
        trackOutput.alwaysCopiesSampleData = false
        guard assetReader.canAdd(trackOutput) else { throw SignVideoLandmarksError("the video track can't be read") }
        assetReader.add(trackOutput)
        guard assetReader.startReading() else {
            throw SignVideoLandmarksError("can't start reading: \(assetReader.error?.localizedDescription ?? "unknown error")")
        }
        defer { if assetReader.status == .reading { assetReader.cancelReading() } }

        var firstFrameTime: Double?
        var lastReadFrameTime: Double?
        var framesRead = 0
        while let sampleBuffer = trackOutput.copyNextSampleBuffer() {
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { continue }
            let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
            guard presentationTime.isFinite else { continue }
            if firstFrameTime == nil { firstFrameTime = presentationTime }
            if let lastReadFrameTime, presentationTime - lastReadFrameTime < shortestGapBetweenReadFrames { continue }
            lastReadFrameTime = presentationTime
            let frame = try autoreleasepool {
                try visionReader.readLandmarks(pixelBuffer: pixelBuffer, orientation: trackInfo.uprightOrientation)
            }
            try handleFrame(frame, presentationTime - (firstFrameTime ?? presentationTime))
            framesRead += 1
        }
        if assetReader.status == .failed {
            throw SignVideoLandmarksError("decoding failed: \(assetReader.error?.localizedDescription ?? "unknown error")")
        }
        return framesRead
    }

    /// The orientation that makes a video track upright, from its `preferredTransform` (the rotation a player applies).
    /// Vision then reports points in the upright picture, without turning any pixels ourselves.
    public static func uprightOrientation(forVideoTransform transform: CGAffineTransform) -> CGImagePropertyOrientation {
        let roundedA = transform.a.rounded()
        let roundedB = transform.b.rounded()
        let roundedC = transform.c.rounded()
        let roundedD = transform.d.rounded()
        switch (roundedA, roundedB, roundedC, roundedD) {
        case (1, 0, 0, 1): return .up
        case (0, 1, -1, 0): return .right        // shown turned 90° clockwise (an iPhone held upright)
        case (0, -1, 1, 0): return .left         // shown turned 90° counter-clockwise
        case (-1, 0, 0, -1): return .down        // shown upside down
        case (-1, 0, 0, 1): return .upMirrored
        case (1, 0, 0, -1): return .downMirrored
        case (0, 1, 1, 0): return .leftMirrored
        case (0, -1, -1, 0): return .rightMirrored
        default: return .up
        }
    }
}
