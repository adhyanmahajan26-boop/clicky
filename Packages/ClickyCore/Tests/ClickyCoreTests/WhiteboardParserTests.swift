import Foundation
import Testing
@testable import ClickyCore

// MARK: - Helpers

private func parseBoard(_ text: String) -> WBParseOutcome {
    WBStreamParser.parse(text)
}

private func parseSplit(_ text: String, atScalarOffset splitOffset: Int) -> WBParseOutcome {
    let scalars = Array(text.unicodeScalars)
    var firstPart = String.UnicodeScalarView()
    firstPart.append(contentsOf: scalars[..<splitOffset])
    var secondPart = String.UnicodeScalarView()
    secondPart.append(contentsOf: scalars[splitOffset...])
    var parser = WBStreamParser()
    parser.feed(String(firstPart))
    parser.feed(String(secondPart))
    return parser.finish()
}

private func parseScalarByScalar(_ text: String) -> WBParseOutcome {
    var parser = WBStreamParser()
    for scalar in text.unicodeScalars { parser.feed(String(scalar)) }
    return parser.finish()
}

private func box(_ outcome: WBParseOutcome, _ elementIdentifier: String) -> WBBox? {
    if case .box(let box)? = outcome.board.element(withIdentifier: elementIdentifier)?.payload { return box }
    return nil
}

private func arrow(_ outcome: WBParseOutcome, _ elementIdentifier: String) -> WBArrow? {
    if case .arrow(let arrow)? = outcome.board.element(withIdentifier: elementIdentifier)?.payload { return arrow }
    return nil
}

private func flow(_ source: String) -> WBFlow {
    MermaidFlowParser.parse(source, flowIdentifier: "f", sectionIdentifier: "s")
}

private func flowBox(_ flow: WBFlow, _ nodeIdentifier: String) -> WBBox? {
    if case .box(let box)? = flow.elements.first(where: { $0.id == "f.\(nodeIdentifier)" })?.payload { return box }
    return nil
}

private func flowArrows(_ flow: WBFlow) -> [WBArrow] {
    flow.elements.compactMap { element in
        if case .arrow(let arrow) = element.payload { return arrow }
        return nil
    }
}

private let header = #"{"wb":1,"title":"TCP","dir":"LR","sections":[{"id":"agenda","title":"Agenda"},{"id":"q1","title":"Handshake","q":"how does tcp connect?"},{"id":"recap","title":"Recap"}]}"#

/// Boards used for the split-invariance checks: clean, broken, wrapped, pretty.
private let invarianceBoards: [String] = [
    header + "\n" + #"""
    {"el":"list","id":"ag","sec":"agenda","items":["handshake","recap"]}
    {"el":"box","id":"c","sec":"q1","text":"Client","color":"blue","icon":"laptopcomputer"}
    {"el":"box","id":"s","text":"Server \"main\"","shape":"cyl"}
    {"el":"arrow","id":"a1","from":"c","to":"s","text":"SYN","style":"dashed"}
    {"step":1,"show":["ag"],"say":"here's the plan"}
    {"step":2,"show":["c","s","a1"],"say":"the client says hi to the server","cue":{"s":"server","c":"client"}}
    """#,
    #"""
    text before {"el":"box","id":"a","text":"one",} junk {“el”:“box”,“id”:“b”,“text”:“two”}
    [{"el":"box","id":"c"}{"el":"box","id":"d"}]
    {'el':'text','id':'e','text':'single'}
    {"el":"box","id":"f","text":"no close"
    {"el":"code","id":"g","lang":"py","text":"print(1)
    print(2)"}
    {"step":1,"show":["a","b","zz"],"say":"émoji 🎉 ok"}
    {"el":"box","id":"h","text":"trunc
    """#,
    #"""
    {
      "title": "Wrapped",
      "dir": "TB",
      "sections": [{"id": "q1", "title": "One"}],
      "elements": [
        {"el": "rect", "id": "x", "text": 42},
        {"el": "edge", "from": "x", "to": "ghost_box"},
        {"el": "mermaid", "id": "fl", "src": "graph TD\nA[Start] --> B{Ok?}\nB -- yes --> C((Done))"}
      ],
      "steps": [{"show": ["x", "fl"], "say": "look"}]
    }
    """#
]

// MARK: - Repair ladder

@Suite("Whiteboard repair ladder")
struct WhiteboardRepairTests {
    @Test func strictJSONUsesTheFirstRung() {
        let result = WBRepair.repair(#"{"el":"box","id":"a"}"#)
        #expect(result.rung == .strict)
        #expect(result.values.count == 1)
    }

    @Test func trailingCommasAreStripped() {
        let result = WBRepair.repair(#"{"el":"list","id":"a","items":["x","y",],}"#)
        #expect(result.rung == .trailingCommas)
        #expect(result.values.first?["items"] == .array([.string("x"), .string("y")]))
    }

    @Test func trailingCommaInsideAStringIsKept() {
        let result = WBRepair.repair(#"{"text":"a, }"}"#)
        #expect(result.rung == .strict)
        #expect(result.values.first?["text"] == .string("a, }"))
    }

    @Test func balanceClosesStringAndBrackets() {
        let result = WBRepair.repair(#"{"el":"list","id":"a","items":["x","y"#)
        #expect(result.rung == .balanced)
        #expect(result.values.first?["items"] == .array([.string("x"), .string("y")]))
        #expect(WBRepair.balance(#"{"a":{"b":[1,2"#) == #"{"a":{"b":[1,2]}}"#)
        #expect(WBRepair.balance(#"{"a":1,"b""#) == #"{"a":1,"b":null}"#)
        #expect(WBRepair.balance(#"{"a":"#) == #"{"a":null}"#)
        #expect(WBRepair.balance(#"{"a":"x\"#) == #"{"a":"x"}"#)
    }

    @Test func balanceEscapesRawNewlinesInStrings() {
        let result = WBRepair.repair("{\"text\":\"line one\nline two\"}")
        #expect(result.rung == .balanced)
        #expect(result.values.first?["text"] == .string("line one\nline two"))
    }

    @Test func splitsBackToBackObjects() {
        let result = WBRepair.repair(#"{"id":"a"}{"id":"b"}"#)
        #expect(result.rung == .splitObjects)
        #expect(result.values == [.object(["id": .string("a")]), .object(["id": .string("b")])])
        let arrayResult = WBRepair.repair(#"[{"id":"a"} {"id":"b"}]"#)
        #expect(arrayResult.rung == .splitObjects)
        #expect(arrayResult.values == [.array([.object(["id": .string("a")]), .object(["id": .string("b")])])])
    }

    @Test func smartQuotesBecomeASCII() {
        let result = WBRepair.repair("{\u{201C}el\u{201D}:\u{201C}box\u{201D},\u{201C}id\u{201D}:\u{201C}a\u{201D}}")
        #expect(result.rung == .smartQuotes)
        #expect(result.values.first?["el"] == .string("box"))
    }

    @Test func singleQuotesOnlyWithoutDoubleQuotes() {
        let result = WBRepair.repair("{'el':'box','id':'a'}")
        #expect(result.rung == .singleQuotes)
        #expect(result.values.first?["id"] == .string("a"))
        #expect(WBRepair.repair(#"{'el':"box"}"#).rung == .failed)
    }

    @Test func hopelessTextFails() {
        #expect(WBRepair.repair("{el: box}").rung == .failed)
        let outcome = parseBoard("{el: box}\n" + #"{"el":"box","id":"a"}"#)
        #expect(outcome.stats.count(for: .failed) == 1)
        #expect(outcome.stats.droppedCount == 1)
        #expect(outcome.board.elements.map(\.id) == ["a"])
    }
}

// MARK: - Scanner

@Suite("Whiteboard scanner")
struct WhiteboardScannerTests {
    @Test func emitsEachValueAsSoonAsItCloses() {
        var scanner = WBScanner()
        #expect(scanner.feed(#"noise {"a":"}{[" "#).isEmpty)
        let closed = scanner.feed(#"} more [1,[2]] tail {"b":"#)
        #expect(closed.map(\.text) == [#"{"a":"}{[" }"#, "[1,[2]]"])
        #expect(scanner.finish() == [WBScannedValue(text: #"{"b":null}"#, wasClosedByScanner: true)])
    }

    @Test func aLineMissingItsCloseDoesNotSwallowTheNext() {
        var scanner = WBScanner()
        let values = scanner.feed("{\"el\":\"box\",\"id\":\"a\"\n{\"el\":\"box\",\"id\":\"b\"}\n")
        #expect(values == [
            WBScannedValue(text: "{\"el\":\"box\",\"id\":\"a\"\n}", wasClosedByScanner: true),
            WBScannedValue(text: #"{"el":"box","id":"b"}"#)
        ])
    }

    @Test func nestedObjectAfterColonIsNotSplit() {
        var scanner = WBScanner()
        let values = scanner.feed("{\"step\":1,\"cue\":\n  {\"a\":\"x\"}}")
        #expect(values.count == 1)
        #expect(values[0].wasClosedByScanner == false)
    }
}

// MARK: - Normalizer goldens

@Suite("Whiteboard normalizer")
struct WhiteboardNormalizerTests {
    @Test func cleanBoardParses() {
        let outcome = parseBoard(invarianceBoards[0])
        #expect(outcome.board.title == "TCP")
        #expect(outcome.board.direction == .leftToRight)
        #expect(outcome.board.sections.map(\.id) == ["agenda", "q1", "recap"])
        #expect(outcome.board.sections[1].question == "how does tcp connect?")
        #expect(outcome.board.elements.map(\.id) == ["ag", "c", "s", "a1"])
        // Missing sec = the last seen section.
        #expect(outcome.board.element(withIdentifier: "s")?.sectionIdentifier == "q1")
        #expect(box(outcome, "s") == WBBox(text: "Server \"main\"", shape: .cyl))
        #expect(box(outcome, "c")?.icon == "laptopcomputer")
        #expect(arrow(outcome, "a1") == WBArrow(fromIdentifier: "c", toIdentifier: "s", text: "SYN", style: .dashed, head: .end))
        #expect(outcome.board.steps.count == 2)
        // Cues sorted by where their word is said.
        #expect(outcome.board.steps[1].cues == [WBCue(elementIdentifier: "c", word: "client"), WBCue(elementIdentifier: "s", word: "server")])
        #expect(outcome.stats.count(for: .strict) == 7)
        #expect(outcome.stats.droppedCount == 0)
        #expect(outcome.isUsable)
    }

    @Test func noCloseTagAndTruncatedLastLine() {
        let answer = "sure, here it is.\n<whiteboard>\n" + header + "\n" + #"{"el":"box","id":"a","sec":"q1","text":"Alpha"}"# + "\n" + #"{"el":"box","id":"b","text":"Bet"#
        let outcome = parseBoard(WBBlockExtractor.whiteboardBody(in: answer))
        #expect(outcome.board.elements.map(\.id) == ["a", "b"])
        #expect(box(outcome, "b")?.text == "Bet")
        #expect(outcome.stats.count(for: .balanced) == 1)
        #expect(outcome.isUsable)
    }

    @Test func blockExtractorTakesEveryBlockOrTheWholeText() {
        #expect(WBBlockExtractor.whiteboardBody(in: "a <WHITEBOARD>x</whiteboard> b <whiteboard>y</whiteboard>") == "x\ny")
        #expect(WBBlockExtractor.whiteboardBody(in: "{\"el\":\"box\"}") == "{\"el\":\"box\"}")
        #expect(WBBlockExtractor.whiteboardBody(in: "hi <whiteboard>\nz") == "\nz")
    }

    @Test func prettyPrintedMultiLineJSON() {
        let text = """
        {
          "wb": 1,
          "title": "Pretty",
          "sections": [
            {"id": "q1", "title": "One"}
          ]
        }
        {
          "el": "table",
          "id": "t",
          "sec": "q1",
          "cols": ["a", "b"],
          "rows": [
            ["1", 2],
            ["3"]
          ]
        }
        {
          "step": 1,
          "show": ["t"],
          "cue": {
            "t": "table"
          },
          "say": "a table"
        }
        """
        let outcome = parseBoard(text)
        #expect(outcome.board.title == "Pretty")
        guard case .table(let table)? = outcome.board.element(withIdentifier: "t")?.payload else {
            Issue.record("no table")
            return
        }
        #expect(table == WBTable(columns: ["a", "b"], rows: [["1", "2"], ["3", ""]]))
        #expect(outcome.board.steps.first?.cues == [WBCue(elementIdentifier: "t", word: "table")])
        #expect(outcome.stats.count(for: .strict) == 3)
    }

    @Test func wrapperObjectAndTopLevelArray() {
        let outcome = parseBoard(invarianceBoards[2])
        #expect(outcome.board.title == "Wrapped")
        #expect(outcome.board.elements.map(\.id) == ["x", "auto_1", "fl", "ghost_box"])
        #expect(box(outcome, "x")?.text == "42")
        #expect(box(outcome, "ghost_box") == WBBox(text: "ghost box", isPlaceholder: true))
        #expect(outcome.board.steps.count == 1)
        #expect(outcome.board.steps[0].shownIdentifiers == ["x", "fl", "auto_1", "ghost_box"])

        let arrayOutcome = parseBoard(#"[{"el":"box","id":"a"},{"el":"box","id":"b"},{"step":1,"show":["a","b"]}]"#)
        #expect(arrayOutcome.board.elements.map(\.id) == ["a", "b"])
        #expect(arrayOutcome.board.steps.map(\.shownIdentifiers) == [["a", "b"]])
    }

    @Test func elementKindSynonyms() {
        let synonymKinds: [(String, WBElementKind)] = [
            ("rect", .box), ("node", .box), ("shape", .box),
            ("line", .arrow), ("edge", .arrow), ("link", .arrow),
            ("note", .text), ("label", .text), ("caption", .text),
            ("bullets", .list),
            ("latex", .math), ("formula", .math), ("equation", .math),
            ("graph", .chart), ("plot", .chart),
            ("mermaid", .flow),
            ("sparkle", .text)
        ]
        var lines = [#"{"el":"box","id":"a"}"#, #"{"el":"box","id":"b"}"#]
        for (index, (synonym, _)) in synonymKinds.enumerated() {
            lines.append(#"{"el":"\#(synonym)","id":"k\#(index)","text":"T","from":"a","to":"b","items":["i"],"tex":"x^2","data":[["q",1]],"src":"graph LR\nA-->B"}"#)
        }
        let outcome = parseBoard(lines.joined(separator: "\n"))
        for (index, (synonym, expectedKind)) in synonymKinds.enumerated() {
            #expect(outcome.board.element(withIdentifier: "k\(index)")?.kind == expectedKind, "\(synonym)")
        }
    }

    @Test func fieldValuesAreSnapped() {
        let outcome = parseBoard(#"""
        {"el":"box","id":"a","text":12.5,"color":"grey","shape":"database","icon":"Bad Icon!"}
        {"el":"box","id":"b","color":"teal","shape":"rounded"}
        {"el":"box","id":"c","color":"chartreuse-ish"}
        {"el":"box","id":"d","color":"light green"}
        {"el":"box","id":"e","color":"#d32f2f"}
        {"el":"box","id":"f","text":"\#(String(repeating: "x", count: 100))"}
        {"el":"chart","id":"g","kind":"donut","data":[["a","3"],["b",4.5],["c","n/a"]]}
        {"el":"code","id":"h","text":"a\nb\nc","hl":["2",9,"1-2"]}
        {"el":"math","id":"i","tex":"$$E=mc^2$$"}
        {"el":"text","id":"j","text":"hi","size":24,"near":"a","pos":"below"}
        {"el":"callout","id":"k","target":"nope","style":"warn","text":"careful"}
        """#)
        #expect(box(outcome, "a") == WBBox(text: "12.5", shape: .cyl, color: .gray))
        #expect(box(outcome, "b")?.color == .blue)
        #expect(box(outcome, "b")?.shape == .round)
        #expect(box(outcome, "c")?.color == .gray)
        #expect(box(outcome, "d")?.color == .green)
        #expect(box(outcome, "e")?.color == .red)
        #expect(box(outcome, "f")?.text.count == WBBox.maximumTextLength)
        #expect(outcome.board.element(withIdentifier: "g")?.payload == .chart(WBChart(kind: .pie, points: [WBChartPoint(label: "a", value: 3), WBChartPoint(label: "b", value: 4.5)])))
        #expect(outcome.board.element(withIdentifier: "h")?.payload == .code(WBCode(text: "a\nb\nc", highlightedLines: [1, 2])))
        #expect(outcome.board.element(withIdentifier: "i")?.payload == .math(WBMath(tex: "E=mc^2")))
        #expect(outcome.board.element(withIdentifier: "j")?.payload == .text(WBText(text: "hi", size: .large, nearIdentifier: "a", position: .bottom)))
        #expect(outcome.board.element(withIdentifier: "k")?.payload == .callout(WBCallout(style: .warning, text: "careful")))
        #expect(outcome.stats.droppedReferenceCount == 1)
    }

    @Test func symbolCheckIsInjected() {
        let text = #"{"el":"box","id":"a","icon":"star.fill"}"# + "\n" + #"{"el":"box","id":"b","icon":"made.up"}"#
        let outcome = WBStreamParser.parse(text, isValidSymbol: { $0 == "star.fill" })
        #expect(box(outcome, "a")?.icon == "star.fill")
        #expect(box(outcome, "b")?.icon == nil)
        #expect(box(parseBoard(text), "b")?.icon == "made.up")
    }

    @Test func missingAndDuplicateIdentifiers() {
        let outcome = parseBoard(#"""
        {"el":"box","id":"a"}
        {"el":"box","id":"a"}
        {"el":"box"}
        {"el":"box","id":"a"}
        {"el":"box","id":"we ird!"}
        {"el":"box","id":"auto_1"}
        {"el":"box"}
        """#)
        #expect(outcome.board.elements.map(\.id) == ["a", "a_2", "auto_1", "a_3", "we_ird_", "auto_1_2", "auto_2"])
    }

    @Test func danglingArrows() {
        let outcome = parseBoard(#"""
        {"el":"box","id":"a"}
        {"el":"arrow","id":"toLoad","from":"a","to":"load_balancer"}
        {"el":"arrow","id":"toB","from":"a","to":"b"}
        {"el":"arrow","id":"toB2","from":"x9","to":"a"}
        {"el":"arrow","id":"again","from":"load_balancer","to":"a","head":"both"}
        """#)
        #expect(outcome.board.elements.map(\.id) == ["a", "toLoad", "again", "load_balancer"])
        #expect(box(outcome, "load_balancer") == WBBox(text: "load balancer", isPlaceholder: true))
        #expect(arrow(outcome, "again")?.head == .both)
        #expect(outcome.stats.droppedCount == 2)
        #expect(outcome.stats.droppedReasons == ["dangling arrow toB", "dangling arrow toB2"])
    }

    @Test func stepsBeforeTheirElements() {
        let outcome = parseBoard(#"""
        {"step":5,"show":["b"],"say":"second thing","point":"b","focus":"b"}
        {"step":2,"show":["a","nope"],"hl":["a","ghost"],"say":"first","focus":"board"}
        {"el":"box","id":"a","sec":"q1"}
        {"el":"box","id":"b","sec":"q2"}
        {"el":"box","id":"c"}
        """#)
        #expect(outcome.board.steps.map(\.number) == [1, 2])
        #expect(outcome.board.steps[0].shownIdentifiers == ["b"])
        #expect(outcome.board.steps[0].pointIdentifier == "b")
        #expect(outcome.board.steps[0].focus == .element("b"))
        // Unknown ids dropped; never-shown "c" joins the last step.
        #expect(outcome.board.steps[1].shownIdentifiers == ["a", "c"])
        #expect(outcome.board.steps[1].highlightedIdentifiers == ["a"])
        #expect(outcome.board.steps[1].focus == .board)
        #expect(outcome.stats.droppedReferenceCount == 2)
        // Unknown sec = a new section; missing sec = the current one.
        #expect(outcome.board.sections.map(\.id) == ["q1", "q2"])
        #expect(outcome.board.element(withIdentifier: "c")?.sectionIdentifier == "q2")
    }

    @Test func noStepsMakesOneStepPerSection() {
        let outcome = parseBoard(header + "\n" + #"""
        {"el":"box","id":"a","sec":"q1"}
        {"el":"box","id":"b","sec":"agenda"}
        {"el":"box","id":"c","sec":"q1"}
        """#)
        #expect(outcome.board.steps == [
            WBStep(number: 1, shownIdentifiers: ["b"], focus: .section("agenda")),
            WBStep(number: 2, shownIdentifiers: ["a", "c"], focus: .section("q1"))
        ])
    }

    @Test func noHeaderAndNoSectionUsesMain() {
        let outcome = parseBoard(#"{"el":"box","id":"a"}"#)
        #expect(outcome.board.sections == [WBSection(id: "main", title: "")])
        #expect(outcome.board.steps.map(\.shownIdentifiers) == [["a"]])
    }

    @Test func limitsAreEnforcedAndCounted() {
        var lines: [String] = []
        for elementNumber in 1...70 { lines.append(#"{"el":"box","id":"b\#(elementNumber)"}"#) }
        for stepNumber in 1...25 { lines.append(#"{"step":\#(stepNumber),"show":["b\#(stepNumber)"]}"#) }
        let outcome = parseBoard(lines.joined(separator: "\n"))
        #expect(outcome.board.elements.count == 60)
        #expect(outcome.board.elements.last?.id == "b60")
        #expect(outcome.board.steps.count == 20)
        #expect(outcome.stats.droppedCount == 15)
        #expect(outcome.stats.itemCount == 95)
        #expect(!outcome.stats.isTooBroken)
        // Elements of dropped steps join the last step.
        #expect(outcome.board.steps.last?.shownIdentifiers.count == 41)
    }

    @Test func moreThanEightSectionsOverflowToPageTwo() {
        var lines: [String] = []
        for sectionNumber in 1...10 { lines.append(#"{"el":"box","id":"b\#(sectionNumber)","sec":"s\#(sectionNumber)"}"#) }
        let outcome = parseBoard(lines.joined(separator: "\n"))
        #expect(outcome.board.sections.map(\.page) == [1, 1, 1, 1, 1, 1, 1, 1, 2, 2])
        #expect(outcome.board.pageCount == 2)
    }

    @Test func headerAfterElementsNamesTheirSections() {
        let outcome = parseBoard(#"{"el":"box","id":"a","sec":"q1"}"# + "\n" + header)
        #expect(outcome.board.sections.map(\.id) == ["q1", "agenda", "recap"])
        #expect(outcome.board.sections[0].title == "Handshake")
        #expect(outcome.board.title == "TCP")
    }

    @Test func tooBrokenBoards() {
        #expect(parseBoard("no json here").stats.isTooBroken)
        #expect(!parseBoard("no json here").isUsable)
        let mostlyBroken = parseBoard(#"{"el":"box","id":"a"}"# + "\n{x}\n{y}\n{\"what\":1}")
        #expect(mostlyBroken.stats.droppedCount == 3)
        #expect(mostlyBroken.stats.isTooBroken)
    }

    @Test func provisionalBoardWhileStreaming() {
        var parser = WBStreamParser()
        parser.feed(#"{"el":"arrow","id":"r","from":"a","to":"b"}"# + "\n" + #"{"el":"box","id":"a"}"# + "\n" + #"{"el":"box","id":"b","text":"Bee"#)
        #expect(parser.provisionalBoard.elements.map(\.id) == ["a"])
        parser.feed("\"}\n")
        #expect(parser.provisionalBoard.elements.map(\.id) == ["r", "a", "b"])
        #expect(parser.finish().board.elements.map(\.id) == ["r", "a", "b"])
    }

    @Test func messyBoardGolden() {
        let outcome = parseBoard(invarianceBoards[1])
        #expect(outcome.board.elements.map(\.id) == ["a", "b", "c", "d", "e", "f", "g", "h"])
        #expect(box(outcome, "b")?.text == "two")
        #expect(box(outcome, "f")?.text == "no close")
        #expect(outcome.board.element(withIdentifier: "g")?.payload == .code(WBCode(language: "py", text: "print(1)\nprint(2)")))
        #expect(box(outcome, "h")?.text == "trunc")
        #expect(outcome.board.steps.first?.say == "émoji 🎉 ok")
        #expect(outcome.stats.count(for: .trailingCommas) == 1)
        #expect(outcome.stats.count(for: .smartQuotes) == 1)
        #expect(outcome.stats.count(for: .splitObjects) == 1)
        #expect(outcome.stats.count(for: .singleQuotes) == 1)
        #expect(outcome.stats.count(for: .balanced) == 3)
        #expect(outcome.stats.droppedCount == 0)
    }
}

// MARK: - Split invariance

@Suite("Whiteboard split invariance")
struct WhiteboardSplitInvarianceTests {
    @Test(arguments: invarianceBoards.indices)
    func splittingAnywhereGivesTheSameBoard(boardIndex: Int) {
        let text = invarianceBoards[boardIndex]
        let wholeOutcome = parseBoard(text)
        let scalarCount = text.unicodeScalars.count
        for splitOffset in 0...scalarCount {
            let splitOutcome = parseSplit(text, atScalarOffset: splitOffset)
            if splitOutcome != wholeOutcome {
                Issue.record("board \(boardIndex) differs when split at \(splitOffset)")
                return
            }
        }
        #expect(parseScalarByScalar(text) == wholeOutcome)
    }
}

// MARK: - Mermaid

@Suite("Mermaid flow parser")
struct MermaidFlowParserTests {
    @Test func headerAndDirections() {
        #expect(flow("flowchart LR\nA-->B").direction == .leftToRight)
        #expect(flow("graph RL\nA-->B").direction == .leftToRight)
        #expect(flow("graph TD\nA-->B").direction == .topToBottom)
        #expect(flow("flowchart BT\nA-->B").direction == .topToBottom)
        #expect(flow("flowchart TB\nA-->B").direction == .topToBottom)
        #expect(flow("A-->B").elements.count == 3)
    }

    @Test func nodeShapes() {
        let parsedFlow = flow("""
        flowchart TB
        A[Rect] --> B(Round)
        C([Pill]) --> D{Diamond}
        E((Circle)) --> F[(Database)]
        G["quoted [x] label"]
        H
        """)
        #expect(flowBox(parsedFlow, "A") == WBBox(text: "Rect", shape: .rect))
        #expect(flowBox(parsedFlow, "B") == WBBox(text: "Round", shape: .round))
        #expect(flowBox(parsedFlow, "C") == WBBox(text: "Pill", shape: .pill))
        #expect(flowBox(parsedFlow, "D") == WBBox(text: "Diamond", shape: .diamond))
        #expect(flowBox(parsedFlow, "E") == WBBox(text: "Circle", shape: .circle))
        #expect(flowBox(parsedFlow, "F") == WBBox(text: "Database", shape: .cyl))
        #expect(flowBox(parsedFlow, "G")?.text == "quoted [x] label")
        #expect(flowBox(parsedFlow, "H") == WBBox(text: "H", shape: .rect))
        #expect(parsedFlow.elements.first?.id == "f.A")
        #expect(parsedFlow.elements.allSatisfy { $0.sectionIdentifier == "s" })
    }

    @Test func linkStyles() {
        let arrows = flowArrows(flow("graph LR\nA --> B\nB --- C\nC -.-> D\nD ==> E\nE <--> F\nF ---> G"))
        #expect(arrows.map(\.style) == [.solid, .solid, .dashed, .thick, .solid, .solid])
        #expect(arrows.map(\.head) == [.end, .none, .end, .end, .both, .end])
        #expect(arrows[0] == WBArrow(fromIdentifier: "f.A", toIdentifier: "f.B"))
    }

    @Test func linkLabels() {
        let arrows = flowArrows(flow("graph LR\nA -->|yes| B\nB -- no way --> C\nC -. maybe .-> D\nD == sure ==> E\nE --- |plain| F"))
        #expect(arrows.map(\.text) == ["yes", "no way", "maybe", "sure", "plain"])
        #expect(arrows.map(\.style) == [.solid, .solid, .dashed, .thick, .solid])
        #expect(arrows.map(\.head) == [.end, .end, .end, .end, .none])
    }

    @Test func chainsAndAmpersands() {
        let chainFlow = flow("graph TD\nA[One] --> B[Two] --> C[Three]")
        #expect(flowArrows(chainFlow).map { "\($0.fromIdentifier)>\($0.toIdentifier)" } == ["f.A>f.B", "f.B>f.C"])
        #expect(chainFlow.elements.map(\.id) == ["f.A", "f.B", "f.C", "f.e1", "f.e2"])
        let groupFlow = flow("graph TD\nA & B --> C & D")
        #expect(flowArrows(groupFlow).map { "\($0.fromIdentifier)>\($0.toIdentifier)" } == ["f.A>f.C", "f.A>f.D", "f.B>f.C", "f.B>f.D"])
    }

    @Test func commentsSemicolonsAndIgnoredLines() {
        let parsedFlow = flow("""
        %% a comment
        graph LR; A-->B; %% trailing
        classDef hot fill:#f00
        class A hot
        style B fill:#0f0
        B:::hot --> C
        click C callback
        """)
        #expect(parsedFlow.direction == .leftToRight)
        #expect(parsedFlow.elements.compactMap { if case .box(let box) = $0.payload { return box.text } else { return nil } } == ["A", "B", "C"])
        #expect(flowArrows(parsedFlow).count == 2)
    }

    @Test func subgraphsBecomeGroups() {
        let parsedFlow = flow("""
        flowchart TB
        subgraph client [Client side]
          A[Browser] --> B[Cache]
        end
        subgraph Server farm
          C[API]
          subgraph db
            D[(Postgres)]
          end
        end
        B --> C --> D
        A --> E
        """)
        #expect(parsedFlow.groups == [
            WBFlowGroup(id: "f.client", title: "Client side", memberIdentifiers: ["f.A", "f.B"]),
            WBFlowGroup(id: "f.g2", title: "Server farm", memberIdentifiers: ["f.C"]),
            WBFlowGroup(id: "f.db", title: "db", memberIdentifiers: ["f.D"])
        ])
        #expect(flowBox(parsedFlow, "E") != nil)
    }

    @Test func laterShapeDefinitionWinsOverBareMention() {
        let parsedFlow = flow("graph TD\nA --> B\nB{Choice}")
        #expect(flowBox(parsedFlow, "B") == WBBox(text: "Choice", shape: .diamond))
    }

    @Test func flowElementOnTheBoard() {
        let outcome = parseBoard(#"""
        {"el":"flow","id":"fl","sec":"q1","src":"graph LR\nA[Client] --> B[Server]"}
        {"el":"arrow","id":"x","from":"fl.B","to":"fl"}
        {"step":1,"show":["fl"],"hl":["fl.A"]}
        """#)
        guard case .flow(let boardFlow)? = outcome.board.element(withIdentifier: "fl")?.payload else {
            Issue.record("no flow")
            return
        }
        #expect(boardFlow.elements.map(\.id) == ["fl.A", "fl.B", "fl.e1"])
        #expect(arrow(outcome, "x")?.fromIdentifier == "fl.B")
        #expect(outcome.board.steps[0].highlightedIdentifiers == ["fl.A"])
    }
}

// MARK: - Round trip and repair request

@Suite("Whiteboard JSONL and repair request")
struct WhiteboardSerializationTests {
    @Test func jsonlRoundTrip() {
        let richBoard = header + "\n" + #"""
        {"el":"box","id":"a","sec":"q1","text":"Client \"A\"\nnext","shape":"pill","color":"green","icon":"star"}
        {"el":"box","id":"a","sec":"q1"}
        {"el":"arrow","from":"a","to":"server_x","text":"SYN","style":"thick","head":"both"}
        {"el":"text","id":"t","text":"note","size":"xl","near":"a","pos":"left"}
        {"el":"list","id":"l","sec":"agenda","title":"Plan","items":["one","two"],"ordered":true}
        {"el":"code","id":"c","lang":"swift","text":"  let a = 1\n  print(a)","hl":[2]}
        {"el":"math","id":"m","tex":"\\frac{a}{b}"}
        {"el":"chart","id":"ch","kind":"line","title":"Growth","data":[["y1",1],["y2",2.25],["y3",1e-5]]}
        {"el":"table","id":"tb","cols":["k","v"],"rows":[["x","1"]]}
        {"el":"callout","id":"co","target":"a","style":"tip","text":"look"}
        {"el":"flow","id":"fl","src":"graph LR\nA-->B"}
        {"el":"divider","id":"dv","sec":"recap"}
        {"step":1,"show":["l"],"say":"plan first","focus":"agenda"}
        {"step":2,"show":["a","a_2"],"hl":["a"],"say":"the client and the server","cue":{"server_x":"server","a":"client"},"point":"a","focus":"a"}
        """#
        let firstOutcome = parseBoard(richBoard)
        let serialized = WBJSONLSerializer.serialize(firstOutcome.board)
        let secondOutcome = parseBoard(serialized)
        #expect(secondOutcome.board == firstOutcome.board)
        #expect(secondOutcome.stats.count(for: .strict) == secondOutcome.stats.itemCount)
        #expect(WBJSONLSerializer.serialize(secondOutcome.board) == serialized)
        // Codable too.
        let encodedBoard = try! JSONEncoder().encode(firstOutcome.board)
        #expect(try! JSONDecoder().decode(WBBoard.self, from: encodedBoard) == firstOutcome.board)
    }

    @Test func repairRequestArguments() {
        let request = WBRepairRequest(brokenBoardText: "{broken", model: "opus", systemPromptFileURL: URL(fileURLWithPath: "/tmp/p.txt"))
        let arguments = request.arguments
        #expect(!arguments.contains("stream-json"))
        #expect(!arguments.contains("--include-partial-messages"))
        #expect(!arguments.contains("--input-format"))
        if let formatIndex = arguments.firstIndex(of: "--output-format") { #expect(arguments[formatIndex + 1] == "json") } else { Issue.record("no output format") }
        if let toolsIndex = arguments.firstIndex(of: "--tools") { #expect(arguments[toolsIndex + 1] == "") } else { Issue.record("no tools") }
        if let modelIndex = arguments.firstIndex(of: "--model") { #expect(arguments[modelIndex + 1] == "opus") } else { Issue.record("no model") }
        if let schemaIndex = arguments.firstIndex(of: "--json-schema") {
            #expect(arguments[schemaIndex + 1] == WBRepairRequest.boardJSONSchema)
        } else {
            Issue.record("no schema")
        }
        #expect(arguments.contains("--no-session-persistence"))
        #expect(request.workingDirectoryURL == ClaudeArgs.sessionWorkingDirectoryURL)
        #expect(request.standardInputText.hasSuffix("{broken"))
        #expect(request.environment["CLAUDE_CODE_DISABLE_CLAUDE_MDS"] == "1")
        #expect(WBRepair.strictParse(WBRepairRequest.boardJSONSchema) != nil)
    }

    @Test func repairResponseIsParsed() {
        let cliResult = #"{"type":"result","subtype":"success","is_error":false,"result":"","structured_output":{"title":"Fixed","dir":"TB","sections":[{"id":"q1","title":"One"}],"elements":[{"el":"box","id":"a","sec":"q1","text":"A"},{"el":"arrow","id":"r","from":"a","to":"b"}],"steps":[{"show":["a"],"say":"hi"}]}}"#
        let outcome = WBRepairRequest.board(fromCLIResult: cliResult)
        #expect(outcome?.board.title == "Fixed")
        #expect(outcome?.board.elements.map(\.id) == ["a"])
        #expect(outcome?.board.steps.map(\.shownIdentifiers) == [["a"]])
        #expect(WBRepairRequest.structuredOutput(fromCLIResult: #"{"type":"result","is_error":true,"result":"limit"}"#) == nil)
        #expect(WBRepairRequest.structuredOutput(fromCLIResult: "not json") == nil)
    }

    @Test func promptSectionDescribesTheContract() {
        let promptText = WhiteboardPromptSection.text
        for keyword in ["<whiteboard>", "\"wb\":1", "agenda", "recap", "cyl", "callout", "mermaid", "MODE: whiteboard", "\\n"] {
            #expect(promptText.contains(keyword), "\(keyword)")
        }
    }
}
