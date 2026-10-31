//
//  ProgressiveBoardTests.swift
//  ClickyCoreTests
//
//  P6.7 progressive boards: the helper-section line filter, placeholder
//  replacement in plan position, and the narrator's bridge / skip /
//  append-before-recap / drop behaviour, driven with a mock clock.
//

import CoreGraphics
import Foundation
import Testing
@testable import ClickyCore

// MARK: - Fixtures

/// Agenda, two helper sections (s1, s2: placeholder + silent step each), one
/// section of the main model's own (q3), recap.
private let progressiveBoardText = """
{"wb":1,"title":"Three things","dir":"TB","sections":[{"id":"agenda","title":"Agenda"},{"id":"s1","title":"HTTPS"},{"id":"s2","title":"Certificates"},{"id":"q3","title":"Speed"},{"id":"recap","title":"Recap"}]}
{"el":"list","id":"ag","sec":"agenda","items":["https","certificates","speed"]}
{"el":"text","id":"s1_wait","sec":"s1","text":"working on it…"}
{"el":"text","id":"s2_wait","sec":"s2","text":"working on it…"}
{"el":"box","id":"q3_box","sec":"q3","text":"Round trips"}
{"el":"list","id":"rc","sec":"recap","items":["hello first","then trust","a little slower"]}
{"step":1,"show":["ag"],"say":"here's what we'll cover today, in three parts."}
{"step":2,"show":["s1_wait"],"say":"","focus":"s1"}
{"step":3,"show":["s2_wait"],"say":"","focus":"s2"}
{"step":4,"show":["q3_box"],"say":"https costs a couple of extra round trips at the start."}
{"step":5,"show":["rc"],"say":"so that's the whole picture in a nutshell."}
"""

private let sectionOneWorkerText = """
{"el":"box","id":"s1_client","sec":"s1","text":"Browser"}
{"el":"box","id":"s1_server","sec":"s1","text":"Server"}
{"el":"arrow","id":"s1_hello","sec":"s1","from":"s1_client","to":"s1_server","text":"hello"}
{"step":1,"show":["s1_client","s1_server","s1_hello"],"say":"the browser says hello and the server answers with its certificate."}
"""

private let sectionTwoWorkerText = """
{"el":"box","id":"s2_ca","sec":"s2","text":"Certificate authority"}
{"el":"box","id":"s2_cert","sec":"s2","text":"Certificate"}
{"el":"arrow","id":"s2_signs","sec":"s2","from":"s2_ca","to":"s2_cert","text":"signs"}
{"step":1,"show":["s2_ca"],"say":"a certificate authority vouches for the site."}
{"step":2,"show":["s2_cert","s2_signs"],"say":"it signs the certificate, so your browser can trust it."}
"""

private func progressiveBoard() -> WBBoard {
    let outcome = WBStreamParser.parse(progressiveBoardText)
    #expect(outcome.isUsable)
    return outcome.board
}

private func workerBoard(_ text: String, section: String) -> WBBoard {
    let outcome = WBWorkerSectionFilter.filter(workerText: text, sectionIdentifier: section)
    #expect(outcome.isUsable)
    return outcome.board
}

private func makeProgressiveNarrator() -> BoardNarrator {
    let board = progressiveBoard()
    return BoardNarrator(board: board, scripts: BoardNarrationScript.make(board: board))
}

private func spokenStepIndexes(_ actions: [BoardNarrationAction]) -> [Int] {
    actions.compactMap { if case .speak(let stepIndex) = $0 { return stepIndex } else { return nil } }
}

private func bridgeCount(_ actions: [BoardNarrationAction]) -> Int {
    actions.filter { if case .bridge = $0 { return true } else { return false } }.count
}

private func droppedSections(_ actions: [BoardNarrationAction]) -> [String] {
    actions.flatMap { action -> [String] in
        if case .dropSections(let sectionIdentifiers) = action { return sectionIdentifiers }
        return []
    }
}

/// The voice plays a whole step: every segment starts and ends.
private func playStep(_ stepIndex: Int, on narrator: inout BoardNarrator, at time: TimeInterval) -> [BoardNarrationAction] {
    var actions: [BoardNarrationAction] = []
    for segment in narrator.scripts[stepIndex].segments {
        actions += narrator.segmentStarted(segmentID: segment.id, at: time)
        actions += narrator.segmentEnded(segmentID: segment.id, at: time + 0.5)
    }
    return actions
}

/// The step a script speaks, by its first shown element (indexes move on merges).
private func stepIndex(showing elementIdentifier: String, in narrator: BoardNarrator) -> Int? {
    narrator.board.steps.firstIndex { $0.shownIdentifiers.contains(elementIdentifier) }
}

// MARK: - Worker filter

struct WorkerSectionFilterTests {
    @Test func acceptsValidSectionLines() {
        let outcome = WBWorkerSectionFilter.filter(workerText: sectionOneWorkerText, sectionIdentifier: "s1", sectionTitle: "HTTPS")
        #expect(outcome.isUsable)
        #expect(outcome.rejectedReasons.isEmpty)
        #expect(outcome.acceptedLineCount == 4)
        #expect(outcome.board.elements.map(\.id) == ["s1_client", "s1_server", "s1_hello"])
        #expect(outcome.board.elements.allSatisfy { $0.sectionIdentifier == "s1" })
        #expect(outcome.board.sections.map(\.id) == ["s1"])
        #expect(outcome.board.sections.first?.title == "HTTPS")
        #expect(outcome.board.steps.count == 1)
    }

    @Test func rejectsIdsOutsideTheSectionHeadersAndOtherSections() {
        let workerText = """
        here you go:
        ```
        {"wb":1,"title":"Mine","sections":[{"id":"s1","title":"HTTPS"}]}
        {"el":"box","id":"client","sec":"s1","text":"No prefix"}
        {"el":"box","sec":"s1","text":"No id at all"}
        {"el":"box","id":"s2_server","sec":"s1","text":"Wrong prefix"}
        {"el":"box","id":"s1_other","sec":"recap","text":"Other section"}
        {"el":"text","id":"s1_wait","sec":"s1","text":"placeholder again"}
        {"el":"arrow","id":"s1_out","sec":"s1","from":"s1_ok","to":"ag","text":"leaves"}
        {"el":"box","id":"s1_ok","text":"Kept, sec filled in"}
        {"step":1,"show":["s1_ok","client","ag"],"say":"only the kept box is shown here.","point":"ag","focus":"recap"}
        {"step":2,"show":["client"]}
        ```
        """
        let outcome = WBWorkerSectionFilter.filter(workerText: workerText, sectionIdentifier: "s1")
        #expect(outcome.board.elements.map(\.id) == ["s1_ok"])
        #expect(outcome.board.elements.first?.sectionIdentifier == "s1")
        #expect(outcome.rejectedReasons.contains("header line"))
        #expect(outcome.rejectedReasons.contains("id outside s1: client"))
        #expect(outcome.rejectedReasons.contains("id outside s1: (none)"))
        #expect(outcome.rejectedReasons.contains("id outside s1: s2_server"))
        #expect(outcome.rejectedReasons.contains("id outside s1: s1_wait"))
        #expect(outcome.rejectedReasons.contains("other section recap: s1_other"))
        #expect(outcome.rejectedReasons.contains("arrow leaves s1: s1_out"))
        #expect(outcome.rejectedReasons.contains("step without s1 elements"))
        // The kept step shows only this section's ids; foreign point / focus are gone.
        #expect(outcome.board.steps.count == 1)
        #expect(outcome.board.steps.first?.shownIdentifiers == ["s1_ok"])
        #expect(outcome.board.steps.first?.pointIdentifier == nil)
        #expect(outcome.board.steps.first?.focus == nil)
    }

    @Test func aReplyWithNothingOfTheSectionIsUnusable() {
        let outcome = WBWorkerSectionFilter.filter(workerText: "{\"el\":\"box\",\"id\":\"b1\",\"text\":\"x\"}\nsorry, i can't draw that.", sectionIdentifier: "s3")
        #expect(!outcome.isUsable)
        #expect(outcome.rejectedReasons == ["id outside s3: b1"])
    }

    @Test func workerTitlesNameTheirSection() {
        #expect(ProgressiveBoard.workerSection(fromWorkerTitle: "s2 The handshake")?.sectionIdentifier == "s2")
        #expect(ProgressiveBoard.workerSection(fromWorkerTitle: "s2 The handshake")?.title == "The handshake")
        #expect(ProgressiveBoard.workerSection(fromWorkerTitle: "S12: Certs")?.sectionIdentifier == "s12")
        #expect(ProgressiveBoard.workerSection(fromWorkerTitle: "s3")?.title == "s3")
        #expect(ProgressiveBoard.workerSection(fromWorkerTitle: "safari tabs") == nil)
        #expect(ProgressiveBoard.workerSection(fromWorkerTitle: "compare prices") == nil)
    }

    @Test func helperPromptsNameTheSectionPrefix() {
        let prompt = WhiteboardPromptSection.workerSectionSystemPrompt(sectionIdentifier: "s2", sectionTitle: "Certificates")
        #expect(prompt.contains("\"s2_"))
        #expect(prompt.contains("no header line"))
        #expect(prompt.contains("\\n"))
        #expect(WhiteboardPromptSection.text.contains("[WORKER:s2 short title:task]"))
        #expect(WhiteboardPromptSection.text.contains(#"{"el":"text","id":"s2_wait","sec":"s2","text":"working on it…"}"#))
        let savedTexts = SystemPromptBuilder.gatedSectionTexts
        defer { SystemPromptBuilder.gatedSectionTexts = savedTexts }
        SystemPromptBuilder.gatedSectionTexts[.whiteboard] = WhiteboardPromptSection.text
        #expect(SystemPromptBuilder.mainSystemPrompt(features: SystemPromptFeatures.current.union(.whiteboard)).contains("helpers on a board"))
        #expect(!SystemPromptBuilder.mainSystemPrompt(features: .current).contains(SystemPromptBuilder.boardHelperWorkersSentence))
    }
}

// MARK: - Placeholder replacement

struct PlaceholderReplacementTests {
    @Test func pendingSectionsAreTheOnesWithAPlaceholder() {
        #expect(ProgressiveBoard.pendingSectionIdentifiers(in: progressiveBoard()) == ["s1", "s2"])
    }

    @Test func helperLinesReplaceThePlaceholderInPlanPosition() throws {
        let board = progressiveBoard()
        let change = try #require(ProgressiveBoard.replacePlaceholder(ofSection: "s2", in: board, with: workerBoard(sectionTwoWorkerText, section: "s2")))
        let merged = change.board
        #expect(merged.elements.map(\.id) == ["ag", "s1_wait", "s2_ca", "s2_cert", "s2_signs", "q3_box", "rc"])
        #expect(merged.elements.filter { $0.id.hasPrefix("s2_") }.allSatisfy { $0.sectionIdentifier == "s2" })
        // The silent placeholder step became the helper's two steps, before q3's.
        #expect(merged.steps.map(\.shownIdentifiers) == [["ag"], ["s1_wait"], ["s2_ca"], ["s2_cert", "s2_signs"], ["q3_box"], ["rc"]])
        #expect(merged.steps.map(\.number) == [1, 2, 3, 4, 5, 6])
        #expect(change.insertedStepIndexes == [2, 3])
        #expect(change.stepIndexMapping == [0: 0, 1: 1, 3: 4, 4: 5])
        #expect(ProgressiveBoard.pendingSectionIdentifiers(in: merged) == ["s1"])
        // A second merge of the same section does nothing.
        #expect(ProgressiveBoard.replacePlaceholder(ofSection: "s2", in: merged, with: workerBoard(sectionTwoWorkerText, section: "s2")) == nil)
    }

    @Test func aDroppedSectionLeavesNoTrace() throws {
        let change = try #require(ProgressiveBoard.replacePlaceholder(ofSection: "s1", in: progressiveBoard(), with: nil))
        #expect(change.board.element(withIdentifier: "s1_wait") == nil)
        #expect(change.board.section(withIdentifier: "s1") == nil)
        #expect(change.board.steps.count == 4)
        #expect(change.insertedStepIndexes.isEmpty)
        #expect(change.stepIndexMapping[1] == nil)
        #expect(change.stepIndexMapping[2] == 1)
    }

    @Test func withoutAPlaceholderStepHelperStepsGoBeforeTheNextSection() throws {
        var board = progressiveBoard()
        board.steps.remove(at: 2)
        let change = try #require(ProgressiveBoard.replacePlaceholder(ofSection: "s2", in: board, with: workerBoard(sectionTwoWorkerText, section: "s2")))
        #expect(change.board.steps.map(\.shownIdentifiers) == [["ag"], ["s1_wait"], ["s2_ca"], ["s2_cert", "s2_signs"], ["q3_box"], ["rc"]])
    }

    @Test func mergedBoardsStillSerializeAndRender() throws {
        var board = progressiveBoard()
        for (section, text) in [("s1", sectionOneWorkerText), ("s2", sectionTwoWorkerText)] {
            board = try #require(ProgressiveBoard.replacePlaceholder(ofSection: section, in: board, with: workerBoard(text, section: section))).board
        }
        #expect(WBStreamParser.parse(WBJSONLSerializer.serialize(board)).board == board)
        let adapted = WBLayoutAdapter.adapt(board, viewportSize: CGSize(width: 1200, height: 800))
        #expect(adapted.boardRect(of: "s1_client", in: WBBoardLayoutEngine.layout(adapted.input)) != nil)
    }
}

// MARK: - Narrator

struct ProgressiveNarratorTests {
    @Test func sectionsThatArriveInTimeAreNarratedInPlanOrder() {
        var narrator = makeProgressiveNarrator()
        #expect(narrator.pendingSectionIdentifiers == ["s1", "s2"])
        // The voice gets the agenda; s1 waits until the voice reaches it.
        let startActions = narrator.start(at: 0)
        #expect(spokenStepIndexes(startActions) == [0])
        #expect(!startActions.contains(.endOfSpeech))
        // Both helpers finish while the agenda is spoken: in place, no bridge.
        var actions: [BoardNarrationAction] = []
        var nextSegmentID = 1_000
        for (section, text) in [("s2", sectionTwoWorkerText), ("s1", sectionOneWorkerText)] {
            let merge = narrator.mergeSection(section, workerBoard: workerBoard(text, section: section), firstSegmentID: nextSegmentID, at: 1)
            nextSegmentID = merge.nextSegmentID
            actions += merge.actions
        }
        #expect(actions.contains(.boardChanged))
        #expect(narrator.pendingSectionIdentifiers.isEmpty)
        #expect(nextSegmentID > 1_000)
        actions += playStep(0, on: &narrator, at: 2)
        #expect(bridgeCount(actions) == 0)
        // Agenda, s1, s2 (two steps), q3, recap — the board's own order.
        let spoken = spokenStepIndexes(startActions + actions)
        #expect(spoken == [0, 1, 2, 3, 4, 5])
        #expect(narrator.board.steps.map { $0.shownIdentifiers.first ?? "" } == ["ag", "s1_client", "s2_ca", "s2_cert", "q3_box", "rc"])
        #expect(actions.contains(.endOfSpeech))
        // New segments have their own ids and map to their steps.
        let s1Segment = narrator.scripts[1].segments[0]
        #expect(s1Segment.id >= 1_000)
        #expect(narrator.segmentStarted(segmentID: s1Segment.id, at: 5).contains(.revealStep(stepIndex: 1)))
    }

    @Test func aLateSectionGetsOneBridgeLineAndComesBackBeforeTheRecap() throws {
        var narrator = makeProgressiveNarrator()
        _ = narrator.start(at: 0)
        // The agenda ends with both helpers still working: one bridge line for both.
        let afterAgenda = playStep(0, on: &narrator, at: 1)
        #expect(bridgeCount(afterAgenda) == 1)
        #expect(afterAgenda.contains(.bridge(sectionIdentifier: "s1")))
        // The placeholders are on the board ("working on it…") while q3 is handed over.
        #expect(narrator.revealTimes["s1_wait"] != nil)
        let q3Index = try #require(stepIndex(showing: "q3_box", in: narrator))
        #expect(spokenStepIndexes(afterAgenda) == [q3Index])
        // The recap isn't handed to the voice yet.
        #expect(!afterAgenda.contains(.endOfSpeech))

        // s2 arrives while q3 is spoken: its steps go just before the recap.
        let merge = narrator.mergeSection("s2", workerBoard: workerBoard(sectionTwoWorkerText, section: "s2"), firstSegmentID: 500, at: 3)
        #expect(merge.actions.contains(.boardChanged))
        let s2First = try #require(stepIndex(showing: "s2_ca", in: narrator))
        let s2Second = try #require(stepIndex(showing: "s2_cert", in: narrator))
        #expect(spokenStepIndexes(merge.actions) == [s2First, s2Second])
        // On the board they sit in plan position (before q3).
        #expect(s2First < (stepIndex(showing: "q3_box", in: narrator) ?? 0))
        #expect(bridgeCount(merge.actions) == 0)

        // q3 and s2 are spoken; s1 never came: one short line, then the recap.
        var actions = playStep(try #require(stepIndex(showing: "q3_box", in: narrator)), on: &narrator, at: 4)
        #expect(droppedSections(actions).isEmpty)
        actions += playStep(try #require(stepIndex(showing: "s2_ca", in: narrator)), on: &narrator, at: 6)
        actions += playStep(try #require(stepIndex(showing: "s2_cert", in: narrator)), on: &narrator, at: 8)
        #expect(droppedSections(actions) == ["s1"])
        #expect(narrator.board.element(withIdentifier: "s1_wait") == nil)
        #expect(narrator.revealTimes["s1_wait"] == nil)
        let recapIndex = try #require(stepIndex(showing: "rc", in: narrator))
        #expect(spokenStepIndexes(actions).last == recapIndex)
        // The drop line comes before the recap is handed over, then the end.
        let dropPosition = try #require(actions.firstIndex(of: .dropSections(sectionIdentifiers: ["s1"])))
        let recapPosition = try #require(actions.firstIndex(of: .speak(stepIndex: recapIndex)))
        #expect(dropPosition < recapPosition)
        #expect(actions.contains(.endOfSpeech))
        let finishing = playStep(recapIndex, on: &narrator, at: 10)
        #expect(finishing.contains(.finished))
    }

    @Test func aSectionArrivingAfterTheRecapStartedIsIgnored() throws {
        var narrator = makeProgressiveNarrator()
        _ = narrator.start(at: 0)
        _ = playStep(0, on: &narrator, at: 1)
        let actions = playStep(try #require(stepIndex(showing: "q3_box", in: narrator)), on: &narrator, at: 2)
        #expect(droppedSections(actions) == ["s1", "s2"])
        let lateMerge = narrator.mergeSection("s1", workerBoard: workerBoard(sectionOneWorkerText, section: "s1"), firstSegmentID: 900, at: 3)
        #expect(lateMerge.actions.isEmpty)
        #expect(lateMerge.nextSegmentID == 900)
        #expect(narrator.board.element(withIdentifier: "s1_client") == nil)
    }

    @Test func aFailedHelperIsDroppedWhereItsSectionWas() {
        var narrator = makeProgressiveNarrator()
        _ = narrator.start(at: 0)
        narrator.markSectionFailed("s1")
        let afterAgenda = playStep(0, on: &narrator, at: 1)
        // s1 is dropped at once; s2 (still coming) gets the bridge line.
        #expect(droppedSections(afterAgenda) == ["s1"])
        #expect(afterAgenda.contains(.bridge(sectionIdentifier: "s2")))
        #expect(narrator.pendingSectionIdentifiers == ["s2"])
        #expect(narrator.board.section(withIdentifier: "s1") == nil)
    }

    @Test func withoutARecapLateSectionsAreDroppedAtTheEnd() throws {
        var board = progressiveBoard()
        board.sections.removeAll { $0.id == "recap" }
        board.elements.removeAll { $0.id == "rc" }
        board.steps.removeLast()
        var narrator = BoardNarrator(board: board, scripts: BoardNarrationScript.make(board: board))
        _ = narrator.start(at: 0)
        _ = playStep(0, on: &narrator, at: 1)
        let q3Index = try #require(stepIndex(showing: "q3_box", in: narrator))
        let actions = playStep(q3Index, on: &narrator, at: 2)
        #expect(droppedSections(actions) == ["s1", "s2"])
        #expect(actions.contains(.endOfSpeech))
        #expect(actions.contains(.finished))
    }

    @Test func boardsWithoutHelpersNarrateAsBefore() {
        let board = WBStreamParser.parse("""
        {"wb":1,"title":"T","sections":[{"id":"q1","title":"Q"},{"id":"recap","title":"Recap"}]}
        {"el":"box","id":"b1","sec":"q1","text":"One"}
        {"el":"list","id":"rc","sec":"recap","items":["one"]}
        {"step":1,"show":["b1"],"say":"this is the first box on the board."}
        {"step":2,"show":["rc"],"say":"and that's the recap."}
        """).board
        var narrator = BoardNarrator(board: board, scripts: BoardNarrationScript.make(board: board))
        let actions = narrator.start(at: 0)
        #expect(spokenStepIndexes(actions) == [0, 1])
        #expect(actions.contains(.endOfSpeech))
        #expect(narrator.pendingSectionIdentifiers.isEmpty)
    }
}
