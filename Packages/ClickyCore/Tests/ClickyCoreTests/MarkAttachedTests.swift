import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import ClickyCore

// The owner's live turns of 2026-10-25: `[MARK:box:#76:M2N3G9024|wrong photo,
// use 4G9088's]` on a 237×237 product photo in a dense Safari grid, and
// `[MARK:box:#77:doyichi]` resnapped onto a 306×587 X post, were both drawn
// as underlines, and the note went to the cursor bubble. Explicit styles now
// win, boxes hug the element, and notes sit right beside their mark.

/// A Safari product grid: 237×237 photo cards (AX links, role text) in rows,
/// each with a title line and a price line under it, plus OCR text inside
/// the photos (the product's printed labels).
private enum ProductGridFixture {
    static let display = MarkSceneDisplay(displayID: 1, bounds: CGRect(x: 0, y: 0, width: 3440, height: 1440),
                                          visible: CGRect(x: 0, y: 30, width: 3440, height: 1400))
    static let cardSize: CGFloat = 237
    static let columnXs: [CGFloat] = [735, 985, 1235, 1485]
    static let rowYs: [CGFloat] = [300, 774]

    static func card(column: Int, row: Int) -> CGRect {
        CGRect(x: columnXs[column], y: rowYs[row], width: cardSize, height: cardSize)
    }

    /// Titles and prices under each card, and a printed label inside each photo.
    static var textObstacles: [CGRect] {
        var texts: [CGRect] = []
        for row in rowYs.indices {
            for column in columnXs.indices {
                let cardRect = card(column: column, row: row)
                texts.append(CGRect(x: cardRect.minX, y: cardRect.maxY + 6, width: 220, height: 15))
                texts.append(CGRect(x: cardRect.minX, y: cardRect.maxY + 25, width: 210, height: 15))
                texts.append(CGRect(x: cardRect.minX, y: cardRect.maxY + 44, width: 90, height: 15))
                texts.append(CGRect(x: cardRect.minX + 60, y: cardRect.minY + 150, width: 110, height: 12))
            }
        }
        return texts
    }
}

@Test func explicitBoxOnAProductPhotoInADenseGridStaysABox() throws {
    let photo = ProductGridFixture.card(column: 1, row: 1)
    let input = MarkSceneInput(id: UUID(), style: .box, rectCG: photo, displayText: "wrong photo, use 4G9088's", isTentative: false,
                               order: 0, targetRole: .text, isStyleExplicit: true)
    for labelStyle in [MarkLabelStyle.attached, .nearCursor, .column] {
        let drawing = MarkSceneBuilder.build(inputs: [input], displays: [ProductGridFixture.display],
                                             textObstacles: ProductGridFixture.textObstacles, labelStyle: labelStyle)[0]
        #expect(drawing.underline == nil, "\(labelStyle): the box became an underline")
        let outline = try #require(drawing.outline)
        #expect(outline.kind == .roundedBox && outline.cornerRadius > 0)
        #expect(drawing.drawnKind == "rbox")
        // Tight: never more than 4 pt outside the photo, never inside it.
        #expect(outline.rect.contains(photo))
        #expect(photo.minX - outline.rect.minX <= 4 && outline.rect.maxY - photo.maxY <= 4)
        // The title line 6 pt below: the pad shrinks so the stroke clears it.
        let title = CGRect(x: photo.minX, y: photo.maxY + 6, width: 220, height: 15)
        #expect(!outline.rect.insetBy(dx: -MarkPalette.fineLineWidth / 2, dy: -MarkPalette.fineLineWidth / 2).intersects(title))
    }
}

@Test func unstyledMarkOnAPhotoCardIsNeverAnUnderlineEither() throws {
    let photo = ProductGridFixture.card(column: 2, row: 1)
    for role in [MarkTargetRole.text, .visual, .unknown] {
        let input = MarkSceneInput(id: UUID(), style: .circle, rectCG: photo, displayText: nil, isTentative: false, order: 0, targetRole: role)
        let drawing = MarkSceneBuilder.build(inputs: [input], displays: [ProductGridFixture.display],
                                             textObstacles: ProductGridFixture.textObstacles)[0]
        #expect(drawing.underline == nil && drawing.outline != nil, "\(role): a 237 pt photo is not a text row")
    }
}

@Test func tallPostCardResnapStaysABox() throws {
    // The X post, 306×587, with lines of tweet text inside and the next post below.
    let post = CGRect(x: 1499, y: 835, width: 306, height: 587)
    var texts: [CGRect] = []
    for line in 0..<12 { texts.append(CGRect(x: 1560, y: 880 + CGFloat(line) * 20, width: 230, height: 14)) }
    texts.append(CGRect(x: 1590, y: 1290, width: 43, height: 14))
    texts.append(CGRect(x: 1560, y: post.maxY + 10, width: 200, height: 14))
    let input = MarkSceneInput(id: UUID(), style: .box, rectCG: post, displayText: nil, isTentative: false, order: 0, targetRole: .text,
                               isStyleExplicit: true)
    let drawing = MarkSceneBuilder.build(inputs: [input], displays: [ProductGridFixture.display], textObstacles: texts)[0]
    #expect(drawing.underline == nil)
    let outline = try #require(drawing.outline)
    #expect(outline.kind == .roundedBox)
    #expect(outline.rect == post.insetBy(dx: -3, dy: -3), "the element's own bounds plus the 3 pt pad")
}

@Test func unstyledMarkOnATwentyPointRowInADenseTableBecomesAnUnderline() throws {
    let display = DenseTableFixture.display
    // 20 pt rows with 12 pt text, one above another.
    let rows = (0..<10).map { CGRect(x: 150, y: 200 + CGFloat($0) * 20, width: 700, height: 20) }
    let texts = rows.map { CGRect(x: $0.minX + 10, y: $0.midY - 6, width: 180, height: 12) }
    let unstyled = MarkSceneInput(id: UUID(), style: .circle, rectCG: rows[4], displayText: nil, isTentative: false, order: 0, targetRole: .text)
    let drawing = MarkSceneBuilder.build(inputs: [unstyled], displays: [display], textObstacles: texts + rows)[0]
    #expect(drawing.outline == nil)
    let underline = try #require(drawing.underline)
    #expect(drawing.isDense && drawing.drawnKind == "underline")
    #expect(abs(underline.start.x - texts[4].minX) < 0.01 && abs(underline.end.x - texts[4].maxX) < 0.01)

    // A step on that row too; but a circle or box the model wrote keeps its outline.
    let step = MarkSceneInput(id: UUID(), style: .step(1), rectCG: rows[4], displayText: nil, isTentative: false, order: 0, targetRole: .text,
                              isStyleExplicit: true)
    #expect(MarkSceneBuilder.build(inputs: [step], displays: [display], textObstacles: texts + rows)[0].underline != nil)
    for style in [MarkStyleKind.circle, .box] {
        let explicit = MarkSceneInput(id: UUID(), style: style, rectCG: rows[4], displayText: nil, isTentative: false, order: 0,
                                      targetRole: .text, isStyleExplicit: true)
        let explicitDrawing = MarkSceneBuilder.build(inputs: [explicit], displays: [display], textObstacles: texts + rows)[0]
        #expect(explicitDrawing.underline == nil && explicitDrawing.outline != nil, "explicit \(style.name) was downgraded")
    }
}

@Test func singleTextRowRule() {
    let row = CGRect(x: 0, y: 0, width: 600, height: 22)
    let text = CGRect(x: 10, y: 4, width: 200, height: 14)
    let rowAnalysis = MarkDensity.analyze(target: row, role: .text, leafTexts: [text])
    #expect(MarkDensity.isSingleTextRow(rowAnalysis, target: row))
    let twoLines = CGRect(x: 0, y: 0, width: 600, height: 44)
    let twoLineAnalysis = MarkDensity.analyze(target: twoLines, role: .text, leafTexts: [text, text.offsetBy(dx: 0, dy: 20)])
    #expect(!MarkDensity.isSingleTextRow(twoLineAnalysis, target: twoLines))
    let image = CGRect(x: 0, y: 0, width: 237, height: 237)
    #expect(!MarkDensity.isSingleTextRow(MarkDensity.analyze(target: image, role: .text, leafTexts: []), target: image))
    #expect(!MarkDensity.isSingleTextRow(MarkDensity.analyze(target: row, role: .visual, leafTexts: [text]), target: row))
    #expect(!MarkDensity.isSingleTextRow(MarkDensity.analyze(target: row, role: .control, leafTexts: [text]), target: row))
    let imageElement = GroundingElement(role: .image, label: "Photo", frameCG: image, processIdentifier: 1, displayID: 1,
                                        isInteractive: false, source: .accessibility)
    #expect(MarkTextObstacles.targetRole(for: imageElement, isTextMatch: false) == .visual)
}

@Test func outlinePadIsAtMostFourAndShrinksForNeighbourText() {
    let target = CGRect(x: 100, y: 100, width: 80, height: 30)
    #expect(MarkDensity.outlinePad(target: target, neighbours: []) == 3)
    #expect(MarkDensity.outlinePad(target: target, neighbours: [CGRect(x: 100, y: 140, width: 80, height: 14)]) == 3)
    // 3 pt below: the stroke (pad + 1) may reach 2 pt → pad 2.
    let close = CGRect(x: 100, y: 133, width: 80, height: 14)
    let pad = MarkDensity.outlinePad(target: target, neighbours: [close])
    #expect(pad == 2)
    // Touching: pad 0.
    #expect(MarkDensity.outlinePad(target: target, neighbours: [CGRect(x: 100, y: 130.5, width: 80, height: 14)]) == 0)
    // Text inside or overlapping the target itself can't be avoided and doesn't shrink it.
    #expect(MarkDensity.outlinePad(target: target, neighbours: [CGRect(x: 110, y: 120, width: 40, height: 20)]) == 3)
    for anyPad in [-2, 0, 3, 9] as [CGFloat] {
        let shape = MarkLayout.tightOutline(target: target, display: CGRect(x: 0, y: 0, width: 800, height: 600), pad: anyPad, isBox: true)
        #expect(target.minX - shape.rect.minX <= 4 && target.minX - shape.rect.minX >= 0)
    }
}

// MARK: - Attached notes

private enum OpenPageFixture {
    static let display = MarkSceneDisplay(displayID: 1, bounds: CGRect(x: 0, y: 0, width: 1440, height: 900),
                                          visible: CGRect(x: 0, y: 25, width: 1440, height: 800))
    static let card = CGRect(x: 600, y: 300, width: 200, height: 200)

    static func input(_ rect: CGRect = card, note: String? = "wrong photo, use 4G9088's", order: Int = 0,
                      style: MarkStyleKind = .box) -> MarkSceneInput {
        MarkSceneInput(id: UUID(), style: style, rectCG: rect, displayText: note, isTentative: false, order: order, targetRole: .visual,
                       isStyleExplicit: true)
    }
}

@Test func attachedNoteSitsRightBesideItsBox() throws {
    let drawing = MarkSceneBuilder.build(inputs: [OpenPageFixture.input()], displays: [OpenPageFixture.display], labelStyle: .attached)[0]
    let outline = try #require(drawing.outline)
    let labelRect = try #require(drawing.labelRect)
    #expect(drawing.isLabelAttached && !drawing.isNoteInLegend && drawing.notePlacement == "attached")
    #expect(drawing.leader == nil && drawing.chipCenter == nil)
    // Right side, 6 pt past the outline's halo, vertically centred.
    let haloEdge = outline.rect.maxX + MarkPalette.fineHaloWidth / 2
    #expect(abs(labelRect.minX - haloEdge - AttachedNotes.gap) < 0.01)
    #expect(abs(labelRect.midY - outline.rect.midY) < 0.01)
    #expect(labelRect.height < 24, "the note pill is small")
    #expect(MarkChips.legend(forFallbacks: [drawing]).isEmpty)
}

@Test func attachedNoteAvoidsObstaclesAndPicksTheNextCleanSide() throws {
    let card = OpenPageFixture.card
    // Text right of the card: the note goes left.
    let rightText = CGRect(x: card.maxX + 8, y: card.minY, width: 300, height: card.height)
    let leftDrawing = MarkSceneBuilder.build(inputs: [OpenPageFixture.input()], displays: [OpenPageFixture.display],
                                             textObstacles: [rightText], labelStyle: .attached)[0]
    let leftLabel = try #require(leftDrawing.labelRect)
    #expect(leftDrawing.isLabelAttached && leftLabel.maxX < card.minX && !leftLabel.intersects(rightText))
    // Text on both sides: below.
    let leftText = CGRect(x: card.minX - 308, y: card.minY, width: 300, height: card.height)
    let belowDrawing = MarkSceneBuilder.build(inputs: [OpenPageFixture.input()], displays: [OpenPageFixture.display],
                                              textObstacles: [rightText, leftText], labelStyle: .attached)[0]
    let belowLabel = try #require(belowDrawing.labelRect)
    #expect(belowLabel.minY > card.maxY && belowLabel.minY - card.maxY <= AttachedNotes.maximumReach + 6)
    // A wide mark prefers below.
    let banner = CGRect(x: 300, y: 200, width: 700, height: 60)
    let bannerDrawing = MarkSceneBuilder.build(inputs: [OpenPageFixture.input(banner)], displays: [OpenPageFixture.display],
                                               labelStyle: .attached)[0]
    #expect(try #require(bannerDrawing.labelRect).minY > banner.maxY)
    // Two neighbouring cards: neither note covers the other mark or note.
    let second = card.offsetBy(dx: 250, dy: 0)
    let pair = MarkSceneBuilder.build(inputs: [OpenPageFixture.input(), OpenPageFixture.input(second, note: "copy this photo", order: 1)],
                                      displays: [OpenPageFixture.display], labelStyle: .attached)
    let firstLabel = try #require(pair[0].labelRect)
    let secondLabel = try #require(pair[1].labelRect)
    #expect(!firstLabel.intersects(secondLabel))
    #expect(!firstLabel.intersects(pair[1].outline!.rect) && !secondLabel.intersects(pair[0].outline!.rect))
    #expect(pair.allSatisfy { $0.isLabelAttached && $0.leader == nil })
}

@Test func attachedNoteKeepsOffNeighbouringPhotosWhenItCan() throws {
    // The owner's grid: photo cards 13 pt apart, titles under them. Right /
    // left would cover the next photo, below is the title: the note goes above.
    let photo = ProductGridFixture.card(column: 1, row: 1)
    let photos = ProductGridFixture.columnXs.indices.flatMap { column in ProductGridFixture.rowYs.indices.map { ProductGridFixture.card(column: column, row: $0) } }
    let input = MarkSceneInput(id: UUID(), style: .box, rectCG: photo, displayText: "wrong photo, use 4G9088's", isTentative: false,
                               order: 0, targetRole: .text, isStyleExplicit: true)
    let drawing = MarkSceneBuilder.build(inputs: [input], displays: [ProductGridFixture.display], textObstacles: ProductGridFixture.textObstacles,
                                         labelStyle: .attached, visualObstacles: photos)[0]
    let labelRect = try #require(drawing.labelRect)
    #expect(drawing.isLabelAttached)
    for other in photos where other != photo { #expect(!labelRect.intersects(other), "note covers the photo at \(other)") }
    #expect(!MarkDensity.leafTextBounds(ProductGridFixture.textObstacles).contains { $0.intersects(labelRect) })
    #expect(labelRect.maxY <= photo.minY && photo.minY - labelRect.maxY <= AttachedNotes.maximumReach + 4, "above, right next to it")
    // With no clean spot off the photos, it still attaches (covering a photo beats the legend).
    let crowded = photos + [CGRect(x: photo.minX, y: photo.minY - 60, width: photo.width, height: 58)]
    let fallbackDrawing = MarkSceneBuilder.build(inputs: [input], displays: [ProductGridFixture.display],
                                                 textObstacles: ProductGridFixture.textObstacles, labelStyle: .attached,
                                                 visualObstacles: crowded)[0]
    #expect(fallbackDrawing.isLabelAttached)
}

@Test func attachedNoteFallsBackToChipAndLegendWhenBoxedIn() throws {
    let card = OpenPageFixture.card
    // Text everywhere within 60 pt of the card, except the card itself.
    var texts: [CGRect] = []
    var y = card.minY - 70
    while y < card.maxY + 70 {
        for x in stride(from: card.minX - 120, to: card.maxX + 120, by: 60) as StrideTo<CGFloat> {
            let text = CGRect(x: x, y: y, width: 56, height: 12)
            if !text.intersects(card.insetBy(dx: -4, dy: -4)) { texts.append(text) }
        }
        y += 14
    }
    let boxed = OpenPageFixture.input()
    let open = OpenPageFixture.input(CGRect(x: 100, y: 100, width: 120, height: 40), note: "this one has room", order: 1)
    let drawings = MarkSceneBuilder.build(inputs: [boxed, open], displays: [OpenPageFixture.display], textObstacles: texts, labelStyle: .attached)
    let fallback = drawings[0]
    #expect(fallback.labelRect == nil && !fallback.isLabelAttached)
    #expect(fallback.isNoteInLegend && fallback.notePlacement == "legend")
    #expect(fallback.outline != nil, "the box itself is still drawn")
    let chip = try #require(fallback.chipCenter)
    #expect(fallback.chipNumber == 1)
    #expect(MarkChips.rect(center: chip).intersects(fallback.outline!.rect.insetBy(dx: -12, dy: -12)), "the chip rides on the mark")
    // Only the fallback is in the legend, with its full note; the other note is attached.
    #expect(MarkChips.legend(forFallbacks: drawings) == [MarkLegendEntry(number: 1, text: "wrong photo, use 4G9088's")])
    #expect(drawings[1].isLabelAttached && drawings[1].chipCenter == nil)
}

@Test func attachedNotesStayOnScreen() throws {
    // A card hard against the right edge: the note goes left, inside visible.
    let card = CGRect(x: 1440 - 210, y: 400, width: 200, height: 150)
    let drawing = MarkSceneBuilder.build(inputs: [OpenPageFixture.input(card)], displays: [OpenPageFixture.display], labelStyle: .attached)[0]
    let labelRect = try #require(drawing.labelRect)
    #expect(OpenPageFixture.display.visible.insetBy(dx: AttachedNotes.screenMargin, dy: AttachedNotes.screenMargin).contains(labelRect))
    #expect(labelRect.maxX <= card.minX)
}

@Test func attachedNoteTextIsShort() {
    #expect(AttachedNotes.noteText("wrong photo, use 4G9088's") == "wrong photo, use 4G9088's")
    let long = AttachedNotes.noteText("this is the photo that is wrong and should really be replaced soon")
    #expect(long.hasSuffix("…") && long.split(separator: " ").count <= AttachedNotes.maximumWords)
    let wordy = AttachedNotes.noteText("supercalifragilistic expialidocious photographs everywhere")
    #expect(wordy.count <= AttachedNotes.maximumCharacters && wordy.hasSuffix("…"))
    #expect(AttachedNotes.noteText("  copy   this  ") == "copy this")
}

@Test func attachedUnderlinedRowNoteGoesBesideTheText() throws {
    let drawings = MarkSceneBuilder.build(inputs: DenseTableFixture.inputs(), displays: [DenseTableFixture.display],
                                          textObstacles: DenseTableFixture.textObstacles, labelStyle: .attached)
    let allText = MarkDensity.leafTextBounds(DenseTableFixture.textObstacles)
    for drawing in drawings {
        #expect(drawing.underline != nil, "steps on dense rows are still underlined")
        #expect(drawing.leader == nil)
        if let labelRect = drawing.labelRect {
            #expect(drawing.isLabelAttached)
            #expect(!allText.contains { $0.intersects(labelRect) }, "note \(labelRect) on text")
            #expect(drawing.labelStepNumber != nil, "a step's number rides in its note")
        } else {
            #expect(drawing.isNoteInLegend && drawing.chipCenter != nil)
        }
    }
    let labelRects = drawings.compactMap(\.labelRect)
    #expect(labelRects.count >= 3, "most rows have room right of their title")
    for (index, first) in labelRects.enumerated() { for second in labelRects[(index + 1)...] { #expect(!first.intersects(second)) } }
}

// MARK: - Parser and settings

@Test func parserRecordsWhetherTheStyleWasWritten() throws {
    #expect(try #require(MarkTagParser.parse("[MARK:box:#76:M2N3G9024|wrong photo, use 4G9088's]")).hasExplicitStyle)
    #expect(try #require(MarkTagParser.parse("[MARK:underline:#67:Sifr's post]")).hasExplicitStyle)
    #expect(try #require(MarkTagParser.parse("[MARK:2:#40:Dark]")).hasExplicitStyle)
    let unstyled = try #require(MarkTagParser.parse("[MARK:#57:Share]"))
    #expect(unstyled.style == .circle && !unstyled.hasExplicitStyle)
    let unknown = try #require(MarkTagParser.parse("[MARK:sparkle:#57:Share]"))
    #expect(unknown.style == .circle && !unknown.hasExplicitStyle)
}

@Test func attachedIsTheDefaultLabelStyle() {
    let entry = ClickySettingsCatalog.entries.first { $0.key == ClickySettings.Keys.marksLabelStyle }
    #expect(entry?.kind == .choice(options: ["attached", "nearCursor", "column"], defaultValue: "attached"))
    #expect(MarkLabelStyle(rawValue: "attached") == .attached && MarkLabelStyle(rawValue: "nearCursor") == .nearCursor
        && MarkLabelStyle(rawValue: "column") == .column)
}

@Test func promptTellsTheModelWhenToBoxAndThatNotesShowBesideTheMark() {
    let prompt = SystemPromptBuilder.mainSystemPrompt()
    #expect(prompt.contains("use box for cards, images, buttons and page regions"))
    #expect(prompt.contains("underline for one text row in a dense list or table"))
    #expect(prompt.contains("at most eight words; it shows right beside the mark"))
}
