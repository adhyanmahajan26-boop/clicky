//
//  ActionTaskLoop.swift
//  ClickyCore
//
//  P7's observe → act loop, as pure state. One task = the owner's request
//  ("open chrome, google ramen, open the second result and summarize it").
//  Each Claude answer may carry one <actions> block; Clicky runs its steps,
//  then (unless the block said "done") re-captures the screen and asks
//  Claude again with ActionTaskLoop.continuationMessage — the step results
//  plus "new screen, ids are fresh". A task runs at most 12 steps in all.
//
//  Within one block, a step that changes the screen (open, search, click,
//  key, scroll, Return) makes every later step that names an element id
//  stale: those are skipped and reported, and Claude re-plans them on the
//  fresh screen.
//

import Foundation

public enum ActionStepOutcome: Equatable, Sendable {
    case done(detail: String?)
    case failed(reason: String)
    case refused(reason: String)
    case skipped(reason: String)
    case cancelled
    case declined
}

public struct ActionStepRecord: Equatable, Sendable {
    /// 1-based over the whole task.
    public var number: Int
    public var step: ActionStep
    public var tier: ActionTier?
    public var tierReason: String?
    public var outcome: ActionStepOutcome

    public init(number: Int, step: ActionStep, tier: ActionTier?, tierReason: String?, outcome: ActionStepOutcome) {
        self.number = number
        self.step = step
        self.tier = tier
        self.tierReason = tierReason
        self.outcome = outcome
    }

    /// "3. click #14 — done" (for Claude's results and the logs).
    public var resultLine: String {
        let outcomeText: String
        switch outcome {
        case .done(let detail): outcomeText = "done" + (detail.map { " (\($0))" } ?? "")
        case .failed(let reason): outcomeText = "failed: \(reason)"
        case .refused(let reason): outcomeText = "refused: \(reason) — don't retry it"
        case .skipped(let reason): outcomeText = "not run: \(reason)"
        case .cancelled: outcomeText = "cancelled"
        case .declined: outcomeText = "the user said no"
        }
        return "\(number). \(step.verb) — \(step.shortDescription) — \(outcomeText)"
    }

    /// "✓ open Chrome" (notch / dashboard).
    public var displayLine: String {
        let symbol: String
        switch outcome {
        case .done: symbol = "✓"
        case .failed: symbol = "!"
        case .refused: symbol = "✕"
        case .skipped: symbol = "–"
        case .cancelled, .declined: symbol = "■"
        }
        return "\(symbol) \(step.shortDescription)"
    }
}

/// What the executor should do with one step of a block, before it looks at the target.
public enum ActionBatchGate: Equatable, Sendable {
    case run
    case skipStaleIDs
    case skipStepLimit
}

public struct ActionTaskLoop: Equatable, Sendable {
    public static let maximumStepsPerTask = 12
    /// Observe turns after the first answer (one per batch), a backstop against ping-pong.
    public static let maximumObserveTurns = 12

    public let goal: String
    public let ownerTranscript: String
    public private(set) var records: [ActionStepRecord] = []
    /// Steps that actually ran (done or failed), counted against the 12.
    public private(set) var executedStepCount = 0
    public private(set) var observeTurnCount = 0
    /// Page text read by a summarize step without text, for the next observe turn.
    public var pendingPageText: String?

    public init(goal: String, ownerTranscript: String) {
        self.goal = goal
        self.ownerTranscript = ownerTranscript
    }

    public var remainingStepBudget: Int { max(0, Self.maximumStepsPerTask - executedStepCount) }
    public var isStepBudgetExhausted: Bool { remainingStepBudget == 0 }
    public var nextStepNumber: Int { records.count + 1 }

    /// Whether the step at this point of a batch runs. `screenChangedEarlierInBatch`
    /// is true once a screen-changing step of this same block ran.
    public func gate(_ step: ActionStep, screenChangedEarlierInBatch: Bool) -> ActionBatchGate {
        if isStepBudgetExhausted { return .skipStepLimit }
        if screenChangedEarlierInBatch && !step.referencedElementIDs.isEmpty { return .skipStaleIDs }
        return .run
    }

    public static func skipReason(for gate: ActionBatchGate) -> String {
        switch gate {
        case .run: return ""
        case .skipStaleIDs: return "the screen changed earlier in this batch; use the fresh ids"
        case .skipStepLimit: return "the \(maximumStepsPerTask)-step limit for one task was reached"
        }
    }

    public mutating func record(_ step: ActionStep, tier: ActionTier?, tierReason: String?, outcome: ActionStepOutcome) {
        records.append(ActionStepRecord(number: nextStepNumber, step: step, tier: tier, tierReason: tierReason, outcome: outcome))
        switch outcome {
        case .done, .failed: executedStepCount += 1
        default: break
        }
    }

    /// Records the parser's rejections (they count as "not run").
    public mutating func recordRejections(_ rejections: [ActionStepRejection]) {
        for rejection in rejections {
            records.append(ActionStepRecord(number: nextStepNumber, step: .wait(seconds: 0), tier: nil, tierReason: nil,
                                            outcome: .skipped(reason: "step \(rejection.position) (\(rejection.verb ?? "?")) couldn't be read: \(rejection.reason)")))
        }
    }

    /// After a batch: is there another observe turn?
    public func needsObserveTurn(planWasDone: Bool, wasCancelled: Bool) -> Bool {
        if wasCancelled { return false }
        if observeTurnCount >= Self.maximumObserveTurns { return false }
        // A summarize step read the page: Claude still has to write the summary.
        if pendingPageText != nil && !isStepBudgetExhausted { return true }
        if planWasDone { return false }
        return !isStepBudgetExhausted
    }

    public mutating func beginObserveTurn() {
        observeTurnCount += 1
    }

    /// The follow-up user text for the observe turn (the new screen follows it).
    public func continuationMessage(newRecordsFrom firstNewRecordIndex: Int = 0) -> String {
        var lines: [String] = []
        lines.append("ACTION TASK IN PROGRESS — continue it.")
        lines.append("goal: \(goal.isEmpty ? ownerTranscript : goal)")
        lines.append("steps used: \(executedStepCount) of \(Self.maximumStepsPerTask) (\(remainingStepBudget) left)")
        lines.append("results so far:")
        if records.isEmpty { lines.append("(none)") }
        lines += records.map(\.resultLine)
        if let pendingPageText {
            lines.append("")
            lines.append("PAGE TEXT (read from the front window, for your summary):")
            lines.append(pendingPageText)
            lines.append("END PAGE TEXT")
            lines.append("now reply with {\"do\":\"summarize\",\"text\":\"- point one\\n- point two …\"} (short bullet points) and \"done\":true, and say one short line.")
        }
        lines.append("")
        if records.contains(where: { if case .refused = $0.outcome { return true } else { return false } }) {
            lines.append("clicky already told the user out loud why a step was refused; don't repeat that at length.")
        }
        lines.append("the screen lists and screenshots below are fresh: the element ids are new. reply with the next <actions> block, or, when the goal is reached, say so in one short line with no actions block. don't repeat steps that are done, and don't retry refused ones.")
        return lines.joined(separator: "\n")
    }

    /// The final spoken line when the loop stops on its own.
    public var limitReachedLine: String {
        "i've used all \(Self.maximumStepsPerTask) steps for this task, so i'm stopping here."
    }
}

/// The owner's answer to a confirm-tier step ("should i press send?").
public enum ActionConfirmReply: Equatable, Sendable {
    case yes
    case no
    case notAReply

    static let fillerWords: Set<String> = ["clicky", "hey", "please", "ok", "okay", "um", "uh", "so", "well", "just"]
    static let yesPhrases: Set<String> = [
        "yes", "yeah", "yep", "yup", "sure", "confirm", "confirmed", "do it", "go ahead", "go for it", "send it", "press it", "click it", "yes do it",
        "yes please", "yes send it", "yes go ahead", "yes confirm", "approved", "approve", "affirmative", "correct", "thats right", "yes thats right",
        "submit it", "post it", "delete it", "buy it", "ok do it", "okay do it", "yes press it",
        // Hindi / Hinglish
        "haan", "ha", "haa", "han", "haan ji", "haanji", "ha ji", "ji", "ji haan", "theek hai", "thik hai", "kar do", "kardo", "haan kar do",
        "haan karo", "karo", "bilkul", "haan bhai", "chalo"
    ]
    static let noPhrases: Set<String> = [
        "no", "nope", "nah", "cancel", "cancel it", "stop", "dont", "do not", "never mind", "nevermind", "abort", "no thanks", "no dont",
        "dont do it", "dont send it", "no stop", "wait no", "hold on", "dont press it", "skip it", "skip",
        "nahi", "nahin", "na", "mat karo", "mat", "ruko", "rehne do", "nahi karo"
    ]

    public static func parse(_ transcript: String) -> ActionConfirmReply {
        let words = normalizedWords(transcript)
        guard !words.isEmpty, words.count <= 6 else { return .notAReply }
        let joined = words.joined(separator: " ")
        if noPhrases.contains(joined) { return .no }
        if yesPhrases.contains(joined) { return .yes }
        let withoutFiller = words.filter { !fillerWords.contains($0) }.joined(separator: " ")
        if withoutFiller.isEmpty { return words.contains("ok") || words.contains("okay") ? .yes : .notAReply }
        if noPhrases.contains(withoutFiller) { return .no }
        if yesPhrases.contains(withoutFiller) { return .yes }
        return .notAReply
    }

    static func normalizedWords(_ transcript: String) -> [String] {
        ActionWordMatch.normalized(transcript)
            .replacingOccurrences(of: "'", with: "")
            .components(separatedBy: CharacterSet.letters.inverted)
            .filter { !$0.isEmpty }
    }
}

/// "stop" / "cancel" said while a task runs (local, never sent to Claude).
public enum ActionStopCommand {
    static let phrases: Set<String> = [
        "stop", "stop it", "stop that", "stop stop", "cancel", "cancel that", "cancel it", "abort", "halt", "stop clicky", "clicky stop",
        "wait stop", "stop now", "never mind", "nevermind", "stop doing that", "cancel the task", "stop the task", "enough"
    ]

    public static func isStop(_ transcript: String) -> Bool {
        let words = ActionConfirmReply.normalizedWords(transcript)
        guard !words.isEmpty, words.count <= 5 else { return false }
        if phrases.contains(words.joined(separator: " ")) { return true }
        let withoutFiller = words.filter { !ActionConfirmReply.fillerWords.contains($0) }.joined(separator: " ")
        return phrases.contains(withoutFiller)
    }
}

/// A real click on the confirm card: untagged, and not in its first 0.5 s on screen.
public enum ActionConfirmClickGate {
    public static let minimumSecondsVisible: TimeInterval = 0.5

    public static func accepts(eventSourceUserData: Int64, secondsSinceShown: TimeInterval) -> Bool {
        !SyntheticEventTag.isTagged(userData: eventSourceUserData) && secondsSinceShown >= minimumSecondsVisible
    }
}
