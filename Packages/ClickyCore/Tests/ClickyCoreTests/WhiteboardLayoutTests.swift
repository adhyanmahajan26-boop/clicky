import CoreGraphics
import Foundation
import Testing
@testable import ClickyCore

// Whiteboard layout: measure, sections, layered diagrams, near placement,
// camera, streaming and the rough.js port. Serialized because one test sets
// the global math measurement hook.

/// SplitMix64: reproducible random boards.
private struct BoardRandom: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var mixed = state
        mixed = (mixed ^ (mixed >> 30)) &* 0xBF58_476D_1CE4_E5B9
        mixed = (mixed ^ (mixed >> 27)) &* 0x94D0_49BB_1331_11EB
        return mixed ^ (mixed >> 31)
    }
}

private let sampleWords = ["load", "balancer", "API", "gateway", "cache", "queue", "worker", "database", "replica", "auth",
                           "token", "user", "request", "response", "retry", "timeout", "shard", "index", "metrics", "alert"]

private func randomPhrase(_ random: inout BoardRandom, maximumWords: Int) -> String {
    (0..<Int.random(in: 1...maximumWords, using: &random)).map { _ in sampleWords.randomElement(using: &random)! }.joined(separator: " ")
}

/// Mixed boards: diagrams (with cycles, long edges, labels), flow content of
/// every kind but math, near callouts, 1–6 sections, both directions.
private func randomBoard(seed: UInt64) -> WBLayoutInput {
    var random = BoardRandom(state: seed)
    let sectionCount = Int.random(in: 1...6, using: &random)
    let sections = (0..<sectionCount).map { WBLayoutSection(id: "s\($0)", title: Bool.random(using: &random) ? "Section \($0)" : nil) }
    let nodeCount = Int.random(in: 4...24, using: &random)
    var nodes: [WBLayoutNode] = []
    let flowKinds: [WBLayoutNodeKind] = [.text, .list, .code, .chart, .table, .callout]
    for nodeIndex in 0..<nodeCount {
        let roll = Double.random(in: 0..<1, using: &random)
        let kind: WBLayoutNodeKind = roll < 0.5 ? .box : (roll < 0.62 ? .ellipse : flowKinds.randomElement(using: &random)!)
        var node = WBLayoutNode(id: "n\(nodeIndex)", kind: kind, section: "s\(Int.random(in: 0..<sectionCount, using: &random))",
                                text: randomPhrase(&random, maximumWords: kind == .text ? 14 : 6))
        switch kind {
        case .list: node.items = (0..<Int.random(in: 1...4, using: &random)).map { _ in randomPhrase(&random, maximumWords: 5) }
        case .table: node.rows = (0..<Int.random(in: 1...3, using: &random)).map { _ in [randomPhrase(&random, maximumWords: 2), randomPhrase(&random, maximumWords: 2)] }
        case .code: node.text = "let x = \(nodeIndex)\nreturn x * 2"
        default: break
        }
        if (kind == .text || kind == .callout), nodeIndex > 0, Double.random(in: 0..<1, using: &random) < 0.6 {
            node.near = WBLayoutNear(targetID: "n\(Int.random(in: 0..<nodeIndex, using: &random))", side: WBLayoutSide.allCases.randomElement(using: &random)!)
        }
        nodes.append(node)
    }
    var edges: [WBLayoutEdge] = []
    let edgeCount = Int.random(in: 0...(nodeCount * 3 / 2), using: &random)
    for _ in 0..<edgeCount {
        let from = Int.random(in: 0..<nodeCount, using: &random)
        let to = Int.random(in: 0..<nodeCount, using: &random)
        let label = Double.random(in: 0..<1, using: &random) < 0.4 ? randomPhrase(&random, maximumWords: 2) : nil
        edges.append(WBLayoutEdge(from: "n\(from)", to: "n\(to)", label: label))
    }
    let viewports = [CGSize(width: 1280, height: 800), CGSize(width: 900, height: 1100), CGSize(width: 1600, height: 900)]
    return WBLayoutInput(nodes: nodes, edges: edges, sections: sections,
                         direction: Bool.random(using: &random) ? .topToBottom : .leftToRight,
                         viewportSize: viewports.randomElement(using: &random)!)
}

private func distanceToBorder(_ point: CGPoint, of rect: CGRect, shape: WBNodeShape) -> CGFloat {
    switch shape {
    case .rectangle:
        if point.x >= rect.minX, point.x <= rect.maxX, point.y >= rect.minY, point.y <= rect.maxY {
            return min(point.x - rect.minX, rect.maxX - point.x, point.y - rect.minY, rect.maxY - point.y)
        }
        let outsideX = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let outsideY = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return hypot(outsideX, outsideY)
    case .ellipse:
        // Distance to the radial projection onto the ellipse (an upper bound).
        let semiAxisX = rect.width / 2, semiAxisY = rect.height / 2
        let deltaX = point.x - rect.midX, deltaY = point.y - rect.midY
        let normalizedRadius = ((deltaX / semiAxisX) * (deltaX / semiAxisX) + (deltaY / semiAxisY) * (deltaY / semiAxisY)).squareRoot()
        guard normalizedRadius > 0 else { return min(semiAxisX, semiAxisY) }
        return hypot(deltaX - deltaX / normalizedRadius, deltaY - deltaY / normalizedRadius)
    }
}

private func strictlyOverlap(_ first: CGRect, _ second: CGRect) -> Bool {
    let intersection = first.intersection(second)
    return !intersection.isNull && intersection.width > 0.01 && intersection.height > 0.01
}

/// Every invariant the layout promises, as a list of failures.
private func layoutProblems(_ layout: WBBoardLayout) -> [String] {
    var problems: [String] = []
    let elements = layout.elements
    for firstIndex in elements.indices {
        for secondIndex in (firstIndex + 1)..<max(firstIndex + 1, elements.count) where strictlyOverlap(elements[firstIndex].rect, elements[secondIndex].rect) {
            problems.append("overlap \(elements[firstIndex].id) \(elements[secondIndex].id)")
        }
    }
    let labelRects = layout.edges.compactMap(\.labelRect)
    for (labelIndex, labelRect) in labelRects.enumerated() {
        for element in elements where strictlyOverlap(labelRect, element.rect) { problems.append("label \(labelIndex) on \(element.id)") }
        for otherIndex in (labelIndex + 1)..<max(labelIndex + 1, labelRects.count) where strictlyOverlap(labelRect, labelRects[otherIndex]) {
            problems.append("label \(labelIndex) on label \(otherIndex)")
        }
    }
    for element in elements {
        guard let section = layout.sections.first(where: { $0.id == element.sectionID }) else {
            problems.append("no section for \(element.id)")
            continue
        }
        if !section.rect.insetBy(dx: -0.01, dy: -0.01).contains(element.rect) { problems.append("\(element.id) outside \(section.id)") }
        if !layout.bounds.contains(section.rect) { problems.append("\(section.id) outside the board") }
    }
    for edge in layout.edges {
        guard let fromElement = layout.element(id: edge.from), let toElement = layout.element(id: edge.to) else {
            problems.append("edge \(edge.edgeIndex) to unknown node")
            continue
        }
        let startDistance = distanceToBorder(edge.start, of: fromElement.rect, shape: fromElement.shape)
        let endDistance = distanceToBorder(edge.end, of: toElement.rect, shape: toElement.shape)
        if startDistance > 0.5 { problems.append("edge \(edge.edgeIndex) starts \(startDistance) pt off \(edge.from)") }
        if endDistance > 0.5 { problems.append("edge \(edge.edgeIndex) ends \(endDistance) pt off \(edge.to)") }
        if edge.segments.first?.start != edge.start || edge.segments.last?.end != edge.end { problems.append("edge \(edge.edgeIndex) segments detached") }
    }
    return problems
}

// MARK: Diagram fixtures

private func graphNodes(_ ids: [String], size: CGSize = CGSize(width: 100, height: 50)) -> [WBGraphLayout.Node] {
    ids.enumerated().map { WBGraphLayout.Node(id: $1, size: size, shape: .rectangle, arrivalRank: $0) }
}

private func graphEdges(_ pairs: [(String, String)], nodes: [WBGraphLayout.Node]) -> [WBGraphLayout.Edge] {
    pairs.enumerated().map { edgeIndex, pair in
        WBGraphLayout.Edge(from: nodes.firstIndex { $0.id == pair.0 }!, to: nodes.firstIndex { $0.id == pair.1 }!,
                           label: nil, labelSize: .zero, edgeIndex: edgeIndex)
    }
}

/// The fewest crossings any ordering of the layered graph's layers achieves.
private func bruteForceMinimumCrossings(_ graph: WBGraphLayout.LayeredGraph) -> Int {
    var layers = [[Int]](repeating: [], count: graph.layerCount)
    for vertex in 0..<graph.vertexCount { layers[graph.layerOfVertex[vertex]].append(vertex) }
    func permutations(_ items: [Int]) -> [[Int]] {
        guard items.count > 1 else { return [items] }
        return items.indices.flatMap { index -> [[Int]] in
            var remaining = items
            let head = remaining.remove(at: index)
            return permutations(remaining).map { [head] + $0 }
        }
    }
    let layerPermutations = layers.map(permutations)
    var best = Int.max
    var chosen = layers
    func search(_ layerIndex: Int) {
        if layerIndex == layers.count {
            best = min(best, WBGraphLayout.crossingCount(graph, layers: chosen))
            return
        }
        for permutation in layerPermutations[layerIndex] {
            chosen[layerIndex] = permutation
            search(layerIndex + 1)
        }
    }
    search(0)
    return best
}

private func permutationCount(_ graph: WBGraphLayout.LayeredGraph) -> Int {
    var layerSizes = [Int](repeating: 0, count: graph.layerCount)
    for vertex in 0..<graph.vertexCount { layerSizes[graph.layerOfVertex[vertex]] += 1 }
    return layerSizes.reduce(1) { total, size in total * (1...max(1, size)).reduce(1, *) }
}

private func streamingBoard() -> (inputs: [WBLayoutInput], addedNode: [WBLayoutNode]) {
    let sections = [WBLayoutSection(id: "flow", title: "How a request flows"), WBLayoutSection(id: "notes", title: "Notes")]
    let allNodes: [WBLayoutNode] = [
        WBLayoutNode(id: "title", kind: .text, section: "flow", text: "Request path"),
        WBLayoutNode(id: "client", kind: .box, section: "flow", text: "Client"),
        WBLayoutNode(id: "lb", kind: .box, section: "flow", text: "Load balancer"),
        WBLayoutNode(id: "api", kind: .box, section: "flow", text: "API server"),
        WBLayoutNode(id: "note1", kind: .text, section: "notes", text: "Requests are retried with backoff"),
        WBLayoutNode(id: "cache", kind: .ellipse, section: "flow", text: "Cache"),
        WBLayoutNode(id: "db", kind: .box, section: "flow", text: "Database"),
        WBLayoutNode(id: "list1", kind: .list, section: "notes", items: ["p50 12 ms", "p99 80 ms"]),
        WBLayoutNode(id: "caption", kind: .text, section: "flow", text: "Reads hit the cache first"),
        WBLayoutNode(id: "chart1", kind: .chart, section: "notes"),
        WBLayoutNode(id: "callout1", kind: .callout, section: "flow", text: "hot path", near: WBLayoutNear(targetID: "cache", side: .right)),
        WBLayoutNode(id: "code1", kind: .code, section: "notes", text: "GET /v1/items")
    ]
    let allEdges = [WBLayoutEdge(from: "client", to: "lb"), WBLayoutEdge(from: "lb", to: "api", label: "HTTPS"),
                    WBLayoutEdge(from: "api", to: "cache", label: "read"), WBLayoutEdge(from: "api", to: "db"),
                    WBLayoutEdge(from: "cache", to: "db", label: "miss")]
    var inputs: [WBLayoutInput] = []
    for count in 1...allNodes.count {
        let presentNodes = Array(allNodes.prefix(count))
        let presentIDs = presentNodes.map(\.id)
        let presentEdges = allEdges.filter { presentIDs.contains($0.from) && presentIDs.contains($0.to) }
        inputs.append(WBLayoutInput(nodes: presentNodes, edges: presentEdges, sections: sections, viewportSize: CGSize(width: 1600, height: 900)))
    }
    return (inputs, allNodes)
}

@Suite(.serialized)
struct WhiteboardLayoutTests {

    // MARK: Measure

    @Test func measureFixedAndWrappedSizes() {
        #expect(WBMeasure.size(of: WBLayoutNode(id: "c", kind: .chart)) == CGSize(width: 320, height: 200))
        let shortBox = WBMeasure.size(of: WBLayoutNode(id: "a", kind: .box, text: "Cache"))
        let longBox = WBMeasure.size(of: WBLayoutNode(id: "b", kind: .box, text: String(repeating: "a long label that wraps ", count: 6)))
        #expect(longBox.width <= WBMeasure.boxWrapWidth + 2 * WBMeasure.boxPadding)
        #expect(longBox.height > shortBox.height * 2)
        #expect(shortBox.width >= WBMeasure.minimumBoxSize.width && shortBox.height >= WBMeasure.minimumBoxSize.height)
        let tinyFont = WBMeasure.size(of: WBLayoutNode(id: "t", kind: .box, text: "Cache", fontSize: 8))
        let minimumFont = WBMeasure.size(of: WBLayoutNode(id: "t", kind: .box, text: "Cache", fontSize: 15))
        #expect(tinyFont == minimumFont)
        let ellipse = WBMeasure.size(of: WBLayoutNode(id: "e", kind: .ellipse, text: "Cache"))
        #expect(ellipse.width > shortBox.width)
        let table = WBMeasure.size(of: WBLayoutNode(id: "t", kind: .table, rows: [["a", "b"], ["c", "d"], ["e", "f"]]))
        let shorterTable = WBMeasure.size(of: WBLayoutNode(id: "t", kind: .table, rows: [["a", "b"]]))
        #expect(table.height > shorterTable.height * 2.5)
        let hinted = WBMeasure.size(of: WBLayoutNode(id: "h", kind: .box, text: "x", sizeHint: CGSize(width: 77, height: 33)))
        #expect(hinted == CGSize(width: 77, height: 33))
        let code = WBMeasure.size(of: WBLayoutNode(id: "k", kind: .code, text: String(repeating: "x", count: 80)))
        #expect(code.width > 400) // code never wraps
    }

    @Test func mathUsesTheHookWhenSet() {
        let node = WBLayoutNode(id: "m", kind: .math, text: "\\frac{a}{b}")
        let sourceSize = WBMeasure.size(of: node)
        #expect(sourceSize.width > 2 * WBMeasure.mathPadding)
        WBMeasure.mathSizeProvider = { _, _ in CGSize(width: 100, height: 40) }
        defer { WBMeasure.mathSizeProvider = nil }
        #expect(WBMeasure.size(of: node) == CGSize(width: 116, height: 56))
    }

    // MARK: Sections

    @Test func sectionArrangements() {
        let wide = CGSize(width: 1600, height: 900)
        let tall = CGSize(width: 900, height: 1100)
        #expect(WBSectionLayout.grid(sectionCount: 1, viewportSize: wide).arrangement == .single)
        #expect(WBSectionLayout.grid(sectionCount: 2, viewportSize: wide).arrangement == .columns)
        #expect(WBSectionLayout.grid(sectionCount: 3, viewportSize: wide).columnCount == 3)
        #expect(WBSectionLayout.grid(sectionCount: 2, viewportSize: tall).arrangement == .rows)
        #expect(WBSectionLayout.grid(sectionCount: 3, viewportSize: CGSize(width: 1200, height: 1000)).arrangement == .rows) // 1.2 < 1.3
        let four = WBSectionLayout.grid(sectionCount: 4, viewportSize: wide)
        #expect(four.arrangement == .grid && four.columnCount == 2 && four.rowCount == 2)
        let seven = WBSectionLayout.grid(sectionCount: 7, viewportSize: wide)
        #expect(seven.arrangement == .threeColumns && seven.columnCount == 3 && seven.rowCount == 3)

        // Sections tile the viewport and keep first-appearance order.
        let input = WBLayoutInput(nodes: [WBLayoutNode(id: "a", kind: .text, section: "right", text: "r"),
                                          WBLayoutNode(id: "b", kind: .text, section: "left", text: "l")],
                                  sections: [WBLayoutSection(id: "left")], viewportSize: wide)
        let layout = WBBoardLayoutEngine.layout(input)
        #expect(layout.sections.map(\.id) == ["left", "right"])
        #expect(layout.sections[0].rect.maxX < layout.sections[1].rect.minX)
        #expect(abs(layout.bounds.width - wide.width) < 1)
    }

    @Test func blocksStackInFirstAppearanceOrder() {
        let input = WBLayoutInput(nodes: [
            WBLayoutNode(id: "heading", kind: .text, text: "Heading"),
            WBLayoutNode(id: "a", kind: .box, text: "A"),
            WBLayoutNode(id: "b", kind: .box, text: "B"),
            WBLayoutNode(id: "after", kind: .text, text: "After the diagram"),
            WBLayoutNode(id: "chart", kind: .chart)
        ], edges: [WBLayoutEdge(from: "a", to: "b")])
        let layout = WBBoardLayoutEngine.layout(input)
        let heading = layout.element(id: "heading")!.rect
        let diagramBottom = max(layout.element(id: "a")!.rect.maxY, layout.element(id: "b")!.rect.maxY)
        let after = layout.element(id: "after")!.rect
        #expect(heading.maxY + WBSectionLayout.blockGap <= layout.element(id: "a")!.rect.minY + 0.01)
        #expect(after.minY >= diagramBottom + WBSectionLayout.blockGap - 0.01)
        #expect(layout.element(id: "chart")!.rect.minY == after.minY) // same flow row
        #expect(layout.element(id: "a")!.role == .graphNode && after.width > 0 && layout.element(id: "after")!.role == .flow)
    }

    // MARK: Invariants on random boards

    @Test func randomBoardsHaveNoOverlapsAndExactArrowEnds() {
        var checkedEdges = 0
        for seed in UInt64(1)...60 {
            let layout = WBBoardLayoutEngine.layout(randomBoard(seed: seed))
            let problems = layoutProblems(layout)
            #expect(problems.isEmpty, "seed \(seed): \(problems.prefix(5))")
            checkedEdges += layout.edges.count
        }
        #expect(checkedEdges > 200)
    }

    @Test func wideDiagramsSwitchToTopToBottomThenScale() {
        // 10 siblings in LR stack vertically: fine. In TB they are too wide.
        let ids = ["root"] + (0..<10).map { "leaf\($0)" }
        let nodes = ids.map { WBLayoutNode(id: $0, kind: .box, text: $0, sizeHint: CGSize(width: 120, height: 50)) }
        let fanOut = (0..<10).map { WBLayoutEdge(from: "root", to: "leaf\($0)") }
        let topToBottom = WBBoardLayoutEngine.layout(WBLayoutInput(nodes: nodes, edges: fanOut, viewportSize: CGSize(width: 1200, height: 800)))
        let leafScale = topToBottom.element(id: "leaf0")!.contentScale
        #expect(leafScale < 1 && leafScale >= 0.7)
        #expect(topToBottom.element(id: "leaf0")!.rect.width == 120 * leafScale)
        #expect(layoutProblems(topToBottom).isEmpty)

        // A long LR chain that can't fit turns into TB.
        let chainIDs = (0..<9).map { "c\($0)" }
        let chainNodes = chainIDs.map { WBLayoutNode(id: $0, kind: .box, text: $0, sizeHint: CGSize(width: 140, height: 50)) }
        let chainEdges = (0..<8).map { WBLayoutEdge(from: "c\($0)", to: "c\($0 + 1)") }
        let chainLayout = WBBoardLayoutEngine.layout(WBLayoutInput(nodes: chainNodes, edges: chainEdges, direction: .leftToRight,
                                                                   viewportSize: CGSize(width: 1000, height: 800)))
        #expect(chainLayout.element(id: "c0")!.rect.midX == chainLayout.element(id: "c8")!.rect.midX)
        #expect(chainLayout.element(id: "c0")!.rect.maxY < chainLayout.element(id: "c1")!.rect.minY)
        #expect(chainLayout.element(id: "c0")!.contentScale == 1)
    }

    // MARK: Crossings

    @Test func planarDiagramsHaveNoCrossings() {
        let fixtures: [(name: String, nodes: [String], edges: [(String, String)])] = [
            ("chain", ["a", "b", "c", "d", "e"], [("a", "b"), ("b", "c"), ("c", "d"), ("d", "e")]),
            ("tree", ["r", "a", "b", "c", "d", "e", "f", "g"],
             [("r", "a"), ("a", "c"), ("r", "b"), ("b", "e"), ("a", "d"), ("b", "f"), ("e", "g")]),
            ("diamond", ["a", "b", "c", "d"], [("a", "b"), ("a", "c"), ("b", "d"), ("c", "d")]),
            ("parallel chains", ["a1", "b2", "b1", "a2", "b3", "a3"], [("a1", "a2"), ("b1", "b2"), ("a2", "a3"), ("b2", "b3")]),
            ("star", ["c", "l1", "l2", "l3", "l4", "l5", "l6"], [("c", "l4"), ("c", "l2"), ("c", "l6"), ("c", "l1"), ("c", "l5"), ("c", "l3")]),
            ("ladder", ["a1", "a2", "a3", "b1", "b2", "b3"],
             [("a1", "a2"), ("a2", "a3"), ("b1", "b2"), ("b2", "b3"), ("a1", "b1"), ("a2", "b2"), ("a3", "b3")]),
            ("small DAG", ["a", "b", "c", "d", "e", "f"],
             [("a", "b"), ("a", "c"), ("b", "d"), ("c", "d"), ("d", "e"), ("a", "e"), ("c", "f")])
        ]
        for fixture in fixtures {
            let nodes = graphNodes(fixture.nodes)
            let edges = graphEdges(fixture.edges, nodes: nodes)
            for direction in [WBLayoutDirection.topToBottom, .leftToRight] {
                let result = WBGraphLayout.layout(nodes: nodes, edges: edges, direction: direction)
                #expect(result.crossings == 0, "\(fixture.name) \(direction): \(result.crossings) crossings")
            }
        }
    }

    @Test func harderDiagramsAreWithinOneOfOptimal() {
        var fixtures: [(name: String, nodes: [String], edges: [(String, String)])] = [
            ("K3,3", ["a", "b", "c", "x", "y", "z"],
             [("a", "z"), ("b", "x"), ("c", "y"), ("a", "x"), ("b", "y"), ("c", "z"), ("a", "y"), ("b", "z"), ("c", "x")])
        ]
        // Random DAGs small enough to brute-force, that do need crossings.
        var random = BoardRandom(state: 42)
        while fixtures.count < 3 {
            let nodeIDs = (0..<8).map { "v\($0)" }
            var pairs: [(String, String)] = []
            for from in 0..<8 {
                for to in (from + 1)..<8 where Double.random(in: 0..<1, using: &random) < 0.32 { pairs.append((nodeIDs[from], nodeIDs[to])) }
            }
            let shuffledIDs = nodeIDs.shuffled(using: &random)
            let nodes = graphNodes(shuffledIDs)
            let graph = WBGraphLayout.layeredGraph(nodes: nodes, edges: graphEdges(pairs, nodes: nodes))
            guard permutationCount(graph) <= 40_000, bruteForceMinimumCrossings(graph) > 0 else { continue }
            fixtures.append(("random DAG \(fixtures.count)", shuffledIDs, pairs))
        }
        for fixture in fixtures {
            let nodes = graphNodes(fixture.nodes)
            let edges = graphEdges(fixture.edges, nodes: nodes)
            let graph = WBGraphLayout.layeredGraph(nodes: nodes, edges: edges)
            let optimum = bruteForceMinimumCrossings(graph)
            let result = WBGraphLayout.layout(nodes: nodes, edges: edges, direction: .topToBottom)
            print("crossings \(fixture.name): heuristic \(result.crossings), optimum \(optimum)")
            #expect(result.crossings <= optimum + 1, "\(fixture.name): \(result.crossings) vs optimum \(optimum)")
        }
    }

    @Test func cyclesAreBrokenAndDrawnTheRightWay() {
        let nodes = graphNodes(["a", "b", "c"])
        let edges = graphEdges([("a", "b"), ("b", "c"), ("c", "a")], nodes: nodes)
        let graph = WBGraphLayout.layeredGraph(nodes: nodes, edges: edges)
        #expect(graph.edgeIsReversed == [false, false, true])
        #expect(graph.layerOfVertex.prefix(3) == [0, 1, 2])
        let result = WBGraphLayout.layout(nodes: nodes, edges: edges, direction: .topToBottom)
        let backEdge = result.edges[2]
        #expect(backEdge.from == "c" && backEdge.to == "a")
        #expect(backEdge.start.y < result.nodeRects[2].midY && backEdge.end.y > result.nodeRects[0].midY)
        #expect(graph.vertexCount == 4) // c→a spans two layers: one dummy
    }

    // MARK: Near

    @Test func nearPlacementPrefersTheRequestedSide() {
        let target = CGRect(x: 200, y: 200, width: 100, height: 50)
        let size = CGSize(width: 60, height: 20)
        let top = WBNearPlacer.place(size: size, near: target, side: .top, obstacles: [target])
        #expect(top.side == .top && top.nudge == 0)
        #expect(top.rect == CGRect(x: 220, y: 168, width: 60, height: 20))

        let blockedTop = WBNearPlacer.place(size: size, near: target, side: .top, obstacles: [target, CGRect(x: 150, y: 150, width: 200, height: 45)])
        #expect(blockedTop.side == .bottom && blockedTop.rect.minY == target.maxY + WBNearPlacer.gap)

        // All four centred spots taken, but room 32 pt to the right above.
        let blockers = WBLayoutSide.allCases.map { WBNearPlacer.rect(size: size, beside: target, side: $0).insetBy(dx: 1, dy: 1) }
        let nudged = WBNearPlacer.place(size: size, near: target, side: .top, obstacles: [target] + blockers)
        #expect(nudged.side == .top && nudged.isBeside)
        #expect(abs(nudged.nudge) <= CGFloat(WBNearPlacer.maximumNudgeTries / 2) * WBNearPlacer.nudgeStep && nudged.nudge != 0)
        #expect(!([target] + blockers).contains { strictlyOverlap($0, nudged.rect) })

        // Boxed in completely: below everything, still overlapping nothing.
        let wall = CGRect(x: -1000, y: -1000, width: 3000, height: 1400)
        let boxedIn = WBNearPlacer.place(size: size, near: target, side: .left, obstacles: [target, wall])
        #expect(!boxedIn.isBeside && boxedIn.rect.minY >= wall.maxY)

        // Through the board: a callout to the right of its box.
        let layout = WBBoardLayoutEngine.layout(WBLayoutInput(nodes: [
            WBLayoutNode(id: "box", kind: .box, text: "Cache"),
            WBLayoutNode(id: "note", kind: .callout, text: "hot", near: WBLayoutNear(targetID: "box", side: .right))
        ]))
        let boxRect = layout.element(id: "box")!.rect
        let noteRect = layout.element(id: "note")!.rect
        #expect(layout.element(id: "note")!.role == .near)
        #expect(noteRect.minX == boxRect.maxX + WBNearPlacer.gap && noteRect.midY == boxRect.midY)
    }

    // MARK: Camera

    @Test func cameraIsFixedWhenTheBoardFits() {
        let layout = WBBoardLayoutEngine.layout(WBLayoutInput(nodes: [WBLayoutNode(id: "a", kind: .box, text: "A"),
                                                                      WBLayoutNode(id: "b", kind: .box, text: "B")],
                                                              edges: [WBLayoutEdge(from: "a", to: "b")]))
        let viewport = CGSize(width: 1280, height: 800)
        let plan = WBCamera.plan(layout: layout, steps: [WBCameraStep(show: ["a"]), WBCameraStep(focus: ["b"])], viewportSize: viewport)
        #expect(plan.mode == .fixed)
        #expect(plan.stepTransforms == [plan.boardTransform, plan.boardTransform])
        #expect(plan.boardTransform.scale <= 1 && plan.boardTransform.scale >= WBCamera.fixedMinimumScale)
        #expect(plan.springDuration == 0.6)
    }

    @Test func cameraFramesEachStepWhenTheBoardIsTooBig() {
        let rects: [String: CGRect] = [
            "a": CGRect(x: 100, y: 100, width: 200, height: 100),
            "b": CGRect(x: 250, y: 120, width: 200, height: 100),
            "c": CGRect(x: 3000, y: 2500, width: 100, height: 100)
        ]
        let viewport = CGSize(width: 1000, height: 800)
        let steps = [WBCameraStep(show: ["a"]), WBCameraStep(highlight: ["b"]), WBCameraStep(focus: ["c"]), WBCameraStep(show: ["missing"])]
        let plan = WBCamera.plan(boardBounds: CGRect(x: 0, y: 0, width: 4000, height: 3000), steps: steps, viewportSize: viewport) { rects[$0] }
        #expect(plan.mode == .perStep)
        #expect(plan.stepTransforms.count == 4)
        #expect(plan.stepTransforms[0].framedRect == CGRect(x: 80, y: 90, width: 240, height: 120))
        // b's margined frame overlaps a's: merged.
        #expect(plan.stepTransforms[1].framedRect == CGRect(x: 80, y: 90, width: 390, height: 140))
        #expect(plan.stepTransforms[2].framedRect == CGRect(x: 2990, y: 2490, width: 120, height: 120))
        #expect(plan.stepTransforms[2].scale == WBCamera.stepMaximumScale)
        #expect(plan.stepTransforms[3] == plan.stepTransforms[2])
        for transform in plan.stepTransforms {
            let center = transform.viewPoint(for: CGPoint(x: transform.framedRect.midX, y: transform.framedRect.midY))
            #expect(abs(center.x - 500) < 0.001 && abs(center.y - 400) < 0.001)
            #expect(transform.visibleBoardRect(viewportSize: viewport).insetBy(dx: -0.01, dy: -0.01).contains(transform.framedRect))
        }
        let merged = plan.stepTransforms[1]
        #expect(abs(merged.scale - min(1.3, 1000 / 390)) < 0.0001)
    }

    // MARK: Determinism

    @Test func layoutIsDeterministic() {
        for seed in UInt64(100)...110 {
            let input = randomBoard(seed: seed)
            #expect(WBBoardLayoutEngine.layout(input).serialized() == WBBoardLayoutEngine.layout(input).serialized())
        }
        // Fixed sizes, so the golden doesn't depend on installed fonts; it was
        // produced by another process, which is the cross-process check.
        let hinted = CGSize(width: 100, height: 40)
        let input = WBLayoutInput(nodes: [
            WBLayoutNode(id: "a", kind: .box, sizeHint: hinted), WBLayoutNode(id: "b", kind: .box, sizeHint: hinted),
            WBLayoutNode(id: "c", kind: .ellipse, sizeHint: hinted), WBLayoutNode(id: "d", kind: .box, sizeHint: hinted),
            WBLayoutNode(id: "t", kind: .chart)
        ], edges: [WBLayoutEdge(from: "a", to: "b"), WBLayoutEdge(from: "a", to: "c"), WBLayoutEdge(from: "b", to: "d"),
                   WBLayoutEdge(from: "c", to: "d"), WBLayoutEdge(from: "d", to: "a")],
        viewportSize: CGSize(width: 1000, height: 700))
        let serialized = WBBoardLayoutEngine.layout(input).serialized()
        #expect(serialized == goldenSmallBoard)
    }

    // MARK: Streaming

    @Test func streamingKeepsPlacedElementsStill() {
        let (inputs, _) = streamingBoard()
        let streaming = WBStreamingLayout()
        var previous: WBBoardLayout?
        for input in inputs {
            let layout = streaming.update(with: input)
            #expect(layoutProblems(layout).isEmpty)
            defer { previous = layout }
            guard let previous else { continue }
            let added = input.nodes.last!
            let addedEdges = input.edges.count > previous.edges.count
            for oldElement in previous.elements {
                let newRect = layout.element(id: oldElement.id)!.rect
                let addedIsFlow = !added.kind.isAlwaysGraphNode && !addedEdges && added.near == nil
                // Flow additions never move anything; nothing in another section ever moves.
                if addedIsFlow || added.section != oldElement.sectionID {
                    #expect(newRect == oldElement.rect, "\(added.id) moved \(oldElement.id)")
                }
            }
        }
        // Re-running an unchanged input is a no-op.
        #expect(streaming.update(with: inputs.last!) == streaming.latest!)
    }

    @Test func relayoutIsFast() {
        var nodes: [WBLayoutNode] = []
        var edges: [WBLayoutEdge] = []
        for index in 0..<40 {
            nodes.append(WBLayoutNode(id: "n\(index)", kind: index % 7 == 0 ? .ellipse : .box, section: index < 24 ? "a" : "b",
                                      text: "\(sampleWords[index % sampleWords.count]) \(index)"))
        }
        for index in 1..<40 {
            let parent = (index < 24) ? (index - 1) / 2 : 24 + (index - 25) / 2
            if index != 24 { edges.append(WBLayoutEdge(from: "n\(max(0, parent))", to: "n\(index)", label: index % 4 == 0 ? "step \(index)" : nil)) }
        }
        edges += [WBLayoutEdge(from: "n9", to: "n2"), WBLayoutEdge(from: "n15", to: "n4"), WBLayoutEdge(from: "n30", to: "n24")]
        let flowKinds: [WBLayoutNodeKind] = [.text, .list, .code, .chart, .table]
        for index in 0..<20 {
            let kind = flowKinds[index % flowKinds.count]
            nodes.append(WBLayoutNode(id: "f\(index)", kind: kind, section: index % 2 == 0 ? "a" : "b", text: "note \(index) about the system",
                                      items: kind == .list ? ["one", "two"] : [], rows: kind == .table ? [["k", "v"], ["a", "1"]] : []))
        }
        let input = WBLayoutInput(nodes: nodes, edges: edges, sections: [WBLayoutSection(id: "a"), WBLayoutSection(id: "b")])
        #expect(input.nodes.count == 60)
        let clock = ContinuousClock()
        let coldDuration = clock.measure { _ = WBBoardLayoutEngine.layout(input) }
        var durations: [Duration] = []
        for _ in 0..<7 { durations.append(clock.measure { _ = WBBoardLayoutEngine.layout(input) }) }
        let median = durations.sorted()[durations.count / 2]
        let streaming = WBStreamingLayout()
        streaming.update(with: input)
        var smallerInput = input
        smallerInput.nodes.append(WBLayoutNode(id: "late", kind: .text, section: "b", text: "late note"))
        let streamingDuration = clock.measure { streaming.update(with: smallerInput) }
        print("relayout 60 elements: cold \(coldDuration), median \(median), streaming flow append \(streamingDuration)")
        #expect(median < .milliseconds(50))
        #expect(layoutProblems(WBBoardLayoutEngine.layout(input)).isEmpty)
    }

    // MARK: RoughPath

    @Test func fnvAndRandomMatchTheReference() {
        #expect(RoughPath.fnv1a32("") == 0x811c_9dc5)
        #expect(RoughPath.fnv1a32("a") == 0xe40c_292c)
        #expect(RoughPath.fnv1a32("foobar") == 0xbf9c_f968)
        var random = RoughRandom(seed: 1)
        #expect(random.next() == 48271.0 / 2_147_483_648)
        #expect(random.next() == Double((UInt32(48271) &* 48271) & 0x7fff_ffff) / 2_147_483_648)
        var zeroSeeded = RoughRandom(seed: 0)
        #expect(zeroSeeded.next() > 0)
    }

    @Test func roughPathsAreDeterministicPerID() {
        let rect = CGRect(x: 10, y: 20, width: 160, height: 80)
        var first = RoughGenerator(elementID: "node-1")
        var again = RoughGenerator(elementID: "node-1")
        var other = RoughGenerator(elementID: "node-2")
        let firstOps = first.rectangle(rect)
        #expect(firstOps == again.rectangle(rect))
        #expect(firstOps != other.rectangle(rect))
        #expect(firstOps.count == 16) // 4 sides × 2 strokes × (move + curve)

        var ellipseGenerator = RoughGenerator(elementID: "e")
        var ellipseAgain = RoughGenerator(elementID: "e")
        let ellipseOps = ellipseGenerator.ellipse(in: rect)
        #expect(ellipseOps.count == 28) // 2 passes × (move + 13 curves through 16 points)
        #expect(ellipseOps == ellipseAgain.ellipse(in: rect))

        var lineGenerator = RoughGenerator(elementID: "l")
        #expect(lineGenerator.line(from: .zero, to: CGPoint(x: 100, y: 0)).count == 4)
        var curveGenerator = RoughGenerator(elementID: "edge")
        #expect(curveGenerator.curve(through: [.zero, CGPoint(x: 50, y: 80), CGPoint(x: 100, y: 160)]).count == 6)

        #expect(RoughPath.rectangle(rect, id: "x") == RoughPath.rectangle(rect, id: "x"))
        #expect(RoughPath.ellipse(in: rect, id: "x") != RoughPath.ellipse(in: rect, id: "y"))

        // Golden: the RNG and FNV are pinned, so this is stable across processes.
        var goldenGenerator = RoughGenerator(elementID: "golden")
        let goldenOps = goldenGenerator.line(from: CGPoint(x: 0, y: 0), to: CGPoint(x: 120, y: 40))
        let goldenText = goldenOps.map { op -> String in
            switch op {
            case .move(let point): return String(format: "M%.4f,%.4f", point.x, point.y)
            case .curve(let control1, let control2, let end):
                return String(format: "C%.4f,%.4f,%.4f,%.4f,%.4f,%.4f", control1.x, control1.y, control2.x, control2.y, end.x, end.y)
            }
        }.joined(separator: " ")
        #expect(goldenText == goldenRoughLine)
    }

    @Test func longLinesAreCalmer() {
        // End-point jitter ≤ roughness × gain × offset: 2 pt short, 0.8 pt past 500 pt.
        for seedIndex in 0..<50 {
            var shortGenerator = RoughGenerator(elementID: "short\(seedIndex)")
            var longGenerator = RoughGenerator(elementID: "long\(seedIndex)")
            for case .curve(_, _, let end) in shortGenerator.line(from: .zero, to: CGPoint(x: 150, y: 0)) {
                #expect(abs(end.x - 150) <= 2.0001 && abs(end.y) <= 2.0001)
            }
            for case .curve(_, _, let end) in longGenerator.line(from: .zero, to: CGPoint(x: 600, y: 0)) {
                #expect(abs(end.x - 600) <= 0.8001 && abs(end.y) <= 0.8001)
            }
        }
    }

    @Test func roughEdgesAndOutlinesFromTheLayout() {
        let layout = WBBoardLayoutEngine.layout(randomBoard(seed: 3))
        for placedEdge in layout.edges {
            let id = RoughPath.edgeID(of: placedEdge)
            #expect(RoughPath.edgeOps(of: placedEdge, id: id) == RoughPath.edgeOps(of: placedEdge, id: id))
            #expect(RoughPath.edgeOps(of: placedEdge, id: id).count >= 4 + 8) // two curve passes + two double-stroked head lines
        }
        for placedElement in layout.elements {
            #expect(RoughPath.outlineOps(of: placedElement) == RoughPath.outlineOps(of: placedElement))
        }
    }
}

private let goldenSmallBoard = """
board 0.00,0.00,1000.00,700.00 crossings 0
section  24.00,24.00,952.00,652.00
node a box graphNode  485.67,44.00,100.00,40.00 x1.00
node b box graphNode  371.00,148.00,100.00,40.00 x1.00
node c ellipse graphNode  507.00,148.00,100.00,40.00 x1.00
node d box graphNode  485.67,252.00,100.00,40.00 x1.00
node t chart flow  44.00,316.00,320.00,200.00 x1.00
edge 0 a>b 513.62,84.00 443.05,148.00
edge 1 a>c 539.77,84.00 552.91,148.07
edge 2 b>d 443.05,188.00 513.62,252.00
edge 3 c>d 552.91,187.93 539.77,252.00
edge 4 d>a 553.62,252.00 629.00,168.00 553.62,84.00
"""
private let goldenRoughLine = "M1.5828,-1.3959 C27.2245,8.5726,51.3745,18.7958,121.9371,38.7122 M-0.0508,-0.4325 C25.9516,6.8892,51.3460,15.0034,119.2626,39.4656"
