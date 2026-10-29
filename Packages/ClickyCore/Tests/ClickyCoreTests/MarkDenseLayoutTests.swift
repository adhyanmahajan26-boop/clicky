import AppKit
import CoreGraphics
import Foundation
import SwiftUI
import Testing
@testable import ClickyCore

// Density-aware marks (v2): Addy's Notion table, where fat rboxes covered the
// rows above and below and labels sat on neighbouring rows.

private func segmentsCross(_ first: (CGPoint, CGPoint), _ second: (CGPoint, CGPoint)) -> Bool {
    func orientation(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint) -> CGFloat { (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x) }
    let d1 = orientation(second.0, second.1, first.0)
    let d2 = orientation(second.0, second.1, first.1)
    let d3 = orientation(first.0, first.1, second.0)
    let d4 = orientation(first.0, first.1, second.1)
    return ((d1 > 0 && d2 < 0) || (d1 < 0 && d2 > 0)) && ((d3 > 0 && d4 < 0) || (d3 < 0 && d4 > 0))
}

private func distance(from point: CGPoint, toSegment segment: (CGPoint, CGPoint)) -> CGFloat {
    let (a, b) = segment
    let lengthSquared = (b.x - a.x) * (b.x - a.x) + (b.y - a.y) * (b.y - a.y)
    guard lengthSquared > 0 else { return hypot(point.x - a.x, point.y - a.y) }
    let t = max(0, min(1, ((point.x - a.x) * (b.x - a.x) + (point.y - a.y) * (b.y - a.y)) / lengthSquared))
    return hypot(point.x - (a.x + t * (b.x - a.x)), point.y - (a.y + t * (b.y - a.y)))
}

/// Fraction of `textRect` (0.5 pt grid) under anything a drawing paints:
/// labels, outline bands, underline bands, leader and arrow strokes.
private func occludedFraction(of textRect: CGRect, by drawings: [MarkDrawing]) -> Double {
    var paintedRects: [CGRect] = []
    var strokes: [((CGPoint, CGPoint), CGFloat)] = []
    for drawing in drawings {
        if let labelRect = drawing.labelRect { paintedRects.append(labelRect) }
        if let underline = drawing.underline { strokes.append(((underline.start, underline.end), MarkPalette.fineHaloWidth / 2)) }
        if let leader = drawing.leader {
            strokes.append(((leader.start, leader.tip), MarkPalette.leaderHaloWidth / 2))
            strokes.append(((leader.headLeft, leader.tip), MarkPalette.leaderHaloWidth / 2))
            strokes.append(((leader.headRight, leader.tip), MarkPalette.leaderHaloWidth / 2))
        }
        if let outline = drawing.outline {
            // The band between the outline inset and outset by half the halo.
            let outer = outline.rect.insetBy(dx: -MarkPalette.fineHaloWidth / 2, dy: -MarkPalette.fineHaloWidth / 2)
            let inner = outline.rect.insetBy(dx: MarkPalette.fineHaloWidth / 2, dy: MarkPalette.fineHaloWidth / 2)
            for edge in [CGRect(x: outer.minX, y: outer.minY, width: outer.width, height: inner.minY - outer.minY),
                         CGRect(x: outer.minX, y: inner.maxY, width: outer.width, height: outer.maxY - inner.maxY),
                         CGRect(x: outer.minX, y: outer.minY, width: inner.minX - outer.minX, height: outer.height),
                         CGRect(x: inner.maxX, y: outer.minY, width: outer.maxX - inner.maxX, height: outer.height)] {
                paintedRects.append(edge)
            }
        }
    }
    var coveredCount = 0
    var sampleCount = 0
    var sampleY = textRect.minY + 0.25
    while sampleY < textRect.maxY {
        var sampleX = textRect.minX + 0.25
        while sampleX < textRect.maxX {
            let point = CGPoint(x: sampleX, y: sampleY)
            sampleCount += 1
            if paintedRects.contains(where: { $0.contains(point) }) || strokes.contains(where: { distance(from: point, toSegment: $0.0) <= $0.1 }) {
                coveredCount += 1
            }
            sampleX += 0.5
        }
        sampleY += 0.5
    }
    return sampleCount == 0 ? 0 : Double(coveredCount) / Double(sampleCount)
}

private func buildDenseTable() -> [MarkDrawing] {
    MarkSceneBuilder.build(inputs: DenseTableFixture.inputs(), displays: [DenseTableFixture.display],
                           textObstacles: DenseTableFixture.textObstacles)
}

@Test func denseTableMarksAreUnderlinesUnderTheText() {
    let drawings = buildDenseTable()
    #expect(drawings.count == 5)
    for (index, drawing) in drawings.enumerated() {
        let row = DenseTableFixture.markedRows[index]
        #expect(drawing.outline == nil, "row \(row) still has an outline")
        #expect(drawing.isDense)
        let underline = try! #require(drawing.underline, "row \(row) has no underline")
        let texts = DenseTableFixture.textBounds(row: row)
        let textSpan = texts.dropFirst().reduce(texts[0]) { $0.union($1) }
        // Spans the text, not the 820 pt row.
        #expect(abs(underline.start.x - textSpan.minX) < 0.01 && abs(underline.end.x - textSpan.maxX) < 0.01)
        // Stroke top edge 2 pt below the text.
        #expect(abs((underline.start.y - MarkDensity.underlineStrokeWidth / 2) - (textSpan.maxY + 2)) < 0.01)
        // Step number inside the label, no gutter disc.
        #expect(drawing.stepDiscCenter == nil && drawing.connectorFrom == nil)
        #expect(drawing.labelStepNumber == index + 1)
    }
}

@Test func denseTableLabelsSitInClearSpaceWithUncrossedLeaders() throws {
    let drawings = buildDenseTable()
    let allText = MarkDensity.leafTextBounds(DenseTableFixture.textObstacles)
    let labelRects = drawings.compactMap(\.labelRect)
    #expect(labelRects.count == 5)
    for labelRect in labelRects {
        #expect(!allText.contains { $0.intersects(labelRect) }, "label \(labelRect) on text")
        #expect(DenseTableFixture.display.visible.insetBy(dx: 8, dy: 8).contains(labelRect))
    }
    for (firstIndex, first) in labelRects.enumerated() {
        for second in labelRects[(firstIndex + 1)...] { #expect(!first.intersects(second)) }
    }
    // One column, in target order.
    #expect(Set(labelRects.map(\.minX)).count == 1)
    #expect(labelRects == labelRects.sorted { $0.minY < $1.minY })

    let leaders = drawings.compactMap(\.leader)
    #expect(leaders.count == 5, "every label is away from its row, so each has a leader")
    for (firstIndex, first) in leaders.enumerated() {
        for second in leaders[(firstIndex + 1)...] {
            #expect(!segmentsCross((first.start, first.tip), (second.start, second.tip)), "leaders cross")
        }
    }
    // Every leader stops 6 pt off its target's text / underline.
    for drawing in drawings {
        let leader = try #require(drawing.leader)
        let underline = try #require(drawing.underline)
        let attach = DenseTableFixture.textBounds(row: DenseTableFixture.markedRows[drawings.firstIndex(of: drawing)!])
            .reduce(MarkSceneBuilder.underlineRect(underline)) { $0.union($1) }
        let gap = hypot(max(attach.minX - leader.tip.x, 0, leader.tip.x - attach.maxX), max(attach.minY - leader.tip.y, 0, leader.tip.y - attach.maxY))
        #expect(abs(gap - 6) < 0.01, "leader gap \(gap)")
    }
}

@Test func denseTableBarelyTouchesOtherRowsText() {
    let drawings = buildDenseTable()
    var worst = 0.0
    for row in 0..<DenseTableFixture.rowCount where !DenseTableFixture.markedRows.contains(row) {
        for textRect in DenseTableFixture.textBounds(row: row) {
            let fraction = occludedFraction(of: textRect, by: drawings)
            worst = max(worst, fraction)
            #expect(fraction < 0.05, "row \(row) text \(textRect) is \(Int(fraction * 100))% covered")
        }
    }
    print("dense table: worst non-target text occlusion \(worst)")
}

@Test func denseTableLabelsAvoidTheCompanionToo() {
    let firstDrawings = buildDenseTable()
    let firstLabel = firstDrawings[0].labelRect!
    let companion = CGRect(x: firstLabel.minX + 10, y: firstLabel.minY, width: 28, height: 28)
    let drawings = MarkSceneBuilder.build(inputs: DenseTableFixture.inputs(), displays: [DenseTableFixture.display],
                                          companionRect: companion, textObstacles: DenseTableFixture.textObstacles)
    for labelRect in drawings.compactMap(\.labelRect) { #expect(!labelRect.intersects(companion)) }
}

// MARK: - Isolated controls

enum IsolatedButtonFixture {
    static let display = MarkSceneDisplay(displayID: 1, bounds: CGRect(x: 0, y: 0, width: 800, height: 500),
                                          visible: CGRect(x: 0, y: 25, width: 800, height: 405))
    static let button = CGRect(x: 360, y: 230, width: 70, height: 26)
    static let buttonText = CGRect(x: 375, y: 236, width: 40, height: 14)
    /// A heading far above and a paragraph far below: not neighbours.
    static let otherTexts = [CGRect(x: 120, y: 80, width: 300, height: 20), CGRect(x: 120, y: 340, width: 500, height: 14)]
    static func input(role: MarkTargetRole, text: String? = "Save") -> MarkSceneInput {
        MarkSceneInput(id: UUID(), style: .circle, rectCG: button, displayText: text, isTentative: false, order: 0, targetRole: role)
    }
}

@Test func isolatedButtonKeepsATightRing() {
    for role in [MarkTargetRole.control, .unknown] {
        let drawings = MarkSceneBuilder.build(inputs: [IsolatedButtonFixture.input(role: role)], displays: [IsolatedButtonFixture.display],
                                              textObstacles: [IsolatedButtonFixture.buttonText] + IsolatedButtonFixture.otherTexts)
        let drawing = drawings[0]
        #expect(drawing.underline == nil, "\(role): became an underline")
        let outline = try! #require(drawing.outline)
        #expect(outline.rect == IsolatedButtonFixture.button.insetBy(dx: -3, dy: -3), "\(role): pad isn't 3 pt")
        #expect(outline.cornerRadius <= 8)
        // Its label sits right next to it (clean anchor), so no leader.
        #expect(drawing.leader == nil)
        let labelRect = try! #require(drawing.labelRect)
        #expect(!labelRect.intersects(IsolatedButtonFixture.button))
    }
}

@Test func outlineNextToANeighbourShrinksItsPadInsteadOfBecomingAnUnderline() {
    // A control right under a line of text: the outline stays, its pad shrinks.
    let display = IsolatedButtonFixture.display
    let target = CGRect(x: 200, y: 200, width: 120, height: 40)
    let input = MarkSceneInput(id: UUID(), style: .box, rectCG: target, displayText: nil, isTentative: false, order: 0, targetRole: .control)
    let farNeighbour = CGRect(x: 200, y: 180, width: 120, height: 14)
    let roomy = MarkSceneBuilder.build(inputs: [input], displays: [display], textObstacles: [farNeighbour])[0]
    #expect(roomy.outline?.rect == target.insetBy(dx: -3, dy: -3), "nothing close: the full 3 pt pad")
    let closeNeighbour = CGRect(x: 200, y: 184, width: 120, height: 14)
    let tight = MarkSceneBuilder.build(inputs: [input], displays: [display], textObstacles: [closeNeighbour])[0]
    let outline = try! #require(tight.outline, "an explicit box never becomes an underline")
    #expect(tight.underline == nil)
    let pad = target.minY - outline.rect.minY
    #expect(pad >= 0 && pad < 3, "pad \(pad) didn't shrink")
    #expect(!outline.rect.insetBy(dx: -MarkPalette.fineLineWidth / 2, dy: -MarkPalette.fineLineWidth / 2).intersects(closeNeighbour))
}

@Test func labellessIsolatedStepKeepsItsDisc() {
    let input = MarkSceneInput(id: UUID(), style: .step(2), rectCG: IsolatedButtonFixture.button, displayText: nil, isTentative: false, order: 0,
                               targetRole: .control)
    let drawing = MarkSceneBuilder.build(inputs: [input], displays: [IsolatedButtonFixture.display])[0]
    #expect(drawing.stepDiscCenter != nil && drawing.labelRect == nil && drawing.labelStepNumber == nil)
    // A dense step with no words gets a number-only pill instead.
    let denseInput = MarkSceneInput(id: UUID(), style: .step(3), rectCG: DenseTableFixture.rowFrame(2), displayText: nil, isTentative: false,
                                    order: 0, targetRole: .text)
    let denseDrawing = MarkSceneBuilder.build(inputs: [denseInput], displays: [DenseTableFixture.display],
                                              textObstacles: DenseTableFixture.textObstacles)[0]
    #expect(denseDrawing.stepDiscCenter == nil && denseDrawing.labelStepNumber == 3 && denseDrawing.labelRect != nil)
}

@Test func containersAreSeenThrough() {
    let row = CGRect(x: 0, y: 0, width: 400, height: 22)
    let cell = CGRect(x: 10, y: 4, width: 100, height: 14)
    #expect(MarkDensity.leafTextBounds([row, cell]) == [cell])
    #expect(MarkDensity.leafTextBounds([row]) == [row])
}

@Test func textObstaclesComeFromTextRolesAndOCR() {
    let text = GroundingElement(role: .text, label: "Hi", frameCG: CGRect(x: 0, y: 0, width: 50, height: 14), processIdentifier: 1, displayID: 1,
                                isInteractive: false, source: .accessibility)
    let button = GroundingElement(role: .button, label: "OK", frameCG: CGRect(x: 0, y: 40, width: 50, height: 24), processIdentifier: 1, displayID: 1,
                                  isInteractive: true, source: .accessibility)
    let behind = GroundingElement(role: .cell, label: "x", frameCG: CGRect(x: 0, y: 80, width: 50, height: 14), processIdentifier: 1, displayID: 1,
                                  isInteractive: false, isBehind: true, source: .accessibility)
    let line = OCRLine(text: "Line", frameCG: CGRect(x: 0, y: 120, width: 80, height: 13), displayID: 1)
    let bounds = MarkTextObstacles.collect(elements: [text, button, behind], ocrLines: [line])
    #expect(bounds == [text.frameCG, line.frameCG])
    #expect(MarkTextObstacles.targetRole(for: button, isTextMatch: false) == .control)
    #expect(MarkTextObstacles.targetRole(for: text, isTextMatch: false) == .text)
    #expect(MarkTextObstacles.targetRole(for: nil, isTextMatch: true) == .text)
}

// MARK: - Renders

/// Offscreen renders (nothing on screen) into
/// ~/Library/Logs/Clicky/renders/marks-dense/. before.png was rendered once
/// from the v1 builder at the start of this change, over the same backdrop.
@MainActor
@Test func rendersDenseTableAndIsolatedButton() throws {
    let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Clicky/renders/marks-dense", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

    func write<Content: View>(_ content: Content, _ name: String) throws {
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        let image = try #require(renderer.cgImage, "no image for \(name)")
        try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent(name))
    }

    let tableDrawings = buildDenseTable()
    try write(ZStack(alignment: .topLeading) {
        DenseTableFixture.Backdrop()
        MarkSceneView(drawings: tableDrawings, displayBoundsCG: DenseTableFixture.display.bounds, drawsImmediately: true)
    }, "after.png")

    let buttonDisplay = IsolatedButtonFixture.display
    let buttonDrawings = MarkSceneBuilder.build(inputs: [IsolatedButtonFixture.input(role: .control)], displays: [buttonDisplay],
                                                textObstacles: [IsolatedButtonFixture.buttonText] + IsolatedButtonFixture.otherTexts)
    try write(ZStack(alignment: .topLeading) {
        Color(white: 0.93)
        ForEach(Array(IsolatedButtonFixture.otherTexts.enumerated()), id: \.offset) { _, textRect in
            RoundedRectangle(cornerRadius: 2).fill(Color(white: 0.55)).frame(width: textRect.width, height: textRect.height)
                .offset(x: textRect.minX, y: textRect.minY)
        }
        RoundedRectangle(cornerRadius: 6).fill(Color.white).frame(width: IsolatedButtonFixture.button.width, height: IsolatedButtonFixture.button.height)
            .offset(x: IsolatedButtonFixture.button.minX, y: IsolatedButtonFixture.button.minY)
        RoundedRectangle(cornerRadius: 2).fill(Color(white: 0.4))
            .frame(width: IsolatedButtonFixture.buttonText.width, height: IsolatedButtonFixture.buttonText.height)
            .offset(x: IsolatedButtonFixture.buttonText.minX, y: IsolatedButtonFixture.buttonText.minY)
        MarkSceneView(drawings: buttonDrawings, displayBoundsCG: buttonDisplay.bounds, drawsImmediately: true)
    }.frame(width: buttonDisplay.bounds.width, height: buttonDisplay.bounds.height, alignment: .topLeading), "isolated-button.png")
}
