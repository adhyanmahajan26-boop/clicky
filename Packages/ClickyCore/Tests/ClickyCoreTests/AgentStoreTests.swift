import AppKit
import Foundation
import SwiftUI
import Testing
@testable import ClickyCore

/// The Agents dashboard's store: upsert / log / finish / cancel, history
/// trimming, persistence round trips, usage parsing and totals, the
/// [AGENTS:open] tag, and offscreen renders of the dashboard (light + dark).
struct AgentStoreTests {
    static let start = Date(timeIntervalSince1970: 1_761_400_000)

    static func record(_ id: String, kind: AgentKind = .worker, status: AgentStatus = .running, startOffset: TimeInterval = 0, endOffset: TimeInterval? = nil) -> AgentRecord {
        AgentRecord(id: id, kind: kind, title: "Agent \(id)", model: "haiku", status: status, startedAt: start.addingTimeInterval(startOffset),
                    endedAt: endOffset.map { start.addingTimeInterval($0) })
    }

    // MARK: - Changes

    @Test func upsertAddsThenReplacesInPlace() {
        var store = AgentStore()
        store.upsert(Self.record("a"))
        store.upsert(Self.record("b"))
        var replacement = Self.record("a")
        replacement.title = "Renamed"
        store.upsert(replacement)
        #expect(store.records.map(\.id) == ["a", "b"])
        #expect(store["a"]?.title == "Renamed")
    }

    @Test func logKeepsTheNewestTwentyLinesAndSplitsLines() {
        var store = AgentStore()
        store.upsert(Self.record("a"))
        for lineNumber in 1...25 { store.appendLog("a", "line \(lineNumber)", at: Self.start) }
        store.appendLog("a", "first\n\n  second  ", at: Self.start)
        let lines = store["a"]?.logLines.map(\.text) ?? []
        #expect(lines.count == AgentStore.maximumLogLines)
        #expect(lines.suffix(2) == ["first", "second"])
        #expect(lines.first == "line 8")
        let didLogMissing = store.appendLog("missing", "x")
        #expect(!didLogMissing)
        store.appendLog("a", String(repeating: "x", count: 1000))
        #expect((store["a"]?.logLines.last?.text.count ?? 0) == AgentStore.maximumLogLineLength)
    }

    @Test func finishSetsEndAddsUsageAndNeverOverwritesAFinishedAgent() {
        var store = AgentStore()
        store.upsert(Self.record("brain", kind: .brain))
        store.update("brain") { $0.phase = BrainPhase.speaking.rawValue }
        store.addUsage("brain", AgentUsage(model: "claude-sonnet", inputTokens: 100, outputTokens: 20, costUSD: 0.01))
        let end = Self.start.addingTimeInterval(12)
        let didFinish = store.finish("brain", status: .done, usage: AgentUsage(inputTokens: 50, outputTokens: 5, cacheReadTokens: 7, costUSD: 0.002), at: end)
        #expect(didFinish)
        let finished = store["brain"]
        #expect(finished?.status == .done)
        #expect(finished?.phase == BrainPhase.done.rawValue)
        #expect(finished?.endedAt == end)
        #expect(finished?.usage == AgentUsage(model: "claude-sonnet", inputTokens: 150, outputTokens: 25, cacheReadTokens: 7, costUSD: 0.012))
        #expect(finished?.elapsedSeconds(now: Self.start.addingTimeInterval(500)) == 12)

        // A late failure after the finish changes nothing.
        store.finish("brain", status: .failed, errorDescription: "late")
        #expect(store["brain"]?.status == .done)
        #expect(store["brain"]?.errorDescription == nil)
    }

    @Test func cancelEndsQueuedAndRunningAgents() {
        var store = AgentStore()
        store.upsert(Self.record("queued", kind: .codeTask, status: .queued))
        store.upsert(Self.record("brain", kind: .brain))
        store.cancel("queued")
        store.cancel("brain")
        #expect(store["queued"]?.status == .cancelled)
        #expect(store["brain"]?.phase == BrainPhase.cancelled.rawValue)
        #expect(store.runningRecords.isEmpty)
        #expect(store.recentRecords.count == 2)
    }

    @Test func historyKeepsFiftyFinishedAndEveryActiveAgent() {
        var store = AgentStore()
        for index in 0..<60 {
            store.upsert(Self.record("done\(index)", status: .done, startOffset: Double(index), endOffset: Double(index) + 0.5))
        }
        store.upsert(Self.record("running", status: .running, startOffset: -100))
        store.upsert(Self.record("queued", status: .queued, startOffset: -200))
        #expect(store.recentRecords.count == 50)
        #expect(store.recentRecords.first?.id == "done59")
        #expect(store.recentRecords.last?.id == "done10")
        #expect(store["done9"] == nil)
        #expect(store.runningRecords.map(\.id) == ["running", "queued"])

        // Finishing one more trims the oldest finished one.
        store.finish("running", status: .done, at: Self.start.addingTimeInterval(1000))
        #expect(store.recentRecords.count == 50)
        #expect(store["done10"] == nil)
        #expect(store.recentRecords.first?.id == "running")

        var smallStore = AgentStore(maximumFinishedRecords: 3)
        for index in 0..<5 { smallStore.upsert(Self.record("s\(index)", status: .failed, startOffset: Double(index), endOffset: Double(index))) }
        #expect(smallStore.records.map(\.id) == ["s2", "s3", "s4"])
    }

    @Test func runningListPutsTheBrainFirstThenRunningThenQueued() {
        var store = AgentStore()
        store.upsert(Self.record("queued", kind: .codeTask, status: .queued, startOffset: 1))
        store.upsert(Self.record("worker", kind: .worker, status: .running, startOffset: 3))
        store.upsert(Self.record("brain", kind: .brain, status: .running, startOffset: 5))
        store.upsert(Self.record("code", kind: .codeTask, status: .running, startOffset: 2))
        #expect(store.runningRecords.map(\.id) == ["brain", "code", "worker", "queued"])
        var helper = Self.record("helper")
        helper.parentID = "brain"
        store.upsert(helper)
        #expect(store.children(of: "brain").map(\.id) == ["helper"])
    }

    // MARK: - Persistence

    @Test func encodeDecodeRoundTripsAndInterruptsActiveAgents() throws {
        var store = AgentStore()
        var codeTask = Self.record("code", kind: .codeTask, status: .done, endOffset: 30)
        codeTask.repository = "octo/app"
        codeTask.branch = "clicky/pr-12"
        codeTask.worktreePath = "/tmp/wt"
        codeTask.changedFiles = ["src/a.swift", "README.md"]
        codeTask.usage = AgentUsage(model: "claude-sonnet-4", inputTokens: 1, outputTokens: 2, cacheReadTokens: 3, cacheCreationTokens: 4, costUSD: 0.5)
        codeTask.logLines = [AgentLogLine(date: Self.start, text: "editing a.swift")]
        store.upsert(codeTask)
        store.upsert(Self.record("live", kind: .worker, status: .running))

        let data = try store.encoded()
        let json = String(decoding: data, as: UTF8.self)
        #expect(json.contains("\"version\" : 1"))
        #expect(json.contains("\"cacheCreationTokens\" : 4"))

        let reloadDate = Self.start.addingTimeInterval(99)
        let decoded = try AgentStore.decoded(from: data, now: reloadDate)
        #expect(decoded["code"] == codeTask)
        #expect(decoded["live"]?.status == .cancelled)
        #expect(decoded["live"]?.endedAt == reloadDate)
        #expect(decoded["live"]?.logLines.last?.text == "Clicky quit while this was running.")
        #expect(decoded.runningRecords.isEmpty)
        #expect(throws: (any Error).self) { try AgentStore.decoded(from: Data("not json".utf8)) }
    }

    // MARK: - Usage

    @Test func usageComesFromTheResultEvent() throws {
        let resultLine = #"{"type":"result","subtype":"success","is_error":false,"result":"hi","total_cost_usd":0.0421,"usage":{"input_tokens":12,"output_tokens":340,"cache_read_input_tokens":20480,"cache_creation_input_tokens":1500,"server_tool_use":{"web_search_requests":0}}}"#
        let usage = try #require(AgentUsage.fromResultLine(Data(resultLine.utf8), model: "claude-sonnet-4-5"))
        #expect(usage == AgentUsage(model: "claude-sonnet-4-5", inputTokens: 12, outputTokens: 340, cacheReadTokens: 20480, cacheCreationTokens: 1500, costUSD: 0.0421))
        #expect(usage.totalTokens == 22332)
        #expect(usage.costText == "$0.04")
        #expect(usage.tokenSummary == "12 in · 340 out · 20k cache read · 1.5k cache write")

        // No cost: costUSD stays nil; no usage and no cost: nil.
        let withoutCost = AgentUsage.fromResultEvent(["type": "result", "usage": ["input_tokens": 5, "output_tokens": 1]], model: nil)
        #expect(withoutCost?.costUSD == nil && withoutCost?.inputTokens == 5)
        #expect(AgentUsage.fromResultEvent(["type": "result", "result": "x"], model: nil) == nil)
        #expect(AgentUsage.fromResultLine(Data(#"{"type":"assistant"}"#.utf8), model: nil) == nil)
        #expect(AgentUsage(costUSD: 0.0012).costText == "$0.0012")
    }

    @Test func usageTotalsSumAcrossAgentsAndModels() {
        var store = AgentStore()
        var brain = Self.record("brain", kind: .brain, status: .done, endOffset: 1)
        brain.model = "sonnet"
        brain.usage = AgentUsage(model: "claude-sonnet", inputTokens: 100, outputTokens: 10, costUSD: 0.1)
        var worker = Self.record("worker", status: .done, endOffset: 1)
        worker.usage = AgentUsage(model: "claude-haiku", inputTokens: 40, outputTokens: 4, cacheReadTokens: 6, costUSD: 0.01)
        var otherWorker = Self.record("worker2", status: .done, endOffset: 1)
        otherWorker.usage = AgentUsage(model: "claude-haiku", inputTokens: 1, outputTokens: 1)
        store.upsert(brain)
        store.upsert(worker)
        store.upsert(otherWorker)
        store.upsert(Self.record("noUsage", status: .failed, endOffset: 1))

        let totals = store.usageTotals()
        #expect(totals.agentCount == 4)
        #expect(totals.agentsWithUsage == 3)
        #expect(totals.usage.inputTokens == 141 && totals.usage.outputTokens == 15 && totals.usage.cacheReadTokens == 6)
        #expect(abs((totals.usage.costUSD ?? 0) - 0.11) < 0.000_001)
        #expect(store.usageTotals { $0.kind == .worker }.usage.inputTokens == 41)

        let byModel = store.usageTotalsByModel()
        #expect(byModel["claude-haiku"]?.agentCount == 2)
        #expect(byModel["claude-haiku"]?.usage.inputTokens == 41)
        #expect(byModel["claude-sonnet"]?.usage.costUSD == 0.1)
        #expect(byModel["haiku"]?.agentsWithUsage == 0)
        #expect(AgentsDashboardView.totalsLine(totals) == "4 agents · 162 tokens · $0.11")
    }

    @Test func elapsedTextAndLogText() {
        #expect(AgentRecord.elapsedText(seconds: 42.9) == "0:42")
        #expect(AgentRecord.elapsedText(seconds: 725) == "12:05")
        #expect(AgentRecord.elapsedText(seconds: 3723) == "1:02:03")
        var record = Self.record("a", kind: .codeTask, status: .failed, endOffset: 3)
        record.worktreePath = "/tmp/wt"
        record.branch = "clicky/x"
        record.errorDescription = "the agent stopped"
        record.logLines = [AgentLogLine(date: Self.start, text: "reading a.swift")]
        let logText = record.logText
        #expect(logText.hasPrefix("Code task: Agent a\nstatus: failed\nmodel: haiku"))
        #expect(logText.contains("worktree: /tmp/wt (clicky/x)"))
        #expect(logText.contains("error: the agent stopped"))
        #expect(logText.hasSuffix(" reading a.swift"))
    }

    // MARK: - [AGENTS:open]

    @Test func agentsTagParses() {
        #expect(AgentsDashboardTag.parse("[AGENTS:open]") == .open)
        #expect(AgentsDashboardTag.parse("[ agents: Show ]") == .open)
        #expect(AgentsDashboardTag.parse("[AGENTS:close]") == nil)
        #expect(AgentsDashboardTag.parse("[AGENT:open]") == nil)
    }

    @Test func routerEmitsTheAgentsTagAndNeverSpeaksIt() {
        for chunkSize in [1, 3, 7, 1000] {
            var router = ResponseRouter()
            let text = "here are your agents. [AGENTS:open] anything else?"
            var outputs: [ResponseRouterOutput] = []
            var index = text.startIndex
            while index < text.endIndex {
                let end = text.index(index, offsetBy: chunkSize, limitedBy: text.endIndex) ?? text.endIndex
                outputs += router.feed(String(text[index..<end]))
                index = end
            }
            outputs += router.finish()
            #expect(outputs.contains(.agentsDashboard(.open)), "chunk \(chunkSize)")
            let narration = outputs.compactMap { output -> String? in
                if case .narration(let text) = output { return text }
                return nil
            }.joined()
            #expect(!narration.uppercased().contains("AGENTS:") && !narration.contains("["), "chunk \(chunkSize): \(narration)")
            #expect(narration.contains("here are your agents.") && narration.contains("anything else?"))
        }
        var router = ResponseRouter()
        let malformed = router.feed("ok [AGENTS:explode] done") + router.finish()
        #expect(malformed.contains { if case .dropped(let reason, _) = $0 { return reason == "malformed agents tag" } else { return false } })
        #expect(!malformed.contains(.agentsDashboard(.open)))
        #expect(ResponseRouter.cleanNarration("see AGENTS:open] here") == "see  here")
    }

    @Test func historyRewriterDropsTheAgentsTag() {
        #expect(HistoryTagRewriter.wordsForHistory("here you go. [AGENTS:open]") == "here you go.")
    }

    @Test func mainPromptAsksForTheAgentsTag() {
        for features: SystemPromptFeatures in [.current, .legacy, []] {
            #expect(SystemPromptBuilder.mainSystemPrompt(features: features, sectionTexts: [:]).contains(AgentsDashboardTag.promptLine))
        }
        #expect(AgentsDashboardTag.promptLine.contains("[AGENTS:open]"))
    }
}

// MARK: - Renders

/// Offscreen renders of AgentsDashboardView with sample data (ImageRenderer,
/// no window, nothing on screen) into ~/Library/Logs/Clicky/renders/agents/,
/// light and dark. The dark render must come out darker than the light one.
@MainActor
struct AgentsDashboardRenderTests {
    static let outputDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Clicky/renders/agents", isDirectory: true)

    static let now = Date(timeIntervalSince1970: 1_761_400_300)

    static func sampleStore() -> AgentStore {
        let start = Date(timeIntervalSince1970: 1_761_400_000)
        var store = AgentStore()
        var brain = AgentRecord(id: "brain", kind: .brain, title: "compare these three laptops for me", model: "sonnet", status: .running,
                                phase: BrainPhase.speaking.rawValue, startedAt: start.addingTimeInterval(270))
        brain.usage = AgentUsage(model: "claude-sonnet-4-5", inputTokens: 3_210, outputTokens: 412, cacheReadTokens: 18_400, cacheCreationTokens: 2_100, costUSD: 0.0312)
        brain.logLines = [
            AgentLogLine(date: start.addingTimeInterval(271), text: "thinking (sonnet)"),
            AgentLogLine(date: start.addingTimeInterval(274), text: "spawned helper: Battery life"),
            AgentLogLine(date: start.addingTimeInterval(274), text: "spawned helper: Price check"),
            AgentLogLine(date: start.addingTimeInterval(281), text: "said: on it, checking those three for you"),
            AgentLogLine(date: start.addingTimeInterval(292), text: "said: the middle one wins on battery by about two hours.")
        ]
        store.upsert(brain)
        var batteryWorker = AgentRecord(id: "w1", kind: .worker, title: "Battery life", model: "haiku", status: .running, startedAt: start.addingTimeInterval(274), parentID: "brain")
        batteryWorker.logLines = [AgentLogLine(date: start.addingTimeInterval(274), text: "started")]
        store.upsert(batteryWorker)
        var priceWorker = AgentRecord(id: "w2", kind: .worker, title: "Price check", model: "haiku", status: .done, startedAt: start.addingTimeInterval(274),
                                      endedAt: start.addingTimeInterval(286), parentID: "brain")
        priceWorker.usage = AgentUsage(model: "claude-haiku-4-5", inputTokens: 2_900, outputTokens: 180, costUSD: 0.0041)
        store.upsert(priceWorker)
        var codeTask = AgentRecord(id: "code", kind: .codeTask, title: "Fix the failing CI on octo/app #42", model: "sonnet", status: .running,
                                   phase: "editing", startedAt: start.addingTimeInterval(40))
        codeTask.repository = "octo/app"
        codeTask.branch = "clicky/pr-42"
        codeTask.worktreePath = "/Users/me/.clicky/code/worktrees/app-pr-42"
        codeTask.currentStep = "running the tests"
        codeTask.changedFiles = ["Sources/App/Parser.swift", "Tests/AppTests/ParserTests.swift"]
        codeTask.queuedBehindCount = 1
        codeTask.logLines = ["Finding octo/app", "Making a worktree for #42", "The agent is working…", "reading Parser.swift", "editing Parser.swift",
                             "editing ParserTests.swift", "running the tests"].enumerated().map { index, text in
            AgentLogLine(date: start.addingTimeInterval(40 + Double(index) * 20), text: text)
        }
        store.upsert(codeTask)
        store.upsert(AgentRecord(id: "queued", kind: .codeTask, title: "Summarize octo/docs #7", model: "sonnet", status: .queued, startedAt: start.addingTimeInterval(200)))
        var board = AgentRecord(id: "board", kind: .boardSection, title: "s2 The handshake", model: "haiku", status: .failed, startedAt: start.addingTimeInterval(10),
                                endedAt: start.addingTimeInterval(19))
        board.errorDescription = "Claude Code sent nothing for 25 seconds."
        store.upsert(board)
        var oldBrain = AgentRecord(id: "old", kind: .brain, title: "how do i turn on dark mode", model: "sonnet", status: .done, phase: BrainPhase.done.rawValue,
                                   startedAt: start, endedAt: start.addingTimeInterval(6))
        oldBrain.usage = AgentUsage(model: "claude-sonnet-4-5", inputTokens: 2_800, outputTokens: 60, cacheReadTokens: 16_000, costUSD: 0.012)
        store.upsert(oldBrain)
        store.upsert(AgentRecord(id: "cancelled", kind: .boardRepair, title: "Repair the board", model: "sonnet", status: .cancelled, startedAt: start.addingTimeInterval(1),
                                 endedAt: start.addingTimeInterval(3)))
        return store
    }

    /// Renders with the given appearance: SwiftUI's colorScheme for its own
    /// colors, and the drawing appearance for the NSColor-backed system colors.
    static func render(selectedAgentID: String?, appearanceName: NSAppearance.Name, colorScheme: ColorScheme) throws -> NSImage {
        let content = AgentsDashboardView(store: sampleStore(), selectedAgentID: .constant(selectedAgentID), now: now, actions: .inert, isScrollable: false)
            .frame(width: 900, height: 700)
            .environment(\.colorScheme, colorScheme)
        let appearance = try #require(NSAppearance(named: appearanceName))
        var image: NSImage?
        appearance.performAsCurrentDrawingAppearance {
            let renderer = ImageRenderer(content: content)
            renderer.scale = 2
            image = renderer.nsImage
        }
        return try #require(image)
    }

    static func averageLuminance(_ image: NSImage) -> Double {
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) else { return -1 }
        var total = 0.0
        var count = 0
        let step = 16
        for pixelY in stride(from: 0, to: bitmap.pixelsHigh, by: step) {
            for pixelX in stride(from: 0, to: bitmap.pixelsWide, by: step) {
                guard let color = bitmap.colorAt(x: pixelX, y: pixelY)?.usingColorSpace(.sRGB) else { continue }
                total += 0.2126 * color.redComponent + 0.7152 * color.greenComponent + 0.0722 * color.blueComponent
                count += 1
            }
        }
        return count > 0 ? total / Double(count) : -1
    }

    static func writePNG(_ image: NSImage, named fileName: String) throws -> URL {
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let tiff = try #require(image.tiffRepresentation)
        let png = try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
        let fileURL = outputDirectory.appendingPathComponent(fileName)
        try png.write(to: fileURL)
        return fileURL
    }

    @Test func rendersLightAndDarkOffscreen() throws {
        var luminanceByName: [String: Double] = [:]
        for (selectedAgentID, suffix) in [("brain", "brain"), ("code", "code")] {
            let light = try Self.render(selectedAgentID: selectedAgentID, appearanceName: .aqua, colorScheme: .light)
            let dark = try Self.render(selectedAgentID: selectedAgentID, appearanceName: .darkAqua, colorScheme: .dark)
            #expect(light.size.width == 900 && light.size.height == 700)
            _ = try Self.writePNG(light, named: "agents-\(suffix)-light.png")
            _ = try Self.writePNG(dark, named: "agents-\(suffix)-dark.png")
            luminanceByName["\(suffix)-light"] = Self.averageLuminance(light)
            luminanceByName["\(suffix)-dark"] = Self.averageLuminance(dark)
        }
        for suffix in ["brain", "code"] {
            let lightLuminance = luminanceByName["\(suffix)-light"] ?? -1
            let darkLuminance = luminanceByName["\(suffix)-dark"] ?? -1
            #expect(lightLuminance > 0.7, "light \(suffix) luminance \(lightLuminance)")
            #expect(darkLuminance < 0.35, "dark \(suffix) luminance \(darkLuminance)")
        }
        let empty = ImageRenderer(content: AgentsDashboardView(store: AgentStore(), selectedAgentID: .constant(nil), now: Self.now, actions: .inert, isScrollable: false)
            .frame(width: 900, height: 600)).nsImage
        #expect(empty != nil)
        if let empty { _ = try Self.writePNG(empty, named: "agents-empty-light.png") }
    }
}
