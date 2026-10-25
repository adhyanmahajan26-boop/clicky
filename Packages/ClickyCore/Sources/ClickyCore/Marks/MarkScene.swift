//
//  MarkScene.swift
//  ClickyCore
//
//  Turns the live marks (target rect + style + text) into everything the
//  overlay draws, in CG global points: the outline, arrow, underline, spot
//  cut-out, step discs and connectors, leader arrows, and where each label
//  goes.
//
//  Density-aware (v2): given the region's text bounds, circle / box / step
//  marks on dense text rows become thin underlines under the text and
//  isolated controls get a tight outline (MarkDensity). Labels go in clear
//  space: next to an isolated outline when that's free, else in one shared
//  column per display with leader arrows (LabelColumnPlacer). A step's
//  number rides inside its label pill; a separate numbered disc is kept only
//  for an outlined step with no label. That is the `column` label style.
//
//  Explicit style wins: a box / circle the model wrote keeps its outline,
//  tight to the element (pad ≤ 3 pt, shrunk to clear neighbouring text);
//  only unstyled marks and steps on a single dense text row are underlined.
//
//  The `attached` style (the default, AttachedNotes): each note is a small
//  pill right beside its mark, no leaders; a mark with no clean spot within
//  40 pt gets a numbered chip and its note goes to the bubble's legend.
//
//  The `nearCursor` style (MarkChips): same shapes, but no text
//  on screen. With 2+ marks each gets a small numbered chip at its
//  underline's start / outline's top-left / arrow's tail, and the words go
//  to the caption bubble's legend; a single mark gets neither.
//

import CoreGraphics
import Foundation

public enum MarkStyleKind: Equatable, Hashable, Sendable {
    case circle
    case box
    case arrow
    case underline
    case spot
    case step(Int)

    public var name: String {
        switch self {
        case .circle: return "circle"
        case .box: return "box"
        case .arrow: return "arrow"
        case .underline: return "underline"
        case .spot: return "spot"
        case .step(let stepNumber): return "step\(stepNumber)"
        }
    }
}

public struct MarkSceneInput: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let style: MarkStyleKind
    public var rectCG: CGRect
    /// Already chosen by the caller: the note, else the name for arrows and steps, else nil.
    public let displayText: String?
    public var isTentative: Bool
    public var isHidden: Bool
    /// 1 normally; tracking fades it before removal.
    public var opacity: Double
    public let order: Int
    /// The target's window (labels prefer its empty area), nil if unknown.
    public var windowFrameCG: CGRect?
    /// What the target is, when the caller knows.
    public var targetRole: MarkTargetRole
    /// The model wrote the style (box, circle…); false for unstyled marks,
    /// which may become underlines on dense text rows.
    public var isStyleExplicit: Bool

    public init(id: UUID, style: MarkStyleKind, rectCG: CGRect, displayText: String?, isTentative: Bool,
                isHidden: Bool = false, opacity: Double = 1, order: Int, windowFrameCG: CGRect? = nil, targetRole: MarkTargetRole = .unknown,
                isStyleExplicit: Bool = false) {
        self.isStyleExplicit = isStyleExplicit
        self.windowFrameCG = windowFrameCG
        self.targetRole = targetRole
        self.id = id
        self.style = style
        self.rectCG = rectCG
        self.displayText = displayText
        self.isTentative = isTentative
        self.isHidden = isHidden
        self.opacity = opacity
        self.order = order
    }
}

public struct MarkSceneDisplay: Equatable, Sendable {
    public let displayID: CGDirectDisplayID
    /// CGDisplayBounds: shapes stay inside it.
    public let bounds: CGRect
    /// Minus menu bar and Dock: labels, tails and the companion stay inside it.
    public let visible: CGRect

    public init(displayID: CGDirectDisplayID, bounds: CGRect, visible: CGRect) {
        self.displayID = displayID
        self.bounds = bounds
        self.visible = visible
    }

    public init(_ displayInfo: DisplayInfo) {
        self.init(displayID: displayInfo.displayID, bounds: displayInfo.boundsCG, visible: displayInfo.visibleCG)
    }
}

public struct MarkDrawing: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let style: MarkStyleKind
    public let targetCG: CGRect
    public let displayID: CGDirectDisplayID
    public let displayBounds: CGRect
    /// Outline for circle / box / step (and the spot's cut-out).
    public let outline: MarkShapeSpec?
    public let arrow: ArrowSpec?
    public let underline: (start: CGPoint, end: CGPoint)?
    public let stepDiscCenter: CGPoint?
    /// The previous step's disc, for the dashed connector.
    public let connectorFrom: CGPoint?
    public let labelRect: CGRect?
    public let labelText: String?
    /// A step's number, drawn as a disc inside the label pill.
    public let labelStepNumber: Int?
    /// Thin arrow from a label placed away from its mark.
    public let leader: LeaderSpec?
    /// nearCursor style (and attached fallbacks): the small numbered chip on the mark.
    public let chipCenter: CGPoint?
    public let chipNumber: Int?
    /// attached style: the label is the small note pill beside the mark.
    public let isLabelAttached: Bool
    /// attached style: no clean spot, so the note is in the bubble's legend.
    public let isNoteInLegend: Bool
    /// The target sat on a dense text row (diagnostics).
    public let isDense: Bool
    public let isTentative: Bool
    public let isHidden: Bool
    public let opacity: Double
    public let order: Int

    /// Everything this mark draws (the spot dims its whole display).
    public var drawnBounds: CGRect {
        if style == .spot { return displayBounds }
        var bounds = targetCG
        if let outline { bounds = bounds.union(outline.rect) }
        if let arrow {
            for point in [arrow.tail, arrow.tip, arrow.control, arrow.headLeft, arrow.headRight] {
                bounds = bounds.union(CGRect(origin: point, size: .zero))
            }
        }
        if let labelRect { bounds = bounds.union(labelRect) }
        if let underline {
            bounds = bounds.union(CGRect(x: underline.start.x, y: underline.start.y - 3, width: underline.end.x - underline.start.x, height: 6))
        }
        if let leader {
            for point in [leader.start, leader.tip, leader.headLeft, leader.headRight] {
                bounds = bounds.union(CGRect(origin: point, size: .zero))
            }
        }
        if let chipCenter { bounds = bounds.union(MarkChips.rect(center: chipCenter)) }
        if let stepDiscCenter {
            let discRadius = MarkLayout.stepDiscDiameter / 2
            bounds = bounds.union(CGRect(x: stepDiscCenter.x - discRadius, y: stepDiscCenter.y - discRadius,
                                         width: MarkLayout.stepDiscDiameter, height: MarkLayout.stepDiscDiameter))
        }
        return bounds
    }

    /// What the caption bubble keeps clear of: the pieces actually painted
    /// plus the marked text, not the whole bounding box (an underlined row's
    /// empty right half is fine for the bubble).
    public var paintedRects: [CGRect] {
        if style == .spot { return [displayBounds] }
        var rects: [CGRect] = []
        if let underline {
            let bandBottom = underline.start.y + MarkPalette.fineHaloWidth / 2
            let top = min(targetCG.minY, bandBottom)
            rects.append(CGRect(x: underline.start.x, y: top, width: underline.end.x - underline.start.x, height: bandBottom - top))
        } else if let outline {
            rects.append(outline.rect.insetBy(dx: -MarkPalette.fineHaloWidth / 2, dy: -MarkPalette.fineHaloWidth / 2))
        } else {
            rects.append(targetCG)
        }
        if let arrow { rects += [MarkLayout.padded(targetCG)] + MarkSceneBuilder.arrowRects(arrow) }
        if let labelRect { rects.append(labelRect) }
        if let leader {
            rects.append([leader.start, leader.tip, leader.headLeft, leader.headRight].reduce(CGRect(origin: leader.start, size: .zero)) {
                $0.union(CGRect(origin: $1, size: .zero))
            }.insetBy(dx: -2, dy: -2))
        }
        if let chipCenter { rects.append(MarkChips.rect(center: chipCenter)) }
        if let stepDiscCenter {
            let discRadius = MarkLayout.stepDiscDiameter / 2
            rects.append(CGRect(x: stepDiscCenter.x - discRadius, y: stepDiscCenter.y - discRadius,
                                width: MarkLayout.stepDiscDiameter, height: MarkLayout.stepDiscDiameter))
        }
        return rects
    }

    public static func == (first: MarkDrawing, second: MarkDrawing) -> Bool {
        first.id == second.id && first.style == second.style && first.targetCG == second.targetCG && first.outline == second.outline
            && first.arrow == second.arrow && first.underline?.start == second.underline?.start && first.underline?.end == second.underline?.end
            && first.stepDiscCenter == second.stepDiscCenter && first.connectorFrom == second.connectorFrom
            && first.labelRect == second.labelRect && first.labelText == second.labelText && first.isTentative == second.isTentative
            && first.isHidden == second.isHidden && first.opacity == second.opacity && first.displayID == second.displayID
            && first.labelStepNumber == second.labelStepNumber && first.leader == second.leader && first.isDense == second.isDense
            && first.chipCenter == second.chipCenter && first.chipNumber == second.chipNumber
            && first.isLabelAttached == second.isLabelAttached && first.isNoteInLegend == second.isNoteInLegend
    }

    /// The final drawn form, for turn.json: rbox / pill / ellipse /
    /// underline / arrow / spot.
    public var drawnKind: String {
        if style == .spot { return "spot" }
        if arrow != nil { return "arrow" }
        if underline != nil { return "underline" }
        return outline?.kind.rawValue ?? style.name
    }

    /// Where the note went, for turn.json: attached / legend / column /
    /// nil (no note on screen, or nearCursor's legend).
    public var notePlacement: String? {
        if isNoteInLegend { return "legend" }
        guard labelRect != nil, labelText != nil || labelStepNumber != nil else { return nil }
        return isLabelAttached ? "attached" : "column"
    }
}

public enum MarkSceneBuilder {
    public static func display(for rectCG: CGRect, in displays: [MarkSceneDisplay]) -> MarkSceneDisplay? {
        if let containing = displays.first(where: { $0.bounds.contains(rectCG.center) }) { return containing }
        return displays.min { first, second in
            first.bounds.edgeDistance(to: rectCG.center) < second.bounds.edgeDistance(to: rectCG.center)
        }
    }

    /// Geometry of one mark before its label is placed.
    struct Planned {
        let input: MarkSceneInput
        let display: MarkSceneDisplay
        var outline: MarkShapeSpec?
        var arrow: ArrowSpec?
        var underline: (start: CGPoint, end: CGPoint)?
        var stepDiscCenter: CGPoint?
        var connectorFrom: CGPoint?
        var labelRect: CGRect?
        var labelSize: CGSize?
        var labelStepNumber: Int?
        var leader: LeaderSpec?
        var chipCenter: CGPoint?
        var chipNumber: Int?
        var isLabelAttached = false
        var isNoteInLegend = false
        /// Where the chip goes before nudging.
        var chipSpot: CGPoint?
        var isDense = false
        /// What a leader points at.
        var attachRect: CGRect
        /// What this mark draws, as obstacles for every other label.
        var geometry: [CGRect] = []
    }

    /// `companionRect`: where the buddy is parked (an obstacle for labels).
    /// `textObstacles`: every text bound in the region (AX text / cell / row
    /// frames, OCR lines), CG; containers are seen through.
    /// `labelStyle`: `.column` (the default here) keeps 2dfbab2's labels;
    /// `.nearCursor` draws chips only (see MarkChips). `expectedMarkCount`:
    /// marks already parsed for this answer, so the first one gets its chip
    /// before the second is spoken. `visualObstacles`: image / card frames
    /// (MarkTextObstacles.collectVisual) an attached note avoids when it can.
    public static func build(inputs: [MarkSceneInput], displays: [MarkSceneDisplay], companionRect: CGRect? = nil,
                             textObstacles: [CGRect] = [], labelStyle: MarkLabelStyle = .column, expectedMarkCount: Int = 0,
                             visualObstacles: [CGRect] = []) -> [MarkDrawing] {
        let leafTexts = MarkDensity.leafTextBounds(textObstacles)
        let isNearCursor = labelStyle == .nearCursor
        let isAttached = labelStyle == .attached
        let hasChips = isNearCursor && MarkChips.isMultiTarget(markCount: inputs.count, expectedMarkCount: expectedMarkCount)
        var planned: [Planned] = []
        var previousStepDisc: CGPoint?
        var arrowObstacles: [CGRect] = (companionRect.map { [$0] } ?? []) + leafTexts

        // Pass 1: each mark's shape.
        for (answerIndex, input) in inputs.sorted(by: { $0.order < $1.order }).enumerated() {
            guard let markDisplay = display(for: input.rectCG, in: displays) else { continue }
            let target = input.rectCG
            let displayTexts = leafTexts.filter { $0.intersects(markDisplay.bounds) }
            let analysis = MarkDensity.analyze(target: target, role: input.targetRole, leafTexts: displayTexts)
            var plan = Planned(input: input, display: markDisplay, attachRect: target)
            var stepNumber: Int?
            if case .step(let number) = input.style { stepNumber = number }

            switch input.style {
            case .circle, .box, .step:
                let pad = MarkDensity.outlinePad(target: target, neighbours: analysis.neighbours)
                let tight = MarkLayout.tightOutline(target: target, display: markDisplay.bounds, pad: pad, isBox: input.style == .box)
                let fullPadOutline = MarkLayout.tightOutline(target: target, display: markDisplay.bounds)
                if MarkDensity.form(for: analysis, style: input.style, isStyleExplicit: input.isStyleExplicit, target: target,
                                    tightOutline: fullPadOutline) == .underline {
                    plan.isDense = analysis.isDense
                    let line = MarkDensity.underline(for: analysis, target: target, display: markDisplay.bounds)
                    plan.underline = line
                    plan.attachRect = (analysis.textSpan ?? target).union(underlineRect(line))
                    plan.chipSpot = MarkChips.underlineSpot(lineStart: line.start, textLine: analysis.textSpan ?? target)
                } else {
                    plan.outline = tight
                    plan.attachRect = tight.rect
                    plan.chipSpot = MarkChips.outlineSpot(tight.rect)
                    if !isNearCursor && stepNumber != nil && input.displayText == nil {
                        // An outlined step with no words keeps its numbered disc.
                        let disc = MarkLayout.stepDiscCenter(ring: tight, visible: markDisplay.visible)
                        plan.stepDiscCenter = disc
                        plan.connectorFrom = previousStepDisc
                        previousStepDisc = disc
                        stepNumber = nil
                    }
                }
                if plan.stepDiscCenter == nil { plan.labelStepNumber = stepNumber }
            case .underline:
                plan.isDense = analysis.isDense
                let line = MarkDensity.underline(for: analysis, target: target, display: markDisplay.bounds)
                plan.underline = line
                plan.attachRect = (analysis.textSpan ?? target).union(underlineRect(line))
                plan.chipSpot = MarkChips.underlineSpot(lineStart: line.start, textLine: analysis.textSpan ?? target)
            case .spot:
                plan.outline = MarkShapeSpec(kind: .roundedBox, rect: MarkLayout.padded(target).intersection(markDisplay.bounds), cornerRadius: 8)
                plan.attachRect = MarkLayout.padded(target)
                plan.chipSpot = plan.outline.map { MarkChips.outlineSpot($0.rect) }
            case .arrow:
                // nearCursor: the words go to the bubble, so no label space is reserved.
                let labelSize = isNearCursor ? nil
                    : isAttached ? input.displayText.map { AttachedNotes.size(for: AttachedNotes.noteText($0)) }
                    : input.displayText.map(LabelPlacer.size(for:))
                let arrow = MarkLayout.arrow(target: target, visible: markDisplay.visible, labelSize: labelSize, obstacles: arrowObstacles)
                plan.arrow = arrow
                plan.labelRect = arrow.labelRect
                plan.chipSpot = MarkChips.arrowSpot(arrow)
            }
            if isNearCursor {
                plan.labelStepNumber = nil
                plan.labelRect = nil
                if hasChips { plan.chipNumber = MarkChips.number(for: input.style, index: answerIndex) }
            } else if isAttached {
                // The fallback chip's number, used only when the note finds no spot.
                plan.chipNumber = MarkChips.number(for: input.style, index: answerIndex)
                if input.displayText != nil || plan.labelStepNumber != nil {
                    plan.labelSize = AttachedNotes.size(for: input.displayText.map(AttachedNotes.noteText), stepNumber: plan.labelStepNumber)
                }
            } else if input.displayText != nil || plan.labelStepNumber != nil {
                plan.labelSize = LabelPlacer.size(for: input.displayText, stepNumber: plan.labelStepNumber)
            }

            if let outline = plan.outline, input.style != .spot { plan.geometry.append(outline.rect.insetBy(dx: -2, dy: -2)) }
            if input.style == .spot { plan.geometry.append(MarkLayout.padded(target)) }
            if let line = plan.underline { plan.geometry.append(underlineRect(line)) }
            if let arrow = plan.arrow {
                plan.geometry.append(MarkLayout.padded(target))
                plan.geometry.append(contentsOf: arrowRects(arrow))
            }
            if let disc = plan.stepDiscCenter {
                let discRadius = MarkLayout.stepDiscDiameter / 2
                plan.geometry.append(CGRect(x: disc.x - discRadius, y: disc.y - discRadius, width: MarkLayout.stepDiscDiameter, height: MarkLayout.stepDiscDiameter))
            }
            if !input.isHidden {
                arrowObstacles += plan.geometry
                if let labelRect = plan.labelRect, !isAttached { arrowObstacles.append(labelRect) }
            }
            planned.append(plan)
        }

        let visibleIndexes = planned.indices.filter { !planned[$0].input.isHidden }
        if isNearCursor {
            placeChips(&planned, visibleIndexes: visibleIndexes, leafTexts: leafTexts, companionRect: companionRect)
            return planned.map(drawing(for:))
        }
        if isAttached {
            placeAttachedNotes(&planned, visibleIndexes: visibleIndexes, leafTexts: leafTexts, companionRect: companionRect,
                               visualObstacles: visualObstacles)
            return planned.map(drawing(for:))
        }

        // Pass 2: labels, against text, every mark's geometry, placed labels and the companion.
        var obstacles: [CGRect] = (companionRect.map { [$0] } ?? []) + leafTexts
        for index in visibleIndexes {
            obstacles += planned[index].geometry
            if let labelRect = planned[index].labelRect { obstacles.append(labelRect) }
        }
        // Outlined marks first try right next to their outline.
        var columnIndexes: [Int] = []
        for index in visibleIndexes where planned[index].labelRect == nil {
            guard let labelSize = planned[index].labelSize else { continue }
            if let outline = planned[index].outline {
                let placement = LabelPlacer.place(size: labelSize, around: outline.rect.insetBy(dx: -2, dy: -2), visible: planned[index].display.visible,
                                                  obstacles: obstacles)
                if placement.isClean {
                    planned[index].labelRect = placement.rect
                    obstacles.append(placement.rect)
                    continue
                }
            }
            columnIndexes.append(index)
        }
        // The rest share one column per display.
        let indexesByDisplay = Dictionary(grouping: columnIndexes) { planned[$0].display.displayID }
        for displayID in indexesByDisplay.keys.sorted() {
            let indexes = indexesByDisplay[displayID]!
            let markDisplay = planned[indexes[0]].display
            let windowFrames = indexes.compactMap { planned[$0].input.windowFrameCG }
            var region = windowFrames.reduce(nil as CGRect?) { union, frame in union.map { $0.union(frame) } ?? frame } ?? markDisplay.visible
            region = region.intersection(markDisplay.visible)
            if region.isNull || region.isEmpty { region = markDisplay.visible }
            let requests = indexes.map { LabelColumnPlacer.Request(id: planned[$0].input.id, size: planned[$0].labelSize!, attachRect: planned[$0].attachRect) }
            if let rects = LabelColumnPlacer.placeColumn(requests, obstacles: obstacles, region: region, visible: markDisplay.visible) {
                for index in indexes {
                    guard let labelRect = rects[planned[index].input.id] else { continue }
                    planned[index].labelRect = labelRect
                    planned[index].leader = LabelColumnPlacer.leader(label: labelRect, attach: planned[index].attachRect)
                    obstacles.append(labelRect)
                }
            } else {
                // No clean column: least-overlap anchors around each mark.
                for index in indexes {
                    let anchorRect = planned[index].attachRect.insetBy(dx: -3, dy: -3)
                    let placement = LabelPlacer.place(size: planned[index].labelSize!, around: anchorRect, visible: markDisplay.visible,
                                                      obstacles: obstacles + [anchorRect])
                    planned[index].labelRect = placement.rect
                    obstacles.append(placement.rect)
                }
            }
        }

        return planned.map(drawing(for:))
    }

    static func drawing(for plan: Planned) -> MarkDrawing {
        MarkDrawing(
            id: plan.input.id, style: plan.input.style, targetCG: plan.input.rectCG, displayID: plan.display.displayID,
            displayBounds: plan.display.bounds, outline: plan.outline, arrow: plan.arrow, underline: plan.underline,
            stepDiscCenter: plan.stepDiscCenter, connectorFrom: plan.connectorFrom, labelRect: plan.labelRect,
            labelText: plan.input.displayText, labelStepNumber: plan.labelRect == nil ? nil : plan.labelStepNumber,
            leader: plan.leader, chipCenter: plan.chipCenter, chipNumber: plan.chipCenter == nil ? nil : plan.chipNumber,
            isLabelAttached: plan.isLabelAttached, isNoteInLegend: plan.isNoteInLegend, isDense: plan.isDense, isTentative: plan.input.isTentative, isHidden: plan.input.isHidden,
            opacity: plan.input.opacity, order: plan.input.order
        )
    }

    /// nearCursor: each numbered mark's chip, clear of text, every other
    /// mark's geometry, the chips placed so far and the companion. A mark's
    /// own underline is an obstacle too (the chip sits beside it); its own
    /// outline and arrow are not (the chip rides on the corner / the tail).
    static func placeChips(_ planned: inout [Planned], visibleIndexes: [Int], leafTexts: [CGRect], companionRect: CGRect?,
                           extraObstacles: [CGRect] = []) {
        var placedChips: [CGRect] = extraObstacles
        for index in visibleIndexes {
            guard planned[index].chipNumber != nil, let spot = planned[index].chipSpot else { continue }
            var obstacles = leafTexts + placedChips + (companionRect.map { [$0] } ?? [])
            for otherIndex in visibleIndexes {
                if otherIndex != index {
                    obstacles += planned[otherIndex].geometry
                } else if planned[index].underline != nil {
                    obstacles += planned[index].geometry
                }
            }
            let center = MarkChips.place(preferred: spot, obstacles: obstacles, visible: planned[index].display.visible)
            planned[index].chipCenter = center
            placedChips.append(MarkChips.rect(center: center).insetBy(dx: -2, dy: -2))
        }
    }

    /// attached: each visible mark's note beside it (AttachedNotes), in
    /// answer order, clear of text, every mark's geometry, the notes placed
    /// so far and the companion. An arrow's note keeps its spot past the
    /// tail when that is clean. A mark whose note finds no spot keeps a
    /// numbered chip and its note goes to the legend; marks without words
    /// get neither. Neighbouring photos / cards (`visualObstacles`) are
    /// avoided when a spot clear of them exists.
    static func placeAttachedNotes(_ planned: inout [Planned], visibleIndexes: [Int], leafTexts: [CGRect], companionRect: CGRect?,
                                   visualObstacles: [CGRect] = []) {
        let baseObstacles = (companionRect.map { [$0] } ?? []) + leafTexts
        var placedNotes: [CGRect] = []
        var fallbackIndexes: Set<Int> = []
        for index in planned.indices where !visibleIndexes.contains(index) { planned[index].labelRect = nil }
        for index in visibleIndexes {
            let plan = planned[index]
            guard let size = plan.labelSize else {
                planned[index].labelRect = nil
                continue
            }
            var otherGeometry: [CGRect] = []
            for otherIndex in visibleIndexes where otherIndex != index { otherGeometry += planned[otherIndex].geometry }
            let obstacles = baseObstacles + otherGeometry + placedNotes
            let visible = plan.display.visible.insetBy(dx: AttachedNotes.screenMargin, dy: AttachedNotes.screenMargin)
            var noteRect: CGRect?
            if let arrow = plan.arrow {
                if let labelRect = arrow.labelRect, visible.contains(labelRect), !labelRect.intersects(MarkLayout.padded(plan.input.rectCG)),
                   !obstacles.contains(where: { $0.intersects(labelRect) }) {
                    noteRect = labelRect
                }
            } else {
                let anchor: CGRect
                if let outline = plan.outline, plan.input.style != .spot {
                    anchor = outline.rect.insetBy(dx: -MarkPalette.fineHaloWidth / 2, dy: -MarkPalette.fineHaloWidth / 2)
                } else {
                    anchor = plan.attachRect
                }
                // First keep off neighbouring photos / cards too (not the
                // mark's own element or anything holding it), then only the
                // hard obstacles.
                let softObstacles = visualObstacles.filter { !$0.intersects(plan.input.rectCG) && !$0.intersects(anchor) }
                noteRect = AttachedNotes.place(size: size, around: anchor, visible: plan.display.visible,
                                               obstacles: obstacles + plan.geometry + softObstacles)?.rect
                    ?? AttachedNotes.place(size: size, around: anchor, visible: plan.display.visible,
                                           obstacles: obstacles + plan.geometry)?.rect
            }
            if let noteRect {
                planned[index].labelRect = noteRect
                planned[index].isLabelAttached = true
                placedNotes.append(noteRect.insetBy(dx: -2, dy: -2))
            } else {
                planned[index].labelRect = nil
                planned[index].isNoteInLegend = plan.input.displayText != nil
                fallbackIndexes.insert(index)
            }
        }
        // Chips only for the fallbacks.
        for index in planned.indices where !fallbackIndexes.contains(index) { planned[index].chipNumber = nil }
        placeChips(&planned, visibleIndexes: visibleIndexes, leafTexts: leafTexts, companionRect: companionRect, extraObstacles: placedNotes)
    }

    /// The underline's drawn band (stroke plus halo).
    static func underlineRect(_ line: (start: CGPoint, end: CGPoint)) -> CGRect {
        let halfBand = MarkPalette.fineHaloWidth / 2
        return CGRect(x: line.start.x - halfBand, y: line.start.y - halfBand, width: line.end.x - line.start.x + 2 * halfBand, height: 2 * halfBand)
    }

    /// The arrow's shaft and head as a few small boxes (its bounding box
    /// would block a whole diagonal quadrant).
    static func arrowRects(_ arrow: ArrowSpec) -> [CGRect] {
        var rects: [CGRect] = []
        let sampleCount = 8
        for sampleIndex in 0...sampleCount {
            let t = CGFloat(sampleIndex) / CGFloat(sampleCount)
            let x = (1 - t) * (1 - t) * arrow.tail.x + 2 * (1 - t) * t * arrow.control.x + t * t * arrow.tip.x
            let y = (1 - t) * (1 - t) * arrow.tail.y + 2 * (1 - t) * t * arrow.control.y + t * t * arrow.tip.y
            rects.append(CGRect(x: x - 5, y: y - 5, width: 10, height: 10))
        }
        for point in [arrow.headLeft, arrow.headRight] { rects.append(CGRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8)) }
        return rects
    }
}
