//
//  CompanionManager.swift
//  leanring-buddy
//
//  Theo's hub: what Theo is doing right now (idle, hearing you, thinking,
//  answering), the permissions it holds, push-to-talk, the spark overlay,
//  and every turn from your words to the spoken, marked-up answer.
//

import AVFoundation
import ClickyCore
import Combine
import Foundation
import os
import ScreenCaptureKit
import Speech
import SwiftUI

/// Theo's voice loop, as the UI shows it.
enum CompanionVoiceState {
    /// Waiting (wake word or push-to-talk).
    case idle
    /// Push-to-talk held: recording.
    case listening
    /// Words in, answer not started yet.
    case processing
    /// Speaking or showing the answer.
    case responding
}

@MainActor
final class CompanionManager: ObservableObject {
    /// The running app's manager, for views made outside the home window (the bots' Clicky card).
    static weak var current: CompanionManager?
    @Published private(set) var voiceState: CompanionVoiceState = .idle
    /// The last thing you said (push-to-talk or wake word).
    @Published private(set) var lastTranscript: String?
    /// Microphone loudness while push-to-talk records (0…1), for the level meter.
    @Published private(set) var currentAudioPowerLevel: CGFloat = 0

    // Privileges, re-read every 1.5 s.
    @Published private(set) var hasAccessibilityPermission = false
    @Published private(set) var hasScreenRecordingPermission = false
    @Published private(set) var hasMicrophonePermission = false
    @Published private(set) var hasScreenContentPermission = false

    /// Where the spark should fly and point (global AppKit point), from the answer's POINT tag.
    @Published var detectedElementScreenLocation: CGPoint?
    /// The frame of the screen that point is on, so only that screen's layer flies.
    @Published var detectedElementDisplayFrame: CGRect?

    /// Rings, arrows, steps etc. Claude drew for the current answer, laid out
    /// in CG points (MarkController). Cleared when the user asks something
    /// new, says "clear", presses Escape, or a little while after the answer.
    @Published private(set) var markDrawings: [MarkDrawing] = []
    let markController = MarkController()
    var hasLiveScreenMarks: Bool { !markController.marks.isEmpty }
    private var liveScreenMarksAutoClearTask: Task<Void, Never>?
    /// How long marks stay up after the buddy finishes talking, so the user
    /// has time to actually follow the steps.
    private static let liveScreenMarksSecondsToKeepAfterSpeech: UInt64 = 20

    // MARK: - Companion Activity (spark + orbiting workers)

    /// True while the activity source says the coordinator is thinking. The
    /// spark also spins while Clicky's own answer is processing.
    @Published private(set) var isCompanionCoordinatorThinking = false
    /// Running workers to draw as orbiting minis (at most 4).
    @Published private(set) var visibleCompanionWorkers: [CompanionWorkerActivity] = []

    /// The real source: Haiku helper workers the main brain opens for a question.
    let companionWorkerRunner = CompanionWorkerRunner()

    // MARK: - Agents dashboard

    /// Every agent Clicky runs (brain turns, helpers, board calls, code tasks) and its history.
    let agentsCenter = AgentsCenter()
    /// Clicking the resting spark opens the dashboard.
    let sparkClickTarget = CompanionSparkClickTarget()
    private(set) lazy var agentsWindowController = AgentsWindowController(agentsCenter: agentsCenter, actions: makeAgentsDashboardActions())
    /// The Voices window and the spoken voice switches ("next voice", "use voice 3", "previous voice", "show voices").
    private(set) lazy var voiceGalleryController = VoiceGalleryController(speechOutput: speechOutputClient)
    /// The brain record started at key-down ("listening"), adopted by the turn that follows.
    private var listeningBrainAgentID: String?
    /// The brain record of the answer in flight (its phase follows voiceState).
    private(set) var currentBrainAgentID: String?
    private var agentsVoiceStateCancellable: AnyCancellable?
    private var listeningBrainRemovalTask: Task<Void, Never>?

    /// Theo's bots live in the home window's Bots tab (with Connectors next to it).
    func showBotsWindow() {
        TheoHomeWindowController.show(companionManager: self, tab: .bots)
    }

    /// Opens the Agents window (menu bar, spark click, or [AGENTS:open]).
    /// Only these user requests order it front; agent updates never do.
    func showAgentsDashboard(activatesClicky: Bool = true) {
        agentsWindowController.show(selecting: nil, activatesClicky: activatesClicky)
    }

    /// The dashboard's Cancel on the brain: the same path as Escape (barge-in,
    /// then the response task and its helpers are cancelled), without ending a
    /// hands-free session.
    func cancelAnswerFromAgentsDashboard() {
        if let activeCoordinator = speechOutputClient.activeCoordinator, activeCoordinator.isSpeaking {
            activeCoordinator.bargeIn(.escape)
        }
        hideCaption()
        stopBuddySpeechAndCancelResponse()
    }

    private func makeAgentsDashboardActions() -> AgentsDashboardActions {
        AgentsDashboardActions(
            canCancel: { [weak self] record in self?.agentsCenter.canCancel(record) ?? false },
            canOpenReview: { [weak self] record in
                record.kind == .codeTask && self?.codeModeController.activeReviewAgentID == record.id
            },
            canRevealWorktree: { record in
                guard let worktreePath = record.worktreePath else { return false }
                return FileManager.default.fileExists(atPath: worktreePath)
            },
            cancel: { [weak self] record in self?.agentsCenter.cancel(record) },
            openReview: { [weak self] record in
                // Shows the existing review panel; its buttons still go through the click gate.
                _ = self?.codeModeController.showActiveReview(agentID: record.id)
            },
            revealWorktree: { record in
                guard let worktreePath = record.worktreePath, FileManager.default.fileExists(atPath: worktreePath) else { return }
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: worktreePath)])
            },
            copyLog: { record in
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(record.logText, forType: .string)
            },
            removeProjectAlias: { aliasKey in ClickySettings.removeProjectAlias(key: aliasKey) }
        )
    }

    /// The brain record follows voiceState: key-down starts one in
    /// "listening" (dropped again if nothing was asked), responding is "speaking".
    private func updateBrainAgent(for newVoiceState: CompanionVoiceState) {
        switch newVoiceState {
        case .listening:
            listeningBrainRemovalTask?.cancel()
            if agentsCenter.record(listeningBrainAgentID)?.phase != BrainPhase.listening.rawValue {
                listeningBrainAgentID = agentsCenter.begin(kind: .brain, title: "Listening…", model: selectedModel, phase: BrainPhase.listening.rawValue)
            }
        case .responding:
            agentsCenter.setBrainPhase(currentBrainAgentID, .speaking)
        case .idle:
            guard let listeningBrainAgentID else { return }
            listeningBrainRemovalTask?.cancel()
            listeningBrainRemovalTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                guard !Task.isCancelled, let self, self.listeningBrainAgentID == listeningBrainAgentID,
                      self.agentsCenter.record(listeningBrainAgentID)?.phase == BrainPhase.listening.rawValue else { return }
                self.agentsCenter.remove(listeningBrainAgentID)
                self.listeningBrainAgentID = nil
            }
        case .processing:
            break
        }
    }

    /// The turn's brain record: the one started at key-down, or a new one.
    private func beginBrainAgent(transcript: String) -> String {
        listeningBrainRemovalTask?.cancel()
        let brainAgentID: String
        if let listeningBrainAgentID, agentsCenter.record(listeningBrainAgentID)?.phase == BrainPhase.listening.rawValue {
            brainAgentID = listeningBrainAgentID
        } else {
            brainAgentID = agentsCenter.begin(kind: .brain, title: transcript, model: selectedModel)
        }
        listeningBrainAgentID = nil
        agentsCenter.update(brainAgentID) { record in
            record.title = AgentsCenter.cleanTitle(transcript)
            record.model = self.selectedModel
            record.phase = BrainPhase.thinking.rawValue
        }
        agentsCenter.log(brainAgentID, "heard: \(transcript)")
        agentsCenter.log(brainAgentID, "thinking (\(selectedModel))")
        agentsCenter.setCancelHandler(brainAgentID) { [weak self] in self?.cancelAnswerFromAgentsDashboard() }
        currentBrainAgentID = brainAgentID
        return brainAgentID
    }
    /// Driven by the debug controls in the panel so the visuals can be tried
    /// without asking Claude anything.
    let simulatedCompanionActivitySource = SimulatedCompanionActivitySource()
    private var companionActivitySources: [CompanionActivitySource] = []

    /// Adds a source whose thinking state and workers the companion shows.
    /// Every source's workers share the one orbit (still capped at four).
    func addCompanionActivitySource(_ newCompanionActivitySource: CompanionActivitySource) {
        companionActivitySources.append(newCompanionActivitySource)
        newCompanionActivitySource.onActivityChanged = { [weak self] in
            self?.republishCompanionActivity()
        }
        republishCompanionActivity()
    }

    private func republishCompanionActivity() {
        isCompanionCoordinatorThinking = companionActivitySources.contains { $0.coordinatorIsThinking }
        visibleCompanionWorkers = CompanionActivityLimits.visibleWorkers(from: companionActivitySources.flatMap(\.workers))
    }

    // MARK: - First-run hint

    /// The hint typed out next to the spark after Theo's first hello.
    @Published var onboardingPromptText: String = ""
    @Published var onboardingPromptOpacity: Double = 0.0
    @Published var showOnboardingPrompt: Bool = false

    let pushToTalkRecorder = PushToTalkRecorder()
    let pushToTalkKeys = PushToTalkKeys()
    let sparkOverlay = SparkOverlayManager()

    /// The brain: Claude Code (or another agent CLI) on your own subscription.
    private lazy var claudeCodeBridge = ClaudeCodeBridge(model: selectedModel)

    /// Theo's voice: Qwen on this Mac, a voice server, or the Mac voice.
    let speechOutputClient = CompanionSpeechOutput()
    /// P7: "hey theo" / "hey clicky", heard on-device (see WakeWordController).
    private(set) lazy var wakeWordController = WakeWordController(speechOutput: speechOutputClient, audioEngineHub: speechOutputClient.audioEngineHub)
    /// System-wide dictation: hold the chord in any app, talk, let go.
    private(set) lazy var dictationController: DictationController = {
        let controller = DictationController(hub: speechOutputClient.audioEngineHub, speech: speechOutputClient)
        controller.isBlocked = { [weak self] in TheoCallController.isActive || self?.pushToTalkRecorder.isDictationInProgress == true || self?.isHandsFreeSessionActive == true }
        return controller
    }()
    private var wakeWordVoiceStateCancellable: AnyCancellable?

    /// P5 Code mode: `<codetask>` blocks, the review panel and click-gated sends.
    private(set) lazy var codeModeController: CodeModeController = {
        let controller = CodeModeController { [weak self] text in
            self?.speakCodeModeLine(text)
        }
        // A real click on the "Turn on code mode" chip: ask the same words again with Code mode on.
        controller.onChipContinueRequest = { [weak self] transcript in
            var continuationOptions = TurnOptions()
            continuationOptions.extraUserText = "(code mode is on now. handle the request above with a codetask; don't say you're turning code mode on again.)"
            self?.sendTranscriptToClaudeWithScreenshot(transcript: transcript, turnOptions: continuationOptions)
        }
        return controller
    }()

    /// Set when an answer turned Code mode on by voice for a coding request:
    /// once that answer ends, the same words are asked again with the code
    /// section in the prompt (so the request itself gets its <codetask>).
    private var pendingCodeModeContinuationTranscript: String?

    func scheduleCodeModeContinuation(transcript: String) {
        pendingCodeModeContinuationTranscript = transcript
    }

    /// Code-mode results arrive long after the answer; wait for any speech to end first.
    func speakCodeModeLine(_ text: String) {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return }
        Task { [weak self] in
            guard let self else { return }
            let giveUpDate = Date().addingTimeInterval(20)
            while self.speechOutputClient.isPlaying && Date() < giveUpDate {
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            try? await self.speechOutputClient.speakText(trimmedText)
        }
    }

    /// "send this to my project …": the outbox file, the replies, the dashboard's project tasks.
    private(set) lazy var projectBridge = ProjectBridgeController(companionManager: self)
    /// P9: background research with Haiku helpers ("research these links").
    private(set) lazy var researchController = ResearchController(companionManager: self)
    /// One-click updates from the updates repo.
    let updateController = UpdateController()

    /// P6.2 "Type this for me": the <type> card, its confirm gate and the insertion.
    private(set) lazy var typeForMeController = TypeForMeController { [weak self] text in
        self?.speakCodeModeLine(text)
    }

    /// P7 computer-use actions: <actions> blocks, the observe → act loop, tiers and cancels.
    private(set) lazy var actionTaskController = ActionTaskController(companionManager: self)
    /// P8: simple spoken commands done locally (volume, media, windows, apps, tabs…), dictation, their confirms.
    private(set) lazy var voiceCommandController = VoiceCommandController(companionManager: self)

    /// The whiteboard panel and its narration (P4).
    private(set) lazy var boardController = BoardController(companionManager: self)
    /// P8: the last article read, its highlights, the notes panel and "save my notes".
    private(set) lazy var articleController = ArticleHighlightController(companionManager: self)
    /// The board panel is open: the caption bubble stays hidden (the board has its subtitle bar).
    @Published private(set) var isWhiteboardPanelOpen = false

    func setWhiteboardPanelOpen(_ isOpen: Bool) {
        isWhiteboardPanelOpen = isOpen
        if isOpen { captionState.isVisible = false }
    }

    /// Whether the Claude Code CLI is signed in. Checked on launch so the
    /// panel can prompt for `claude auth login` instead of failing silently.
    @Published private(set) var isClaudeCodeSignedIn = false

    func refreshClaudeCodeSignInStatus() {
        Task {
            isClaudeCodeSignedIn = await ClaudeCodeBridge.checkIsSignedIn()
            print("🔑 Claude Code signed in: \(isClaudeCodeSignedIn)")
        }
    }

    /// This session's exchanges (your words, Theo's answer), sent along so Theo remembers.
    private var conversationHistory: [(userTranscript: String, assistantResponse: String)] = []

    /// False when the startup geometry check found AppKit and CG display
    /// frames disagreeing; then nothing is drawn from tags for this session.
    /// Never written to settings.
    private(set) var isGroundingActiveThisSession = ClickySettings.isGroundingEnabled
    /// The model id the CLI last resolved the selected alias to.
    private(set) var lastResolvedModelIdentifier: String?
    /// Element lists, badges and tag resolution (v2 grounding).
    let groundingCoordinator = GroundingCoordinator()

    /// Called with each newly resolved model id (the tier probe uses it).
    var onNewResolvedModelIdentifier: ((String) -> Void)?

    /// Runs once at launch: if any display's flipped AppKit frame is more
    /// than 0.5 pt off its CGDisplayBounds, coordinates can't be trusted.
    func runStartupGeometryCheck() {
        let displayDisagreements = ScreenTopology.flipDisagreements(
            displays: ScreenTopology.current(),
            flipH: ScreenTopology.mainDisplayHeight
        )
        if !displayDisagreements.isEmpty {
            isGroundingActiveThisSession = false
            print("⚠️ Geometry self-check failed for displays \(displayDisagreements); pointing is off for this session")
        }
    }

    private func noteResolvedModelIdentifier(_ resolvedModelIdentifier: String?) {
        guard let resolvedModelIdentifier, resolvedModelIdentifier != lastResolvedModelIdentifier else { return }
        lastResolvedModelIdentifier = resolvedModelIdentifier
        onNewResolvedModelIdentifier?(resolvedModelIdentifier)
    }

    /// Forgets the conversation and anything on screen from the last answer
    /// (the debug inbox's `reset`, so eval rows don't influence each other).
    func resetConversation() {
        currentResponseTask?.cancel()
        speechOutputClient.stopPlayback()
        conversationHistory.removeAll()
        clearLiveScreenMarks()
        clearDetectedElementLocation()
        if voiceState == .processing || voiceState == .responding {
            voiceState = .idle
        }
    }

    /// The answer being produced; a new question cancels it.
    private var currentResponseTask: Task<Void, Never>?
    /// When push-to-talk was last released; the turn log's keyUp time.
    private var lastPushToTalkReleaseDate: Date?

    // Subscriptions and timers for push-to-talk and the permission poll.
    private var shortcutTransitionCancellable: AnyCancellable?
    private var voiceStateCancellable: AnyCancellable?
    private var audioPowerCancellable: AnyCancellable?
    private var permissionPollTimer: Timer?
    private var appDidBecomeActiveObserver: NSObjectProtocol?
    /// Permission changes in the unified log: `log show --predicate 'subsystem == "com.personal.clicky"'`.
    private let permissionLogger = Logger(subsystem: "com.personal.clicky", category: "permissions")
    /// Push-to-talk's start, which can still be pending when the keys come up.
    private var pendingKeyboardShortcutStartTask: Task<Void, Never>?
    /// With the spark hidden by choice, it shows for one exchange and then fades; this is that fade.
    private var transientHideTask: Task<Void, Never>?

    /// Everything Theo needs is allowed.
    var allPermissionsGranted: Bool {
        [hasAccessibilityPermission, hasScreenRecordingPermission, hasMicrophonePermission, hasScreenContentPermission].allSatisfy { $0 }
    }

    /// The spark layer is on screen.
    @Published private(set) var isOverlayVisible: Bool = false

    /// The answer model (ClickyModels.main: "codex:…" etc. for other brains).
    @Published var selectedModel: String = ClickyModels.main

    /// Silent mode: listen and answer on screen, never speak (v2.voice.silent).
    @Published private(set) var isSilentModeEnabled = ClickySettings.isSilentModeEnabled

    func setSilentModeEnabled(_ enabled: Bool) {
        ClickySettings.isSilentModeEnabled = enabled
        isSilentModeEnabled = enabled
        if enabled { speechOutputClient.activeCoordinator?.bargeIn(.newQuestion) }
    }

    func setSelectedModel(_ model: String) {
        ClickyModels.main = model
        selectedModel = ClickyModels.main
        claudeCodeBridge.model = selectedModel
    }

    /// "Show the spark by my pointer" (stored under its old key so the choice carries over).
    @Published var isClickyCursorEnabled: Bool = UserDefaults.standard.object(forKey: "isClickyCursorEnabled") as? Bool ?? true

    func setClickyCursorEnabled(_ enabled: Bool) {
        isClickyCursorEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "isClickyCursorEnabled")
        transientHideTask?.cancel()
        transientHideTask = nil
        enabled ? putSparkOnScreens(greeting: false) : takeSparkOffScreens()
    }

    /// Shows the spark layer on every screen (`greeting` plays the first-run hello).
    /// The owner opened or closed this Mac's screen to Clicky.
    func clickyPlaceChanged() {
        if TheoLink.shared.clickyRunsHere { showSparkIfReady() } else if isOverlayVisible { takeSparkOffScreens() }
    }

    func putSparkOnScreens(greeting: Bool) {
        guard TheoLink.shared.clickyRunsHere else { return }
        if !greeting { sparkOverlay.hasShownOverlayBefore = true }
        sparkOverlay.showOverlay(onScreens: NSScreen.ownerScreens, companionManager: self)
        isOverlayVisible = true
    }

    private func takeSparkOffScreens() {
        sparkOverlay.hideOverlay()
        isOverlayVisible = false
    }

    /// Set once the first-run hello has played.
    var hasCompletedOnboarding: Bool {
        get { UserDefaults.standard.bool(forKey: "hasCompletedOnboarding") }
        set { UserDefaults.standard.set(newValue, forKey: "hasCompletedOnboarding") }
    }

    func start() {
        runStartupGeometryCheck()
        // The CODE prompt section exists from launch; it's only sent while Code mode is on.
        CodeModePrompt.register()
        escapeKeyConsumers.append { [weak self] in self?.codeModeController.handleEscapeKey() ?? false }
        // P6.2: the TYPING prompt section (sent only while v2.typeForMe.enabled is on); the card takes Esc first.
        TypeForMePrompt.register()
        escapeKeyConsumers.insert({ [weak self] in self?.typeForMeController.handleEscapeKey() ?? false }, at: 0)
        // P7: Esc ends an action task (never consumed: Escape's usual stop still runs).
        escapeKeyConsumers.insert({ [weak self] in self?.actionTaskController.handleEscapeKey() ?? false }, at: 0)

        // P4: the whiteboard prompt section exists now that boards are drawn.
        SystemPromptBuilder.gatedSectionTexts[.whiteboard] = WhiteboardPromptSection.text
        WBMathRenderer.install()
        _ = boardController
        markController.onDrawingsChanged = { [weak self] drawings in self?.markDrawings = drawings }
        markController.onLegendChanged = { [weak self] legend in self?.showMarkLegend(legend) }
        groundingCoordinator.effectiveMaxEdgeProvider = { [weak self] in
            ClickySettings.effectiveMaxEdge(forModelIdentifier: self?.lastResolvedModelIdentifier)
        }
        // P6.8: AX observers (walk cache) and enhanced UI for Chromium/Electron.
        groundingCoordinator.startBackgroundServices()
        // A model we haven't measured yet: check in the background what image
        // size it really sees (stored per resolved model id).
        onNewResolvedModelIdentifier = { [weak self] resolvedModelIdentifier in
            guard let self else { return }
            DiagnosticSelfTests.probeInBackgroundIfNeeded(resolvedModelIdentifier: resolvedModelIdentifier, model: self.selectedModel)
        }
        speechOutputClient.warmUpIfNeeded()
        addCompanionActivitySource(companionWorkerRunner)
        addCompanionActivitySource(simulatedCompanionActivitySource)
        addCompanionActivitySource(researchController)
        updateController.startAutomaticChecks()
        TheoLink.shared.start()
        // Agents dashboard: the brain record follows voiceState; code tasks report in; the spark opens it.
        codeModeController.agentsCenter = agentsCenter
        projectBridge.start()
        sparkClickTarget.onClick = { [weak self] in self?.showAgentsDashboard(activatesClicky: true) }
        agentsVoiceStateCancellable = $voiceState.removeDuplicates().sink { [weak self] newVoiceState in
            self?.updateBrainAgent(for: newVoiceState)
        }
        startWakeWord()
        refreshAllPermissions()
        print("🔑 Theo start: accessibility \(hasAccessibilityPermission), screen \(hasScreenRecordingPermission), mic \(hasMicrophonePermission), screen content \(hasScreenContentPermission)")
        startPermissionPolling()
        bindVoiceStateObservation()
        bindAudioPowerLevel()
        bindShortcutTransitions()
        bindEscapeKey()
        _ = claudeCodeBridge
        refreshClaudeCodeSignInStatus()
        showSparkIfReady()
    }

    /// Once everything is allowed the spark appears; the very first time it says hello.
    func showSparkIfReady() {
        guard allPermissionsGranted, isClickyCursorEnabled, !isOverlayVisible, TheoLink.shared.clickyRunsHere else { return }
        let isFirstTime = !hasCompletedOnboarding
        hasCompletedOnboarding = true
        putSparkOnScreens(greeting: isFirstTime)
    }

    /// Plays the first-run hello again (and closes the menu-bar panel so it doesn't cover it).
    func triggerOnboarding() {
        NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)
        hasCompletedOnboarding = true
        sparkOverlay.hasShownOverlayBefore = false
        putSparkOnScreens(greeting: true)
    }

    /// Setup's "Test the spark": the overlay has to be up to show it.
    func showOverlayForSparkTest() {
        guard !isOverlayVisible else { return }
        sparkOverlay.showOverlay(onScreens: NSScreen.ownerScreens, companionManager: self)
        isOverlayVisible = true
        scheduleTransientHideIfNeeded()
    }

    func clearDetectedElementLocation() {
        detectedElementScreenLocation = nil
        detectedElementDisplayFrame = nil
        pointTargetCG = nil
    }

    func clearLiveScreenMarks() {
        liveScreenMarksAutoClearTask?.cancel()
        liveScreenMarksAutoClearTask = nil
        markController.clear()
    }

    /// Keeps the marks up while the buddy is still talking, then for a short
    /// grace period so the user can follow them, then clears them.
    private func scheduleLiveScreenMarksAutoClear() {
        liveScreenMarksAutoClearTask?.cancel()
        guard hasLiveScreenMarks else { return }

        liveScreenMarksAutoClearTask = Task {
            while speechOutputClient.isPlaying {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }
            }
            try? await Task.sleep(nanoseconds: Self.liveScreenMarksSecondsToKeepAfterSpeech * 1_000_000_000)
            guard !Task.isCancelled else { return }
            markController.clear()
        }
    }

    func stop() {
        speechOutputClient.shutDown()
        endHandsFreeSession()
        wakeWordController.stop()
        [wakeWordVoiceStateCancellable, escapeKeyCancellable, agentsVoiceStateCancellable,
         shortcutTransitionCancellable, voiceStateCancellable, audioPowerCancellable].forEach { $0?.cancel() }
        pushToTalkKeys.stop()
        dictationController.keys.stop()
        TheoCallController.end()
        pushToTalkRecorder.cancelCurrentDictation()
        sparkOverlay.hideOverlay()
        transientHideTask?.cancel()
        currentResponseTask?.cancel()
        currentResponseTask = nil
        projectBridge.stop()
        sparkClickTarget.reset()
        agentsCenter.saveNow(waitsForWrite: true)
        permissionPollTimer?.invalidate()
        permissionPollTimer = nil
    }

    // MARK: - Permissions

    private var hasLoggedPermissionStateThisLaunch = false

    /// Re-reads every privilege. Each @Published value is only written when it changes,
    /// because every write re-renders the overlays and panels watching this object.
    func refreshAllPermissions() {
        let before = (hasAccessibilityPermission, hasScreenRecordingPermission, hasMicrophonePermission)

        let accessibility = TheoPermissions.isAccessibilityGranted
        if hasAccessibilityPermission != accessibility { hasAccessibilityPermission = accessibility }
        // The keyboard listener needs Accessibility.
        accessibility ? pushToTalkKeys.start() : pushToTalkKeys.stop()
        dictationController.refresh(accessibilityGranted: accessibility)

        let screenRecording = TheoPermissions.isScreenRecordingGranted
        if hasScreenRecordingPermission != screenRecording { hasScreenRecordingPermission = screenRecording }

        let microphone = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        if hasMicrophonePermission != microphone { hasMicrophonePermission = microphone }

        // The screen-content picker's approval is remembered once seen.
        if !hasScreenContentPermission, UserDefaults.standard.bool(forKey: "hasScreenContentPermission") {
            hasScreenContentPermission = true
        }

        let after = (hasAccessibilityPermission, hasScreenRecordingPermission, hasMicrophonePermission)
        if !hasLoggedPermissionStateThisLaunch || before != after {
            hasLoggedPermissionStateThisLaunch = true
            let speech = SFSpeechRecognizer.authorizationStatus() == .authorized ? "yes" : "no"
            let line = "accessibility \(after.0), screen \(after.1), mic \(after.2), screen content \(hasScreenContentPermission), speech \(speech)"
            print("🔑 Permissions: \(line)")
            permissionLogger.notice("Permissions: \(line, privacy: .public)")
        }
        showSparkIfReady()
    }

    /// Asks macOS for screen content by taking one tiny capture (that's what brings up its picker),
    /// and remembers the approval.
    @Published private(set) var isRequestingScreenContent = false

    func requestScreenContentPermission() {
        guard !isRequestingScreenContent else { return }
        isRequestingScreenContent = true
        Task {
            var approved = false
            do {
                let shareable = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                if let display = shareable.displays.first {
                    let settings = SCStreamConfiguration()
                    settings.width = 160
                    settings.height = 120
                    let image = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(display: display, excludingWindows: []),
                                                                           configuration: settings)
                    approved = image.width > 0 && image.height > 0
                }
            } catch {
                print("⚠️ Screen content request failed: \(error)")
            }
            isRequestingScreenContent = false
            guard approved else { return }
            hasScreenContentPermission = true
            UserDefaults.standard.set(true, forKey: "hasScreenContentPermission")
            showSparkIfReady()
        }
    }

    /// The Mac's microphone prompt, if it was never shown.
    private func promptForMicrophoneIfNotDetermined() {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined else { return }
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            Task { @MainActor [weak self] in self?.hasMicrophonePermission = granted }
        }
    }

    /// Re-checks every 1.5 s and whenever Theo comes to the front (back from System Settings).
    /// Screen Recording still needs a relaunch to take effect.
    private func startPermissionPolling() {
        permissionPollTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { _ in
            Task { @MainActor [weak self] in self?.refreshAllPermissions() }
        }
        appDidBecomeActiveObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            Task { @MainActor [weak self] in self?.refreshAllPermissions() }
        }
    }

    // MARK: - Push-to-talk

    /// The recorder's loudness feeds the spark's level meter.
    private func bindAudioPowerLevel() {
        audioPowerCancellable = pushToTalkRecorder.$currentAudioPowerLevel
            .receive(on: DispatchQueue.main)
            .sink { [weak self] level in self?.currentAudioPowerLevel = level }
    }

    /// Recording → listening; finishing or getting ready → processing; otherwise idle.
    /// While an answer is being given, the answer pipeline owns the state.
    private func bindVoiceStateObservation() {
        voiceStateCancellable = Publishers.CombineLatest3(pushToTalkRecorder.$isRecordingFromKeyboardShortcut,
                                                          pushToTalkRecorder.$isFinalizingTranscript,
                                                          pushToTalkRecorder.$isPreparingToRecord)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] recording, finishing, preparing in
                guard let self, self.voiceState != .responding else { return }
                if recording {
                    self.voiceState = .listening
                } else if finishing || preparing {
                    self.voiceState = .processing
                } else {
                    self.voiceState = .idle
                    // Keys tapped with nothing said: no answer will hide a temporary spark, so do it here.
                    if self.currentResponseTask == nil { self.scheduleTransientHideIfNeeded() }
                }
            }
    }

    private func bindShortcutTransitions() {
        shortcutTransitionCancellable = pushToTalkKeys.transitions
            .receive(on: DispatchQueue.main)
            .sink { [weak self] transition in self?.handleShortcutTransition(transition) }
    }

    private func handleShortcutTransition(_ transition: PushToTalkTransition) {
        switch transition {
        case .pressed: pushToTalkPressed()
        case .released: pushToTalkReleased()
        case .none: break
        }
    }

    /// Keys down: stop whatever Theo is saying, get the screens and the brain ready, start recording.
    private func pushToTalkPressed() {
        lastShortcutPressDate = Date()
        // Hands-free already has the mic open; a double tap ends it instead. A call has it too.
        guard !isHandsFreeSessionActive, !pushToTalkRecorder.isDictationInProgress, !TheoCallController.isActive else { return }

        // The wake listener gives up the mic until key-up.
        speechOutputClient.audioEngineHub.claimMicrophone(for: .pushToTalk)
        if TheoLink.shared.clickyRunsHere { groundingCoordinator.prewarm() }
        transientHideTask?.cancel()
        transientHideTask = nil
        // With the spark hidden by choice it still shows for this exchange.
        if !isClickyCursorEnabled && !isOverlayVisible { putSparkOnScreens(greeting: false) }
        NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)

        // Barge in: voices off, caption frozen, the answer in flight cancelled.
        speechOutputClient.stopVoicesNow()
        speechOutputClient.activeCoordinator?.bargeIn(.pushToTalk)
        currentResponseTask?.cancel()
        speechOutputClient.stopPlayback()
        clearDetectedElementLocation()

        // Start the brain now so key-up only has to send the words.
        prespawnMainBrainStandby()
        zoomChecker.prespawnStandbyIfEnabled()

        if showOnboardingPrompt {
            withAnimation(.easeOut(duration: 0.3)) { onboardingPromptOpacity = 0 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                self.showOnboardingPrompt = false
                self.onboardingPromptText = ""
            }
        }

        pendingKeyboardShortcutStartTask?.cancel()
        pendingKeyboardShortcutStartTask = Task {
            await pushToTalkRecorder.startPushToTalkFromKeyboardShortcut(currentDraftText: "", updateDraftText: { _ in }) { [weak self] words in
                guard let self else { return }
                // "slower" / "faster" on their own change the voice speed; no brain turn.
                if self.applyVoiceSpeedCommandIfExact(words) { return }
                self.lastTranscript = words
                print("🗣️ Heard: \(words)")
                self.sendTranscriptToClaudeWithScreenshot(transcript: words,
                                                         turnOptions: TurnOptions(keyUpDate: self.lastPushToTalkReleaseDate ?? Date()))
            }
        }
    }

    /// Keys up: stop recording (the words arrive a moment later). Two quick taps start hands-free.
    private func pushToTalkReleased() {
        let isDoubleTap = registerShortcutReleaseAndDetectDoubleTap()
        if isHandsFreeSessionActive {
            if isDoubleTap { endHandsFreeSession() }
            return
        }
        lastPushToTalkReleaseDate = Date()
        // A press released before recording began must still end cleanly.
        pendingKeyboardShortcutStartTask?.cancel()
        pendingKeyboardShortcutStartTask = nil
        pushToTalkRecorder.stopPushToTalkFromKeyboardShortcut()
        speechOutputClient.audioEngineHub.releaseMicrophone(for: .pushToTalk)
        if isDoubleTap {
            // The two taps each recorded a sliver of silence: throw them away.
            pushToTalkRecorder.cancelCurrentDictation(preserveDraftText: false)
            startHandsFreeSession()
        }
    }

    // MARK: - Wake Word (P7)

    private func startWakeWord() {
        wakeWordController.onWake = { [weak self] initialTurnText in self?.wakeWordDidFire(initialTurnText: initialTurnText) }
        wakeWordController.onStopCommand = { [weak self] in self?.wakeStopCommandHeard() }
        wakeWordController.onTurnFinished = { [weak self] turnText in self?.wakeWordTurnDidFinish(turnText: turnText) }
        wakeWordController.onTurnAbandoned = { [weak self] in self?.wakeWordTurnWasAbandoned() }
        // P8 follow-up window: the answer is done once nothing is thinking, speaking or acting
        // (an action task waiting for a spoken yes counts as done, so the yes needs no wake word).
        wakeWordController.isAnswerBusy = { [weak self] in
            guard let self else { return false }
            let isActionTaskBusy = self.actionTaskController.isActive && !self.actionTaskController.isAwaitingConfirmation
            return self.voiceState != .idle || self.speechOutputClient.isPlaying || isActionTaskBusy
        }
        wakeWordController.onFollowUpCommandStarted = { [weak self] in self?.wakeWordFollowUpCommandDidStart() }
        wakeWordController.onFollowUpEnded = { [weak self] reason in self?.wakeWordFollowUpDidEnd(reason) }
        // Clicky starting or stopping an answer: the wake recognizer goes deaf / listens again.
        wakeWordVoiceStateCancellable = $voiceState.removeDuplicates().sink { [weak self] _ in
            DispatchQueue.main.async { self?.wakeWordController.refreshSpeechSuppression() }
        }
        if DeviceRoles.runsHere(.voice) { wakeWordController.start() }
    }

    /// The wake phrase fired: the same set-up as a push-to-talk key-down
    /// (listening state, screens and CLI warming up), then the turn is heard
    /// by the wake listener until the hands-free end-of-speech rule ends it.
    /// P9: "stop" / "wait" heard by the wake listener: silence Clicky and end any action right away.
    private func wakeStopCommandHeard() {
        let isActing = actionTaskController.isActive
        guard speechOutputClient.isPlaying || isActing || currentResponseTask != nil else { return }
        print("✋ Barge-in: stop heard")
        speechOutputClient.activeCoordinator?.bargeIn(.escape)
        speechOutputClient.stopPlayback()
        currentResponseTask?.cancel()
        if isActing { actionTaskController.cancel(reason: "you said stop", stopsSpeech: true, speaksLine: false) }
        voiceState = .idle
    }

    private func wakeWordDidFire(initialTurnText: String) {
        guard !isHandsFreeSessionActive, !pushToTalkRecorder.isDictationInProgress else {
            wakeWordController.cancelCurrentTurn()
            return
        }
        if TheoLink.shared.clickyRunsHere { groundingCoordinator.prewarm() }
        transientHideTask?.cancel()
        transientHideTask = nil
        if !isClickyCursorEnabled && !isOverlayVisible && TheoLink.shared.clickyRunsHere {
            sparkOverlay.hasShownOverlayBefore = true
            sparkOverlay.showOverlay(onScreens: NSScreen.ownerScreens, companionManager: self)
            isOverlayVisible = true
        }
        NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)
        // A new question replaces an answer still being worked on (P9: also an action in progress).
        speechOutputClient.activeCoordinator?.bargeIn(.newQuestion)
        currentResponseTask?.cancel()
        speechOutputClient.stopPlayback()
        if actionTaskController.isActive { actionTaskController.cancel(reason: "you asked something new", stopsSpeech: true, speaksLine: false) }
        clearDetectedElementLocation()
        prespawnMainBrainStandby()
        zoomChecker.prespawnStandbyIfEnabled()
        // The hands-free session's start sound, reused.
        NSSound(named: "Pop")?.play()
        voiceState = .listening
    }

    private func wakeWordTurnDidFinish(turnText: String) {
        guard voiceState == .listening, !pushToTalkRecorder.isDictationInProgress, !isHandsFreeSessionActive else { return }
        voiceState = .idle
        lastTranscript = turnText
        // Latency is measured from the end of speech, as push-to-talk does from key-up.
        sendTranscriptToClaudeWithScreenshot(transcript: turnText, turnOptions: TurnOptions(keyUpDate: Date()))
        if currentResponseTask == nil { scheduleTransientHideIfNeeded() }
        // P8: once this is answered, listen a little longer for another command (wake turns only).
        wakeWordController.wakeTurnWasSent()
    }

    /// P8: words inside the follow-up window (no wake word): the listening state without the Pop.
    private func wakeWordFollowUpCommandDidStart() {
        guard !isHandsFreeSessionActive, !pushToTalkRecorder.isDictationInProgress, voiceState == .idle else {
            wakeWordController.cancelCurrentTurn()
            return
        }
        transientHideTask?.cancel()
        transientHideTask = nil
        voiceState = .listening
    }

    /// P8: "that's all", 10 s of nothing, or cancelled. Dictation ends with the window unless cancelled.
    private func wakeWordFollowUpDidEnd(_ reason: WakeFollowUpEndReason) {
        if reason != .cancelled, voiceCommandController.isDictating {
            voiceCommandController.stopDictation(speaks: false, reason: reason.rawValue)
        }
        if voiceState == .idle { scheduleTransientHideIfNeeded() }
    }

    private func wakeWordTurnWasAbandoned() {
        guard voiceState == .listening, !pushToTalkRecorder.isDictationInProgress else { return }
        voiceState = .idle
        claudeCodeBridge.reapStandbyProcess()
        zoomChecker.reapStandby()
        scheduleTransientHideIfNeeded()
    }

    /// "stop listening" turns the wake word off until "start listening" or the menu toggle.
    private func performWakeListeningCommand(_ wakeListeningCommand: WakeListeningCommand, speaks: Bool) {
        if wakeListeningCommand == .silentModeOn || wakeListeningCommand == .silentModeOff {
            setSilentModeEnabled(wakeListeningCommand == .silentModeOn)
            let confirmation = isSilentModeEnabled
                ? "Silent mode on. I'm still listening; answers show on screen."
                : "Okay, I'll talk again."
            Task { try? await speechOutputClient.speakText(confirmation) }
            return
        }
        let enables = wakeListeningCommand == .startListening
        wakeWordController.setEnabled(enables)
        guard speaks else { return }
        let confirmation = enables
            ? "Okay, I'm listening for hey Theo again."
            : "Okay, I've stopped listening for my name. Say start listening with the shortcut to turn it back on."
        Task { try? await speechOutputClient.speakText(confirmation) }
    }

    // MARK: - Hands-Free Session

    /// True while the always-on mic session is running (started by
    /// double-tapping the shortcut or from the panel).
    @Published private(set) var isHandsFreeSessionActive = false
    /// Set by "wait" / "stop", cleared by "go". The autopilot scroller
    /// (later phase) holds still while this is true.
    @Published private(set) var isHandsFreeSessionPaused = false
    /// Live partial transcript, shown in the session indicator.
    @Published private(set) var handsFreeLastHeardText = ""
    @Published private(set) var handsFreeSessionCaptureCount = 0
    /// Short-lived feedback in the indicator, e.g. "Saved capture 3".
    @Published private(set) var handsFreeStatusMessage: String?
    /// Scroll speed for the autopilot scroller (later phase), adjusted by
    /// "slower" / "faster" while it runs. 1.0 is the default speed.
    @Published private(set) var autopilotScrollSpeedMultiplier: Double = 1.0
    /// Set by the autopilot scroller (later phase) while it scrolls. When
    /// it isn't, "slower" / "faster" change the voice speed instead.
    @Published private(set) var isAutopilotScrollRunning = false

    private var handsFreeListeningSession: HandsFreeListeningSession?
    private var handsFreeSessionCaptureStore: HandsFreeSessionCaptureStore?
    private let handsFreeSessionIndicatorManager = HandsFreeSessionIndicatorManager()
    private var handsFreeStatusMessageClearTask: Task<Void, Never>?
    private var escapeKeyCancellable: AnyCancellable?

    /// The buddy was talking while this utterance was being heard. If it's
    /// not a command, it's most likely the mic picking up the buddy's own
    /// voice, so we drop it instead of sending it to Claude.
    private var currentUtteranceOverlappedBuddySpeech = false

    /// Two quick taps of the shortcut within this window toggle the session.
    private static let shortcutDoubleTapMaximumIntervalSeconds: TimeInterval = 0.45
    /// A press shorter than this counts as a tap rather than push-to-talk.
    private static let shortcutTapMaximumHoldSeconds: TimeInterval = 0.3
    private var lastShortcutPressDate: Date?
    private var lastShortcutTapReleaseDate: Date?

    func toggleHandsFreeSession() {
        if isHandsFreeSessionActive {
            endHandsFreeSession()
        } else {
            startHandsFreeSession()
        }
    }

    func startHandsFreeSession() {
        guard !isHandsFreeSessionActive else { return }

        NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)
        stopBuddySpeechAndCancelResponse()

        transientHideTask?.cancel()
        transientHideTask = nil
        if !isOverlayVisible {
            sparkOverlay.hasShownOverlayBefore = true
            sparkOverlay.showOverlay(onScreens: NSScreen.ownerScreens, companionManager: self)
            isOverlayVisible = true
        }

        // P7: the wake listener gives the mic to the session until it ends.
        speechOutputClient.audioEngineHub.claimMicrophone(for: .handsFree)
        let handsFreeListeningSession = HandsFreeListeningSession(
            requestedEchoMode: ClickySettings.echoMode,
            audioEngineHub: speechOutputClient.audioEngineHub,
            onPartialTranscript: { [weak self] partialTranscript in
                self?.handleHandsFreePartialTranscript(partialTranscript)
            },
            onUtteranceFinished: { [weak self] finishedUtterance in
                self?.handleHandsFreeUtteranceFinished(finishedUtterance)
            }
        )
        self.handsFreeListeningSession = handsFreeListeningSession
        handsFreeSessionCaptureStore = HandsFreeSessionCaptureStore()

        isHandsFreeSessionActive = true
        isHandsFreeSessionPaused = false
        handsFreeLastHeardText = ""
        handsFreeSessionCaptureCount = 0
        currentUtteranceOverlappedBuddySpeech = false
        handsFreeSessionIndicatorManager.showIndicator(companionManager: self)
        NSSound(named: "Pop")?.play()

        Task {
            do {
                try await handsFreeListeningSession.startListening()
            } catch {
                print("⚠️ Hands-free session couldn't start: \(error)")
                endHandsFreeSession()
                try? await speechOutputClient.speakText(error.localizedDescription)
            }
        }
    }

    func endHandsFreeSession() {
        guard isHandsFreeSessionActive else { return }
        claudeCodeBridge.reapStandbyProcess()
        zoomChecker.reapStandby()

        handsFreeListeningSession?.stopListening()
        handsFreeListeningSession = nil
        speechOutputClient.audioEngineHub.releaseMicrophone(for: .handsFree)
        isHandsFreeSessionActive = false
        isHandsFreeSessionPaused = false
        handsFreeLastHeardText = ""
        handsFreeStatusMessageClearTask?.cancel()
        handsFreeStatusMessage = nil
        handsFreeSessionIndicatorManager.hideIndicator()
        NSSound(named: "Bottle")?.play()

        let endedSessionCaptureStore = handsFreeSessionCaptureStore
        handsFreeSessionCaptureStore = nil
        let savedCaptureCount = endedSessionCaptureStore?.savedCaptureFileURLs.count ?? 0

        if savedCaptureCount > 0 {
            endedSessionCaptureStore?.revealCapturesInFinder()
            let captureWord = savedCaptureCount == 1 ? "capture" : "captures"
            Task {
                try? await speechOutputClient.speakText("session done. I saved \(savedCaptureCount) \(captureWord).")
            }
        }

        scheduleTransientHideIfNeeded()
    }

    private func handleHandsFreePartialTranscript(_ partialTranscript: String) {
        handsFreeLastHeardText = partialTranscript
        // First words of an utterance: start reading the screens and the CLI.
        if TheoLink.shared.clickyRunsHere { groundingCoordinator.prewarm() }
        if claudeCodeBridge.standbySlot.currentProcess?.isHealthy != true {
            prespawnMainBrainStandby()
        }
        zoomChecker.prespawnStandbyIfEnabled()

        // Until output latency + 0.25 s after the last audio, what the mic
        // hears is most likely Clicky itself.
        if speechOutputClient.isPlayingOrEchoTail {
            // The mode that actually runs ("aec" may have resolved to open / halfDuplex).
            let activeEchoMode = handsFreeListeningSession?.effectiveEchoMode ?? ClickySettings.echoMode
            // AEC: Clicky's words that leaked past the canceller (last 4 words
            // ≥ 60 % its own) are dropped, so they don't start an utterance.
            if activeEchoMode == .aec, let activeCoordinator = speechOutputClient.activeCoordinator,
               activeCoordinator.isLikelyEcho(partialTranscript) {
                print("🔇 Hands-free: echo of Clicky's own words dropped: \(partialTranscript)")
                handsFreeListeningSession?.discardCurrentUtterance()
                currentUtteranceOverlappedBuddySpeech = false
                return
            }
            currentUtteranceOverlappedBuddySpeech = true
            // Half-duplex: nothing the mic hears while Clicky talks counts.
            if activeEchoMode == .halfDuplex { return }
            // "stop" / "wait" / "clicky stop" barge in, unless Clicky itself
            // just said that word (the mic heard the speaker). AEC: only those
            // exact phrases count while it plays.
            if let activeCoordinator = speechOutputClient.activeCoordinator, activeCoordinator.isSpeaking {
                let isAcceptedBargeIn = activeEchoMode == .aec
                    ? activeCoordinator.heardWhileSpeakingWithEchoCancellation(partialTranscript)
                    : activeCoordinator.heardWhileSpeaking(partialTranscript)
                if isAcceptedBargeIn {
                    handsFreeListeningSession?.discardCurrentUtterance()
                    currentUtteranceOverlappedBuddySpeech = false
                    isHandsFreeSessionPaused = true
                    showHandsFreeStatusMessage("Stopped")
                }
                // A "wait" the mic heard from Clicky's own voice is ignored.
                return
            }
        }

        // "wait" / "stop" should cut the buddy off mid-sentence, so check
        // partial transcripts for them instead of waiting for the pause.
        // Only when there's something to interrupt — otherwise a sentence
        // that merely starts with "stop…" would get chopped in half.
        let isBuddyBusy = speechOutputClient.isPlaying || voiceState == .processing || actionTaskController.isActive
        guard isBuddyBusy,
              let instantCommand = HandsFreeVoiceCommand.parse(partialTranscript),
              instantCommand.shouldTriggerOnPartialTranscript else {
            return
        }

        // Start a fresh utterance so these words aren't delivered again
        // (and run twice) when the user stops talking.
        handsFreeListeningSession?.discardCurrentUtterance()
        currentUtteranceOverlappedBuddySpeech = false
        performHandsFreeVoiceCommand(instantCommand)
    }

    private func handleHandsFreeUtteranceFinished(_ finishedUtterance: String) {
        let utteranceOverlappedBuddySpeech = currentUtteranceOverlappedBuddySpeech
        currentUtteranceOverlappedBuddySpeech = false

        // P7: a yes/no to an action's confirm card, or "stop" (not Clicky's own echo).
        if !utteranceOverlappedBuddySpeech, actionTaskController.isActive,
           actionTaskController.isReplyToPendingConfirmation(finishedUtterance) || ActionStopCommand.isStop(finishedUtterance) {
            if actionTaskController.handleOwnerTranscript(finishedUtterance) { return }
        }

        // P8: "save my notes" (not Clicky's own echo).
        if !utteranceOverlappedBuddySpeech, NotesVoiceCommand.parse(finishedUtterance) == .save {
            speakCodeModeLine(articleController.saveNotesAndDescribe())
            return
        }

        // Board commands first (with a board open "next" / "pause" mean the board).
        if let boardCommand = BoardVoiceCommand.parse(finishedUtterance), !boardCommand.needsOpenBoard || boardController.isOpen {
            // While Clicky talks, only if it didn't just say those words itself.
            if utteranceOverlappedBuddySpeech, let activeCoordinator = speechOutputClient.activeCoordinator,
               !activeCoordinator.echoGuard.accepts(finishedUtterance, commandWords: BoardVoiceCommand.echoWords(in: finishedUtterance), at: Date()) {
                print("🔇 Hands-free: board command heard in Clicky's own words, ignored: \(finishedUtterance)")
                return
            }
            performBoardVoiceCommand(boardCommand)
            return
        }

        if let voiceCommand = HandsFreeVoiceCommand.parse(finishedUtterance) {
            performHandsFreeVoiceCommand(voiceCommand)
            return
        }

        guard !utteranceOverlappedBuddySpeech else {
            print("🔇 Hands-free: ignored speech heard while the buddy was talking: \(finishedUtterance)")
            return
        }

        lastTranscript = finishedUtterance
        sendTranscriptToClaudeWithScreenshot(transcript: finishedUtterance)
    }

    private func performHandsFreeVoiceCommand(_ voiceCommand: HandsFreeVoiceCommand) {
        print("⚡️ Hands-free command: \(voiceCommand)")

        switch voiceCommand {
        case .pause:
            stopBuddySpeechAndCancelResponse()
            isHandsFreeSessionPaused = true
            showHandsFreeStatusMessage("Paused")

        case .resume:
            isHandsFreeSessionPaused = false
            showHandsFreeStatusMessage("Continuing")

        case .capture(let requestedCaptureCount):
            captureScreenForHandsFreeSession(requestedCaptureCount: requestedCaptureCount)

        case .slower:
            if isAutopilotScrollRunning {
                autopilotScrollSpeedMultiplier = max(0.25, autopilotScrollSpeedMultiplier * 0.75)
                showHandsFreeStatusMessage(String(format: "Scroll speed %.2g×", autopilotScrollSpeedMultiplier))
            } else {
                let newRate = speechOutputClient.stepVoiceRate(faster: false)
                showHandsFreeStatusMessage(String(format: "Voice speed %.2f×", newRate))
            }

        case .faster:
            if isAutopilotScrollRunning {
                autopilotScrollSpeedMultiplier = min(3.0, autopilotScrollSpeedMultiplier * 1.33)
                showHandsFreeStatusMessage(String(format: "Scroll speed %.2g×", autopilotScrollSpeedMultiplier))
            } else {
                let newRate = speechOutputClient.stepVoiceRate(faster: true)
                showHandsFreeStatusMessage(String(format: "Voice speed %.2f×", newRate))
            }

        case .clearMarks:
            clearLiveScreenMarks()
            showHandsFreeStatusMessage("Cleared marks")

        case .copyLastAnswer:
            copyLastAnswerToPasteboard()
            showHandsFreeStatusMessage(lastAnswerText == nil ? "Nothing to copy yet" : "Copied the last answer")

        case .endSession:
            endHandsFreeSession()
        }
    }

    /// Saves one full-resolution screenshot of the cursor's screen. When the
    /// user asks for several ("capture these two"), the autopilot scroller
    /// will take the rest as it scrolls; until then each "capture" is one shot.
    private func captureScreenForHandsFreeSession(requestedCaptureCount: Int) {
        guard let handsFreeSessionCaptureStore else { return }

        Task {
            do {
                try await handsFreeSessionCaptureStore.captureCursorScreenAndSave()
                handsFreeSessionCaptureCount = handsFreeSessionCaptureStore.savedCaptureFileURLs.count
                NSSound(named: "Tink")?.play()

                if requestedCaptureCount > 1 {
                    showHandsFreeStatusMessage("Saved capture \(handsFreeSessionCaptureCount) · say “capture” for the next one")
                } else {
                    showHandsFreeStatusMessage("Saved capture \(handsFreeSessionCaptureCount)")
                }
            } catch {
                print("⚠️ Hands-free capture failed: \(error)")
                showHandsFreeStatusMessage("Couldn't save the screenshot")
            }
        }
    }

    func showHandsFreeStatusMessage(_ statusMessage: String) {
        handsFreeStatusMessage = statusMessage
        handsFreeStatusMessageClearTask?.cancel()
        handsFreeStatusMessageClearTask = Task {
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard !Task.isCancelled else { return }
            handsFreeStatusMessage = nil
        }
    }

    /// A push-to-talk transcript that is exactly "slower" or "faster" steps
    /// the voice speed (0.85 / 1.0 / 1.15 / 1.3) and says so at the new speed.
    /// While the autopilot scroller runs it changes the scroll speed instead.
    func applyVoiceSpeedCommandIfExact(_ transcript: String) -> Bool {
        let normalizedTranscript = transcript.lowercased().trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        guard normalizedTranscript == "slower" || normalizedTranscript == "faster" else { return false }
        let isFaster = normalizedTranscript == "faster"
        if isAutopilotScrollRunning {
            performHandsFreeVoiceCommand(isFaster ? .faster : .slower)
            return true
        }
        speechOutputClient.stepVoiceRate(faster: isFaster)
        Task {
            try? await speechOutputClient.speakText(isFaster ? "Okay, a bit faster." : "Okay, a bit slower.")
        }
        return true
    }

    /// Cuts off the buddy mid-sentence and abandons any answer in flight.
    func stopBuddySpeechAndCancelResponse() {
        // P7: "stop", Escape and the dashboard's Cancel end an action task too.
        actionTaskController.cancel(reason: "stopped", stopsSpeech: false, speaksLine: false)
        currentResponseTask?.cancel()
        speechOutputClient.stopPlayback()
        clearDetectedElementLocation()
        clearLiveScreenMarks()
        // A cancelled response task skips its own reset to idle, so do it here
        // or the cursor would stay stuck on the spinner.
        if voiceState == .processing || voiceState == .responding {
            voiceState = .idle
        }
    }

    /// Returns true when this release completes a quick double-tap.
    private func registerShortcutReleaseAndDetectDoubleTap() -> Bool {
        let releaseDate = Date()
        guard let lastShortcutPressDate,
              releaseDate.timeIntervalSince(lastShortcutPressDate) <= Self.shortcutTapMaximumHoldSeconds else {
            // A long hold is push-to-talk, not a tap — it breaks any tap sequence.
            lastShortcutTapReleaseDate = nil
            return false
        }

        if let lastShortcutTapReleaseDate,
           releaseDate.timeIntervalSince(lastShortcutTapReleaseDate) <= Self.shortcutDoubleTapMaximumIntervalSeconds {
            self.lastShortcutTapReleaseDate = nil
            return true
        }

        lastShortcutTapReleaseDate = releaseDate
        return false
    }

    private func bindEscapeKey() {
        escapeKeyCancellable = pushToTalkKeys
            .escapePressed
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                self?.handleEscapeKeyPressed()
            }
    }

    /// Panels that use Esc themselves (Type card, review panel, board) get
    /// it first: each returns true when it consumed the key.
    var escapeKeyConsumers: [() -> Bool] = []

    /// Escape is the universal "stop everything": it silences the buddy,
    /// cancels any answer in flight, and ends a hands-free session. A key
    /// panel that's open consumes it first.
    private func handleEscapeKeyPressed() {
        // Article highlights always go on Escape (the notes panel stays until it's closed).
        if !articleController.highlights.isEmpty { articleController.removeHighlights() }
        if escapeKeyConsumers.contains(where: { $0() }) { return }
        if let activeCoordinator = speechOutputClient.activeCoordinator, activeCoordinator.isSpeaking {
            // Barge-in: the caption is hidden.
            activeCoordinator.bargeIn(.escape)
            hideCaption()
        } else {
            hideCaption()
        }
        if wakeWordController.isHearingTurn {
            wakeWordController.cancelCurrentTurn()
            wakeWordTurnWasAbandoned()
        }
        // P8: Escape also closes the follow-up window and ends dictation.
        wakeWordController.cancelFollowUp()
        voiceCommandController.stopDictation(speaks: false, reason: "escape")
        let isBuddyBusy = speechOutputClient.isPlaying || voiceState == .processing
        let hasLiveScreenMarksShowing = hasLiveScreenMarks
        guard isHandsFreeSessionActive || isBuddyBusy || hasLiveScreenMarksShowing else { return }

        stopBuddySpeechAndCancelResponse()
        endHandsFreeSession()
    }

    // MARK: - Whiteboard commands

    func performBoardVoiceCommand(_ boardCommand: BoardVoiceCommand) {
        print("🧑‍🏫 Board command: \(boardCommand)")
        switch boardCommand {
        case .next: boardController.next()
        case .back: boardController.back()
        case .repeatStep: boardController.repeatStep()
        case .pause: boardController.pause()
        case .resume: boardController.resume()
        case .close: boardController.close()
        case .save:
            // "save the board" / "save this as a pdf": says where it went.
            speakCodeModeLine(saveBoardAndDescribe())
        case .whiteboardThat:
            whiteboardLastAnswer()
        case .goDeeper(let sectionNumber):
            goDeeper(onSection: sectionNumber)
        }
    }

    /// Saves the open board (PNG, PDF and .clickyboard in BoardExportLocation) and returns
    /// the line to say: where it went, that it failed, or that there's no board.
    /// Used by the "save board" / "save this as a pdf" voice commands and the model's [SNAP:board].
    func saveBoardAndDescribe() -> String {
        guard boardController.hasBoard else {
            showHandsFreeStatusMessage("No board to save")
            return BoardExportLocation.noBoardLine
        }
        let savedURL = boardController.exportBoard()
        showHandsFreeStatusMessage(savedURL == nil ? "Couldn't save the board" : "Saved the board to Pictures/Clicky")
        return savedURL == nil ? BoardExportLocation.failedLine : BoardExportLocation.savedLine
    }

    /// "whiteboard that": the last answer again, drawn as a board.
    func whiteboardLastAnswer() {
        guard let lastAnswerText, !lastAnswerText.isEmpty else {
            showHandsFreeStatusMessage("Nothing to put on a board yet")
            return
        }
        var turnOptions = TurnOptions()
        turnOptions.forcedModeHint = .whiteboard
        turnOptions.extraUserText = "redraw your last answer as a whiteboard (same content, as a board with steps). your last answer was:\n\(lastAnswerText)"
        sendTranscriptToClaudeWithScreenshot(transcript: "whiteboard that", turnOptions: turnOptions)
    }

    /// "go deeper on <n>": a new page about the board's n-th question section.
    func goDeeper(onSection sectionNumber: Int) {
        guard let board = boardController.board else {
            showHandsFreeStatusMessage("There's no board to go deeper on")
            return
        }
        let questionSections = BoardHistory.questionSections(of: board)
        guard questionSections.indices.contains(sectionNumber - 1),
              let sectionJSONL = BoardHistory.sectionJSONL(board: board, sectionIdentifier: questionSections[sectionNumber - 1].id) else {
            showHandsFreeStatusMessage("The board has no part \(sectionNumber)")
            return
        }
        var turnOptions = TurnOptions()
        turnOptions.forcedModeHint = .whiteboard
        turnOptions.extraUserText = "go deeper on this part of the board you drew: a new whiteboard page with more detail about it. the part, as JSON lines:\n\(sectionJSONL)"
        sendTranscriptToClaudeWithScreenshot(transcript: "go deeper on part \(sectionNumber)", turnOptions: turnOptions)
    }

    /// Plays an answer written elsewhere (T3 Code's `show`): its words are spoken and its tags run
    /// ([POINT]/[MARK] against `groundedTurn`, the screen the agent saw, else a fresh look; boards; actions).
    func playAnswer(_ answerText: String, groundedTurn seenTurn: GroundedTurn?, speaks: Bool, transcript: String) async -> URL? {
        let turnRecord = TurnLogger.beginTurn(transcript: transcript, keyUpDate: Date())
        let groundedTurn: GroundedTurn
        if let seenTurn {
            groundedTurn = seenTurn
        } else {
            guard let freshTurn = try? await groundingCoordinator.prepareTurn(keyUpDate: Date()) else { return nil }
            groundedTurn = freshTurn
        }
        currentResponseTask?.cancel()
        speechOutputClient.stopPlayback()
        markController.startAnswer(turnRecord: turnRecord)
        let answerSession = AnswerSession(transcript: transcript, groundedTurn: groundedTurn, turnRecord: turnRecord,
                                          companionManager: self, speaksResponse: speaks)
        currentAnswerSession = answerSession
        turnRecord?.rawResponse = answerText
        answerSession.handle(.messageStart(id: UUID().uuidString))
        answerSession.handle(.textDelta(answerText))
        answerSession.handle(.result(text: answerText, isError: false, subtype: "success"))
        await answerSession.waitUntilFinished()
        if let turnRecord { TurnLogger.finishTurn(turnRecord) }
        return turnRecord?.turnDirectoryURL
    }

    /// The debug inbox's `board`: an answer text (or a bare board's JSONL)
    /// played as if Claude had just said it, through the real answer path.
    func playDebugAnswer(_ answerText: String, speaks: Bool = true) async -> URL? {
        let fullAnswerText = WBBlockExtractor.containsWhiteboardBlock(answerText) ? answerText : "Here's the board.\n<whiteboard>\n\(answerText)\n</whiteboard>"
        let turnRecord = TurnLogger.beginTurn(transcript: "debug board", keyUpDate: Date())
        guard let groundedTurn = try? await groundingCoordinator.prepareTurn(keyUpDate: Date()) else { return nil }
        currentResponseTask?.cancel()
        speechOutputClient.stopPlayback()
        markController.startAnswer(turnRecord: turnRecord)
        let answerSession = AnswerSession(transcript: "debug board", groundedTurn: groundedTurn, turnRecord: turnRecord,
                                          companionManager: self, speaksResponse: speaks)
        currentAnswerSession = answerSession
        turnRecord?.rawResponse = fullAnswerText
        answerSession.handle(.textDelta(fullAnswerText))
        answerSession.handle(.result(text: fullAnswerText, isError: false, subtype: "success"))
        await answerSession.waitUntilFinished()
        if let turnRecord { TurnLogger.finishTurn(turnRecord) }
        return turnRecord?.turnDirectoryURL
    }

    // MARK: - Companion Prompt

    /// The main brain's system prompt. Pointing and live marks are only
    /// requested while grounding is trusted this session.
    /// The whiteboard section is in when a board can be drawn this turn:
    /// v2.whiteboard.auto is on (and the user didn't say "no board"), or the
    /// turn carries MODE: whiteboard ("draw a diagram", "whiteboard that").
    /// Otherwise the missing-ability sentence keeps saying it can't draw boards.
    private struct FastPressHandled: Error {}

    /// "Press Continue", "click this and that": Prism picks from what's on screen, and each press goes through the usual safety tiers.
    /// False when it isn't clear, and this is a normal Claude turn on the same screens.
    private func pressWithPrism(transcript: String, groundedTurn: GroundedTurn, turnOptions: TurnOptions, turnRecord: TurnRecord?) async throws -> Bool {
        guard turnOptions.isOwnersWords, turnOptions.extraUserText == nil, turnOptions.forcedModeHint == nil, PrismClient.isOn, ClickySettings.isActionsEnabled,
              ProviderKeys.shared.hasKey(for: "sarvam"), let steps = FastDecisions.pressRequest(transcript) else { return false }
        var grounded = groundedTurn
        // A new press replaces whatever Clicky was still doing, the same as any new request.
        if actionTaskController.isActive { actionTaskController.cancel(reason: "you asked something new", stopsSpeech: false, speaksLine: false) }
        // The whole phrase first: "press terms and conditions" is one button.
        // But Prism can settle on the first of two things, so with several steps it only counts if the label really has them both.
        if let pick = await prismPick(words: transcript, groundedTurn: grounded),
           steps.count == 1 || pick.label.range(of: #"(?i)\band\b|&"#, options: .regularExpression) != nil {
            turnRecord?.markTiming("prismPicked")
            if turnOptions.speaksResponse { speakCodeModeLine("Pressing \(String(pick.label.prefix(40))).") }
            _ = await actionTaskController.press(elementID: pick.elementID, label: pick.label, ownerWords: transcript, groundedTurn: grounded, speaks: turnOptions.speaksResponse)
            turnRecord?.markTiming("pressDone")
            return true
        }
        guard steps.count > 1 else { return false }
        for (index, step) in steps.enumerated() {
            if index > 0 {
                try await Task.sleep(nanoseconds: 500_000_000)
                grounded = try await groundingCoordinator.prepareTurn(keyUpDate: Date())
            }
            guard let pick = await prismPick(words: step, groundedTurn: grounded) else {
                if index == 0 { return false }
                // Some done, the rest isn't clear: Claude takes what's left, once this turn has ended.
                let rest = steps[index...].joined(separator: " and then ")
                var options = TurnOptions()
                options.speaksResponse = turnOptions.speaksResponse
                options.isOwnersWords = true
                options.skipsFastPress = true
                Task { @MainActor [weak self] in
                    for _ in 0..<40 where self?.voiceState != .idle { try? await Task.sleep(nanoseconds: 100_000_000) }
                    self?.sendTranscriptToClaudeWithScreenshot(transcript: rest, turnOptions: options)
                }
                return true
            }
            if index == 0 { turnRecord?.markTiming("prismPicked") }
            if turnOptions.speaksResponse { speakCodeModeLine("Pressing \(String(pick.label.prefix(40))).") }
            let pressed = await actionTaskController.press(elementID: pick.elementID, label: pick.label, ownerWords: step, groundedTurn: grounded, speaks: turnOptions.speaksResponse)
            turnRecord?.markTiming("pressDone")
            if !pressed { return true }
        }
        return true
    }

    private func prismPick(words: String, groundedTurn: GroundedTurn) async -> (elementID: Int, label: String)? {
        let pressable: Set<GroundingRole> = [.button, .link, .checkBox, .radio, .tab, .popUp, .menu, .menuItem, .cell, .row]
        var entries = groundedTurn.registry.orderedIDs.compactMap { groundedTurn.registry.entries[$0] }.filter { entry in
            let element = entry.element
            return pressable.contains(element.role) && element.isInteractive && element.isEnabled && !element.isBehind && !element.isSystemChrome
                && element.source == .accessibility && !(element.label ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        entries.sort { ($0.element.windowZIndex, $0.elementID) < ($1.element.windowZIndex, $1.elementID) }
        let pointerOn = entries.filter { $0.element.visibleFrameCG.contains(groundedTurn.cursorCG) }.min { $0.element.visibleFrameCG.width < $1.element.visibleFrameCG.width }?.element
        func ask(_ among: [ElementRegistry.Entry]) async -> (elementID: Int, label: String)? {
            let options = among.prefix(FastDecisionPolicy.pressOptionsAtMost).map {
                FastPressOption(id: String($0.elementID), role: $0.element.role.rawValue, label: $0.element.label ?? "", app: $0.element.applicationName ?? "this app")
            }
            guard let question = FastDecisions.whichToPress(words: words, options: Array(options), pointerOn: pointerOn?.label) else { return nil }
            let answers = await PrismClient.decideAll("press", question, timeout: 1.2)
            guard let pick = FastDecisions.pressPick(from: answers, options: Array(options)), let elementID = Int(pick.id) else { return nil }
            return (elementID, pick.label)
        }
        // What's in front or under the pointer first: it's what "press" usually means, and the other windows' words stay out of it.
        let inFront = entries.filter { $0.element.isInFrontWindow || ($0.element.windowID != nil && $0.element.windowID == pointerOn?.windowID) }
        if !inFront.isEmpty, let pick = await ask(inFront) { return pick }
        // Then whatever else can be seen, for a page on another monitor. A button only counts if it's clear from everything showing.
        return entries.count > inFront.count ? await ask(entries) : nil
    }

    private func companionSystemPrompt(modeHint: ModeHint) -> String {
        var promptFeatures = SystemPromptFeatures.current
        if !ClickySettings.areBadgesEnabled {
            promptFeatures.remove(.badges)
        }
        if !isGroundingActiveThisSession {
            promptFeatures.remove([.grounding, .badges])
        }
        // Gated sections: P4's whiteboard (auto, or a MODE: whiteboard turn), P5's code (registered at start).
        if (ClickySettings.isWhiteboardAutoEnabled && !modeHint.isAnswerOnly) || modeHint.isWhiteboard { promptFeatures.insert(.whiteboard) }
        if ClickySettings.isCodeEnabled { promptFeatures.insert(.code) }
        // Always: the spoken Code-mode switch ([CODEMODE:on] while off, [CODEMODE:off] while on).
        promptFeatures.insert(.codeToggle)
        if ClickySettings.isTypeForMeEnabled { promptFeatures.insert(.typing) }
        // "send this to my project …" works only from the user's words; Claude tells them the phrase.
        if ClickySettings.isProjectBridgeEnabled { promptFeatures.insert(.projectBridge) }
        // P7: the ACTIONS section (open apps, click, type, highlight, summarize…).
        if ClickySettings.isActionsEnabled { promptFeatures.insert(.actions) }
        var mainPrompt = SystemPromptBuilder.mainSystemPrompt(features: promptFeatures)
        // The name the owner gave the assistant (v2.assistant.name).
        let assistantName = ClickySettings.assistantName
        if assistantName.lowercased() != "theo" {
            mainPrompt = mainPrompt.replacingOccurrences(of: "you're theo (built on clicky)", with: "you're \(assistantName.lowercased())")
        }
        // Clicky's team, and Theo above it. Added here so the warm standby brain gets the same prompt.
        mainPrompt += "\n\n" + BotsStore.shared.clickyTeamPromptSection
        // A screen of its own: searches and links open in Claudia's own browser window there.
        if let claudiaScreen = ClaudiaScreen.picked, ClickySettings.isActionsEnabled {
            mainPrompt += "\n\nyour own screen: you have a display of your own (\"\(claudiaScreen.localizedName)\"). to search the web or open a site, always use a search or open_url step: they open in your own browser window on that display, so the user's windows stay as they are. never switch to the user's browser and type a search into it, unless they ask you to do something in a specific window of theirs."
        }
        // Unasked boards open small at the side of the screen. The same prompt goes with every turn (the
        // MODE line in the user's message decides a board), so the brain kept warm for the next question
        // also fits a board request instead of being thrown away and started cold.
        if ClickySettings.isWhiteboardAutoEnabled && promptFeatures.contains(.whiteboard) {
            return mainPrompt + "\n\n" + WhiteboardPromptSection.sideBoardText
        }
        return mainPrompt
    }

    /// How many earlier exchanges are sent with each question (text only).
    private static let conversationHistoryExchangeLimit = 6

    /// The first text block: earlier exchanges in words, then what the user
    /// just said. No coordinates, ids or images from earlier turns.
    private func makeConversationText(transcript: String) -> String {
        var conversationLines: [String] = []
        let recentHistory = conversationHistory.suffix(Self.conversationHistoryExchangeLimit)
        if !recentHistory.isEmpty {
            conversationLines.append("earlier in this conversation (text only):")
            for exchange in recentHistory {
                conversationLines.append("USER SAID: \"\(exchange.userTranscript)\"")
                conversationLines.append("YOU SAID: \(exchange.assistantResponse)")
            }
            conversationLines.append("")
        }
        conversationLines.append("USER SAID: \"\(transcript)\"")
        return conversationLines.joined(separator: "\n")
    }

    // MARK: - AI Response Pipeline

    /// P6.3: launches the main CLI for the next answer and leaves it waiting
    /// on stdin, with the settings a plain question uses (no MODE hint). A
    /// question that needs another effort or prompt reaps it and spawns
    /// fresh at key-up; one unused for 60 s is reaped.
    private func prespawnMainBrainStandby() {
        let defaultModeHint = ModeHint.detect("")
        claudeCodeBridge.prespawnStandbyProcess(
            systemPromptFileName: Self.mainSystemPromptFileName,
            systemPrompt: companionSystemPrompt(modeHint: defaultModeHint),
            effortLevel: ClickySettings.claudeEffortOverride ?? defaultModeHint.effort
        )
    }

    private static let mainSystemPromptFileName = "system-prompt.md"

    /// Optional extras for one turn, used by the debug inbox's `ask`.
    struct TurnOptions {
        /// false = no TTS; tags still fire right away.
        var speaksResponse = true
        /// When the user finished asking (key up / transcript arrival).
        var keyUpDate = Date()
        /// Called once the turn has fully finished (or failed/cancelled) with
        /// the turn's log directory.
        var onTurnFinished: ((URL?, Error?) -> Void)?
        /// P4 follow-ups ("whiteboard that", "go deeper on 2"): the MODE to
        /// use instead of detecting one, and text added after the user's words.
        var forcedModeHint: ModeHint?
        var extraUserText: String?
        /// P7 observe turns: the marks a highlight step drew stay up.
        var keepsLiveScreenMarks = false
        /// P8: the fast path already looked at this transcript (it had nothing by that name): straight to Claude.
        var skipsFastPath = false
        /// What's left of "press this and that", for Claude: Prism wasn't sure of it.
        var skipsFastPress = false
        /// False for words that aren't the owner's own (an agent's, Theo's): those stay out of Memory's log.
        var isOwnersWords = true
        /// Theo ordered this turn: what the team does for it reports back to him too.
        var theoOrder: ClickyTheoOrder?
        /// The other Mac sent this here because Clicky doesn't work there.
        var cameFromOtherMac = false
    }

    /// Reads the screens, streams Claude's answer and speaks it as it
    /// arrives: the caption follows the voice and tags fire on their words.
    /// The spinner stays until the first words play.
    func sendTranscriptToClaudeWithScreenshot(transcript: String, turnOptions requestedTurnOptions: TurnOptions? = nil) {
        // Built here rather than as a default argument, which Swift would
        // evaluate off the main actor.
        var turnOptions = requestedTurnOptions ?? TurnOptions()
        // "Clicky, work on the Air": the switch, wherever it's said.
        if !turnOptions.cameFromOtherMac, turnOptions.theoOrder == nil, let word = ClickyMachineWords.choice(in: transcript), TheoLink.shared.setClickyMac(word: word) {
            let line = "Okay, I'll work on \(TheoLink.shortName(TheoLink.shared.clickyMacNow)) now."
            showHandsFreeStatusMessage(line)
            if turnOptions.speaksResponse { speakCodeModeLine(line) }
            voiceState = .idle
            turnOptions.onTurnFinished?(nil, nil)
            return
        }
        // Clicky works on the Mac the switch says, wherever it's asked.
        if !turnOptions.cameFromOtherMac, !TheoLink.shared.clickyRunsHere {
            TheoLink.shared.sendClickyToOtherMac(transcript, speaks: turnOptions.speaksResponse)
            voiceState = .idle
            turnOptions.onTurnFinished?(nil, nil)
            return
        }
        // Memory keeps what the owner says to Clicky. Only their first pass at it, not a turn's continuations.
        if turnOptions.isOwnersWords, turnOptions.extraUserText == nil, turnOptions.forcedModeHint == nil, !turnOptions.skipsFastPath {
            BotsStore.shared.noteOwnerSaid(transcript)
        }
        // "Do it for me" after a step-by-step answer: Claudia clicks the steps she marked, in order
        // (an actions block on the fresh screen, with the usual countdown and safety tiers).
        if turnOptions.extraUserText == nil, ClickForMeCommand.matches(transcript), let markedSteps = lastMarkedStepsDescription {
            turnOptions.extraUserText = ClickForMeCommand.instruction(markedSteps: markedSteps)
        }
        // P7: while an action task runs, the owner's own words are a yes/no to its
        // confirm card, "stop", or a new request (which ends the task first).
        if turnOptions.extraUserText == nil, turnOptions.forcedModeHint == nil,
           actionTaskController.handleOwnerTranscript(transcript) {
            turnOptions.onTurnFinished?(nil, nil)
            return
        }
        // P8: a yes / no to a fast-path confirm ("Lock the screen?"), or a dictated line ("type what I say").
        if turnOptions.extraUserText == nil, turnOptions.forcedModeHint == nil,
           voiceCommandController.handleEarlyTranscript(transcript, speaks: turnOptions.speaksResponse) {
            turnOptions.onTurnFinished?(nil, nil)
            return
        }
        // "copy that" works with push-to-talk too, without asking Claude.
        if HandsFreeVoiceCommand.parse(transcript) == .copyLastAnswer {
            copyLastAnswerToPasteboard()
            turnOptions.onTurnFinished?(nil, nil)
            return
        }
        // "close the tabs you opened": the browser tabs Clicky opened for searches and links.
        if turnOptions.extraUserText == nil, BrowserTabCleanupCommand.matches(transcript) {
            let closedCount = BrowserTabTracker.shared.closeTracked()
            if turnOptions.speaksResponse {
                Task { try? await speechOutputClient.speakText(closedCount == 0 ? "There are no tabs of mine open." : "Closed \(closedCount) tab\(closedCount == 1 ? "" : "s").") }
            }
            turnOptions.onTurnFinished?(nil, nil)
            return
        }
        // P7: "stop listening" / "start listening" switch the wake word (push-to-talk or a wake turn).
        if turnOptions.extraUserText == nil, let wakeListeningCommand = WakeListeningCommand.parse(transcript) {
            performWakeListeningCommand(wakeListeningCommand, speaks: turnOptions.speaksResponse)
            turnOptions.onTurnFinished?(nil, nil)
            return
        }
        // P9 "research these links" / "research X for me" / "cancel research": runs in the background.
        if turnOptions.extraUserText == nil, turnOptions.forcedModeHint == nil,
           researchController.handleSpokenTranscript(transcript, speaks: turnOptions.speaksResponse) {
            turnOptions.onTurnFinished?(nil, nil)
            return
        }
        // "send this to my project …" (the owner's own words only): written to the
        // project outbox and answered here, no brain turn. Follow-ups that carry
        // extra text (code-mode continuations, "whiteboard that") never send.
        if turnOptions.extraUserText == nil, turnOptions.forcedModeHint == nil,
           projectBridge.handleSpokenTranscript(transcript, speaks: turnOptions.speaksResponse).isHandledLocally {
            turnOptions.onTurnFinished?(nil, nil)
            return
        }
        // "next voice", "use voice 3", "previous voice", "show voices": switched here,
        // no brain turn. The new voice says one short line only if this turn speaks.
        if turnOptions.extraUserText == nil, turnOptions.forcedModeHint == nil,
           let voiceGalleryCommand = VoiceGalleryCommand.parse(transcript) {
            voiceGalleryController.perform(voiceGalleryCommand, speaks: turnOptions.speaksResponse)
            turnOptions.onTurnFinished?(nil, nil)
            return
        }
        // P8: "save my notes" saves the notes panel's notes here, no brain turn.
        if turnOptions.extraUserText == nil, NotesVoiceCommand.parse(transcript) == .save {
            let line = articleController.saveNotesAndDescribe()
            if turnOptions.speaksResponse { speakCodeModeLine(line) }
            turnOptions.onTurnFinished?(nil, nil)
            return
        }
        // Board commands work with push-to-talk too ("next", "whiteboard that").
        if turnOptions.extraUserText == nil, let boardCommand = BoardVoiceCommand.parse(transcript),
           !boardCommand.needsOpenBoard || boardController.isOpen {
            performBoardVoiceCommand(boardCommand)
            turnOptions.onTurnFinished?(nil, nil)
            return
        }
        // P8 local fast path: "volume 40", "next song", "snap left", "switch to chrome", "new tab"… done on the
        // Mac in well under a second, no Claude call. Not found here ("open dark mode") → this same turn, to Claude.
        if turnOptions.extraUserText == nil, turnOptions.forcedModeHint == nil, !turnOptions.skipsFastPath {
            var claudeTurnOptions = turnOptions
            claudeTurnOptions.skipsFastPath = true
            let isHandledByFastPath = voiceCommandController.handleFastPathTranscript(
                transcript, speaks: turnOptions.speaksResponse,
                fallBackToClaude: { [weak self] in self?.sendTranscriptToClaudeWithScreenshot(transcript: transcript, turnOptions: claudeTurnOptions) },
                onFinished: { turnOptions.onTurnFinished?(nil, nil) })
            if isHandledByFastPath { return }
        }
        currentResponseTask?.cancel()
        speechOutputClient.stopPlayback()
        // The owner spoke: this turn isn't a bot's screen job any more.
        // Marks from the previous answer would be confusing next to a new one
        // (an action task's observe turn keeps what its highlight steps drew).
        if !turnOptions.keepsLiveScreenMarks { clearLiveScreenMarks() }

        let turnRecord = TurnLogger.beginTurn(transcript: transcript, keyUpDate: turnOptions.keyUpDate)
        // Zoom checks still running for the last answer apply nothing now.
        zoomChecker.beginQuestion()
        let brainAgentID = beginBrainAgent(transcript: transcript)

        currentResponseTask = Task {
            // Thinking: the spark spins until the first words are ready.
            voiceState = .processing
            var turnError: Error?
            /// Kept outside the do block so an interrupted answer can still log what it spoke.
            var activeAnswerSession: AnswerSession?

            do {
                // Every screen's element list + badged screenshot (warm from the
                // key-down prewarm when possible). SCREEN 1 = cursor screen.
                let prewarmReadyDate = groundingCoordinator.lastPrewarmReadyDate
                let groundedTurn = try await groundingCoordinator.prepareTurn(keyUpDate: turnOptions.keyUpDate)
                turnRecord?.markTiming("captureDone")
                turnRecord?.recordScreens(groundedTurn.screenCaptures)
                turnRecord?.recordElementLists(groundedTurn.elementListTexts)
                if !turnOptions.skipsFastPress, try await pressWithPrism(transcript: transcript, groundedTurn: groundedTurn, turnOptions: turnOptions, turnRecord: turnRecord) {
                    throw FastPressHandled()
                }
                turnRecord?.grounding = TurnRecord.GroundingEntry(
                    isWarm: groundedTurn.isWarm,
                    keyUpToReadyMs: groundedTurn.keyUpToReadyMilliseconds,
                    prewarmReadyBeforeKeyUp: prewarmReadyDate.map { $0 <= turnOptions.keyUpDate },
                    registryCount: groundedTurn.registry.orderedIDs.count,
                    badgedCount: groundedTurn.registry.orderedIDs.filter { groundedTurn.registry.entries[$0]?.isBadged == true }.count,
                    isBadged: groundedTurn.isBadged,
                    droppedAXApplications: groundedTurn.droppedAXApplications,
                    axWalks: groundingCoordinator.lastAXWalkStats,
                    ocrCoverage: groundingCoordinator.lastOCRCoverageStats,
                    latencyAlarm: groundedTurn.latencyAlarmWarning,
                    blackFrameRetry: groundedTurn.blackFrameRetry
                )

                guard !Task.isCancelled else { throw CancellationError() }

                let screenBlocks = groundedTurn.contentBlocks
                let conversationText = makeConversationText(transcript: transcript)
                // "draw a diagram" / "no whiteboard": a MODE hint (the user's words still win).
                let modeHint = turnOptions.forcedModeHint ?? ModeHint.detect(transcript)
                var userText = modeHint.line.map { conversationText + "\n" + $0 } ?? conversationText
                if let extraUserText = turnOptions.extraUserText { userText += "\n" + extraUserText }
                let remembered = BotsStore.shared.memoryStore.context()
                if !remembered.isEmpty { userText += "\n\n" + remembered }
                let systemPrompt = companionSystemPrompt(modeHint: modeHint)

                // Streamed: the router, segmenter and voice start on the first words.
                let answerSession = AnswerSession(transcript: transcript, groundedTurn: groundedTurn, turnRecord: turnRecord,
                                                  companionManager: self, speaksResponse: turnOptions.speaksResponse)
                answerSession.isWhiteboardTurn = modeHint.isWhiteboard
                answerSession.brainAgentID = brainAgentID
                answerSession.theoOrder = turnOptions.theoOrder
                currentAnswerSession = answerSession
                activeAnswerSession = answerSession
                markController.startAnswer(turnRecord: turnRecord)

                let effortLevel = ClickySettings.claudeEffortOverride ?? modeHint.effort
                let firstStreamUsage = try await runAnswerStream(answerSession, systemPrompt: systemPrompt, contentBlocks: [.text(userText)] + screenBlocks,
                                                                 effortLevel: effortLevel, allowsStandbyProcess: true, turnRecord: turnRecord)
                recordBrainUsage(firstStreamUsage, brainAgentID: brainAgentID, turnRecord: turnRecord)

                // Helpers spawned while streaming: wait for them, then ask
                // again with their results (same answer, same screens).
                // Board-section helpers (P6.7) draw into the board instead: no follow-up for them.
                if answerSession.hasFollowUpWorkers && !Task.isCancelled && !answerSession.isFinished {
                    let workerResults = await answerSession.followUpWorkerResults()
                    try Task.checkCancellation()
                    print("🧠 Workers finished: \(workerResults.map(\.workerTitle))")
                    answerSession.beginFollowUpStream()
                    agentsCenter.log(brainAgentID, "helpers done (\(workerResults.filter(\.didWorkerSucceed).count)/\(workerResults.count) ok); final answer")
                    let followUpStreamUsage = try await runAnswerStream(answerSession, systemPrompt: systemPrompt, contentBlocks: [.text(Self.makeMainBrainPromptWithWorkerResults(
                        transcript: userText, companionWorkerResults: workerResults))] + screenBlocks, effortLevel: effortLevel, turnRecord: nil)
                    recordBrainUsage(followUpStreamUsage, brainAgentID: brainAgentID, turnRecord: turnRecord)
                }
                turnRecord?.rawResponse = answerSession.rawResponse

                // Until the last word is spoken (or the answer is interrupted).
                await withTaskCancellationHandler {
                    await answerSession.waitUntilFinished()
                } onCancel: {
                    Task { @MainActor in answerSession.coordinator.bargeIn(.newQuestion) }
                }
                if Task.isCancelled {
                    // Interrupted while speaking: log what played before the cut.
                    turnRecord?.speech = Self.interruptedSpeechEntry(for: answerSession.coordinator)
                } else {
                    turnRecord?.speech = TurnRecord.SpeechEntry(
                        engine: answerSession.coordinator.isSilent ? nil : answerSession.coordinator.spokenEngineName,
                        fallback: answerSession.coordinator.didUseFallback,
                        voice: answerSession.coordinator.spokenEngineName == "qwen"
                            ? (ClickySettings.qwenReferenceClipPath as NSString).lastPathComponent : nil
                    )
                }
            } catch is CancellationError {
                // A new question or "stop" cut this answer off.
                turnError = CancellationError()
                // Log what actually played before the interrupt (the entry
                // after waitUntilFinished is never reached on this path).
                if let activeAnswerSession {
                    turnRecord?.speech = Self.interruptedSpeechEntry(for: activeAnswerSession.coordinator)
                } else {
                    turnRecord?.speech.interrupted = true
                    turnRecord?.speech.playedSegments = 0
                }
            } catch is FastPressHandled {
                // Prism picked it and it's been pressed: no Claude turn.
            } catch {
                print("⚠️ Companion response error: \(error)")
                turnError = error
                speakErrorFallback(for: error)
            }

            if let turnRecord {
                turnRecord.errorDescription = turnError.map { String(describing: $0) }
                TurnLogger.finishTurn(turnRecord)
            }
            finishBrainAgent(brainAgentID, turnError: turnError, wasCancelled: Task.isCancelled)
            turnOptions.onTurnFinished?(turnRecord?.turnDirectoryURL, turnError)
            // P7: an action task waits for its answer to end before it looks at the screen again.
            actionTaskController.answerTurnDidFinish(turnError: turnError, wasCancelled: Task.isCancelled || turnError is CancellationError)

            if !Task.isCancelled {
                // The Haiku standby lives only while this answer can draw marks
                // (a cancelled turn leaves it to the next question's key-down).
                zoomChecker.reapStandby()
                voiceState = .idle
                scheduleLiveScreenMarksAutoClear()
                scheduleTransientHideIfNeeded()
            }

            // Code mode was just switched on for this request: ask it again, now with the code section.
            if let continuationTranscript = pendingCodeModeContinuationTranscript, continuationTranscript == transcript {
                pendingCodeModeContinuationTranscript = nil
                if !Task.isCancelled && turnError == nil && ClickySettings.isCodeEnabled {
                    var continuationOptions = TurnOptions()
                    continuationOptions.speaksResponse = turnOptions.speaksResponse
                    continuationOptions.extraUserText = "(code mode is on now. handle the request above with a codetask; don't say you're turning code mode on again.)"
                    sendTranscriptToClaudeWithScreenshot(transcript: continuationTranscript, turnOptions: continuationOptions)
                }
            }
        }
    }

    /// turn.json speech for an answer cut off mid-way: the engine that spoke
    /// what played (the primary's name when nothing started yet, with
    /// playedSegments 0), whether the fallback spoke, and the Qwen clip.
    static func interruptedSpeechEntry(for coordinator: SpeechCoordinator) -> TurnRecord.SpeechEntry {
        let engineName = coordinator.isSilent ? nil : (coordinator.playedEngineName ?? coordinator.primaryEngineName)
        return TurnRecord.SpeechEntry(
            engine: engineName,
            fallback: coordinator.playedOnFallback,
            voice: engineName == "qwen" ? (ClickySettings.qwenReferenceClipPath as NSString).lastPathComponent : nil,
            interrupted: true,
            playedSegments: coordinator.playedSegmentCount
        )
    }

    /// Runs one Claude stream into the answer: every event goes to the
    /// session; stream failures become something said out loud.
    /// `allowsStandbyProcess`: the first stream may take the CLI pre-spawned
    /// at key-down (P6.3); worker follow-ups always spawn their own.
    @discardableResult
    private func runAnswerStream(_ answerSession: AnswerSession, systemPrompt: String, contentBlocks: [ClaudeContentBlock], effortLevel: String?,
                                 allowsStandbyProcess: Bool = false, turnRecord: TurnRecord?) async throws -> AgentUsage? {
        do {
            let mainBrainTurn = try await claudeCodeBridge.runTurn(
                systemPromptFileName: Self.mainSystemPromptFileName,
                systemPrompt: systemPrompt,
                contentBlocks: contentBlocks,
                effortLevel: effortLevel,
                allowsStandbyProcess: allowsStandbyProcess,
                onStreamEvent: { streamEvent in
                    answerSession.handle(streamEvent)
                },
                onPipelineStage: { pipelineStageName in
                    turnRecord?.markTiming(pipelineStageName)
                },
                onProcessReady: { processOrigin in
                    guard let turnRecord else { return }
                    turnRecord.markTiming("cliSpawned", at: processOrigin.spawnDate)
                    turnRecord.cli = TurnRecord.CLIProcessEntry(
                        prespawned: processOrigin.usedStandbyProcess,
                        standby: processOrigin.standbyOutcome?.rawValue,
                        retriedAfterBrokenPipe: processOrigin.retriedAfterBrokenPipe
                    )
                    print("⏱️ CLI \(processOrigin.usedStandbyProcess ? "pre-spawned" : "spawned at key-up") (standby \(processOrigin.standbyOutcome?.rawValue ?? "off"))")
                }
            )
            turnRecord?.markTiming("result")
            noteResolvedModelIdentifier(mainBrainTurn.resolvedModelIdentifier)
            return mainBrainTurn.usageSummary
        } catch ClaudeCodeBridgeError.claudeCodeStalled {
            answerSession.streamFailed(.stalled)
            agentsCenter.log(answerSession.brainAgentID, "stream stalled")
        } catch ClaudeCodeBridgeError.claudeCodeExitedWithoutResult {
            if Task.isCancelled { throw CancellationError() }
            answerSession.streamEndedWithoutResult()
            agentsCenter.log(answerSession.brainAgentID, "Claude Code exited without a result")
        } catch ClaudeCodeBridgeError.claudeCodeReportedError(let message) {
            // Already spoken: the result event went through the session.
            agentsCenter.log(answerSession.brainAgentID, "Claude Code error: \(message)")
            refreshClaudeCodeSignInStatus()
        }
        return nil
    }

    /// A stream's tokens and cost, into turn.json and the brain's record.
    private func recordBrainUsage(_ usage: AgentUsage?, brainAgentID: String, turnRecord: TurnRecord?) {
        guard let usage else { return }
        turnRecord?.addUsage(usage)
        agentsCenter.addUsage(brainAgentID, usage)
        agentsCenter.log(brainAgentID, "usage: \(usage.tokenSummary)\(usage.costText.map { " · \($0)" } ?? "")")
    }

    /// The turn ended: done, cancelled (a new question, Escape, Cancel) or failed.
    private func finishBrainAgent(_ brainAgentID: String, turnError: Error?, wasCancelled: Bool) {
        let status: AgentStatus
        if wasCancelled || turnError is CancellationError {
            status = .cancelled
        } else if turnError != nil {
            status = .failed
        } else {
            status = .done
        }
        agentsCenter.log(brainAgentID, status == .done ? "answered" : status.rawValue)
        agentsCenter.finish(brainAgentID, status: status, errorDescription: status == .failed ? turnError?.localizedDescription : nil)
        if currentBrainAgentID == brainAgentID { currentBrainAgentID = nil }
    }

    /// P6.1: Haiku's second look at tentative marks (v2.grounding.verifyWithHaiku).
    let zoomChecker = HaikuZoomChecker()

    /// The answer being spoken now.
    private(set) var currentAnswerSession: AnswerSession?
    /// The last answer's spoken text ("Copy last answer", "copy that").
    @Published private(set) var lastAnswerText: String?

    /// The numbered steps the last answer marked ("1. Bluetooth — click here…"), for "do it for me".
    var lastMarkedStepsDescription: String? {
        guard let raw = lastRawAnswerWithMarks else { return nil }
        let steps = ClickForMeCommand.markedSteps(inAnswer: raw)
        return steps.isEmpty ? nil : steps.joined(separator: "\n")
    }
    /// The raw text of the newest answer that had [MARK:…] steps.
    var lastRawAnswerWithMarks: String?
    /// The caption bubble's content (all overlays read it).
    @Published private(set) var captionState = CaptionState()
    private var captionHideTask: Task<Void, Never>?
    private static let captionHideDelaySeconds: UInt64 = 4
    private static let silentCaptionHideDelaySeconds: UInt64 = 10

    /// The answer ended but the bubble stays up: it holds the marks' legend.
    private var isCaptionHeldForLegend = false

    func showCaption(_ caption: CaptionState) {
        captionHideTask?.cancel()
        isCaptionHeldForLegend = false
        captionState = caption
        captionState.markLegend = markController.legend
        // The board shows the words in its own subtitle bar.
        if isWhiteboardPanelOpen { captionState.isVisible = false }
        if caption.current != nil && voiceState == .processing {
            voiceState = .responding
        }
    }

    func hideCaption() {
        captionHideTask?.cancel()
        isCaptionHeldForLegend = false
        captionState.isVisible = false
    }

    /// nearCursor marks: their words ride in the bubble while they're on
    /// screen; once they're cleared a bubble held for them goes too.
    private func showMarkLegend(_ legend: [MarkLegendEntry]) {
        guard captionState.markLegend != legend else { return }
        captionState.markLegend = legend
        if legend.isEmpty && isCaptionHeldForLegend {
            isCaptionHeldForLegend = false
            captionState.isVisible = false
        }
    }

    /// Kills the in-flight Claude request (the coordinator's barge-in step).
    func cancelResponseRequest() {
        currentResponseTask?.cancel()
    }

    /// History and the copyable last answer, once an answer ends.
    func recordAnswer(transcript: String, history: String, spokenText: String, wasInterrupted: Bool) {
        conversationHistory.append((userTranscript: transcript, assistantResponse: history))
        if conversationHistory.count > Self.conversationHistoryExchangeLimit {
            conversationHistory.removeFirst(conversationHistory.count - Self.conversationHistoryExchangeLimit)
        }
        if !spokenText.isEmpty { lastAnswerText = spokenText }
        print("🧠 Conversation history: \(conversationHistory.count) exchanges\(wasInterrupted ? " (interrupted)" : "")")
        captionHideTask?.cancel()
        captionHideTask = Task { @MainActor [weak self] in
            // Silent mode: the caption is the whole answer, so it stays up longer.
            let hideDelaySeconds = ClickySettings.isSilentModeEnabled ? Self.silentCaptionHideDelaySeconds : Self.captionHideDelaySeconds
            try? await Task.sleep(nanoseconds: hideDelaySeconds * 1_000_000_000)
            guard !Task.isCancelled, let self else { return }
            // The legend explains marks still on screen: keep it until they go.
            if !self.captionState.markLegend.isEmpty {
                self.isCaptionHeldForLegend = true
                return
            }
            self.captionState.isVisible = false
        }
    }

    /// Debug inbox: the newest history entry, and Esc as if pressed.
    var lastHistoryEntryForDebug: String? { conversationHistory.last?.assistantResponse }
    func handleEscapeKeyPressedForDebug() { handleEscapeKeyPressed() }

    func copyLastAnswerToPasteboard() {
        guard let lastAnswerText, !lastAnswerText.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lastAnswerText, forType: .string)
    }

    /// Flies the companion beside a POINT target, clear of it and of the marks.
    func flyCompanion(to target: ResolvedTarget, frame: CaptureFrame) {
        let markObstacles = markController.marks.map { MarkLayout.padded($0.rectCG) }
        let landing = CompanionLanding.landing(target: target.frameCG, visible: frame.display.visibleCG, obstacles: markObstacles)
        markController.companionRect = landing
        detectedElementScreenLocation = ScreenTopology.appKit(fromCG: landing.center, flipH: ScreenTopology.mainDisplayHeight)
        detectedElementDisplayFrame = frame.display.frameAppKit
        pointTargetCG = target.frameCG
        lastFlightSource = .screen
    }

    /// Where the companion last flew for a POINT: the real screen or the board.
    enum CompanionFlightSource: String {
        case screen, board
    }

    private(set) var lastFlightSource: CompanionFlightSource = .screen

    /// Flies the companion beside a board element (its rect on screen, CG).
    func flyCompanion(toBoardRectCG rectCG: CGRect) {
        let displays = ScreenTopology.current()
        guard let display = displays.first(where: { $0.boundsCG.contains(rectCG.center) }) ?? displays.first else { return }
        let landing = CompanionLanding.landing(target: rectCG, visible: display.visibleCG, obstacles: [])
        markController.companionRect = landing
        detectedElementScreenLocation = ScreenTopology.appKit(fromCG: landing.center, flipH: ScreenTopology.mainDisplayHeight)
        detectedElementDisplayFrame = display.frameAppKit
        pointTargetCG = rectCG
        lastFlightSource = .board
    }

    /// The current POINT target (the caption bubble avoids it).
    @Published private(set) var pointTargetCG: CGRect?
    /// Targets of the segment being spoken that haven't fired yet (the bubble avoids them).
    @Published var upcomingTargetRectsCG: [CGRect] = []
    /// This answer's on-screen text bounds (AX text / cell / row frames and
    /// OCR lines, CG), set by AnswerSession: marks and the caption bubble
    /// keep clear of them.
    @Published var screenTextObstaclesCG: [CGRect] = [] {
        didSet { markController.textObstaclesCG = screenTextObstaclesCG }
    }

    /// Draws a full answer's tags at once, without speaking (the debug
    /// inbox's `marks`). Returns the text that would have been spoken.
    @discardableResult
    func presentGroundedTags(responseText: String, groundedTurn: inout GroundedTurn, turnRecord: TurnRecord?) async -> String {
        guard isGroundingActiveThisSession else {
            // Grounding is off this session: nothing is drawn, only the words remain.
            var router = ResponseRouter()
            return (router.feed(responseText) + router.finish()).compactMap { output -> String? in
                if case .narration(let text) = output { return text.replacingOccurrences(of: String(ResponseRouter.placeholder), with: "") }
                return nil
            }.joined()
        }
        markController.startAnswer(turnRecord: turnRecord)
        let answerSession = AnswerSession(transcript: "debug marks", groundedTurn: groundedTurn, turnRecord: turnRecord,
                                          companionManager: self, speaksResponse: false)
        answerSession.handle(.textDelta(responseText))
        answerSession.handle(.result(text: responseText, isError: false, subtype: "success"))
        await answerSession.waitUntilFinished()
        groundedTurn = answerSession.groundedTurn
        return answerSession.coordinator.spokenText
    }

    /// With the spark hidden by choice it appears for one exchange; once the voice, any pointing
    /// flight and the marks are done, it waits a second and fades. A new question cancels this.
    private func scheduleTransientHideIfNeeded() {
        guard !isClickyCursorEnabled && isOverlayVisible else { return }
        transientHideTask?.cancel()
        transientHideTask = Task {
            @MainActor func stillBusy() -> Bool { speechOutputClient.isPlaying || detectedElementScreenLocation != nil || hasLiveScreenMarks }
            while stillBusy() {
                try? await Task.sleep(nanoseconds: 200_000_000)
                if Task.isCancelled { return }
            }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            if Task.isCancelled { return }
            sparkOverlay.fadeOutAndHideOverlay()
            isOverlayVisible = false
        }
    }

    /// When an answer fails, Theo says why in plain words instead of going quiet.
    private func speakErrorFallback(for error: Error) {
        let brainName = BrainModel(setting: selectedModel).provider.displayName
        let line: String
        switch error {
        case ClaudeCodeBridgeError.claudeCodeNotInstalled:
            line = "I can't find \(brainName) on this Mac. Open my Setup guide to install it and sign in."
        case ClaudeCodeBridgeError.claudeCodeReportedError(let message)
            where message.localizedCaseInsensitiveContains("auth") || message.localizedCaseInsensitiveContains("login"):
            line = "I'm signed out of \(brainName). Sign in again from my Setup guide, then ask me again."
        case ClaudeCodeBridgeError.claudeCodeReportedError(let message) where message.localizedCaseInsensitiveContains("limit"):
            line = "You've hit your usage limit for now. Try again a bit later."
        default:
            line = "Something went wrong reaching my brain. Diagnostics in the menu bar has the details."
        }
        refreshClaudeCodeSignInStatus()
        Task { try? await speechOutputClient.speakText(line) }
        voiceState = .responding
    }

    // MARK: - Helper Workers

    static func makeMainBrainPromptWithWorkerResults(
        transcript: String,
        companionWorkerResults: [CompanionWorkerResult]
    ) -> String {
        let workerResultSections = companionWorkerResults.map { companionWorkerResult in
            "### \(companionWorkerResult.workerTitle)\n\(companionWorkerResult.workerResultText)"
        }.joined(separator: "\n\n")

        return """
        \(transcript)

        (your helper workers finished. their results are below. now give the user your final spoken answer, following all the usual rules. MARK and POINT tags are allowed. do not open any more workers. if a helper failed, answer with what the others found.)

        \(workerResultSections)
        """
    }

    static let companionWorkerSystemPrompt = """
    you're a fast helper working for theo, a voice assistant. theo's main brain gave you one small sub-task. you can see the user's screen in the attached images. do only that sub-task and reply in plain, concise text (under 150 words) with the facts the main brain needs. no greetings, no tags, no markdown headings.
    """

    // MARK: - First-run hint

    /// Types "hold control + option and say hi" next to the spark after the hello, then fades it.
    func startOnboardingPromptStream() {
        let hint = "hold control + option and say hi"
        onboardingPromptText = ""
        showOnboardingPrompt = true
        withAnimation(.easeIn(duration: 0.4)) { onboardingPromptOpacity = 1 }
        for count in 1...hint.count {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(count) * 0.03) {
                guard self.showOnboardingPrompt else { return }
                self.onboardingPromptText = String(hint.prefix(count))
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Double(hint.count) * 0.03 + 10) {
            guard self.showOnboardingPrompt else { return }
            withAnimation(.easeOut(duration: 0.3)) { self.onboardingPromptOpacity = 0 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                self.showOnboardingPrompt = false
                self.onboardingPromptText = ""
            }
        }
    }
}
