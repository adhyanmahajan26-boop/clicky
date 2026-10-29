//
//  HandsFreeListeningSession.swift
//  leanring-buddy
//
//  Always-on microphone listener for hands-free sessions. Unlike push-to-talk
//  (one recording per key hold), this keeps the mic open and splits speech
//  into utterances by detecting pauses, so the user can just talk.
//
//  - Transcription is on-device Apple Speech, so nothing is sent anywhere
//    until an utterance is routed to Claude.
//  - Voice processing (echo cancellation) is enabled on the input node so the
//    buddy's own spoken replies are less likely to be heard as the user.
//  - After each utterance the recognition request is restarted, which keeps
//    transcripts short and avoids recognizer time limits.
//  - P6.4 v2.voice.echoMode "aec": the mic runs on the AudioEngineHub's
//    shared engine instead (the voices play through it, so the canceller
//    has the reference). Headphones resolve to "open", a voice-processing
//    throw to "halfDuplex" (both then use the session's own engine).
//

import AVFoundation
import Foundation
import ClickyCore
import Speech

/// Holds the currently active recognition request so the audio tap (which
/// runs on a realtime audio thread) can keep appending buffers while the main
/// actor swaps in a fresh request after each utterance.
private nonisolated final class HandsFreeRecognitionRequestBox: @unchecked Sendable {
    private let lock = NSLock()
    private var activeRecognitionRequest: SFSpeechAudioBufferRecognitionRequest?

    func replaceActiveRecognitionRequest(with newRecognitionRequest: SFSpeechAudioBufferRecognitionRequest?) {
        lock.lock()
        activeRecognitionRequest = newRecognitionRequest
        lock.unlock()
    }

    func appendAudioBuffer(_ audioBuffer: AVAudioPCMBuffer) {
        lock.lock()
        let currentRecognitionRequest = activeRecognitionRequest
        lock.unlock()
        currentRecognitionRequest?.append(audioBuffer)
    }
}

struct HandsFreeListeningSessionError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

final class HandsFreeListeningSession {
    /// How long the user must be quiet before an utterance counts as finished.
    /// Long enough to not cut people off mid-thought, short enough to feel snappy.
    /// (Shared with the P7 wake turn through UtteranceEndRule.)
    private let utteranceEndSilenceSeconds: TimeInterval = UtteranceEndRule.silenceSeconds

    private let onPartialTranscript: (String) -> Void
    private let onUtteranceFinished: (String) -> Void

    /// The shared mic + voice engine ("aec" only).
    private let audioEngineHub: AudioEngineHub?
    private let requestedEchoMode: ClickySettings.EchoMode
    /// The echo mode that actually runs once listening started.
    private(set) var resolvedEchoMode: ClickySettings.EchoMode
    /// What CompanionManager filters with: the resolved mode for "aec";
    /// open / halfDuplex keep following the live setting (switching to
    /// "aec" takes effect at the next hands-free start).
    var effectiveEchoMode: ClickySettings.EchoMode {
        if requestedEchoMode == .aec { return resolvedEchoMode }
        let currentSetting = ClickySettings.echoMode
        return currentSetting == .aec ? requestedEchoMode : currentSetting
    }
    /// The mic tap is on the hub's engine (AEC on), not ours.
    private var usesSharedAudioEngine = false

    private let audioEngine = AVAudioEngine()
    private let recognitionRequestBox = HandsFreeRecognitionRequestBox()
    private var speechRecognizer: SFSpeechRecognizer?
    private var activeRecognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var activeRecognitionTask: SFSpeechRecognitionTask?

    /// Incremented each time a new recognition task starts, so late callbacks
    /// from a task we already replaced are ignored.
    private var recognitionTaskGeneration = 0

    private var latestPartialTranscript = ""
    private var latestPartialTranscriptChangeDate = Date()
    private var utteranceEndCheckTimer: Timer?
    private(set) var isListening = false

    init(
        requestedEchoMode: ClickySettings.EchoMode = .open,
        audioEngineHub: AudioEngineHub? = nil,
        onPartialTranscript: @escaping (String) -> Void,
        onUtteranceFinished: @escaping (String) -> Void
    ) {
        self.requestedEchoMode = requestedEchoMode
        self.resolvedEchoMode = requestedEchoMode
        self.audioEngineHub = audioEngineHub
        self.onPartialTranscript = onPartialTranscript
        self.onUtteranceFinished = onUtteranceFinished
    }

    // MARK: - Lifecycle

    func startListening() async throws {
        guard !isListening else { return }

        // Without mic access AVAudioEngine still starts and just delivers
        // silence, so the session would look like it's listening but never
        // hear anything. Fail loudly instead.
        let isMicrophoneAuthorized = await Self.requestMicrophoneAuthorizationIfNeeded()
        guard isMicrophoneAuthorized else {
            throw HandsFreeListeningSessionError(message: "Microphone permission is off. Turn it on in System Settings > Privacy & Security > Microphone.")
        }

        let isSpeechRecognitionAuthorized = await Self.requestSpeechRecognitionAuthorizationIfNeeded()
        guard isSpeechRecognitionAuthorized else {
            throw HandsFreeListeningSessionError(message: "Speech recognition permission is off. Turn it on in System Settings > Privacy & Security > Speech Recognition.")
        }

        guard let speechRecognizer = SFSpeechRecognizer(locale: Locale.autoupdatingCurrent)
                ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US")),
              speechRecognizer.isAvailable else {
            throw HandsFreeListeningSessionError(message: "Speech recognition isn't available on this Mac right now.")
        }
        self.speechRecognizer = speechRecognizer

        startMicrophoneCapture()
        if !usesSharedAudioEngine {
            audioEngine.prepare()
            try audioEngine.start()
        }

        isListening = true
        startNewRecognitionTask()

        utteranceEndCheckTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.finishUtteranceIfUserWentQuiet()
            }
        }
        print("🎙️ Hands-free: listening (echo mode \(resolvedEchoMode.rawValue))")
    }

    /// "aec" → the hub's shared engine with voice processing (it starts the
    /// engine itself); otherwise, or when that resolves to open/halfDuplex,
    /// this session's own engine (started by the caller).
    private func startMicrophoneCapture() {
        let audioTapBlock = Self.makeAudioTapBlock(recognitionRequestBox: recognitionRequestBox)
        if requestedEchoMode == .aec, let audioEngineHub {
            let isHeadphoneRoute = AudioOutputRouteInspector.isDefaultOutputHeadphones()
            resolvedEchoMode = EchoCancellationPolicy.resolvedMode(
                requestedMode: .aec,
                isHeadphoneRoute: isHeadphoneRoute,
                enableVoiceProcessing: { _ = try audioEngineHub.startVoiceProcessingCapture(tapBlock: audioTapBlock) },
                log: { print("🎙️ Hands-free: \($0)") }
            )
            usesSharedAudioEngine = resolvedEchoMode == .aec
            if usesSharedAudioEngine { return }
        }
        installTapOnOwnAudioEngine(audioTapBlock: audioTapBlock)
    }

    private func installTapOnOwnAudioEngine(audioTapBlock: @escaping AVAudioNodeTapBlock) {
        let inputNode = audioEngine.inputNode

        // Echo cancellation: lets the mic stay open while the buddy talks
        // without transcribing its own voice. If the hardware doesn't support
        // it we keep going — CompanionManager also ignores non-command speech
        // while the buddy is talking. Some mic setups transcribe worse with it
        // on; turn it off with:
        //   defaults write com.personal.clicky handsFreeEchoCancellationDisabled -bool YES
        let isEchoCancellationDisabled = UserDefaults.standard.bool(forKey: "handsFreeEchoCancellationDisabled")
        if !isEchoCancellationDisabled {
            do {
                try inputNode.setVoiceProcessingEnabled(true)
                // Voice processing ducks other audio by default, which would make
                // music or videos go quiet for the whole session.
                inputNode.voiceProcessingOtherAudioDuckingConfiguration = AVAudioVoiceProcessingOtherAudioDuckingConfiguration(
                    enableAdvancedDucking: false,
                    duckingLevel: .min
                )
            } catch {
                print("⚠️ Hands-free: echo cancellation unavailable, continuing without it: \(error)")
            }
        }

        let inputFormat = inputNode.outputFormat(forBus: 0)
        // A tap with an empty format raises an Objective-C exception and kills the app.
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            print("⚠️ Hands-free: the mic has no usable format, not listening")
            return
        }
        print("🎙️ Hands-free: mic format \(inputFormat.sampleRate)Hz, \(inputFormat.channelCount) channel(s), echo cancellation \(inputNode.isVoiceProcessingEnabled ? "on" : "off")")
        inputNode.removeTap(onBus: 0)
        inputNode.installTap(
            onBus: 0,
            bufferSize: 1024,
            format: inputFormat,
            block: audioTapBlock
        )
    }

    func stopListening() {
        guard isListening else { return }
        isListening = false

        utteranceEndCheckTimer?.invalidate()
        utteranceEndCheckTimer = nil

        recognitionRequestBox.replaceActiveRecognitionRequest(with: nil)
        activeRecognitionRequest?.endAudio()
        activeRecognitionTask?.cancel()
        activeRecognitionRequest = nil
        activeRecognitionTask = nil

        if usesSharedAudioEngine {
            audioEngineHub?.stopVoiceProcessingCapture()
            usesSharedAudioEngine = false
        } else {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
            try? audioEngine.inputNode.setVoiceProcessingEnabled(false)
        }

        latestPartialTranscript = ""
        print("🎙️ Hands-free: stopped listening")
    }

    /// Drops whatever has been heard so far in the current utterance. Used
    /// after an instant command fires on a partial transcript, so the same
    /// words don't also get sent to Claude when the utterance finishes.
    func discardCurrentUtterance() {
        guard isListening else { return }
        latestPartialTranscript = ""
        startNewRecognitionTask()
    }

    // MARK: - Recognition

    private func startNewRecognitionTask() {
        guard isListening, let speechRecognizer else { return }

        recognitionTaskGeneration += 1
        let currentRecognitionTaskGeneration = recognitionTaskGeneration

        activeRecognitionRequest?.endAudio()
        activeRecognitionTask?.cancel()

        let newRecognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        newRecognitionRequest.shouldReportPartialResults = true
        newRecognitionRequest.taskHint = .dictation
        newRecognitionRequest.addsPunctuation = true
        if speechRecognizer.supportsOnDeviceRecognition {
            newRecognitionRequest.requiresOnDeviceRecognition = true
        }

        activeRecognitionRequest = newRecognitionRequest
        recognitionRequestBox.replaceActiveRecognitionRequest(with: newRecognitionRequest)

        activeRecognitionTask = speechRecognizer.recognitionTask(
            with: newRecognitionRequest,
            resultHandler: Self.makeRecognitionResultHandler(
                handsFreeListeningSession: self,
                recognitionTaskGeneration: currentRecognitionTaskGeneration
            )
        )
    }

    private func handleRecognitionUpdate(
        recognizedText: String?,
        isFinalResult: Bool,
        recognitionError: Error?,
        recognitionTaskGeneration resultTaskGeneration: Int
    ) {
        guard isListening, resultTaskGeneration == recognitionTaskGeneration else { return }

        if let recognizedText, recognizedText != latestPartialTranscript {
            latestPartialTranscript = recognizedText
            latestPartialTranscriptChangeDate = Date()
            onPartialTranscript(recognizedText)
        }

        if isFinalResult {
            finishCurrentUtterance()
            return
        }

        if let recognitionError {
            // "No speech detected" and similar errors happen routinely after
            // long silences. Deliver anything heard so far, then start fresh.
            print("🎙️ Hands-free: recognizer ended (\(recognitionError.localizedDescription)), restarting")
            if !latestPartialTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                finishCurrentUtterance()
            } else {
                Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    self?.startNewRecognitionTask()
                }
            }
        }
    }

    private func finishUtteranceIfUserWentQuiet() {
        guard isListening else { return }
        guard !latestPartialTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        let secondsSinceLastSpeech = Date().timeIntervalSince(latestPartialTranscriptChangeDate)
        if secondsSinceLastSpeech >= utteranceEndSilenceSeconds {
            finishCurrentUtterance()
        }
    }

    private func finishCurrentUtterance() {
        let finishedUtterance = latestPartialTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        latestPartialTranscript = ""
        startNewRecognitionTask()

        guard !finishedUtterance.isEmpty else { return }
        print("🗣️ Hands-free heard: \(finishedUtterance)")
        onUtteranceFinished(finishedUtterance)
    }

    // MARK: - Off-Main-Thread Callbacks

    /// Built in a nonisolated context because AVAudioEngine calls the tap on
    /// a realtime audio thread, not the main actor.
    private nonisolated static func makeAudioTapBlock(
        recognitionRequestBox: HandsFreeRecognitionRequestBox
    ) -> AVAudioNodeTapBlock {
        return { audioBuffer, _ in
            recognitionRequestBox.appendAudioBuffer(audioBuffer)
        }
    }

    /// Speech calls this on a background queue. We pull out the plain values
    /// there and hop to the main actor with them.
    private nonisolated static func makeRecognitionResultHandler(
        handsFreeListeningSession: HandsFreeListeningSession,
        recognitionTaskGeneration: Int
    ) -> (SFSpeechRecognitionResult?, Error?) -> Void {
        return { [weak handsFreeListeningSession] recognitionResult, recognitionError in
            guard let handsFreeListeningSession else { return }
            let recognizedText = recognitionResult?.bestTranscription.formattedString
            let isFinalResult = recognitionResult?.isFinal ?? false
            Task { @MainActor in
                handsFreeListeningSession.handleRecognitionUpdate(
                    recognizedText: recognizedText,
                    isFinalResult: isFinalResult,
                    recognitionError: recognitionError,
                    recognitionTaskGeneration: recognitionTaskGeneration
                )
            }
        }
    }

    private static func requestMicrophoneAuthorizationIfNeeded() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        default:
            return false
        }
    }

    private static func requestSpeechRecognitionAuthorizationIfNeeded() async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { authorizationStatus in
                    continuation.resume(returning: authorizationStatus == .authorized)
                }
            }
        default:
            return false
        }
    }
}
