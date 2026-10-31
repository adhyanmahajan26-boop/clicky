//
//  RecheckMath.swift
//  ClickyCore
//
//  The pure parts of a mark's OCR re-check: which part of the screen to
//  capture, the ScreenCaptureKit source rect and output size for it, and
//  whether the OCR'd lines still show the target's name where the mark is.
//  The capture itself excludes Clicky's own windows, so a mark (or its
//  label) can never confirm itself.
//

import CoreGraphics
import Foundation

public enum RecheckMath {
    public static let cropMargin: CGFloat = 24
    public static let maximumCentreDistance: CGFloat = 6

    /// Target grown by 24 pt, ∩ its display.
    public static func cropRect(target: CGRect, displayBounds: CGRect) -> CGRect {
        target.insetBy(dx: -cropMargin, dy: -cropMargin).intersection(displayBounds)
    }

    /// SCStreamConfiguration.sourceRect: display-local points, top-left origin.
    public static func sourceRect(region: CGRect, displayBounds: CGRect) -> CGRect {
        CGRect(x: region.minX - displayBounds.minX, y: region.minY - displayBounds.minY, width: region.width, height: region.height)
    }

    /// Output pixel size: region × pointPixelScale.
    public static func pixelSize(region: CGRect, pointPixelScale: CGFloat) -> PixelSize {
        PixelSize(width: Int((region.width * pointPixelScale).rounded()), height: Int((region.height * pointPixelScale).rounded()))
    }

    /// Where the name was found: a fuzzy match (≤ 1 edit per 6 characters)
    /// whose box comes within 6 pt of the target's centre; nil = not found.
    public static func matchingFrame(name: String, lines: [OCRLine], target: CGRect) -> CGRect? {
        let targetCenter = target.center
        for line in lines {
            let normalizedLineLength = LabelSimilarity.normalize(line.text).count
            for occurrence in LabelSimilarity.findOccurrences(of: name, in: line.text) {
                let occurrenceFrame = OCREngine.substringFrame(of: occurrence.range, inLineOfLength: normalizedLineLength, lineFrameCG: line.frameCG)
                if occurrenceFrame.edgeDistance(to: targetCenter) <= maximumCentreDistance {
                    return occurrenceFrame
                }
            }
        }
        return nil
    }
}
