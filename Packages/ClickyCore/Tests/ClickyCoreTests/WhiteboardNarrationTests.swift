import CoreGraphics
import Foundation
import Testing
@testable import ClickyCore

// MARK: - Helpers

private func board(_ jsonl: String) -> WBBoard {
    let outcome = WBStreamParser.parse(jsonl)
    #expect(outcome.isUsable)
    return outcome.board
}

private let threeStepBoard = """
{"wb":1,"title":"HTTPS","dir":"TB","sections":[{"id":"agenda","title":"Agenda"},{"id":"q1","title":"Handshake"},{"id":"recap","title":"Recap"}]}
{"el":"list","id":"ag","sec":"agenda","items":["hello","keys"]}
{"el":"box","id":"client","sec":"q1","text":"Browser"}
{"el":"box","id":"server","sec":"q1","text":"Server"}
{"el":"arrow","id":"a1","sec":"q1","from":"client","to":"server","text":"hello"}
{"el":"list","id":"rc","sec":"recap","items":["identity","privacy"]}
{"step":1,"show":["ag"],"say":"here is the plan for today, in two parts."}
{"step":2,"show":["client","server","a1"],"hl":["a1"],"say":"first the browser says hello to the server, listing what it supports.","cue":{"server":"server"},"point":"a1"}
{"step":3,"show":["rc"],"say":"so that's identity and privacy in one quick handshake."}
"""

private let silentStepBoard = """
{"wb":1,"title":"Hold","sections":[{"id":"q1","title":"One"}]}
{"el":"box","id":"b1","sec":"q1","text":"One"}
{"el":"box","id":"b2","sec":"q1","text":"Two"}
{"el":"box","id":"b3","sec":"q1","text":"Three"}
{"step":1,"show":["b1"],"say":"this is the first box on the board."}
{"step":2,"show":["b2"],"say":""}
{"step":3,"show":["b3"],"say":"and this one comes after the pause."}
"""

private func makeNarrator(_ jsonl: String) -> BoardNarrator {
    let parsedBoard = board(jsonl)
    return BoardNarrator(board: parsedBoard, scripts: BoardNarrationScript.make(board: parsedBoard))
}

private func speakIndexes(_ actions: [BoardNarrationAction]) -> [Int] {
    actions.compactMap { if case .speak(let stepIndex) = $0 { return stepIndex } else { return nil } }
}

// MARK: - Script

struct BoardNarrationScriptTests {
    @Test func segmentsCarryTheirStepAndTagsGetBoardIndexes() {
        let parsedBoard = board("""
        {"wb":1,"title":"T","sections":[{"id":"q1","title":"Q"}]}
        {"el":"box","id":"b1","sec":"q1","text":"Save"}
        {"step":1,"show":["b1"],"say":"click save up here [POINT:\\"Save\\":Save] and you're done with this part."}
        {"step":2,"show":[],"say":"[POINT:none]"}
        """)
        let scripts = BoardNarrationScript.make(board: parsedBoard, firstSegmentID: 7)
        #expect(scripts.count == 2)
        #expect(scripts[0].segments.allSatisfy { $0.boardStep == 1 })
        #expect(scripts[0].segments.first?.id == 7)
        #expect(scripts[0].tags.first?.index == BoardNarrationScript.firstBoardTagIndex)
        #expect(scripts[0].segments.flatMap(\.anchors).map(\.tagIndex) == [BoardNarrationScript.firstBoardTagIndex])
        #expect(!scripts[0].spokenText.contains("POINT"))
        // A step whose say is only a tag says nothing: it's a silent step.
        #expect(scripts[1].isSilent)
        #expect(scripts[1].tags.first?.index == BoardNarrationScript.firstBoardTagIndex + 1)
    }

    @Test func cueWordsFindTheirOffsets() {
        let scripts = BoardNarrationScript.make(board: board(threeStepBoard))
        let cue = scripts[1].cueAnchors.first
        #expect(cue?.elementIdentifier == "server")
        let speech = scripts[1].segments.first { $0.id == cue?.segmentID }?.speech ?? ""
        let afterOffset = String(speech.lowercased().dropFirst(cue?.speechOffset ?? 0))
        #expect(afterOffset.hasPrefix("server"))
    }

    @Test func speechlessPiecesJoinANeighbour() {
        #expect(BoardNarrationScript.mergingSpeechlessSegments(["\u{E000} ", "hello there. ", "\u{E000}"]) == ["\u{E000} hello there. \u{E000}"])
    }
}

// MARK: - Narrator

struct BoardNarratorTests {
    @Test func revealsNeverBeforeTheFirstSegmentStarts() {
        var narrator = makeNarrator(threeStepBoard)
        let startActions = narrator.start(at: 100)
        #expect(speakIndexes(startActions) == [0, 1, 2])
        #expect(startActions.contains(.endOfSpeech))
        #expect(narrator.revealTimes.isEmpty)
        #expect(narrator.currentStepIndex == nil)
        // Time passes, nothing plays yet: still nothing on the board.
        #expect(narrator.tick(at: 105).isEmpty)
        #expect(narrator.revealTimes.isEmpty)

        let firstSegmentID = narrator.scripts[0].segments[0].id
        let actions = narrator.segmentStarted(segmentID: firstSegmentID, at: 106)
        #expect(actions.contains(.revealStep(stepIndex: 0)))
        #expect(narrator.currentStepIndex == 0)
        #expect(narrator.revealTimes["ag"] == 106)
        let revealEntry = narrator.log.first { $0.kind == .reveal }
        let startEntry = narrator.log.first { $0.kind == .segmentStart }
        #expect(revealEntry?.time == startEntry?.time)
    }

    @Test func aLaggingVoiceHoldsTheBoard() {
        var narrator = makeNarrator(threeStepBoard)
        _ = narrator.start(at: 0)
        let step0 = narrator.scripts[0].segments
        _ = narrator.segmentStarted(segmentID: step0[0].id, at: 1)
        for segment in step0 { _ = narrator.segmentEnded(segmentID: segment.id, at: 3) }
        // Step 2's voice is late: the board waits for it.
        #expect(narrator.tick(at: 10).isEmpty)
        #expect(narrator.revealTimes["client"] == nil)
        #expect(narrator.currentStepIndex == 0)
        let step1First = narrator.scripts[1].segments[0].id
        let actions = narrator.segmentStarted(segmentID: step1First, at: 12)
        #expect(actions.contains(.revealStep(stepIndex: 1)))
        #expect(actions.contains(.point(elementIdentifier: "a1")))
        #expect((narrator.revealTimes["client"] ?? 0) >= 12)
        #expect(narrator.highlightedIdentifiers == ["a1"])
    }

    @Test func cuedElementsAppearOnTheirWord() {
        var narrator = makeNarrator(threeStepBoard)
        _ = narrator.start(at: 0)
        for segment in narrator.scripts[0].segments {
            _ = narrator.segmentStarted(segmentID: segment.id, at: 1)
            _ = narrator.segmentEnded(segmentID: segment.id, at: 2)
        }
        let cue = narrator.scripts[1].cueAnchors[0]
        _ = narrator.segmentStarted(segmentID: narrator.scripts[1].segments[0].id, at: 3)
        #expect(narrator.revealTimes["server"] == nil)
        #expect(narrator.revealTimes["client"] != nil)
        _ = narrator.segmentProgress(segmentID: cue.segmentID, spokenCharacters: cue.speechOffset - 1, at: 3.5)
        #expect(narrator.revealTimes["server"] == nil)
        _ = narrator.segmentProgress(segmentID: cue.segmentID, spokenCharacters: cue.speechOffset, at: 4)
        #expect(narrator.revealTimes["server"] == 4)
    }

    @Test func revealsSpreadOverTheStepWindow() {
        var narrator = makeNarrator(threeStepBoard)
        _ = narrator.start(at: 0)
        for segment in narrator.scripts[0].segments {
            _ = narrator.segmentStarted(segmentID: segment.id, at: 0)
            _ = narrator.segmentEnded(segmentID: segment.id, at: 0)
        }
        _ = narrator.segmentStarted(segmentID: narrator.scripts[1].segments[0].id, at: 10)
        // client and a1 are not cued (server is): two elements, window min(0.6 × duration, 1.0 s).
        let times = ["client", "a1"].compactMap { narrator.revealTimes[$0] }
        #expect(times.count == 2)
        let window = min(BoardNarrator.revealWindowFraction * narrator.scripts[1].estimatedDuration, BoardNarrator.revealSecondsPerElement * 2)
        #expect(times.allSatisfy { $0 >= 10 && $0 <= 10 + window })
        #expect(times[0] == 10)
    }

    @Test func aSilentStepHoldsForOnePointTwoSeconds() {
        var narrator = makeNarrator(silentStepBoard)
        let startActions = narrator.start(at: 0)
        // Step 3 waits until the silent step 2 has been shown and held.
        #expect(speakIndexes(startActions) == [0])
        #expect(!startActions.contains(.endOfSpeech))
        let step0 = narrator.scripts[0].segments
        _ = narrator.segmentStarted(segmentID: step0[0].id, at: 1)
        var endActions: [BoardNarrationAction] = []
        for segment in step0 { endActions += narrator.segmentEnded(segmentID: segment.id, at: 5) }
        #expect(endActions.contains(.stepEnded(stepIndex: 0)))
        #expect(endActions.contains(.revealStep(stepIndex: 1)))
        #expect(narrator.revealTimes["b2"] == 5)
        #expect(narrator.tick(at: 6.1).isEmpty)
        let holdEnd = narrator.tick(at: 6.2)
        #expect(holdEnd.contains(.stepEnded(stepIndex: 1)))
        #expect(speakIndexes(holdEnd) == [2])
        #expect(holdEnd.contains(.endOfSpeech))
        #expect(narrator.revealTimes["b3"] == nil)
    }

    @Test func pauseFreezesTheHold() {
        var narrator = makeNarrator(silentStepBoard)
        _ = narrator.start(at: 0)
        for segment in narrator.scripts[0].segments {
            _ = narrator.segmentStarted(segmentID: segment.id, at: 0)
            _ = narrator.segmentEnded(segmentID: segment.id, at: 1)
        }
        narrator.pause(at: 1.5)
        #expect(narrator.isPaused)
        #expect(narrator.tick(at: 10).isEmpty)
        // 0.7 s of the hold were left.
        #expect(narrator.resume(at: 20).isEmpty)
        #expect(narrator.tick(at: 20.6).isEmpty)
        #expect(speakIndexes(narrator.tick(at: 20.7)) == [2])
    }

    @Test func nextBackAndReplay() {
        var narrator = makeNarrator(threeStepBoard)
        _ = narrator.start(at: 0)
        for script in narrator.scripts {
            for segment in script.segments {
                _ = narrator.segmentStarted(segmentID: segment.id, at: 1)
                _ = narrator.segmentEnded(segmentID: segment.id, at: 1)
            }
        }
        #expect(narrator.isFinished)
        #expect(narrator.currentStepIndex == 2)
        #expect(narrator.next(at: 2).isEmpty)

        let backActions = narrator.back(at: 3)
        #expect(backActions.first == .stopSpeech)
        #expect(speakIndexes(backActions) == [1])
        #expect(narrator.mode == .single)
        // Step 1 is on the board at once; steps 2 and 3 wait for the voice.
        #expect(narrator.revealTimes["ag"] == BoardNarrator.instantRevealTime)
        #expect(narrator.revealTimes["client"] == nil)
        #expect(narrator.revealTimes["rc"] == nil)
        _ = narrator.segmentStarted(segmentID: narrator.scripts[1].segments[0].id, at: 4)
        #expect(narrator.currentStepIndex == 1)
        #expect(narrator.revealTimes["client"] == 4)

        let nextActions = narrator.next(at: 5)
        #expect(speakIndexes(nextActions) == [2])

        let replayActions = narrator.replay(at: 6)
        #expect(replayActions.first == .stopSpeech)
        #expect(speakIndexes(replayActions) == [0, 1, 2])
        #expect(narrator.revealTimes.isEmpty)
        #expect(narrator.currentStepIndex == nil)
    }

    @Test func eventsFromStepsNotBeingSpokenAreIgnored() {
        var narrator = makeNarrator(threeStepBoard)
        _ = narrator.goTo(stepIndex: 2, at: 0)
        // A stale segment of step 1 (another run) must not reveal anything.
        #expect(narrator.segmentStarted(segmentID: narrator.scripts[0].segments[0].id, at: 1).isEmpty)
        #expect(narrator.revealTimes["rc"] == nil)
    }
}

// MARK: - With the real coordinator

@MainActor
private final class NarratingHost: SpeechCoordinatorHost {
    var narrator: BoardNarrator
    var clock: TimeInterval = 0
    var revealLog: [(step: Int, time: TimeInterval)] = []

    init(narrator: BoardNarrator) { self.narrator = narrator }

    func cancelClaudeAndWorkers() {}
    func fireTag(index: Int) {}
    func dropUnfiredTags(_ tagIndexes: [Int]) {}
    func captionDidChange(_ caption: CaptionState) {}
    func answerDidFinish(historyText: String, wasInterrupted: Bool) {}
    func speakApology(_ text: String) {}
    func log(_ event: String) {}

    func segmentDidStart(_ segment: CaptionSegment) {
        for action in narrator.segmentStarted(segmentID: segment.id, at: clock) {
            if case .revealStep(let stepIndex) = action { revealLog.append((stepIndex, clock)) }
        }
    }

    func segmentDidProgress(_ segment: CaptionSegment, spokenCharacters: Int) {
        _ = narrator.segmentProgress(segmentID: segment.id, spokenCharacters: spokenCharacters, at: clock)
    }

    func segmentDidEnd(_ segment: CaptionSegment) {
        _ = narrator.segmentEnded(segmentID: segment.id, at: clock)
    }
}

@MainActor
private final class PausingEngine: SpeechEngine {
    let name = "mock"
    var callbacks = SpeechEngineCallbacks()
    var queued: [CaptionSegment] = []
    var pauseCount = 0
    var resumeCount = 0
    func begin(epoch: Int) { queued = [] }
    func enqueue(_ segment: CaptionSegment) { queued.append(segment) }
    func endOfAnswer() {}
    func stopNow() { queued = [] }
    func pause() { pauseCount += 1 }
    func resume() { resumeCount += 1 }

    func playNext() {
        guard !queued.isEmpty else { return }
        let segment = queued.removeFirst()
        callbacks.onSegmentStart(segment.id)
        for wordRange in segment.wordRanges { callbacks.onProgress(segment.id, wordRange.upperBound, wordRange.upperBound, true) }
        callbacks.onSegmentEnd(segment.id)
        if queued.isEmpty { callbacks.onAllPlayed() }
    }
}

@MainActor
struct BoardNarrationCoordinatorTests {
    @Test func stepsRevealOnlyWhenTheVoiceStartsThem() {
        let parsedBoard = board(threeStepBoard)
        let host = NarratingHost(narrator: BoardNarrator(board: parsedBoard, scripts: BoardNarrationScript.make(board: parsedBoard)))
        let primary = PausingEngine()
        let fallback = PausingEngine()
        let coordinator = SpeechCoordinator(primaryEngine: primary, fallbackEngine: fallback, host: host)
        coordinator.beginAnswer()
        for action in host.narrator.start(at: 0) {
            if case .speak(let stepIndex) = action { host.narrator.scripts[stepIndex].segments.forEach(coordinator.enqueue) }
        }
        coordinator.streamDidFinish(spawnedWorkers: false)
        #expect(host.revealLog.isEmpty)
        host.clock = 2
        primary.playNext()
        #expect(host.revealLog.map(\.step) == [0])
        #expect(host.revealLog.first?.time == 2)
        while !primary.queued.isEmpty {
            host.clock += 3
            primary.playNext()
        }
        #expect(host.revealLog.map(\.step) == [0, 1, 2])
        #expect(host.narrator.isFinished)
        #expect(host.narrator.revealTimes["server"] != nil)
    }

    @Test func pauseAndResumeReachBothEngines() {
        let host = NarratingHost(narrator: makeNarrator(threeStepBoard))
        let primary = PausingEngine()
        let fallback = PausingEngine()
        let coordinator = SpeechCoordinator(primaryEngine: primary, fallbackEngine: fallback, host: host)
        coordinator.beginAnswer()
        coordinator.pause()
        coordinator.pause()
        #expect(coordinator.isPaused)
        #expect(primary.pauseCount == 1 && fallback.pauseCount == 1)
        coordinator.resume()
        #expect(!coordinator.isPaused)
        #expect(primary.resumeCount == 1 && fallback.resumeCount == 1)
    }
}

// MARK: - Adapter

struct WBLayoutAdapterTests {
    @Test func mapsKindsShapesAndOwners() {
        let parsedBoard = board("""
        {"wb":1,"title":"Shapes","dir":"LR","sections":[{"id":"s","title":"S"}]}
        {"el":"box","id":"c","sec":"s","text":"Circle","shape":"circle"}
        {"el":"box","id":"d","sec":"s","text":"Decide","shape":"diamond"}
        {"el":"box","id":"r","sec":"s","text":"Plain"}
        {"el":"arrow","id":"a","sec":"s","from":"c","to":"d","text":"next"}
        {"el":"text","id":"t","sec":"s","text":"note","size":"l","near":"r","pos":"bottom"}
        {"el":"list","id":"l","sec":"s","title":"Points","items":["one","two"]}
        {"el":"table","id":"tb","sec":"s","cols":["a","b"],"rows":[["1","2"]]}
        {"el":"callout","id":"co","sec":"s","target":"d","style":"tip","text":"careful"}
        {"el":"flow","id":"f","sec":"s","src":"flowchart LR\\nA[Start] --> B[End]"}
        {"el":"arrow","id":"a2","sec":"s","from":"r","to":"f"}
        {"step":1,"show":["c","d","a","r","t","l","tb","co","f","a2"]}
        """)
        let adapted = WBLayoutAdapter.adapt(parsedBoard, viewportSize: CGSize(width: 1200, height: 800))
        let nodesByID = Dictionary(uniqueKeysWithValues: adapted.input.nodes.map { ($0.id, $0) })
        #expect(nodesByID["c"]?.kind == .ellipse)
        #expect(nodesByID["d"]?.kind == .box)
        #expect((nodesByID["d"]?.sizeHint?.width ?? 0) > WBMeasure.size(of: WBLayoutNode(id: "x", text: "Decide")).width)
        #expect(nodesByID["t"]?.near == WBLayoutNear(targetID: "r", side: .bottom))
        #expect(nodesByID["t"]?.fontSize == 24)
        #expect(nodesByID["l"]?.items == ["Points", "one", "two"])
        #expect(nodesByID["tb"]?.rows == [["a", "b"], ["1", "2"]])
        #expect(nodesByID["co"]?.near == WBLayoutNear(targetID: "d", side: .right))
        #expect(adapted.input.direction == .leftToRight)
        // The flow expands to its inner boxes, owned by the flow.
        let flowNodes = adapted.layoutIdentifiersByElement["f"] ?? []
        #expect(flowNodes.count == 2)
        #expect(flowNodes.allSatisfy { adapted.ownerIdentifiers[$0] == "f" })
        // Arrows are edges; one naming the flow goes to its first box.
        #expect(adapted.input.edges.first == WBLayoutEdge(from: "c", to: "d", label: "next"))
        #expect(adapted.input.edges.contains(WBLayoutEdge(from: "r", to: flowNodes[0], label: nil)))
        #expect(adapted.owner(ofEdge: 0) == "a")
        #expect(adapted.cameraIdentifiers(for: "a") == ["c", "d"])
        #expect(adapted.cameraIdentifiers(for: "s") == ["s"])
        let layout = WBBoardLayoutEngine.layout(adapted.input)
        #expect(adapted.boardRect(of: "f", in: layout) != nil)
    }

    @Test func agendaComesFirstAndRecapLast() {
        let parsedBoard = board("""
        {"wb":1,"title":"Order","sections":[{"id":"recap","title":"Recap"},{"id":"q1","title":"One"},{"id":"agenda","title":"Agenda"},{"id":"q2","title":"Two"}]}
        {"el":"box","id":"b","sec":"q1","text":"x"}
        {"step":1,"show":["b"]}
        """)
        #expect(WBLayoutAdapter.agendaFirstRecapLast(parsedBoard).sections.map(\.id) == ["agenda", "q1", "q2", "recap"])
    }

    @Test func doubleEscapedCodeNewlinesBecomeLines() {
        #expect(WBCode(text: "a\\n  b").displayText == "a\n  b")
        #expect(WBCode(text: "a\nb \\n c").displayText == "a\nb \\n c")
    }

    @Test func everyFixtureBoardLaysOutWithEveryShownElement() throws {
        let fixturesDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/boards")
        for fileName in try FileManager.default.contentsOfDirectory(atPath: fixturesDirectory.path) where fileName.hasSuffix(".txt") {
            let answerText = try String(contentsOf: fixturesDirectory.appendingPathComponent(fileName), encoding: .utf8)
            let parsedBoard = WBStreamParser.parse(WBBlockExtractor.whiteboardBody(in: answerText)).board
            let adapted = WBLayoutAdapter.adapt(parsedBoard, viewportSize: CGSize(width: 1280, height: 760))
            let layout = WBBoardLayoutEngine.layout(adapted.input)
            for step in parsedBoard.steps {
                for elementIdentifier in step.shownIdentifiers {
                    let isArrow = parsedBoard.element(withIdentifier: elementIdentifier)?.kind == .arrow
                    #expect(isArrow || adapted.boardRect(of: elementIdentifier, in: layout) != nil, "\(fileName): \(elementIdentifier) has no rect")
                }
            }
            #expect(adapted.cameraSteps.count == parsedBoard.steps.count)
        }
    }
}

// MARK: - History and commands

struct BoardHistoryTests {
    @Test func boardStateIsAtMostFourKilobytes() {
        var lines = [#"{"wb":1,"title":"Big","sections":[{"id":"q1","title":"One","q":"what is it"}]}"#]
        for index in 0..<60 {
            lines.append(#"{"el":"box","id":"b\#(index)","sec":"q1","text":"A fairly long box label number \#(index) that takes room"}"#)
        }
        for index in 0..<20 {
            lines.append(#"{"step":\#(index + 1),"show":["b\#(index)"],"say":"step \#(index) explains a fairly long thing about box \#(index) in detail."}"#)
        }
        let bigBoard = board(lines.joined(separator: "\n"))
        let text = BoardHistory.boardStateText(board: bigBoard, currentStepNumber: 3)
        #expect(text.utf8.count <= BoardHistory.maximumBytes)
        #expect(text.hasPrefix("BOARD STATE\ntitle: Big"))
        #expect(text.contains("current step: 3 of 20"))
        #expect(text.contains("q1 (One: \"what is it\")"))
        #expect(text.hasSuffix(BoardHistory.truncationLine))
        // Every JSONL line kept is whole.
        let jsonlPart = text.components(separatedBy: "jsonl:\n").last ?? ""
        for line in jsonlPart.split(separator: "\n") where !line.hasPrefix("…") {
            #expect(WBRepair.strictParse(String(line)) != nil)
        }
    }

    @Test func aSmallBoardKeepsItsWholeJSONL() {
        let smallBoard = board(threeStepBoard)
        let entry = BoardHistory.historyEntry(spokenHistory: "here's the board.", board: smallBoard, currentStepNumber: nil)
        #expect(entry.hasPrefix("here's the board.\n\nBOARD STATE"))
        #expect(entry.contains("current step: none of 3"))
        let jsonl = entry.components(separatedBy: "jsonl:\n").last ?? ""
        #expect(WBStreamParser.parse(jsonl).board == smallBoard)
    }

    @Test func sectionJSONLForGoDeeper() {
        let smallBoard = board(threeStepBoard)
        #expect(BoardHistory.questionSections(of: smallBoard).map(\.id) == ["q1"])
        let sectionText = BoardHistory.sectionJSONL(board: smallBoard, sectionIdentifier: "q1") ?? ""
        let sectionBoard = WBStreamParser.parse(sectionText).board
        #expect(sectionBoard.elements.map(\.id) == ["client", "server", "a1"])
        #expect(sectionBoard.steps.count == 1)
    }
}

struct BoardVoiceCommandTests {
    @Test func parsesBoardCommands() {
        #expect(BoardVoiceCommand.parse("Next.") == .next)
        #expect(BoardVoiceCommand.parse("okay clicky, go back") == .back)
        #expect(BoardVoiceCommand.parse("repeat that") == .repeatStep)
        #expect(BoardVoiceCommand.parse("pause") == .pause)
        #expect(BoardVoiceCommand.parse("continue") == .resume)
        #expect(BoardVoiceCommand.parse("close the board") == .close)
        #expect(BoardVoiceCommand.parse("save board") == .save)
        #expect(BoardVoiceCommand.parse("Whiteboard that!") == .whiteboardThat)
        #expect(BoardVoiceCommand.parse("go deeper on two") == .goDeeper(sectionNumber: 2))
        #expect(BoardVoiceCommand.parse("go deeper on section 3") == .goDeeper(sectionNumber: 3))
        #expect(BoardVoiceCommand.parse("go deeper on the second one") == .goDeeper(sectionNumber: 2))
        #expect(BoardVoiceCommand.parse("next time tell me more") == nil)
        #expect(BoardVoiceCommand.parse("go deeper on everything") == nil)
        #expect(BoardVoiceCommand.goDeeper(sectionNumber: 1).needsOpenBoard == false)
        #expect(BoardVoiceCommand.next.needsOpenBoard)
    }

    @Test func echoGuardIgnoresCommandsClickyJustSaid() {
        var echoGuard = EchoGuard()
        let now = Date()
        echoGuard.recordSpoken("next, the server answers with its certificate", at: now)
        let words = BoardVoiceCommand.echoWords(in: "next")
        #expect(words == ["next"])
        #expect(!echoGuard.accepts("next", commandWords: words, at: now.addingTimeInterval(1)))
        #expect(echoGuard.accepts("go back", commandWords: BoardVoiceCommand.echoWords(in: "go back"), at: now.addingTimeInterval(1)))
        #expect(echoGuard.accepts("next", commandWords: words, at: now.addingTimeInterval(5)))
    }
}

struct WhiteboardPromptTests {
    @Test func promptKeepsBoardsForConceptsOnly() {
        let text = WhiteboardPromptSection.text
        #expect(text.contains("boards are for concepts only"))
        #expect(text.contains("numbered marks on the real screen"))
        #expect(!text.lowercased().contains("the web"))
        #expect(!SystemPromptBuilder.helperWorkersSection.lowercased().contains("the web"))
    }

    @Test func whiteboardFeatureAddsTheSectionAndDropsTheMissingAbility() {
        let savedTexts = SystemPromptBuilder.gatedSectionTexts
        defer { SystemPromptBuilder.gatedSectionTexts = savedTexts }
        SystemPromptBuilder.gatedSectionTexts[.whiteboard] = WhiteboardPromptSection.text
        let withBoard = SystemPromptBuilder.mainSystemPrompt(features: SystemPromptFeatures.current.union(.whiteboard))
        #expect(withBoard.contains("<whiteboard>"))
        #expect(!withBoard.contains("draw on a whiteboard"))
        let withoutBoard = SystemPromptBuilder.mainSystemPrompt(features: .current)
        #expect(!withoutBoard.contains("<whiteboard>"))
        #expect(withoutBoard.contains("draw on a whiteboard"))
        #expect(ModeHint.whiteboard.effort == nil)
        #expect(ModeHint.detect("draw me a diagram of tcp").isWhiteboard)
    }
}
