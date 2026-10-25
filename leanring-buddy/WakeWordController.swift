//
//  WakeWordController.swift
//  leanring-buddy
//
//  P7: "Hey Claudia" / "Hey Clicky" on-device wake word.
//
//  - Mic: its own small AVAudioEngine with one input tap (no voice
//    processing, 4096-frame buffers). It yields whenever push-to-talk or
//    hands-free claims the mic on the AudioEngineHub (or the hub's AEC
//    engine is live) and starts again after the last claim is released.
//  - Recognition: ClickyCore's WakeWordRecognitionPipeline, always
//    on-device (no on-device support for the locale → off, never a server
//    fallback). An energy gate keeps the recognizer idle in silence, and no
//    audio reaches it while Clicky talks.
//  - A match fires through WakeWordGate (2 s debounce, not while Clicky
//    talks or within 1.5 s after, not if Clicky just said the name). Then
//    the turn is heard on the same request until the hands-free
//    end-of-speech rule ends it, and CompanionManager sends it down the
//    normal turn path.
//  - Auto-pause: another app capturing from the mic (polled every 2 s),
//    screen locked, display or system asleep.
//  - Privacy: nothing leaves the Mac until the wake word fires; no audio or
//    transcript is written anywhere. Logs carry counts and latencies only.
//  - P8: the wake engine listens on the mic push-to-talk last used (unless
//    that's a Bluetooth headset); the recognizer error codes, near misses
//    ("hey <second word>" counts, in memory), gate levels, device and
//    format are in wakeStatus; v2.wake.locale auto moves between en-IN and
//    en-US on-device when one keeps failing; and after a wake turn is
//    answered the follow-up window takes a command without the wake word
//    for v2.wake.followUpSeconds (10 s).
//

import AppKit
import AVFoundation
import ClickyCore
import Combine
import CoreGraphics
import Foundation
import Speech

@MainActor
final class WakeWordController: ObservableObject {
    @Published private(set) var state: WakeWordListenerState = .off(.disabledInSettings)
    @Published private(set) var isEnabled = ClickySettings.isWakeWordEnabled

    /// The phrase fired; `initialTurnText` is what followed it in the same breath.
    var onWake: ((_ initialTurnText: String) -> Void)?
    /// P9: a standalone "stop" heard while Clicky may be talking or acting (CompanionManager decides).
    var onStopCommand: (() -> Void)?
    private(set) var stopCommandCount = 0
    /// The turn after the wake word ended (end-of-speech rule or the 30 s cap).
    var onTurnFinished: ((_ turnText: String) -> Void)?
    /// Nothing followed the wake word, or push-to-talk / hands-free took the mic.
    var onTurnAbandoned: (() -> Void)?
    /// P8: words started inside the follow-up window (no wake word): the listening state, no sound.
    var onFollowUpCommandStarted: (() -> Void)?
    /// P8: the follow-up window closed ("that's all", silence, cancelled).
    var onFollowUpEnded: ((WakeFollowUpEndReason) -> Void)?
    /// P8: true while Clicky is still answering (thinking, speaking, running an action): the window waits.
    var isAnswerBusy: () -> Bool = { false }

    /// P8: the follow-up window is open (the notch shows "listening…").
    @Published private(set) var isFollowUpListening = false

    static let pollIntervalSeconds: TimeInterval = 2

    private let speechOutput: CompanionSpeechOutput
    private let audioEngineHub: AudioEngineHub

    private var audioEngine: AVAudioEngine?
    private var audioEngineConfigurationObserver: NSObjectProtocol?
    private var pipeline: WakeWordRecognitionPipeline?
    private var matcher = WakeWordMatcher(phrases: ClickySettings.wakePhrases)
    private var phrasesInUse = ClickySettings.wakePhrases
    /// P8: the on-device locale in use, chosen by v2.wake.locale (auto: the system locale first,
    /// the other English one if requests keep failing). Nil: no on-device English recognizer.
    private lazy var localeSelector: WakeLocaleSelector = Self.makeLocaleSelector(setting: ClickySettings.wakeLocaleSetting)
    private var localeSettingInUse = ClickySettings.wakeLocaleSetting
    private var recognitionLocale: Locale? {
        get { localeSelector.currentLocale.map { Locale(identifier: $0) } }
        set { if newValue == nil { localeSelector = WakeLocaleSelector(setting: localeSettingInUse, candidates: []) } }
    }
    private var followUpWindow = WakeFollowUpWindow()
    private var followUpTimer: Timer?
    private var answerQuietSinceDate: Date?
    private var answerWaitStartedDate: Date?
    /// The device the wake engine is capturing from (and why that one).
    private(set) var listeningDevice: AudioInputDeviceInfo?
    private var listeningDeviceReason = "default input"
    private var lastPipelineStatistics = WakeWordPipelineStatistics()
    private var gate = WakeWordGate()

    private var isScreenLocked = false
    private var isDisplayAsleep = false
    private var isSystemAsleep = false
    private var isMicrophoneInUseElsewhere = false
    private var isDefaultInputBluetooth = false
    private var didAudioEngineFail = false
    private var isCapturingTurn = false
    private var hasRequestedAuthorization = false
    private var isStarted = false

    private var pollTimer: Timer?
    private var speechSuppressionRecheckTask: Task<Void, Never>?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var distributedObservers: [NSObjectProtocol] = []

    // Measurement (counts and latencies only).
    private(set) var wakeCount = 0
    /// Wakes with nothing said afterwards (likely false wakes).
    private(set) var falseWakeCount = 0
    private(set) var ignoredMatchCounts: [String: Int] = [:]
    private(set) var lastWakeLatencyMilliseconds: Int?
    private(set) var lastWakeDate: Date?
    private(set) var engineStartCount = 0
    private var processCPUWindow = ProcessCPUUsageWindow()
    private var speechServiceCPUWindow = ProcessCPUUsageWindow()
    private var pollTickCount = 0

    init(speechOutput: CompanionSpeechOutput, audioEngineHub: AudioEngineHub) {
        self.speechOutput = speechOutput
        self.audioEngineHub = audioEngineHub
    }

    // MARK: - Lifecycle

    func start() {
        guard !isStarted else { return }
        isStarted = true
        audioEngineHub.onExclusiveMicrophoneUsersChanged = { [weak self] _ in self?.microphoneClaimsChanged() }
        observeLockAndSleep()
        pollTimer = Timer.scheduledTimer(withTimeInterval: Self.pollIntervalSeconds, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollTick() }
        }
        isDefaultInputBluetooth = Self.isBluetoothWithoutWiredFallback()
        sampleCPU(includingSpeechService: true)
        reevaluate()
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        speechSuppressionRecheckTask?.cancel()
        workspaceObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        workspaceObservers.removeAll()
        distributedObservers.forEach { DistributedNotificationCenter.default().removeObserver($0) }
        distributedObservers.removeAll()
        stopMicrophone(reportAbandonedTurn: false)
        cancelFollowUp()
        isStarted = false
    }

    /// The menu toggle and "stop listening" / "start listening".
    func setEnabled(_ enabled: Bool) {
        ClickySettings.isWakeWordEnabled = enabled
        print("👂 Wake word \(enabled ? "on" : "off")")
        reevaluate()
    }

    /// Escape or a new push-to-talk turn: drop the turn being heard (and the follow-up window).
    func cancelCurrentTurn() {
        cancelFollowUp()
        guard isCapturingTurn else { return }
        isCapturingTurn = false
        pipeline?.cancelCapture()
        reevaluate()
    }

    var isHearingTurn: Bool { isCapturingTurn }

    // MARK: - State

    private func currentConditions() -> WakeWordConditions {
        let microphoneUsers = audioEngineHub.exclusiveMicrophoneUsers
        return WakeWordConditions(
            isEnabledInSettings: ClickySettings.isWakeWordEnabled,
            hasUsablePhrases: !matcher.phraseTexts.isEmpty,
            isOnDeviceRecognitionSupported: recognitionLocale != nil,
            isRecognizerAvailable: pipeline?.isRecognizerAvailable ?? true,
            isMicrophoneAuthorized: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
            isSpeechRecognitionAuthorized: SFSpeechRecognizer.authorizationStatus() == .authorized,
            isMicrophoneInUseByAnotherApp: isMicrophoneInUseElsewhere,
            isDefaultInputBluetooth: isDefaultInputBluetooth,
            isScreenLocked: isScreenLocked,
            isSystemAsleep: isSystemAsleep || isDisplayAsleep,
            isPushToTalkCapturing: microphoneUsers.contains(.pushToTalk),
            isHandsFreeCapturing: microphoneUsers.contains(.handsFree) || audioEngineHub.isVoiceProcessingActive,
            didAudioEngineFail: didAudioEngineFail,
            isCapturingTurn: isCapturingTurn
        )
    }

    /// Recomputes the state and opens or closes the mic to match.
    private func reevaluate() {
        guard isStarted else { return }
        // Runs every 2 s: publish only on a change.
        let isEnabledNow = ClickySettings.isWakeWordEnabled
        if isEnabled != isEnabledNow { isEnabled = isEnabledNow }
        let configuredPhrases = ClickySettings.wakePhrases
        let configuredLocaleSetting = ClickySettings.wakeLocaleSetting
        if configuredLocaleSetting != localeSettingInUse {
            localeSettingInUse = configuredLocaleSetting
            localeSelector = Self.makeLocaleSelector(setting: configuredLocaleSetting)
            print("👂 Wake word: locale setting → \(localeSelector.currentLocale ?? "none")")
            stopMicrophone(reportAbandonedTurn: true)
            pipeline = nil
        }
        if configuredPhrases != phrasesInUse {
            phrasesInUse = configuredPhrases
            matcher = WakeWordMatcher(phrases: configuredPhrases)
            // The pipeline holds the old matcher: rebuild it.
            stopMicrophone(reportAbandonedTurn: true)
            pipeline = nil
        }
        requestAuthorizationIfNeeded()

        var newState = currentConditions().state
        if newState.wantsMicrophone {
            if !startMicrophoneIfNeeded() {
                didAudioEngineFail = audioEngine == nil && recognitionLocale != nil && pipeline != nil
                newState = currentConditions().state
                if newState.wantsMicrophone { newState = .paused(.audioEngineFailed) }
            }
        } else {
            stopMicrophone(reportAbandonedTurn: true)
            // Push-to-talk, hands-free, lock, off: the follow-up window ends with the mic.
            cancelFollowUp()
        }
        if newState != state {
            print("👂 Wake word: \(newState.displayText)")
            state = newState
        }
        refreshSpeechSuppression()
    }

    /// Asks once for mic / speech permission when the wake word is on and macOS hasn't asked yet.
    private func requestAuthorizationIfNeeded() {
        guard ClickySettings.isWakeWordEnabled, !hasRequestedAuthorization else { return }
        let isMicrophoneUndetermined = AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined
        let isSpeechUndetermined = SFSpeechRecognizer.authorizationStatus() == .notDetermined
        guard isMicrophoneUndetermined || isSpeechUndetermined else { return }
        hasRequestedAuthorization = true
        Task { @MainActor [weak self] in
            if isMicrophoneUndetermined { _ = await AVCaptureDevice.requestAccess(for: .audio) }
            if isSpeechUndetermined { await Self.requestSpeechRecognitionAuthorization() }
            self?.reevaluate()
        }
    }

    private func microphoneClaimsChanged() {
        // Yield at once (before push-to-talk / hands-free start their engines); resume shortly after.
        if !audioEngineHub.exclusiveMicrophoneUsers.isEmpty {
            reevaluate()
        } else {
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 400_000_000)
                self?.reevaluate()
            }
        }
    }

    private func pollTick() {
        pollTickCount += 1
        didAudioEngineFail = false
        if let isLockedNow = Self.readScreenLockState() { isScreenLocked = isLockedNow }
        if ClickySettings.isWakeWordEnabled, audioEngineHub.exclusiveMicrophoneUsers.isEmpty, !isScreenLocked {
            isMicrophoneInUseElsewhere = MicrophoneInUseProbe.isMicrophoneInUseByAnotherProcess(isOwnEngineRunning: audioEngine?.isRunning == true)
            isDefaultInputBluetooth = Self.isBluetoothWithoutWiredFallback()
        }
        sampleCPU(includingSpeechService: pollTickCount % 5 == 0)
        reevaluate()
    }

    // MARK: - Microphone

    /// Pause for Bluetooth only when there's no wired mic to pin instead.
    private static func isBluetoothWithoutWiredFallback() -> Bool {
        MicrophoneInUseProbe.isDefaultInputBluetooth() && MicrophoneInUseProbe.wiredInputDeviceID() == nil
    }

    /// Opens the wake mic if it isn't open. False if it couldn't.
    private func startMicrophoneIfNeeded() -> Bool {
        if audioEngine != nil { return true }
        guard let recognitionLocale else { return false }
        if pipeline == nil {
            pipeline = WakeWordRecognitionPipeline(locale: recognitionLocale, matcher: matcher,
                                                   onEvent: Self.makePipelineEventHandler(wakeWordController: self))
            if pipeline == nil {
                print("⚠️ Wake word: no on-device recognizer for \(recognitionLocale.identifier)")
                self.recognitionLocale = nil
                return false
            }
        }
        guard let pipeline else { return false }

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        // P8: listen on the mic push-to-talk really uses (its turns are the ones that work), unless that's a
        // Bluetooth headset. Else, a Bluetooth headset as the default input: listen on a wired mic instead (the
        // headset stays in music mode for Netflix). Only this engine; push-to-talk keeps the default input.
        let defaultInputDevice = AudioInputDeviceInfo.defaultInput()
        var pinnedDeviceID: AudioDeviceID?
        listeningDeviceReason = "default input"
        if let pushToTalkDevice = PushToTalkInputDeviceRecord.lastDevice, !pushToTalkDevice.isBluetooth,
           let liveDeviceID = AudioInputDeviceInfo.inputDeviceID(forUID: pushToTalkDevice.uid) {
            listeningDeviceReason = "same mic as push-to-talk"
            if liveDeviceID != defaultInputDevice?.deviceID { pinnedDeviceID = liveDeviceID }
        } else if MicrophoneInUseProbe.isDefaultInputBluetooth(), let wiredDeviceID = MicrophoneInUseProbe.wiredInputDeviceID() {
            listeningDeviceReason = "wired mic (the default input is Bluetooth)"
            pinnedDeviceID = wiredDeviceID
        }
        if var pinnedDeviceID, let audioUnit = inputNode.audioUnit {
            let status = AudioUnitSetProperty(audioUnit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                              &pinnedDeviceID, UInt32(MemoryLayout<AudioDeviceID>.size))
            print(status == noErr ? "🎙️ Wake word: listening on device \(pinnedDeviceID) (\(listeningDeviceReason))"
                                  : "⚠️ Wake word: couldn't pin device \(pinnedDeviceID) (\(status))")
        }
        let inputFormat = inputNode.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            print("⚠️ Wake word: the mic has no usable format")
            return false
        }
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat, block: Self.makeAudioTapBlock(pipeline: pipeline))
        engine.prepare()
        do {
            try engine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            print("⚠️ Wake word: the mic didn't start: \(error.localizedDescription)")
            return false
        }
        audioEngine = engine
        engineStartCount += 1
        listeningDevice = AudioInputDeviceInfo.current(of: inputNode.audioUnit) ?? defaultInputDevice
        if let listeningDevice {
            print("🎙️ Wake word input: \(listeningDevice.name) (\(listeningDevice.uid), \(Int(listeningDevice.nominalSampleRate)) Hz, \(listeningDeviceReason))")
        }
        // A rebuilt pipeline (new locale, new device) keeps an open follow-up window.
        pipeline.setFollowUpListening(followUpWindow.isOpen)
        audioEngineConfigurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                // New device or format: start over on a fresh engine.
                self?.stopMicrophone(reportAbandonedTurn: true)
                self?.reevaluate()
            }
        }
        print("👂 Wake word: mic open (\(Int(inputFormat.sampleRate)) Hz, \(pipeline.localeIdentifier), on-device)")
        return true
    }

    private func stopMicrophone(reportAbandonedTurn: Bool) {
        if let audioEngineConfigurationObserver { NotificationCenter.default.removeObserver(audioEngineConfigurationObserver) }
        audioEngineConfigurationObserver = nil
        if let audioEngine {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
            self.audioEngine = nil
            print("👂 Wake word: mic closed")
        }
        if let pipeline { lastPipelineStatistics = pipeline.currentStatistics() }
        pipeline?.reset()
        if isCapturingTurn {
            isCapturingTurn = false
            if reportAbandonedTurn { onTurnAbandoned?() }
        }
    }

    // MARK: - Clicky talking

    /// While Clicky talks (and 1.5 s after) no audio reaches the recognizer.
    func refreshSpeechSuppression() {
        // P9 barge-in: keep listening while Clicky talks so "stop" / "Hey Claudia" can interrupt it.
        let isSuppressed = isClickySpeakingOrJustSpoke && !ClickySettings.isWakeBargeInEnabled
        pipeline?.setSuppressed(isSuppressed && !isCapturingTurn)
        speechSuppressionRecheckTask?.cancel()
        guard isSuppressed, audioEngine != nil else { return }
        speechSuppressionRecheckTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            self?.refreshSpeechSuppression()
        }
    }

    private var isClickySpeakingOrJustSpoke: Bool {
        if speechOutput.isPlaying { return true }
        guard let lastSpeechEndDate = speechOutput.lastSpeechEndDate else { return false }
        return Date().timeIntervalSince(lastSpeechEndDate) < WakeWordGate.afterSpeechSeconds
    }

    // MARK: - Pipeline events

    private func handle(_ event: WakeWordPipelineEvent) {
        switch event {
        case .candidate(let candidate):
            guard state == .armed, let pipeline else {
                ignoredMatchCounts["notArmed", default: 0] += 1
                return
            }
            let now = Date()
            if candidate.isFollowUp {
                // Inside the follow-up window: no wake word needed, but never while Clicky talks.
                guard !speechOutput.isPlaying, followUpWindow.commandSpeechStarted(at: now) else {
                    ignoredMatchCounts["followUpClosedOrSpeaking", default: 0] += 1
                    return
                }
                isCapturingTurn = true
                followUpCommandCount += 1
                pipeline.beginCapture(for: candidate)
                publishFollowUpState()
                reevaluate()
                onFollowUpCommandStarted?()
                return
            }
            let decision = gate.decide(at: now, isClickySpeaking: speechOutput.isPlaying, lastClickySpeechEndDate: speechOutput.lastSpeechEndDate,
                                       recentClickySpokenWords: speechOutput.recentSpokenWords(at: now), matcher: matcher,
                                       allowsBargeIn: ClickySettings.isWakeBargeInEnabled)
            guard decision == .fire else {
                ignoredMatchCounts[decision.rawValue, default: 0] += 1
                print("👂 Wake word: match ignored (\(decision.rawValue))")
                return
            }
            wakeCount += 1
            lastWakeDate = now
            lastWakeLatencyMilliseconds = candidate.latencySeconds.map { Int(($0 * 1000).rounded()) }
            print("👂 Wake word: fired #\(wakeCount), latency \(lastWakeLatencyMilliseconds.map { "\($0) ms" } ?? "n/a (no word times)")")
            isCapturingTurn = true
            pipeline.beginCapture(for: candidate)
            reevaluate()
            onWake?(candidate.match.remainderText)

        case .captureUpdated:
            break

        case .stopCommand(let words):
            guard state == .armed, ClickySettings.isWakeBargeInEnabled,
                  WakeStopCommand.isStopUtterance(words, recentClickySpokenWords: speechOutput.recentSpokenWords(at: Date())) else {
                ignoredMatchCounts["stopEcho", default: 0] += 1
                return
            }
            stopCommandCount += 1
            onStopCommand?()

        case .captureFinished(let turnText, let candidate):
            guard isCapturingTurn else { return }
            isCapturingTurn = false
            defer { rebuildPipelineForLocaleIfIdle() }
            reevaluate()
            if candidate.isFollowUp {
                let decision = followUpWindow.commandHeard(turnText, at: Date(), recentClickySpokenWords: speechOutput.recentSpokenWords(at: Date()))
                switch decision {
                case .command(let commandText):
                    print("👂 Follow-up: command heard (\(commandText.split(separator: " ").count) words)")
                    publishFollowUpState()
                    onTurnFinished?(commandText)
                case .ended(let reason):
                    finishFollowUp(reason)
                    onTurnAbandoned?()
                case .ignored(let reason):
                    ignoredMatchCounts["followUp.\(reason)", default: 0] += 1
                    publishFollowUpState()
                    onTurnAbandoned?()
                }
                return
            }
            onTurnFinished?(turnText)

        case .captureAbandoned(let candidate):
            guard isCapturingTurn else { return }
            isCapturingTurn = false
            if candidate.isFollowUp {
                followUpWindow.commandAbandoned(at: Date())
                publishFollowUpState()
                reevaluate()
                onTurnAbandoned?()
                return
            }
            falseWakeCount += 1
            print("👂 Wake word: nothing said after it (likely false wakes: \(falseWakeCount))")
            reevaluate()
            onTurnAbandoned?()

        case .requestFinished(let localeIdentifier, let failed):
            guard let switchedLocale = localeSelector.record(locale: localeIdentifier, failed: failed, at: Date()) else { return }
            print("👂 Wake word: switching the recognizer to \(switchedLocale) — \(localeSelector.switchLog.last ?? "")")
            // Rebuilt between turns only (never mid-turn or inside the follow-up window).
            needsPipelineRebuildForLocale = true
            rebuildPipelineForLocaleIfIdle()
        }
    }

    // MARK: - Follow-up window (P8)

    private(set) var followUpCommandCount = 0
    private(set) var followUpEndCounts: [String: Int] = [:]

    /// A wake turn (or a follow-up command) went to Clicky: once its answer is done, listen for more.
    func wakeTurnWasSent() {
        let listenSeconds = ClickySettings.wakeFollowUpSeconds
        guard listenSeconds > 0, ClickySettings.isWakeWordEnabled else { return }
        followUpWindow.listenSeconds = listenSeconds
        followUpWindow.turnSent()
        answerQuietSinceDate = nil
        answerWaitStartedDate = Date()
        startFollowUpTimer()
        publishFollowUpState()
    }

    /// Dictation ("type what I say"): keep the window open for `seconds` from now (opening it if needed).
    func keepFollowUpOpen(forSeconds seconds: TimeInterval) {
        guard ClickySettings.isWakeWordEnabled, state == .armed || state == .capturing else { return }
        let now = Date()
        if followUpWindow.phase == .idle {
            followUpWindow.listenSeconds = seconds
            followUpWindow.turnSent()
            followUpWindow.answerFinished(at: now)
            pipeline?.setFollowUpListening(true)
            startFollowUpTimer()
        } else {
            // Waiting for the answer: the window that follows lasts at least this long.
            followUpWindow.listenSeconds = max(followUpWindow.listenSeconds, seconds)
            followUpWindow.extend(until: now.addingTimeInterval(seconds))
        }
        publishFollowUpState()
    }

    var isFollowUpOpen: Bool { followUpWindow.isOpen }

    func cancelFollowUp() {
        guard followUpWindow.phase != .idle else { return }
        followUpWindow.cancel()
        finishFollowUp(.cancelled)
    }

    private func startFollowUpTimer() {
        guard followUpTimer == nil else { return }
        followUpTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.followUpTimerTick() }
        }
    }

    private func followUpTimerTick() {
        let now = Date()
        switch followUpWindow.phase {
        case .idle:
            followUpTimer?.invalidate()
            followUpTimer = nil
        case .awaitingAnswer:
            // The answer is done once Clicky has been quiet (not thinking, speaking or acting) for half a second.
            if isAnswerBusy() || speechOutput.isPlaying {
                answerQuietSinceDate = nil
                // A turn that never finishes (stuck) doesn't keep the window pending forever.
                if let answerWaitStartedDate, now.timeIntervalSince(answerWaitStartedDate) > 180 { cancelFollowUp() }
                return
            }
            if answerQuietSinceDate == nil { answerQuietSinceDate = now }
            guard let answerQuietSinceDate, now.timeIntervalSince(answerQuietSinceDate) >= 0.5 else { return }
            followUpWindow.answerFinished(at: now)
            pipeline?.setFollowUpListening(true)
            print("👂 Follow-up: listening \(Int(followUpWindow.listenSeconds)) s for another command")
            publishFollowUpState()
        case .listening:
            if let endReason = followUpWindow.tick(now: now) { finishFollowUp(endReason) }
        case .hearingCommand:
            break
        }
    }

    private func finishFollowUp(_ reason: WakeFollowUpEndReason) {
        pipeline?.setFollowUpListening(false)
        followUpTimer?.invalidate()
        followUpTimer = nil
        followUpEndCounts[reason.rawValue, default: 0] += 1
        print("👂 Follow-up: ended (\(reason.rawValue))")
        publishFollowUpState()
        onFollowUpEnded?(reason)
        rebuildPipelineForLocaleIfIdle()
    }

    private func publishFollowUpState() {
        let isListeningNow = followUpWindow.showsListening
        if isFollowUpListening != isListeningNow { isFollowUpListening = isListeningNow }
    }

    // MARK: - Locale

    private var needsPipelineRebuildForLocale = false

    private func rebuildPipelineForLocaleIfIdle() {
        guard needsPipelineRebuildForLocale, !isCapturingTurn, followUpWindow.phase == .idle else { return }
        needsPipelineRebuildForLocale = false
        stopMicrophone(reportAbandonedTurn: true)
        pipeline = nil
        reevaluate()
    }

    /// The on-device English locales, the system one first.
    private static func makeLocaleSelector(setting: WakeLocaleSetting) -> WakeLocaleSelector {
        var candidates: [String] = []
        if let preferredLocale = WakeWordRecognitionPipeline.preferredLocale() { candidates.append(preferredLocale.identifier) }
        for identifier in ["en-IN", "en-US"] where !candidates.contains(where: { WakeLocaleSelector.sameLocale($0, identifier) })
            && WakeWordRecognitionPipeline.supportsOnDeviceRecognition(Locale(identifier: identifier)) {
            candidates.append(identifier)
        }
        var selector = WakeLocaleSelector(setting: setting, candidates: candidates)
        // A fixed locale that can't run on-device falls back to the automatic choice.
        if selector.currentLocale == nil, case .fixed = setting { selector = WakeLocaleSelector(setting: .automatic, candidates: candidates) }
        return selector
    }

    // MARK: - Lock and sleep

    private func observeLockAndSleep() {
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        let workspaceEvents: [(Notification.Name, @MainActor (WakeWordController) -> Void)] = [
            (NSWorkspace.screensDidSleepNotification, { $0.isDisplayAsleep = true }),
            (NSWorkspace.screensDidWakeNotification, { $0.isDisplayAsleep = false }),
            (NSWorkspace.willSleepNotification, { $0.isSystemAsleep = true }),
            (NSWorkspace.didWakeNotification, { $0.isSystemAsleep = false })
        ]
        for (notificationName, update) in workspaceEvents {
            workspaceObservers.append(workspaceCenter.addObserver(forName: notificationName, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    update(self)
                    self.reevaluate()
                }
            })
        }
        let distributedEvents: [(String, Bool)] = [("com.apple.screenIsLocked", true), ("com.apple.screenIsUnlocked", false)]
        for (notificationName, isLocked) in distributedEvents {
            distributedObservers.append(DistributedNotificationCenter.default().addObserver(
                forName: Notification.Name(notificationName), object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.isScreenLocked = isLocked
                    self?.reevaluate()
                }
            })
        }
        isScreenLocked = Self.readScreenLockState() ?? false
    }

    /// The login session's lock flag (absent while unlocked); nil if the session can't be read.
    private static func readScreenLockState() -> Bool? {
        guard let sessionDictionary = CGSessionCopyCurrentDictionary() as? [String: Any] else { return nil }
        return (sessionDictionary["CGSSessionScreenIsLocked"] as? Bool) == true
    }

    // MARK: - Measurement

    private func sampleCPU(includingSpeechService: Bool) {
        let uptimeSeconds = ProcessInfo.processInfo.systemUptime
        processCPUWindow.record(wallSeconds: uptimeSeconds, cpuSeconds: ProcessCPUTimeProbe.currentProcessCPUSeconds())
        if includingSpeechService, let speechServiceSeconds = ProcessCPUTimeProbe.speechServiceCPUSeconds() {
            speechServiceCPUWindow.record(wallSeconds: uptimeSeconds, cpuSeconds: speechServiceSeconds)
        }
    }

    /// The debug inbox's `wakeStatus`.
    func statusSnapshot() -> [String: Any] {
        let statistics = pipeline?.currentStatistics() ?? lastPipelineStatistics
        func rounded(_ value: Double?) -> Any { value.map { ($0 * 100).rounded() / 100 } ?? NSNull() }
        return [
            "enabled": ClickySettings.isWakeWordEnabled,
            "armed": state == .armed,
            "state": state.displayText,
            "pausedReason": state.inactiveReason?.rawValue ?? NSNull(),
            "phrases": matcher.phraseTexts,
            "locale": recognitionLocale?.identifier ?? NSNull(),
            "onDevice": true,
            "micOpen": audioEngine?.isRunning == true,
            "wakes": wakeCount,
            "falseWakes": falseWakeCount,
            "ignoredMatches": ignoredMatchCounts,
            "lastWakeLatencyMs": lastWakeLatencyMilliseconds ?? NSNull(),
            "lastWakeAgoSeconds": lastWakeDate.map { Int(Date().timeIntervalSince($0)) } ?? NSNull(),
            "restarts": statistics.restarts,
            "requestsStarted": statistics.requestsStarted,
            "recognizerErrors": statistics.recognizerErrors,
            "gateOpenings": statistics.gateOpenings,
            "recognizedAudioSeconds": rounded(statistics.recognizedAudioSeconds),
            "receivedAudioSeconds": rounded(statistics.receivedAudioSeconds),
            "recognizerWordTimes": statistics.usedRecognizerWordTimes,
            "engineStarts": engineStartCount,
            "cpuPercentLastMinute": rounded(processCPUWindow.percent),
            "cpuWindowSeconds": Int(processCPUWindow.spanSeconds),
            "speechServiceCpuPercentLastMinute": rounded(speechServiceCPUWindow.percent),
            // P8 diagnosis.
            "errorsByCode": statistics.errorsByCode,
            "benignErrors": statistics.benignErrors,
            "nearMisses": statistics.nearMisses.displayCounts,
            "nearMissTotal": statistics.nearMisses.totalCount,
            "followUpActive": followUpWindow.isOpen,
            "followUpPhase": String(describing: followUpWindow.phase).components(separatedBy: "(").first ?? "",
            "followUpCommands": followUpCommandCount,
            "followUpEnds": followUpEndCounts,
            "deviceSampleRate": statistics.inputSampleRate ?? listeningDevice?.nominalSampleRate ?? NSNull(),
            "device": listeningDevice?.statusDictionary ?? NSNull(),
            "deviceReason": listeningDeviceReason,
            "pushToTalkDevice": PushToTalkInputDeviceRecord.lastDevice?.statusDictionary ?? NSNull(),
            "defaultInputDevice": AudioInputDeviceInfo.defaultInput()?.statusDictionary ?? NSNull(),
            "inputFormat": statistics.inputFormatText ?? NSNull(),
            "conversion": statistics.conversionText,
            "noiseFloorDb": rounded(statistics.noiseFloorDecibels),
            "openThresholdDb": rounded(statistics.openThresholdDecibels),
            "lastOpenPeakDb": rounded(statistics.lastOpenPeakDecibels),
            "makeUpGainDb": rounded(statistics.makeUpGainDecibels),
            "suppressed": statistics.isSuppressed,
            "preRollSeconds": WakeWordRecognitionPipeline.preRollSeconds,
            "localeSetting": UserDefaults.standard.string(forKey: ClickySettings.Keys.wakeLocale) ?? "auto",
            "localeCandidates": localeSelector.candidates,
            "localeFailureRates": Dictionary(uniqueKeysWithValues: localeSelector.candidates.map { ($0, rounded(localeSelector.failureRate(of: $0))) }),
            "localeSwitches": localeSelector.switchLog
        ]
    }

    /// The Diagnostics window's wake word section.
    func diagnosticsLines() -> [DiagnosticsStatusLine] {
        let level: DiagnosticsStatusLine.Level
        switch state {
        case .armed, .capturing: level = .good
        case .paused: level = .unknown
        case .off(let reason): level = reason == .disabledInSettings ? .unknown : .problem
        }
        var lines = [
            DiagnosticsStatusLine(label: "Wake word", value: state.displayText, level: level),
            DiagnosticsStatusLine(label: "Wake phrases", value: matcher.phraseTexts.joined(separator: ", "), level: matcher.phraseTexts.isEmpty ? .problem : .good),
            DiagnosticsStatusLine(label: "Wake recognizer", value: recognitionLocale.map { "\($0.identifier), on-device only" } ?? "No on-device recognizer (wake word off)",
                                  level: recognitionLocale == nil ? .problem : .good)
        ]
        let latencyText = lastWakeLatencyMilliseconds.map { ", last latency \($0) ms" } ?? ""
        let cpuText = processCPUWindow.percent.map { String(format: ", Clicky CPU %.1f%%", $0) } ?? ""
        lines.append(DiagnosticsStatusLine(label: "Wake counts", value: "\(wakeCount) wakes, \(falseWakeCount) likely false\(latencyText)\(cpuText)", level: .unknown))
        return lines
    }

    /// The debug inbox's `wakeFeed`: a WAV/CAF through the same recognizer
    /// and matcher (a separate pipeline; the live one keeps listening). No
    /// mic, no speaker.
    /// `localeIdentifier` (P8 wakeFeedBatch): feed through that on-device locale instead of the live one.
    func feedFile(at fileURL: URL, localeIdentifier: String? = nil) async -> (isSuccess: Bool, result: [String: Any], errorMessage: String?) {
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else {
            return (false, [:], "speech recognition isn't authorized")
        }
        guard let feedLocale = localeIdentifier.map({ Locale(identifier: $0) }) ?? recognitionLocale else { return (false, [:], "no on-device recognizer for this language") }
        guard FileManager.default.isReadableFile(atPath: fileURL.path) else { return (false, [:], "can't read \(fileURL.path)") }
        let report = await WakeWordFileFeeder.feed(fileURL: fileURL, locale: feedLocale, matcher: matcher)
        func milliseconds(_ seconds: TimeInterval?) -> Any { seconds.map { Int(($0 * 1000).rounded()) } ?? NSNull() }
        let detections: [[String: Any]] = report.detections.map { detection in
            [
                "phrase": detection.phrase,
                "decision": detection.decision.rawValue,
                "detectedAtMs": milliseconds(detection.detectedAtSeconds),
                "phraseEndMs": milliseconds(detection.phraseEndSeconds),
                "latencyMs": detection.latencyMilliseconds ?? NSNull(),
                // The test file's own words after the phrase (this is a file the caller supplied, not the mic).
                "turnText": detection.turnText ?? NSNull()
            ]
        }
        let result: [String: Any] = [
            "file": fileURL.lastPathComponent,
            "fileSeconds": (report.fileSeconds * 100).rounded() / 100,
            "locale": report.localeIdentifier,
            "detections": detections,
            "requestsStarted": report.statistics.requestsStarted,
            "restarts": report.statistics.restarts,
            "recognizedAudioSeconds": (report.statistics.recognizedAudioSeconds * 100).rounded() / 100,
            "recognizerWordTimes": report.statistics.usedRecognizerWordTimes,
            // What the recognizer heard in this test file (feed only; never the mic).
            "heard": report.statistics.heardTexts.filter { !$0.isEmpty },
            "errorsByCode": report.statistics.errorsByCode,
            "inputFormat": report.statistics.inputFormatText ?? NSNull(),
            "conversion": report.statistics.conversionText,
            "noiseFloorDb": (report.statistics.noiseFloorDecibels * 10).rounded() / 10,
            "makeUpGainDb": (report.statistics.makeUpGainDecibels * 10).rounded() / 10
        ]
        return (report.errorMessage == nil, result, report.errorMessage)
    }

    /// P8 `wakeFeedBatch {paths, locale?}`: each file through a fresh pipeline (one after another), with a summary
    /// of how many woke. `localeIdentifier` nil: the live locale. Test files only, never the mic.
    func feedFiles(at fileURLs: [URL], localeIdentifier: String?) async -> (isSuccess: Bool, result: [String: Any], errorMessage: String?) {
        if let localeIdentifier, !WakeWordRecognitionPipeline.supportsOnDeviceRecognition(Locale(identifier: localeIdentifier)) {
            return (false, [:], "\(localeIdentifier) has no on-device recognizer")
        }
        var fileResults: [[String: Any]] = []
        var wokeCount = 0
        for fileURL in fileURLs {
            let (isSuccess, result, errorMessage) = await feedFile(at: fileURL, localeIdentifier: localeIdentifier)
            var fileResult = result
            fileResult["ok"] = isSuccess
            if let errorMessage { fileResult["error"] = errorMessage }
            let detections = result["detections"] as? [[String: Any]] ?? []
            let woke = detections.contains { $0["decision"] as? String == WakeWordGate.Decision.fire.rawValue }
            fileResult["woke"] = woke
            if woke { wokeCount += 1 }
            fileResults.append(fileResult)
        }
        let usedLocale = localeIdentifier ?? recognitionLocale?.identifier ?? ""
        return (true, ["locale": usedLocale, "files": fileResults, "woke": wokeCount, "total": fileURLs.count,
                       "wakeRate": fileURLs.isEmpty ? 0 : Double(wokeCount) / Double(fileURLs.count)], nil)
    }

    /// P8 `wakeFeedChain {path}`: "hey claudia, <cmd1>" … "<cmd2>" … "that's all" through the recognizer, the
    /// matcher and the follow-up window. `describeCommand` turns each command into the fast path's dry-run
    /// description (nothing is executed). The trailing 11 s of silence lets the window end on silence too.
    func feedChain(at fileURL: URL, localeIdentifier: String?,
                   describeCommand: (String) -> [String: Any]) async -> (isSuccess: Bool, result: [String: Any], errorMessage: String?) {
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else { return (false, [:], "speech recognition isn't authorized") }
        guard let feedLocale = localeIdentifier.map({ Locale(identifier: $0) }) ?? recognitionLocale else { return (false, [:], "no on-device recognizer for this language") }
        guard FileManager.default.isReadableFile(atPath: fileURL.path) else { return (false, [:], "can't read \(fileURL.path)") }
        let report = await WakeWordFileFeeder.feed(fileURL: fileURL, locale: feedLocale, matcher: matcher,
                                                   trailingSilenceSeconds: WakeFollowUpWindow.defaultListenSeconds + 1.5, followsUp: true)
        let wakes = report.detections.filter { $0.decision == .fire }.count
        var commands: [[String: Any]] = []
        if let wakeTurnText = report.wakeTurnText {
            var entry = describeCommand(wakeTurnText)
            entry["text"] = wakeTurnText
            entry["viaFollowUp"] = false
            commands.append(entry)
        }
        let followUpCommands: [[String: Any]] = report.followUpCommands.map { command in
            var entry = describeCommand(command.text)
            entry["text"] = command.text
            entry["heardAtMs"] = Int((command.heardAtSeconds * 1000).rounded())
            entry["viaFollowUp"] = true
            return entry
        }
        commands += followUpCommands
        let result: [String: Any] = [
            "file": fileURL.lastPathComponent,
            "locale": report.localeIdentifier,
            "wakes": wakes,
            "wakeTurn": commands.first.map { $0 as Any } ?? NSNull(),
            "followUpCommands": followUpCommands,
            "commands": commands,
            "endedBy": report.followUpEndedBy ?? NSNull(),
            "heard": report.statistics.heardTexts.filter { !$0.isEmpty },
            "errorsByCode": report.statistics.errorsByCode
        ]
        return (report.errorMessage == nil, result, report.errorMessage)
    }

    // MARK: - Off-main-thread callbacks

    /// Built nonisolated: Speech answers on its own queue.
    private nonisolated static func requestSpeechRecognitionAuthorization() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            SFSpeechRecognizer.requestAuthorization { _ in continuation.resume() }
        }
    }

    /// Built nonisolated: AVAudioEngine calls the tap on its own audio thread.
    private nonisolated static func makeAudioTapBlock(pipeline: WakeWordRecognitionPipeline) -> AVAudioNodeTapBlock {
        return { audioBuffer, _ in
            pipeline.append(audioBuffer)
        }
    }

    /// The pipeline calls this on its queue; hop to the main actor.
    private nonisolated static func makePipelineEventHandler(wakeWordController: WakeWordController) -> @Sendable (WakeWordPipelineEvent) -> Void {
        let controllerBox = WeakWakeWordControllerBox(controller: wakeWordController)
        return { event in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { controllerBox.controller?.handle(event) }
            }
        }
    }
}

private nonisolated final class WeakWakeWordControllerBox: @unchecked Sendable {
    weak var controller: WakeWordController?

    init(controller: WakeWordController) {
        self.controller = controller
    }
}
