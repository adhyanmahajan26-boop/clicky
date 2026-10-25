import CoreGraphics
import Foundation
import Testing
@testable import ClickyCore

// Addy's three displays (CG points) plus a 4K at negative x, each with and
// without a menu bar / Dock carved out of `visible`.
private let testDisplays: [MarkSceneDisplay] = {
    let bounds: [CGRect] = [
        CGRect(x: 0, y: 0, width: 3440, height: 1440),
        CGRect(x: -1920, y: 155, width: 1920, height: 1080),
        CGRect(x: 3440, y: 198, width: 1920, height: 1080),
        CGRect(x: -5760, y: -400, width: 3840, height: 2160)
    ]
    var displays: [MarkSceneDisplay] = []
    for (index, displayBounds) in bounds.enumerated() {
        displays.append(MarkSceneDisplay(displayID: CGDirectDisplayID(index + 1), bounds: displayBounds, visible: displayBounds))
        let withChrome = CGRect(x: displayBounds.minX, y: displayBounds.minY + 25, width: displayBounds.width, height: displayBounds.height - 25 - 70)
        displays.append(MarkSceneDisplay(displayID: CGDirectDisplayID(index + 11), bounds: displayBounds, visible: withChrome))
    }
    return displays
}()

/// SplitMix64: reproducible random cases.
private struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var mixed = state
        mixed = (mixed ^ (mixed >> 30)) &* 0xBF58_476D_1CE4_E5B9
        mixed = (mixed ^ (mixed >> 27)) &* 0x94D0_49BB_1331_11EB
        return mixed ^ (mixed >> 31)
    }
}

/// A random target on `display`: anywhere, or hugging an edge / corner, the
/// menu bar or the Dock. Its centre is always on the display.
private func randomTarget(on display: MarkSceneDisplay, using generator: inout SeededGenerator) -> CGRect {
    let bounds = display.bounds
    // Log-uniform sides (2–1200 pt) so icons and text rows are as common as panels.
    let width = exp(CGFloat.random(in: log(2)...log(min(1200, bounds.width - 8)), using: &generator))
    let height = exp(CGFloat.random(in: log(2)...log(min(1200, bounds.height - 8)), using: &generator))
    var originX = CGFloat.random(in: bounds.minX...(bounds.maxX - width), using: &generator)
    var originY = CGFloat.random(in: bounds.minY...(bounds.maxY - height), using: &generator)
    switch Int.random(in: 0..<6, using: &generator) {
    case 0: originY = bounds.minY + CGFloat.random(in: 0...3, using: &generator)                  // menu bar
    case 1: originY = bounds.maxY - height - CGFloat.random(in: 0...3, using: &generator)         // Dock
    case 2: originX = bounds.minX; originY = bounds.minY                                           // top-left corner
    case 3: originX = bounds.maxX - width; originY = bounds.maxY - height                         // bottom-right corner
    default: break
    }
    return CGRect(x: originX, y: originY, width: width, height: height)
}

private func distance(from point: CGPoint, to rect: CGRect) -> CGFloat {
    let deltaX = max(rect.minX - point.x, 0, point.x - rect.maxX)
    let deltaY = max(rect.minY - point.y, 0, point.y - rect.maxY)
    return hypot(deltaX, deltaY)
}

private func corners(of rect: CGRect) -> [CGPoint] {
    [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY), CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY)]
}

/// Fraction of `rect` (grid-sampled) inside `shape`.
private func coveredFraction(of rect: CGRect, by shape: MarkShapeSpec) -> Double {
    let gridSize = 20
    var insideCount = 0
    for row in 0..<gridSize {
        for column in 0..<gridSize {
            let samplePoint = CGPoint(x: rect.minX + (CGFloat(column) + 0.5) / CGFloat(gridSize) * rect.width,
                                      y: rect.minY + (CGFloat(row) + 0.5) / CGFloat(gridSize) * rect.height)
            if shape.contains(samplePoint) { insideCount += 1 }
        }
    }
    return Double(insideCount) / Double(gridSize * gridSize)
}

private func containsWithTolerance(_ outer: CGRect, _ inner: CGRect, tolerance: CGFloat = 1e-6) -> Bool {
    outer.insetBy(dx: -tolerance, dy: -tolerance).contains(inner)
}

// MARK: - Arrow properties

@Test func arrowPropertiesHoldOnTenThousandRandomTargets() {
    var generator = SeededGenerator(state: 0xC11C_C1)
    var minimumGap = CGFloat.greatestFiniteMagnitude
    var labelAllowedButMissing = 0
    for caseIndex in 0..<10_000 {
        let display = testDisplays[caseIndex % testDisplays.count]
        let target = randomTarget(on: display, using: &generator)
        let paddedTarget = MarkLayout.padded(target)
        let labelSize = LabelPlacer.size(for: ["Run", "Build settings", "Export as PDF…"][caseIndex % 3])
        let arrow = MarkLayout.arrow(target: target, visible: display.visible, labelSize: labelSize)

        let gap = distance(from: arrow.tip, to: paddedTarget)
        minimumGap = min(minimumGap, gap)
        #expect(gap >= 6 - 1e-6, "tip gap \(gap) for \(target)")
        // Exactly 6 pt outside the side it exits through.
        let sideGaps = [paddedTarget.minX - arrow.tip.x, arrow.tip.x - paddedTarget.maxX, paddedTarget.minY - arrow.tip.y, arrow.tip.y - paddedTarget.maxY]
        #expect(sideGaps.contains { abs($0 - 6) < 1e-6 }, "no side at exactly 6 pt for \(target)")

        // Tail on screen whenever the arrow's ray reaches the screen at all.
        let tailArea = display.visible.insetBy(dx: 1, dy: 1)
        if MarkLayout.rayInterval(through: tailArea, from: arrow.tip, along: arrow.direction) != nil {
            #expect(containsWithTolerance(tailArea, CGRect(origin: arrow.tail, size: .zero), tolerance: 1e-3), "tail off screen for \(target)")
        }

        let labelArea = display.visible.insetBy(dx: 8, dy: 8)
        if let labelRect = arrow.labelRect {
            #expect(containsWithTolerance(labelArea, labelRect), "label off screen for \(target)")
            #expect(!labelRect.intersects(paddedTarget), "label on target for \(target)")
        } else {
            // Must be because no direction allows a label.
            let anyDirectionAllows = MarkLayout.arrowDirections.contains { direction in
                let tip = MarkLayout.arrowTip(padded: paddedTarget, direction: direction)
                guard let tailRange = MarkLayout.rayInterval(through: tailArea, from: tip, along: direction) else { return false }
                let shaftLength = min(max(MarkLayout.arrowLength, tailRange.lowerBound), tailRange.upperBound)
                let tail = CGPoint(x: tip.x + direction.dx * shaftLength, y: tip.y + direction.dy * shaftLength)
                let labelRect = MarkLayout.arrowLabelRect(tail: tail, direction: direction, labelSize: labelSize)
                return labelArea.contains(labelRect) && !labelRect.intersects(paddedTarget)
            }
            if anyDirectionAllows { labelAllowedButMissing += 1 }
        }
    }
    #expect(labelAllowedButMissing == 0)
    #expect(minimumGap >= 6 - 1e-6)
    print("arrow: min tip gap \(minimumGap) pt")
}

@Test func diagonalArrowGapIsSixNotFourPointTwo() {
    // The old rule put the tip 6 pt out along the diagonal: 6/√2 = 4.243 pt
    // from the side. Now the perpendicular gap is exactly 6.
    let paddedTarget = CGRect(x: 100, y: 100, width: 40, height: 40)
    let diagonal = CGVector(dx: -1 / sqrt(2.0), dy: -1 / sqrt(2.0))
    let tip = MarkLayout.arrowTip(padded: paddedTarget, direction: diagonal)
    #expect(abs((paddedTarget.minX - tip.x) - 6) < 1e-9)
    #expect(abs((paddedTarget.minY - tip.y) - 6) < 1e-9)
    let oldTipGap = 6 / sqrt(2.0)
    #expect(abs(oldTipGap - 4.243) < 0.001)
}

// MARK: - Ring properties

@Test func ringPropertiesHoldOnTenThousandRandomTargets() {
    var generator = SeededGenerator(state: 0x5EED_0001)
    var minimumClearanceByKind: [MarkShapeKind: CGFloat] = [:]
    var countByKind: [MarkShapeKind: Int] = [:]
    for caseIndex in 0..<10_000 {
        let display = testDisplays[caseIndex % testDisplays.count]
        let target = randomTarget(on: display, using: &generator)
        let allowedRect = display.bounds.insetBy(dx: 3, dy: 3)
        let paddedTarget = MarkLayout.padded(target)
        for shape in [MarkLayout.ring(target: target, display: display.bounds), MarkLayout.box(target: target, display: display.bounds)] {
            countByKind[shape.kind, default: 0] += 1
            #expect(containsWithTolerance(allowedRect, shape.rect), "shape off display for \(target): \(shape)")
            if allowedRect.contains(paddedTarget) {
                for corner in corners(of: target) {
                    let clearance = shape.clearance(of: corner)
                    minimumClearanceByKind[shape.kind] = min(minimumClearanceByKind[shape.kind] ?? .greatestFiniteMagnitude, clearance)
                    #expect(clearance >= 1.5 - 1e-6, "corner clearance \(clearance) for \(target): \(shape)")
                }
            } else {
                let drawable = target.intersection(allowedRect)
                if allowedRect.contains(target.center) {
                    #expect(shape.contains(target.center), "edge shape misses centre for \(target): \(shape)")
                }
                if !drawable.isNull, drawable.width > 1, drawable.height > 1 {
                    #expect(coveredFraction(of: drawable, by: shape) >= 0.8, "edge shape covers < 80% for \(target): \(shape)")
                }
            }
        }
    }
    print("ring: min corner clearance by kind \(minimumClearanceByKind), counts \(countByKind)")
}

@Test func pillVectorsKeepClearance() {
    let display = CGRect(x: 0, y: 0, width: 3440, height: 1440)
    for size in [CGSize(width: 120, height: 20), CGSize(width: 320, height: 26), CGSize(width: 400, height: 50)] {
        let target = CGRect(origin: CGPoint(x: 1000, y: 600), size: size)
        let shape = MarkLayout.ring(target: target, display: display)
        #expect(shape.kind == .pill)
        for corner in corners(of: target) {
            #expect(shape.clearance(of: corner) >= 1.5, "\(size): \(shape.clearance(of: corner))")
        }
    }
}

@Test func ringKindsFollowTheRules() {
    let display = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    #expect(MarkLayout.ring(target: CGRect(x: 500, y: 500, width: 24, height: 24), display: display).kind == .ellipse)
    #expect(MarkLayout.ring(target: CGRect(x: 500, y: 500, width: 200, height: 24), display: display).kind == .pill)
    #expect(MarkLayout.ring(target: CGRect(x: 100, y: 100, width: 900, height: 600), display: display).kind == .roundedBox)
    // Top-left corner icon: the ellipse would leave the display.
    let cornerShape = MarkLayout.ring(target: CGRect(x: 0, y: 0, width: 30, height: 30), display: display)
    #expect(cornerShape.kind != .ellipse)
    #expect(display.insetBy(dx: 3, dy: 3).contains(cornerShape.rect))
}

// MARK: - LabelPlacer

@Test func labelPlacerTakesFirstCleanAnchorInOrder() {
    let visible = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    let size = CGSize(width: 80, height: 30)
    let anchorRect = CGRect(x: 800, y: 500, width: 300, height: 40)
    #expect(LabelPlacer.place(size: size, around: anchorRect, visible: visible, obstacles: []).anchor == .belowLeft)
    // Block below-left → below-right.
    let belowLeft = LabelPlacer.rect(for: .belowLeft, size: size, around: anchorRect)
    #expect(LabelPlacer.place(size: size, around: anchorRect, visible: visible, obstacles: [belowLeft]).anchor == .belowRight)
    // Near the bottom edge, below doesn't fit → above-left.
    let bottomAnchor = CGRect(x: 800, y: 1030, width: 100, height: 40)
    #expect(LabelPlacer.place(size: size, around: bottomAnchor, visible: visible, obstacles: []).anchor == .aboveLeft)
}

@Test func labelPlacerFallsBackToLeastOverlapInside() {
    let visible = CGRect(x: 0, y: 0, width: 400, height: 300)
    let size = CGSize(width: 120, height: 30)
    let anchorRect = CGRect(x: 0, y: 0, width: 400, height: 300)
    let placement = LabelPlacer.place(size: size, around: anchorRect, visible: visible, obstacles: [anchorRect.insetBy(dx: 50, dy: 50)])
    #expect(!placement.isClean)
    #expect(visible.insetBy(dx: 8, dy: 8).contains(placement.rect))
}

@Test func labelSizeIsCeiledWithPadding() {
    let size = LabelPlacer.size(for: "Build settings")
    #expect(size.width == size.width.rounded(.up))
    #expect(size.height >= 15 + 12)
    #expect(LabelPlacer.size(for: String(repeating: "wide words ", count: 40)).width <= 260 + 16)
}

// MARK: - CompanionLanding

@Test func companionLandsBottomRightOfPaddedTarget() {
    let visible = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    let target = CGRect(x: 500, y: 400, width: 60, height: 24)
    let landing = CompanionLanding.landing(target: target, visible: visible)
    let paddedTarget = MarkLayout.padded(target)
    #expect(landing.minX == paddedTarget.maxX + 6)
    #expect(landing.minY == paddedTarget.maxY + 6)
}

@Test func companionNeverLeavesVisibleOrSitsOnTarget() {
    var generator = SeededGenerator(state: 42)
    for caseIndex in 0..<2000 {
        let display = testDisplays[caseIndex % testDisplays.count]
        var target = randomTarget(on: display, using: &generator)
        target.size = CGSize(width: min(target.width, 400), height: min(target.height, 300))
        let landing = CompanionLanding.landing(target: target, visible: display.visible)
        #expect(display.visible.insetBy(dx: 2, dy: 2).insetBy(dx: -1e-6, dy: -1e-6).contains(landing))
        #expect(!landing.intersects(MarkLayout.padded(target)), "companion on target \(target) → \(landing)")
    }
    // Bottom-right corner target: lands elsewhere, still inside.
    let visible = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    let cornerLanding = CompanionLanding.landing(target: CGRect(x: 1880, y: 1050, width: 40, height: 30), visible: visible)
    #expect(visible.contains(cornerLanding))
}

// MARK: - TrackerLogic

@Test func trackerHidesBelowHalfVisibleAndReshows() {
    let rect = CGRect(x: 0, y: 0, width: 100, height: 20)
    let clip = CGRect(x: 0, y: 12, width: 500, height: 500)
    #expect(TrackerLogic.visibleFraction(rect, clip: clip, window: nil) == 0.4)
    #expect(!TrackerLogic.isShown(visibleFraction: 0.4))
    #expect(TrackerLogic.isShown(visibleFraction: 0.5))
    #expect(TrackerLogic.visibleFraction(rect, clip: CGRect(x: 0, y: 0, width: 50, height: 500), window: CGRect(x: 0, y: 0, width: 25, height: 500)) == 0.25)
}

@Test func trackerDetectsReusedRows() {
    #expect(!TrackerLogic.labelDrifted(original: "Row 12", current: "Row 12"))
    #expect(TrackerLogic.labelDrifted(original: "Row 12", current: "Row 31"))
    #expect(TrackerLogic.labelDrifted(original: "Deploy failed", current: nil))
    #expect(!TrackerLogic.labelDrifted(original: nil, current: "Anything"))
}

@Test func trackerCadenceIsFastForOneSecondAfterActivity() {
    var cadence = TrackerLogic.Cadence()
    let start = Date(timeIntervalSince1970: 1000)
    #expect(cadence.interval(at: start) == 1.0)
    cadence.noteActivity(at: start)
    #expect(cadence.interval(at: start.addingTimeInterval(0.5)) == 0.1)
    #expect(cadence.interval(at: start.addingTimeInterval(1.01)) == 1.0)
}

@Test func untrackedMarksClearOnlyForTheirOwnWindowsEvents() {
    let markWindowFrame = CGRect(x: 0, y: 0, width: 800, height: 600)
    let ownPid: pid_t = 77
    // Scroll on another display (outside the window) keeps it.
    #expect(!TrackerLogic.clearsUntrackedMark(.scrollWheel(locationCG: CGPoint(x: 3600, y: 400)), markWindowID: 9, markWindowFrame: markWindowFrame, ownProcessIdentifier: ownPid))
    #expect(TrackerLogic.clearsUntrackedMark(.scrollWheel(locationCG: CGPoint(x: 100, y: 100)), markWindowID: 9, markWindowFrame: markWindowFrame, ownProcessIdentifier: ownPid))
    #expect(!TrackerLogic.clearsUntrackedMark(.applicationActivated(processIdentifier: ownPid), markWindowID: 9, markWindowFrame: markWindowFrame, ownProcessIdentifier: ownPid))
    #expect(TrackerLogic.clearsUntrackedMark(.applicationActivated(processIdentifier: 12), markWindowID: 9, markWindowFrame: markWindowFrame, ownProcessIdentifier: ownPid))
    #expect(TrackerLogic.clearsUntrackedMark(.windowChanged(windowID: 9, newFrame: markWindowFrame.offsetBy(dx: 40, dy: 0)), markWindowID: 9, markWindowFrame: markWindowFrame, ownProcessIdentifier: ownPid))
    #expect(!TrackerLogic.clearsUntrackedMark(.windowChanged(windowID: 9, newFrame: markWindowFrame), markWindowID: 9, markWindowFrame: markWindowFrame, ownProcessIdentifier: ownPid))
    #expect(TrackerLogic.clearsUntrackedMark(.windowChanged(windowID: 9, newFrame: nil), markWindowID: 9, markWindowFrame: markWindowFrame, ownProcessIdentifier: ownPid))
    #expect(!TrackerLogic.clearsUntrackedMark(.windowChanged(windowID: 10, newFrame: nil), markWindowID: 9, markWindowFrame: markWindowFrame, ownProcessIdentifier: ownPid))
}

// MARK: - Scene

@Test func sceneStepsConnectAndLabelsAvoidEachOther() {
    let display = MarkSceneDisplay(displayID: 1, bounds: CGRect(x: 0, y: 0, width: 1920, height: 1080), visible: CGRect(x: 0, y: 25, width: 1920, height: 985))
    let inputs = (1...3).map { stepNumber in
        MarkSceneInput(id: UUID(), style: .step(stepNumber), rectCG: CGRect(x: 300 + CGFloat(stepNumber) * 200, y: 400, width: 80, height: 24),
                       displayText: "Step \(stepNumber)", isTentative: false, order: stepNumber)
    }
    let drawings = MarkSceneBuilder.build(inputs: inputs, displays: [display])
    #expect(drawings.count == 3)
    #expect(drawings[0].connectorFrom == nil)
    #expect(drawings[1].connectorFrom == drawings[0].stepDiscCenter)
    #expect(drawings[2].connectorFrom == drawings[1].stepDiscCenter)
    let labelRects = drawings.compactMap(\.labelRect)
    for (firstIndex, first) in labelRects.enumerated() {
        for second in labelRects[(firstIndex + 1)...] { #expect(!first.intersects(second)) }
        for drawing in drawings { #expect(!first.intersects(MarkLayout.padded(drawing.targetCG))) }
    }
}

// MARK: - Re-check maths

@Test func recheckCropSourceRectAndSize() {
    let display = CGRect(x: 3440, y: 198, width: 1920, height: 1080)
    let target = CGRect(x: 3450, y: 210, width: 60, height: 20)
    let crop = RecheckMath.cropRect(target: target, displayBounds: display)
    // Grown by 24, clipped at the display's top-left.
    #expect(crop == CGRect(x: 3440, y: 198, width: 60 + 24 + 10, height: 20 + 24 + 12))
    #expect(RecheckMath.sourceRect(region: crop, displayBounds: display) == CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
    #expect(RecheckMath.pixelSize(region: crop, pointPixelScale: 2) == PixelSize(width: 188, height: 112))
    let leftDisplay = CGRect(x: -1920, y: 155, width: 1920, height: 1080)
    let leftCrop = RecheckMath.cropRect(target: CGRect(x: -1000, y: 500, width: 40, height: 40), displayBounds: leftDisplay)
    #expect(RecheckMath.sourceRect(region: leftCrop, displayBounds: leftDisplay).origin == CGPoint(x: 896, y: 321))
}

@Test func recheckOnAOneXDisplayMapsThroughThePreUpscaleGrid() {
    // A 1x crop (< 1.5 px/pt) is upscaled 2x for Vision, but its CaptureFrame
    // is the native crop: normalised boxes map back the same either way.
    let displayInfo = DisplayInfo(displayID: 1, localizedName: "DELL", boundsCG: CGRect(x: 0, y: 0, width: 3440, height: 1440),
                                  visibleCG: CGRect(x: 0, y: 0, width: 3440, height: 1440), frameAppKit: CGRect(x: 0, y: 0, width: 3440, height: 1440), isMain: true)
    let crop = CGRect(x: 1000, y: 500, width: 100, height: 50)
    let frame = CaptureFrame(display: displayInfo, screenNumber: 0, regionCG: crop, native: PixelSize(width: 100, height: 50), model: nil)
    #expect(OCRBandPlanner.upscaleFactor(pixelsPerPoint: frame.nativePixelsPerPoint) == 2)
    let fullCropPx = CGRect(x: 0, y: 0, width: 100, height: 50)
    // Vision box: lower-left origin, normalised. Text at x 20–60, y 10–30 (top-left, px).
    let visionBox = CGRect(x: 0.2, y: 1 - 30.0 / 50, width: 0.4, height: 20.0 / 50)
    let mapped = frame.cgRect(visionBox: visionBox, cropPx: fullCropPx)
    #expect(abs(mapped.minX - 1020) < 1e-9 && abs(mapped.minY - 510) < 1e-9 && abs(mapped.width - 40) < 1e-9 && abs(mapped.height - 20) < 1e-9)
}

@Test func recheckMatchesNameNearTheTargetOnly() {
    let target = CGRect(x: 100, y: 100, width: 120, height: 20)
    let nearLine = OCRLine(text: "Deploy faled", frameCG: CGRect(x: 100, y: 100, width: 120, height: 20), displayID: 1, confidence: 0.9)
    let farLine = OCRLine(text: "Deploy failed", frameCG: CGRect(x: 600, y: 600, width: 120, height: 20), displayID: 1, confidence: 0.9)
    #expect(RecheckMath.matchingFrame(name: "Deploy failed", lines: [nearLine], target: target) != nil)
    #expect(RecheckMath.matchingFrame(name: "Deploy failed", lines: [farLine], target: target) == nil)
    #expect(RecheckMath.matchingFrame(name: "Zebra 4821", lines: [nearLine], target: target) == nil)
}
