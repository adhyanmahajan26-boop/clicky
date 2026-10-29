import AppKit
import CoreGraphics
import Foundation
import SwiftUI
import Testing
@testable import ClickyCore

// The nearCursor label style (v2.marks.labelStyle default): Addy preferred
// the explanation next to the cursor over the label column with leader
// arrows. Marks keep their underlines / tight rings and get only a numbered
// chip; the words go to the caption bubble's legend.

private func buildNearCursorTable(companionRect: CGRect? = nil) -> [MarkDrawing] {
    MarkSceneBuilder.build(inputs: DenseTableFixture.inputs(), displays: [DenseTableFixture.display], companionRect: companionRect,
                           textObstacles: DenseTableFixture.textObstacles, labelStyle: .nearCursor)
}

/// Every text bar of the fixture (the leaves: OCR lines).
private var allFixtureText: [CGRect] { (0..<DenseTableFixture.rowCount).flatMap(DenseTableFixture.textBounds(row:)) }

@Test func nearCursorDenseTableHasFiveChipsAndNoLabels() throws {
    let drawings = buildNearCursorTable()
    #expect(drawings.count == 5)
    let chipRects = drawings.compactMap { $0.chipCenter.map(MarkChips.rect(center:)) }
    #expect(chipRects.count == 5)
    #expect(drawings.map(\.chipNumber) == [1, 2, 3, 4, 5])
    for (index, drawing) in drawings.enumerated() {
        let row = DenseTableFixture.markedRows[index]
        // The thin underline stays; no pill, no leader, no gutter disc.
        let underline = try #require(drawing.underline, "row \(row) lost its underline")
        #expect(drawing.outline == nil)
        #expect(drawing.labelRect == nil && drawing.labelStepNumber == nil, "row \(row) has a label pill")
        #expect(drawing.leader == nil, "row \(row) has a leader arrow")
        #expect(drawing.stepDiscCenter == nil && drawing.connectorFrom == nil)
        // The chip sits just left of the underline's start, centred on the text line.
        let chip = try #require(drawing.chipCenter)
        let textLine = DenseTableFixture.textBounds(row: row)[0]
        #expect(chip.x < underline.start.x && underline.start.x - chip.x <= MarkChips.gap + MarkChips.diameter / 2 + MarkChips.maximumNudge)
        #expect(abs(chip.y - textLine.midY) < 0.01, "row \(row): chip not on the text line")
        #expect(DenseTableFixture.display.visible.contains(MarkChips.rect(center: chip)))
    }
    for chipRect in chipRects {
        #expect(!allFixtureText.contains { $0.intersects(chipRect) }, "chip \(chipRect) on text")
    }
    for (firstIndex, first) in chipRects.enumerated() {
        for second in chipRects[(firstIndex + 1)...] { #expect(!first.intersects(second)) }
    }
}

@Test func nearCursorLegendListsEveryMarkInOrder() {
    let legend = MarkChips.legend(for: DenseTableFixture.inputs(), labelStyle: .nearCursor)
    #expect(legend.count == 5)
    #expect(legend.map(\.number) == [1, 2, 3, 4, 5])
    #expect(legend.map(\.text) == DenseTableFixture.labels)
    // Out-of-order inputs still come out in answer order.
    #expect(MarkChips.legend(for: DenseTableFixture.inputs().reversed(), labelStyle: .nearCursor) == legend)
    // The column style keeps its words on screen: no legend.
    #expect(MarkChips.legend(for: DenseTableFixture.inputs(), labelStyle: .column).isEmpty)
}

@Test func nearCursorChipsDodgeTextBesideTheUnderline() throws {
    // A cell right where the chip would go: it moves left (or up), off the text.
    let row = DenseTableFixture.markedRows[0]
    let line = DenseTableFixture.textBounds(row: row)[0]
    let blocker = CGRect(x: line.minX - 16, y: line.minY, width: 12, height: line.height)
    let drawings = MarkSceneBuilder.build(inputs: DenseTableFixture.inputs(), displays: [DenseTableFixture.display],
                                          textObstacles: DenseTableFixture.textObstacles + [blocker], labelStyle: .nearCursor)
    let chip = MarkChips.rect(center: try #require(drawings[0].chipCenter))
    #expect(!chip.intersects(blocker))
    #expect(!allFixtureText.contains { $0.intersects(chip) })
}

@Test func nearCursorSingleTargetHasNoChipAndNoLegend() throws {
    let input = DenseTableFixture.inputs()[2]
    let drawing = MarkSceneBuilder.build(inputs: [input], displays: [DenseTableFixture.display],
                                         textObstacles: DenseTableFixture.textObstacles, labelStyle: .nearCursor)[0]
    #expect(drawing.underline != nil)
    #expect(drawing.chipCenter == nil && drawing.chipNumber == nil)
    #expect(drawing.labelRect == nil && drawing.leader == nil && drawing.stepDiscCenter == nil)
    #expect(MarkChips.legend(for: [input], labelStyle: .nearCursor).isEmpty)

    // An isolated button keeps its tight ring, and nothing else.
    let button = MarkSceneBuilder.build(inputs: [IsolatedButtonFixture.input(role: .control)], displays: [IsolatedButtonFixture.display],
                                        textObstacles: [IsolatedButtonFixture.buttonText] + IsolatedButtonFixture.otherTexts,
                                        labelStyle: .nearCursor)[0]
    let outline = try #require(button.outline)
    #expect(outline.rect == IsolatedButtonFixture.button.insetBy(dx: -3, dy: -3))
    #expect(button.labelRect == nil && button.chipCenter == nil && button.leader == nil)
}

@Test func nearCursorFirstMarkGetsItsChipWhenMoreAreComing() {
    // Only one mark fired yet, but the answer has three: chip 1 shows now.
    let input = DenseTableFixture.inputs()[0]
    let drawing = MarkSceneBuilder.build(inputs: [input], displays: [DenseTableFixture.display], textObstacles: DenseTableFixture.textObstacles,
                                         labelStyle: .nearCursor, expectedMarkCount: 3)[0]
    #expect(drawing.chipNumber == 1 && drawing.chipCenter != nil)
    #expect(MarkChips.legend(for: [input], labelStyle: .nearCursor, expectedMarkCount: 3).map(\.number) == [1])
}

@Test func nearCursorRingChipSitsOnTheTopLeftCorner() throws {
    let display = IsolatedButtonFixture.display
    let inputs = [
        MarkSceneInput(id: UUID(), style: .circle, rectCG: IsolatedButtonFixture.button, displayText: "Save", isTentative: false, order: 0,
                       targetRole: .control),
        MarkSceneInput(id: UUID(), style: .circle, rectCG: CGRect(x: 560, y: 230, width: 70, height: 26), displayText: "Cancel",
                       isTentative: false, order: 1, targetRole: .control)
    ]
    let drawings = MarkSceneBuilder.build(inputs: inputs, displays: [display],
                                          textObstacles: [IsolatedButtonFixture.buttonText] + IsolatedButtonFixture.otherTexts, labelStyle: .nearCursor)
    for drawing in drawings {
        let outline = try #require(drawing.outline)
        let chip = try #require(drawing.chipCenter)
        #expect(chip.x <= outline.rect.minX && chip.y <= outline.rect.minY)
        #expect(hypot(chip.x - outline.rect.minX, chip.y - outline.rect.minY) < MarkChips.diameter)
        #expect(!MarkChips.rect(center: chip).intersects(IsolatedButtonFixture.buttonText))
        #expect(drawing.labelRect == nil)
    }
    #expect(drawings.map(\.chipNumber) == [1, 2])
}

@Test func nearCursorArrowsKeepNoPillAndTheirWordsGoToTheLegend() throws {
    let display = MarkSceneDisplay(displayID: 1, bounds: CGRect(x: 0, y: 0, width: 1440, height: 900), visible: CGRect(x: 0, y: 25, width: 1440, height: 800))
    let inputs = [
        MarkSceneInput(id: UUID(), style: .arrow, rectCG: CGRect(x: 400, y: 400, width: 60, height: 24), displayText: "Share", isTentative: false, order: 0),
        MarkSceneInput(id: UUID(), style: .arrow, rectCG: CGRect(x: 900, y: 500, width: 60, height: 24), displayText: "Export", isTentative: false, order: 1)
    ]
    let drawings = MarkSceneBuilder.build(inputs: inputs, displays: [display], labelStyle: .nearCursor)
    for drawing in drawings {
        let arrow = try #require(drawing.arrow)
        #expect(arrow.labelRect == nil && drawing.labelRect == nil)
        let chip = try #require(drawing.chipCenter)
        #expect(hypot(chip.x - arrow.tail.x, chip.y - arrow.tail.y) <= MarkChips.gap + MarkChips.diameter / 2 + 0.01)
    }
    #expect(MarkChips.legend(for: inputs, labelStyle: .nearCursor).map(\.text) == ["Share", "Export"])
    // Arrows are otherwise unchanged: same tip as the column style.
    let columnDrawings = MarkSceneBuilder.build(inputs: inputs, displays: [display], labelStyle: .column)
    #expect(drawings.map { $0.arrow?.tip } == columnDrawings.map { $0.arrow?.tip })
}

@Test func columnStyleIsTheBuildersDefault() {
    let inputs = DenseTableFixture.inputs()
    let byDefault = MarkSceneBuilder.build(inputs: inputs, displays: [DenseTableFixture.display], textObstacles: DenseTableFixture.textObstacles)
    let column = MarkSceneBuilder.build(inputs: inputs, displays: [DenseTableFixture.display], textObstacles: DenseTableFixture.textObstacles,
                                        labelStyle: .column, expectedMarkCount: 5)
    #expect(byDefault == column)
    #expect(column.allSatisfy { $0.chipCenter == nil && $0.labelRect != nil })
}

// MARK: - The bubble with the legend

private let legendCompanion = CGRect(x: 746, y: 256, width: 28, height: 28)

private func legendCaption() -> CaptionState {
    var caption = CaptionState()
    caption.current = CaptionParser.parse("Here are the five rows to fix before you publish the template.", id: 1, firstTagIndex: 0)
    caption.revealedDisplayCharacters = caption.current!.display.count
    caption.isVisible = true
    caption.markLegend = MarkChips.legend(for: DenseTableFixture.inputs(), labelStyle: .nearCursor)
    return caption
}

private func legendBubblePlacement(_ caption: CaptionState, drawings: [MarkDrawing]) -> BubblePlacement {
    BubblePlacer.place(BubblePlacer.Input(
        companionRect: legendCompanion,
        bubbleSize: BubblePlacer.estimatedBubbleSize(for: caption, maxWidth: 360, maxLines: 4),
        visibleFrames: [DenseTableFixture.display.visible],
        mouseLocation: legendCompanion.center,
        obstacles: drawings.flatMap(\.paintedRects),
        textObstacles: DenseTableFixture.textObstacles
    ))
}

@Test func legendBubbleSitsNextToTheCompanionOffTheText() {
    let drawings = buildNearCursorTable(companionRect: legendCompanion)
    let placement = legendBubblePlacement(legendCaption(), drawings: drawings)
    #expect(placement.slot != .dockedTop)
    #expect(placement.leaderLine == nil)
    let gapX = max(placement.rect.minX - legendCompanion.maxX, legendCompanion.minX - placement.rect.maxX)
    let gapY = max(placement.rect.minY - legendCompanion.maxY, legendCompanion.minY - placement.rect.maxY)
    #expect(abs(gapX - BubblePlacer.gap) < 0.01 && abs(gapY - BubblePlacer.gap) < 0.01, "bubble not beside the companion")
    #expect(!allFixtureText.contains { $0.intersects(placement.rect) })
    #expect(!drawings.flatMap(\.paintedRects).contains { $0.intersects(placement.rect) })
}

@MainActor
@Test func legendRowsGrowTheBubbleButRevealingWordsDoesNot() {
    var caption = legendCaption()
    let full = BubblePlacer.estimatedBubbleSize(for: caption, maxWidth: 360, maxLines: 4)
    caption.revealedDisplayCharacters = 0
    #expect(BubblePlacer.estimatedBubbleSize(for: caption, maxWidth: 360, maxLines: 4) == full)
    var withoutLegend = caption
    withoutLegend.markLegend = []
    let bare = BubblePlacer.estimatedBubbleSize(for: withoutLegend, maxWidth: 360, maxLines: 4)
    #expect(abs(full.height - bare.height - CaptionBubbleMetrics.legendHeight(rowCount: 5)) < 0.01)
    #expect(full.width == bare.width)
    // A status line hides the legend.
    var status = caption
    status.statusText = SpeechCoordinator.workerStatusText
    var bareStatus = status
    bareStatus.markLegend = []
    #expect(BubblePlacer.estimatedBubbleSize(for: status, maxWidth: 360, maxLines: 4) == BubblePlacer.estimatedBubbleSize(for: bareStatus, maxWidth: 360, maxLines: 4))
}

@MainActor
@Test func legendBubbleRendersAtItsEstimatedSize() throws {
    let caption = legendCaption()
    let estimate = BubblePlacer.estimatedBubbleSize(for: caption, maxWidth: 360, maxLines: 4)
    var sizes: Set<String> = []
    for percent in [0, 50, 100] {
        var revealing = caption
        revealing.revealedDisplayCharacters = caption.current!.display.count * percent / 100
        // Proposed the bubble's width, as CaptionBubbleLayer does.
        let renderer = ImageRenderer(content: CaptionBubbleView(caption: revealing, maxWidth: 360, maxLines: 4).frame(width: estimate.width))
        renderer.scale = 1
        let image = try #require(renderer.cgImage)
        sizes.insert("\(image.width)x\(image.height)")
        #expect(abs(CGFloat(image.width) - estimate.width) <= 2 && abs(CGFloat(image.height) - estimate.height) <= 3,
                "rendered \(image.width)x\(image.height), estimated \(estimate)")
    }
    #expect(sizes.count == 1, "size changed while revealing: \(sizes)")
}

// MARK: - Render

/// ~/Library/Logs/Clicky/renders/marks-dense/near-cursor.png: the table with
/// chips, a mock cursor + companion, and the bubble with the legend beside it
/// (before.png / after.png from the earlier styles are left as they are).
@MainActor
@Test func rendersNearCursorTable() throws {
    let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Clicky/renders/marks-dense", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let drawings = buildNearCursorTable(companionRect: legendCompanion)
    let caption = legendCaption()
    let placement = legendBubblePlacement(caption, drawings: drawings)
    let cursorTip = CGPoint(x: legendCompanion.minX - 10, y: legendCompanion.minY - 12)

    let scene = ZStack(alignment: .topLeading) {
        DenseTableFixture.Backdrop()
        MarkSceneView(drawings: drawings, displayBoundsCG: DenseTableFixture.display.bounds, drawsImmediately: true)
        // Mock system cursor.
        Path { path in
            path.move(to: cursorTip)
            path.addLine(to: CGPoint(x: cursorTip.x, y: cursorTip.y + 17))
            path.addLine(to: CGPoint(x: cursorTip.x + 4.5, y: cursorTip.y + 13))
            path.addLine(to: CGPoint(x: cursorTip.x + 11.5, y: cursorTip.y + 12))
            path.closeSubpath()
        }
        .fill(Color.black)
        .overlay(Path { path in
            path.move(to: cursorTip)
            path.addLine(to: CGPoint(x: cursorTip.x, y: cursorTip.y + 17))
            path.addLine(to: CGPoint(x: cursorTip.x + 4.5, y: cursorTip.y + 13))
            path.addLine(to: CGPoint(x: cursorTip.x + 11.5, y: cursorTip.y + 12))
            path.closeSubpath()
        }.stroke(Color.white, lineWidth: 1.2))
        // Mock companion.
        Circle().fill(MarkPalette.orange).frame(width: 18, height: 18)
            .position(x: legendCompanion.midX, y: legendCompanion.midY)
        CaptionBubbleView(caption: caption, maxWidth: 360, maxLines: 4)
            .frame(width: placement.rect.width, height: placement.rect.height, alignment: .topLeading)
            .position(x: placement.rect.midX, y: placement.rect.midY)
    }
    .frame(width: DenseTableFixture.display.bounds.width, height: DenseTableFixture.display.bounds.height, alignment: .topLeading)

    let renderer = ImageRenderer(content: scene)
    renderer.scale = 2
    let image = try #require(renderer.cgImage)
    try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent("near-cursor.png"))
}
