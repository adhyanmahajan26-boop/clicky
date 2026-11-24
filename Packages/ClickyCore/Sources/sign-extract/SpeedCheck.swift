//
//  SpeedCheck.swift
//  sign-extract
//
//  `sign-extract speed --video <file> [--frames N]`: how long `SignVisionReader` takes a frame on one thread, the
//  way the app's camera calls it, so it can be checked against 30 frames a second on any Mac (the MacBook Air is
//  slower than the Studio). Three settings: the hand pose alone, hands + the padded body pose (what the app reads),
//  and that with the face too (what `--face` extraction reads).
//

import ClickyCore
import CoreVideo
import Foundation
import Vision

func runSpeedCheck(arguments: [String]) -> Never {
    var videoPath: String?
    var framesToTime = 300
    var argumentIndex = 0
    while argumentIndex < arguments.count {
        switch arguments[argumentIndex] {
        case "--video":
            argumentIndex += 1
            videoPath = argumentIndex < arguments.count ? arguments[argumentIndex] : nil
        case "--frames":
            argumentIndex += 1
            framesToTime = argumentIndex < arguments.count ? (Int(arguments[argumentIndex]) ?? 300) : 300
        default:
            break
        }
        argumentIndex += 1
    }
    guard let videoPath else {
        print("usage: sign-extract speed --video <file> [--frames N]")
        exit(2)
    }

    // The frames are decoded first and kept, so only the reading is timed.
    var decodedFrames: [(CVPixelBuffer, CGImagePropertyOrientation)] = []
    do {
        _ = try readVideoFrames(videoURL: URL(fileURLWithPath: videoPath), maximumFramesPerSecond: 30) { pixelBuffer, orientation in
            if decodedFrames.count < framesToTime {
                // Copied, because the decoder reuses its buffers.
                decodedFrames.append((copyOfPixelBuffer(pixelBuffer), orientation))
            }
        }
    } catch {
        print("can't read \(videoPath): \(error)")
        exit(1)
    }
    guard let firstFrame = decodedFrames.first else { print("no frames"); exit(1) }
    print("\(decodedFrames.count) frames of \(CVPixelBufferGetWidth(firstFrame.0))×\(CVPixelBufferGetHeight(firstFrame.0)), one thread")

    func time(_ settingName: String, readOneFrame: (CVPixelBuffer, CGImagePropertyOrientation) throws -> Void) {
        // The first few frames load the models; they are read once before timing.
        for (pixelBuffer, orientation) in decodedFrames.prefix(5) { try? readOneFrame(pixelBuffer, orientation) }
        var millisecondsPerFrame: [Double] = []
        for (pixelBuffer, orientation) in decodedFrames {
            let startTime = DispatchTime.now().uptimeNanoseconds
            autoreleasepool { try? readOneFrame(pixelBuffer, orientation) }
            millisecondsPerFrame.append(Double(DispatchTime.now().uptimeNanoseconds - startTime) / 1_000_000)
        }
        let sorted = millisecondsPerFrame.sorted()
        let mean = millisecondsPerFrame.reduce(0, +) / Double(millisecondsPerFrame.count)
        let median = sorted[sorted.count / 2]
        let slowestTwentieth = sorted[min(sorted.count - 1, sorted.count * 95 / 100)]
        print(String(format: "  %-30@ mean %5.1f ms, median %5.1f ms, 95th %5.1f ms a frame → %4.0f frames a second", settingName as NSString, mean, median, slowestTwentieth, 1000 / mean))
    }

    let handPoseRequest = VNDetectHumanHandPoseRequest()
    handPoseRequest.maximumHandCount = 2
    time("hands alone") { pixelBuffer, orientation in
        try VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: orientation, options: [:]).perform([handPoseRequest])
    }
    let cameraReader = SignVisionReader(readsFace: false)
    time("hands + padded body (the app)") { pixelBuffer, orientation in
        _ = try cameraReader.readLandmarks(pixelBuffer: pixelBuffer, orientation: orientation)
    }
    let faceReader = SignVisionReader(readsFace: true)
    time("hands + padded body + face") { pixelBuffer, orientation in
        _ = try faceReader.readLandmarks(pixelBuffer: pixelBuffer, orientation: orientation)
    }
    exit(0)
}

private func copyOfPixelBuffer(_ source: CVPixelBuffer) -> CVPixelBuffer {
    var copy: CVPixelBuffer?
    let attributes = [kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()] as CFDictionary
    CVPixelBufferCreate(nil, CVPixelBufferGetWidth(source), CVPixelBufferGetHeight(source), CVPixelBufferGetPixelFormatType(source), attributes, &copy)
    guard let copy else { return source }
    CVPixelBufferLockBaseAddress(source, .readOnly)
    CVPixelBufferLockBaseAddress(copy, [])
    for plane in 0..<max(1, CVPixelBufferGetPlaneCount(source)) {
        let isPlanar = CVPixelBufferIsPlanar(source)
        let sourceAddress = isPlanar ? CVPixelBufferGetBaseAddressOfPlane(source, plane) : CVPixelBufferGetBaseAddress(source)
        let copyAddress = isPlanar ? CVPixelBufferGetBaseAddressOfPlane(copy, plane) : CVPixelBufferGetBaseAddress(copy)
        let sourceRowBytes = isPlanar ? CVPixelBufferGetBytesPerRowOfPlane(source, plane) : CVPixelBufferGetBytesPerRow(source)
        let copyRowBytes = isPlanar ? CVPixelBufferGetBytesPerRowOfPlane(copy, plane) : CVPixelBufferGetBytesPerRow(copy)
        let rows = isPlanar ? CVPixelBufferGetHeightOfPlane(source, plane) : CVPixelBufferGetHeight(source)
        guard let sourceAddress, let copyAddress else { continue }
        for row in 0..<rows {
            memcpy(copyAddress + row * copyRowBytes, sourceAddress + row * sourceRowBytes, min(sourceRowBytes, copyRowBytes))
        }
    }
    CVPixelBufferUnlockBaseAddress(copy, [])
    CVPixelBufferUnlockBaseAddress(source, .readOnly)
    return copy
}
