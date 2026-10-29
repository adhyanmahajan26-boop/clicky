//
//  WBBoardLayoutEngine.swift
//  ClickyCore
//
//  The whole board, from WBLayoutInput to WBBoardLayout:
//   - roles: boxes / ellipses and anything an edge touches are diagram
//     nodes; text / callouts with a resolvable `near` sit beside their
//     target (in the target's section); everything else flows
//   - per section: its diagram (WBGraphLayout); too wide → LR becomes TB,
//     then it is scaled down (not below 0.7), then the section just grows
//     and the camera copes. Blocks stack in first-appearance order 24 pt
//     apart: the diagram is one block (it appears with its first node),
//     consecutive flow elements share wrapping rows. `near` elements last.
//   - sections cut from the viewport (WBSectionLayout), grown to fit
//   - edges between sections: straight, clipped, label nudged
//  WBStreamingLayout keeps a cache between calls so a re-layout while the
//  board streams in is fast and stable: an unchanged diagram is reused
//  verbatim, a changed one starts from the previous layer orders.
//

import CoreGraphics
import Foundation

final class WBLayoutCache {
    struct GraphEntry {
        let signature: String
        let result: WBGraphLayout.Result
    }

    /// By section id (lookups only).
    var graphEntries: [String: GraphEntry] = [:]
    var orderKeys: [String: [String: Int]] = [:]
}

public enum WBBoardLayoutEngine {
    public static let minimumDiagramScale: CGFloat = 0.7

    public static func layout(_ input: WBLayoutInput) -> WBBoardLayout {
        layout(input, cache: nil)
    }

    struct ResolvedEdge {
        let edgeIndex: Int
        let from: Int
        let to: Int
        let label: String?
    }

    struct SectionContent {
        /// (global node index, section-local rect, content scale)
        var placements: [(node: Int, rect: CGRect, scale: CGFloat)]
        var edges: [WBPlacedEdge]
        var size: CGSize
        var crossings: Int
    }

    static func layout(_ input: WBLayoutInput, cache: WBLayoutCache?) -> WBBoardLayout {
        // Distinct nodes, first occurrence wins.
        var nodes: [WBLayoutNode] = []
        var nodeIndexByID: [String: Int] = [:]
        for node in input.nodes where nodeIndexByID[node.id] == nil {
            nodeIndexByID[node.id] = nodes.count
            nodes.append(node)
        }

        // Drawable edges.
        var resolvedEdges: [ResolvedEdge] = []
        var nodeHasEdge = [Bool](repeating: false, count: nodes.count)
        for (edgeIndex, edge) in input.edges.enumerated() {
            guard let fromIndex = nodeIndexByID[edge.from], let toIndex = nodeIndexByID[edge.to], fromIndex != toIndex else { continue }
            let label = (edge.label?.isEmpty ?? true) ? nil : edge.label
            resolvedEdges.append(ResolvedEdge(edgeIndex: edgeIndex, from: fromIndex, to: toIndex, label: label))
            nodeHasEdge[fromIndex] = true
            nodeHasEdge[toIndex] = true
        }

        // Roles.
        var roles: [WBPlacementRole] = nodes.indices.map { nodeHasEdge[$0] || nodes[$0].kind.isAlwaysGraphNode ? .graphNode : .flow }
        let nearTargetOfNode: [Int?] = nodes.indices.map { nodeIndex in
            let node = nodes[nodeIndex]
            guard roles[nodeIndex] == .flow, node.kind == .text || node.kind == .callout,
                  let near = node.near, let targetIndex = nodeIndexByID[near.targetID], targetIndex != nodeIndex else { return nil }
            return targetIndex
        }
        for nodeIndex in nodes.indices {
            // A near element's target must itself be placed normally.
            if let targetIndex = nearTargetOfNode[nodeIndex], nearTargetOfNode[targetIndex] == nil { roles[nodeIndex] = .near }
        }

        // Sections: declared ones, then any named only by nodes.
        var sectionIDs: [String] = []
        var sectionTitles: [String?] = []
        var sectionIndexByID: [String: Int] = [:]
        for section in input.sections where sectionIndexByID[section.id] == nil {
            sectionIndexByID[section.id] = sectionIDs.count
            sectionIDs.append(section.id)
            sectionTitles.append(section.title)
        }
        let defaultSectionID = sectionIDs.first ?? ""
        var sectionIDOfNode: [String] = nodes.map { node in
            if let section = node.section, !section.isEmpty { return section }
            return defaultSectionID
        }
        for nodeIndex in nodes.indices where roles[nodeIndex] == .near {
            if let targetIndex = nearTargetOfNode[nodeIndex] { sectionIDOfNode[nodeIndex] = sectionIDOfNode[targetIndex] }
        }
        for nodeIndex in nodes.indices where sectionIndexByID[sectionIDOfNode[nodeIndex]] == nil {
            sectionIndexByID[sectionIDOfNode[nodeIndex]] = sectionIDs.count
            sectionIDs.append(sectionIDOfNode[nodeIndex])
            sectionTitles.append(nil)
        }
        if sectionIDs.isEmpty {
            sectionIDs = [defaultSectionID]
            sectionTitles = [nil]
        }
        let sectionIndexOfNode = nodes.indices.map { sectionIndexByID[sectionIDOfNode[$0]] ?? 0 }
        var membersOfSection = [[Int]](repeating: [], count: sectionIDs.count)
        for nodeIndex in nodes.indices { membersOfSection[sectionIndexOfNode[nodeIndex]].append(nodeIndex) }
        var intraEdgesOfSection = [[ResolvedEdge]](repeating: [], count: sectionIDs.count)
        var crossSectionEdges: [ResolvedEdge] = []
        for edge in resolvedEdges {
            if sectionIndexOfNode[edge.from] == sectionIndexOfNode[edge.to] {
                intraEdgesOfSection[sectionIndexOfNode[edge.from]].append(edge)
            } else {
                crossSectionEdges.append(edge)
            }
        }

        let grid = WBSectionLayout.grid(sectionCount: sectionIDs.count, viewportSize: input.viewportSize)
        let nodeSizes = nodes.map(WBMeasure.size(of:))

        let contents: [SectionContent] = sectionIDs.indices.map { sectionIndex in
            sectionContent(sectionID: sectionIDs[sectionIndex], members: membersOfSection[sectionIndex], nodes: nodes, roles: roles,
                           nearTargetOfNode: nearTargetOfNode, nodeSizes: nodeSizes, intraEdges: intraEdgesOfSection[sectionIndex],
                           direction: input.direction, contentWidth: grid.contentWidth, cache: cache)
        }
        let titleBlockHeights = sectionTitles.map(WBSectionLayout.titleBlockHeight)
        let neededSizes: [CGSize] = contents.indices.map { sectionIndex in
            CGSize(width: contents[sectionIndex].size.width + 2 * WBSectionLayout.sectionPadding,
                   height: contents[sectionIndex].size.height + 2 * WBSectionLayout.sectionPadding + titleBlockHeights[sectionIndex])
        }
        let sectionRects = WBSectionLayout.sectionRects(neededSizes: neededSizes, grid: grid)

        // Into board points.
        var placedElementOfNode = [WBPlacedElement?](repeating: nil, count: nodes.count)
        var placedEdges: [WBPlacedEdge] = []
        var placedSections: [WBPlacedSection] = []
        for sectionIndex in sectionIDs.indices {
            let sectionRect = sectionRects[sectionIndex]
            let contentOrigin = CGVector(dx: sectionRect.minX + WBSectionLayout.sectionPadding,
                                         dy: sectionRect.minY + WBSectionLayout.sectionPadding + titleBlockHeights[sectionIndex])
            for placement in contents[sectionIndex].placements {
                let node = nodes[placement.node]
                placedElementOfNode[placement.node] = WBPlacedElement(
                    id: node.id, kind: node.kind, sectionID: sectionIDs[sectionIndex],
                    rect: placement.rect.offsetBy(dx: contentOrigin.dx, dy: contentOrigin.dy),
                    shape: node.kind.shape, role: roles[placement.node], contentScale: placement.scale)
            }
            placedEdges += contents[sectionIndex].edges.map { $0.applying(scale: 1, offset: contentOrigin) }
            let measuredTitle = WBSectionLayout.titleSize(sectionTitles[sectionIndex])
            let titleRect = measuredTitle.height > 0
                ? CGRect(x: sectionRect.minX + WBSectionLayout.sectionPadding, y: sectionRect.minY + WBSectionLayout.sectionPadding,
                         width: measuredTitle.width, height: measuredTitle.height)
                : nil
            placedSections.append(WBPlacedSection(id: sectionIDs[sectionIndex], title: sectionTitles[sectionIndex], rect: sectionRect, titleRect: titleRect))
        }
        let placedElements = placedElementOfNode.compactMap { $0 }

        // Edges between sections: one straight piece, clipped at both ends.
        var labelObstacles = placedElements.map(\.rect) + placedEdges.compactMap(\.labelRect)
        for edge in crossSectionEdges {
            guard let fromElement = placedElementOfNode[edge.from], let toElement = placedElementOfNode[edge.to] else { continue }
            let fromCenter = CGPoint(x: fromElement.rect.midX, y: fromElement.rect.midY)
            let toCenter = CGPoint(x: toElement.rect.midX, y: toElement.rect.midY)
            let knots = [WBLayoutGeometry.borderPoint(of: fromElement.rect, shape: fromElement.shape, toward: toCenter),
                         WBLayoutGeometry.borderPoint(of: toElement.rect, shape: toElement.shape, toward: fromCenter)]
            let segments = WBLayoutGeometry.catmullRomSegments(through: knots)
            var labelRect: CGRect?
            if let label = edge.label, let anchor = WBLayoutGeometry.labelAnchor(of: segments) {
                let placedLabel = WBLayoutGeometry.placeLabel(size: WBMeasure.edgeLabelSize(label), at: anchor, obstacles: labelObstacles)
                labelObstacles.append(placedLabel)
                labelRect = placedLabel
            }
            placedEdges.append(WBPlacedEdge(edgeIndex: edge.edgeIndex, from: fromElement.id, to: toElement.id, label: edge.label,
                                            points: knots, segments: segments, labelRect: labelRect))
        }
        placedEdges.sort { $0.edgeIndex < $1.edgeIndex }

        var contentBounds = sectionRects.reduce(CGRect.null) { $0.union($1) }
        for placedEdge in placedEdges {
            contentBounds = contentBounds.union(WBLayoutGeometry.bounds(of: placedEdge.segments))
            if let labelRect = placedEdge.labelRect { contentBounds = contentBounds.union(labelRect) }
        }
        let boardBounds = CGRect(x: 0, y: 0, width: max(0, contentBounds.maxX) + WBSectionLayout.boardMargin,
                                 height: max(0, contentBounds.maxY) + WBSectionLayout.boardMargin)
        return WBBoardLayout(elements: placedElements, edges: placedEdges, sections: placedSections, bounds: boardBounds,
                             crossingCount: contents.reduce(0) { $0 + $1.crossings })
    }

    // MARK: One section

    static func diagramSignature(nodes: [WBGraphLayout.Node], edges: [WBGraphLayout.Edge], direction: WBLayoutDirection, contentWidth: CGFloat) -> String {
        var signature = "\(direction.rawValue)|\(contentWidth)|"
        for node in nodes { signature += "\(node.id)\u{1}\(node.size.width)x\(node.size.height)\u{1}\(node.shape.rawValue)\u{1}\(node.arrivalRank)\u{2}" }
        signature += "|"
        for edge in edges { signature += "\(edge.from)>\(edge.to)\u{1}\(edge.label ?? "")\u{1}\(edge.edgeIndex)\u{2}" }
        return signature
    }

    static func diagram(sectionID: String, nodes: [WBGraphLayout.Node], edges: [WBGraphLayout.Edge], direction: WBLayoutDirection,
                        contentWidth: CGFloat, cache: WBLayoutCache?) -> WBGraphLayout.Result {
        let signature = diagramSignature(nodes: nodes, edges: edges, direction: direction, contentWidth: contentWidth)
        if let cachedEntry = cache?.graphEntries[sectionID], cachedEntry.signature == signature { return cachedEntry.result }
        let previousOrderKeys = cache?.orderKeys[sectionID] ?? [:]
        var result = WBGraphLayout.layout(nodes: nodes, edges: edges, direction: direction, previousOrderKeys: previousOrderKeys)
        if result.size.width > contentWidth && direction == .leftToRight {
            result = WBGraphLayout.layout(nodes: nodes, edges: edges, direction: .topToBottom, previousOrderKeys: previousOrderKeys)
        }
        if result.size.width > contentWidth {
            result = result.scaled(by: max(minimumDiagramScale, contentWidth / result.size.width))
        }
        cache?.graphEntries[sectionID] = WBLayoutCache.GraphEntry(signature: signature, result: result)
        cache?.orderKeys[sectionID] = result.orderKeys
        return result
    }

    static func sectionContent(sectionID: String, members: [Int], nodes: [WBLayoutNode], roles: [WBPlacementRole], nearTargetOfNode: [Int?],
                               nodeSizes: [CGSize], intraEdges: [ResolvedEdge], direction: WBLayoutDirection, contentWidth: CGFloat,
                               cache: WBLayoutCache?) -> SectionContent {
        let graphMembers = members.filter { roles[$0] == .graphNode }
        var localIndexOfNode: [Int: Int] = [:]
        for (localIndex, nodeIndex) in graphMembers.enumerated() { localIndexOfNode[nodeIndex] = localIndex }
        let graphNodes = graphMembers.map { nodeIndex in
            WBGraphLayout.Node(id: nodes[nodeIndex].id, size: nodeSizes[nodeIndex], shape: nodes[nodeIndex].kind.shape, arrivalRank: nodeIndex)
        }
        let graphEdges: [WBGraphLayout.Edge] = intraEdges.compactMap { edge in
            guard let fromLocal = localIndexOfNode[edge.from], let toLocal = localIndexOfNode[edge.to] else { return nil }
            return WBGraphLayout.Edge(from: fromLocal, to: toLocal, label: edge.label,
                                      labelSize: edge.label.map(WBMeasure.edgeLabelSize) ?? .zero, edgeIndex: edge.edgeIndex)
        }
        let diagramResult = diagram(sectionID: sectionID, nodes: graphNodes, edges: graphEdges, direction: direction,
                                    contentWidth: contentWidth, cache: cache)

        // Blocks in first-appearance order.
        var rectOfNode: [Int: CGRect] = [:]
        var scaleOfNode: [Int: CGFloat] = [:]
        var diagramOrigin = CGVector.zero
        var cursorY: CGFloat = 0
        var rowX: CGFloat = 0
        var rowHeight: CGFloat = 0
        var rowIsOpen = false
        var diagramIsPlaced = false
        func closeRow() {
            guard rowIsOpen else { return }
            cursorY += rowHeight + WBSectionLayout.blockGap
            rowX = 0
            rowHeight = 0
            rowIsOpen = false
        }
        for nodeIndex in members where roles[nodeIndex] != .near {
            if roles[nodeIndex] == .graphNode {
                guard !diagramIsPlaced else { continue }
                closeRow()
                diagramOrigin = CGVector(dx: max(0, (contentWidth - diagramResult.size.width) / 2).rounded(), dy: cursorY)
                cursorY += diagramResult.size.height + WBSectionLayout.blockGap
                diagramIsPlaced = true
                continue
            }
            let elementSize = nodeSizes[nodeIndex]
            if rowIsOpen && rowX + elementSize.width > contentWidth { closeRow() }
            rectOfNode[nodeIndex] = CGRect(x: rowX, y: cursorY, width: elementSize.width, height: elementSize.height)
            scaleOfNode[nodeIndex] = 1
            rowX += elementSize.width + WBSectionLayout.blockGap
            rowHeight = max(rowHeight, elementSize.height)
            rowIsOpen = true
        }
        closeRow()
        for (localIndex, nodeIndex) in graphMembers.enumerated() {
            rectOfNode[nodeIndex] = diagramResult.nodeRects[localIndex].offsetBy(dx: diagramOrigin.dx, dy: diagramOrigin.dy)
            scaleOfNode[nodeIndex] = diagramResult.scale
        }
        var sectionEdges = diagramResult.edges.map { $0.applying(scale: 1, offset: diagramOrigin) }

        // `near` elements, beside their targets, clear of everything placed.
        var obstacles = members.compactMap { rectOfNode[$0] } + sectionEdges.compactMap(\.labelRect)
        for nodeIndex in members where roles[nodeIndex] == .near {
            guard let targetIndex = nearTargetOfNode[nodeIndex], let targetRect = rectOfNode[targetIndex], let near = nodes[nodeIndex].near else { continue }
            let placement = WBNearPlacer.place(size: nodeSizes[nodeIndex], near: targetRect, side: near.side, obstacles: obstacles)
            rectOfNode[nodeIndex] = placement.rect
            scaleOfNode[nodeIndex] = 1
            obstacles.append(placement.rect)
        }

        // Normalise so nothing sits left of / above the content origin.
        var bounds = CGRect(x: 0, y: 0, width: 0, height: 0)
        for nodeIndex in members { if let rect = rectOfNode[nodeIndex] { bounds = bounds.union(rect) } }
        for sectionEdge in sectionEdges {
            bounds = bounds.union(WBLayoutGeometry.bounds(of: sectionEdge.segments))
            if let labelRect = sectionEdge.labelRect { bounds = bounds.union(labelRect) }
        }
        let shift = CGVector(dx: -min(0, bounds.minX), dy: -min(0, bounds.minY))
        if shift.dx != 0 || shift.dy != 0 { sectionEdges = sectionEdges.map { $0.applying(scale: 1, offset: shift) } }
        let placements = members.compactMap { nodeIndex -> (node: Int, rect: CGRect, scale: CGFloat)? in
            guard let rect = rectOfNode[nodeIndex] else { return nil }
            return (nodeIndex, rect.offsetBy(dx: shift.dx, dy: shift.dy), scaleOfNode[nodeIndex] ?? 1)
        }
        return SectionContent(placements: placements, edges: sectionEdges,
                              size: CGSize(width: bounds.maxX + shift.dx, height: bounds.maxY + shift.dy), crossings: diagramResult.crossings)
    }
}

/// Re-layout while the board streams in: call `update` with the whole
/// current input each time. Unchanged diagrams are reused verbatim; changed
/// ones start from the previous layer orders, so placed nodes only move
/// when the layout has to change.
public final class WBStreamingLayout {
    private let cache = WBLayoutCache()
    public private(set) var latest: WBBoardLayout?

    public init() {}

    @discardableResult
    public func update(with input: WBLayoutInput) -> WBBoardLayout {
        let boardLayout = WBBoardLayoutEngine.layout(input, cache: cache)
        latest = boardLayout
        return boardLayout
    }

    public func reset() {
        cache.graphEntries = [:]
        cache.orderKeys = [:]
        latest = nil
    }
}
