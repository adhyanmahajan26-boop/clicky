//
//  CodeModeController.swift
//  leanring-buddy
//
//  P5 Code mode in the app. Claude's `<codetask>` block lands here (via
//  AnswerSession); this controller runs the preflight once per launch,
//  resolves the spoken repo name (confident: "Opening o/n #N" for 2 s, Esc
//  cancels; otherwise a top-4 chooser), hands the task to ClickyCore's
//  CodeTaskEngine, speaks read-only answers, and shows the review panel for
//  everything else. Nothing goes out until a real click on a panel button:
//  the button must pass the click gate, every Approve precondition must hold
//  (agent group reaped, no processes left under the worktree/ctx, push
//  dry-run OK, no un-acked red finding), and the ApprovalKey of what the
//  panel showed must still match the disk before each command.
//
//  Live use: Code mode can be switched by voice ([CODEMODE:on]/[CODEMODE:off]
//  from the main brain, honoured only when the user's words say "code mode";
//  otherwise a one-click "Turn on code mode" chip that only a real click works);
//  "this repo" comes from the front Xcode / VS Code / Terminal window
//  (FrontWindowProbe → FrontWindowRepoResolver); Clicky's own checkouts are
//  never used (CodeRepoDenylist); while the agent runs the panel shows its
//  current step, files changed so far and elapsed time, with a short spoken
//  update at most every 20 s; several tasks asked at once are queued and run
//  one after another, each with its own review. None of this changes the
//  click gate: outward steps still need a real click in the review panel.
//

import AppKit
import ClickyCore
import Combine
import Foundation

/// The turn a code task came from (for logs).
struct CodeTurnContext {
    var transcript: String
    /// The front window when the task arrived (read only for "this repo").
    var frontWindow: FrontWindowContext? = nil
}

/// A task waiting for the one before it to finish (or the running one).
struct QueuedCodeTask {
    var task: CodeTask
    var context: CodeTurnContext
    /// Its record in the Agents dashboard.
    var agentID: String? = nil
    /// "send this to the X project": the folder the owner's named project
    /// resolved to (alias, confident match or his pick). The repo name in
    /// `task` is then only a label; this path is used, after the same
    /// denylist checks and the same 2 s "Opening" card.
    var pinnedRootPath: String? = nil
    /// The screenshot / session extras for this run (never from the model's block).
    var launchOptions = CodeTaskLaunchOptions()
}

@MainActor
final class CodeModeController: ObservableObject {
    @Published private(set) var isEnabled = ClickySettings.isCodeEnabled
    @Published private(set) var preflightStatusLine = ClickySettings.isCodeEnabled ? "Not checked yet" : "Off"
    @Published private(set) var phaseDescription = "Idle"
    @Published private(set) var isBusy = false

    private(set) var preflightReport: CodePreflightReport?
    private var preflightTask: Task<CodePreflightReport, Never>?
    private var toolPaths: CodeToolPaths?
    private var cachedLocalRepos: [LocalRepoEntry]?
    /// The clones indexed so far (empty until a code task has run): the project
    /// bridge's front-window repo lookup uses them for title-only matches.
    var indexedLocalReposForFrontWindow: [LocalRepoEntry] { cachedLocalRepos ?? [] }

    /// Every clone under the repo roots (indexed once and cached, like a
    /// code task's lookup), Clicky's own checkouts left out. Read-only:
    /// a folder walk plus `git config --get` for the remotes.
    func localRepositoriesForProjectLookup() async -> [LocalRepoEntry] {
        if cachedLocalRepos == nil {
            let tools: CodeToolPaths
            if let toolPaths {
                tools = toolPaths
            } else {
                guard let locatedTools = try? await CodeToolPaths.locate() else { return [] }
                tools = locatedTools
                toolPaths = locatedTools
            }
            let git = HardenedGit(gitPath: tools.git, ghPath: tools.gh, runner: ChildProcessCommandRunner())
            cachedLocalRepos = await LocalRepoIndexer(git: git, roots: ClickySettings.codeRepoRoots).index()
        }
        return (cachedLocalRepos ?? []).filter { !CodeRepoDenylist.isDeniedLocalRoot($0.folderPath) }
    }
    private var cachedAccountRepos: [String]?
    private var activeTask: Task<Void, Never>?
    private var activeEngine: CodeTaskEngine?
    private var activeReview: PreparedReview?
    /// The last review shown (kept after it closes, for codeStatus / tests).
    private var lastReviewSummary: [String: Any]?
    private var acks: Set<String> = []
    /// The ApprovalKey of each button as the panel shows it right now.
    private var displayedApprovalKeys: [String: ApprovalKey] = [:]
    private var approveConditions: ReviewApproveConditions?
    private var isAmendingCommit = false
    private var amendDebounceTask: Task<Void, Never>?
    private var sweepRetryTask: Task<Void, Never>?
    private var checksPollTask: Task<Void, Never>?
    private var isExecuting = false
    private var pendingRepositoryChoice: CheckedContinuation<RepoCandidate?, Never>?
    private var pendingQuestionAnswer: CheckedContinuation<Bool, Never>?
    private var isOpeningCancelled = false
    private var recentEvents: [String] = []

    /// Asked while another task runs: run in order, each with its own review.
    private(set) var queuedTasks: [QueuedCodeTask] = []
    static let maximumQueuedTasks = 4
    private var activeQueuedTask: QueuedCodeTask?
    private var activeRepository: ResolvedRepository?
    private var progressTracker: CodeTaskProgressTracker?
    private var progressTickerTask: Task<Void, Never>?
    /// The user hid the progress card (Hide / Esc / close): don't bring it back for this task.
    private var isProgressPanelHidden = false
    private var lastNarration: String?
    private var lastToggleDescription: String?
    /// Which run owns the controller's state (a cancelled run's late clean-up must not end the next one).
    private var activeRunIdentifier: UUID?

    private let speak: (String) -> Void
    private let panelController: ReviewPanelController
    /// The Agents dashboard (set by CompanionManager). Each task is one
    /// record: queued, running (steps, files, worktree), then done / failed / cancelled.
    weak var agentsCenter: AgentsCenter?
    /// Set when the active run fails or is cancelled; read when it finishes.
    private var activeRunFailureDescription: String?
    private var wasActiveRunCancelled = false
    /// "Turn on code mode": shown when [CODEMODE:on] came without the user saying "code mode".
    private let chipController = CodeModeChipController()
    private var pendingChipTranscript: String?
    /// After a chip click: ask the refused request again, now with Code mode on.
    var onChipContinueRequest: ((String) -> Void)?

    init(speak: @escaping (String) -> Void) {
        self.speak = speak
        self.panelController = ReviewPanelController(state: ReviewPanelState(content: CodeReviewContent(repositoryFullName: "")))
        wirePanelCallbacks()
        chipController.onTurnOn = { [weak self] in self?.turnOnFromChip() }
        chipController.onLog = { [weak self] line in self?.record(line) }
    }

    // MARK: - Settings

    func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: ClickySettings.Keys.codeEnabled)
        isEnabled = enabled
        if enabled {
            preflightStatusLine = "Checking…"
            Task { _ = await ensurePreflight(force: true) }
        } else {
            cancelQueuedAgents()
            queuedTasks = []
            cancelActiveTask()
            preflightStatusLine = "Off"
        }
    }

    /// [CODEMODE:on] / [CODEMODE:off] from the main brain. "on" is honoured
    /// only when the user's own words say "code mode" (CodeModeToggle);
    /// otherwise the chip is offered.
    @discardableResult
    func handleSpokenToggle(isOn requestedOn: Bool, transcript: String) -> CodeModeToggle.Decision {
        let decision = CodeModeToggle.decide(isOn: requestedOn, isCurrentlyOn: isEnabled, transcript: transcript)
        lastToggleDescription = "\(requestedOn ? "on" : "off") → \(decision) from \"\(transcript.prefix(80))\""
        record("spoken toggle: \(lastToggleDescription ?? "")")
        switch decision {
        case .turnOn:
            chipController.hide()
            setEnabled(true)
        case .turnOff:
            chipController.hide()
            setEnabled(false)
        case .unchanged: break
        case .refused:
            // The tag alone never switches it on: offer the one-click chip (a real click only).
            record("refused [CODEMODE:on]: the user didn't say \"code mode\"; showing the Turn on code mode chip")
            pendingChipTranscript = transcript
            chipController.show()
        }
        return decision
    }

    /// The chip's real click: Code mode on, then (if the words asked for
    /// more than the switch) the same request again with Code mode on.
    private func turnOnFromChip() {
        let transcript = pendingChipTranscript
        pendingChipTranscript = nil
        lastToggleDescription = "on → chip click from \"\(transcript?.prefix(80) ?? "")\""
        setEnabled(true)
        if let transcript, CodeModeToggle.shouldContinueRequest(afterTurningOn: transcript) {
            onChipContinueRequest?(transcript)
        }
    }

    /// Runs the preflight once per launch (again when `force`).
    func ensurePreflight(force: Bool = false) async -> CodePreflightReport {
        if !force, let preflightReport { return preflightReport }
        if !force, let preflightTask { return await preflightTask.value }
        let task = Task { () -> CodePreflightReport in
            do {
                let tools = try await CodeToolPaths.locate()
                self.toolPaths = tools
                let probeDirectory = ClaudeArgs.sessionWorkingDirectoryURL
                try? FileManager.default.createDirectory(at: probeDirectory, withIntermediateDirectories: true)
                try? FileManager.default.createDirectory(at: CodeTaskWorkspace.defaultRootURL, withIntermediateDirectories: true)
                let log = CodeCommandLog(fileURL: CodeTaskWorkspace.defaultRootURL.appendingPathComponent("preflight-commands.log"))
                return await CodePreflight(tools: tools, runner: ChildProcessCommandRunner(log: log), probeWorkingDirectory: probeDirectory.path).run()
            } catch {
                return CodePreflightReport.failed(String(describing: error))
            }
        }
        preflightTask = task
        let report = await task.value
        preflightTask = nil
        preflightReport = report
        preflightStatusLine = isEnabled ? report.statusLine : "Off"
        record("preflight: \(report.statusLine)\n\(report.flagTable)")
        return report
    }

    // MARK: - Entry points

    /// From AnswerSession. False when the block isn't a valid CodeTask.
    func handleCodeTaskBlock(_ blockBody: String, context: CodeTurnContext) -> Bool {
        guard let task = try? CodeTask.decode(blockBody: blockBody) else {
            record("undecodable codetask: \(blockBody.prefix(200))")
            return false
        }
        start(task, context: context)
        return true
    }

    func start(_ task: CodeTask, context: CodeTurnContext) {
        start(task, context: context, pinnedRootPath: nil, launchOptions: CodeTaskLaunchOptions())
    }

    /// "update it to the X project": the owner named the project and asked
    /// for the change in his own words, so that counts as asking for code
    /// mode for it (said aloud and saved on, like "turn on code mode").
    /// Everything after is the normal repo_change path: the 2 s "Opening"
    /// card, a worktree, the review panel, outward steps only on a click.
    func startNamedProjectTask(rootPath: String, displayName: String, instructions: String, transcript: String, launchOptions: CodeTaskLaunchOptions) {
        if !isEnabled {
            record("named project \(displayName): turning code mode on (the owner asked for the change in \(displayName))")
            lastToggleDescription = "on → named project \"\(displayName)\" from \"\(transcript.prefix(80))\""
            speak(NamedProjectSpeech.turningOnCodeModeLine(repositoryName: displayName))
            setEnabled(true)
        }
        let task = CodeTask(action: .repoChange, repo: displayName, instructions: instructions)
        start(task, context: CodeTurnContext(transcript: transcript), pinnedRootPath: rootPath, launchOptions: launchOptions)
    }

    private func start(_ task: CodeTask, context: CodeTurnContext, pinnedRootPath: String?, launchOptions: CodeTaskLaunchOptions) {
        guard isEnabled else {
            speak("Code mode is off. Say \"turn on code mode\" first.")
            return
        }
        var context = context
        // "this repo": remember the front window now, before any panel takes focus.
        if pinnedRootPath == nil, context.frontWindow == nil, FrontWindowRepoResolver.isDeicticRepoName(task.repo) {
            context.frontWindow = FrontWindowProbe.capture()
        }
        var queuedTask = QueuedCodeTask(task: task, context: context, pinnedRootPath: pinnedRootPath, launchOptions: launchOptions)
        guard !isBusy else {
            guard queuedTasks.count < Self.maximumQueuedTasks else {
                speak("I already have \(Self.maximumQueuedTasks) code tasks waiting. Let me finish those first.")
                return
            }
            queuedTask.agentID = beginAgentRecord(for: task, status: .queued)
            queuedTasks.append(queuedTask)
            refreshQueueCounts()
            record("queued #\(queuedTasks.count) \(task.action.rawValue) repo=\(task.repo)")
            // Several tasks from one answer: Claude already said they'll run in order.
            if activeQueuedTask?.context.transcript != context.transcript {
                speak("Got it, I'll do that one after the current task.")
            }
            return
        }
        begin(queuedTask)
    }

    private func begin(_ queuedTask: QueuedCodeTask) {
        var queuedTask = queuedTask
        let task = queuedTask.task
        record("start \(task.action.rawValue) repo=\(task.repo) pr=\(task.pr.map(String.init) ?? "-") from \"\(queuedTask.context.transcript.prefix(80))\"")
        isBusy = true
        if queuedTask.agentID == nil { queuedTask.agentID = beginAgentRecord(for: task, status: .running) }
        let agentID = queuedTask.agentID
        agentsCenter?.update(agentID) { agentRecord in
            agentRecord.status = .running
            agentRecord.startedAt = Date()
        }
        agentsCenter?.log(agentID, "started")
        agentsCenter?.setCancelHandler(agentID) { [weak self] in self?.stopTask(agentID: agentID) }
        activeRunFailureDescription = nil
        wasActiveRunCancelled = false
        activeQueuedTask = queuedTask
        refreshQueueCounts()
        isProgressPanelHidden = false
        let runIdentifier = UUID()
        activeRunIdentifier = runIdentifier
        activeTask = Task { [weak self] in
            await self?.run(task, frontWindow: queuedTask.context.frontWindow, pinnedRootPath: queuedTask.pinnedRootPath,
                            launchOptions: queuedTask.launchOptions, runIdentifier: runIdentifier)
        }
    }

    /// The next queued task, once the current one is fully done.
    private func startNextQueuedTaskIfAny() {
        guard isEnabled, !isBusy, !queuedTasks.isEmpty else { return }
        let next = queuedTasks.removeFirst()
        record("dequeued \(next.task.action.rawValue) repo=\(next.task.repo) (\(queuedTasks.count) left)")
        begin(next)
    }

    /// "Stop" on the progress card: the running task and the queue end; nothing was sent.
    func stopAllTasks() {
        let hadWork = isBusy || !queuedTasks.isEmpty
        cancelQueuedAgents()
        queuedTasks = []
        cancelActiveTask()
        if hadWork { speak("Stopped. Nothing was sent.") }
    }

    func cancelActiveTask() {
        if isBusy { wasActiveRunCancelled = true }
        activeEngine?.cancelAgent()
        activeTask?.cancel()
        checksPollTask?.cancel()
        pendingRepositoryChoice?.resume(returning: nil)
        pendingRepositoryChoice = nil
        pendingQuestionAnswer?.resume(returning: false)
        pendingQuestionAnswer = nil
        finishTask(hidePanel: true)
    }

    /// Esc while "Opening…" is up cancels the task.
    func handleEscapeKey() -> Bool {
        guard panelController.isVisible, case .opening = panelController.state.mode else { return false }
        isOpeningCancelled = true
        return true
    }

    /// Voice can only arm the primary button (highlight); a click is still needed.
    func armPrimaryButtonByVoice() {
        panelController.state.primaryButtonView?.armFromVoice()
    }

    // MARK: - Running a task

    private func run(_ task: CodeTask, frontWindow: FrontWindowContext?, pinnedRootPath: String?, launchOptions: CodeTaskLaunchOptions,
                     runIdentifier: UUID) async {
        defer { if activeRunIdentifier == runIdentifier && activeReview == nil && !isExecuting { finishTask(hidePanel: true) } }
        setPhase("Checking code mode")
        let report = await ensurePreflight()
        guard report.isReady, let toolPaths else {
            speak(report.spokenExplanation)
            return
        }
        setPhase("Finding \(task.repo)")
        let foundRepository: ResolvedRepository?
        if let pinnedRootPath {
            foundRepository = await resolvePinnedRepository(rootPath: pinnedRootPath, task: task, tools: toolPaths)
        } else {
            foundRepository = await resolveRepository(for: task, frontWindow: frontWindow, tools: toolPaths)
        }
        guard var repository = foundRepository, !Task.isCancelled else { return }
        activeRepository = repository
        if repository.clonePath == nil, Self.needsLocalClone(task) {
            guard let clonePath = await offerClone(repository.remote, tools: toolPaths) else { return }
            repository.clonePath = clonePath
        }
        let resolvedRepository = repository
        agentsCenter?.update(activeQueuedTask?.agentID) { agentRecord in
            agentRecord.repository = resolvedRepository.isLocalOnly ? resolvedRepository.remote.name : resolvedRepository.remote.fullName
            agentRecord.clonePath = resolvedRepository.clonePath
            agentRecord.title = AgentsCenter.cleanTitle(Self.progressTitle(for: task, repository: resolvedRepository))
        }

        do {
            let workspace = try CodeTaskWorkspace.create()
            let engine = CodeTaskEngine(tools: toolPaths, preflight: report, runner: ChildProcessCommandRunner(log: CodeCommandLog(fileURL: workspace.commandLogURL)),
                                        isBashAllowed: ClickySettings.isCodeBashAllowed)
            engine.onProgress = { [weak self] progress in
                let controller = self
                Task { @MainActor in
                    controller?.setPhase(progress)
                    controller?.progressTracker?.setPhase(progress.prefix(1).lowercased() + String(progress.dropFirst()))
                }
            }
            engine.onAgentProgress = { [weak self] progressEvent in
                let controller = self
                Task { @MainActor in controller?.applyAgentProgress(progressEvent) }
            }
            let usageAgentID = activeQueuedTask?.agentID
            engine.launchOptions = launchOptions
            engine.onNote = { [weak self] note in
                let controller = self
                Task { @MainActor in
                    controller?.record(note)
                    controller?.agentsCenter?.log(usageAgentID, note)
                }
            }
            engine.onAgentUsage = { [weak self] agentUsage in
                let controller = self
                Task { @MainActor in
                    controller?.agentsCenter?.addUsage(usageAgentID, agentUsage)
                    controller?.agentsCenter?.log(usageAgentID, "agent usage: \(agentUsage.tokenSummary)\(agentUsage.costText.map { " · \($0)" } ?? "")")
                }
            }
            activeEngine = engine
            startProgress(title: Self.progressTitle(for: task, repository: repository))
            defer { stopProgress() }
            record("task dir \(workspace.taskDirectoryURL.path)")
            let preparation = try await engine.prepare(task, repository: repository, workspace: workspace)
            stopProgress()
            switch preparation {
            case .spoken(let answer, let agentReport):
                record("answer (\(agentReport.map { String(describing: $0.outcome).prefix(60) } ?? "no agent")): \(answer.prefix(200))")
                agentsCenter?.log(activeQueuedTask?.agentID, "answer: \(answer)")
                speak(answer)
            case .review(let review):
                await presentReview(review)
            }
        } catch is CancellationError {
            record("cancelled")
            wasActiveRunCancelled = true
        } catch let engineError as CodeTaskEngineError {
            record("engine: \(engineError)")
            activeRunFailureDescription = engineError.spokenMessage
            speak(engineError.spokenMessage)
        } catch let worktreeError as WorktreeError {
            record("worktree: \(worktreeError)")
            activeRunFailureDescription = "Worktree: \(worktreeError.description)"
            switch worktreeError {
            case .integrityChanged:
                speak("Something changed git's settings or hooks during the run, so I stopped and won't use that change.")
            case .existingWorktreeHasUnpushedWork:
                speak("There's already a Clicky worktree for that with unpushed work. Clean it up from the menu first.")
            default:
                speak("I couldn't set up the worktree: \(worktreeError.description).")
            }
        } catch {
            record("failed: \(error)")
            activeRunFailureDescription = String(describing: error).prefix(300).description
            speak("The code task failed: \(String(describing: error).prefix(140)).")
        }
    }

    private static func needsLocalClone(_ task: CodeTask) -> Bool {
        switch task.action {
        case .askRepo, .fixReview, .fixCI, .edit, .resolveConflicts, .repoChange: return true
        default: return false
        }
    }

    /// Test only (debug inbox codeCloseReview): the review panel's Close, exactly as its Close button —
    /// nothing outward happens; the worktree and branch stay.
    func closeReviewForTest() -> Bool {
        guard panelController.isVisible else { return false }
        panelController.state.onCancel()
        return true
    }

    private func finishTask(hidePanel: Bool) {
        finishActiveAgentRecord()
        stopProgress()
        activeRunIdentifier = nil
        activeQueuedTask = nil
        activeRepository = nil
        activeTask = nil
        activeEngine = nil
        activeReview = nil
        displayedApprovalKeys = [:]
        approveConditions = nil
        acks = []
        isExecuting = false
        amendDebounceTask?.cancel()
        sweepRetryTask?.cancel()
        isBusy = false
        setPhase("Idle")
        if hidePanel { panelController.hide() }
        if !queuedTasks.isEmpty {
            Task { @MainActor [weak self] in self?.startNextQueuedTaskIfAny() }
        }
    }

    // MARK: - Agents dashboard

    /// The record for a task asked by voice (queued or about to run).
    private func beginAgentRecord(for task: CodeTask, status: AgentStatus) -> String? {
        guard let agentsCenter else { return nil }
        let action = task.action.rawValue.replacingOccurrences(of: "_", with: " ")
        let title = "\(action.prefix(1).uppercased() + action.dropFirst()) \(task.repo)\(task.pr.map { " #\($0)" } ?? "")"
        let agentID = agentsCenter.begin(kind: .codeTask, title: title, model: AgentInvocation.model, status: status)
        agentsCenter.update(agentID) { agentRecord in agentRecord.repository = task.repo }
        agentsCenter.log(agentID, "asked: \(task.instructions)")
        if status == .queued {
            agentsCenter.log(agentID, "queued behind the current code task")
            agentsCenter.setCancelHandler(agentID) { [weak self] in self?.stopTask(agentID: agentID) }
        }
        return agentID
    }

    /// Each record's "waiting after this" count.
    private func refreshQueueCounts() {
        let waitingCount = queuedTasks.count
        agentsCenter?.update(activeQueuedTask?.agentID) { agentRecord in agentRecord.queuedBehindCount = waitingCount }
        for (queuePosition, queuedTask) in queuedTasks.enumerated() {
            agentsCenter?.update(queuedTask.agentID) { agentRecord in agentRecord.queuedBehindCount = waitingCount - queuePosition - 1 }
        }
    }

    private func cancelQueuedAgents() {
        for queuedTask in queuedTasks {
            agentsCenter?.log(queuedTask.agentID, "removed from the queue")
            agentsCenter?.finish(queuedTask.agentID, status: .cancelled)
        }
    }

    /// The active task's record ends with how the run went.
    private func finishActiveAgentRecord() {
        guard let agentID = activeQueuedTask?.agentID else { return }
        let status: AgentStatus
        if wasActiveRunCancelled {
            status = .cancelled
        } else if activeRunFailureDescription != nil {
            status = .failed
        } else {
            status = .done
        }
        agentsCenter?.update(agentID) { agentRecord in
            if agentRecord.phase == "waiting for review" { agentRecord.phase = nil }
        }
        agentsCenter?.log(agentID, status.rawValue)
        agentsCenter?.finish(agentID, status: status, errorDescription: activeRunFailureDescription)
        activeRunFailureDescription = nil
        wasActiveRunCancelled = false
    }

    /// Cancel from the Agents dashboard: the running task stops like the
    /// progress card's Stop (nothing was sent); a queued one leaves the queue.
    func stopTask(agentID: String?) {
        guard let agentID else { return }
        if activeQueuedTask?.agentID == agentID {
            record("stop from the Agents window")
            cancelActiveTask()
            speak("Stopped. Nothing was sent.")
        } else if let queuePosition = queuedTasks.firstIndex(where: { $0.agentID == agentID }) {
            let removedTask = queuedTasks.remove(at: queuePosition)
            record("removed queued \(removedTask.task.action.rawValue) repo=\(removedTask.task.repo) from the Agents window")
            agentsCenter?.log(agentID, "removed from the queue")
            agentsCenter?.finish(agentID, status: .cancelled)
            refreshQueueCounts()
        }
    }

    /// The dashboard record whose review is open right now (Open review).
    var activeReviewAgentID: String? {
        activeReview != nil ? activeQueuedTask?.agentID : nil
    }

    /// Open review: shows the existing review panel again. Every button in it
    /// still needs a real click through the gate; nothing else changes.
    @discardableResult
    func showActiveReview(agentID: String) -> Bool {
        guard activeReview != nil, activeQueuedTask?.agentID == agentID else { return false }
        record("review reopened from the Agents window")
        panelController.show(mode: .review)
        return true
    }

    // MARK: - Live progress

    static func progressTitle(for task: CodeTask, repository: ResolvedRepository) -> String {
        let name = repository.isLocalOnly ? repository.remote.name : repository.remote.fullName
        switch task.flow {
        case .readOnlyAgent: return "Reading \(name)\(task.pr.map { " #\($0)" } ?? "")"
        case .editingAgent: return "Working on \(name)\(task.pr.map { " #\($0)" } ?? "")"
        case .panelOnly: return "Preparing \(task.action.rawValue.replacingOccurrences(of: "_", with: " ")) on \(name)"
        }
    }

    private var progressTitle = ""

    private func startProgress(title: String) {
        progressTitle = title
        progressTracker = CodeTaskProgressTracker(startedAt: Date(), initialStep: "starting")
        lastNarration = nil
        progressTickerTask?.cancel()
        progressTickerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled else { return }
                self?.progressTick()
            }
        }
        refreshProgressPanel()
    }

    private func stopProgress() {
        progressTickerTask?.cancel()
        progressTickerTask = nil
        if case .working = panelController.state.mode, panelController.isVisible { panelController.hide() }
    }

    private func applyAgentProgress(_ progressEvent: AgentProgressEvent) {
        guard progressTracker != nil, progressTickerTask != nil else { return }
        progressTracker?.apply(progressEvent)
        let changedFiles = progressTracker?.changedFiles ?? []
        agentsCenter?.update(activeQueuedTask?.agentID) { agentRecord in
            agentRecord.currentStep = progressEvent.stepDescription
            agentRecord.changedFiles = changedFiles
        }
        agentsCenter?.log(activeQueuedTask?.agentID, progressEvent.stepDescription + (progressEvent.toolName.isEmpty ? "" : " (\(progressEvent.toolName))"))
        setPhase(progressEvent.stepDescription.prefix(1).uppercased() + String(progressEvent.stepDescription.dropFirst()))
        refreshProgressPanel()
    }

    private func progressTick() {
        guard progressTickerTask != nil else { return }
        refreshProgressPanel()
        if ClickySettings.isCodeProgressNarrationEnabled, let narration = progressTracker?.narrationIfDue(now: Date()) {
            lastNarration = narration
            record("narrate: \(narration)")
            speak(narration)
        }
    }

    private func refreshProgressPanel() {
        guard let progressTracker, progressTickerTask != nil, !isProgressPanelHidden else { return }
        // Only over its own card or a hidden panel (never over the chooser or a question).
        if panelController.isVisible, !Self.isWorkingMode(panelController.state.mode) { return }
        panelController.showProgress(progressTracker.snapshot(title: progressTitle, now: Date(), queuedCount: queuedTasks.count))
    }

    private static func isWorkingMode(_ mode: ReviewPanelState.Mode) -> Bool {
        if case .working = mode { return true }
        return false
    }

    private func setPhase(_ phase: String) {
        phaseDescription = phase
        record("phase: \(phase)")
        logPhaseToAgentRecord(phase)
    }

    /// Engine phases ("Making a worktree…") go into the task's dashboard log.
    private func logPhaseToAgentRecord(_ phase: String) {
        guard phase != "Idle", let agentsCenter, let agentID = activeQueuedTask?.agentID else { return }
        // applyAgentProgress already logged the agent's own step and then sets the phase to the same words.
        guard phase.lowercased() != agentsCenter.record(agentID)?.currentStep?.lowercased() else { return }
        agentsCenter.update(agentID) { agentRecord in agentRecord.currentStep = phase }
        agentsCenter.log(agentID, phase)
    }

    // MARK: - Resolving the repo

    private func resolveRepository(for task: CodeTask, frontWindow: FrontWindowContext?, tools: CodeToolPaths) async -> ResolvedRepository? {
        let git = HardenedGit(gitPath: tools.git, ghPath: tools.gh, runner: ChildProcessCommandRunner())
        if cachedLocalRepos == nil {
            cachedLocalRepos = await LocalRepoIndexer(git: git, roots: ClickySettings.codeRepoRoots).index()
        }
        let allLocalRepos = cachedLocalRepos ?? []
        // Clicky's own checkouts never match, and neither does their GitHub repo.
        let deniedLocalRepos = allLocalRepos.filter { CodeRepoDenylist.isDeniedLocalRoot($0.folderPath) }
        let allowedLocalRepos = allLocalRepos.filter { !CodeRepoDenylist.isDeniedLocalRoot($0.folderPath) }
        let deniedFullNames = Set(deniedLocalRepos.flatMap { [$0.originURL, $0.upstreamURL] }.compactMap { $0.flatMap(GitHubRemote.parse)?.fullName.lowercased() })

        if FrontWindowRepoResolver.isDeicticRepoName(task.repo) {
            return await resolveFrontWindowRepository(task: task, frontWindow: frontWindow, localRepos: allLocalRepos, deniedFullNames: deniedFullNames, git: git)
        }

        func match() -> RepoMatchResult {
            var result = RepoMatcher(localRepos: allowedLocalRepos, accountRepoFullNames: (cachedAccountRepos ?? []).filter { !deniedFullNames.contains($0.lowercased()) })
                .match(spokenName: task.repo)
            result.rankedCandidates.removeAll { deniedFullNames.contains($0.fullName.lowercased()) }
            return result
        }
        var matchResult = match()
        if !matchResult.isConfident {
            if cachedAccountRepos == nil, let engine = makeReadOnlyEngine(tools: tools) {
                cachedAccountRepos = await engine.accountRepositoryNames()
            }
            matchResult = match()
        }
        guard !matchResult.rankedCandidates.isEmpty else {
            if deniedLocalRepos.contains(where: { RepoMatcher.normalize(($0.folderPath as NSString).lastPathComponent) == RepoMatcher.normalize(task.repo) }) {
                speak("That's Clicky's own code, and I don't work on that one.")
            } else {
                speak("I couldn't find a repo called \(task.repo).")
            }
            return nil
        }
        let chosenCandidate: RepoCandidate
        if matchResult.isConfident, let top = matchResult.top {
            let openingName = top.source == .localOnly ? (top.folderPath.map { ($0 as NSString).lastPathComponent } ?? top.fullName) : top.fullName
            guard await showOpeningCountdown(OpeningCard(repositoryName: openingName, path: top.folderPath, pullRequestNumber: task.pr)) else {
                return nil
            }
            chosenCandidate = top
        } else {
            panelController.show(mode: .chooser(title: "Which \"\(task.repo)\"?", candidates: matchResult.chooserCandidates))
            let choice = await withCheckedContinuation { continuation in pendingRepositoryChoice = continuation }
            panelController.hide()
            guard let choice else { return nil }
            chosenCandidate = choice
        }
        guard !RepoMatcher.isDenied(chosenCandidate.fullName), !deniedFullNames.contains(chosenCandidate.fullName.lowercased()) else { return nil }
        if let folderPath = chosenCandidate.folderPath, CodeRepoDenylist.isDeniedLocalRoot(folderPath) { return nil }
        let nameParts = chosenCandidate.fullName.split(separator: "/").map(String.init)
        guard nameParts.count == 2 else { return nil }
        return ResolvedRepository(remote: GitHubRemote(owner: nameParts[0], name: nameParts[1]), clonePath: chosenCandidate.folderPath,
                                  isLocalOnly: chosenCandidate.source == .localOnly)
    }

    /// "Opening <repo>" with its full path for 2 s; Esc or Cancel stops it. False when cancelled.
    private func showOpeningCountdown(_ card: OpeningCard) async -> Bool {
        isOpeningCancelled = false
        var shownCard = card
        shownCard.secondsRemaining = 2
        panelController.show(mode: .opening(shownCard))
        record("opening \(card.repositoryName) at \(card.path ?? "-")")
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline, !isOpeningCancelled, !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 100_000_000)
            let secondsRemaining = max(1, Int(ceil(deadline.timeIntervalSinceNow)))
            if secondsRemaining != shownCard.secondsRemaining, case .opening = panelController.state.mode {
                shownCard.secondsRemaining = secondsRemaining
                panelController.state.mode = .opening(shownCard)
            }
        }
        panelController.hide()
        guard !isOpeningCancelled, !Task.isCancelled else {
            record("opening cancelled")
            return false
        }
        return true
    }

    /// "this repo": the front Xcode / VS Code / Terminal window's git root.
    private func resolveFrontWindowRepository(task: CodeTask, frontWindow: FrontWindowContext?, localRepos: [LocalRepoEntry], deniedFullNames: Set<String>,
                                              git: HardenedGit) async -> ResolvedRepository? {
        guard let frontWindow else {
            speak("I couldn't tell which repo is in front. Say its name, or bring it up in Xcode, VS Code or Terminal.")
            return nil
        }
        let resolution = FrontWindowRepoResolver.resolve(frontWindow, localRepos: localRepos)
        record("front window \(frontWindow.bundleIdentifier ?? "-") \"\(frontWindow.windowTitle?.prefix(80) ?? "")\" → \(resolution)")
        let rootPath: String
        switch resolution {
        case .found(let foundRootPath, _):
            rootPath = foundRootPath
        case .denied:
            speak("That's Clicky's own code, and I don't work on that one.")
            return nil
        case .notFound:
            speak("I couldn't tell which repo is in front. Say its name, or bring it up in Xcode, VS Code or Terminal.")
            return nil
        }
        return await resolveLocalRoot(rootPath: rootPath, task: task, deniedFullNames: deniedFullNames, git: git)
    }

    /// A named project's folder (alias, confident match or the owner's pick):
    /// the same denylist checks and "Opening" card as "this repo".
    private func resolvePinnedRepository(rootPath: String, task: CodeTask, tools: CodeToolPaths) async -> ResolvedRepository? {
        let git = HardenedGit(gitPath: tools.git, ghPath: tools.gh, runner: ChildProcessCommandRunner())
        guard !CodeRepoDenylist.isDeniedLocalRoot(rootPath) else {
            speak("That's Clicky's own code, and I don't work on that one.")
            return nil
        }
        guard FileManager.default.fileExists(atPath: (rootPath as NSString).appendingPathComponent(".git")) else {
            speak(NamedProjectSpeech.notAGitRepositoryLine(folderName: (rootPath as NSString).lastPathComponent))
            return nil
        }
        let deniedFullNames = Set((cachedLocalRepos ?? []).filter { CodeRepoDenylist.isDeniedLocalRoot($0.folderPath) }
            .flatMap { [$0.originURL, $0.upstreamURL] }.compactMap { $0.flatMap(GitHubRemote.parse)?.fullName.lowercased() })
        record("named project → \(rootPath)")
        return await resolveLocalRoot(rootPath: rootPath, task: task, deniedFullNames: deniedFullNames, git: git)
    }

    /// A local git root → its identity (origin, else upstream, else local-only), after the 2 s "Opening" card.
    private func resolveLocalRoot(rootPath: String, task: CodeTask, deniedFullNames: Set<String>, git: HardenedGit) async -> ResolvedRepository? {
        let originURL = await git.remoteURL(named: "origin", in: rootPath)
        let upstreamURL = await git.remoteURL(named: "upstream", in: rootPath)
        let folderName = (rootPath as NSString).lastPathComponent
        var repository: ResolvedRepository
        if let identity = originURL.flatMap(GitHubRemote.parse) ?? upstreamURL.flatMap(GitHubRemote.parse) {
            guard !RepoMatcher.isDenied(identity.fullName), !deniedFullNames.contains(identity.fullName.lowercased()) else {
                speak("That's Clicky's own code, and I don't work on that one.")
                return nil
            }
            repository = ResolvedRepository(remote: identity, clonePath: rootPath)
        } else {
            repository = ResolvedRepository(remote: GitHubRemote(owner: RepoMatcher.localOnlyOwner, name: folderName), clonePath: rootPath, isLocalOnly: true)
        }
        guard await showOpeningCountdown(OpeningCard(repositoryName: repository.isLocalOnly ? folderName : repository.remote.fullName, path: rootPath,
                                                     pullRequestNumber: task.pr)) else { return nil }
        repository.clonePath = rootPath
        return repository
    }

    private func makeReadOnlyEngine(tools: CodeToolPaths) -> CodeTaskEngine? {
        guard let preflightReport else { return nil }
        return CodeTaskEngine(tools: tools, preflight: preflightReport, runner: ChildProcessCommandRunner(), isBashAllowed: false)
    }

    /// "Clone o/n into ~/Projects/n?" — a gated click, then a hardened clone.
    private func offerClone(_ remote: GitHubRemote, tools: CodeToolPaths) async -> String? {
        let rootPath = ((ClickySettings.codeRepoRoots.first ?? "~/Projects") as NSString).expandingTildeInPath
        let destinationPath = (rootPath as NSString).appendingPathComponent(CodeTaskWorkspace.safeFileName(remote.name))
        guard !FileManager.default.fileExists(atPath: destinationPath) else {
            speak("There's already a folder at \((destinationPath as NSString).abbreviatingWithTildeInPath) that isn't a clone of \(remote.fullName).")
            return nil
        }
        let shouldClone = await ask(title: "Clone \(remote.fullName)?", detail: "I'll clone it into \((destinationPath as NSString).abbreviatingWithTildeInPath) to work on it.",
                                    confirmTitle: "Clone", gatedAction: .clone)
        guard shouldClone else { return nil }
        setPhase("Cloning \(remote.fullName)")
        try? FileManager.default.createDirectory(atPath: rootPath, withIntermediateDirectories: true)
        let git = HardenedGit(gitPath: tools.git, ghPath: tools.gh, runner: ChildProcessCommandRunner())
        do {
            try await git.runChecked(["clone", "--quiet", "--no-recurse-submodules", "--", GitHubCommands.httpsURL(remote), destinationPath], in: rootPath,
                                     usesGitHubCredentials: true, timeoutSeconds: 600)
            cachedLocalRepos = nil
            return destinationPath
        } catch {
            speak("Cloning \(remote.fullName) failed.")
            record("clone failed: \(error)")
            return nil
        }
    }

    private func ask(title: String, detail: String, confirmTitle: String, gatedAction: GatedAction) async -> Bool {
        panelController.show(mode: .question(title: title, detail: detail, confirmTitle: confirmTitle, gatedAction: gatedAction))
        let answer = await withCheckedContinuation { continuation in pendingQuestionAnswer = continuation }
        panelController.hide()
        return answer
    }

    // MARK: - Review

    private func presentReview(_ review: PreparedReview) async {
        activeReview = review
        lastReviewSummary = ["repo": review.task.repo, "worktree": review.worktree.map { $0.path as Any } ?? NSNull(),
                             "branch": review.worktree.map { $0.branch as Any } ?? NSNull(), "reviewOID": review.reviewOID,
                             "changedFiles": review.content.diffFiles.map(\.displayPath), "shownAt": Date().timeIntervalSince1970]
        acks = []
        agentsCenter?.update(activeQueuedTask?.agentID) { agentRecord in
            agentRecord.worktreePath = review.worktree?.path
            agentRecord.branch = review.worktree?.branch
            agentRecord.phase = "waiting for review"
            agentRecord.changedFiles = review.content.diffFiles.map(\.displayPath)
        }
        panelController.state.content = review.content
        panelController.show(mode: .review)
        setPhase("Waiting for your review")
        let summary = review.agentResult?.spokenSummary ?? review.content.summary ?? ""
        speak((summary.isEmpty ? "" : summary + " ") + "Take a look at the panel.")
        await refreshApproveConditions()
    }

    /// Re-checks everything Approve depends on and re-keys every button.
    private func refreshApproveConditions(runDryRun: Bool = true) async {
        guard let review = activeReview, let engine = activeEngine else { return }
        var directories = [review.workspace.contextDirectoryURL.path]
        if let worktree = review.worktree { directories.append(worktree.path) }
        var leftoverProcesses = ProcessSweep.processes(underDirectories: directories)
        if !leftoverProcesses.isEmpty {
            record("sweep: killing \(leftoverProcesses)")
            leftoverProcesses = ProcessSweep.killAll(underDirectories: directories)
            if !leftoverProcesses.isEmpty { scheduleSweepRetry() }
        }
        var dryRunSucceeded = approveConditions?.pushDryRunSucceeded
        var dryRunMessage = approveConditions?.pushDryRunMessage
        if runDryRun, let pushTarget = activeReview?.dryRunPush {
            if pushTarget.forkFrom != nil {
                // The fork may not exist yet; the real push re-checks the remote first.
                dryRunSucceeded = nil
            } else {
                panelController.state.content.progress = "Checking the push (dry run)…"
                let dryRun = await engine.pushDryRun(pushTarget)
                dryRunSucceeded = dryRun.succeeded
                dryRunMessage = dryRun.message
                panelController.state.content.progress = nil
            }
        }
        guard let currentReview = activeReview else { return }
        let findings = currentFindings(for: currentReview)
        let conditions = ReviewApproveConditions(isAgentProcessGroupReaped: currentReview.agentReport?.isProcessGroupReaped ?? true,
                                                 leftoverProcessIdentifiers: leftoverProcesses, pushDryRunSucceeded: dryRunSucceeded,
                                                 pushDryRunMessage: dryRunMessage, findings: findings, acks: acks)
        approveConditions = conditions
        var blockers = conditions.blockers
        if isAmendingCommit { blockers.append("updating the commit…") }
        if isExecuting { blockers.append("running…") }
        panelController.state.content.findings = findings
        panelController.state.content.acks = acks
        panelController.state.content.approveBlockers = blockers
        rekeyButtons()
    }

    private func scheduleSweepRetry() {
        sweepRetryTask?.cancel()
        sweepRetryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            await self?.refreshApproveConditions(runDryRun: false)
        }
    }

    private func currentFindings(for review: PreparedReview) -> [CodeGuardFinding] {
        let texts = panelController.state.content.editableTexts
        let commitMessage = texts.first { $0.fileName == "commit-msg.txt" }?.text
        let bodies = texts.filter { $0.fileName != "commit-msg.txt" }.map { CodeGuards.BodyText(label: $0.label, text: $0.text) }
        return CodeGuards.scan(diffText: review.diffText, commitMessage: commitMessage, bodies: bodies)
    }

    /// The key of what each button would send, from the files on disk now.
    private func rekeyButtons() {
        guard let review = activeReview, let engine = activeEngine else { return }
        var keys: [String: ApprovalKey] = [:]
        for (buttonID, action) in review.actionsByButtonID {
            if let material = try? engine.approvalMaterial(for: action, reviewOID: review.reviewOID, acks: acks.sorted()) {
                keys[buttonID] = material.approvalKey
            }
        }
        displayedApprovalKeys = keys
    }

    private func wirePanelCallbacks() {
        let state = panelController.state
        state.onEditText = { [weak self] fileName, text in self?.editOutboxText(fileName: fileName, text: text) }
        state.onToggleAck = { [weak self] ackIdentifier, isAcked in
            guard let self else { return }
            if isAcked { self.acks.insert(ackIdentifier) } else { self.acks.remove(ackIdentifier) }
            Task { await self.refreshApproveConditions(runDryRun: false) }
        }
        state.onApprove = { [weak self] button in
            guard let self else { return }
            Task { await self.approve(button) }
        }
        state.onChooseRepository = { [weak self] candidate in
            self?.pendingRepositoryChoice?.resume(returning: candidate)
            self?.pendingRepositoryChoice = nil
        }
        state.onConfirmQuestion = { [weak self] in
            self?.pendingQuestionAnswer?.resume(returning: true)
            self?.pendingQuestionAnswer = nil
        }
        state.onStopTask = { [weak self] in self?.stopAllTasks() }
        state.onCancel = { [weak self] in
            guard let self else { return }
            if case .opening = state.mode { self.isOpeningCancelled = true; return }
            // Hide / Esc / close on the progress card: the task keeps running.
            if case .working = state.mode {
                self.isProgressPanelHidden = true
                self.panelController.hide()
                return
            }
            if self.pendingRepositoryChoice != nil || self.pendingQuestionAnswer != nil {
                self.pendingRepositoryChoice?.resume(returning: nil)
                self.pendingRepositoryChoice = nil
                self.pendingQuestionAnswer?.resume(returning: false)
                self.pendingQuestionAnswer = nil
                return
            }
            guard !self.isExecuting else { return }
            self.record("review closed without sending")
            self.agentsCenter?.log(self.activeQueuedTask?.agentID, "review closed without sending")
            self.finishTask(hidePanel: true)
        }
        panelController.onReturnKey = { [weak self] event in
            self?.panelController.state.primaryButtonView?.armFromKeyboard(event)
        }
    }

    /// Edits rewrite the outbox file, so the ApprovalKey changes with them.
    private func editOutboxText(fileName: String, text: String) {
        guard let review = activeReview else { return }
        do {
            try CodeTaskWorkspace.writePrivateFile(review.workspace.outboxFileURL(fileName), text)
        } catch {
            record("couldn't save \(fileName): \(error)")
            return
        }
        if let textIndex = panelController.state.content.editableTexts.firstIndex(where: { $0.fileName == fileName }) {
            panelController.state.content.editableTexts[textIndex].text = text
        }
        if fileName == "commit-msg.txt", review.worktree != nil {
            isAmendingCommit = true
            amendDebounceTask?.cancel()
            amendDebounceTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled else { return }
                await self?.amendCommitMessage()
            }
        }
        Task { await refreshApproveConditions(runDryRun: false) }
    }

    private func amendCommitMessage() async {
        guard let review = activeReview, let engine = activeEngine else { return }
        do {
            let amendedReview = try await engine.amendCommitMessage(review)
            activeReview = amendedReview
            panelController.state.content.newOID = amendedReview.reviewOID
            panelController.state.content.buttons = amendedReview.content.buttons
            record("amended commit message → \(amendedReview.reviewOID.prefix(7))")
        } catch {
            record("amend failed: \(error)")
        }
        isAmendingCommit = false
        await refreshApproveConditions(runDryRun: true)
    }

    // MARK: - Approve

    private func approve(_ button: CodeReviewContent.ActionButton) async {
        guard let review = activeReview, let engine = activeEngine, let action = review.actionsByButtonID[button.id], !isExecuting else { return }
        if button.isOutward {
            guard panelController.state.content.isApproveEnabled else {
                record("approve refused: \(panelController.state.content.approveBlockers)")
                return
            }
        }
        // What the panel showed must still be what's on disk.
        let shownKey = displayedApprovalKeys[button.id]
        if case .keepLocal = action {} else {
            guard let shownKey, let currentMaterial = try? engine.approvalMaterial(for: action, reviewOID: review.reviewOID, acks: acks.sorted()),
                  shownKey.verify(current: currentMaterial) else {
                panelController.state.content.progress = "Something changed since the panel was drawn. Look again, then click."
                await refreshApproveConditions(runDryRun: false)
                return
            }
        }
        isExecuting = true
        panelController.state.content.progress = "Running \(button.title)…"
        await refreshApproveConditions(runDryRun: false)
        record("approved \(button.id) key=\(shownKey?.hexDigest.prefix(12) ?? "-")")
        let result = await engine.execute(action, approvedKey: shownKey, reviewOID: review.reviewOID, acks: acks.sorted(), workspace: review.workspace)
        isExecuting = false
        record("\(button.id): \(result.succeeded ? "ok" : "failed") \(result.message) pr=\(result.createdPullRequestURL ?? "-")")
        agentsCenter?.log(activeQueuedTask?.agentID, "\(button.title): \(result.succeeded ? "done" : "failed") \(result.message)")

        guard result.succeeded else {
            panelController.state.content.progress = result.message
            speak("That didn't go through: \(result.message.prefix(140)).")
            await refreshApproveConditions(runDryRun: false)
            return
        }
        switch action {
        case .keepLocal:
            speak("Okay, it's on the branch \(review.worktree?.branch ?? "locally").")
        default:
            if let pullRequestURL = result.createdPullRequestURL {
                let numberPhrase = Self.pullRequestNumber(fromURL: pullRequestURL).map { " number \($0)" } ?? ""
                speak("I opened pull request\(numberPhrase) on \(review.repository.remote.name).")
                panelController.state.content.progress = pullRequestURL
                record("PR: \(pullRequestURL)")
            } else {
                speak(result.pushed ? "Pushed." : "Done.")
            }
        }
        if result.pushed {
            let pullRequestNumber = review.pullRequestContext?.number ?? result.createdPullRequestURL.flatMap(Self.pullRequestNumber(fromURL:))
            if let pullRequestNumber { watchChecks(review.repository.remote, number: pullRequestNumber, engine: engine) }
            if let worktree = review.worktree { await removeWorktreeIfPushed(worktree, engine: engine) }
        }
        finishTask(hidePanel: true)
    }

    static func pullRequestNumber(fromURL url: String) -> Int? {
        guard let pullRange = url.range(of: "/pull/") else { return nil }
        return Int(url[pullRange.upperBound...].prefix { $0.isNumber })
    }

    /// After a push: `gh pr checks` every 15 s for up to 20 minutes, then say how it went.
    private func watchChecks(_ repository: GitHubRemote, number: Int, engine: CodeTaskEngine) {
        checksPollTask?.cancel()
        checksPollTask = Task { [weak self] in
            let summary = await engine.waitForChecks(repository, number: number)
            guard !Task.isCancelled, let self else { return }
            switch summary {
            case .passed?: self.speak("Checks passed on \(repository.name) number \(number).")
            case .failed(let names)?: self.speak("Checks failed on \(repository.name) number \(number): \(names.prefix(3).joined(separator: ", ")).")
            case .pending?: self.speak("Checks on \(repository.name) number \(number) are still running after twenty minutes.")
            case .none?, nil: break
            }
        }
    }

    private func removeWorktreeIfPushed(_ worktree: ClickyWorktree, engine: CodeTaskEngine) async {
        let manager = engine.worktreeManager
        guard let entry = try? await manager.clickyWorktrees(clonePath: worktree.clonePath).first(where: { $0.path == worktree.path || $0.shortBranch == worktree.branch }) else { return }
        let extraExcludes = worktree.pullRequestNumber.map { ["refs/clicky/pr/\($0)"] } ?? []
        // The just-pushed commit isn't in a remote-tracking ref yet; ask before removing anything else.
        guard await manager.unpushedCommitCount(entry, clonePath: worktree.clonePath, alsoExcluding: extraExcludes + [activeReview?.reviewOID ?? worktree.startOID]) == 0 else { return }
        try? await manager.remove(entry, clonePath: worktree.clonePath)
    }

    // MARK: - Cleanup

    /// Removes Clicky's worktrees (asks first when any has unpushed commits).
    func cleanUpWorktrees() {
        guard !isBusy else { return }
        isBusy = true
        Task { [weak self] in
            guard let self else { return }
            defer { self.isBusy = false; self.setPhase("Idle") }
            var locatedTools = self.toolPaths
            if locatedTools == nil { locatedTools = try? await CodeToolPaths.locate() }
            guard let tools = locatedTools else { return }
            self.setPhase("Cleaning up worktrees")
            let git = HardenedGit(gitPath: tools.git, ghPath: tools.gh, runner: ChildProcessCommandRunner())
            let manager = WorktreeManager(git: git)
            let clones = await LocalRepoIndexer(git: git, roots: ClickySettings.codeRepoRoots).index().map(\.folderPath)
            var entriesByClone: [(String, [WorktreeListEntry])] = []
            var unpushedCount = 0
            for clonePath in clones {
                guard let entries = try? await manager.clickyWorktrees(clonePath: clonePath), !entries.isEmpty else { continue }
                entriesByClone.append((clonePath, entries))
                for entry in entries {
                    let pullRequestRef = entry.shortBranch.flatMap { $0.hasPrefix("clicky/pr-") ? "refs/clicky/pr/\($0.dropFirst("clicky/pr-".count))" : nil }
                    unpushedCount += await manager.unpushedCommitCount(entry, clonePath: clonePath, alsoExcluding: pullRequestRef.map { [$0] } ?? []) > 0 ? 1 : 0
                }
            }
            guard !entriesByClone.isEmpty else {
                self.speak("There are no Clicky worktrees to clean up.")
                return
            }
            if unpushedCount > 0 {
                let removeAnyway = await self.ask(title: "Remove Clicky's worktrees?", detail: "\(unpushedCount) of them have commits that were never pushed. Removing deletes that work.",
                                                  confirmTitle: "Remove all", gatedAction: .apply)
                guard removeAnyway else { return }
            }
            var removedCount = 0
            for (clonePath, entries) in entriesByClone {
                for entry in entries where (try? await manager.remove(entry, clonePath: clonePath)) != nil { removedCount += 1 }
                if (try? await manager.clickyWorktrees(clonePath: clonePath))?.isEmpty == true { await manager.removeAllClickyRefs(clonePath: clonePath) }
            }
            self.record("cleanup removed \(removedCount)")
            self.speak("Removed \(removedCount) Clicky worktree\(removedCount == 1 ? "" : "s").")
        }
    }

    // MARK: - State (debug)

    private func record(_ event: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(event)"
        recentEvents.append(line)
        if recentEvents.count > 80 { recentEvents.removeFirst(recentEvents.count - 80) }
        print("🧑‍💻 Code: \(event.prefix(300))")
    }

    func stateSnapshot() -> [String: Any] {
        var snapshot: [String: Any] = [
            "enabled": isEnabled,
            "busy": isBusy,
            "phase": phaseDescription,
            "preflight": preflightStatusLine,
            "events": Array(recentEvents.suffix(30))
        ]
        if let preflightReport {
            snapshot["flags"] = preflightReport.flagTable
            snapshot["droppedFlags"] = preflightReport.droppedOptionalFlags
            snapshot["viewer"] = preflightReport.viewerLogin ?? NSNull()
            snapshot["unremovableTools"] = preflightReport.unremovableTools
            snapshot["disabledPlugins"] = preflightReport.disabledPluginSources
            snapshot["preflightExplanation"] = preflightReport.spokenExplanation
        }
        if let review = activeReview {
            snapshot["review"] = [
                "header": review.content.headerText,
                "taskDir": review.workspace.taskDirectoryURL.path,
                "worktree": review.worktree?.path ?? NSNull(),
                "buttons": review.content.buttons.map(\.id),
                "blockers": panelController.state.content.approveBlockers,
                "findings": panelController.state.content.findings.map(\.message)
            ] as [String: Any]
        }
        return snapshot
    }

    /// `codeStatus` (debug inbox): the current task, its live progress, the queue and the panel.
    func statusSnapshot() -> [String: Any] {
        func describe(_ task: CodeTask) -> [String: Any] {
            ["action": task.action.rawValue, "repo": task.repo, "instructions": task.instructions, "pr": task.pr.map { $0 as Any } ?? NSNull(), "flow": task.flow.rawValue]
        }
        var status: [String: Any] = [
            "enabled": isEnabled,
            "busy": isBusy,
            "phase": phaseDescription,
            "preflight": preflightStatusLine,
            "queue": queuedTasks.map { describe($0.task) },
            "panelVisible": panelController.isVisible,
            "panelMode": Self.modeName(panelController.state.mode),
            "lastNarration": lastNarration.map { $0 as Any } ?? NSNull(),
            "lastToggle": lastToggleDescription.map { $0 as Any } ?? NSNull(),
            "codeModeChipVisible": chipController.isVisible,
            "narrateProgress": ClickySettings.isCodeProgressNarrationEnabled
        ]
        if let preflightReport {
            // Why code mode is off and what to do, as it would be spoken.
            status["preflightReady"] = preflightReport.isReady
            status["preflightExplanation"] = preflightReport.spokenExplanation
            status["preflightRemedy"] = preflightReport.remedy.map { $0 as Any } ?? NSNull()
            status["disabledPlugins"] = preflightReport.disabledPluginSources
        }
        if let activeQueuedTask {
            var taskStatus = describe(activeQueuedTask.task)
            if let frontWindow = activeQueuedTask.context.frontWindow {
                func valueOrNull(_ value: String?) -> Any { value.map { $0 as Any } ?? NSNull() }
                taskStatus["frontWindow"] = ["bundle": valueOrNull(frontWindow.bundleIdentifier), "title": valueOrNull(frontWindow.windowTitle),
                                             "document": valueOrNull(frontWindow.documentURL), "terminalCwd": valueOrNull(frontWindow.terminalWorkingDirectory)] as [String: Any]
            }
            status["task"] = taskStatus
        } else {
            status["task"] = NSNull()
        }
        if let activeRepository {
            status["repository"] = ["fullName": activeRepository.remote.fullName, "clonePath": activeRepository.clonePath.map { $0 as Any } ?? NSNull(),
                                    "localOnly": activeRepository.isLocalOnly] as [String: Any]
        }
        if let progressTracker {
            let snapshot = progressTracker.snapshot(title: progressTitle, now: Date(), queuedCount: queuedTasks.count)
            status["progress"] = ["title": snapshot.title, "step": snapshot.currentStep, "changedFiles": snapshot.changedFiles,
                                  "elapsedSeconds": snapshot.elapsedSeconds, "toolCalls": snapshot.toolCallCount, "running": progressTickerTask != nil] as [String: Any]
        }
        if let review = activeReview {
            status["review"] = ["header": review.content.headerText, "worktree": review.worktree.map { $0.path as Any } ?? NSNull(), "buttons": review.content.buttons.map(\.id),
                                "changedFiles": review.content.diffFiles.map(\.displayPath), "blockers": panelController.state.content.approveBlockers] as [String: Any]
        }
        status["lastReview"] = lastReviewSummary.map { $0 as Any } ?? NSNull()
        return status
    }

    private static func modeName(_ mode: ReviewPanelState.Mode) -> String {
        switch mode {
        case .opening: return "opening"
        case .chooser: return "chooser"
        case .question: return "question"
        case .working: return "working"
        case .review: return "review"
        }
    }
}
