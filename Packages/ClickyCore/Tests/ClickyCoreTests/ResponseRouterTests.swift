import Foundation
import Testing
@testable import ClickyCore

/// Narration joined, plus the non-narration outputs in order.
private struct RouterSummary: Equatable {
    var narration = ""
    var events: [String] = []
}

private func summarize(_ outputs: [ResponseRouterOutput], into summary: inout RouterSummary) {
    for output in outputs {
        switch output {
        case .narration(let text): summary.narration += text
        case .tag(let index, let tag): summary.events.append("tag\(index):\(tag.raw)")
        case .worker(let title, let task): summary.events.append("worker:\(title):\(task)")
        case .block(let name, let body): summary.events.append("block:\(name):\(body)")
        case .unsupportedBlock(let name): summary.events.append("unsupported:\(name)")
        case .dropped(let reason, _): summary.events.append("dropped:\(reason)")
        case .codeModeToggle(let isOn): summary.events.append("codemode:\(isOn ? "on" : "off")")
        case .agentsDashboard(let command): summary.events.append("agents:\(command.rawValue)")
        case .notesCommand(let command): summary.events.append("notes:\(command.rawValue)")
        }
    }
}

private func routeWhole(_ text: String, consumers: Set<String> = []) -> RouterSummary {
    var router = ResponseRouter(blockConsumers: consumers)
    var summary = RouterSummary()
    summarize(router.feed(text), into: &summary)
    summarize(router.finish(), into: &summary)
    return summary
}

private func routeSplit(_ text: String, at splitOffset: Int, consumers: Set<String> = []) -> RouterSummary {
    var router = ResponseRouter(blockConsumers: consumers)
    var summary = RouterSummary()
    summarize(router.feed(String(text.prefix(splitOffset))), into: &summary)
    summarize(router.feed(String(text.dropFirst(splitOffset))), into: &summary)
    summarize(router.finish(), into: &summary)
    return summary
}

private func routeCharByChar(_ text: String) -> RouterSummary {
    var router = ResponseRouter()
    var summary = RouterSummary()
    for character in text { summarize(router.feed(String(character)), into: &summary) }
    summarize(router.finish(), into: &summary)
    return summary
}

let routerAnswers: [String] = [
    "click share in the toolbar [MARK:1:#57:Share], then export as pdf [MARK:2:#60:Export as PDF]. [POINT:#57:Share]",
    "the error says rate limit exceeded [MARK:underline:\"rate limit exceeded (429)\"] so wait a minute.",
    "look at items[0] in the code, it's the first one.",
    "the tab is called \"[Draft]\" [MARK:circle:\"[Draft]\":Draft tab] up top.",
    "open the menu [MARK:circle:#5:File|Edit|View menus] and pick one.",
    "on it, checking those for you.\n[WORKER:Compare plans:Look at the three pricing cards on screen and list price, seats and storage for each.]\n",
    "this one [ POINT:#5:Run] runs it.",
    "[CLEAR] okay, starting over. click run [POINT:#12:Run]",
    "here's the flow.\n<whiteboard>\nnode a -> node b\n</whiteboard>\nthat's it.",
    "use the shortcut Command-Shift-P [MARK:arrow:#3:Command palette], then type build.",
    "the value is 1203.5,788 in the cell [MARK:box:#9:Cell].",
    "point here [POINT:#57@1203,788:Share] please, at @1203.5,788 exactly.",
    "PR #12 fixes it, see [MARK:circle:\"PR #12\":PR] in the list.",
    "first [MARK:1:\"Save\"~2:Save], then [MARK:2:\"Delete\" in #12:Delete].",
    "box rows ten to twelve [MARK:box:#30-#34:Rows 10 to 12].",
    "the arrow [MARK:arrow:120,40,30,20:icon:screen2] on the other screen.",
    "nothing to point at here, html is markup. [POINT:none]",
    "escaped quote [MARK:circle:\"say \\\"hi\\\"\":Hi] works.",
    "a [mark:circle:#4:lowercase] tag and a [Point:#5:mixed] one.",
    "trailing text without a tag at the end"
]

@Test func routerOutputIsTheSameForEverySplitPoint() {
    for answer in routerAnswers {
        let whole = routeWhole(answer)
        #expect(routeCharByChar(answer) == whole, "char-by-char differs for: \(answer)")
        for splitOffset in 0...answer.count {
            #expect(routeSplit(answer, at: splitOffset) == whole, "split at \(splitOffset) differs for: \(answer)")
        }
    }
}

@Test func routerNeverSpeaksTagText() {
    for answer in routerAnswers {
        let narration = routeWhole(answer).narration
        #expect(!narration.contains("[POINT"), "\(answer)")
        #expect(!narration.uppercased().contains("[MARK"), "\(answer)")
        #expect(!narration.contains("WORKER"), "\(answer)")
        #expect(!narration.contains("<whiteboard>"), "\(answer)")
    }
}

@Test func routerVectors() {
    // Brackets inside quotes don't close the tag.
    let underline = routeWhole("see [MARK:underline:\"items[0]\"] there")
    #expect(underline.events == ["tag0:[MARK:underline:\"items[0]\"]"])
    #expect(underline.narration == "see \u{E000} there")

    // A bracketed word that isn't a tag is spoken.
    #expect(routeWhole("the \"[Draft]\" tab").narration == "the \"[Draft]\" tab")

    // "|" in a name is the note separator, not a break.
    let pipe = routeWhole("open [MARK:circle:#5:File|three menus] now")
    #expect(pipe.events.count == 1)

    // A 650-character worker task survives (under the 800 hold).
    let longTask = String(repeating: "check the screen carefully ", count: 24).prefix(650)
    let worker = routeWhole("on it.\n[WORKER:Long job:\(longTask)]\n")
    #expect(worker.events == ["worker:Long job:\(longTask.trimmingCharacters(in: .whitespaces))"])

    // An unterminated tag at the end is dropped, never spoken.
    let unterminated = routeWhole("click here [MARK:circle:#5:Sha")
    #expect(unterminated.narration == "click here ")
    #expect(unterminated.events == ["dropped:tag open at end"])

    // Optional space after "[".
    #expect(routeWhole("run [ POINT:#5]").events == ["tag0:[ POINT:#5]"])

    // A block with no consumer: "I can't do that yet", block never spoken.
    let block = routeWhole("sure.\n<whiteboard>\nboxes\n</whiteboard>\n")
    #expect(block.events == ["unsupported:whiteboard"])
    #expect(block.narration.contains(ResponseRouter.unsupportedBlockSentence))
    #expect(!block.narration.contains("boxes"))
    // With a consumer it's handed over.
    #expect(routeWhole("sure.\n<whiteboard>\nboxes\n</whiteboard>\n", consumers: ["whiteboard"]).events == ["block:whiteboard:\nboxes\n"])

    // [MARK:#57:Share] (no style) is malformed in the v2 grammar? It parses as a mark with an id target.
    let noStyle = routeWhole("click [MARK:#57:Share] it")
    #expect(noStyle.narration == "click \u{E000} it" || noStyle.events.first?.hasPrefix("dropped") == true)

    // Bare numbers stay; "@x,y" coordinates are removed.
    #expect(routeWhole("the value 1203.5,788 is fine").narration == "the value 1203.5,788 is fine")
    #expect(routeWhole("at @1203.5,788 exactly").narration == "at  exactly")

    // Over-long tag: dropped, and the rest of it never leaks.
    let hugeName = String(repeating: "x", count: 900)
    let overflow = routeWhole("a [MARK:circle:#5:\(hugeName)] b")
    #expect(!overflow.narration.contains("xxx"))
    #expect(overflow.narration.hasPrefix("a "))
    #expect(overflow.narration.hasSuffix(" b"))

    // At most four workers.
    let workers = (1...6).map { "[WORKER:Job \($0):do part \($0)]" }.joined(separator: "\n")
    #expect(routeWhole("on it.\n" + workers + "\n").events.filter { $0.hasPrefix("worker:") }.count == 4)

    // Stray head without "[" is removed.
    #expect(routeWhole("click POINT:#5] now").narration == "click  now")
}
