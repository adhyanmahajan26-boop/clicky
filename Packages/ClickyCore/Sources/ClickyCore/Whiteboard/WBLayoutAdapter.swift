//
//  WBLayoutAdapter.swift
//  ClickyCore
//
//  Maps a parsed board (WBBoard) onto the layout's own input
//  (WBLayoutInput), and remembers which board element every layout node and
//  edge came from, so the view can draw the right shape and the narrator's
//  reveals (keyed by board element id) find their nodes:
//   - boxes: rect/round/pill/note/cyl/diamond → a layout box (the view draws
//     the real shape inside the placed rect; diamonds and icons get room),
//     circle → ellipse; a box no arrow touches flows like other content
//     (sized as a box) so it doesn't widen the layered diagram
//   - arrows → edges; flows expand to their inner boxes and arrows
//     ("<flow>.<node>" ids), owned by the flow element
//   - text (near/pos), list (title as the first line), code, math, chart,
//     table (header row first), callout (near its target, on the right),
//     divider (a thin text-kind strip)
//  The camera gets layout ids: an arrow stands for its two ends, a flow for
//  its boxes, a section focus for the section.
//

import CoreGraphics
import Foundation

public struct WBAdaptedBoard: Sendable {
    public let board: WBBoard
    public let input: WBLayoutInput
    /// Layout node id → the element drawn there (a flow's inner box for flow nodes).
    public let nodeElements: [String: WBElement]
    /// Layout edge index → its arrow element (a flow's inner arrow for flow edges).
    public let edgeElements: [WBElement]
    /// Layout node id / "edge#<index>" → the board element that reveals it.
    public let ownerIdentifiers: [String: String]
    /// Board element id → its layout node ids, in order (camera, POINT).
    public let layoutIdentifiersByElement: [String: [String]]

    /// The board element that reveals layout edge `edgeIndex`.
    public func owner(ofEdge edgeIndex: Int) -> String? { ownerIdentifiers["edge#\(edgeIndex)"] }

    /// Layout ids a board element (or section) stands for, for the camera.
    public func cameraIdentifiers(for identifier: String) -> [String] {
        if let layoutIdentifiers = layoutIdentifiersByElement[identifier] { return layoutIdentifiers }
        if board.section(withIdentifier: identifier) != nil { return [identifier] }
        return []
    }

    public var cameraSteps: [WBCameraStep] {
        board.steps.map { step in
            var focusIdentifiers: [String] = []
            switch step.focus {
            case .element(let elementIdentifier): focusIdentifiers = cameraIdentifiers(for: elementIdentifier)
            case .section(let sectionIdentifier): focusIdentifiers = [sectionIdentifier]
            case .board, nil: break
            }
            return WBCameraStep(show: step.shownIdentifiers.flatMap(cameraIdentifiers(for:)),
                                highlight: step.highlightedIdentifiers.flatMap(cameraIdentifiers(for:)),
                                focus: focusIdentifiers)
        }
    }

    /// The board rect of an element (union of its nodes) in `layout`, e.g. for a board POINT.
    public func boardRect(of elementIdentifier: String, in layout: WBBoardLayout) -> CGRect? {
        let rect = cameraIdentifiers(for: elementIdentifier).compactMap(layout.rect(forID:)).reduce(CGRect.null) { $0.union($1) }
        return rect.isNull ? nil : rect
    }
}

public enum WBLayoutAdapter {
    /// Room for a box's SF Symbol, left of its text.
    public static let iconWidth: CGFloat = 26
    /// A diamond's text rect is its inscribed rect: the box grows by this.
    public static let diamondGrowth: CGFloat = 1.45
    public static let calloutIconWidth: CGFloat = 24
    public static let pillEndAllowance: CGFloat = 18
    public static let listMarkerAllowance: CGFloat = 16
    public static let dividerSize = CGSize(width: 320, height: 18)

    public static func fontSize(for textSize: WBTextSize) -> CGFloat {
        switch textSize {
        case .small: return 15
        case .medium: return 19
        case .large: return 24
        case .title: return 30
        }
    }

    /// Board order is agenda, the question sections as asked, recap: an
    /// "agenda" section the model put later moves first, a "recap" last.
    public static func agendaFirstRecapLast(_ board: WBBoard) -> WBBoard {
        func isNamed(_ section: WBSection, _ name: String) -> Bool {
            section.id.lowercased() == name || section.title.lowercased() == name
        }
        let agendaSections = board.sections.filter { isNamed($0, "agenda") }
        let recapSections = board.sections.filter { isNamed($0, "recap") && !isNamed($0, "agenda") }
        let otherSections = board.sections.filter { !isNamed($0, "agenda") && !isNamed($0, "recap") }
        var orderedBoard = board
        orderedBoard.sections = agendaSections + otherSections + recapSections
        return orderedBoard
    }

    public static func adapt(_ board: WBBoard, viewportSize: CGSize) -> WBAdaptedBoard {
        var nodes: [WBLayoutNode] = []
        var edges: [WBLayoutEdge] = []
        var nodeElements: [String: WBElement] = [:]
        var edgeElements: [WBElement] = []
        var ownerIdentifiers: [String: String] = [:]
        var layoutIdentifiersByElement: [String: [String]] = [:]

        // Arrow / callout / near ids naming a flow mean its first box.
        var firstNodeOfFlow: [String: String] = [:]
        for element in board.elements {
            if case .flow(let flow) = element.payload, let firstBox = flow.elements.first(where: { $0.kind == .box }) {
                firstNodeOfFlow[element.id] = firstBox.id
            }
        }
        func resolvedNodeIdentifier(_ identifier: String) -> String { firstNodeOfFlow[identifier] ?? identifier }

        func addNode(for element: WBElement, owner ownerIdentifier: String, section: String) {
            guard let node = layoutNode(for: element, section: section, resolve: resolvedNodeIdentifier) else { return }
            guard nodeElements[node.id] == nil else { return }
            nodes.append(node)
            nodeElements[node.id] = element
            ownerIdentifiers[node.id] = ownerIdentifier
            layoutIdentifiersByElement[ownerIdentifier, default: []].append(node.id)
        }

        func addEdge(for element: WBElement, arrow: WBArrow, owner ownerIdentifier: String) {
            let fromIdentifier = resolvedNodeIdentifier(arrow.fromIdentifier)
            let toIdentifier = resolvedNodeIdentifier(arrow.toIdentifier)
            ownerIdentifiers["edge#\(edges.count)"] = ownerIdentifier
            edges.append(WBLayoutEdge(from: fromIdentifier, to: toIdentifier, label: arrow.text))
            edgeElements.append(element)
            // The camera frames a stand-alone arrow by its two ends.
            if ownerIdentifier == element.id { layoutIdentifiersByElement[ownerIdentifier] = [fromIdentifier, toIdentifier] }
        }

        for element in board.elements {
            switch element.payload {
            case .arrow(let arrow):
                addEdge(for: element, arrow: arrow, owner: element.id)
            case .flow(let flow):
                for innerElement in flow.elements {
                    if case .arrow(let innerArrow) = innerElement.payload {
                        addEdge(for: innerElement, arrow: innerArrow, owner: element.id)
                    } else {
                        addNode(for: innerElement, owner: element.id, section: element.sectionIdentifier)
                    }
                }
            default:
                addNode(for: element, owner: element.id, section: element.sectionIdentifier)
            }
        }

        // A box no arrow touches flows with the other content (in wrapping
        // rows) instead of widening the section's layered diagram.
        let connectedIdentifiers = Set(edges.flatMap { [$0.from, $0.to] })
        for nodeIndex in nodes.indices where nodes[nodeIndex].kind.isAlwaysGraphNode && !connectedIdentifiers.contains(nodes[nodeIndex].id) {
            nodes[nodeIndex].kind = .callout
        }

        let input = WBLayoutInput(
            nodes: nodes,
            edges: edges,
            sections: board.sections.map { WBLayoutSection(id: $0.id, title: $0.title) },
            direction: board.direction == .leftToRight ? .leftToRight : .topToBottom,
            viewportSize: viewportSize
        )
        return WBAdaptedBoard(board: board, input: input, nodeElements: nodeElements, edgeElements: edgeElements,
                              ownerIdentifiers: ownerIdentifiers, layoutIdentifiersByElement: layoutIdentifiersByElement)
    }

    static func layoutNode(for element: WBElement, section: String, resolve: (String) -> String) -> WBLayoutNode? {
        switch element.payload {
        case .box(let box):
            var node = WBLayoutNode(id: element.id, kind: box.shape == .circle ? .ellipse : .box, section: section, text: box.text)
            var size = WBMeasure.size(of: node)
            if box.icon != nil { size.width += iconWidth }
            if box.shape == .diamond { size = CGSize(width: ceil(size.width * diamondGrowth), height: ceil(size.height * diamondGrowth)) }
            if box.shape == .cyl { size.height += 14 }
            // A pill's round ends eat into the text width.
            if box.shape == .pill { size.width += pillEndAllowance }
            node.sizeHint = size
            return node
        case .text(let text):
            let near = text.nearIdentifier.map { WBLayoutNear(targetID: resolve($0), side: layoutSide(text.position ?? .right)) }
            return WBLayoutNode(id: element.id, kind: .text, section: section, text: text.text, fontSize: fontSize(for: text.size), near: near)
        case .list(let list):
            let lines = (list.title.map { [$0] } ?? []) + list.items
            var node = WBLayoutNode(id: element.id, kind: .list, section: section, text: lines.joined(separator: "\n"), items: lines)
            // Room for "12.  " markers and SwiftUI's slightly wider text.
            var size = WBMeasure.size(of: node)
            size.width += listMarkerAllowance
            node.sizeHint = size
            return node
        case .code(let code):
            return WBLayoutNode(id: element.id, kind: .code, section: section, text: code.displayText)
        case .math(let math):
            return WBLayoutNode(id: element.id, kind: .math, section: section, text: math.tex)
        case .chart(let chart):
            return WBLayoutNode(id: element.id, kind: .chart, section: section, text: chart.title ?? "")
        case .table(let table):
            return WBLayoutNode(id: element.id, kind: .table, section: section, rows: [table.columns] + table.rows)
        case .callout(let callout):
            var node = WBLayoutNode(id: element.id, kind: .callout, section: section, text: callout.text,
                                    near: callout.targetIdentifier.map { WBLayoutNear(targetID: resolve($0), side: .right) })
            var size = WBMeasure.size(of: node)
            size.width += calloutIconWidth
            node.sizeHint = size
            return node
        case .divider:
            return WBLayoutNode(id: element.id, kind: .text, section: section, sizeHint: dividerSize)
        case .arrow, .flow:
            return nil
        }
    }

    static func layoutSide(_ position: WBRelativePosition) -> WBLayoutSide {
        switch position {
        case .top: return .top
        case .bottom: return .bottom
        case .left: return .left
        case .right: return .right
        }
    }
}

extension WBCode {
    /// The code as drawn: a model that double-escaped its newlines (a
    /// literal "\\n" and no real line break) still gets its lines.
    public var displayText: String {
        guard !text.contains("\n"), text.contains("\\n") else { return text }
        return text.replacingOccurrences(of: "\\n", with: "\n").replacingOccurrences(of: "\\t", with: "    ")
    }
}
