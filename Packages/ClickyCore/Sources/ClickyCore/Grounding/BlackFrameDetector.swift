//
//  BlackFrameDetector.swift
//  ClickyCore
//
//  ScreenCaptureKit now and then returns a frame where the wallpaper and
//  desktop widgets are fine but every app window is solid black (seen in
//  live turns right after a new app instance launched; the next capture a
//  moment later is fine). The model then says the window "shows up as a
//  blank black area". This spots such a frame: the on-screen app windows
//  (layer 0, not Clicky's, from the window list) are sampled on the
//  downsampled grey image; a window whose visible part is near-uniform
//  black (mean luma < 6, standard deviation < 3) counts as black. When at
//  least 60 % of the window area is black the frame is bad and the caller
//  captures again. Pure: the app supplies the grey image and window rects.
//

import CoreGraphics
import Foundation

public enum BlackFrameDetector {
    public static let maximumMeanLuma = 6.0
    public static let maximumStandardDeviation = 3.0
    /// Share of the windows' visible area that must be black.
    public static let blackAreaFractionThreshold = 0.60
    /// Visible window area below this many grey pixels isn't judged.
    public static let minimumWindowSamplePixels = 16
    /// Windows must cover at least this share of the image(s) for a verdict.
    public static let minimumWindowAreaFraction = 0.02

    public struct Verdict: Sendable, Equatable {
        public var judgedWindowCount: Int
        public var blackWindowCount: Int
        /// Grey pixels of visible window area judged / found black.
        public var windowSamplePixels: Int
        public var blackSamplePixels: Int
        public var imageSamplePixels: Int

        public static let empty = Verdict(judgedWindowCount: 0, blackWindowCount: 0, windowSamplePixels: 0, blackSamplePixels: 0, imageSamplePixels: 0)

        public var blackFraction: Double { windowSamplePixels > 0 ? Double(blackSamplePixels) / Double(windowSamplePixels) : 0 }

        public var isBlackFrame: Bool {
            judgedWindowCount > 0 && imageSamplePixels > 0
                && Double(windowSamplePixels) >= minimumWindowAreaFraction * Double(imageSamplePixels)
                && blackFraction >= blackAreaFractionThreshold
        }

        public static func + (lhs: Verdict, rhs: Verdict) -> Verdict {
            Verdict(judgedWindowCount: lhs.judgedWindowCount + rhs.judgedWindowCount, blackWindowCount: lhs.blackWindowCount + rhs.blackWindowCount,
                    windowSamplePixels: lhs.windowSamplePixels + rhs.windowSamplePixels, blackSamplePixels: lhs.blackSamplePixels + rhs.blackSamplePixels,
                    imageSamplePixels: lhs.imageSamplePixels + rhs.imageSamplePixels)
        }
    }

    /// One image. `windowRectsNativePx` are the app windows on it, front to
    /// back, in the capture's native pixels (the grey image may be
    /// downsampled: `nativePixelsPerPixel`). Each grey pixel belongs to the
    /// frontmost window over it, so a covered window is judged only on what
    /// shows of it.
    public static func analyze(gray: GrayImage, windowRectsNativePx: [CGRect]) -> Verdict {
        guard gray.width > 0, gray.height > 0 else { return .empty }
        let scale = CGFloat(max(1, gray.nativePixelsPerPixel))
        var owner = [Int32](repeating: -1, count: gray.width * gray.height)
        for (windowIndex, nativeRect) in windowRectsNativePx.enumerated() where !nativeRect.isNull && !nativeRect.isEmpty {
            let minX = max(0, Int((nativeRect.minX / scale).rounded(.up)))
            let maxX = min(gray.width, Int((nativeRect.maxX / scale).rounded(.down)))
            let minY = max(0, Int((nativeRect.minY / scale).rounded(.up)))
            let maxY = min(gray.height, Int((nativeRect.maxY / scale).rounded(.down)))
            guard minX < maxX, minY < maxY else { continue }
            for y in minY..<maxY {
                let rowStart = y * gray.width
                for x in minX..<maxX where owner[rowStart + x] < 0 { owner[rowStart + x] = Int32(windowIndex) }
            }
        }

        let windowCount = windowRectsNativePx.count
        var sums = [Double](repeating: 0, count: windowCount)
        var squareSums = [Double](repeating: 0, count: windowCount)
        var counts = [Int](repeating: 0, count: windowCount)
        for pixelIndex in owner.indices {
            let windowIndex = Int(owner[pixelIndex])
            guard windowIndex >= 0 else { continue }
            let luma = Double(gray.pixels[pixelIndex])
            sums[windowIndex] += luma
            squareSums[windowIndex] += luma * luma
            counts[windowIndex] += 1
        }

        var verdict = Verdict.empty
        verdict.imageSamplePixels = gray.width * gray.height
        for windowIndex in 0..<windowCount where counts[windowIndex] >= minimumWindowSamplePixels {
            let count = Double(counts[windowIndex])
            let mean = sums[windowIndex] / count
            let variance = max(0, squareSums[windowIndex] / count - mean * mean)
            verdict.judgedWindowCount += 1
            verdict.windowSamplePixels += counts[windowIndex]
            if mean < maximumMeanLuma && variance.squareRoot() < maximumStandardDeviation {
                verdict.blackWindowCount += 1
                verdict.blackSamplePixels += counts[windowIndex]
            }
        }
        return verdict
    }

    /// The app windows of `windowStack` on a capture, front to back, in its
    /// native px: layer 0, not Clicky's (the stack already leaves those and
    /// invisible windows out), at least 40x40 pt.
    public static func windowRectsNativePx(windowStack: WindowStack, frame: CaptureFrame) -> [CGRect] {
        windowStack.windows.compactMap { window -> CGRect? in
            guard window.layer == 0, window.boundsCG.width >= 40, window.boundsCG.height >= 40 else { return nil }
            let visibleCG = window.boundsCG.intersection(frame.regionCG)
            guard !visibleCG.isNull, visibleCG.width > 0, visibleCG.height > 0 else { return nil }
            return OCRCoveragePlanner.nativePxRect(fromCG: visibleCG, frame: frame)
        }
    }
}
