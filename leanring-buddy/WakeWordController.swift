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
    /// The turn after the wake word ended (end-of-speech rule or the 30 s cap).
    var onTurnFinished: ((_ turnText: String) -> Void)?
    /// Nothing followed the wake word, or push-to-talk / hands-free took the mic.
    var onTurnAbandoned: (() -> Void)?

    static let pollIntervalSeconds: TimeInterval = 2

    private let speechOutput: CompanionSpeechOutput
    private let audioEngineHub: AudioEngineHub

    private var audioEngine: AVAudioEngine?
    private var audioEngineConfigurationObserver: NSObjectProtocol?
    private var pipeline: WakeWordRecognitionPipeline?
    private var matcher = WakeWordMatcher(phrases: ClickySettings.wakePhrases)
    private var phrasesInUse = ClickySettings.wakePhrases
    /// Resolved once: the system locale if English and on-device, else en-US, else nil.
    private lazy var recognitionLocale: Locale? = WakeWordRecognitionPipeline.preferredLocale()
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
        isStarted = false
    }

    /// The menu toggle and "stop listening" / "start listening".
    func setEnabled(_ enabled: Bool) {
        ClickySettings.isWakeWordEnabled = enabled
        print("👂 Wake word \(enabled ? "on" : "off")")
        reevaluate()
    }

    /// Escape or a new push-to-talk turn: drop the turn being heard.
    func cancelCurrentTurn() {
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
        // A Bluetooth headset is the default input: listen on a wired mic instead (the headset stays in
        // music mode for Netflix). Only this engine; push-to-talk keeps the default input.
        if MicrophoneInUseProbe.isDefaultInputBluetooth(), var wiredDeviceID = MicrophoneInUseProbe.wiredInputDeviceID(),
           let audioUnit = inputNode.audioUnit {
            let status = AudioUnitSetProperty(audioUnit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                              &wiredDeviceID, UInt32(MemoryLayout<AudioDeviceID>.size))
            print(status == noErr ? "🎙️ Wake word: Bluetooth default input, listening on wired mic \(wiredDeviceID)"
                                  : "⚠️ Wake word: couldn't pin the wired mic (\(status))")
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
        pipeline?.reset()
        if isCapturingTurn {
            isCapturingTurn = false
            if reportAbandonedTurn { onTurnAbandoned?() }
        }
    }

    // MARK: - Clicky talking

    /// While Clicky talks (and 1.5 s after) no audio reaches the recognizer.
    func refreshSpeechSuppression() {
        let isSuppressed = isClickySpeakingOrJustSpoke
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
            let decision = gate.decide(at: now, isClickySpeaking: speechOutput.isPlaying, lastClickySpeechEndDate: speechOutput.lastSpeechEndDate,
                                       recentClickySpokenWords: speechOutput.recentSpokenWords(at: now), matcher: matcher)
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

        case .captureFinished(let turnText, _):
            guard isCapturingTurn else { return }
            isCapturingTurn = false
            reevaluate()
            onTurnFinished?(turnText)

        case .captureAbandoned:
            guard isCapturingTurn else { return }
            isCapturingTurn = false
            falseWakeCount += 1
            print("👂 Wake word: nothing said after it (likely false wakes: \(falseWakeCount))")
            reevaluate()
            onTurnAbandoned?()
        }
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
        let statistics = pipeline?.currentStatistics() ?? WakeWordPipelineStatistics()
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
            "speechServiceCpuPercentLastMinute": rounded(speechServiceCPUWindow.percent)
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
    func feedFile(at fileURL: URL) async -> (isSuccess: Bool, result: [String: Any], errorMessage: String?) {
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else {
            return (false, [:], "speech recognition isn't authorized")
        }
        guard let recognitionLocale else { return (false, [:], "no on-device recognizer for this language") }
        guard FileManager.default.isReadableFile(atPath: fileURL.path) else { return (false, [:], "can't read \(fileURL.path)") }
        let report = await WakeWordFileFeeder.feed(fileURL: fileURL, locale: recognitionLocale, matcher: matcher)
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
            "heard": report.statistics.heardTexts.filter { !$0.isEmpty }
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
