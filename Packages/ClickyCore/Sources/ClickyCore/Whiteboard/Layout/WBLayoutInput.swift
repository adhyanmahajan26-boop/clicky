//
//  WBLayoutInput.swift
//  ClickyCore
//
//  The whiteboard layout's own input and output types. The board model and
//  its parser live elsewhere; an adapter maps them onto these, so layout
//  never depends on how a board was written down. Coordinates are board
//  points, y down (origin top-left), like SwiftUI.
//
//  Input order is meaning: nodes, edges and sections are laid out in the
//  order they arrived, and every tie anywhere is broken by that order.
//

import CoreGraphics
import Foundation

public enum WBLayoutDirection: String, Sendable, Equatable {
    case topToBottom = "TB"
    case leftToRight = "LR"
}

public enum WBLayoutNodeKind: String, Sendable, Equatable, CaseIterable {
    case box, ellipse, text, callout, list, code, math, chart, table

    /// Boxes and ellipses are diagram nodes even before an edge reaches them;
    /// everything else joins the graph only once an edge names it.
    public var isAlwaysGraphNode: Bool { self == .box || self == .ellipse }

    public var shape: WBNodeShape { self == .ellipse ? .ellipse : .rectangle }
}

/// The outline arrows are clipped against (exactly, on the node's rect).
public enum WBNodeShape: String, Sendable, Equatable {
    case rectangle, ellipse
}

public enum WBLayoutSide: String, Sendable, Equatable, CaseIterable {
    case top, bottom, left, right
}

/// "Put me next to `targetID`, on `side`" (text and callouts only).
public struct WBLayoutNear: Equatable, Sendable {
    public var targetID: String
    public var side: WBLayoutSide

    public init(targetID: String, side: WBLayoutSide) {
        self.targetID = targetID
        self.side = side
    }
}

public struct WBLayoutNode: Equatable, Sendable {
    public var id: String
    public var kind: WBLayoutNodeKind
    /// Section id; nil or empty → the first section.
    public var section: String?
    /// Label / body text (code source for `.code`, TeX for `.math`).
    public var text: String
    /// List items (`.list`); empty → `text` split into lines.
    public var items: [String]
    /// Table cells, row-major (`.table`); empty → `text` lines split on "|".
    public var rows: [[String]]
    /// Overrides measurement when set (already-rendered content, tests).
    public var sizeHint: CGSize?
    /// Requested font size; never below WBMeasure.minimumFontSize.
    public var fontSize: CGFloat?
    public var near: WBLayoutNear?

    public init(id: String, kind: WBLayoutNodeKind = .box, section: String? = nil, text: String = "",
                items: [String] = [], rows: [[String]] = [], sizeHint: CGSize? = nil, fontSize: CGFloat? = nil,
                near: WBLayoutNear? = nil) {
        self.id = id
        self.kind = kind
        self.section = section
        self.text = text
        self.items = items
        self.rows = rows
        self.sizeHint = sizeHint
        self.fontSize = fontSize
        self.near = near
    }
}

public struct WBLayoutEdge: Equatable, Sendable {
    public var from: String
    public var to: String
    public var label: String?

    public init(from: String, to: String, label: String? = nil) {
        self.from = from
        self.to = to
        self.label = label
    }
}

public struct WBLayoutSection: Equatable, Sendable {
    public var id: String
    public var title: String?

    public init(id: String, title: String? = nil) {
        self.id = id
        self.title = title
    }
}

public struct WBLayoutInput: Equatable, Sendable {
    public var nodes: [WBLayoutNode]
    public var edges: [WBLayoutEdge]
    public var sections: [WBLayoutSection]
    public var direction: WBLayoutDirection
    /// The board window's size; sections are cut from it.
    public var viewportSize: CGSize

    public init(nodes: [WBLayoutNode] = [], edges: [WBLayoutEdge] = [], sections: [WBLayoutSection] = [],
                direction: WBLayoutDirection = .topToBottom, viewportSize: CGSize = CGSize(width: 1280, height: 800)) {
        self.nodes = nodes
        self.edges = edges
        self.sections = sections
        self.direction = direction
        self.viewportSize = viewportSize
    }
}

// MARK: - Output

public enum WBPlacementRole: String, Sendable, Equatable {
    /// Part of its section's layered diagram.
    case graphNode
    /// Edgeless content flowing in arrival order.
    case flow
    /// Text / callout parked next to its `near` target.
    case near
}

public struct WBPlacedElement: Equatable, Sendable {
    public let id: String
    public let kind: WBLayoutNodeKind
    public let sectionID: String
    public let rect: CGRect
    public let shape: WBNodeShape
    public let role: WBPlacementRole
    /// < 1 when the diagram was shrunk to fit its section (never below 0.7);
    /// the view draws the content at this scale inside `rect`.
    public let contentScale: CGFloat
}

/// One cubic Bézier piece of an edge.
public struct WBCubicSegment: Equatable, Sendable {
    public let start: CGPoint
    public let control1: CGPoint
    public let control2: CGPoint
    public let end: CGPoint

    public init(start: CGPoint, control1: CGPoint, control2: CGPoint, end: CGPoint) {
        self.start = start
        self.control1 = control1
        self.control2 = control2
        self.end = end
    }

    public func point(at parameter: CGFloat) -> CGPoint {
        let inverse = 1 - parameter
        let weightStart = inverse * inverse * inverse
        let weightControl1 = 3 * inverse * inverse * parameter
        let weightControl2 = 3 * inverse * parameter * parameter
        let weightEnd = parameter * parameter * parameter
        return CGPoint(x: weightStart * start.x + weightControl1 * control1.x + weightControl2 * control2.x + weightEnd * end.x,
                       y: weightStart * start.y + weightControl1 * control1.y + weightControl2 * control2.y + weightEnd * end.y)
    }

    func applying(scale: CGFloat, offset: CGVector) -> WBCubicSegment {
        func map(_ point: CGPoint) -> CGPoint { CGPoint(x: point.x * scale + offset.dx, y: point.y * scale + offset.dy) }
        return WBCubicSegment(start: map(start), control1: map(control1), control2: map(control2), end: map(end))
    }
}

public struct WBPlacedEdge: Equatable, Sendable {
    /// Index into WBLayoutInput.edges.
    public let edgeIndex: Int
    public let from: String
    public let to: String
    public let label: String?
    /// Knots of the Catmull-Rom spline, from `from`'s border to `to`'s
    /// border (the arrow tip is the last point).
    public let points: [CGPoint]
    public let segments: [WBCubicSegment]
    public let labelRect: CGRect?

    public var start: CGPoint { points.first ?? .zero }
    public var end: CGPoint { points.last ?? .zero }

    public var path: CGPath {
        let mutablePath = CGMutablePath()
        guard let firstSegment = segments.first else { return mutablePath }
        mutablePath.move(to: firstSegment.start)
        for segment in segments {
            mutablePath.addCurve(to: segment.end, control1: segment.control1, control2: segment.control2)
        }
        return mutablePath
    }

    func applying(scale: CGFloat, offset: CGVector) -> WBPlacedEdge {
        WBPlacedEdge(edgeIndex: edgeIndex, from: from, to: to, label: label,
                     points: points.map { CGPoint(x: $0.x * scale + offset.dx, y: $0.y * scale + offset.dy) },
                     segments: segments.map { $0.applying(scale: scale, offset: offset) },
                     labelRect: labelRect.map { WBLayoutGeometry.transform($0, scale: scale, offset: offset) })
    }
}

public struct WBPlacedSection: Equatable, Sendable {
    public let id: String
    public let title: String?
    public let rect: CGRect
    public let titleRect: CGRect?
}

public struct WBBoardLayout: Equatable, Sendable {
    /// One per distinct node id, in input order.
    public let elements: [WBPlacedElement]
    /// Drawable edges in input order (self loops and edges to unknown ids
    /// are left out).
    public let edges: [WBPlacedEdge]
    public let sections: [WBPlacedSection]
    /// Everything, plus the board margin; origin is always (0, 0).
    public let bounds: CGRect
    /// Barycenter crossings summed over the sections' diagrams.
    public let crossingCount: Int

    public func element(id: String) -> WBPlacedElement? { elements.first { $0.id == id } }

    /// Element or section rect, for the camera.
    public func rect(forID id: String) -> CGRect? {
        if let placedElement = element(id: id) { return placedElement.rect }
        return sections.first { $0.id == id }?.rect
    }

    /// A stable text form (2 decimals) for goldens and cross-process checks.
    public func serialized() -> String {
        func number(_ value: CGFloat) -> String {
            let formatted = String(format: "%.2f", Double(value))
            return formatted == "-0.00" ? "0.00" : formatted
        }
        func rectText(_ rect: CGRect) -> String {
            "\(number(rect.minX)),\(number(rect.minY)),\(number(rect.width)),\(number(rect.height))"
        }
        var lines: [String] = ["board \(rectText(bounds)) crossings \(crossingCount)"]
        for section in sections {
            lines.append("section \(section.id) \(rectText(section.rect))")
        }
        for placedElement in elements {
            lines.append("node \(placedElement.id) \(placedElement.kind.rawValue) \(placedElement.role.rawValue) \(placedElement.sectionID) \(rectText(placedElement.rect)) x\(number(placedElement.contentScale))")
        }
        for placedEdge in edges {
            let pointsText = placedEdge.points.map { "\(number($0.x)),\(number($0.y))" }.joined(separator: " ")
            let labelText = placedEdge.labelRect.map { " label \(rectText($0))" } ?? ""
            lines.append("edge \(placedEdge.edgeIndex) \(placedEdge.from)>\(placedEdge.to) \(pointsText)\(labelText)")
        }
        return lines.joined(separator: "\n")
    }
}
