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
//  for an outlined step with no label.
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

    public init(id: UUID, style: MarkStyleKind, rectCG: CGRect, displayText: String?, isTentative: Bool,
                isHidden: Bool = false, opacity: Double = 1, order: Int, windowFrameCG: CGRect? = nil, targetRole: MarkTargetRole = .unknown) {
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
        if let stepDiscCenter {
            let discRadius = MarkLayout.stepDiscDiameter / 2
            bounds = bounds.union(CGRect(x: stepDiscCenter.x - discRadius, y: stepDiscCenter.y - discRadius,
                                         width: MarkLayout.stepDiscDiameter, height: MarkLayout.stepDiscDiameter))
        }
        return bounds
    }

    public static func == (first: MarkDrawing, second: MarkDrawing) -> Bool {
        first.id == second.id && first.style == second.style && first.targetCG == second.targetCG && first.outline == second.outline
            && first.arrow == second.arrow && first.underline?.start == second.underline?.start && first.underline?.end == second.underline?.end
            && first.stepDiscCenter == second.stepDiscCenter && first.connectorFrom == second.connectorFrom
            && first.labelRect == second.labelRect && first.labelText == second.labelText && first.isTentative == second.isTentative
            && first.isHidden == second.isHidden && first.opacity == second.opacity && first.displayID == second.displayID
            && first.labelStepNumber == second.labelStepNumber && first.leader == second.leader && first.isDense == second.isDense
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
        var isDense = false
        /// What a leader points at.
        var attachRect: CGRect
        /// What this mark draws, as obstacles for every other label.
        var geometry: [CGRect] = []
    }

    /// `companionRect`: where the buddy is parked (an obstacle for labels).
    /// `textObstacles`: every text bound in the region (AX text / cell / row
    /// frames, OCR lines), CG; containers are seen through.
    public static func build(inputs: [MarkSceneInput], displays: [MarkSceneDisplay], companionRect: CGRect? = nil,
                             textObstacles: [CGRect] = []) -> [MarkDrawing] {
        let leafTexts = MarkDensity.leafTextBounds(textObstacles)
        var planned: [Planned] = []
        var previousStepDisc: CGPoint?
        var arrowObstacles: [CGRect] = (companionRect.map { [$0] } ?? []) + leafTexts

        // Pass 1: each mark's shape.
        for input in inputs.sorted(by: { $0.order < $1.order }) {
            guard let markDisplay = display(for: input.rectCG, in: displays) else { continue }
            let target = input.rectCG
            let displayTexts = leafTexts.filter { $0.intersects(markDisplay.bounds) }
            let analysis = MarkDensity.analyze(target: target, role: input.targetRole, leafTexts: displayTexts)
            var plan = Planned(input: input, display: markDisplay, attachRect: target)
            var stepNumber: Int?
            if case .step(let number) = input.style { stepNumber = number }

            switch input.style {
            case .circle, .box, .step:
                let tight = MarkLayout.tightOutline(target: target, display: markDisplay.bounds)
                if MarkDensity.form(for: analysis, tightOutline: tight) == .underline {
                    plan.isDense = analysis.isDense
                    let line = MarkDensity.underline(for: analysis, target: target, display: markDisplay.bounds)
                    plan.underline = line
                    plan.attachRect = (analysis.textSpan ?? target).union(underlineRect(line))
                } else {
                    plan.outline = tight
                    plan.attachRect = tight.rect
                    if stepNumber != nil && input.displayText == nil {
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
            case .spot:
                plan.outline = MarkShapeSpec(kind: .roundedBox, rect: MarkLayout.padded(target).intersection(markDisplay.bounds), cornerRadius: 8)
                plan.attachRect = MarkLayout.padded(target)
            case .arrow:
                let labelSize = input.displayText.map(LabelPlacer.size(for:))
                plan.arrow = MarkLayout.arrow(target: target, visible: markDisplay.visible, labelSize: labelSize, obstacles: arrowObstacles)
                plan.labelRect = plan.arrow?.labelRect
            }
            if input.displayText != nil || plan.labelStepNumber != nil {
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
                if let labelRect = plan.labelRect { arrowObstacles.append(labelRect) }
            }
            planned.append(plan)
        }

        // Pass 2: labels, against text, every mark's geometry, placed labels and the companion.
        let visibleIndexes = planned.indices.filter { !planned[$0].input.isHidden }
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

        return planned.map { plan in
            MarkDrawing(
                id: plan.input.id, style: plan.input.style, targetCG: plan.input.rectCG, displayID: plan.display.displayID,
                displayBounds: plan.display.bounds, outline: plan.outline, arrow: plan.arrow, underline: plan.underline,
                stepDiscCenter: plan.stepDiscCenter, connectorFrom: plan.connectorFrom, labelRect: plan.labelRect,
                labelText: plan.input.displayText, labelStepNumber: plan.labelRect == nil ? nil : plan.labelStepNumber,
                leader: plan.leader, isDense: plan.isDense, isTentative: plan.input.isTentative, isHidden: plan.input.isHidden,
                opacity: plan.input.opacity, order: plan.input.order
            )
        }
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
