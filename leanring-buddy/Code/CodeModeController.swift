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

import AppKit
import ClickyCore
import Combine
import Foundation

/// The turn a code task came from (for logs).
struct CodeTurnContext {
    var transcript: String
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
    private var cachedAccountRepos: [String]?
    private var activeTask: Task<Void, Never>?
    private var activeEngine: CodeTaskEngine?
    private var activeReview: PreparedReview?
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

    private let speak: (String) -> Void
    private let panelController: ReviewPanelController

    init(speak: @escaping (String) -> Void) {
        self.speak = speak
        self.panelController = ReviewPanelController(state: ReviewPanelState(content: CodeReviewContent(repositoryFullName: "")))
        wirePanelCallbacks()
    }

    // MARK: - Settings

    func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: ClickySettings.Keys.codeEnabled)
        isEnabled = enabled
        if enabled {
            preflightStatusLine = "Checking…"
            Task { _ = await ensurePreflight(force: true) }
        } else {
            cancelActiveTask()
            preflightStatusLine = "Off"
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
        guard isEnabled else {
            speak("Code mode is off. Turn it on in Clicky's menu first.")
            return
        }
        guard !isBusy else {
            speak("I'm still on the last code task. Close its panel first.")
            return
        }
        record("start \(task.action.rawValue) repo=\(task.repo) pr=\(task.pr.map(String.init) ?? "-") from \"\(context.transcript.prefix(80))\"")
        isBusy = true
        activeTask = Task { [weak self] in
            await self?.run(task)
        }
    }

    func cancelActiveTask() {
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

    private func run(_ task: CodeTask) async {
        defer { if activeReview == nil && !isExecuting { finishTask(hidePanel: true) } }
        setPhase("Checking code mode")
        let report = await ensurePreflight()
        guard report.isReady, let toolPaths else {
            speak("Code mode can't run: \(report.failureReason ?? "the preflight failed").")
            return
        }
        setPhase("Finding \(task.repo)")
        guard var repository = await resolveRepository(for: task, tools: toolPaths), !Task.isCancelled else { return }
        if repository.clonePath == nil, Self.needsLocalClone(task) {
            guard let clonePath = await offerClone(repository.remote, tools: toolPaths) else { return }
            repository.clonePath = clonePath
        }

        do {
            let workspace = try CodeTaskWorkspace.create()
            let engine = CodeTaskEngine(tools: toolPaths, preflight: report, runner: ChildProcessCommandRunner(log: CodeCommandLog(fileURL: workspace.commandLogURL)),
                                        isBashAllowed: ClickySettings.isCodeBashAllowed)
            engine.onProgress = { [weak self] progress in
                let controller = self
                Task { @MainActor in controller?.setPhase(progress) }
            }
            activeEngine = engine
            record("task dir \(workspace.taskDirectoryURL.path)")
            switch try await engine.prepare(task, repository: repository, workspace: workspace) {
            case .spoken(let answer, let agentReport):
                record("answer (\(agentReport.map { String(describing: $0.outcome).prefix(60) } ?? "no agent")): \(answer.prefix(200))")
                speak(answer)
            case .review(let review):
                await presentReview(review)
            }
        } catch is CancellationError {
            record("cancelled")
        } catch let engineError as CodeTaskEngineError {
            record("engine: \(engineError)")
            speak(engineError.spokenMessage)
        } catch let worktreeError as WorktreeError {
            record("worktree: \(worktreeError)")
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
            speak("The code task failed: \(String(describing: error).prefix(140)).")
        }
    }

    private static func needsLocalClone(_ task: CodeTask) -> Bool {
        switch task.action {
        case .askRepo, .fixReview, .fixCI, .edit, .resolveConflicts, .repoChange: return true
        default: return false
        }
    }

    private func finishTask(hidePanel: Bool) {
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
    }

    private func setPhase(_ phase: String) {
        phaseDescription = phase
        record("phase: \(phase)")
    }

    // MARK: - Resolving the repo

    private func resolveRepository(for task: CodeTask, tools: CodeToolPaths) async -> ResolvedRepository? {
        let git = HardenedGit(gitPath: tools.git, ghPath: tools.gh, runner: ChildProcessCommandRunner())
        if cachedLocalRepos == nil {
            cachedLocalRepos = await LocalRepoIndexer(git: git, roots: ClickySettings.codeRepoRoots).index()
        }
        var matchResult = RepoMatcher(localRepos: cachedLocalRepos ?? [], accountRepoFullNames: cachedAccountRepos ?? []).match(spokenName: task.repo)
        if !matchResult.isConfident {
            if cachedAccountRepos == nil, let engine = makeReadOnlyEngine(tools: tools) {
                cachedAccountRepos = await engine.accountRepositoryNames()
            }
            matchResult = RepoMatcher(localRepos: cachedLocalRepos ?? [], accountRepoFullNames: cachedAccountRepos ?? []).match(spokenName: task.repo)
        }
        guard !matchResult.rankedCandidates.isEmpty else {
            speak("I couldn't find a repo called \(task.repo).")
            return nil
        }
        let chosenCandidate: RepoCandidate
        if matchResult.isConfident, let top = matchResult.top {
            let openingText = "Opening \(top.fullName)\(task.pr.map { " #\($0)" } ?? "")"
            isOpeningCancelled = false
            panelController.show(mode: .opening(openingText))
            let deadline = Date().addingTimeInterval(2)
            while Date() < deadline, !isOpeningCancelled, !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            panelController.hide()
            guard !isOpeningCancelled, !Task.isCancelled else {
                record("opening cancelled")
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
        guard !RepoMatcher.isDenied(chosenCandidate.fullName) else { return nil }
        let nameParts = chosenCandidate.fullName.split(separator: "/").map(String.init)
        guard nameParts.count == 2 else { return nil }
        return ResolvedRepository(remote: GitHubRemote(owner: nameParts[0], name: nameParts[1]), clonePath: chosenCandidate.folderPath)
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
        acks = []
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
        state.onCancel = { [weak self] in
            guard let self else { return }
            if case .opening = state.mode { self.isOpeningCancelled = true; return }
            if self.pendingRepositoryChoice != nil || self.pendingQuestionAnswer != nil {
                self.pendingRepositoryChoice?.resume(returning: nil)
                self.pendingRepositoryChoice = nil
                self.pendingQuestionAnswer?.resume(returning: false)
                self.pendingQuestionAnswer = nil
                return
            }
            guard !self.isExecuting else { return }
            self.record("review closed without sending")
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
}
