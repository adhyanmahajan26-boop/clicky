//
//  VisionLandmarkReader.swift
//  sign-extract
//
//  One picture in, one `SignLandmarkFrame` out (Tools/signs/SPEC.md section 1), with Apple Vision: the same
//  requests the app's camera will run, so the models train on what the app sees.
//
//  Which side is which, checked on this Mac (macOS 27) with five real signing videos (Wikimedia Commons, people
//  facing an unmirrored camera, 1,713 frames):
//  - Body joints are named for the PERSON: `.leftShoulder` was on the picture's right in 100% of frames. They map
//    straight across to the signer's sides.
//  - Face landmarks are named by the PICTURE: `leftEyebrow` and `leftEye` were on the picture's left (the signer's
//    right) in 100% of frames. They are swapped to the signer's sides below.
//  - A hand's `chirality` is named for the person: `.left` matched the hand the body wrists made the signer's left
//    on 2,093 of 2,138 hands (98%). It is only a guess for `SignHandSides`, which uses it when no body wrist is seen.
//

import ClickyCore
import CoreGraphics
import CoreImage
import Foundation
import Vision

/// A Vision joint under this confidence counts as not seen (SPEC section 1).
let minimumSeenJointConfidence: Float = 0.3
/// A hand with fewer seen joints than this is dropped: too little of it to be useful, and often a false hand.
let minimumSeenJointsForAHand = 12

/// Vision's hand joint names, in stored order (`SignLandmarkLayout.handJointOrder`).
private let visionHandJointNames: [(HandJoint, VNHumanHandPoseObservation.JointName)] = [
    (.wrist, .wrist),
    (.thumbCMC, .thumbCMC), (.thumbMP, .thumbMP), (.thumbIP, .thumbIP), (.thumbTip, .thumbTip),
    (.indexMCP, .indexMCP), (.indexPIP, .indexPIP), (.indexDIP, .indexDIP), (.indexTip, .indexTip),
    (.middleMCP, .middleMCP), (.middlePIP, .middlePIP), (.middleDIP, .middleDIP), (.middleTip, .middleTip),
    (.ringMCP, .ringMCP), (.ringPIP, .ringPIP), (.ringDIP, .ringDIP), (.ringTip, .ringTip),
    (.littleMCP, .littleMCP), (.littlePIP, .littlePIP), (.littleDIP, .littleDIP), (.littleTip, .littleTip)
]

/// Vision's body joint names for the 13 stored body points. Apple names them for the person, the same as SPEC.
private let visionBodyJointNames: [(SignBodyPoint, VNHumanBodyPoseObservation.JointName)] = [
    (.nose, .nose),
    (.leftEye, .leftEye), (.rightEye, .rightEye),
    (.leftEar, .leftEar), (.rightEar, .rightEar),
    (.leftShoulder, .leftShoulder), (.rightShoulder, .rightShoulder),
    (.leftElbow, .leftElbow), (.rightElbow, .rightElbow),
    (.leftWrist, .leftWrist), (.rightWrist, .rightWrist),
    (.leftHip, .leftHip), (.rightHip, .rightHip)
]

/// Vision gives 0–1 with y UP; the landmark files are y DOWN.
private func picturePoint(fromVisionLocation visionLocation: CGPoint) -> SignPicturePoint {
    SignPicturePoint(x: Float(visionLocation.x), y: Float(1 - visionLocation.y))
}

/// Holds its own Vision request objects: one reader per worker thread, never shared (requests keep state).
final class VisionLandmarkReader {
    private let handPoseRequest: VNDetectHumanHandPoseRequest
    private let bodyPoseRequest: VNDetectHumanBodyPoseRequest
    private let faceLandmarksRequest: VNDetectFaceLandmarksRequest?

    init(readsFace: Bool) {
        handPoseRequest = VNDetectHumanHandPoseRequest()
        handPoseRequest.maximumHandCount = 2
        bodyPoseRequest = VNDetectHumanBodyPoseRequest()
        faceLandmarksRequest = readsFace ? VNDetectFaceLandmarksRequest() : nil
    }

    /// Runs the requests on one picture. `requestHandler` already carries the orientation that makes the picture
    /// upright, so every point comes back in the upright picture.
    ///
    /// `uprightPictureForPaddedBody`, when given, is the same picture upright; the body pose then runs on it placed at
    /// the top middle of a bigger grey canvas instead of on the picture itself. Why: Vision's body pose finds nobody
    /// in a close head-and-shoulders picture (a phone or laptop camera at arm's length: PopSign's selfie videos gave
    /// shoulders in 0 of 67 frames), but finds the same person once they look smaller in a bigger picture (62–67 of 67).
    func readLandmarks(requestHandler: VNImageRequestHandler, pictureWidthOverHeight: Float, uprightPictureForPaddedBody: CIImage? = nil) throws -> SignLandmarkFrame {
        var requests: [VNRequest] = [handPoseRequest]
        if uprightPictureForPaddedBody == nil { requests.append(bodyPoseRequest) }
        if let faceLandmarksRequest { requests.append(faceLandmarksRequest) }
        try requestHandler.perform(requests)

        var pictureLocationFromBodyLocation: (CGPoint) -> CGPoint = { $0 }
        if let uprightPictureForPaddedBody {
            pictureLocationFromBodyLocation = try runBodyPoseOnPaddedCanvas(uprightPicture: uprightPictureForPaddedBody)
        }

        var frame = SignLandmarkFrame()
        let bodyPoints = biggestPersonBodyPoints(pictureLocationFromBodyLocation: pictureLocationFromBodyLocation)
        for (bodyPoint, landmarkPoint) in bodyPoints {
            frame[bodyPoint] = landmarkPoint
        }

        let seenHands = seenHandsWithConfidences()
        let bodyRightWrist = bodyPoints[.rightWrist].map { SignPicturePoint(x: $0.x, y: $0.y) }
        let bodyLeftWrist = bodyPoints[.leftWrist].map { SignPicturePoint(x: $0.x, y: $0.y) }
        let sides = SignHandSides.assignSides(
            seenHands: seenHands.map(\.seenHand),
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
            for (joint, visionJointName) in visionHandJointNames {
                guard let recognizedPoint = recognizedPoints[visionJointName], recognizedPoint.confidence >= minimumSeenJointConfidence else { continue }
                let point = picturePoint(fromVisionLocation: recognizedPoint.location)
                picturePointsByJoint[joint] = point
                landmarkPointsByJoint[joint] = SignLandmarkPoint(x: point.x, y: point.y, confidence: recognizedPoint.confidence)
            }
            guard picturePointsByJoint.count >= minimumSeenJointsForAHand else { return nil }
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

    /// The canvas is twice as wide and 1.6 times as tall as the picture, with the picture at its top middle (the
    /// person's lower body would be below a head-and-shoulders picture). Returns how to turn a Vision location on the
    /// canvas back into one on the picture (both 0–1, y up).
    private func runBodyPoseOnPaddedCanvas(uprightPicture: CIImage) throws -> (CGPoint) -> CGPoint {
        // Vision looks at the body pose at a few hundred pixels anyway, so the picture is first made at most 640
        // pixels on its long side: drawing a 5-megapixel phone frame into a canvas 3 times its size was the slow part.
        let longestSide = max(uprightPicture.extent.width, uprightPicture.extent.height)
        let shrinkScale = min(1, 640 / max(longestSide, 1))
        let picture = uprightPicture
            .transformed(by: CGAffineTransform(translationX: -uprightPicture.extent.minX, y: -uprightPicture.extent.minY))
            .transformed(by: CGAffineTransform(scaleX: shrinkScale, y: shrinkScale))
        let pictureWidth = picture.extent.width
        let pictureHeight = picture.extent.height
        let canvasWidth = (pictureWidth * 2).rounded()
        let canvasHeight = (pictureHeight * 1.6).rounded()
        let pictureOffsetX = ((canvasWidth - pictureWidth) / 2).rounded()
        let pictureOffsetY = canvasHeight - pictureHeight  // CoreImage's y is up, so this is the top of the canvas
        let canvasRectangle = CGRect(x: 0, y: 0, width: canvasWidth, height: canvasHeight)
        let greyCanvas = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5)).cropped(to: canvasRectangle)
        let paddedPicture = picture.transformed(by: CGAffineTransform(translationX: pictureOffsetX, y: pictureOffsetY)).composited(over: greyCanvas)
        try VNImageRequestHandler(ciImage: paddedPicture, options: [:]).perform([bodyPoseRequest])
        return { canvasLocation in
            CGPoint(
                x: (canvasLocation.x * canvasWidth - pictureOffsetX) / pictureWidth,
                y: (canvasLocation.y * canvasHeight - pictureOffsetY) / pictureHeight
            )
        }
    }

    /// The body points of the person whose seen points cover the most picture (the signer is nearly always the
    /// biggest person; a small one in the background is ignored). A point that lands outside the picture (possible
    /// with the padded canvas) counts as not seen, since landmarks are 0–1 of the picture.
    private func biggestPersonBodyPoints(pictureLocationFromBodyLocation: (CGPoint) -> CGPoint) -> [SignBodyPoint: SignLandmarkPoint] {
        var biggestPersonPoints: [SignBodyPoint: SignLandmarkPoint] = [:]
        var biggestPersonArea: Float = -1
        for observation in bodyPoseRequest.results ?? [] {
            guard let recognizedPoints = try? observation.recognizedPoints(.all) else { continue }
            // The person's size is measured over all their seen joints (knees and ankles too), not only the 13 kept.
            let seenLocations = recognizedPoints.values.filter { $0.confidence >= minimumSeenJointConfidence }.map(\.location)
            guard !seenLocations.isEmpty else { continue }
            let width = Float((seenLocations.map(\.x).max() ?? 0) - (seenLocations.map(\.x).min() ?? 0))
            let height = Float((seenLocations.map(\.y).max() ?? 0) - (seenLocations.map(\.y).min() ?? 0))
            let area = width * height
            guard area > biggestPersonArea else { continue }
            biggestPersonArea = area
            var personPoints: [SignBodyPoint: SignLandmarkPoint] = [:]
            for (bodyPoint, visionJointName) in visionBodyJointNames {
                guard let recognizedPoint = recognizedPoints[visionJointName], recognizedPoint.confidence >= minimumSeenJointConfidence else { continue }
                let pictureLocation = pictureLocationFromBodyLocation(recognizedPoint.location)
                guard (0...1).contains(pictureLocation.x), (0...1).contains(pictureLocation.y) else { continue }
                let point = picturePoint(fromVisionLocation: pictureLocation)
                personPoints[bodyPoint] = SignLandmarkPoint(x: point.x, y: point.y, confidence: recognizedPoint.confidence)
            }
            biggestPersonPoints = personPoints
        }
        return biggestPersonPoints
    }

    // MARK: Face

    /// Mouth corners, the middle of each lip's outer edge, and the middle of each brow, from the biggest face.
    private func writeMouthAndBrows(into frame: inout SignLandmarkFrame) {
        guard let faceObservations = faceLandmarksRequest?.results, !faceObservations.isEmpty else { return }
        let biggestFace = faceObservations.max { firstFace, secondFace in
            firstFace.boundingBox.width * firstFace.boundingBox.height < secondFace.boundingBox.width * secondFace.boundingBox.height
        }!
        guard let landmarks = biggestFace.landmarks else { return }
        let faceConfidence = biggestFace.confidence

        // Passing a 1 × 1 picture gives each landmark in 0–1 picture coordinates (y up, flipped here).
        func picturePoints(of region: VNFaceLandmarkRegion2D?) -> [SignPicturePoint] {
            guard let region, region.pointCount > 0 else { return [] }
            return region.pointsInImage(imageSize: CGSize(width: 1, height: 1)).map { picturePoint(fromVisionLocation: $0) }
        }

        // Brows and eyes: unlike the body joints, Vision names the face's parts by the PICTURE (checked: `leftEyebrow`
        // and `leftEye` are on the picture's left for someone facing the camera, which is the signer's right), so they
        // are swapped here. "Middle" of a brow is the average of its points.
        let signerLeftBrowPoints = picturePoints(of: landmarks.rightEyebrow)
        let signerRightBrowPoints = picturePoints(of: landmarks.leftEyebrow)
        if let middle = averagePoint(of: signerLeftBrowPoints) {
            frame[SignBrowPoint.leftBrowMiddle] = SignLandmarkPoint(x: middle.x, y: middle.y, confidence: faceConfidence)
        }
        if let middle = averagePoint(of: signerRightBrowPoints) {
            frame[SignBrowPoint.rightBrowMiddle] = SignLandmarkPoint(x: middle.x, y: middle.y, confidence: faceConfidence)
        }

        // Mouth: `outerLips` is one loop with no named corners, so the corners are worked out from its shape: the two
        // points furthest apart. The corner nearer the signer's right eye is their right corner (this still holds with
        // the head tilted). The lip middles are the loop points nearest the corners' midpoint along the mouth, on the
        // eyes' side (upper) and the chin's side (lower).
        let outerLipPoints = picturePoints(of: landmarks.outerLips)
        guard outerLipPoints.count >= 4,
              let signerRightEye = averagePoint(of: picturePoints(of: landmarks.leftEye)),
              let signerLeftEye = averagePoint(of: picturePoints(of: landmarks.rightEye))
        else { return }

        var firstCornerIndex = 0
        var secondCornerIndex = 1
        var largestSquaredDistance: Float = -1
        for firstIndex in outerLipPoints.indices {
            for secondIndex in outerLipPoints.indices where secondIndex > firstIndex {
                let squaredDistance = squaredDistanceBetween(outerLipPoints[firstIndex], outerLipPoints[secondIndex])
                if squaredDistance > largestSquaredDistance {
                    largestSquaredDistance = squaredDistance
                    firstCornerIndex = firstIndex
                    secondCornerIndex = secondIndex
                }
            }
        }
        var signerRightCorner = outerLipPoints[firstCornerIndex]
        var signerLeftCorner = outerLipPoints[secondCornerIndex]
        if squaredDistanceBetween(signerLeftCorner, signerRightEye) < squaredDistanceBetween(signerRightCorner, signerRightEye) {
            swap(&signerRightCorner, &signerLeftCorner)
        }

        let mouthAxisX = signerLeftCorner.x - signerRightCorner.x
        let mouthAxisY = signerLeftCorner.y - signerRightCorner.y
        let mouthAxisSquaredLength = max(mouthAxisX * mouthAxisX + mouthAxisY * mouthAxisY, 1e-12)
        let eyesMiddle = SignPicturePoint(x: (signerRightEye.x + signerLeftEye.x) / 2, y: (signerRightEye.y + signerLeftEye.y) / 2)
        // Which side of the corner-to-corner line the eyes are on: points on that side are the upper lip.
        let eyesSideSign = crossProductSign(axisStart: signerRightCorner, axisX: mouthAxisX, axisY: mouthAxisY, point: eyesMiddle)

        var upperLipMiddle: SignPicturePoint?
        var lowerLipMiddle: SignPicturePoint?
        var upperLipBestOffset = Float.greatestFiniteMagnitude
        var lowerLipBestOffset = Float.greatestFiniteMagnitude
        for (pointIndex, point) in outerLipPoints.enumerated() where pointIndex != firstCornerIndex && pointIndex != secondCornerIndex {
            // 0 at the right corner, 1 at the left corner; the middle of the lip is nearest 0.5.
            let placeAlongMouth = ((point.x - signerRightCorner.x) * mouthAxisX + (point.y - signerRightCorner.y) * mouthAxisY) / mouthAxisSquaredLength
            let offsetFromMiddle = abs(placeAlongMouth - 0.5)
            let isOnEyesSide = crossProductSign(axisStart: signerRightCorner, axisX: mouthAxisX, axisY: mouthAxisY, point: point) == eyesSideSign
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

private func averagePoint(of points: [SignPicturePoint]) -> SignPicturePoint? {
    guard !points.isEmpty else { return nil }
    let totalX = points.reduce(Float(0)) { $0 + $1.x }
    let totalY = points.reduce(Float(0)) { $0 + $1.y }
    return SignPicturePoint(x: totalX / Float(points.count), y: totalY / Float(points.count))
}

private func squaredDistanceBetween(_ firstPoint: SignPicturePoint, _ secondPoint: SignPicturePoint) -> Float {
    (firstPoint.x - secondPoint.x) * (firstPoint.x - secondPoint.x) + (firstPoint.y - secondPoint.y) * (firstPoint.y - secondPoint.y)
}

/// Which side of the line through `axisStart` along (axisX, axisY) a point is on: +1 or -1 (0 on the line).
private func crossProductSign(axisStart: SignPicturePoint, axisX: Float, axisY: Float, point: SignPicturePoint) -> Int {
    let crossProduct = axisX * (point.y - axisStart.y) - axisY * (point.x - axisStart.x)
    return crossProduct > 0 ? 1 : (crossProduct < 0 ? -1 : 0)
}
