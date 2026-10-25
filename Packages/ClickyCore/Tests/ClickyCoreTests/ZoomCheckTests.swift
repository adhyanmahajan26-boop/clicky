//
//  ZoomCheckTests.swift
//  ClickyCoreTests
//
//  P6.1 Haiku zoom check: the reply grammar, the crop (3× padded target,
//  at least 300×200 pt, kept on its display), mapping crop pixels back to
//  CG at 1× and 2× and on a display left of / above the main one, the
//  decision rules for each reply, the "moved on" skip, and the render.
//

import CoreGraphics
import Foundation
import Testing
@testable import ClickyCore

private func display(_ bounds: CGRect, id: CGDirectDisplayID = 1) -> DisplayInfo {
    DisplayInfo(displayID: id, localizedName: "Test", boundsCG: bounds, visibleCG: bounds, frameAppKit: bounds, isMain: bounds.origin == .zero)
}

private func element(_ label: String?, frame: CGRect, displayID: CGDirectDisplayID = 1, isBehind: Bool = false) -> GroundingElement {
    GroundingElement(role: .button, label: label, frameCG: frame, processIdentifier: 42, displayID: displayID, isInteractive: true,
                     isBehind: isBehind, source: .accessibility)
}

private final class StaticLookup: GroundingLiveLookup {
    func refreshedFrame(of element: GroundingElement) -> CGRect? { element.visibleFrameCG }
    func textRanges(of query: String, in element: GroundingElement) -> [(frameCG: CGRect, isFuzzy: Bool)] { [] }
}

@Suite("Zoom check (P6.1)")
struct ZoomCheckTests {
    // MARK: Reply parser

    @Test func parsesTheThreeReplyForms() {
        #expect(ZoomCheck.parseReply("OK") == .ok)
        #expect(ZoomCheck.parseReply("  OK\n") == .ok)
        #expect(ZoomCheck.parseReply("#12") == .element(12))
        #expect(ZoomCheck.parseReply("\t#7 ") == .element(7))
        #expect(ZoomCheck.parseReply("120,45") == .point(CGPoint(x: 120, y: 45)))
        #expect(ZoomCheck.parseReply(" 0,0\n") == .point(.zero))
    }

    @Test func ignoresEverythingElse() {
        for reply in ["", "ok", "Ok", "OK.", "OK, it is", "Yes", "#", "#a", "# 12", "#12 is right", "12", "12, 45", "12,45,3",
                      "-3,4", "1.5,2", "(12,45)", "x,y", "OK\nOK", "#12\n#13"] {
            #expect(ZoomCheck.parseReply(reply) == nil, "\(reply.debugDescription) should be ignored")
        }
    }

    // MARK: Crop

    @Test func cropIsThreeTimesThePaddedTarget() {
        let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let target = CGRect(x: 800, y: 500, width: 200, height: 100)
        let padded = ZoomCheck.paddedTarget(target)
        #expect(padded == target.insetBy(dx: -10, dy: -10))
        let crop = ZoomCheck.cropRect(target: target, displayBounds: screen)
        #expect(crop.width == 3 * padded.width)
        #expect(crop.height == 3 * padded.height)
        #expect(abs(crop.midX - padded.midX) <= 0.5)
        #expect(abs(crop.midY - padded.midY) <= 0.5)
    }

    @Test func smallTargetsGetAtLeast300By200() {
        let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let crop = ZoomCheck.cropRect(target: CGRect(x: 900, y: 500, width: 20, height: 12), displayBounds: screen)
        #expect(crop.size == CGSize(width: 300, height: 200))
        #expect(abs(crop.midX - 910) <= 0.5)
        #expect(abs(crop.midY - 506) <= 0.5)
        // A zero-size raw point still gets a crop.
        #expect(ZoomCheck.cropRect(target: CGRect(x: 50, y: 50, width: 0, height: 0), displayBounds: screen).size == CGSize(width: 300, height: 200))
    }

    @Test func cropIsClampedToItsDisplay() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let cornerCrop = ZoomCheck.cropRect(target: CGRect(x: 2, y: 2, width: 30, height: 20), displayBounds: screen)
        #expect(cornerCrop.origin == .zero)
        #expect(cornerCrop.size == CGSize(width: 300, height: 200))

        let farCornerCrop = ZoomCheck.cropRect(target: CGRect(x: 1420, y: 880, width: 18, height: 18), displayBounds: screen)
        #expect(farCornerCrop.maxX == screen.maxX)
        #expect(farCornerCrop.maxY == screen.maxY)
        #expect(screen.contains(farCornerCrop))

        // 3× would be bigger than the display: the whole display.
        let hugeCrop = ZoomCheck.cropRect(target: CGRect(x: 100, y: 100, width: 1000, height: 600), displayBounds: screen)
        #expect(hugeCrop == screen)
    }

    @Test func cropStaysOnANegativeOriginDisplay() {
        let leftScreen = CGRect(x: -1920, y: -300, width: 1920, height: 1080)
        let crop = ZoomCheck.cropRect(target: CGRect(x: -1915, y: -295, width: 40, height: 20), displayBounds: leftScreen)
        #expect(crop.minX == leftScreen.minX)
        #expect(crop.minY == leftScreen.minY)
        #expect(leftScreen.contains(crop))
        let rightEdgeCrop = ZoomCheck.cropRect(target: CGRect(x: -30, y: 400, width: 25, height: 20), displayBounds: leftScreen)
        #expect(rightEdgeCrop.maxX == 0)
        #expect(leftScreen.contains(rightEdgeCrop))
    }

    // MARK: Mapping

    @Test func cropMappingAtOneX() {
        let screen = display(CGRect(x: 0, y: 0, width: 1920, height: 1080))
        let crop = CGRect(x: 600, y: 300, width: 300, height: 200)
        let native = PixelSize(width: 300, height: 200)
        let model = ZoomCheck.modelImageSize(nativeSize: native)
        #expect(model == native)
        let frame = ZoomCheck.cropFrame(display: screen, cropRegionCG: crop, nativeSize: native, modelSize: model)
        #expect(frame.cg(fromModelPx: CGPoint(x: 0, y: 0)) == CGPoint(x: 600.5, y: 300.5))
        #expect(frame.cg(fromModelPx: CGPoint(x: 150, y: 100)) == CGPoint(x: 750.5, y: 400.5))
        #expect(frame.cg(fromModelPx: CGPoint(x: 299, y: 199)) == CGPoint(x: 899.5, y: 499.5))
    }

    @Test func cropMappingAtTwoXIsDownscaledForTheModel() {
        let screen = display(CGRect(x: 0, y: 0, width: 1512, height: 982))
        let crop = CGRect(x: 100, y: 100, width: 900, height: 600)
        let native = PixelSize(width: 1800, height: 1200)
        let model = ZoomCheck.modelImageSize(nativeSize: native)
        #expect(model.width < native.width)
        #expect(ClaudeImageSizing.fits(model, maxEdge: 1568, maxTokens: 1568))
        let frame = ZoomCheck.cropFrame(display: screen, cropRegionCG: crop, nativeSize: native, modelSize: model)
        // Pixel centres: pixel (i, j) covers crop/model points each.
        let pointsPerModelPixel = crop.width / CGFloat(model.width)
        let mapped = frame.cg(fromModelPx: CGPoint(x: 10, y: 20))
        #expect(abs(mapped.x - (100 + 10.5 * pointsPerModelPixel)) < 1e-9)
        #expect(abs(mapped.y - (100 + 20.5 * crop.height / CGFloat(model.height))) < 1e-9)
        // And back.
        let roundTrip = frame.modelPx(fromCG: mapped)
        #expect(abs(roundTrip.x - 10) < 1e-9 && abs(roundTrip.y - 20) < 1e-9)

        // An unscaled 2× crop (small enough to send whole): 2 px per point.
        let smallCrop = CGRect(x: 200, y: 200, width: 300, height: 200)
        let smallNative = PixelSize(width: 600, height: 400)
        let smallFrame = ZoomCheck.cropFrame(display: screen, cropRegionCG: smallCrop, nativeSize: smallNative,
                                             modelSize: ZoomCheck.modelImageSize(nativeSize: smallNative))
        #expect(smallFrame.modelSize == smallNative)
        #expect(smallFrame.cg(fromModelPx: CGPoint(x: 0, y: 0)) == CGPoint(x: 200.25, y: 200.25))
        #expect(smallFrame.cg(fromModelPx: CGPoint(x: 599, y: 399)) == CGPoint(x: 499.75, y: 399.75))
    }

    @Test func cropMappingOnANegativeOriginDisplay() {
        let leftScreen = display(CGRect(x: -1920, y: -300, width: 1920, height: 1080), id: 2)
        let crop = ZoomCheck.cropRect(target: CGRect(x: -1000, y: -100, width: 40, height: 20), displayBounds: leftScreen.boundsCG)
        let native = PixelSize(width: Int(crop.width * 2), height: Int(crop.height * 2))
        let frame = ZoomCheck.cropFrame(display: leftScreen, cropRegionCG: crop, nativeSize: native,
                                        modelSize: ZoomCheck.modelImageSize(nativeSize: native))
        let topLeft = frame.cg(fromModelPx: .zero)
        #expect(topLeft.x == crop.minX + 0.25)
        #expect(topLeft.y == crop.minY + 0.25)
        #expect(topLeft.x < 0 && topLeft.y < 0)
        let centre = frame.cg(fromModelPx: CGPoint(x: native.width / 2, y: native.height / 2))
        #expect(abs(centre.x - (crop.midX + 0.25)) < 1e-9)
        #expect(abs(centre.y - (crop.midY + 0.25)) < 1e-9)
    }

    // MARK: Candidates and decisions

    private func fixture() -> (registry: ElementRegistry, crop: CGRect, frame: CaptureFrame, markRect: CGRect) {
        var registry = ElementRegistry()
        let markRect = CGRect(x: 700, y: 400, width: 80, height: 24)
        _ = registry.append(element("Reply", frame: markRect))                                           // #1, the marked one
        _ = registry.append(element("Reply All", frame: CGRect(x: 800, y: 400, width: 90, height: 24)))  // #2
        _ = registry.append(element("Archive", frame: CGRect(x: 600, y: 440, width: 80, height: 24)))    // #3
        _ = registry.append(element("Far away", frame: CGRect(x: 100, y: 100, width: 80, height: 24)))   // #4 outside
        _ = registry.append(element("Covered", frame: CGRect(x: 650, y: 380, width: 40, height: 20), isBehind: true)) // #5
        _ = registry.append(element("Window", frame: CGRect(x: 0, y: 0, width: 1920, height: 1080)))     // #6 too big
        _ = registry.append(element("Other screen", frame: CGRect(x: 720, y: 410, width: 20, height: 10), displayID: 9)) // #7
        let screen = display(CGRect(x: 0, y: 0, width: 1920, height: 1080))
        let crop = ZoomCheck.cropRect(target: markRect, displayBounds: screen.boundsCG)
        let native = PixelSize(width: Int(crop.width), height: Int(crop.height))
        let frame = ZoomCheck.cropFrame(display: screen, cropRegionCG: crop, nativeSize: native, modelSize: ZoomCheck.modelImageSize(nativeSize: native))
        return (registry, crop, frame, markRect)
    }

    @Test func candidatesAreTheElementsInsideTheCrop() {
        let (registry, crop, _, _) = fixture()
        let candidateIDs = ZoomCheck.candidates(in: registry, cropCG: crop, displayID: 1).map(\.elementID)
        #expect(candidateIDs == [1, 2, 3])
    }

    @Test func okConfirms() {
        let (registry, crop, frame, markRect) = fixture()
        let candidates = ZoomCheck.candidates(in: registry, cropCG: crop, displayID: 1)
        #expect(ZoomCheck.decide(replyText: "OK", markName: "Reply", candidates: candidates, currentTargetCG: markRect, frame: frame) == .confirm)
    }

    @Test func idRepliesMoveOnlyToAMatchingCandidate() {
        let (registry, crop, frame, markRect) = fixture()
        let candidates = ZoomCheck.candidates(in: registry, cropCG: crop, displayID: 1)
        let moved = ZoomCheck.decide(replyText: "#2", markName: "Reply all", candidates: candidates, currentTargetCG: markRect, frame: frame)
        #expect(moved == .moveToElement(candidates[1]))
        #expect(moved.action == .movedToElement)
        // Label too different from the name: a correct mark is never moved.
        #expect(ZoomCheck.decide(replyText: "#3", markName: "Reply", candidates: candidates, currentTargetCG: markRect, frame: frame) == .ignore(.ignoredLabelMismatch))
        // Not badged in the crop.
        #expect(ZoomCheck.decide(replyText: "#4", markName: "Far away", candidates: candidates, currentTargetCG: markRect, frame: frame) == .ignore(.ignoredUnknownID))
        #expect(ZoomCheck.decide(replyText: "#99", markName: "Reply", candidates: candidates, currentTargetCG: markRect, frame: frame) == .ignore(.ignoredUnknownID))
        // The element it's already on.
        #expect(ZoomCheck.decide(replyText: "#1", markName: "Reply", candidates: candidates, currentTargetCG: markRect, frame: frame) == .ignore(.ignoredSameTarget))
    }

    @Test func pointRepliesMoveOnlyWhenOutsideThePaddedRect() {
        let (registry, crop, frame, markRect) = fixture()
        let candidates = ZoomCheck.candidates(in: registry, cropCG: crop, displayID: 1)
        // Inside the mark's padded rect: already right.
        let insidePixel = frame.modelPx(fromCG: markRect.center)
        let insideReply = "\(Int(insidePixel.x.rounded())),\(Int(insidePixel.y.rounded()))"
        #expect(ZoomCheck.decide(replyText: insideReply, markName: "Reply", candidates: candidates, currentTargetCG: markRect, frame: frame) == .ignore(.ignoredInsideRect))
        // On Archive, outside: move there (in CG, at the pixel's centre).
        let archivePixel = frame.modelPx(fromCG: CGPoint(x: 640, y: 452))
        let archiveReply = "\(Int(archivePixel.x.rounded())),\(Int(archivePixel.y.rounded()))"
        guard case .moveToPoint(let pointCG) = ZoomCheck.decide(replyText: archiveReply, markName: "Archive", candidates: candidates,
                                                                currentTargetCG: markRect, frame: frame) else {
            Issue.record("expected a move")
            return
        }
        #expect(abs(pointCG.x - 640) <= 1 && abs(pointCG.y - 452) <= 1)
        #expect(ZoomCheck.decide(replyText: "it's #3", markName: "Archive", candidates: candidates, currentTargetCG: markRect, frame: frame) == .ignore(.ignoredUnparsable))
    }

    @Test func pointReplySnapsWithTheResolver() {
        let (registry, _, frame, _) = fixture()
        let resolver = TargetResolver(registry: registry, framesByScreenNumber: [:], cursorCG: .zero, windowStack: nil, lookup: StaticLookup())
        let snapped = resolver.snapPoint(CGPoint(x: 640, y: 452), name: "Archive", frame: frame)
        #expect(snapped.method == .snapped)
        #expect(snapped.elementID == 3)
        #expect(snapped.frameCG == CGRect(x: 600, y: 440, width: 80, height: 24))
        let raw = resolver.snapPoint(CGPoint(x: 1500, y: 900), name: "Nothing", frame: frame)
        #expect(raw.method == .raw)
    }

    @Test func movedOnSkipsTheResult() {
        #expect(ZoomCheck.shouldApply(startedForQuestion: 3, currentQuestion: 3, isMarkStillLive: true))
        // A new question started while Haiku was looking.
        #expect(!ZoomCheck.shouldApply(startedForQuestion: 3, currentQuestion: 4, isMarkStillLive: true))
        // The mark was cleared ("clear", auto-clear, a CLEAR tag).
        #expect(!ZoomCheck.shouldApply(startedForQuestion: 3, currentQuestion: 3, isMarkStillLive: false))
        #expect(!ZoomCheck.shouldApply(startedForQuestion: 3, currentQuestion: 4, isMarkStillLive: false))
    }

    @Test func promptNamesTheLabel() {
        #expect(ZoomCheck.prompt(label: "Reply All") == "Is the orange ring around 'Reply All'? Reply exactly OK, or the correct #id, or x,y in this image's pixels.")
    }

    // MARK: Render

    @Test func renderDrawsTheOrangeRingAndBadges() throws {
        let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(data: nil, width: 300, height: 200, bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
                                             bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 300, height: 200))
        let whiteImage = try #require(context.makeImage())
        let ringRect = CGRect(x: 120, y: 80, width: 60, height: 40)
        let placements = BadgeLayout.place(candidates: [BadgeLayout.Candidate(elementID: 2, rectPx: CGRect(x: 20, y: 20, width: 40, height: 20))],
                                           allElementRectsPx: [CGRect(x: 20, y: 20, width: 40, height: 20)], imageSize: CGSize(width: 300, height: 200))
        #expect(placements.count == 1)
        let rendered = try #require(ZoomCheckRenderer.render(onto: whiteImage, ringRectPx: ringRect, placements: placements, outlinedRectsPx: [2: CGRect(x: 20, y: 20, width: 40, height: 20)]))
        #expect(rendered.width == 300 && rendered.height == 200)

        let pixelData = try #require(rendered.dataProvider?.data as Data?)
        func pixel(_ x: Int, _ y: Int) -> (UInt8, UInt8, UInt8) {
            let offset = y * rendered.bytesPerRow + x * 4
            return (pixelData[offset], pixelData[offset + 1], pixelData[offset + 2])
        }
        // The ring's left edge, on the horizontal centre line (top-left image coordinates).
        let ellipse = ZoomCheckRenderer.ringEllipse(around: ringRect)
        let ringPixel = pixel(Int(ellipse.minX.rounded()), Int(ringRect.midY))
        #expect(ringPixel.0 > 200 && ringPixel.1 > 100 && ringPixel.1 < 170 && ringPixel.2 < 60)
        // Inside the ring stays untouched.
        let insidePixel = pixel(Int(ringRect.midX), Int(ringRect.midY))
        #expect(insidePixel == (255, 255, 255))
        // The badge is magenta.
        let badge = placements[0].badgeRectPx
        let badgePixel = pixel(Int(badge.minX) + 1, Int(badge.minY) + 1)
        #expect(badgePixel.0 > 200 && badgePixel.1 < 90 && badgePixel.2 > 110)
    }
}
