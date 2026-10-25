//
//  OCREngine.swift
//  ClickyCore
//
//  Recognises on-screen text with Vision, for things AX can't see (canvas
//  text, images of text, some web content). The screen is split into
//  full-width bands of about 500 native px with 96 px overlap, each run
//  concurrently; on low-density displays (< 1.5 px/pt, e.g. the 1x
//  ultrawide) bands are upscaled 2x for recognition but mapped back through
//  the native crop. Lines found twice in overlapping bands are de-duplicated.
//  P6.8: `recognizeLines(regionsPx:)` reads only planned regions (see
//  OCRCoveragePlanner); their bands keep the region's own x range.
//

import CoreGraphics
import Foundation
import Vision

public enum OCRBandPlanner {
    public static let targetBandHeightPx = 500
    public static let overlapPx = 96

    /// Native-pixel crop rects (full width) covering `regionPx`.
    /// `phase` (0...1) shifts band boundaries by that fraction of a band; the
    /// retry pass uses 0.5 so text that fell on a seam lands mid-band.
    public static func bands(imageWidthPx: Int, regionPx: CGRect, phase: Double = 0) -> [CGRect] {
        let regionHeight = Int(regionPx.height.rounded())
        let bandCount = max(1, Int((Double(regionHeight) / Double(targetBandHeightPx)).rounded()))
        let step = Double(regionHeight) / Double(bandCount)
        let offset = phase * step
        let bandStarts = phase > 0 ? [0.0] + (0..<bandCount).map { offset + Double($0) * step } : (0..<bandCount).map { Double($0) * step }
        return bandStarts.compactMap { relativeStart -> CGRect? in
            let relativeEnd = phase > 0 && relativeStart == 0 ? offset : relativeStart + step
            guard relativeStart < Double(regionHeight) else { return nil }
            let top = max(Double(regionPx.minY), Double(regionPx.minY) + relativeStart - Double(overlapPx) / 2)
            let bottom = min(Double(regionPx.maxY), Double(regionPx.minY) + relativeEnd + Double(overlapPx) / 2)
            guard bottom > top else { return nil }
            return CGRect(x: 0, y: top.rounded(.down), width: Double(imageWidthPx), height: (bottom - top).rounded(.up))
        }
    }

    /// Bands over `regionPx` that keep its x range (not full width).
    public static func regionBands(regionPx: CGRect, phase: Double = 0) -> [CGRect] {
        bands(imageWidthPx: Int(regionPx.width.rounded(.up)), regionPx: regionPx, phase: phase).map { band in
            CGRect(x: regionPx.minX.rounded(.down), y: band.minY, width: band.width, height: band.height)
        }
    }

    /// Vision's minimumTextHeight (fraction of the band image height) for
    /// 6 pt text.
    public static func minimumTextHeight(pixelsPerPoint: CGFloat, bandHeightPx: CGFloat) -> Float {
        guard bandHeightPx > 0 else { return 0 }
        return Float(min(1, 6 * pixelsPerPoint / bandHeightPx))
    }

    public static func upscaleFactor(pixelsPerPoint: CGFloat) -> CGFloat {
        pixelsPerPoint < 1.5 ? 2 : 1
    }
}

public enum OCREngine {
    /// Vision's perform() blocks its thread, so OCR runs on its own bounded
    /// queue — never on Swift's cooperative pool, which it could exhaust.
    private static let recognitionQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "clicky.ocr"
        queue.maxConcurrentOperationCount = 6
        queue.qualityOfService = .userInitiated
        return queue
    }()

    public enum Level: Sendable {
        case accurate
        case fast
    }

    /// ["en-US"] plus the user's preferred languages Vision supports (max 2 total).
    public static func recognitionLanguages() -> [String] {
        let supportedLanguages = (try? VNRecognizeTextRequest().supportedRecognitionLanguages()) ?? ["en-US"]
        var languages = ["en-US"]
        for preferredLanguage in Locale.preferredLanguages where languages.count < 2 {
            if let supportedMatch = supportedLanguages.first(where: { $0 == preferredLanguage || $0.hasPrefix(preferredLanguage.prefix(2)) }),
               !languages.contains(supportedMatch) {
                languages.append(supportedMatch)
            }
        }
        return languages
    }

    /// OCR over `regionPx` (native pixels; whole image when nil) of a capture.
    public static func recognizeLines(in nativeImage: CGImage, frame: CaptureFrame, regionPx: CGRect? = nil, level: Level = .accurate, bandPhase: Double = 0) async -> [OCRLine] {
        let fullRegion = CGRect(x: 0, y: 0, width: nativeImage.width, height: nativeImage.height)
        let bands = OCRBandPlanner.bands(imageWidthPx: nativeImage.width, regionPx: (regionPx ?? fullRegion).intersection(fullRegion), phase: bandPhase)
        return await recognizeBands(bands, in: nativeImage, frame: frame, level: level)
    }

    /// OCR over several native-px regions (an OCRCoveragePlanner plan);
    /// each region's bands keep its x range. No regions → no lines.
    public static func recognizeLines(in nativeImage: CGImage, frame: CaptureFrame, regionsPx: [CGRect], level: Level = .accurate) async -> [OCRLine] {
        let fullRegion = CGRect(x: 0, y: 0, width: nativeImage.width, height: nativeImage.height)
        let bands = regionsPx.flatMap { regionPx -> [CGRect] in
            let clippedRegion = regionPx.intersection(fullRegion)
            guard !clippedRegion.isNull, clippedRegion.width >= 1, clippedRegion.height >= 1 else { return [] }
            if clippedRegion.width >= fullRegion.width - 1 {
                return OCRBandPlanner.bands(imageWidthPx: nativeImage.width, regionPx: clippedRegion)
            }
            return OCRBandPlanner.regionBands(regionPx: clippedRegion).map { $0.intersection(fullRegion) }
        }
        return await recognizeBands(bands, in: nativeImage, frame: frame, level: level)
    }

    private static func recognizeBands(_ bands: [CGRect], in nativeImage: CGImage, frame: CaptureFrame, level: Level) async -> [OCRLine] {
        guard !bands.isEmpty else { return [] }
        let pixelsPerPoint = frame.nativePixelsPerPoint
        let languages = recognitionLanguages()

        let bandLines = await withTaskGroup(of: [OCRLine].self) { taskGroup in
            for bandRect in bands {
                taskGroup.addTask {
                    // A cancelled prewarm doesn't start bands it hasn't begun.
                    guard !Task.isCancelled else { return [] }
                    return await withCheckedContinuation { continuation in
                        recognitionQueue.addOperation {
                            continuation.resume(returning: recognizeBand(nativeImage: nativeImage, bandRect: bandRect, frame: frame,
                                                                         pixelsPerPoint: pixelsPerPoint, languages: languages, level: level))
                        }
                    }
                }
            }
            var collectedLines: [[OCRLine]] = []
            for await lines in taskGroup { collectedLines.append(lines) }
            return collectedLines
        }
        return deduplicated(bandLines.flatMap { $0 })
    }

    static func recognizeBand(nativeImage: CGImage, bandRect: CGRect, frame: CaptureFrame, pixelsPerPoint: CGFloat,
                              languages: [String], level: Level) -> [OCRLine] {
        guard let bandImage = nativeImage.cropping(to: bandRect) else { return [] }
        let upscale = OCRBandPlanner.upscaleFactor(pixelsPerPoint: pixelsPerPoint)
        let recognitionImage = upscale > 1 ? (scaled(bandImage, by: upscale) ?? bandImage) : bandImage

        let textRequest = VNRecognizeTextRequest()
        textRequest.recognitionLevel = level == .accurate ? .accurate : .fast
        textRequest.usesLanguageCorrection = false
        textRequest.recognitionLanguages = languages
        textRequest.minimumTextHeight = OCRBandPlanner.minimumTextHeight(pixelsPerPoint: pixelsPerPoint * upscale,
                                                                         bandHeightPx: CGFloat(recognitionImage.height))
        let requestHandler = VNImageRequestHandler(cgImage: recognitionImage, options: [:])
        do {
            try requestHandler.perform([textRequest])
        } catch {
            return []
        }
        return (textRequest.results ?? []).compactMap { observation -> OCRLine? in
            guard let topCandidate = observation.topCandidates(1).first, !topCandidate.string.isEmpty else { return nil }
            // Normalised box in the (possibly upscaled) band → native crop →
            // CG, through the one CaptureFrame.
            let frameCG = frame.cgRect(visionBox: observation.boundingBox, cropPx: bandRect)
            return OCRLine(text: topCandidate.string, frameCG: frameCG, displayID: frame.display.displayID, confidence: topCandidate.confidence)
        }
    }

    static func scaled(_ image: CGImage, by factor: CGFloat) -> CGImage? {
        let scaledWidth = Int(CGFloat(image.width) * factor)
        let scaledHeight = Int(CGFloat(image.height) * factor)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: scaledWidth, height: scaledHeight, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: colorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: scaledWidth, height: scaledHeight))
        return context.makeImage()
    }

    /// Same text and IoU > 0.5 → one line (the more confident one).
    public static func deduplicated(_ lines: [OCRLine]) -> [OCRLine] {
        var keptLines: [OCRLine] = []
        for line in lines.sorted(by: { $0.confidence > $1.confidence }) {
            let isDuplicate = keptLines.contains { keptLine in
                keptLine.text == line.text && keptLine.frameCG.intersectionOverUnion(with: line.frameCG) > 0.5
            }
            if !isDuplicate { keptLines.append(line) }
        }
        return keptLines
    }

    /// Approximate CG box of a substring of a line, by character position
    /// (used when the query is only part of a line).
    public static func substringFrame(of characterRange: Range<Int>, inLineOfLength lineLength: Int, lineFrameCG: CGRect) -> CGRect {
        guard lineLength > 0 else { return lineFrameCG }
        let startFraction = CGFloat(characterRange.lowerBound) / CGFloat(lineLength)
        let endFraction = CGFloat(characterRange.upperBound) / CGFloat(lineLength)
        return CGRect(x: lineFrameCG.minX + startFraction * lineFrameCG.width, y: lineFrameCG.minY,
                      width: max(1, (endFraction - startFraction) * lineFrameCG.width), height: lineFrameCG.height)
    }
}
