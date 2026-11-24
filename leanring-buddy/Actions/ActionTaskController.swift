//
//  ActionTaskController.swift
//  leanring-buddy
//
//  P7 computer-use actions: the observe → act loop in the app.
//
//  1. Claude's answer carries an <actions> block (ActionDSL). AnswerSession
//     hands it here with the turn's grounding (element ids #n).
//  2. The batch runs step by step while Claude's narration plays. Each step
//     is resolved (ActionExecutor.resolve, read only), classified
//     (ActionTierClassifier) and then:
//       free → run · countdown → 1.5 s in the notch first · confirm (only
//       sends, buys, deletes and the like) → the batch pauses on a confirm
//       card + "should i …? say yes or no." and the wake listener stays open
//       for the answer, so a spoken yes is enough; nobody has to click the
//       card (a click still counts, and moving the mouse away from the card
//       doesn't cancel what follows) · refused → not run, Clicky says why
//       out loud right away, the rest of the batch is dropped, Claude hears
//       why.
//     After a screen-changing step, later steps naming ids are skipped as
//     stale (ActionTaskLoop.gate).
//  3. Unless the block said "done", once the batch has run AND the answer
//     has finished speaking, Clicky asks Claude again: the same request with
//     the step results (ActionTaskLoop.continuationMessage) and a freshly
//     captured screen (sendTranscriptToClaudeWithScreenshot → prepareTurn).
//     A reply without an <actions> block ends the task. At most 12 steps.
//  Cancel: "stop" (local), Esc, the dashboard / notch Cancel, any other
//  owner utterance, and — while steps run — ANY physical input
//  (ActionInputMonitor; Clicky's own events are tagged and ignored).
//  The task is an AgentRecord (.actionTask) whose actionSteps / currentStep
//  are the live step list in the notch and the Agents dashboard.
//

import AppKit
import ClickyCore

@MainActor
final class ActionTaskController {
    enum Phase: String {
        case executing
        case countdown
        case awaitingConfirmation
        case waitingForModel
    }

    struct PendingConfirmation {
        var steps: [ActionStep]
        var plan: ActionPlan
        var groundedTurn: GroundedTurn
        weak var session: AnswerSession?
        var screenChangedEarlier: Bool
        var question: String
        var createdAt: Date
        /// The held step is a Return: "press enter" said again also counts as the yes.
        var isReturnStep: Bool
        /// Said when the window runs out without a yes.
        var expiryLine: String
    }

    /// Vello on a call drives this task: its own brain plans each batch in the call's conversation, and everything the task
    /// would say goes through the call's voice. Nil for Pointer Assistant's own turns.
    struct CallTaskHooks {
        /// A line the task says by itself (a refusal, a yes to wait for, a step left unsent).
        let speak: (String) -> Void
        /// The batch ran: the call shows its brain this text (the step results) with a fresh screen, and the brain's reply
        /// brings the next block (`handleCallActionsBlock`) or ends the task (`callTurnDidFinish`).
        let wantsObserveTurn: (String) -> Void
        /// The task ended: what was done (`ActionTaskReport`), how it ended, and why it was stopped if it was.
        let ended: (_ report: String, _ status: AgentStatus, _ cancelReason: String?) -> Void
    }

    final class ActiveTask {
        var loop: ActionTaskLoop
        /// The app the last step that ran acted on: a key step goes there when a notification alert or one of
        /// Theo's panels has come to the front (ActionKeyTarget).
        var lastTargetProcessIdentifier: pid_t?
        /// The last step that ran was switch_window / open_app: a key right after it goes to that app.
        var lastStepBroughtAppForward = false
        let agentID: String
        var phase: Phase = .executing
        var pendingConfirmation: PendingConfirmation?
        var isBatchRunning = false
        /// The answer turn that carried the current block is still open (speaking).
        var isAnswerTurnOpen: Bool
        var didReceiveBlockThisTurn = true
        var needsObserveTurn = false
        var isCancelled = false
        var currentStepText: String?
        /// The owner's words of the turn that carried the current block.
        var currentTranscript: String?
        /// Every tier decision, for actionsStatus.
        var tierDecisions: [[String: Any]] = []
        /// Plain names for steps by their number ("click “Send” in Claude"), for the report of what was done.
        var stepNames: [Int: String] = [:]
        /// Why it was cancelled, for the report.
        var cancelReason: String?
        let speaks: Bool
        /// False for the debug inbox's actionsRun: no observe turns.
        let continuesWithModel: Bool
        /// Set when Vello's call drives the task.
        var callHooks: CallTaskHooks?

        init(loop: ActionTaskLoop, agentID: String, isAnswerTurnOpen: Bool, speaks: Bool, continuesWithModel: Bool) {
            self.loop = loop
            self.agentID = agentID
            self.isAnswerTurnOpen = isAnswerTurnOpen
            self.speaks = speaks
            self.continuesWithModel = continuesWithModel
        }
    }

    static let confirmationLifetime: TimeInterval = 60
    static let settleAfterStep: UInt64 = 350_000_000
    static let settleAfterScreenChange: UInt64 = 700_000_000
    static let firstHighlightTagIndex = 50_000

    private unowned let companionManager: CompanionManager
    private let executor: ActionExecutor
    private let inputMonitor = ActionInputMonitor()
    private let confirmCard = ActionConfirmCardController()
    private(set) var task: ActiveTask?
    private var batchTask: Task<Void, Never>?
    private var confirmationExpiryTask: Task<Void, Never>?
    /// The last finished task's summary (actionsStatus after it ended).
    private var lastFinishedSummary: [String: Any]?
    /// "type it in Safari" covers that Safari window for 2 minutes of follow-ups (across tasks).
    private var safariFollowUp = ActionSafariFollowUp()
    private(set) var recentEvents: [String] = []
    /// What each recently ended task did on screen, by its agent id (`ActionTaskReport`), for whoever ordered it.
    private var endedTaskReports: [(agentID: String, report: String)] = []
    /// After a click on the confirm card the owner's hand is still on the mouse: moves until this uptime don't cancel.
    private var mouseMovesExcusedUntilUptime: TimeInterval?
    static let mouseMovesExcusedAfterCardClickSeconds: TimeInterval = 2.5
    /// What a task stopped by newer words reports, so Pointer Assistant (and Vello) never pick the old goal back up.
    nonisolated static let replacedByNewerRequestReason = "a newer request replaced it, so don't go back to it"
    /// The last block that started no task at all (unreadable, or actions switched off), so an order's report says
    /// nothing was done instead of repeating the spoken "on it".
    private(set) var lastBlockThatStartedNothing: (date: Date, why: String)?

    var isActive: Bool { task != nil }
    var isAwaitingConfirmation: Bool { task?.phase == .awaitingConfirmation }

    init(companionManager: CompanionManager) {
        self.companionManager = companionManager
        self.executor = ActionExecutor(companionManager: companionManager)
        executor.onSyntheticPointerEvent = { [weak self] in self?.inputMonitor.noteSyntheticPointerEvent() }
        inputMonitor.onPhysicalInput = { [weak self] reason in self?.cancel(reason: reason, stopsSpeech: true) }
        confirmCard.onConfirm = { [weak self] in self?.approvePendingStep(how: "click") }
        confirmCard.onCancel = { [weak self] in self?.declinePendingStep(how: "click") }
    }

    // MARK: - Blocks from Claude

    /// An <actions> block closed in this answer.
    func handleActionsBlock(_ blockBody: String, session: AnswerSession) {
        guard ClickySettings.isActionsEnabled else {
            lastBlockThatStartedNothing = (Date(), "doing things on screen is turned off")
            session.speakNow("doing things on screen is turned off.")
            return
        }
        // Pointer Assistant's own block while Vello's call is working on screen: the newer request wins.
        if let task, task.callHooks != nil { cancel(reason: Self.replacedByNewerRequestReason, stopsSpeech: false, speaksLine: false) }
        let plan: ActionPlan
        switch ActionDSL.parse(blockBody) {
        case .failure(let error):
            note("unreadable actions block: \(error.explanation)")
            if let task, task.phase == .waitingForModel {
                task.didReceiveBlockThisTurn = true
                finish(status: .failed, line: "i couldn't read my own next steps, so i stopped.", errorDescription: error.explanation)
            } else {
                lastBlockThatStartedNothing = (Date(), "its steps couldn't be read (\(error.explanation))")
                session.speakNow("i couldn't read those steps.")
            }
            return
        case .success(let parsedPlan):
            plan = parsedPlan
        }

        if let task {
            guard task.phase == .waitingForModel, !task.isBatchRunning else {
                note("a second actions block while a batch is \(task.phase.rawValue): ignored")
                return
            }
            task.didReceiveBlockThisTurn = true
            task.currentTranscript = session.transcript
            companionManager.agentsCenter.log(task.agentID, "next batch: \(plan.steps.count) steps\(plan.isDone ? " (done)" : "")")
            startBatch(plan: plan, steps: plan.steps, groundedTurn: session.groundedTurn, session: session, screenChangedEarlier: false, approvedFirstStep: false)
            return
        }

        let goal = plan.goal.isEmpty ? session.transcript : plan.goal
        let agentID = companionManager.agentsCenter.begin(kind: .actionTask, title: goal, model: nil, parentID: session.brainAgentID)
        let newTask = ActiveTask(loop: ActionTaskLoop(goal: goal, ownerTranscript: session.transcript), agentID: agentID,
                                 isAnswerTurnOpen: true, speaks: !session.coordinator.isSilent, continuesWithModel: true)
        task = newTask
        companionManager.agentsCenter.setCancelHandler(agentID) { [weak self] in self?.cancel(reason: "cancelled from the dashboard", stopsSpeech: true) }
        companionManager.agentsCenter.log(agentID, "heard: \(session.transcript)")
        companionManager.agentsCenter.log(agentID, "first batch: \(plan.steps.count) steps\(plan.isDone ? " (done)" : "")")
        note("task started: \(goal.prefix(80))")
        startBatch(plan: plan, steps: plan.steps, groundedTurn: session.groundedTurn, session: session, screenChangedEarlier: false, approvedFirstStep: false)
    }

    // MARK: - Vello on a call

    /// The task running now is Vello's call's.
    var isRunningCallTask: Bool { task?.callHooks != nil }

    /// The call's steps are being carried out right now (or wait for a yes). A new turn for the brain waits for them: a look
    /// taken mid-batch shows the screen half changed, and a block written from it replaced the steps still running (the
    /// Studio test on 25 Nov: TextEdit "not up yet", so it was opened again and the first job thrown away twice).
    var isCallBatchUnderWay: Bool {
        guard let task, task.callHooks != nil else { return false }
        return task.isBatchRunning || task.phase == .countdown || task.phase == .executing
    }

    /// Vello's call wrote an `<actions>` block. It starts the call's task, or is the next batch of the one waiting for it.
    /// `groundedTurn`: the screen the brain was last shown, whose ids the block uses. Returns words for the brain when nothing
    /// could start (unreadable, switched off), nil when steps are running.
    func handleCallActionsBlock(_ blockBody: String, groundedTurn: GroundedTurn, ownerWords: String, hooks: CallTaskHooks) -> String? {
        let plan: ActionPlan
        switch ActionDSL.parse(blockBody) {
        case .failure(let error):
            note("unreadable actions block from the call: \(error.explanation)")
            if let task, task.callHooks != nil, task.phase == .waitingForModel {
                task.didReceiveBlockThisTurn = true
                finish(status: .failed, line: nil, errorDescription: error.explanation)
            }
            return "Your last steps couldn't be read (\(error.explanation)), so nothing ran. Write the block again as one JSON object."
        case .success(let parsedPlan):
            plan = parsedPlan
        }
        if let task {
            if task.callHooks != nil, task.phase == .waitingForModel, !task.isBatchRunning {
                task.didReceiveBlockThisTurn = true
                companionManager.agentsCenter.log(task.agentID, "next batch: \(plan.steps.count) steps\(plan.isDone ? " (done)" : "")")
                startBatch(plan: plan, steps: plan.steps, groundedTurn: groundedTurn, session: nil, screenChangedEarlier: false, approvedFirstStep: false)
                return nil
            }
            // Something else is going on screen (Pointer Assistant's own task, or a batch still running): the call's newer
            // block replaces it.
            cancel(reason: Self.replacedByNewerRequestReason, stopsSpeech: false, speaksLine: false)
        }
        let goal = plan.goal.isEmpty ? ownerWords : plan.goal
        let agentID = companionManager.agentsCenter.begin(kind: .actionTask, title: goal, model: nil)
        let newTask = ActiveTask(loop: ActionTaskLoop(goal: goal, ownerTranscript: ownerWords, stepLimit: CallHands.stepLimit, observeTurnLimit: CallHands.observeTurnLimit),
                                 agentID: agentID, isAnswerTurnOpen: true, speaks: true, continuesWithModel: true)
        newTask.callHooks = hooks
        task = newTask
        companionManager.agentsCenter.setCancelHandler(agentID) { [weak self] in self?.cancel(reason: "cancelled from the dashboard", stopsSpeech: false) }
        companionManager.agentsCenter.log(agentID, "Vello on a call: \(ownerWords)")
        companionManager.agentsCenter.log(agentID, "first batch: \(plan.steps.count) steps\(plan.isDone ? " (done)" : "")")
        note("call task started: \(goal.prefix(80))")
        startBatch(plan: plan, steps: plan.steps, groundedTurn: groundedTurn, session: nil, screenChangedEarlier: false, approvedFirstStep: false)
        return nil
    }

    /// A reply of the call's brain ended while its task is open. `hadBlock`: it carried the next steps. `failed`: the brain
    /// gave no answer or was cut off.
    func callTurnDidFinish(hadBlock: Bool, failed: Bool) {
        guard let task, task.callHooks != nil else { return }
        task.isAnswerTurnOpen = false
        if task.phase == .waitingForModel && !task.isBatchRunning {
            if failed {
                finish(status: .failed, line: nil, errorDescription: "the brain gave no answer")
                return
            }
            if !hadBlock && !task.didReceiveBlockThisTurn {
                // An answer with no more steps: the job is done (or Vello said why it can't be).
                finish(status: .done, line: nil)
                return
            }
        }
        continueIfReady()
    }

    /// The owner spoke on the call while the call's task runs. A yes or no to a step waiting for one is answered here
    /// (true). Anything else stops the steps where they are and gives back what was done, for the brain to hear with the
    /// owner's words: it decides whether that's a new job or a comment on this one.
    enum CallOwnerWordsOutcome {
        case answeredConfirmation
        case pausedWork(report: String)
        case noCallTask
    }

    func takeCallOwnerWords(_ words: String, ownerName: String) -> CallOwnerWordsOutcome {
        guard let task, let hooks = task.callHooks else { return .noCallTask }
        if task.phase == .awaitingConfirmation {
            if task.pendingConfirmation?.isReturnStep == true, ActionEnterIntent.ownerAsked(words, stepPressesReturn: true) {
                approvePendingStep(how: "the call")
                return .answeredConfirmation
            }
            switch ActionConfirmReply.parseRelayed(words) {
            case .yes:
                approvePendingStep(how: "the call")
                return .answeredConfirmation
            case .no:
                // Declining ends the task; the brain hears it from the hook like any other ending.
                declinePendingStep(how: "the call")
                return .answeredConfirmation
            case .notAReply:
                break
            }
        }
        // The task's end is told to the brain with the owner's words, not as a turn of its own.
        task.callHooks = CallTaskHooks(speak: hooks.speak, wantsObserveTurn: { _ in }, ended: { _, _, _ in })
        let agentID = task.agentID
        cancel(reason: "\(ownerName) started talking", stopsSpeech: false, speaksLine: false)
        let report = endedTaskReports.last(where: { $0.agentID == agentID })?.report ?? "nothing yet."
        return .pausedWork(report: report)
    }

    /// The call ended: its task stops with it.
    func endCallTask() {
        guard let task, task.callHooks != nil else { return }
        task.callHooks = CallTaskHooks(speak: { _ in }, wantsObserveTurn: { _ in }, ended: { _, _, _ in })
        cancel(reason: "the call ended", stopsSpeech: false, speaksLine: false)
    }

    // MARK: - One press Prism picked

    /// The same steps, tiers and confirm cards as a click from Claude. Returns when it's finished, and whether it went through.
    func press(elementID: Int, label: String, ownerWords: String, groundedTurn: GroundedTurn, speaks: Bool) async -> Bool {
        guard task == nil, ClickySettings.isActionsEnabled else { return false }
        let plan = #"{"goal":"press","steps":[{"do":"click","id":\#(elementID)}],"done":true}"#
        guard case .success(let parsed) = ActionDSL.parse(plan) else { return false }
        let agentID = companionManager.agentsCenter.begin(kind: .actionTask, title: "press \(label)", model: nil)
        let newTask = ActiveTask(loop: ActionTaskLoop(goal: "press \(label)", ownerTranscript: ownerWords), agentID: agentID, isAnswerTurnOpen: false,
                                 speaks: speaks, continuesWithModel: false)
        task = newTask
        companionManager.agentsCenter.setCancelHandler(agentID) { [weak self] in self?.cancel(reason: "cancelled from the dashboard", stopsSpeech: true) }
        companionManager.agentsCenter.log(agentID, "heard: \(ownerWords)")
        startBatch(plan: parsed, steps: parsed.steps, groundedTurn: groundedTurn, session: nil, screenChangedEarlier: false, approvedFirstStep: false)
        while task === newTask {
            if Task.isCancelled { return false }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return !newTask.isCancelled
    }

    // MARK: - The batch

    /// A click in a task the owner started with "do it for me" (the steps Claudia had marked).
    static func isClickForMeClick(_ step: ActionStep, transcript: String) -> Bool {
        guard ClickForMeCommand.matches(transcript) else { return false }
        if case .click = step { return true }
        return false
    }

    private func startBatch(plan: ActionPlan, steps: [ActionStep], groundedTurn: GroundedTurn, session: AnswerSession?,
                            screenChangedEarlier: Bool, approvedFirstStep: Bool) {
        guard let task else { return }
        if !approvedFirstStep { task.loop.recordRejections(plan.rejectedSteps) }
        task.isBatchRunning = true
        task.phase = .executing
        publish()
        batchTask = Task { [weak self] in
            await self?.runBatch(plan: plan, steps: steps, groundedTurn: groundedTurn, session: session,
                                 screenChangedEarlier: screenChangedEarlier, approvedFirstStep: approvedFirstStep)
        }
    }

    private func runBatch(plan: ActionPlan, steps: [ActionStep], groundedTurn: GroundedTurn, session: AnswerSession?,
                          screenChangedEarlier: Bool, approvedFirstStep: Bool) async {
        guard let task else { return }
        // On a call the owner's hand rests on the trackpad: only a real move takes over (ClickyCore `ActionCancelLogic`).
        inputMonitor.arm(excusingMouseMovesUntilUptime: mouseMovesExcusedUntilUptime,
                         mouseTolerance: task.callHooks != nil ? ActionCancelLogic.handsFreeMouseTolerance : ActionCancelLogic.mouseJitterTolerance)
        mouseMovesExcusedUntilUptime = nil
        defer { if self.task === task { inputMonitor.disarm() } }
        var screenChanged = screenChangedEarlier
        var stoppedEarly = false
        let context = ActionTurnContext(ownerTranscript: task.loop.ownerTranscript, currentTranscript: task.currentTranscript,
                                        safariFollowUp: safariFollowUp, now: Date())

        for (offset, step) in steps.enumerated() {
            if task.isCancelled || Task.isCancelled { return }
            if stoppedEarly {
                task.loop.record(step, tier: nil, tierReason: nil, outcome: .skipped(reason: "an earlier step in this batch was refused"))
                continue
            }
            let gate = task.loop.gate(step, screenChangedEarlierInBatch: screenChanged, previousStepInBatch: offset > 0 ? steps[offset - 1] : nil)
            guard gate == .run else {
                task.loop.record(step, tier: nil, tierReason: nil, outcome: .skipped(reason: ActionTaskLoop.skipReason(for: gate, stepLimit: task.loop.stepLimit)))
                publish()
                continue
            }

            let target = executor.resolve(step, groundedTurn: groundedTurn, ownerTranscript: task.loop.ownerTranscript,
                                          previousTargetProcessIdentifier: task.lastTargetProcessIdentifier,
                                          previousStepBroughtAppForward: task.lastStepBroughtAppForward)
            if let failure = target.failure {
                task.loop.record(step, tier: nil, tierReason: nil, outcome: .skipped(reason: failure))
                publish()
                continue
            }
            let decision = target.refusal.map { ActionTierDecision(.refused, $0) }
                ?? ActionTierClassifier.classify(step, target: target.facts, context: context)
            recordDecision(step: step, decision: decision, target: target)
            // He named Safari in this task: that Safari window stays covered for follow-ups.
            if decision.tier != .refused, let facts = target.facts, ActionTierClassifier.isSafari(facts), context.ownerNamedSafariOrNetflix {
                safariFollowUp.noteOwnerNamedSafari(windowIdentifier: facts.windowIdentifier, at: Date())
            }

            switch decision.tier {
            case .refused:
                task.loop.record(step, tier: .refused, tierReason: decision.reason, outcome: .refused(reason: decision.reason))
                publish()
                speakRefusal(decision.refusalLine(for: step))
                stoppedEarly = true
                continue
            case .confirm where !(approvedFirstStep && offset == 0) && !Self.isClickForMeClick(step, transcript: task.loop.ownerTranscript):
                pauseForConfirmation(step: step, decision: decision, target: target, remainingSteps: Array(steps[offset...]), plan: plan,
                                     groundedTurn: groundedTurn, session: session, screenChangedEarlier: screenChanged)
                return
            case .confirm where Self.isClickForMeClick(step, transcript: task.loop.ownerTranscript):
                // "Do it for me": the owner asked for exactly these clicks, so each gets the countdown instead of a confirm card.
                fallthrough
            case .countdown:
                let countdownSeconds = ClickySettings.actionsCountdownSeconds
                task.phase = .countdown
                task.currentStepText = "\(step.shortDescription) in \(countdownSeconds.formatted(.number.precision(.fractionLength(0...1)))) s — move or press anything to cancel"
                publish()
                let endUptime = ProcessInfo.processInfo.systemUptime + countdownSeconds
                while ProcessInfo.processInfo.systemUptime < endUptime {
                    if task.isCancelled || Task.isCancelled { return }
                    try? await Task.sleep(nanoseconds: 50_000_000)
                }
            case .free, .confirm:
                break
            }

            if task.isCancelled || Task.isCancelled { return }
            task.phase = .executing
            task.currentStepText = step.shortDescription
            publish()
            // P9 Enter policy: a message to other people (he didn't say send) or a plain field is typed without its Return.
            let stepToRun = decision.dropsReturn ? step.withoutReturn : step
            let result: ActionPerformResult
            if decision.dropsReturn, case .key = step {
                result = ActionPerformResult(.done(detail: "left unsent"))
            } else {
                // A call's task draws nothing through Pointer Assistant's answer on screen.
                let answerSession = task.callHooks != nil ? nil : (session ?? companionManager.currentAnswerSession)
                result = await executor.perform(stepToRun, target: target, groundedTurn: groundedTurn, session: answerSession,
                                                ownerTranscript: task.loop.ownerTranscript, isCancelled: { [weak task] in task?.isCancelled ?? true })
            }
            if decision.dropsReturn, let line = decision.spokenLine, case .done = result.outcome { say(line, for: task) }
            if task.isCancelled { return }
            if case .done = result.outcome {
                if let actedProcessIdentifier = target.processIdentifier ?? target.runningApplication?.processIdentifier {
                    task.lastTargetProcessIdentifier = actedProcessIdentifier
                }
                switch step {
                case .switchWindow, .openApp: task.lastStepBroughtAppForward = true
                default: task.lastStepBroughtAppForward = false
                }
            }
            task.loop.record(step, tier: decision.tier, tierReason: decision.reason, outcome: result.outcome)
            if case .refused(let reason) = result.outcome { speakRefusal("i didn't \(step.shortDescription): \(reason).") }
            if let pageText = result.pageText { task.loop.pendingPageText = pageText }
            if let articleText = result.articleText { task.loop.pendingArticleText = articleText }
            task.currentStepText = nil
            companionManager.agentsCenter.log(task.agentID, task.loop.records.last?.resultLine ?? "")
            publish()
            if case .done = result.outcome, step.changesScreen(targetRole: target.facts?.role) { screenChanged = true }
            try? await Task.sleep(nanoseconds: step.changesScreen ? Self.settleAfterScreenChange : Self.settleAfterStep)
        }

        guard !task.isCancelled else { return }
        task.isBatchRunning = false
        task.currentStepText = nil
        inputMonitor.disarm()
        // Vello on a call always looks once more after a batch, even one it called done: it checks the screen shows the job
        // worked before it says so (Pointer Assistant called "done" on a prompt whose typing step never ran).
        let callLooksAgain = task.callHooks != nil && task.loop.observeTurnCount < task.loop.observeTurnLimit && !task.loop.isStepBudgetExhausted
        let wantsObserveTurn = (task.loop.needsObserveTurn(planWasDone: plan.isDone, wasCancelled: false) || callLooksAgain) && task.continuesWithModel
        if wantsObserveTurn {
            task.phase = .waitingForModel
            task.needsObserveTurn = true
            publish()
            continueIfReady()
            return
        }
        // No observe turn follows: say what was refused, or that the limit was hit.
        var closingLine: String?
        if task.loop.records.contains(where: { if case .refused = $0.outcome { return true } else { return false } }) {
            // Already said out loud when it was refused.
            closingLine = nil
        } else if task.loop.isStepBudgetExhausted && !plan.isDone {
            closingLine = task.loop.limitReachedLine
        }
        finish(status: .done, line: closingLine)
    }

    /// A refused step is never silent: one short spoken line, right away.
    private func speakRefusal(_ line: String) {
        guard let task else { return }
        note("refused: \(line)")
        say(line, for: task)
    }

    /// A line the task says by itself: through the call's voice when Vello's call drives it, else Pointer Assistant's.
    private func say(_ line: String, for task: ActiveTask) {
        if let callHooks = task.callHooks {
            callHooks.speak(line)
        } else if task.speaks {
            companionManager.speakCodeModeLine(line)
        }
    }

    private func recordDecision(step: ActionStep, decision: ActionTierDecision, target: ResolvedActionTarget) {
        guard let task else { return }
        var entry: [String: Any] = ["step": step.shortDescription, "verb": step.verb, "tier": decision.tier.rawValue, "reason": decision.reason]
        if let facts = target.facts {
            entry["app"] = facts.applicationName ?? facts.bundleIdentifier ?? NSNull()
            entry["role"] = facts.role ?? facts.groundingRole?.rawValue ?? NSNull()
            entry["label"] = facts.label.map { String($0.prefix(60)) } ?? NSNull()
        }
        task.stepNames[task.loop.nextStepNumber] = Self.plainStepName(step, facts: target.facts)
        task.tierDecisions.append(entry)
        if task.tierDecisions.count > 40 { task.tierDecisions.removeFirst(task.tierDecisions.count - 40) }
        companionManager.agentsCenter.log(task.agentID, "tier \(decision.tier.rawValue): \(step.shortDescription) — \(decision.reason)")
    }

    /// "click “Send” in Claude" for "click #14": an element id means nothing once its turn is over.
    static func plainStepName(_ step: ActionStep, facts: ActionTargetFacts?) -> String {
        var name = step.shortDescription
        if let label = facts?.label?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty {
            let quotedLabel = NSRegularExpression.escapedTemplate(for: "\u{201C}\(String(label.prefix(40)))\u{201D}")
            name = name.replacingOccurrences(of: #"#\d+"#, with: quotedLabel, options: .regularExpression)
        }
        if let appName = facts?.applicationName, !appName.isEmpty, !name.localizedCaseInsensitiveContains(appName) {
            name += " in \(appName)"
        }
        return name
    }

    // MARK: - Whoever ordered the task

    /// The task running now, by its agent id.
    var activeTaskID: String? { task?.agentID }

    /// Waits until the task with this id has ended, or has stopped for the owner's yes, for at most `seconds`, and says
    /// what it did on screen. Nil when it's still going after that long.
    func waitForOutcome(ofTask agentID: String, upToSeconds seconds: Double) async -> String? {
        let giveUpDate = Date().addingTimeInterval(seconds)
        while Date() < giveUpDate {
            if let task, task.agentID == agentID {
                if task.phase == .awaitingConfirmation {
                    return ActionTaskReport.summary(records: task.loop.records, ending: .waitingForYes,
                                                    pendingQuestion: task.pendingConfirmation?.question, stepNames: task.stepNames)
                }
            } else {
                return endedTaskReports.last(where: { $0.agentID == agentID })?.report
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        return nil
    }

    /// A yes or no for the step that's waiting, given on a call: the owner said it to Vello, who passed it on.
    /// True when these words answered it.
    func answerConfirmation(withWords words: String) -> Bool {
        guard let task, task.phase == .awaitingConfirmation else { return false }
        if task.pendingConfirmation?.isReturnStep == true, ActionEnterIntent.ownerAsked(words, stepPressesReturn: true) {
            approvePendingStep(how: "the call")
            return true
        }
        // Vello passes the yes on in its own words ("Yes, Addy confirmed. Click Displays."): the opening yes counts.
        switch ActionConfirmReply.parseRelayed(words) {
        case .yes:
            approvePendingStep(how: "the call")
            return true
        case .no:
            declinePendingStep(how: "the call")
            return true
        case .notAReply:
            return false
        }
    }

    // MARK: - Confirm tier

    private func pauseForConfirmation(step: ActionStep, decision: ActionTierDecision, target: ResolvedActionTarget, remainingSteps: [ActionStep], plan: ActionPlan,
                                      groundedTurn: GroundedTurn, session: AnswerSession?, screenChangedEarlier: Bool) {
        guard let task else { return }
        inputMonitor.disarm()
        let appName = target.facts?.applicationName.map { " in \($0)" } ?? ""
        let question = decision.confirmQuestion ?? "should i \(step.shortDescription)\(appName)? \(decision.reason). say yes or no."
        let isReturnStep = step.pressesReturn
        let lifetime = decision.confirmWindowSeconds ?? Self.confirmationLifetime
        // Hands-free: the wake listener takes the next words without "hey pointer", so the yes or no is just said.
        // (On a call the call's own ears hear it and Vello passes it on; in a hands-free session that mic hears it.)
        companionManager.wakeWordController.keepFollowUpOpen(forSeconds: lifetime)
        task.pendingConfirmation = PendingConfirmation(steps: remainingSteps, plan: plan, groundedTurn: groundedTurn, session: session,
                                                       screenChangedEarlier: screenChangedEarlier, question: question, createdAt: Date(),
                                                       isReturnStep: isReturnStep,
                                                       expiryLine: isReturnStep ? "okay, i didn't press enter." : "stopped — no answer to the confirmation.")
        task.phase = .awaitingConfirmation
        task.isBatchRunning = false
        task.currentStepText = "waiting for your yes: \(step.shortDescription)"
        publish()
        confirmCard.show(title: "\(step.shortDescription.prefix(1).uppercased() + step.shortDescription.dropFirst())\(appName)?", detail: decision.reason)
        say(question, for: task)
        note("waiting for confirmation: \(step.shortDescription)")
        confirmationExpiryTask?.cancel()
        let speaks = task.speaks && task.callHooks == nil
        confirmationExpiryTask = Task { [weak self] in
            // The window starts once the question has been said.
            if speaks {
                try? await Task.sleep(nanoseconds: 400_000_000)
                let giveUpDate = Date().addingTimeInterval(20)
                while let self, self.companionManager.speechOutputClient.isPlaying, Date() < giveUpDate, !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 150_000_000)
                }
            }
            try? await Task.sleep(nanoseconds: UInt64(lifetime * 1_000_000_000))
            guard !Task.isCancelled, let self, self.task === task, task.phase == .awaitingConfirmation else { return }
            self.expirePendingStep()
        }
    }

    private func approvePendingStep(how: String) {
        guard let task, task.phase == .awaitingConfirmation, let pending = task.pendingConfirmation else { return }
        confirmationExpiryTask?.cancel()
        confirmCard.hide()
        task.pendingConfirmation = nil
        note("confirmed by \(how)")
        companionManager.agentsCenter.log(task.agentID, "confirmed by \(how)")
        if how == "click" {
            mouseMovesExcusedUntilUptime = ProcessInfo.processInfo.systemUptime + Self.mouseMovesExcusedAfterCardClickSeconds
        }
        startBatch(plan: pending.plan, steps: pending.steps, groundedTurn: pending.groundedTurn, session: pending.session,
                   screenChangedEarlier: pending.screenChangedEarlier, approvedFirstStep: true)
    }

    /// No yes in time: the step isn't done, and Clicky says so.
    private func expirePendingStep() {
        guard let task, task.phase == .awaitingConfirmation, let pending = task.pendingConfirmation, let step = pending.steps.first else { return }
        confirmCard.hide()
        task.loop.record(step, tier: .confirm, tierReason: nil, outcome: .cancelled)
        task.pendingConfirmation = nil
        note("no answer to the confirmation: \(step.shortDescription)")
        finish(status: .cancelled, line: pending.expiryLine)
    }

    private func declinePendingStep(how: String) {
        guard let task, task.phase == .awaitingConfirmation, let pending = task.pendingConfirmation, let step = pending.steps.first else { return }
        confirmationExpiryTask?.cancel()
        confirmCard.hide()
        task.loop.record(step, tier: .confirm, tierReason: nil, outcome: .declined)
        for remainingStep in pending.steps.dropFirst() {
            task.loop.record(remainingStep, tier: nil, tierReason: nil, outcome: .skipped(reason: "the step before it was declined"))
        }
        note("declined by \(how)")
        finish(status: .cancelled, line: "okay, i won't.")
    }

    // MARK: - The owner's words

    /// Called for the owner's own utterances (push-to-talk or hands-free).
    /// True when it was answered here (a yes/no to a confirm card, or
    /// "stop"); any other words end the task and the turn goes ahead.
    func handleOwnerTranscript(_ transcript: String) -> Bool {
        noteSafariNaming(in: transcript)
        guard let task else { return false }
        if task.phase == .awaitingConfirmation {
            // "Press enter? Say yes." — "press enter" (or its ASR look-alikes) again is a yes too.
            if task.pendingConfirmation?.isReturnStep == true, ActionEnterIntent.ownerAsked(transcript, stepPressesReturn: true) {
                approvePendingStep(how: "voice")
                return true
            }
            switch ActionConfirmReply.parse(transcript) {
            case .yes:
                approvePendingStep(how: "voice")
                return true
            case .no:
                declinePendingStep(how: "voice")
                return true
            case .notAReply:
                break
            }
        }
        if ActionStopCommand.isStop(transcript) {
            cancel(reason: "you said stop", stopsSpeech: true)
            return true
        }
        cancel(reason: Self.replacedByNewerRequestReason, stopsSpeech: false, speaksLine: false)
        return false
    }

    /// True when these words answer the confirm card that's waiting (hands-free routing).
    func isReplyToPendingConfirmation(_ transcript: String) -> Bool {
        guard let task, task.phase == .awaitingConfirmation else { return false }
        if task.pendingConfirmation?.isReturnStep == true, ActionEnterIntent.ownerAsked(transcript, stepPressesReturn: true) { return true }
        return ActionConfirmReply.parse(transcript) != .notAReply
    }

    /// The owner named Safari (conversation or task): its front window is covered for 2 minutes.
    private func noteSafariNaming(in transcript: String) {
        guard ActionWordMatch.containsWord(in: transcript, anyOf: ["safari"]) else { return }
        let safari = ActionExecutor.frontSafariWindowIdentifier()
        guard safari.isRunning else { return }
        safariFollowUp.noteOwnerNamedSafari(windowIdentifier: safari.windowIdentifier, at: Date())
    }

    /// Esc while no batch runs (a running batch is cancelled by the input monitor).
    /// Never consumes the key: Escape's usual stop still happens.
    func handleEscapeKey() -> Bool {
        if task != nil { cancel(reason: "you pressed Escape", stopsSpeech: false) }
        return false
    }

    // MARK: - Turns

    /// Every answer turn's end (CompanionManager).
    func answerTurnDidFinish(turnError: Error?, wasCancelled: Bool) {
        // Vello's call reports its own turns (`callTurnDidFinish`).
        guard let task, task.callHooks == nil else { return }
        task.isAnswerTurnOpen = false
        if task.phase == .waitingForModel && !task.isBatchRunning {
            if wasCancelled || turnError != nil {
                // The observe turn itself failed or was cut off.
                finish(status: wasCancelled ? .cancelled : .failed, line: nil, errorDescription: turnError.map { String(describing: $0) })
                return
            }
            if !task.didReceiveBlockThisTurn {
                // Claude answered without more steps: the goal is reached (or it explained why not).
                finish(status: .done, line: nil)
                return
            }
        }
        continueIfReady()
    }

    /// The observe turn starts once the batch has run and the answer has finished speaking.
    private func continueIfReady() {
        guard let task, task.needsObserveTurn, !task.isBatchRunning, !task.isAnswerTurnOpen, task.phase == .waitingForModel else { return }
        task.needsObserveTurn = false
        task.loop.beginObserveTurn()
        let continuationText = task.loop.continuationMessage()
        task.loop.pendingPageText = nil
        task.loop.pendingArticleText = nil
        task.didReceiveBlockThisTurn = false
        task.isAnswerTurnOpen = true
        task.currentStepText = "looking at the screen again"
        publish()
        companionManager.agentsCenter.log(task.agentID, "observe turn \(task.loop.observeTurnCount)")
        if let callHooks = task.callHooks {
            // Vello's call shows its own brain the results with a fresh screen, in the same conversation it talks in.
            Task { @MainActor [weak self] in
                guard let self, self.task === task, !task.isCancelled else { return }
                callHooks.wantsObserveTurn(continuationText)
            }
            return
        }
        var turnOptions = CompanionManager.TurnOptions()
        turnOptions.speaksResponse = task.speaks
        turnOptions.extraUserText = continuationText
        turnOptions.keepsLiveScreenMarks = true
        let ownerTranscript = task.loop.ownerTranscript
        // Next run loop turn: the answer that just ended may still be unwinding its task.
        Task { @MainActor [weak self] in
            guard let self, self.task === task, !task.isCancelled else { return }
            self.companionManager.sendTranscriptToClaudeWithScreenshot(transcript: ownerTranscript, turnOptions: turnOptions)
        }
    }

    // MARK: - Ending

    /// Stops the task now. `stopsSpeech`: also cut Clicky's narration and any answer in flight.
    func cancel(reason: String, stopsSpeech: Bool, speaksLine: Bool = true) {
        guard let task else { return }
        // The "look again" turn this task already sent: its answer would plan more steps for the old goal and, with
        // the task gone, start it over as a new one (the owner's "it keeps doing the old thing after I said a new one").
        let ownObserveTurnIsInFlight = task.phase == .waitingForModel && task.isAnswerTurnOpen && task.loop.observeTurnCount > 0
        task.isCancelled = true
        task.cancelReason = reason
        batchTask?.cancel()
        note("cancelled: \(reason)")
        if let pending = task.pendingConfirmation, let step = pending.steps.first {
            task.loop.record(step, tier: .confirm, tierReason: nil, outcome: .cancelled)
        }
        finish(status: .cancelled, line: speaksLine ? "stopped: \(reason)." : nil, errorDescription: nil)
        if task.callHooks == nil, stopsSpeech || ownObserveTurnIsInFlight { companionManager.stopBuddySpeechAndCancelResponse() }
    }

    private func finish(status: AgentStatus, line: String?, errorDescription: String? = nil) {
        guard let task else { return }
        self.task = nil
        task.isCancelled = task.isCancelled || status != .done
        inputMonitor.disarm()
        confirmCard.hide()
        confirmationExpiryTask?.cancel()
        task.currentStepText = nil
        publish(task)
        companionManager.agentsCenter.log(task.agentID, "finished: \(status.rawValue)\(line.map { " — \($0)" } ?? "")")
        companionManager.agentsCenter.finish(task.agentID, status: status, errorDescription: errorDescription)
        lastFinishedSummary = summary(of: task, status: status.rawValue)
        note("task \(status.rawValue) after \(task.loop.executedStepCount) steps")
        let ending: ActionTaskReport.Ending = status == .done ? .done : (status == .failed ? .failed : .cancelled)
        let report = ActionTaskReport.summary(records: task.loop.records, ending: ending, cancelReason: task.cancelReason ?? line,
                                              stepNames: task.stepNames)
        endedTaskReports.append((task.agentID, report))
        if endedTaskReports.count > 10 { endedTaskReports.removeFirst(endedTaskReports.count - 10) }
        // The next question knows what was already clicked and opened, instead of starting from nothing.
        companionManager.rememberActionTaskOutcome(goal: task.loop.goal, report: report)
        if let callHooks = task.callHooks {
            // The call's brain hears how it ended and says so in its own words; only a refusal or a no was said already.
            callHooks.ended(report, status, task.cancelReason ?? (status == .done ? nil : line))
            return
        }
        if let line, task.speaks { companionManager.speakCodeModeLine(line) }
    }

    // MARK: - Notch / dashboard

    private func publish(_ explicitTask: ActiveTask? = nil) {
        guard let publishedTask = explicitTask ?? task else { return }
        let stepLines = publishedTask.loop.records.map(\.displayLine)
        let currentStep = publishedTask.currentStepText
        companionManager.agentsCenter.update(publishedTask.agentID) { record in
            record.actionSteps = stepLines
            record.currentStep = currentStep
            record.phase = publishedTask.phase.rawValue
        }
    }

    private func note(_ line: String) {
        print("🖱️ Actions: \(line)")
        recentEvents.append("\(Self.timeFormatter.string(from: Date())) \(line)")
        if recentEvents.count > 30 { recentEvents.removeFirst(recentEvents.count - 30) }
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    private func summary(of task: ActiveTask, status: String) -> [String: Any] {
        [
            "agentID": task.agentID,
            "goal": task.loop.goal,
            "ownerTranscript": task.loop.ownerTranscript,
            "status": status,
            "phase": task.phase.rawValue,
            "stepsUsed": task.loop.executedStepCount,
            "stepLimit": task.loop.stepLimit,
            "observeTurns": task.loop.observeTurnCount,
            "steps": task.loop.records.map(\.resultLine),
            "tierDecisions": task.tierDecisions,
            "currentStep": task.currentStepText ?? NSNull(),
            "pendingConfirmation": task.pendingConfirmation?.question ?? NSNull(),
            "monitorArmed": inputMonitor.isArmed
        ]
    }

    /// The debug inbox's actionsStatus.
    func statusSnapshot() -> [String: Any] {
        [
            "enabled": ClickySettings.isActionsEnabled,
            "countdownSeconds": ClickySettings.actionsCountdownSeconds,
            "active": task.map { summary(of: $0, status: "running") } ?? NSNull(),
            "last": lastFinishedSummary ?? NSNull(),
            "recentEvents": recentEvents
        ]
    }

    // MARK: - Debug runs

    /// actionsRun: a step list as if Claude had sent it, on a fresh capture.
    /// dryRun (the default) resolves and classifies every step and returns
    /// the tier decisions without running anything.
    func debugRun(planObject: [String: Any], ownerTranscript: String, isDryRun: Bool) async -> (isSuccess: Bool, result: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(planObject), let data = try? JSONSerialization.data(withJSONObject: planObject) else {
            return (false, ["error": "steps must be JSON"])
        }
        let plan: ActionPlan
        switch ActionDSL.parse(String(decoding: data, as: UTF8.self)) {
        case .failure(let error): return (false, ["error": error.explanation])
        case .success(let parsedPlan): plan = parsedPlan
        }
        guard let groundedTurn = try? await companionManager.groundingCoordinator.prepareTurn(keyUpDate: Date()) else {
            return (false, ["error": "couldn't capture the screen"])
        }
        let context = ActionTurnContext(ownerTranscript: ownerTranscript, safariFollowUp: safariFollowUp, now: Date())
        if isDryRun {
            var screenChanged = false
            let loop = ActionTaskLoop(goal: plan.goal, ownerTranscript: ownerTranscript)
            let decisions: [[String: Any]] = plan.steps.map { step in
                var entry: [String: Any] = ["step": step.shortDescription, "verb": step.verb]
                let gate = loop.gate(step, screenChangedEarlierInBatch: screenChanged)
                if step.changesScreen { screenChanged = true }
                if gate != .run { entry["gate"] = ActionTaskLoop.skipReason(for: gate, stepLimit: loop.stepLimit) }
                let target = executor.resolve(step, groundedTurn: groundedTurn, ownerTranscript: ownerTranscript)
                if let failure = target.failure {
                    entry["tier"] = NSNull()
                    entry["failure"] = failure
                    return entry
                }
                let decision = target.refusal.map { ActionTierDecision(.refused, $0) } ?? ActionTierClassifier.classify(step, target: target.facts, context: context)
                entry["tier"] = decision.tier.rawValue
                entry["reason"] = decision.reason
                if let facts = target.facts {
                    entry["facts"] = ["bundle": facts.bundleIdentifier ?? NSNull(), "app": facts.applicationName ?? NSNull(), "window": facts.windowTitle ?? NSNull(),
                                      "role": facts.role ?? NSNull(), "subrole": facts.subrole ?? NSNull(), "groundingRole": facts.groundingRole?.rawValue ?? NSNull(),
                                      "label": facts.label ?? NSNull()] as [String: Any]
                }
                return entry
            }
            return (true, ["dryRun": true, "done": plan.isDone, "rejected": plan.rejectedSteps.map { "step \($0.position): \($0.reason)" }, "decisions": decisions])
        }
        guard task == nil else { return (false, ["error": "an action task is already running (actionsCancel first)"]) }
        let agentID = companionManager.agentsCenter.begin(kind: .actionTask, title: plan.goal.isEmpty ? "debug actions" : plan.goal, model: nil)
        let newTask = ActiveTask(loop: ActionTaskLoop(goal: plan.goal, ownerTranscript: ownerTranscript), agentID: agentID, isAnswerTurnOpen: false,
                                 speaks: false, continuesWithModel: false)
        task = newTask
        companionManager.agentsCenter.setCancelHandler(agentID) { [weak self] in self?.cancel(reason: "cancelled from the dashboard", stopsSpeech: false) }
        note("debug run: \(plan.steps.count) steps")
        startBatch(plan: plan, steps: plan.steps, groundedTurn: groundedTurn, session: companionManager.currentAnswerSession,
                   screenChangedEarlier: false, approvedFirstStep: false)
        return (true, ["dryRun": false, "started": true, "agentID": agentID])
    }
}
