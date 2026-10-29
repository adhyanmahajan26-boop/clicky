//
//  ZoomCheck.swift
//  ClickyCore
//
//  P6.1 (behind v2.grounding.verifyWithHaiku): a second look at a tentative
//  mark. The app crops 3× the mark's padded target (at least 300×200 pt,
//  kept on its display), captures it at native scale without Clicky's
//  windows, downsizes it to what Claude sees (1568 edge / 1568 tokens),
//  rings the target in orange, badges the registry elements inside the crop
//  in magenta, and asks Haiku one question. This file is the maths and the
//  decisions: the crop, its CaptureFrame, which elements get badges, the
//  reply grammar (OK | #id | x,y) and what each reply may change.
//

import CoreGraphics
import Foundation

public enum ZoomCheck {
    public static let cropScale: CGFloat = 3
    public static let minimumCropSize = CGSize(width: 300, height: 200)
    public static let maximumImageEdge = 1568
    public static let maximumImageTokens = 1568
    /// A #id reply moves the mark only when its label matches this well.
    public static let minimumCandidateLabelSimilarity = 0.5
    /// Confidence of a mark the check confirmed or corrected.
    public static let checkedConfidence = 0.9
    /// 3 px #FF8A00 ring, drawn outside the padded target.
    public static let ringLineWidth: CGFloat = 3

    public static let systemPromptFileName = "zoom-check-prompt.md"
    public static let systemPrompt = """
    You check one mark on a zoomed screenshot crop. The orange ring is the mark; magenta tags show element ids. \
    Answer with one line and nothing else: OK if the ring is on the named thing, else the #id of the right element, \
    else the x,y pixel position of the right thing in this image.
    """

    public static func prompt(label: String) -> String {
        "Is the orange ring around '\(label)'? Reply exactly OK, or the correct #id, or x,y in this image's pixels."
    }

    // MARK: Reply

    public enum Reply: Equatable, Sendable {
        case ok
        case element(Int)
        /// Model pixels of the crop image.
        case point(CGPoint)
    }

    private static let elementPattern = try! NSRegularExpression(pattern: #"^#(\d+)$"#)
    private static let pointPattern = try! NSRegularExpression(pattern: #"^(\d+),(\d+)$"#)

    /// ^OK$ | ^#\d+$ | ^\d+,\d+$ after trimming whitespace; anything else is nil.
    public static func parseReply(_ replyText: String) -> Reply? {
        let trimmedReply = replyText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedReply == "OK" { return .ok }
        let fullRange = NSRange(trimmedReply.startIndex..., in: trimmedReply)
        func group(_ match: NSTextCheckingResult, _ index: Int) -> Int? {
            Range(match.range(at: index), in: trimmedReply).flatMap { Int(trimmedReply[$0]) }
        }
        if let match = elementPattern.firstMatch(in: trimmedReply, range: fullRange), let elementID = group(match, 1) {
            return .element(elementID)
        }
        if let match = pointPattern.firstMatch(in: trimmedReply, range: fullRange), let x = group(match, 1), let y = group(match, 2) {
            return .point(CGPoint(x: x, y: y))
        }
        return nil
    }

    // MARK: Crop

    /// The ring's padded target (MarkLayout's pad).
    public static func paddedTarget(_ target: CGRect) -> CGRect {
        MarkLayout.padded(target)
    }

    /// 3× the padded target around its centre, at least 300×200 pt, whole
    /// points, shifted (and if need be shrunk) to stay on its display.
    public static func cropRect(target: CGRect, displayBounds: CGRect) -> CGRect {
        let padded = paddedTarget(target)
        let width = min(max(cropScale * padded.width, minimumCropSize.width).rounded(.up), displayBounds.width)
        let height = min(max(cropScale * padded.height, minimumCropSize.height).rounded(.up), displayBounds.height)
        let originX = min(max((padded.midX - width / 2).rounded(), displayBounds.minX), displayBounds.maxX - width)
        let originY = min(max((padded.midY - height / 2).rounded(), displayBounds.minY), displayBounds.maxY - height)
        return CGRect(x: originX, y: originY, width: width, height: height)
    }

    /// The size the model will see the native crop at.
    public static func modelImageSize(nativeSize: PixelSize) -> PixelSize {
        ClaudeImageSizing.claudeResizedSize(nativeSize, maxEdge: maximumImageEdge, maxTokens: maximumImageTokens)
    }

    /// The crop as an image of the screen: native capture, model-size send.
    public static func cropFrame(display: DisplayInfo, cropRegionCG: CGRect, nativeSize: PixelSize, modelSize: PixelSize) -> CaptureFrame {
        CaptureFrame(display: display, screenNumber: 0, regionCG: cropRegionCG, native: nativeSize, model: modelSize)
    }

    // MARK: Candidates

    public struct Candidate: Equatable, Sendable {
        public let elementID: Int
        public let label: String?
        public let frameCG: CGRect

        public init(elementID: Int, label: String?, frameCG: CGRect) {
            self.elementID = elementID
            self.label = label
            self.frameCG = frameCG
        }
    }

    /// Registry elements on the crop's display whose centre is inside the
    /// crop, smaller than half of it and not behind another app: these get
    /// badges and are the only ids a #id reply may name.
    public static func candidates(in registry: ElementRegistry, cropCG: CGRect, displayID: CGDirectDisplayID) -> [Candidate] {
        registry.orderedIDs.compactMap { elementID in
            guard let element = registry[elementID], element.displayID == displayID, !element.isBehind,
                  element.visibleFrameCG.width > 0, element.visibleFrameCG.height > 0,
                  cropCG.contains(element.visibleFrameCG.center),
                  element.visibleFrameCG.area <= 0.5 * cropCG.area else { return nil }
            return Candidate(elementID: elementID, label: element.label, frameCG: element.visibleFrameCG)
        }
    }

    // MARK: Decision

    /// What a reply did, as recorded in turn.json's zoomCheck.action.
    public enum Action: String, Sendable {
        case confirmed
        case movedToElement
        case movedToPoint
        /// The reply wasn't OK / #id / x,y.
        case ignoredUnparsable
        /// #id not among the badged candidates.
        case ignoredUnknownID
        /// #id whose label doesn't match the mark's name (< 0.5).
        case ignoredLabelMismatch
        /// x,y inside the current padded rect: the mark is already there.
        case ignoredInsideRect
        /// #id of the element the mark is already on.
        case ignoredSameTarget
        /// The user asked something new or the mark was cleared.
        case skippedMovedOn
        /// No capture, no answer from Haiku.
        case failed
    }

    public enum Decision: Equatable, Sendable {
        case confirm
        case moveToElement(Candidate)
        /// A CG point to snap (TargetResolver's point rule) and move to.
        case moveToPoint(CGPoint)
        case ignore(Action)

        public var action: Action {
            switch self {
            case .confirm: return .confirmed
            case .moveToElement: return .movedToElement
            case .moveToPoint: return .movedToPoint
            case .ignore(let action): return action
            }
        }
    }

    /// The rules for one reply. `currentTargetCG` is the mark's rect now.
    public static func decide(replyText: String, markName: String, candidates: [Candidate], currentTargetCG: CGRect, frame: CaptureFrame) -> Decision {
        guard let reply = parseReply(replyText) else { return .ignore(.ignoredUnparsable) }
        switch reply {
        case .ok:
            return .confirm
        case .element(let elementID):
            guard let candidate = candidates.first(where: { $0.elementID == elementID }) else { return .ignore(.ignoredUnknownID) }
            if candidate.frameCG == currentTargetCG { return .ignore(.ignoredSameTarget) }
            guard LabelSimilarity.labelSim(markName, candidates: [candidate.label]) >= minimumCandidateLabelSimilarity else {
                return .ignore(.ignoredLabelMismatch)
            }
            return .moveToElement(candidate)
        case .point(let modelPixel):
            let pointCG = frame.cg(fromModelPx: modelPixel)
            guard !paddedTarget(currentTargetCG).contains(pointCG) else { return .ignore(.ignoredInsideRect) }
            return .moveToPoint(pointCG)
        }
    }

    /// A finished check changes nothing once the user moved on: a newer
    /// question started, or the mark is no longer on screen.
    public static func shouldApply(startedForQuestion: Int, currentQuestion: Int, isMarkStillLive: Bool) -> Bool {
        startedForQuestion == currentQuestion && isMarkStillLive
    }
}

public enum ZoomCheckRenderer {
    /// #FF8A00
    static let orange = CGColor(srgbRed: 1, green: 0x8A / 255.0, blue: 0, alpha: 1)

    /// The image sent to Haiku: magenta outlines and badges for the
    /// candidates (BadgeRenderer), then the orange ring (an ellipse through
    /// the padded target's corners) on top. Rects are model pixels.
    public static func render(onto modelImage: CGImage, ringRectPx: CGRect, placements: [BadgeLayout.Placement], outlinedRectsPx: [Int: CGRect]) -> CGImage? {
        guard let badgedImage = BadgeRenderer.render(onto: modelImage, placements: placements, outlinedRectsPx: outlinedRectsPx, cursorPx: nil),
              let sRGBColorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: badgedImage.width, height: badgedImage.height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: sRGBColorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        let imageHeight = CGFloat(badgedImage.height)
        context.draw(badgedImage, in: CGRect(x: 0, y: 0, width: badgedImage.width, height: badgedImage.height))
        context.translateBy(x: 0, y: imageHeight)
        context.scaleBy(x: 1, y: -1)
        context.setStrokeColor(orange)
        context.setLineWidth(ZoomCheck.ringLineWidth)
        context.strokeEllipse(in: ringEllipse(around: ringRectPx))
        return context.makeImage()
    }

    /// The ellipse through a rect's corners (grown by w·k, h·k, k = (√2−1)/2).
    public static func ringEllipse(around rect: CGRect) -> CGRect {
        let growth = (2.0.squareRoot() - 1) / 2
        return rect.insetBy(dx: -rect.width * growth - ZoomCheck.ringLineWidth, dy: -rect.height * growth - ZoomCheck.ringLineWidth)
    }
}
