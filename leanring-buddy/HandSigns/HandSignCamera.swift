//
//  HandSignCamera.swift
//  leanring-buddy
//
//  The camera for hand signs: AVFoundation at 640×480, and Apple Vision's hand pose on each
//  frame it keeps (about 12 a second), all on this Mac. Nothing is saved or sent anywhere: each
//  frame becomes 21 joint positions per hand (up to two hands, since many Indian Sign Language
//  letters use both), handed to HandSignController on the main thread, and is gone.
//
//  Sign to text reads more, more often: about 30 frames a second, each turned into the 61 landmarks of
//  Tools/signs/SPEC.md (hands, body on the padded canvas, mouth and brows) by ClickyCore's SignVisionReader,
//  with the camera's own time stamp. When Vision can't keep up, late frames are dropped (by AVFoundation, and
//  here when the main thread hasn't taken the last few yet), never queued: the reader brings whatever rate
//  arrives to 30 a second by the frames' times.
//

import AVFoundation
import ClickyCore
import Foundation
import QuartzCore
import Vision

/// Not on the main actor: AVFoundation calls `captureOutput` on `videoQueue`, and the session is
/// started and stopped on `sessionQueue`. Only `onHandPose` is called on the main thread.
nonisolated final class HandSignCamera: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    enum CameraProblem: LocalizedError {
        case noCamera
        case notAllowed
        case couldNotUse(String)

        var errorDescription: String? {
            switch self {
            case .noCamera: return "No camera found. Plug one in, or use your iPhone as a camera."
            case .notAllowed: return "Vello isn't allowed to use the camera. Turn it on in System Settings › Privacy & Security › Camera."
            case .couldNotUse(let reason): return "The camera couldn't start: \(reason)"
            }
        }
    }

    /// Frames read a second. Signs are held for over half a second, so this is plenty and keeps the Mac cool.
    static let analysedFramesPerSecond: Double = 12
    /// Vision's own confidence for a joint before it counts.
    static let leastJointConfidence: Float = 0.3

    /// Sign to text: frames closer together than this are skipped, so a camera giving 60 a second is read at 30.
    /// A little under 1/30 s, so a 30 a second camera keeps every frame despite jitter in its time stamps.
    static let shortestGapBetweenSignFrames: Double = 0.8 / 30
    /// Sign to text: frames handed to the main thread but not taken yet. Past this many, new frames are dropped
    /// rather than piling up behind a busy main thread.
    static let mostSignFramesWaitingForTheMainThread = 4

    let captureSession = AVCaptureSession()
    /// Called on the main thread for every analysed frame: the hands seen (none, one or two).
    var onHandPoses: (([HandPose]) -> Void)?
    /// Sign to text: called on the main thread for every frame read, with the camera's time stamp (seconds) and
    /// the upright picture's size in pixels.
    var onSignFrame: ((SignLandmarkFrame, Double, Int, Int) -> Void)?

    private let sessionQueue = DispatchQueue(label: "vello.handsigns.session")
    private let videoQueue = DispatchQueue(label: "vello.handsigns.frames", qos: .userInitiated)
    private var lastAnalysedFrameTime: CFTimeInterval = 0
    private var isConfigured = false
    /// Only read and written on `videoQueue`.
    private var readsSignLanguage = false
    private var lastSignFrameTime: Double = -.infinity
    /// Made on `videoQueue` the first time Sign to text runs, and only used there (Vision requests keep state).
    private var signVisionReader: SignVisionReader?
    /// Guards `signFramesWaitingForTheMainThread`, which `videoQueue` raises and the main thread lowers.
    private let signFramesWaitingLock = NSLock()
    private var signFramesWaitingForTheMainThread = 0
    private let handPoseRequest: VNDetectHumanHandPoseRequest = {
        let request = VNDetectHumanHandPoseRequest()
        request.maximumHandCount = 2
        return request
    }()

    /// Asks for the camera if macOS hasn't asked yet. True when Vello may use it.
    static func requestAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .video)
        default: return false
        }
    }

    func start() throws {
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else { throw CameraProblem.notAllowed }
        if !isConfigured { try configure() }
        sessionQueue.async { [captureSession] in
            if !captureSession.isRunning { captureSession.startRunning() }
        }
    }

    func stop() {
        sessionQueue.async { [captureSession] in
            if captureSession.isRunning { captureSession.stopRunning() }
        }
    }

    /// Sign to text on or off. Set on the frame queue, so a frame being read finishes the way it started.
    func setReadsSignLanguage(_ isOn: Bool) {
        videoQueue.async { [weak self] in
            guard let self else { return }
            self.readsSignLanguage = isOn
            self.lastSignFrameTime = -.infinity
        }
    }

    private func configure() throws {
        // The built-in camera first, then whatever macOS calls the default (an external or iPhone camera).
        let discovery = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
                                                         mediaType: .video, position: .unspecified)
        guard let device = discovery.devices.first(where: { $0.deviceType == .builtInWideAngleCamera }) ?? AVCaptureDevice.default(for: .video) ?? discovery.devices.first else {
            throw CameraProblem.noCamera
        }
        let input: AVCaptureDeviceInput
        do { input = try AVCaptureDeviceInput(device: device) } catch { throw CameraProblem.couldNotUse(error.localizedDescription) }

        captureSession.beginConfiguration()
        defer { captureSession.commitConfiguration() }
        if captureSession.canSetSessionPreset(.vga640x480) { captureSession.sessionPreset = .vga640x480 }
        guard captureSession.canAddInput(input) else { throw CameraProblem.couldNotUse("the camera is busy") }
        captureSession.addInput(input)

        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.setSampleBufferDelegate(self, queue: videoQueue)
        guard captureSession.canAddOutput(output) else { throw CameraProblem.couldNotUse("no video output") }
        captureSession.addOutput(output)
        isConfigured = true
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if readsSignLanguage {
            readSignFrame(sampleBuffer)
            return
        }
        let now = CACurrentMediaTime()
        guard now - lastAnalysedFrameTime >= 1 / Self.analysedFramesPerSecond else { return }
        lastAnalysedFrameTime = now
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let frameWidth = Double(CVPixelBufferGetWidth(pixelBuffer))
        let frameHeight = Double(CVPixelBufferGetHeight(pixelBuffer))

        var handPoses: [HandPose] = []
        let requestHandler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
        if (try? requestHandler.perform([handPoseRequest])) != nil, let observations = handPoseRequest.results {
            handPoses = observations.compactMap { Self.handPose(from: $0, frameWidth: frameWidth, frameHeight: frameHeight) }
        }
        DispatchQueue.main.async { [weak self] in self?.onHandPoses?(handPoses) }
    }

    /// Sign to text: the frame's 61 landmarks, read on this queue and handed to the main thread with the camera's
    /// own time stamp. The Mac camera's picture is upright and not mirrored (the panel mirrors only its preview).
    private func readSignFrame(_ sampleBuffer: CMSampleBuffer) {
        let frameTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        guard frameTime.isFinite, frameTime - lastSignFrameTime >= Self.shortestGapBetweenSignFrames else { return }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        signFramesWaitingLock.lock()
        let mainThreadIsBehind = signFramesWaitingForTheMainThread >= Self.mostSignFramesWaitingForTheMainThread
        signFramesWaitingLock.unlock()
        guard !mainThreadIsBehind else { return }
        lastSignFrameTime = frameTime

        let visionReader = signVisionReader ?? SignVisionReader(readsFace: SignVisionReader.cameraReadsFace)
        signVisionReader = visionReader
        guard let frame = try? visionReader.readLandmarks(pixelBuffer: pixelBuffer, orientation: .up) else { return }
        let pictureWidth = CVPixelBufferGetWidth(pixelBuffer)
        let pictureHeight = CVPixelBufferGetHeight(pixelBuffer)

        signFramesWaitingLock.lock()
        signFramesWaitingForTheMainThread += 1
        signFramesWaitingLock.unlock()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.signFramesWaitingLock.lock()
            self.signFramesWaitingForTheMainThread -= 1
            self.signFramesWaitingLock.unlock()
            self.onSignFrame?(frame, frameTime, pictureWidth, pictureHeight)
        }
    }

    /// Vision's joints in pixels (so x and y are the same size), y up as Vision gives them.
    static func handPose(from observation: VNHumanHandPoseObservation, frameWidth: Double, frameHeight: Double) -> HandPose? {
        guard let recognizedPoints = try? observation.recognizedPoints(.all) else { return nil }
        var joints: [HandJoint: HandPoint] = [:]
        for (visionJointName, handJoint) in visionJointNames {
            guard let recognizedPoint = recognizedPoints[visionJointName], recognizedPoint.confidence >= leastJointConfidence else { continue }
            joints[handJoint] = HandPoint(x: Double(recognizedPoint.location.x) * frameWidth, y: Double(recognizedPoint.location.y) * frameHeight)
        }
        // Most of the hand has to be seen; half a hand at the edge of the picture reads as anything.
        guard joints.count >= 16 else { return nil }
        return HandPose(joints: joints)
    }

    private static let visionJointNames: [(VNHumanHandPoseObservation.JointName, HandJoint)] = [
        (.wrist, .wrist),
        (.thumbCMC, .thumbCMC), (.thumbMP, .thumbMP), (.thumbIP, .thumbIP), (.thumbTip, .thumbTip),
        (.indexMCP, .indexMCP), (.indexPIP, .indexPIP), (.indexDIP, .indexDIP), (.indexTip, .indexTip),
        (.middleMCP, .middleMCP), (.middlePIP, .middlePIP), (.middleDIP, .middleDIP), (.middleTip, .middleTip),
        (.ringMCP, .ringMCP), (.ringPIP, .ringPIP), (.ringDIP, .ringDIP), (.ringTip, .ringTip),
        (.littleMCP, .littleMCP), (.littlePIP, .littlePIP), (.littleDIP, .littleDIP), (.littleTip, .littleTip)
    ]
}
