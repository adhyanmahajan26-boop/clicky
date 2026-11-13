import Foundation
import Testing
@testable import ClickyCore

/// Air, 2026-11-13: "it keeps speaking after I press escape". Lines waiting to be spoken, and the "stopped: …" line an
/// Escape-cancelled action queued, played right after Escape silenced the answer.
struct EscapeSilenceTests {
    @Test func escapeDropsEveryLineQueuedBeforeIt() {
        var gate = SpokenLineGate()
        let doneLine = gate.ticket()
        let refusalLine = gate.ticket()
        #expect(gate.allows(doneLine))
        gate.silenceQueuedLines()
        #expect(!gate.allows(doneLine))
        #expect(!gate.allows(refusalLine))
    }

    @Test func aLineQueuedAfterEscapeIsSpoken() {
        var gate = SpokenLineGate()
        gate.silenceQueuedLines()
        let nextAnswerLine = gate.ticket()
        #expect(gate.allows(nextAnswerLine))
        // A second Escape silences it too.
        gate.silenceQueuedLines()
        #expect(!gate.allows(nextAnswerLine))
    }

    @Test func escapeCancelsAnActionWithoutSayingSo() {
        var logic = ActionCancelLogic()
        logic.arm()
        guard case .cancel(let reason) = logic.handle(PhysicalInputEvent(kind: .keyDown(keyCode: 53), eventSourceUserData: 0, timestamp: 1)) else {
            Issue.record("Escape should cancel the action")
            return
        }
        #expect(reason == ActionCancelLogic.escapeReason)
        #expect(!ActionCancelLogic.cancelSpeaksLine(forReason: reason))
        // Other input still says why it stopped.
        #expect(ActionCancelLogic.cancelSpeaksLine(forReason: "you moved the mouse"))
        #expect(ActionCancelLogic.cancelSpeaksLine(forReason: "you pressed a key"))
    }
}
