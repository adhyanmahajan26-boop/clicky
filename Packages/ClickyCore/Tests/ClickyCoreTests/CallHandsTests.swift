import Testing
@testable import ClickyCore

struct CallHandsTests {
    private func streamed(_ reply: String, size: Int) -> (speech: String, pieces: [CallScreenPiece]) {
        var stream = CallScreenStream()
        var speech = ""
        var pieces: [CallScreenPiece] = []
        var rest = Substring(reply)
        while !rest.isEmpty {
            let delta = rest.prefix(size)
            rest = rest.dropFirst(size)
            let fed = stream.feed(String(delta))
            speech += fed.speech
            pieces += fed.pieces
        }
        let last = stream.finish()
        return (speech + last.speech, pieces + last.pieces)
    }

    @Test func actionsBlockComesOutWhereverTheDeltasSplitIt() {
        let reply = #"Opening ChatGPT now. <actions>{"goal":"open codex","steps":[{"do":"open_app","name":"ChatGPT"}]}</actions>"#
        for size in [1, 2, 3, 7, 50, 1_000] {
            let result = streamed(reply, size: size)
            #expect(result.speech.trimmingCharacters(in: .whitespaces) == "Opening ChatGPT now.", "size \(size)")
            #expect(result.pieces == [.actions(#"{"goal":"open codex","steps":[{"do":"open_app","name":"ChatGPT"}]}"#)], "size \(size)")
        }
    }

    @Test func lookIsTakenOutAndNeverSpoken() {
        for size in [1, 4, 100] {
            let result = streamed("Let me look. [LOOK]", size: size)
            #expect(result.speech.trimmingCharacters(in: .whitespaces) == "Let me look.")
            #expect(result.pieces == [.look])
        }
        #expect(CallScreenStream.extract(from: "One sec [look: the sidebar]").pieces == [.look])
    }

    @Test func everydayBracketsAndAnglesStaySpeech() {
        let result = CallScreenStream.extract(from: "Two [options] and 3 < 4, also [Lookout] stays.")
        #expect(result.text == "Two [options] and 3 < 4, also [Lookout] stays.")
        #expect(result.pieces.isEmpty)
    }

    @Test func aBlockThatNeverClosesIsDroppedNotReadAloud() {
        let result = CallScreenStream.extract(from: #"Typing it in. <actions>{"steps":[{"do":"type","text":"hello"#)
        #expect(result.text.trimmingCharacters(in: .whitespaces) == "Typing it in.")
        #expect(result.pieces.isEmpty)
    }

    @Test func codeFencesAroundABlockAreNotSpoken() {
        let result = CallScreenStream.extract(from: "Clicking it.\n```json\n<actions>{\"steps\":[{\"do\":\"click\",\"id\":3}]}</actions>\n```")
        #expect(!result.text.contains("```"))
        #expect(result.pieces.count == 1)
    }

    @Test func pointStepParsesAndIsFree() {
        guard case .success(let plan) = ActionDSL.parse(#"{"steps":[{"do":"point","id":12}]}"#) else { Issue.record("expected a plan"); return }
        #expect(plan.steps == [.point(elementID: 12)])
        #expect(plan.steps[0].referencedElementIDs == [12])
        #expect(!plan.steps[0].changesScreen)
        guard case .failure = ActionDSL.parse(#"{"steps":[{"do":"point"}]}"#) else { Issue.record("a point with no id should fail"); return }
    }

    @Test func codexAndClaudeCodeOpenTheAppsTheyLiveIn() {
        #expect(ActionAppHomes.home(of: "Codex") == "ChatGPT")
        #expect(ActionAppHomes.home(of: "openai  codex") == "ChatGPT")
        #expect(ActionAppHomes.home(of: "Claude Code") == "Claude")
        #expect(ActionAppHomes.home(of: "Spotify") == nil)
    }

    @Test func typingIntoTheFieldJustClickedIsNotStale() {
        let loop = ActionTaskLoop(goal: "name the project", ownerTranscript: "", stepLimit: CallHands.stepLimit, observeTurnLimit: CallHands.observeTurnLimit)
        let typeInto65 = ActionStep.type(elementID: 65, text: "Vello", pressesReturn: false)
        #expect(loop.gate(typeInto65, screenChangedEarlierInBatch: true, previousStepInBatch: .click(elementID: 65)) == .run)
        #expect(loop.gate(typeInto65, screenChangedEarlierInBatch: true, previousStepInBatch: .click(elementID: 64)) == .skipStaleIDs)
        #expect(loop.gate(.click(elementID: 70), screenChangedEarlierInBatch: true, previousStepInBatch: .click(elementID: 70)) == .skipStaleIDs)
        #expect(loop.remainingStepBudget == 40)
        #expect(ActionTaskLoop.skipReason(for: .skipStepLimit, stepLimit: 40).contains("40-step"))
    }

    @Test func aBrushOfTheTrackpadDoesNotStopCallWork() {
        var callLogic = ActionCancelLogic()
        callLogic.arm(mouseTolerance: ActionCancelLogic.handsFreeMouseTolerance)
        #expect(callLogic.handle(PhysicalInputEvent(kind: .mouseMoved(deltaX: 20, deltaY: 10), timestamp: 1)) == .ignore)
        guard case .cancel = callLogic.handle(PhysicalInputEvent(kind: .mouseMoved(deltaX: 90, deltaY: 0), timestamp: 2)) else {
            Issue.record("a real move should still stop the work"); return
        }
        var clickLogic = ActionCancelLogic()
        clickLogic.arm(mouseTolerance: ActionCancelLogic.handsFreeMouseTolerance)
        guard case .cancel = clickLogic.handle(PhysicalInputEvent(kind: .mouseDown, timestamp: 1)) else { Issue.record("a click still stops it"); return }
    }

    @Test func howToKeepsTheSafetyRuleAndNamesCodexsHome() {
        let howTo = CallHands.howTo(owner: "Addy", leavesSafariAlone: false)
        #expect(howTo.contains("send, post, buy, pay, book or delete"))
        #expect(howTo.contains("Codex lives inside the ChatGPT app"))
        #expect(howTo.contains("[LOOK]"))
        #expect(!howTo.contains("Safari and Netflix"))
        #expect(CallHands.howTo(owner: "Addy", leavesSafariAlone: true).contains("Safari and Netflix"))
    }
}
