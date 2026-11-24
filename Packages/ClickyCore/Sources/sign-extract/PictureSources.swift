//
//  PictureSources.swift
//  sign-extract
//
//  Reading the pictures: a video frame by frame (upright, thinned to a frame rate), or one still photo.
//  Only the frame being read and the one before it are held, so a long video never fills memory.
//

import AVFoundation
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import ImageIO
import Vision

struct ExtractionError: Error, CustomStringConvertible {
    var description: String
    init(_ description: String) { self.description = description }
}

/// Carries an async result back to the thread waiting for it (written once, read after the signal).
private final class AsyncResultBox<ResultType>: @unchecked Sendable {
    var result: Result<ResultType, Error>?
}

/// Waits on an async AVFoundation load from a plain worker thread. The workers are threads (not Swift tasks)
/// because Vision blocks for the whole frame and would otherwise starve Swift's small shared task pool.
func waitForAsyncResult<ResultType>(_ operation: @escaping @Sendable () async throws -> ResultType) throws -> ResultType {
    let resultBox = AsyncResultBox<ResultType>()
    let finishedSignal = DispatchSemaphore(value: 0)
    Task.detached {
        do {
            resultBox.result = .success(try await operation())
        } catch {
            resultBox.result = .failure(error)
        }
        finishedSignal.signal()
    }
    finishedSignal.wait()
    return try resultBox.result!.get()
}

/// The orientation that makes a video track upright, from its `preferredTransform` (the rotation a player applies).
/// Vision then reports points in the upright picture, without turning any pixels ourselves.
func uprightOrientation(forVideoTransform transform: CGAffineTransform) -> CGImagePropertyOrientation {
    let roundedA = transform.a.rounded(), roundedB = transform.b.rounded()
    let roundedC = transform.c.rounded(), roundedD = transform.d.rounded()
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

/// True when the orientation turns the picture a quarter turn, so its upright width and height are swapped.
func orientationSwapsWidthAndHeight(_ orientation: CGImagePropertyOrientation) -> Bool {
    [.left, .right, .leftMirrored, .rightMirrored].contains(orientation)
}

struct VideoReadSummary {
    var keptFrameRate: Double
    var uprightWidth: Int
    var uprightHeight: Int
    var keptFrameCount: Int
}

/// Reads a video and calls `handleKeptFrame` for each kept frame, in order, with its pixels and the orientation
/// that makes it upright. When the video is faster than `maximumFramesPerSecond`, the kept frames are the ones
/// nearest an even grid at that rate (starting at the first frame), so a 60 fps clip becomes an even 30 fps one.
func readVideoFrames(
    videoURL: URL,
    maximumFramesPerSecond: Double,
    handleKeptFrame: (CVPixelBuffer, CGImagePropertyOrientation, _ uprightWidthOverHeight: Float) throws -> Void
) throws -> VideoReadSummary {
    let asset = AVURLAsset(url: videoURL)
    let videoTracks = try waitForAsyncResult { try await asset.loadTracks(withMediaType: .video) }
    guard let videoTrack = videoTracks.first else { throw ExtractionError("no video track") }
    let (naturalSize, preferredTransform, nominalFrameRate) = try waitForAsyncResult {
        try await videoTrack.load(.naturalSize, .preferredTransform, .nominalFrameRate)
    }
    let orientation = uprightOrientation(forVideoTransform: preferredTransform)
    let storedWidth = Int(abs(naturalSize.width).rounded())
    let storedHeight = Int(abs(naturalSize.height).rounded())
    let uprightWidth = orientationSwapsWidthAndHeight(orientation) ? storedHeight : storedWidth
    let uprightHeight = orientationSwapsWidthAndHeight(orientation) ? storedWidth : storedHeight
    guard uprightWidth > 0, uprightHeight > 0 else { throw ExtractionError("the video has no picture size") }
    let uprightWidthOverHeight = Float(uprightWidth) / Float(uprightHeight)

    let assetReader = try AVAssetReader(asset: asset)
    // Bi-planar 4:2:0 is what the decoder makes anyway and Vision reads it directly, so no colour conversion is paid.
    let trackOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
    ])
    trackOutput.alwaysCopiesSampleData = false
    guard assetReader.canAdd(trackOutput) else { throw ExtractionError("the video track can't be read") }
    assetReader.add(trackOutput)
    guard assetReader.startReading() else {
        throw ExtractionError("can't start reading: \(assetReader.error?.localizedDescription ?? "unknown error")")
    }
    defer { if assetReader.status == .reading { assetReader.cancelReading() } }

    let thinsFrames = maximumFramesPerSecond > 0 && Double(nominalFrameRate) > maximumFramesPerSecond + 0.01
    let gridStepSeconds = thinsFrames ? 1 / maximumFramesPerSecond : 0
    var nextGridTimeSeconds: Double?
    var previousFrame: (sampleBuffer: CMSampleBuffer, timeSeconds: Double, wasKept: Bool)?
    var keptFrameCount = 0
    var firstFrameTimeSeconds: Double?
    var lastFrameTimeSeconds: Double = 0

    func keep(_ sampleBuffer: CMSampleBuffer) throws {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        try autoreleasepool {
            try handleKeptFrame(pixelBuffer, orientation, uprightWidthOverHeight)
        }
        keptFrameCount += 1
    }

    while let sampleBuffer = trackOutput.copyNextSampleBuffer() {
        guard CMSampleBufferGetImageBuffer(sampleBuffer) != nil else { continue }
        let frameTimeSeconds = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        if firstFrameTimeSeconds == nil { firstFrameTimeSeconds = frameTimeSeconds }
        lastFrameTimeSeconds = frameTimeSeconds

        guard thinsFrames else {
            try keep(sampleBuffer)
            continue
        }

        if nextGridTimeSeconds == nil { nextGridTimeSeconds = frameTimeSeconds }
        var keepsThisFrame = false
        // Every grid time this frame has reached is given to whichever of this frame and the one before is nearer.
        while let gridTimeSeconds = nextGridTimeSeconds, frameTimeSeconds >= gridTimeSeconds - 1e-6 {
            if let previous = previousFrame, !previous.wasKept,
               gridTimeSeconds - previous.timeSeconds < frameTimeSeconds - gridTimeSeconds {
                try keep(previous.sampleBuffer)
                previousFrame?.wasKept = true
            } else {
                keepsThisFrame = true
            }
            nextGridTimeSeconds = gridTimeSeconds + gridStepSeconds
        }
        if keepsThisFrame { try keep(sampleBuffer) }
        previousFrame = (sampleBuffer, frameTimeSeconds, keepsThisFrame)
    }
    if assetReader.status == .failed {
        throw ExtractionError("decoding failed: \(assetReader.error?.localizedDescription ?? "unknown error")")
    }

    let keptFrameRate: Double
    if thinsFrames {
        keptFrameRate = maximumFramesPerSecond
    } else if nominalFrameRate > 0 {
        keptFrameRate = Double(nominalFrameRate)
    } else if keptFrameCount > 1, let firstFrameTimeSeconds, lastFrameTimeSeconds > firstFrameTimeSeconds {
        keptFrameRate = Double(keptFrameCount - 1) / (lastFrameTimeSeconds - firstFrameTimeSeconds)
    } else {
        keptFrameRate = 0
    }
    return VideoReadSummary(keptFrameRate: keptFrameRate, uprightWidth: uprightWidth, uprightHeight: uprightHeight, keptFrameCount: keptFrameCount)
}

struct StillPhoto {
    var image: CGImage
    var orientation: CGImagePropertyOrientation
    var uprightWidth: Int
    var uprightHeight: Int
}

/// Loads a photo with the orientation its EXIF says (a phone photo is often stored sideways).
func loadStillPhoto(photoURL: URL) throws -> StillPhoto {
    guard let imageSource = CGImageSourceCreateWithURL(photoURL as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(imageSource, 0, nil)
    else { throw ExtractionError("not a readable picture") }
    let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any]
    let exifOrientationNumber = (properties?[kCGImagePropertyOrientation] as? NSNumber)?.uint32Value ?? 1
    let orientation = CGImagePropertyOrientation(rawValue: exifOrientationNumber) ?? .up
    let swapsSides = orientationSwapsWidthAndHeight(orientation)
    return StillPhoto(
        image: image,
        orientation: orientation,
        uprightWidth: swapsSides ? image.height : image.width,
        uprightHeight: swapsSides ? image.width : image.height
    )
}
