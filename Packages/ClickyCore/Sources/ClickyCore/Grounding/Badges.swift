//
//  Badges.swift
//  ClickyCore
//
//  Draws element ids onto the image the model sees (at its final size, so
//  nothing gets resampled after drawing): a 2 px #FF2D95 outline at 70% around
//  each badged element and a white bold id on a magenta tag, plus a crosshair
//  at the cursor. Placement is greedy in id order: try the corners starting
//  outside the top-left, never overlap another badge, and never cover more
//  than 30% of ANY listed element. If nothing fits at 11.5 px, try 9 px;
//  otherwise that element gets no badge (it stays in the list).
//

import CoreGraphics
import CoreText
import Foundation

public enum BadgeLayout {
    public static let defaultFontSize: CGFloat = 11.5
    public static let shrunkFontSize: CGFloat = 9
    public static let maximumCoveredFraction: CGFloat = 0.30

    public struct Candidate: Sendable {
        public let elementID: Int
        /// The element in model pixels (top-left origin).
        public let rectPx: CGRect

        public init(elementID: Int, rectPx: CGRect) {
            self.elementID = elementID
            self.rectPx = rectPx
        }
    }

    public struct Placement: Sendable, Equatable {
        public let elementID: Int
        public let badgeRectPx: CGRect
        public let fontSize: CGFloat
    }

    /// Badge size for an id at a font size (estimated from bold digit widths).
    public static func badgeSize(for elementID: Int, fontSize: CGFloat) -> CGSize {
        let digitCount = CGFloat(String(elementID).count)
        return CGSize(width: (digitCount * 0.62 * fontSize + 5).rounded(.up), height: (fontSize + 3).rounded(.up))
    }

    public static func place(candidates: [Candidate], allElementRectsPx: [CGRect], imageSize: CGSize) -> [Placement] {
        var placements: [Placement] = []
        let imageBounds = CGRect(origin: .zero, size: imageSize)

        for candidate in candidates {
            for fontSize in [defaultFontSize, shrunkFontSize] {
                let size = badgeSize(for: candidate.elementID, fontSize: fontSize)
                let elementRect = candidate.rectPx
                let corners: [CGPoint] = [
                    CGPoint(x: elementRect.minX - size.width, y: elementRect.minY - size.height), // outside top-left
                    CGPoint(x: elementRect.maxX, y: elementRect.minY - size.height),              // outside top-right
                    CGPoint(x: elementRect.minX - size.width, y: elementRect.maxY),               // outside bottom-left
                    CGPoint(x: elementRect.maxX, y: elementRect.maxY),                            // outside bottom-right
                    CGPoint(x: elementRect.minX, y: elementRect.minY),                            // inside top-left
                    CGPoint(x: elementRect.maxX - size.width, y: elementRect.minY),               // inside top-right
                    CGPoint(x: elementRect.minX, y: elementRect.maxY - size.height),              // inside bottom-left
                    CGPoint(x: elementRect.maxX - size.width, y: elementRect.maxY - size.height)  // inside bottom-right
                ]
                if let fittingRect = corners
                    .map({ CGRect(origin: $0, size: size) })
                    .first(where: { badgeRect in
                        imageBounds.contains(badgeRect)
                            && !placements.contains { $0.badgeRectPx.intersects(badgeRect) }
                            && !allElementRectsPx.contains { elementRect in
                                elementRect.area > 0 && badgeRect.intersection(elementRect).area > maximumCoveredFraction * elementRect.area
                            }
                    }) {
                    placements.append(Placement(elementID: candidate.elementID, badgeRectPx: fittingRect, fontSize: fontSize))
                    break
                }
            }
        }
        return placements
    }
}

public enum BadgeRenderer {
    /// #FF2D95
    static let magenta = CGColor(srgbRed: 1, green: 0x2D / 255.0, blue: 0x95 / 255.0, alpha: 1)

    /// Draws outlines, badges and the cursor crosshair onto `image` (already
    /// at model size) and returns the new image. Rects are model pixels,
    /// top-left origin.
    public static func render(onto image: CGImage, placements: [BadgeLayout.Placement], outlinedRectsPx: [Int: CGRect], cursorPx: CGPoint?) -> CGImage? {
        guard let sRGBColorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: sRGBColorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        let imageHeight = CGFloat(image.height)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        // Work in top-left coordinates like the model's pixels.
        context.translateBy(x: 0, y: imageHeight)
        context.scaleBy(x: 1, y: -1)

        context.setStrokeColor(magenta.copy(alpha: 0.7) ?? magenta)
        context.setLineWidth(2)
        for placement in placements {
            if let outlineRect = outlinedRectsPx[placement.elementID] {
                context.stroke(outlineRect.insetBy(dx: -1, dy: -1))
            }
        }

        for placement in placements {
            context.setFillColor(magenta)
            let badgePath = CGPath(roundedRect: placement.badgeRectPx, cornerWidth: 3, cornerHeight: 3, transform: nil)
            context.addPath(badgePath)
            context.fillPath()
            drawLabel(String(placement.elementID), in: placement.badgeRectPx, fontSize: placement.fontSize, context: context)
        }

        if let cursorPx {
            // A small white-edged magenta crosshair marks the cursor.
            for (lineWidth, color) in [(CGFloat(4), CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)), (CGFloat(2), magenta)] {
                context.setStrokeColor(color)
                context.setLineWidth(lineWidth)
                context.move(to: CGPoint(x: cursorPx.x - 9, y: cursorPx.y))
                context.addLine(to: CGPoint(x: cursorPx.x + 9, y: cursorPx.y))
                context.move(to: CGPoint(x: cursorPx.x, y: cursorPx.y - 9))
                context.addLine(to: CGPoint(x: cursorPx.x, y: cursorPx.y + 9))
                context.strokePath()
            }
        }
        return context.makeImage()
    }

    private static func drawLabel(_ text: String, in badgeRect: CGRect, fontSize: CGFloat, context: CGContext) {
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, fontSize, nil)
        let attributes: [CFString: Any] = [kCTFontAttributeName: font, kCTForegroundColorAttributeName: CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)]
        guard let attributedText = CFAttributedStringCreate(nil, text as CFString, attributes as CFDictionary) else { return }
        let line = CTLineCreateWithAttributedString(attributedText)
        let textBounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
        context.saveGState()
        // CoreText draws y-up; flip locally around the badge.
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        let textX = badgeRect.midX - textBounds.width / 2 - textBounds.minX
        let textY = badgeRect.midY + (textBounds.height / 2) + textBounds.minY - 0.5
        context.textPosition = CGPoint(x: textX, y: textY)
        CTLineDraw(line, context)
        context.restoreGState()
    }
}
