//
//  ActionTaskReport.swift
//  ClickyCore
//
//  What an action task did on screen, in one short line. It goes to whoever asked for the task (Vello on a call, or in
//  its chat, when it ordered Pointer Assistant) once the whole task has ended, not when the first answer is spoken, and
//  into Pointer Assistant's own conversation, so the next question knows what it already clicked and opened.
//

import Foundation

public enum ActionTaskReport {
    public enum Ending: String, Equatable, Sendable {
        case done
        case cancelled
        case failed
        /// Stopped at a step that needs the owner's yes.
        case waitingForYes
    }

    /// The steps that were tried, one by one, with what came of each. Steps that never ran because of an earlier one
    /// are left out: the earlier one says why. `stepNames`: a plainer name for a step by its number ("click Send in
    /// Claude" rather than "click #14"), since element ids mean nothing outside the turn that saw them.
    public static func summary(records: [ActionStepRecord], ending: Ending, cancelReason: String? = nil, pendingQuestion: String? = nil,
                               stepNames: [Int: String] = [:]) -> String {
        let tried = records.filter { record in
            if case .skipped = record.outcome { return false }
            return true
        }
        let stepWords = tried.map { record -> String in
            let name = stepNames[record.number] ?? record.step.shortDescription
            switch record.outcome {
            case .done: return name
            case .failed(let reason): return "\(name) (failed: \(reason))"
            case .refused(let reason): return "\(name) (refused: \(reason))"
            case .skipped(let reason): return "\(name) (not run: \(reason))"
            case .cancelled: return "\(name) (stopped before it ran)"
            case .declined: return "\(name) (the owner said no)"
            }
        }
        var stepsLine = stepWords.isEmpty ? "" : stepWords.joined(separator: ", ")
        // Nothing ran at all: say why the steps didn't (a click Pointer Assistant couldn't read), rather than "Done."
        // or a bare "Nothing was done", so whoever asked can tell it to try again another way.
        let notRunReasons = records.compactMap { record -> String? in
            if case .skipped(let reason) = record.outcome { return reason }
            return nil
        }
        let nothingRanBecause = tried.isEmpty && !notRunReasons.isEmpty
            ? " Steps that didn't run: " + notRunReasons.prefix(3).joined(separator: "; ") + "."
            : ""
        if !tried.isEmpty, !notRunReasons.isEmpty { stepsLine += " (\(notRunReasons.count) more didn't run)" }
        switch ending {
        case .done:
            let allDone = tried.allSatisfy { record in
                if case .done = record.outcome { return true }
                return false
            }
            if stepsLine.isEmpty { return "Nothing was done on screen." + nothingRanBecause }
            return (allDone ? "Done on screen: " : "Finished, but not every step went through: ") + stepsLine + "."
        case .waitingForYes:
            let question = pendingQuestion.map { " It asked: \($0)" } ?? ""
            return (stepsLine.isEmpty ? "" : "Done so far: \(stepsLine). ") + "Waiting for the owner to say yes out loud before the next step (nothing to click).\(question)"
        case .cancelled:
            let reason = cancelReason.map { " (\($0))" } ?? ""
            return "Stopped\(reason)" + (stepsLine.isEmpty ? " before doing anything on screen." + nothingRanBecause : " after: \(stepsLine).")
        case .failed:
            return "It went wrong" + (stepsLine.isEmpty ? " before doing anything on screen." + nothingRanBecause : " after: \(stepsLine).")
        }
    }
}
