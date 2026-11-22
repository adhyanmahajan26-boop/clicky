import Foundation
import Testing
@testable import ClickyCore

struct ActionTaskReportTests {
    private func record(_ number: Int, _ step: ActionStep, _ outcome: ActionStepOutcome) -> ActionStepRecord {
        ActionStepRecord(number: number, step: step, tier: .free, tierReason: nil, outcome: outcome)
    }

    @Test func aFinishedTaskSaysEveryStepInPlainWords() {
        let records = [
            record(1, .openApp(name: "Safari", bundleIdentifier: nil), .done(detail: "brought it forward")),
            record(2, .click(elementID: 14), .done(detail: "pressed")),
        ]
        let report = ActionTaskReport.summary(records: records, ending: .done, stepNames: [2: "click “Search” in Safari"])
        #expect(report == "Done on screen: open Safari, click “Search” in Safari.")
    }

    @Test func aRefusedOrFailedStepIsNamed() {
        let records = [
            record(1, .openApp(name: "Safari", bundleIdentifier: nil), .done(detail: nil)),
            record(2, .click(elementID: 3), .failed(reason: "something is covering it")),
            record(3, .click(elementID: 4), .skipped(reason: "an earlier step in this batch was refused")),
        ]
        let report = ActionTaskReport.summary(records: records, ending: .done)
        #expect(report.hasPrefix("Finished, but not every step went through: "))
        #expect(report.contains("click #3 (failed: something is covering it)"))
        #expect(!report.contains("#4"))
    }

    @Test func waitingAndStoppedTasksSaySo() {
        let records = [record(1, .openApp(name: "Mail", bundleIdentifier: nil), .done(detail: nil))]
        let waiting = ActionTaskReport.summary(records: records, ending: .waitingForYes, pendingQuestion: "should i press send?")
        #expect(waiting.contains("Done so far: open Mail."))
        #expect(waiting.contains("Waiting for the owner's yes"))
        #expect(waiting.contains("should i press send?"))
        let stopped = ActionTaskReport.summary(records: [], ending: .cancelled, cancelReason: "you pressed Escape")
        #expect(stopped == "Stopped (you pressed Escape) before doing anything on screen.")
        #expect(ActionTaskReport.summary(records: [], ending: .done) == "Nothing was done on screen.")
    }
}
