//
//  MarkScene.swift
//  ClickyCore
//
//  Turns the live marks (target rect + style + text) into everything the
//  overlay draws, in CG global points: the outline, arrow, underline, spot
//  cut-out, step discs and connectors, and where each label goes. Marks are
//  laid out in order, each one avoiding the shapes and labels before it and
//  the companion.
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

    public init(id: UUID, style: MarkStyleKind, rectCG: CGRect, displayText: String?, isTentative: Bool,
                isHidden: Bool = false, opacity: Double = 1, order: Int) {
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
    }
}

public enum MarkSceneBuilder {
    public static func display(for rectCG: CGRect, in displays: [MarkSceneDisplay]) -> MarkSceneDisplay? {
        if let containing = displays.first(where: { $0.bounds.contains(rectCG.center) }) { return containing }
        return displays.min { first, second in
            first.bounds.edgeDistance(to: rectCG.center) < second.bounds.edgeDistance(to: rectCG.center)
        }
    }

    /// `companionRect`: where the buddy is parked (an obstacle for labels).
    public static func build(inputs: [MarkSceneInput], displays: [MarkSceneDisplay], companionRect: CGRect? = nil) -> [MarkDrawing] {
        var obstacles: [CGRect] = companionRect.map { [$0] } ?? []
        var drawings: [MarkDrawing] = []
        var previousStepDisc: CGPoint?

        for input in inputs.sorted(by: { $0.order < $1.order }) {
            guard let markDisplay = display(for: input.rectCG, in: displays) else { continue }
            let target = input.rectCG
            let paddedTarget = MarkLayout.padded(target)
            let labelSize = input.displayText.map(LabelPlacer.size(for:))
            var outline: MarkShapeSpec?
            var arrow: ArrowSpec?
            var underline: (start: CGPoint, end: CGPoint)?
            var stepDiscCenter: CGPoint?
            var connectorFrom: CGPoint?
            var labelRect: CGRect?
            var labelAnchorRect = paddedTarget

            switch input.style {
            case .circle:
                outline = MarkLayout.ring(target: target, display: markDisplay.bounds)
                labelAnchorRect = outline!.rect
            case .box:
                outline = MarkLayout.box(target: target, display: markDisplay.bounds)
                labelAnchorRect = outline!.rect
            case .spot:
                outline = MarkShapeSpec(kind: .roundedBox, rect: paddedTarget.intersection(markDisplay.bounds), cornerRadius: 8)
            case .underline:
                underline = MarkLayout.underline(target: target, display: markDisplay.bounds)
                labelAnchorRect = target.insetBy(dx: 0, dy: -3)
            case .step:
                outline = MarkLayout.ring(target: target, display: markDisplay.bounds)
                labelAnchorRect = outline!.rect
                stepDiscCenter = MarkLayout.stepDiscCenter(ring: outline!, visible: markDisplay.visible)
                connectorFrom = previousStepDisc
                previousStepDisc = stepDiscCenter
            case .arrow:
                arrow = MarkLayout.arrow(target: target, visible: markDisplay.visible, labelSize: labelSize, obstacles: obstacles)
                labelRect = arrow?.labelRect
            }

            var markObstacles: [CGRect] = [paddedTarget]
            if let outline, input.style != .spot { markObstacles.append(outline.rect) }
            if let stepDiscCenter {
                let discRadius = MarkLayout.stepDiscDiameter / 2
                markObstacles.append(CGRect(x: stepDiscCenter.x - discRadius, y: stepDiscCenter.y - discRadius,
                                            width: MarkLayout.stepDiscDiameter, height: MarkLayout.stepDiscDiameter))
            }
            if let labelSize, labelRect == nil {
                labelRect = LabelPlacer.place(size: labelSize, around: labelAnchorRect, visible: markDisplay.visible,
                                              obstacles: obstacles + markObstacles).rect
            }
            if !input.isHidden {
                obstacles += markObstacles
                if let labelRect { obstacles.append(labelRect) }
            }

            drawings.append(MarkDrawing(
                id: input.id, style: input.style, targetCG: target, displayID: markDisplay.displayID, displayBounds: markDisplay.bounds,
                outline: outline, arrow: arrow, underline: underline, stepDiscCenter: stepDiscCenter, connectorFrom: connectorFrom,
                labelRect: labelRect, labelText: input.displayText, isTentative: input.isTentative, isHidden: input.isHidden,
                opacity: input.opacity, order: input.order
            ))
        }
        return drawings
    }
}
