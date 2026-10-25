//
//  WBGraphLayout.swift
//  ClickyCore
//
//  One section's diagram, Sugiyama style:
//   1. cycles: DFS in arrival order; back edges are reversed (drawn the
//      right way round at the end)
//   2. layers: Kahn longest path
//   3. dummy vertices on every edge spanning > 1 layer
//   4. order: 8 barycenter sweeps (down, up, …); the ordering with the
//      fewest crossings wins, ties keep the earlier one; equal barycenters
//      fall back to arrival order; after each sweep, adjacent swaps that
//      strictly remove crossings (Graphviz's transpose); run from three
//      starts (given order, mirrored, depth-first), best kept
//   5. coordinates (TB; LR is the transpose): layers 64 pt apart (a gap
//      grows to fit the edge label that sits in it), nodes ≥ 36 pt apart, 4
//      neighbour-mean passes, each solved exactly under the spacing
//      constraints (isotonic regression)
//   6. edges: Catmull-Rom through the dummy points, clipped exactly to both
//      node outlines; label on the middle segment, nudged ±12 pt on
//      collision
//  Everything is index arrays; no Dictionary/Set order reaches the output.
//

import CoreGraphics
import Foundation

enum WBGraphLayout {
    static let layerGap: CGFloat = 64
    static let nodeGap: CGFloat = 36
    static let dummyGap: CGFloat = 18
    static let dummyBreadth: CGFloat = 8
    static let sweepCount = 8
    static let coordinatePassCount = 4
    static let transposeRoundLimit = 12
    static let labelGapMargin: CGFloat = 12

    struct Node: Equatable {
        let id: String
        let size: CGSize
        let shape: WBNodeShape
        let arrivalRank: Int
    }

    struct Edge: Equatable {
        let from: Int
        let to: Int
        let label: String?
        let labelSize: CGSize
        let edgeIndex: Int
    }

    struct Result {
        var nodeRects: [CGRect]
        var edges: [WBPlacedEdge]
        var size: CGSize
        var crossings: Int
        var direction: WBLayoutDirection
        var scale: CGFloat
        /// Vertex stability key → position in its layer, seeds the next run.
        var orderKeys: [String: Int]

        func scaled(by scale: CGFloat) -> Result {
            var scaledResult = self
            scaledResult.nodeRects = nodeRects.map { WBLayoutGeometry.transform($0, scale: scale, offset: .zero) }
            scaledResult.edges = edges.map { $0.applying(scale: scale, offset: .zero) }
            scaledResult.size = CGSize(width: size.width * scale, height: size.height * scale)
            scaledResult.scale = self.scale * scale
            return scaledResult
        }
    }

    // MARK: Layered graph

    struct LayeredGraph {
        var layerOfVertex: [Int] = []
        /// Real node index, or -1 for a dummy.
        var realNodeOfVertex: [Int] = []
        var arrivalRankOfVertex: [Int] = []
        var stabilityKeyOfVertex: [String] = []
        var upperNeighbours: [[Int]] = []
        var lowerNeighbours: [[Int]] = []
        /// Per input edge: its vertices top to bottom (endpoints included).
        var chainOfEdge: [[Int]] = []
        var edgeIsReversed: [Bool] = []
        var layerCount = 0

        var vertexCount: Int { layerOfVertex.count }
        func isDummy(_ vertex: Int) -> Bool { realNodeOfVertex[vertex] < 0 }
    }

    /// Which edges a DFS (roots and out-edges in arrival order) finds going
    /// back up its stack; reversing exactly those leaves a DAG.
    static func backEdges(nodeCount: Int, edges: [(from: Int, to: Int)]) -> [Bool] {
        var outgoingEdges = [[Int]](repeating: [], count: nodeCount)
        for (edgeIndex, edge) in edges.enumerated() { outgoingEdges[edge.from].append(edgeIndex) }
        var visitState = [UInt8](repeating: 0, count: nodeCount) // 0 new, 1 on stack, 2 done
        var isBackEdge = [Bool](repeating: false, count: edges.count)
        for root in 0..<nodeCount where visitState[root] == 0 {
            var stack: [(vertex: Int, nextEdge: Int)] = [(root, 0)]
            visitState[root] = 1
            while let top = stack.last {
                if top.nextEdge < outgoingEdges[top.vertex].count {
                    let edgeIndex = outgoingEdges[top.vertex][top.nextEdge]
                    stack[stack.count - 1].nextEdge += 1
                    let target = edges[edgeIndex].to
                    if visitState[target] == 1 {
                        isBackEdge[edgeIndex] = true
                    } else if visitState[target] == 0 {
                        visitState[target] = 1
                        stack.append((target, 0))
                    }
                } else {
                    visitState[top.vertex] = 2
                    stack.removeLast()
                }
            }
        }
        return isBackEdge
    }

    /// Kahn's order; each node one layer below its deepest predecessor.
    static func longestPathLayers(nodeCount: Int, dagEdges: [(from: Int, to: Int)]) -> [Int] {
        var outgoingTargets = [[Int]](repeating: [], count: nodeCount)
        var incomingCount = [Int](repeating: 0, count: nodeCount)
        for edge in dagEdges {
            outgoingTargets[edge.from].append(edge.to)
            incomingCount[edge.to] += 1
        }
        var layers = [Int](repeating: 0, count: nodeCount)
        var queue = (0..<nodeCount).filter { incomingCount[$0] == 0 }
        var queueHead = 0
        while queueHead < queue.count {
            let vertex = queue[queueHead]
            queueHead += 1
            for target in outgoingTargets[vertex] {
                layers[target] = max(layers[target], layers[vertex] + 1)
                incomingCount[target] -= 1
                if incomingCount[target] == 0 { queue.append(target) }
            }
        }
        return layers
    }

    static func layeredGraph(nodes: [Node], edges: [Edge]) -> LayeredGraph {
        let nodeCount = nodes.count
        let directedEdges = edges.map { (from: $0.from, to: $0.to) }
        let isBackEdge = backEdges(nodeCount: nodeCount, edges: directedEdges)
        let dagEdges = directedEdges.enumerated().map { edgeIndex, edge in
            isBackEdge[edgeIndex] ? (from: edge.to, to: edge.from) : edge
        }
        let nodeLayers = longestPathLayers(nodeCount: nodeCount, dagEdges: dagEdges)

        var graph = LayeredGraph()
        graph.layerOfVertex = nodeLayers
        graph.realNodeOfVertex = Array(0..<nodeCount)
        graph.arrivalRankOfVertex = nodes.map(\.arrivalRank)
        graph.stabilityKeyOfVertex = nodes.map(\.id)
        graph.upperNeighbours = [[Int]](repeating: [], count: nodeCount)
        graph.lowerNeighbours = [[Int]](repeating: [], count: nodeCount)
        graph.edgeIsReversed = isBackEdge
        graph.layerCount = (nodeLayers.max() ?? -1) + 1
        let dummyArrivalBase = (nodes.map(\.arrivalRank).max() ?? 0) + 1

        var occurrenceKeys: [String] = []
        for (edgeIndex, dagEdge) in dagEdges.enumerated() {
            let pairKey = "\(nodes[dagEdge.from].id)>\(nodes[dagEdge.to].id)"
            let occurrence = occurrenceKeys.filter { $0 == pairKey }.count
            occurrenceKeys.append(pairKey)
            var chain = [dagEdge.from]
            let upperLayer = nodeLayers[dagEdge.from]
            let lowerLayer = nodeLayers[dagEdge.to]
            if lowerLayer - upperLayer > 1 {
                for (dummyNumber, dummyLayer) in ((upperLayer + 1)..<lowerLayer).enumerated() {
                    let dummyVertex = graph.vertexCount
                    graph.layerOfVertex.append(dummyLayer)
                    graph.realNodeOfVertex.append(-1)
                    graph.arrivalRankOfVertex.append(dummyArrivalBase + edges[edgeIndex].edgeIndex)
                    graph.stabilityKeyOfVertex.append("\(pairKey)#\(occurrence):\(dummyNumber)")
                    graph.upperNeighbours.append([])
                    graph.lowerNeighbours.append([])
                    chain.append(dummyVertex)
                }
            }
            chain.append(dagEdge.to)
            for hop in 0..<(chain.count - 1) {
                graph.lowerNeighbours[chain[hop]].append(chain[hop + 1])
                graph.upperNeighbours[chain[hop + 1]].append(chain[hop])
            }
            graph.chainOfEdge.append(chain)
        }
        return graph
    }

    // MARK: Ordering

    /// Layers in their starting order: previous positions first (streaming
    /// stability), then arrival.
    static func initialLayers(_ graph: LayeredGraph, previousOrderKeys: [String: Int]) -> [[Int]] {
        var layers = [[Int]](repeating: [], count: graph.layerCount)
        for vertex in 0..<graph.vertexCount { layers[graph.layerOfVertex[vertex]].append(vertex) }
        return layers.map { layer in
            layer.sorted { first, second in
                let firstPrevious = previousOrderKeys[graph.stabilityKeyOfVertex[first]] ?? Int.max
                let secondPrevious = previousOrderKeys[graph.stabilityKeyOfVertex[second]] ?? Int.max
                if firstPrevious != secondPrevious { return firstPrevious < secondPrevious }
                if graph.arrivalRankOfVertex[first] != graph.arrivalRankOfVertex[second] {
                    return graph.arrivalRankOfVertex[first] < graph.arrivalRankOfVertex[second]
                }
                return first < second
            }
        }
    }

    static func positions(of layers: [[Int]], vertexCount: Int) -> [Int] {
        var positionOfVertex = [Int](repeating: 0, count: vertexCount)
        for layer in layers {
            for (position, vertex) in layer.enumerated() { positionOfVertex[vertex] = position }
        }
        return positionOfVertex
    }

    /// Pairs of edges between adjacent layers whose ends are in opposite order.
    static func crossingCount(_ graph: LayeredGraph, layers: [[Int]]) -> Int {
        let positionOfVertex = positions(of: layers, vertexCount: graph.vertexCount)
        var total = 0
        var hopEnds: [(upper: Int, lower: Int)] = []
        for layer in layers {
            hopEnds.removeAll(keepingCapacity: true)
            for upperVertex in layer {
                for lowerVertex in graph.lowerNeighbours[upperVertex] {
                    hopEnds.append((positionOfVertex[upperVertex], positionOfVertex[lowerVertex]))
                }
            }
            guard hopEnds.count > 1 else { continue }
            for firstIndex in 0..<(hopEnds.count - 1) {
                let first = hopEnds[firstIndex]
                for secondIndex in (firstIndex + 1)..<hopEnds.count {
                    let second = hopEnds[secondIndex]
                    if (first.upper - second.upper) * (first.lower - second.lower) < 0 { total += 1 }
                }
            }
        }
        return total
    }

    static func orderLayers(_ graph: LayeredGraph, initial: [[Int]]) -> (layers: [[Int]], crossings: Int) {
        var currentLayers = initial
        var bestLayers = initial
        var bestCrossings = crossingCount(graph, layers: initial)
        guard bestCrossings > 0, graph.layerCount > 1 else { return (bestLayers, bestCrossings) }
        var positionOfVertex = positions(of: currentLayers, vertexCount: graph.vertexCount)

        func reorder(layerIndex: Int, usingUpper: Bool) {
            let layer = currentLayers[layerIndex]
            let barycenters: [Double] = layer.map { vertex in
                let neighbours = usingUpper ? graph.upperNeighbours[vertex] : graph.lowerNeighbours[vertex]
                guard !neighbours.isEmpty else { return Double(positionOfVertex[vertex]) }
                return Double(neighbours.reduce(0) { $0 + positionOfVertex[$1] }) / Double(neighbours.count)
            }
            let sortedIndices = layer.indices.sorted { first, second in
                if barycenters[first] != barycenters[second] { return barycenters[first] < barycenters[second] }
                let firstRank = graph.arrivalRankOfVertex[layer[first]]
                let secondRank = graph.arrivalRankOfVertex[layer[second]]
                if firstRank != secondRank { return firstRank < secondRank }
                return first < second
            }
            let reordered = sortedIndices.map { layer[$0] }
            currentLayers[layerIndex] = reordered
            for (position, vertex) in reordered.enumerated() { positionOfVertex[vertex] = position }
        }

        for sweep in 0..<sweepCount {
            if sweep % 2 == 0 {
                for layerIndex in 1..<graph.layerCount { reorder(layerIndex: layerIndex, usingUpper: true) }
            } else {
                for layerIndex in stride(from: graph.layerCount - 2, through: 0, by: -1) { reorder(layerIndex: layerIndex, usingUpper: false) }
            }
            transpose(graph, layers: &currentLayers, positions: &positionOfVertex)
            let sweepCrossings = crossingCount(graph, layers: currentLayers)
            if sweepCrossings < bestCrossings {
                bestCrossings = sweepCrossings
                bestLayers = currentLayers
                if bestCrossings == 0 { break }
            }
        }
        return (bestLayers, bestCrossings)
    }

    /// Crossings among the hops at `left` and `right` (left placed first)
    /// against one neighbour list each.
    static func pairCrossings(_ leftNeighbours: [Int], _ rightNeighbours: [Int], positions positionOfVertex: [Int]) -> Int {
        var count = 0
        for leftNeighbour in leftNeighbours {
            for rightNeighbour in rightNeighbours where positionOfVertex[leftNeighbour] > positionOfVertex[rightNeighbour] { count += 1 }
        }
        return count
    }

    /// Graphviz-style refinement after each sweep: swap adjacent vertices
    /// while that strictly removes crossings (left to right, bounded).
    static func transpose(_ graph: LayeredGraph, layers: inout [[Int]], positions positionOfVertex: inout [Int]) {
        for _ in 0..<transposeRoundLimit {
            var improved = false
            for layerIndex in layers.indices where layers[layerIndex].count > 1 {
                for position in 0..<(layers[layerIndex].count - 1) {
                    let left = layers[layerIndex][position]
                    let right = layers[layerIndex][position + 1]
                    let keptCrossings = pairCrossings(graph.upperNeighbours[left], graph.upperNeighbours[right], positions: positionOfVertex) +
                        pairCrossings(graph.lowerNeighbours[left], graph.lowerNeighbours[right], positions: positionOfVertex)
                    let swappedCrossings = pairCrossings(graph.upperNeighbours[right], graph.upperNeighbours[left], positions: positionOfVertex) +
                        pairCrossings(graph.lowerNeighbours[right], graph.lowerNeighbours[left], positions: positionOfVertex)
                    if swappedCrossings < keptCrossings {
                        layers[layerIndex].swapAt(position, position + 1)
                        positionOfVertex[left] = position + 1
                        positionOfVertex[right] = position
                        improved = true
                    }
                }
            }
            if !improved { break }
        }
    }

    /// Depth-first discovery order (roots and children in arrival order),
    /// the classic starting order for the sweeps.
    static func depthFirstLayers(_ graph: LayeredGraph, initial: [[Int]]) -> [[Int]] {
        var discoveryRank = [Int](repeating: -1, count: graph.vertexCount)
        var nextRank = 0
        let roots = (0..<graph.vertexCount).filter { !graph.isDummy($0) }.sorted {
            graph.arrivalRankOfVertex[$0] != graph.arrivalRankOfVertex[$1] ? graph.arrivalRankOfVertex[$0] < graph.arrivalRankOfVertex[$1] : $0 < $1
        }
        for root in roots where discoveryRank[root] < 0 {
            var stack = [root]
            while let vertex = stack.popLast() {
                guard discoveryRank[vertex] < 0 else { continue }
                discoveryRank[vertex] = nextRank
                nextRank += 1
                for child in graph.lowerNeighbours[vertex].reversed() where discoveryRank[child] < 0 { stack.append(child) }
            }
        }
        return initial.map { layer in layer.sorted { discoveryRank[$0] < discoveryRank[$1] } }
    }

    /// The sweeps from three starts (the given order, its mirror, depth-
    /// first order); fewest crossings wins, ties go to the earlier start so
    /// a streaming re-layout keeps the previous order when it is as good.
    static func bestOrdering(_ graph: LayeredGraph, initial: [[Int]]) -> (layers: [[Int]], crossings: Int) {
        var best = orderLayers(graph, initial: initial)
        guard best.crossings > 0 else { return best }
        for alternativeStart in [initial.map { Array($0.reversed()) }, depthFirstLayers(graph, initial: initial)] {
            let candidate = orderLayers(graph, initial: alternativeStart)
            if candidate.crossings < best.crossings { best = candidate }
            if best.crossings == 0 { break }
        }
        return best
    }

    // MARK: Coordinates

    /// Closest positions to `desired` (least squares) with
    /// x[i+1] − x[i] ≥ separations[i]: pool-adjacent-violators on the
    /// offset-shifted targets.
    static func spacedPositions(desired: [CGFloat], separations: [CGFloat]) -> [CGFloat] {
        guard !desired.isEmpty else { return [] }
        var offsets = [CGFloat](repeating: 0, count: desired.count)
        for index in 1..<max(1, desired.count) { offsets[index] = offsets[index - 1] + separations[index - 1] }
        var blocks: [(sum: CGFloat, count: Int)] = []
        for index in desired.indices {
            blocks.append((desired[index] - offsets[index], 1))
            while blocks.count > 1 {
                let last = blocks[blocks.count - 1]
                let previous = blocks[blocks.count - 2]
                guard previous.sum / CGFloat(previous.count) > last.sum / CGFloat(last.count) else { break }
                blocks.removeLast(2)
                blocks.append((previous.sum + last.sum, previous.count + last.count))
            }
        }
        var result: [CGFloat] = []
        result.reserveCapacity(desired.count)
        for block in blocks {
            let blockMean = block.sum / CGFloat(block.count)
            for _ in 0..<block.count { result.append(blockMean + offsets[result.count]) }
        }
        return result
    }

    // MARK: Entry point

    static func layout(nodes: [Node], edges: [Edge], direction: WBLayoutDirection, previousOrderKeys: [String: Int] = [:]) -> Result {
        guard !nodes.isEmpty else {
            return Result(nodeRects: [], edges: [], size: .zero, crossings: 0, direction: direction, scale: 1, orderKeys: [:])
        }
        let graph = layeredGraph(nodes: nodes, edges: edges)
        let (layers, crossings) = bestOrdering(graph, initial: initialLayers(graph, previousOrderKeys: previousOrderKeys))
        let isTopToBottom = direction == .topToBottom

        // Breadth runs along a layer, depth across it.
        func breadth(_ vertex: Int) -> CGFloat {
            let realNode = graph.realNodeOfVertex[vertex]
            guard realNode >= 0 else { return dummyBreadth }
            return isTopToBottom ? nodes[realNode].size.width : nodes[realNode].size.height
        }
        func depth(_ vertex: Int) -> CGFloat {
            let realNode = graph.realNodeOfVertex[vertex]
            guard realNode >= 0 else { return 0 }
            return isTopToBottom ? nodes[realNode].size.height : nodes[realNode].size.width
        }

        // Gap after each layer: 64, or wider for the label that sits in it.
        var gapAfterLayer = [CGFloat](repeating: layerGap, count: graph.layerCount)
        for (edgeIndex, edge) in edges.enumerated() where edge.label != nil {
            let chain = graph.chainOfEdge[edgeIndex]
            let hopCount = chain.count - 1
            let outputHop = WBLayoutGeometry.labelSegmentIndex(segmentCount: hopCount)
            let topDownHop = graph.edgeIsReversed[edgeIndex] ? hopCount - 1 - outputHop : outputHop
            let gapLayer = graph.layerOfVertex[chain[topDownHop]]
            let labelDepth = isTopToBottom ? edge.labelSize.height : edge.labelSize.width
            gapAfterLayer[gapLayer] = max(gapAfterLayer[gapLayer], labelDepth + 2 * labelGapMargin)
        }
        var layerCenterAcross = [CGFloat](repeating: 0, count: graph.layerCount)
        var acrossCursor: CGFloat = 0
        for (layerIndex, layer) in layers.enumerated() {
            let layerDepth = layer.map(depth).max() ?? 0
            layerCenterAcross[layerIndex] = acrossCursor + layerDepth / 2
            acrossCursor += layerDepth + gapAfterLayer[layerIndex]
        }

        func separations(for layer: [Int]) -> [CGFloat] {
            guard layer.count > 1 else { return [] }
            return (0..<(layer.count - 1)).map { index in
                let first = layer[index]
                let second = layer[index + 1]
                let gap = graph.isDummy(first) || graph.isDummy(second) ? dummyGap : nodeGap
                return (breadth(first) + breadth(second)) / 2 + gap
            }
        }

        // Packed, each layer centred on 0, then neighbour-mean passes.
        var along = [CGFloat](repeating: 0, count: graph.vertexCount)
        for layer in layers {
            let packed = spacedPositions(desired: [CGFloat](repeating: 0, count: layer.count), separations: separations(for: layer))
            for (index, vertex) in layer.enumerated() { along[vertex] = packed[index] }
        }
        for pass in 0..<coordinatePassCount {
            let usesUpper = pass % 2 == 0
            let layerOrder: [Int] = usesUpper ? Array(1..<max(1, graph.layerCount)) : Array(stride(from: graph.layerCount - 2, through: 0, by: -1))
            for layerIndex in layerOrder {
                let layer = layers[layerIndex]
                let desired: [CGFloat] = layer.map { vertex in
                    let neighbours = usesUpper ? graph.upperNeighbours[vertex] : graph.lowerNeighbours[vertex]
                    guard !neighbours.isEmpty else { return along[vertex] }
                    return neighbours.reduce(CGFloat(0)) { $0 + along[$1] } / CGFloat(neighbours.count)
                }
                let solved = spacedPositions(desired: desired, separations: separations(for: layer))
                for (index, vertex) in layer.enumerated() { along[vertex] = solved[index] }
            }
        }

        func center(of vertex: Int) -> CGPoint {
            let acrossValue = layerCenterAcross[graph.layerOfVertex[vertex]]
            return isTopToBottom ? CGPoint(x: along[vertex], y: acrossValue) : CGPoint(x: acrossValue, y: along[vertex])
        }
        let nodeRects: [CGRect] = nodes.indices.map { nodeIndex in
            let nodeCenter = center(of: nodeIndex)
            return CGRect(x: nodeCenter.x - nodes[nodeIndex].size.width / 2, y: nodeCenter.y - nodes[nodeIndex].size.height / 2,
                          width: nodes[nodeIndex].size.width, height: nodes[nodeIndex].size.height)
        }

        // Edges: knots = clipped ends + dummy centres, in the edge's own direction.
        var placedEdges: [WBPlacedEdge] = []
        var labelObstacles = nodeRects
        for (edgeIndex, edge) in edges.enumerated() {
            let chain = graph.chainOfEdge[edgeIndex]
            var knots = chain.map(center)
            let upperNode = chain[0]
            let lowerNode = chain[chain.count - 1]
            knots[0] = WBLayoutGeometry.borderPoint(of: nodeRects[upperNode], shape: nodes[upperNode].shape, toward: knots[1])
            knots[knots.count - 1] = WBLayoutGeometry.borderPoint(of: nodeRects[lowerNode], shape: nodes[lowerNode].shape, toward: knots[knots.count - 2])
            if graph.edgeIsReversed[edgeIndex] { knots.reverse() }
            let segments = WBLayoutGeometry.catmullRomSegments(through: knots)
            var labelRect: CGRect?
            if edge.label != nil, let anchor = WBLayoutGeometry.labelAnchor(of: segments) {
                let placedLabel = WBLayoutGeometry.placeLabel(size: edge.labelSize, at: anchor, obstacles: labelObstacles)
                labelObstacles.append(placedLabel)
                labelRect = placedLabel
            }
            placedEdges.append(WBPlacedEdge(edgeIndex: edge.edgeIndex, from: nodes[edge.from].id, to: nodes[edge.to].id,
                                            label: edge.label, points: knots, segments: segments, labelRect: labelRect))
        }

        // Normalise to the origin.
        var bounds = nodeRects.reduce(CGRect.null) { $0.union($1) }
        for placedEdge in placedEdges {
            bounds = bounds.union(WBLayoutGeometry.bounds(of: placedEdge.segments))
            if let labelRect = placedEdge.labelRect { bounds = bounds.union(labelRect) }
        }
        let offset = CGVector(dx: -bounds.minX, dy: -bounds.minY)
        var orderKeys: [String: Int] = [:]
        for layer in layers {
            for (position, vertex) in layer.enumerated() { orderKeys[graph.stabilityKeyOfVertex[vertex]] = position }
        }
        return Result(nodeRects: nodeRects.map { $0.offsetBy(dx: offset.dx, dy: offset.dy) },
                      edges: placedEdges.map { $0.applying(scale: 1, offset: offset) },
                      size: bounds.size, crossings: crossings, direction: direction, scale: 1, orderKeys: orderKeys)
    }
}
