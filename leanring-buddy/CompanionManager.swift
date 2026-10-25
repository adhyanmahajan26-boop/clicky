//
//  CompanionManager.swift
//  leanring-buddy
//
//  Central state manager for the companion voice mode. Owns the push-to-talk
//  pipeline (dictation manager + global shortcut monitor + overlay) and
//  exposes observable voice state for the panel UI.
//

import ClickyCore
import AVFoundation
import Combine
import Foundation
import os
import ScreenCaptureKit
import Speech
import SwiftUI

enum CompanionVoiceState {
    case idle
    case listening
    case processing
    case responding
}

@MainActor
final class CompanionManager: ObservableObject {
    @Published private(set) var voiceState: CompanionVoiceState = .idle
    @Published private(set) var lastTranscript: String?
    @Published private(set) var currentAudioPowerLevel: CGFloat = 0
    @Published private(set) var hasAccessibilityPermission = false
    @Published private(set) var hasScreenRecordingPermission = false
    @Published private(set) var hasMicrophonePermission = false
    @Published private(set) var hasScreenContentPermission = false

    /// Screen location (global AppKit coords) of a detected UI element the
    /// buddy should fly to and point at. Parsed from Claude's response;
    /// observed by BlueCursorView to trigger the flight animation.
    @Published var detectedElementScreenLocation: CGPoint?
    /// The display frame (global AppKit coords) of the screen the detected
    /// element is on, so BlueCursorView knows which screen overlay should animate.
    @Published var detectedElementDisplayFrame: CGRect?
    /// Custom speech bubble text for the pointing animation. When set,
    /// BlueCursorView uses this instead of a random pointer phrase.
    @Published var detectedElementBubbleText: String?

    /// Circles, arrows, and numbered steps Claude drew for the current answer
    /// (global AppKit coords). Cleared when the user asks something new, says
    /// "clear", presses Escape, or a little while after the answer finishes.
    @Published private(set) var liveScreenMarks: [LiveScreenMark] = []
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

    // MARK: - Onboarding Prompt Bubble

    /// "press control + option…" hint streamed character-by-character on the
    /// cursor after the first-run welcome text, so a new user knows what to do.
    @Published var onboardingPromptText: String = ""
    @Published var onboardingPromptOpacity: Double = 0.0
    @Published var showOnboardingPrompt: Bool = false

    let buddyDictationManager = BuddyDictationManager()
    let globalPushToTalkShortcutMonitor = GlobalPushToTalkShortcutMonitor()
    let overlayWindowManager = OverlayWindowManager()
    // Response text is now displayed inline on the cursor overlay via
    // streamingResponseText, so no separate response overlay manager is needed.

    /// Claude runs through the local Claude Code CLI on the user's
    /// subscription — no API key or proxy server involved.
    private lazy var claudeCodeBridge: ClaudeCodeBridge = {
        return ClaudeCodeBridge(model: selectedModel)
    }()

    /// Built-in Mac voice for spoken replies (free, offline).
    let speechOutputClient = CompanionSpeechOutput()

    /// Whether the Claude Code CLI is signed in. Checked on launch so the
    /// panel can prompt for `claude auth login` instead of failing silently.
    @Published private(set) var isClaudeCodeSignedIn = false

    func refreshClaudeCodeSignInStatus() {
        Task {
            isClaudeCodeSignedIn = await ClaudeCodeBridge.checkIsSignedIn()
            print("🔑 Claude Code signed in: \(isClaudeCodeSignedIn)")
        }
    }

    /// Conversation history so Claude remembers prior exchanges within a session.
    /// Each entry is the user's transcript and Claude's response.
    private var conversationHistory: [(userTranscript: String, assistantResponse: String)] = []

    /// False when the startup geometry check found AppKit and CG display
    /// frames disagreeing; then nothing is drawn from tags for this session.
    /// Never written to settings.
    private(set) var isGroundingActiveThisSession = ClickySettings.isGroundingEnabled
    /// The model id the CLI last resolved the selected alias to.
    private(set) var lastResolvedModelIdentifier: String?
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

    /// The currently running AI response task, if any. Cancelled when the user
    /// speaks again so a new response can begin immediately.
    private var currentResponseTask: Task<Void, Never>?
    /// When push-to-talk was last released; the turn log's keyUp time.
    private var lastPushToTalkReleaseDate: Date?

    private var shortcutTransitionCancellable: AnyCancellable?
    private var voiceStateCancellable: AnyCancellable?
    private var audioPowerCancellable: AnyCancellable?
    private var accessibilityCheckTimer: Timer?
    private var appDidBecomeActiveObserver: NSObjectProtocol?

    /// Permission changes go to the unified log (not just the Xcode console)
    /// so they can be checked with `log show --predicate 'subsystem == "com.personal.clicky"'`.
    private let permissionLogger = Logger(subsystem: "com.personal.clicky", category: "permissions")
    private var pendingKeyboardShortcutStartTask: Task<Void, Never>?
    /// Scheduled hide for transient cursor mode — cancelled if the user
    /// speaks again before the delay elapses.
    private var transientHideTask: Task<Void, Never>?

    /// True when all three required permissions (accessibility, screen recording,
    /// microphone) are granted. Used by the panel to show a single "all good" state.
    var allPermissionsGranted: Bool {
        hasAccessibilityPermission && hasScreenRecordingPermission && hasMicrophonePermission && hasScreenContentPermission
    }

    /// Whether the blue cursor overlay is currently visible on screen.
    /// Used by the panel to show accurate status text ("Active" vs "Ready").
    @Published private(set) var isOverlayVisible: Bool = false

    /// The Claude model used for voice responses. Persisted to UserDefaults.
    /// Stored as a Claude Code model alias ("sonnet" / "opus") so it always
    /// tracks the newest model in that family.
    @Published var selectedModel: String = UserDefaults.standard.string(forKey: "selectedClaudeCodeModelAlias") ?? "sonnet"

    func setSelectedModel(_ model: String) {
        selectedModel = model
        UserDefaults.standard.set(model, forKey: "selectedClaudeCodeModelAlias")
        claudeCodeBridge.model = model
    }

    /// User preference for whether the Clicky cursor should be shown.
    /// When toggled off, the overlay is hidden and push-to-talk is disabled.
    /// Persisted to UserDefaults so the choice survives app restarts.
    @Published var isClickyCursorEnabled: Bool = UserDefaults.standard.object(forKey: "isClickyCursorEnabled") == nil
        ? true
        : UserDefaults.standard.bool(forKey: "isClickyCursorEnabled")

    func setClickyCursorEnabled(_ enabled: Bool) {
        isClickyCursorEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "isClickyCursorEnabled")
        transientHideTask?.cancel()
        transientHideTask = nil

        if enabled {
            overlayWindowManager.hasShownOverlayBefore = true
            overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
            isOverlayVisible = true
        } else {
            overlayWindowManager.hideOverlay()
            isOverlayVisible = false
        }
    }

    /// Whether the user has completed onboarding at least once. Persisted
    /// to UserDefaults so the Start button only appears on first launch.
    var hasCompletedOnboarding: Bool {
        get { UserDefaults.standard.bool(forKey: "hasCompletedOnboarding") }
        set { UserDefaults.standard.set(newValue, forKey: "hasCompletedOnboarding") }
    }

    /// The upstream app gated onboarding behind an email signup form. This
    /// personal build has no signup, so the gate is always considered passed.
    @Published var hasSubmittedEmail: Bool = true

    /// Kept so the panel's (now hidden) email field still compiles. Nothing
    /// is sent anywhere.
    func submitEmail(_ email: String) {
        hasSubmittedEmail = true
    }

    func start() {
        runStartupGeometryCheck()
        // A model we haven't measured yet: check in the background what image
        // size it really sees (stored per resolved model id).
        onNewResolvedModelIdentifier = { [weak self] resolvedModelIdentifier in
            guard let self else { return }
            DiagnosticSelfTests.probeInBackgroundIfNeeded(resolvedModelIdentifier: resolvedModelIdentifier, model: self.selectedModel)
        }
        speechOutputClient.warmUpIfNeeded()
        addCompanionActivitySource(companionWorkerRunner)
        addCompanionActivitySource(simulatedCompanionActivitySource)
        refreshAllPermissions()
        print("🔑 Clicky start — accessibility: \(hasAccessibilityPermission), screen: \(hasScreenRecordingPermission), mic: \(hasMicrophonePermission), screenContent: \(hasScreenContentPermission), onboarded: \(hasCompletedOnboarding)")
        startPermissionPolling()
        bindVoiceStateObservation()
        bindAudioPowerLevel()
        bindShortcutTransitions()
        bindEscapeKey()
        _ = claudeCodeBridge
        refreshClaudeCodeSignInStatus()

        // If the user already completed onboarding AND all permissions are
        // still granted, show the cursor overlay immediately. If permissions
        // were revoked (e.g. signing change), don't show the cursor — the
        // panel will show the permissions UI instead.
        if hasCompletedOnboarding && allPermissionsGranted && isClickyCursorEnabled {
            overlayWindowManager.hasShownOverlayBefore = true
            overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
            isOverlayVisible = true
        }
    }

    /// Called by BlueCursorView after the buddy finishes its pointing
    /// animation and returns to cursor-following mode.
    /// Triggers the onboarding sequence — dismisses the panel and shows the
    /// overlay for the first time so the welcome text and the
    /// "press control + option" hint play.
    func triggerOnboarding() {
        // Post notification so the panel manager can dismiss the panel
        NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)

        // Mark onboarding as completed so the Start button won't appear
        // again on future launches — the cursor will auto-show instead
        hasCompletedOnboarding = true

        ClickyAnalytics.trackOnboardingStarted()

        // Show the overlay for the first time — isFirstAppearance triggers
        // the welcome animation, then the push-to-talk hint
        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
        isOverlayVisible = true
    }

    func clearDetectedElementLocation() {
        detectedElementScreenLocation = nil
        detectedElementDisplayFrame = nil
        detectedElementBubbleText = nil
    }

    func clearLiveScreenMarks() {
        liveScreenMarksAutoClearTask?.cancel()
        liveScreenMarksAutoClearTask = nil
        liveScreenMarks = []
    }

    /// Keeps the marks up while the buddy is still talking, then for a short
    /// grace period so the user can follow them, then clears them.
    private func scheduleLiveScreenMarksAutoClear() {
        liveScreenMarksAutoClearTask?.cancel()
        guard !liveScreenMarks.isEmpty else { return }

        liveScreenMarksAutoClearTask = Task {
            while speechOutputClient.isPlaying {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }
            }
            try? await Task.sleep(nanoseconds: Self.liveScreenMarksSecondsToKeepAfterSpeech * 1_000_000_000)
            guard !Task.isCancelled else { return }
            liveScreenMarks = []
        }
    }

    func stop() {
        speechOutputClient.shutDown()
        endHandsFreeSession()
        escapeKeyCancellable?.cancel()
        globalPushToTalkShortcutMonitor.stop()
        buddyDictationManager.cancelCurrentDictation()
        overlayWindowManager.hideOverlay()
        transientHideTask?.cancel()

        currentResponseTask?.cancel()
        currentResponseTask = nil
        shortcutTransitionCancellable?.cancel()
        voiceStateCancellable?.cancel()
        audioPowerCancellable?.cancel()
        accessibilityCheckTimer?.invalidate()
        accessibilityCheckTimer = nil
    }

    private var hasLoggedPermissionStateThisLaunch = false

    func refreshAllPermissions() {
        let previouslyHadAccessibility = hasAccessibilityPermission
        let previouslyHadScreenRecording = hasScreenRecordingPermission
        let previouslyHadMicrophone = hasMicrophonePermission
        let previouslyHadAll = allPermissionsGranted

        let currentlyHasAccessibility = WindowPositionManager.hasAccessibilityPermission()
        hasAccessibilityPermission = currentlyHasAccessibility

        if currentlyHasAccessibility {
            globalPushToTalkShortcutMonitor.start()
        } else {
            globalPushToTalkShortcutMonitor.stop()
        }

        hasScreenRecordingPermission = WindowPositionManager.hasScreenRecordingPermission()

        let micAuthStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        hasMicrophonePermission = micAuthStatus == .authorized

        // Log permission state on changes (and on the first check of a launch)
        if !hasLoggedPermissionStateThisLaunch
            || previouslyHadAccessibility != hasAccessibilityPermission
            || previouslyHadScreenRecording != hasScreenRecordingPermission
            || previouslyHadMicrophone != hasMicrophonePermission {
            hasLoggedPermissionStateThisLaunch = true
            let speechRecognitionStatus = SFSpeechRecognizer.authorizationStatus() == .authorized ? "authorized" : "not authorized (\(SFSpeechRecognizer.authorizationStatus().rawValue))"
            let permissionSummary = "accessibility: \(hasAccessibilityPermission), screen: \(hasScreenRecordingPermission), mic: \(hasMicrophonePermission), screenContent: \(hasScreenContentPermission), speech: \(speechRecognitionStatus)"
            print("🔑 Permissions — \(permissionSummary)")
            permissionLogger.notice("Permissions — \(permissionSummary, privacy: .public)")
        }

        // Track individual permission grants as they happen
        if !previouslyHadAccessibility && hasAccessibilityPermission {
            ClickyAnalytics.trackPermissionGranted(permission: "accessibility")
        }
        if !previouslyHadScreenRecording && hasScreenRecordingPermission {
            ClickyAnalytics.trackPermissionGranted(permission: "screen_recording")
        }
        if !previouslyHadMicrophone && hasMicrophonePermission {
            ClickyAnalytics.trackPermissionGranted(permission: "microphone")
        }
        // Screen content permission is persisted — once the user has approved the
        // SCShareableContent picker, we don't need to re-check it.
        if !hasScreenContentPermission {
            hasScreenContentPermission = UserDefaults.standard.bool(forKey: "hasScreenContentPermission")
        }

        if !previouslyHadAll && allPermissionsGranted {
            ClickyAnalytics.trackAllPermissionsGranted()
        }
    }

    /// Triggers the macOS screen content picker by performing a dummy
    /// screenshot capture. Once the user approves, we persist the grant
    /// so they're never asked again during onboarding.
    @Published private(set) var isRequestingScreenContent = false

    func requestScreenContentPermission() {
        guard !isRequestingScreenContent else { return }
        isRequestingScreenContent = true
        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let display = content.displays.first else {
                    await MainActor.run { isRequestingScreenContent = false }
                    return
                }
                let filter = SCContentFilter(display: display, excludingWindows: [])
                let config = SCStreamConfiguration()
                config.width = 320
                config.height = 240
                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                // Verify the capture actually returned real content — a 0x0 or
                // fully-empty image means the user denied the prompt.
                let didCapture = image.width > 0 && image.height > 0
                print("🔑 Screen content capture result — width: \(image.width), height: \(image.height), didCapture: \(didCapture)")
                await MainActor.run {
                    isRequestingScreenContent = false
                    guard didCapture else { return }
                    hasScreenContentPermission = true
                    UserDefaults.standard.set(true, forKey: "hasScreenContentPermission")
                    ClickyAnalytics.trackPermissionGranted(permission: "screen_content")

                    // If onboarding was already completed, show the cursor overlay now
                    if hasCompletedOnboarding && allPermissionsGranted && !isOverlayVisible && isClickyCursorEnabled {
                        overlayWindowManager.hasShownOverlayBefore = true
                        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
                        isOverlayVisible = true
                    }
                }
            } catch {
                print("⚠️ Screen content permission request failed: \(error)")
                await MainActor.run { isRequestingScreenContent = false }
            }
        }
    }

    // MARK: - Private

    /// Triggers the system microphone prompt if the user has never been asked.
    /// Once granted/denied the status sticks and polling picks it up.
    private func promptForMicrophoneIfNotDetermined() {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined else { return }
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            Task { @MainActor [weak self] in
                self?.hasMicrophonePermission = granted
            }
        }
    }

    /// Polls all permissions frequently so the UI updates live after the
    /// user grants them in System Settings. Screen Recording is the exception —
    /// macOS requires an app restart for that one to take effect.
    private func startPermissionPolling() {
        accessibilityCheckTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshAllPermissions()
            }
        }

        // Coming back from System Settings activates Clicky (e.g. clicking its
        // menu bar icon), so re-check right away instead of waiting for the timer.
        appDidBecomeActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshAllPermissions()
            }
        }
    }

    private func bindAudioPowerLevel() {
        audioPowerCancellable = buddyDictationManager.$currentAudioPowerLevel
            .receive(on: DispatchQueue.main)
            .sink { [weak self] powerLevel in
                self?.currentAudioPowerLevel = powerLevel
            }
    }

    private func bindVoiceStateObservation() {
        voiceStateCancellable = buddyDictationManager.$isRecordingFromKeyboardShortcut
            .combineLatest(
                buddyDictationManager.$isFinalizingTranscript,
                buddyDictationManager.$isPreparingToRecord
            )
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isRecording, isFinalizing, isPreparing in
                guard let self else { return }
                // Don't override .responding — the AI response pipeline
                // manages that state directly until streaming finishes.
                guard self.voiceState != .responding else { return }

                if isFinalizing {
                    self.voiceState = .processing
                } else if isRecording {
                    self.voiceState = .listening
                } else if isPreparing {
                    self.voiceState = .processing
                } else {
                    self.voiceState = .idle
                    // If the user pressed and released the hotkey without
                    // saying anything, no response task runs — schedule the
                    // transient hide here so the overlay doesn't get stuck.
                    // Only do this when no response is in flight, otherwise
                    // the brief idle gap between recording and processing
                    // would prematurely hide the overlay.
                    if self.currentResponseTask == nil {
                        self.scheduleTransientHideIfNeeded()
                    }
                }
            }
    }

    private func bindShortcutTransitions() {
        shortcutTransitionCancellable = globalPushToTalkShortcutMonitor
            .shortcutTransitionPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] transition in
                self?.handleShortcutTransition(transition)
            }
    }

    private func handleShortcutTransition(_ transition: BuddyPushToTalkShortcut.ShortcutTransition) {
        switch transition {
        case .pressed:
            lastShortcutPressDate = Date()
            // During a hands-free session the mic is already open, so holding
            // the shortcut does nothing — a double-tap ends the session instead.
            guard !isHandsFreeSessionActive else { return }
            guard !buddyDictationManager.isDictationInProgress else { return }

            // Cancel any pending transient hide so the overlay stays visible
            transientHideTask?.cancel()
            transientHideTask = nil

            // If the cursor is hidden, bring it back transiently for this interaction
            if !isClickyCursorEnabled && !isOverlayVisible {
                overlayWindowManager.hasShownOverlayBefore = true
                overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
                isOverlayVisible = true
            }

            // Dismiss the menu bar panel so it doesn't cover the screen
            NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)

            // Cancel any in-progress response and TTS from a previous utterance
            currentResponseTask?.cancel()
            speechOutputClient.stopPlayback()
            clearDetectedElementLocation()

            // Dismiss the onboarding prompt if it's showing
            if showOnboardingPrompt {
                withAnimation(.easeOut(duration: 0.3)) {
                    onboardingPromptOpacity = 0.0
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    self.showOnboardingPrompt = false
                    self.onboardingPromptText = ""
                }
            }
    

            ClickyAnalytics.trackPushToTalkStarted()

            pendingKeyboardShortcutStartTask?.cancel()
            pendingKeyboardShortcutStartTask = Task {
                await buddyDictationManager.startPushToTalkFromKeyboardShortcut(
                    currentDraftText: "",
                    updateDraftText: { _ in
                        // Partial transcripts are hidden (waveform-only UI)
                    },
                    submitDraftText: { [weak self] finalTranscript in
                        self?.lastTranscript = finalTranscript
                        print("🗣️ Companion received transcript: \(finalTranscript)")
                        ClickyAnalytics.trackUserMessageSent(transcript: finalTranscript)
                        // Latency is measured from the moment the keys were released.
                        let keyUpDate = self?.lastPushToTalkReleaseDate ?? Date()
                        self?.sendTranscriptToClaudeWithScreenshot(
                            transcript: finalTranscript,
                            turnOptions: TurnOptions(keyUpDate: keyUpDate)
                        )
                    }
                )
            }
        case .released:
            let wasShortcutDoubleTapped = registerShortcutReleaseAndDetectDoubleTap()

            if isHandsFreeSessionActive {
                if wasShortcutDoubleTapped {
                    endHandsFreeSession()
                }
                return
            }

            // Cancel the pending start task in case the user released the shortcut
            // before the async startPushToTalk had a chance to begin recording.
            // Without this, a quick press-and-release drops the release event and
            // leaves the waveform overlay stuck on screen indefinitely.
            ClickyAnalytics.trackPushToTalkReleased()
            lastPushToTalkReleaseDate = Date()
            pendingKeyboardShortcutStartTask?.cancel()
            pendingKeyboardShortcutStartTask = nil
            buddyDictationManager.stopPushToTalkFromKeyboardShortcut()

            if wasShortcutDoubleTapped {
                // The two quick taps each started a (silent) push-to-talk
                // recording — throw those away before opening the session mic.
                buddyDictationManager.cancelCurrentDictation(preserveDraftText: false)
                startHandsFreeSession()
            }
        case .none:
            break
        }
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
    /// "slower" / "faster". 1.0 is the default speed.
    @Published private(set) var autopilotScrollSpeedMultiplier: Double = 1.0

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
            overlayWindowManager.hasShownOverlayBefore = true
            overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
            isOverlayVisible = true
        }

        let handsFreeListeningSession = HandsFreeListeningSession(
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

        handsFreeListeningSession?.stopListening()
        handsFreeListeningSession = nil
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

        if speechOutputClient.isPlaying {
            currentUtteranceOverlappedBuddySpeech = true
        }

        // "wait" / "stop" should cut the buddy off mid-sentence, so check
        // partial transcripts for them instead of waiting for the pause.
        // Only when there's something to interrupt — otherwise a sentence
        // that merely starts with "stop…" would get chopped in half.
        let isBuddyBusy = speechOutputClient.isPlaying || voiceState == .processing
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

        if let voiceCommand = HandsFreeVoiceCommand.parse(finishedUtterance) {
            performHandsFreeVoiceCommand(voiceCommand)
            return
        }

        guard !utteranceOverlappedBuddySpeech else {
            print("🔇 Hands-free: ignored speech heard while the buddy was talking: \(finishedUtterance)")
            return
        }

        lastTranscript = finishedUtterance
        ClickyAnalytics.trackUserMessageSent(transcript: finishedUtterance)
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
            autopilotScrollSpeedMultiplier = max(0.25, autopilotScrollSpeedMultiplier * 0.75)
            showHandsFreeStatusMessage(String(format: "Scroll speed %.2g×", autopilotScrollSpeedMultiplier))

        case .faster:
            autopilotScrollSpeedMultiplier = min(3.0, autopilotScrollSpeedMultiplier * 1.33)
            showHandsFreeStatusMessage(String(format: "Scroll speed %.2g×", autopilotScrollSpeedMultiplier))

        case .clearMarks:
            clearLiveScreenMarks()
            showHandsFreeStatusMessage("Cleared marks")

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

    private func showHandsFreeStatusMessage(_ statusMessage: String) {
        handsFreeStatusMessage = statusMessage
        handsFreeStatusMessageClearTask?.cancel()
        handsFreeStatusMessageClearTask = Task {
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard !Task.isCancelled else { return }
            handsFreeStatusMessage = nil
        }
    }

    /// Cuts off the buddy mid-sentence and abandons any answer in flight.
    func stopBuddySpeechAndCancelResponse() {
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
        escapeKeyCancellable = globalPushToTalkShortcutMonitor
            .escapeKeyPressedPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                self?.handleEscapeKeyPressed()
            }
    }

    /// Escape is the universal "stop everything": it silences the buddy,
    /// cancels any answer in flight, and ends a hands-free session.
    private func handleEscapeKeyPressed() {
        let isBuddyBusy = speechOutputClient.isPlaying || voiceState == .processing
        let hasLiveScreenMarksShowing = !liveScreenMarks.isEmpty
        guard isHandsFreeSessionActive || isBuddyBusy || hasLiveScreenMarksShowing else { return }

        stopBuddySpeechAndCancelResponse()
        endHandsFreeSession()
    }

    // MARK: - Companion Prompt

    /// The main brain's system prompt. Pointing and live marks are only
    /// requested while grounding is trusted this session.
    private var companionSystemPrompt: String {
        var promptFeatures = SystemPromptFeatures.current
        if !isGroundingActiveThisSession {
            promptFeatures.remove([.pointing, .liveMarks])
        }
        return SystemPromptBuilder.mainSystemPrompt(features: promptFeatures)
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

    /// Each screen as its SCREEN header followed by its image.
    private static func screenContentBlocks(for screenCaptures: [ScreenCapture]) -> [ClaudeContentBlock] {
        screenCaptures.flatMap { screenCapture in
            [ClaudeContentBlock.text(screenCapture.header), .jpegImage(screenCapture.modelJPEGData)]
        }
    }


    // MARK: - AI Response Pipeline

    /// Captures a screenshot, sends it along with the transcript to Claude,
    /// and plays the response aloud with the built-in Mac voice. The cursor stays in
    /// the spinner/processing state until TTS audio begins playing.
    /// Claude's response may include a [POINT:x,y:label] tag which triggers
    /// the buddy to fly to that element on screen.
    /// Optional extras for one turn, used by the debug inbox's `ask`.
    struct TurnOptions {
        /// false = no TTS; tags still fire right away.
        var speaksResponse = true
        /// When the user finished asking (key up / transcript arrival).
        var keyUpDate = Date()
        /// Called once the turn has fully finished (or failed/cancelled) with
        /// the turn's log directory.
        var onTurnFinished: ((URL?, Error?) -> Void)?
    }

    func sendTranscriptToClaudeWithScreenshot(transcript: String, turnOptions requestedTurnOptions: TurnOptions? = nil) {
        // Built here rather than as a default argument, which Swift would
        // evaluate off the main actor.
        let turnOptions = requestedTurnOptions ?? TurnOptions()
        currentResponseTask?.cancel()
        speechOutputClient.stopPlayback()
        // Marks from the previous answer would be confusing next to a new one.
        clearLiveScreenMarks()

        let turnRecord = TurnLogger.beginTurn(transcript: transcript, keyUpDate: turnOptions.keyUpDate)

        currentResponseTask = Task {
            // Stay in processing (spinner) state — no streaming text displayed
            voiceState = .processing
            var turnError: Error?

            do {
                // Capture every display at native resolution, sized to exactly
                // what the model will see (SCREEN 1 = cursor screen).
                let screenCaptures = try await ScreenCaptureService.captureAllScreens(options: ScreenCaptureService.Options(
                    effectiveMaxEdge: ClickySettings.effectiveMaxEdge(forModelIdentifier: lastResolvedModelIdentifier)
                ))
                turnRecord?.markTiming("captureDone")
                turnRecord?.recordScreens(screenCaptures)

                guard !Task.isCancelled else { throw CancellationError() }

                let screenBlocks = Self.screenContentBlocks(for: screenCaptures)
                let conversationText = makeConversationText(transcript: transcript)

                let mainBrainTurn = try await claudeCodeBridge.runTurn(
                    systemPromptFileName: "system-prompt.md",
                    systemPrompt: companionSystemPrompt,
                    contentBlocks: [.text(conversationText)] + screenBlocks,
                    onTextChunk: { _ in
                        // No streaming text display — spinner stays until TTS plays
                        turnRecord?.markTiming("firstDelta")
                    },
                    onPipelineStage: { pipelineStageName in
                        turnRecord?.markTiming(pipelineStageName)
                    }
                )
                turnRecord?.markTiming("result")
                let fullResponseText = mainBrainTurn.text
                noteResolvedModelIdentifier(mainBrainTurn.resolvedModelIdentifier)

                guard !Task.isCancelled else { throw CancellationError() }

                // If the main brain split the question into helper workers, run
                // them (on Haiku, at most four at once) and ask the main brain
                // again with their results for the final answer.
                let (responseTextWithoutWorkerTags, companionWorkerRequests) = CompanionWorkerTagParser.extractWorkerTags(from: fullResponseText)
                var mainBrainResponseText = responseTextWithoutWorkerTags
                if !companionWorkerRequests.isEmpty {
                    mainBrainResponseText = try await runCompanionWorkersAndAskMainBrainForFinalAnswer(
                        companionWorkerRequests: companionWorkerRequests,
                        workerHeadsUpText: responseTextWithoutWorkerTags,
                        conversationText: conversationText,
                        screenBlocks: screenBlocks
                    )
                }
                turnRecord?.rawResponse = companionWorkerRequests.isEmpty
                    ? fullResponseText
                    : fullResponseText + "\n\n--- final answer after workers ---\n" + mainBrainResponseText

                guard !Task.isCancelled else { throw CancellationError() }

                let spokenText = presentLegacyTags(
                    responseText: mainBrainResponseText,
                    screenCaptures: screenCaptures,
                    turnRecord: turnRecord
                )

                // Save this exchange in words only: what it pointed at survives
                // as "(pointed at Share)", never coordinates.
                conversationHistory.append((
                    userTranscript: transcript,
                    assistantResponse: HistoryTagRewriter.wordsForHistory(mainBrainResponseText)
                ))

                // Keep only what's sent, so memory doesn't grow without bound.
                if conversationHistory.count > Self.conversationHistoryExchangeLimit {
                    conversationHistory.removeFirst(conversationHistory.count - Self.conversationHistoryExchangeLimit)
                }

                print("🧠 Conversation history: \(conversationHistory.count) exchanges")

                ClickyAnalytics.trackAIResponseReceived(response: spokenText)

                // Play the response via TTS. Keep the spinner (processing state)
                // until the audio actually starts playing, then switch to responding.
                if turnOptions.speaksResponse && !spokenText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    do {
                        try await speechOutputClient.speakText(spokenText)
                        // speakText returns after player.play() — audio is now playing
                        turnRecord?.markTiming("firstAudio")
                        turnRecord?.speech = TurnRecord.SpeechEntry(
                            engine: speechOutputClient.lastSpeechEngineName,
                            fallback: speechOutputClient.didLastSpeechFallBack
                        )
                        voiceState = .responding
                    } catch {
                        ClickyAnalytics.trackTTSError(error: error.localizedDescription)
                        print("⚠️ System voice TTS error: \(error)")
                        speakErrorFallback(for: error)
                    }
                }
            } catch is CancellationError {
                // User spoke again — response was interrupted
                turnError = CancellationError()
            } catch {
                ClickyAnalytics.trackResponseError(error: error.localizedDescription)
                print("⚠️ Companion response error: \(error)")
                turnError = error
                speakErrorFallback(for: error)
            }

            if let turnRecord {
                turnRecord.errorDescription = turnError.map { String(describing: $0) }
                TurnLogger.finishTurn(turnRecord)
            }
            turnOptions.onTurnFinished?(turnRecord?.turnDirectoryURL, turnError)

            if !Task.isCancelled {
                voiceState = .idle
                scheduleLiveScreenMarksAutoClear()
                scheduleTransientHideIfNeeded()
            }
        }
    }

    /// Handles the tags at the end of an answer: draws its [MARK:...] live
    /// marks and flies the buddy to its [POINT:...] target, logging each tag
    /// to the turn record. Returns the text to speak (tags removed). Shared by
    /// normal answers and the debug inbox's `marks` command.
    @discardableResult
    func presentLegacyTags(
        responseText: String,
        screenCaptures: [ScreenCapture],
        turnRecord: TurnRecord?
    ) -> String {
        // Pull out the [MARK:...] tags first. They sit before the
        // [POINT:...] tag, which must be last for its parser to find it.
        let (responseTextWithoutMarkTags, parsedLiveScreenMarkTags) = LiveScreenMarkTagParser.extractLiveScreenMarkTags(from: responseText)

        // Parse the [POINT:...] tag from Claude's response
        let parseResult = Self.parsePointingCoordinates(from: responseTextWithoutMarkTags)

        // With grounding off this session (geometry self-check failed), tags
        // are stripped from speech but never drawn.
        guard isGroundingActiveThisSession else {
            return parseResult.spokenText
        }

        // Handle element pointing if Claude returned coordinates.
        // Switch to idle BEFORE setting the location so the triangle
        // becomes visible and can fly to the target. Without this, the
        // spinner hides the triangle and the flight animation is invisible.
        if parseResult.coordinate != nil {
            voiceState = .idle
        }

        // Pick the screen capture matching Claude's screen number,
        // falling back to the cursor screen if not specified.
        let pointScreenIndex: Int? = {
            if let screenNumber = parseResult.screenNumber,
               screenNumber >= 1 && screenNumber <= screenCaptures.count {
                return screenNumber - 1
            }
            return screenCaptures.firstIndex(where: { $0.isCursorScreen })
        }()

        // The POINT is logged after the MARKs so the turn log lists tags in
        // the order Claude wrote them (MARKs come before the final POINT).
        var pointTagForTurnLog: (screenNumber: Int, modelPixel: CGPoint, cgPoint: CGPoint)?

        if let pointCoordinate = parseResult.coordinate, let pointScreenIndex {
            let targetScreenCapture = screenCaptures[pointScreenIndex]
            // Claude's coordinates are pixels of the image named in that
            // SCREEN header; one CaptureFrame maps them to CG, and the
            // AppKit flip happens only for the legacy flight animation.
            let pointCG = targetScreenCapture.frame.cg(fromModelPx: pointCoordinate)
            let globalLocation = ScreenTopology.appKit(fromCG: pointCG, flipH: ScreenTopology.mainDisplayHeight)

            detectedElementScreenLocation = globalLocation
            detectedElementDisplayFrame = targetScreenCapture.frame.display.frameAppKit
            pointTagForTurnLog = (pointScreenIndex + 1, pointCoordinate, pointCG)
            ClickyAnalytics.trackElementPointed(elementLabel: parseResult.elementLabel)
            print("🎯 Element pointing: (\(Int(pointCoordinate.x)), \(Int(pointCoordinate.y))) → \"\(parseResult.elementLabel ?? "element")\"")
        } else {
            print("🎯 Element pointing: \(parseResult.elementLabel ?? "no element")")
        }

        liveScreenMarks = Self.makeLiveScreenMarks(
            from: parsedLiveScreenMarkTags,
            screenCaptures: screenCaptures,
            turnRecord: turnRecord
        )
        if !liveScreenMarks.isEmpty {
            print("✏️ Live marks: \(liveScreenMarks.map { "\($0.markKind) \($0.markLabel ?? "")" })")
        }
        if let pointTagForTurnLog {
            turnRecord?.recordTag(
                raw: Self.rawPointTag(in: responseTextWithoutMarkTags) ?? "[POINT]",
                screenNumber: pointTagForTurnLog.screenNumber,
                modelPixel: pointTagForTurnLog.modelPixel,
                cgPoint: pointTagForTurnLog.cgPoint
            )
        }

        return parseResult.spokenText
    }

    /// The literal [POINT:...] tag at the end of the text, for the turn log.
    private static func rawPointTag(in responseText: String) -> String? {
        guard let pointTagRange = responseText.range(of: #"\[POINT:[^\]]*\]\s*$"#, options: .regularExpression) else { return nil }
        return responseText[pointTagRange].trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// If the cursor is in transient mode (user toggled "Show Clicky" off),
    /// waits for TTS playback and any pointing animation to finish, then
    /// fades out the overlay after a 1-second pause. Cancelled automatically
    /// if the user starts another push-to-talk interaction.
    private func scheduleTransientHideIfNeeded() {
        guard !isClickyCursorEnabled && isOverlayVisible else { return }

        transientHideTask?.cancel()
        transientHideTask = Task {
            // Wait for TTS audio to finish playing
            while speechOutputClient.isPlaying {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }
            }

            // Wait for pointing animation to finish (location is cleared
            // when the buddy flies back to the cursor)
            while detectedElementScreenLocation != nil {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }
            }

            // Keep the overlay up while live marks are showing, otherwise
            // they'd vanish the moment the buddy stops talking.
            while !liveScreenMarks.isEmpty {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }
            }

            // Pause 1s after everything finishes, then fade out
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            overlayWindowManager.fadeOutAndHideOverlay()
            isOverlayVisible = false
        }
    }

    /// Speaks a short explanation when a response fails, so the user hears
    /// what to fix instead of the buddy going quiet. The most common cause is
    /// Claude Code being signed out or out of subscription usage.
    private func speakErrorFallback(for error: Error) {
        let utterance: String
        switch error {
        case ClaudeCodeBridgeError.claudeCodeNotInstalled:
            utterance = "I can't find Claude Code on this Mac. Install it, then sign in."
        case ClaudeCodeBridgeError.claudeCodeReportedError(let message)
            where message.localizedCaseInsensitiveContains("auth") || message.localizedCaseInsensitiveContains("login"):
            utterance = "I'm signed out of Claude. Run claude auth login in Terminal, then try again."
        case ClaudeCodeBridgeError.claudeCodeReportedError(let message)
            where message.localizedCaseInsensitiveContains("limit"):
            utterance = "You've hit your Claude usage limit for now. Try again a bit later."
        default:
            utterance = "Something went wrong talking to Claude. Check the Xcode console for details."
        }
        refreshClaudeCodeSignInStatus()
        // Same voice as normal answers. (This used a throwaway
        // NSSpeechSynthesizer before, which was freed mid-sentence and cut off.)
        Task {
            try? await speechOutputClient.speakText(utterance)
        }
        voiceState = .responding
    }

    // MARK: - Helper Workers

    /// Speaks the main brain's short heads-up, runs every worker in parallel
    /// (the runner caps it at four and queues the rest), then asks the main
    /// brain for the final answer with the workers' results folded in.
    /// Cancelling the response task (Escape, "stop", a new question) cancels
    /// the workers too, because they run as child tasks of it.
    private func runCompanionWorkersAndAskMainBrainForFinalAnswer(
        companionWorkerRequests: [CompanionWorkerRequest],
        workerHeadsUpText: String,
        conversationText: String,
        screenBlocks: [ClaudeContentBlock]
    ) async throws -> String {
        print("🧠 Main brain opened \(companionWorkerRequests.count) worker(s): \(companionWorkerRequests.map(\.workerTitle))")

        // The heads-up shouldn't carry marks or a point, but strip them in
        // case it does so they're never read aloud.
        let spokenWorkerHeadsUpText = Self.parsePointingCoordinates(
            from: LiveScreenMarkTagParser.extractLiveScreenMarkTags(from: workerHeadsUpText).textWithoutMarkTags
        ).spokenText
        if !spokenWorkerHeadsUpText.isEmpty {
            try? await speechOutputClient.speakText(spokenWorkerHeadsUpText)
        }

        let companionWorkerResults = try await companionWorkerRunner.runWorkers(companionWorkerRequests) { companionWorkerRequest in
            // Workers see the same screens (same frames and JPEGs).
            let workerClaudeCodeBridge = CompanionWorkerRunner.makeWorkerClaudeCodeBridge()
            let workerTurn = try await workerClaudeCodeBridge.runTurn(
                systemPromptFileName: "worker-prompt.md",
                systemPrompt: Self.companionWorkerSystemPrompt,
                contentBlocks: [.text(companionWorkerRequest.workerTaskPrompt)] + screenBlocks
            )
            return workerTurn.text
        }

        try Task.checkCancellation()

        let finalTurn = try await claudeCodeBridge.runTurn(
            systemPromptFileName: "system-prompt.md",
            systemPrompt: companionSystemPrompt,
            contentBlocks: [.text(Self.makeMainBrainPromptWithWorkerResults(
                transcript: conversationText,
                companionWorkerResults: companionWorkerResults
            ))] + screenBlocks
        )
        let finalResponseText = finalTurn.text

        // One round of workers per question: any new worker tags are dropped.
        return CompanionWorkerTagParser.extractWorkerTags(from: finalResponseText).textWithoutWorkerTags
    }

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

    private static let companionWorkerSystemPrompt = """
    you're a fast helper working for clicky, a voice assistant. clicky's main brain gave you one small sub-task. you can see the user's screen in the attached images. do only that sub-task and reply in plain, concise text (under 150 words) with the facts the main brain needs. no greetings, no tags, no markdown headings.
    """

    // MARK: - Live Screen Marks

    /// Turns Claude's [MARK:...] tags into drawable marks, mapping each from
    /// its screenshot's pixel space onto the matching display. Marks that name
    /// a screen that doesn't exist fall back to the cursor's screen.
    private static func makeLiveScreenMarks(
        from parsedLiveScreenMarkTags: [ParsedLiveScreenMarkTag],
        screenCaptures: [ScreenCapture],
        turnRecord: TurnRecord? = nil
    ) -> [LiveScreenMark] {
        var liveScreenMarks: [LiveScreenMark] = []

        for parsedLiveScreenMarkTag in parsedLiveScreenMarkTags {
            // SCREEN n from the tag, falling back to the cursor screen.
            let targetScreenIndex: Int? = {
                if let screenNumber = parsedLiveScreenMarkTag.screenNumber,
                   screenNumber >= 1 && screenNumber <= screenCaptures.count {
                    return screenNumber - 1
                }
                return screenCaptures.firstIndex(where: \.isCursorScreen)
            }()
            guard let targetScreenIndex else { continue }

            let markCG = screenCaptures[targetScreenIndex].frame.cg(fromModelPx: parsedLiveScreenMarkTag.screenshotPixelCoordinate)
            turnRecord?.recordTag(
                raw: "[MARK:\(parsedLiveScreenMarkTag.markKind):\(parsedLiveScreenMarkTag.markLabel ?? "")]",
                screenNumber: targetScreenIndex + 1,
                modelPixel: parsedLiveScreenMarkTag.screenshotPixelCoordinate,
                cgPoint: markCG
            )

            liveScreenMarks.append(LiveScreenMark(
                markKind: parsedLiveScreenMarkTag.markKind,
                locationCG: markCG,
                markLabel: parsedLiveScreenMarkTag.markLabel,
                orderInResponse: liveScreenMarks.count
            ))
        }

        return liveScreenMarks
    }

    // MARK: - Point Tag Parsing

    /// Result of parsing a [POINT:...] tag from Claude's response.
    struct PointingParseResult {
        /// The response text with the [POINT:...] tag removed — this is what gets spoken.
        let spokenText: String
        /// The parsed pixel coordinate, or nil if Claude said "none" or no tag was found.
        let coordinate: CGPoint?
        /// Short label describing the element (e.g. "run button"), or "none".
        let elementLabel: String?
        /// Which screen the coordinate refers to (1-based), or nil to default to cursor screen.
        let screenNumber: Int?
    }

    /// Parses a [POINT:x,y:label:screenN] or [POINT:none] tag from the end of Claude's response.
    /// Returns the spoken text (tag removed) and the optional coordinate + label + screen number.
    static func parsePointingCoordinates(from responseText: String) -> PointingParseResult {
        // Match [POINT:none] or [POINT:123,456:label] or [POINT:123,456:label:screen2]
        let pattern = #"\[POINT:(?:none|(\d+)\s*,\s*(\d+)(?::([^\]:\s][^\]:]*?))?(?::screen(\d+))?)\]\s*$"#

        guard let regex = try? NSRegularExpression(pattern: pattern, options: []),
              let match = regex.firstMatch(in: responseText, range: NSRange(responseText.startIndex..., in: responseText)) else {
            // No tag found at all
            return PointingParseResult(spokenText: responseText, coordinate: nil, elementLabel: nil, screenNumber: nil)
        }

        // Remove the tag from the spoken text
        let tagRange = Range(match.range, in: responseText)!
        let spokenText = String(responseText[..<tagRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)

        // Check if it's [POINT:none]
        guard match.numberOfRanges >= 3,
              let xRange = Range(match.range(at: 1), in: responseText),
              let yRange = Range(match.range(at: 2), in: responseText),
              let x = Double(responseText[xRange]),
              let y = Double(responseText[yRange]) else {
            return PointingParseResult(spokenText: spokenText, coordinate: nil, elementLabel: "none", screenNumber: nil)
        }

        var elementLabel: String? = nil
        if match.numberOfRanges >= 4, let labelRange = Range(match.range(at: 3), in: responseText) {
            elementLabel = String(responseText[labelRange]).trimmingCharacters(in: .whitespaces)
        }

        var screenNumber: Int? = nil
        if match.numberOfRanges >= 5, let screenRange = Range(match.range(at: 4), in: responseText) {
            screenNumber = Int(responseText[screenRange])
        }

        return PointingParseResult(
            spokenText: spokenText,
            coordinate: CGPoint(x: x, y: y),
            elementLabel: elementLabel,
            screenNumber: screenNumber
        )
    }

    // MARK: - Onboarding Prompt

    func startOnboardingPromptStream() {
        let message = "press control + option and introduce yourself"
        onboardingPromptText = ""
        showOnboardingPrompt = true
        onboardingPromptOpacity = 0.0

        withAnimation(.easeIn(duration: 0.4)) {
            onboardingPromptOpacity = 1.0
        }

        var currentIndex = 0
        Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { timer in
            guard currentIndex < message.count else {
                timer.invalidate()
                // Auto-dismiss after 10 seconds
                DispatchQueue.main.asyncAfter(deadline: .now() + 10.0) {
                    guard self.showOnboardingPrompt else { return }
                    withAnimation(.easeOut(duration: 0.3)) {
                        self.onboardingPromptOpacity = 0.0
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        self.showOnboardingPrompt = false
                        self.onboardingPromptText = ""
                    }
                }
                return
            }
            let index = message.index(message.startIndex, offsetBy: currentIndex)
            self.onboardingPromptText.append(message[index])
            currentIndex += 1
        }
    }
}
