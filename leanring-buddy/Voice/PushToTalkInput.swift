//
//  PushToTalkInput.swift
//  leanring-buddy
//
//  Theo's push-to-talk: hold Control + Option, talk, let go. Two parts:
//  PushToTalkKeys watches the keyboard through a listen-only event tap
//  (it reports press / release of the two modifiers, and Esc), and
//  PushToTalkRecorder records the microphone with AVAudioEngine and turns it
//  into text with Apple's speech recognizer, on this Mac when it can. The
//  recognizer's last result is handed over once the keys are released and
//  it has finished (or after a short wait, whichever comes first).
//

import AppKit
import AVFoundation
import ClickyCore
import Combine
import Speech

/// What the keys just did.
enum PushToTalkTransition: Equatable {
    case pressed
    case released
    case none
}

/// Watches for Control + Option held together (and nothing else), plus Esc.
@MainActor
final class PushToTalkKeys {
    static let displayText = "ctrl + option"
    static let keyCapLabels = ["ctrl", "option"]

    let transitions = PassthroughSubject<PushToTalkTransition, Never>()
    let escapePressed = PassthroughSubject<Void, Never>()

    private var tap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    private var isHeld = false

    private static let escapeKeyCode: Int64 = 53
    private static let wantedFlags: CGEventFlags = [.maskControl, .maskAlternate]
    private static let otherFlags: CGEventFlags = [.maskShift, .maskCommand, .maskSecondaryFn]

    func start() {
        guard tap == nil else { return }
        let mask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let keys = Unmanaged<PushToTalkKeys>.fromOpaque(userInfo).takeUnretainedValue()
            MainActor.assumeIsolated { keys.handle(type: type, event: event) }
            return Unmanaged.passUnretained(event)
        }
        guard let newTap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
                                             eventsOfInterest: CGEventMask(mask), callback: callback,
                                             userInfo: Unmanaged.passUnretained(self).toOpaque()),
              let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, newTap, 0) else {
            print("⚠️ Push-to-talk: the keyboard listener couldn't start (Accessibility?)")
            return
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: newTap, enable: true)
        tap = newTap
        tapSource = source
    }

    func stop() {
        if isHeld { isHeld = false }
        if let tapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), tapSource, .commonModes) }
        if let tap { CFMachPortInvalidate(tap) }
        tap = nil
        tapSource = nil
    }

    private func handle(type: CGEventType, event: CGEvent) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        case .keyDown:
            if event.getIntegerValueField(.keyboardEventKeycode) == Self.escapeKeyCode { escapePressed.send() }
            // Typing a letter while holding the two keys means it's a shortcut, not talking.
            if isHeld { release() }
        case .flagsChanged:
            let flags = event.flags
            let bothDown = flags.contains(Self.wantedFlags) && flags.intersection(Self.otherFlags).isEmpty
            if bothDown && !isHeld {
                isHeld = true
                transitions.send(.pressed)
            } else if !bothDown && isHeld {
                release()
            }
        default:
            break
        }
    }

    private func release() {
        isHeld = false
        transitions.send(.released)
    }
}

/// Records while the keys are held and returns the words.
@MainActor
final class PushToTalkRecorder: ObservableObject {
    @Published private(set) var isRecordingFromKeyboardShortcut = false
    @Published private(set) var isFinalizingTranscript = false
    @Published private(set) var isPreparingToRecord = false
    /// 0…1, smoothed, for the waveform.
    @Published private(set) var currentAudioPowerLevel: CGFloat = 0
    @Published private(set) var transcriptionProviderDisplayName = "Apple Speech (on this Mac)"

    var isDictationInProgress: Bool { isPreparingToRecord || isRecordingFromKeyboardShortcut || isFinalizingTranscript }

    /// Names and words the recognizer should expect.
    var expectedPhrases: [String] = ["Theo", "Claude", "T3 Code", "Codex", "whiteboard", "flowchart"]

    private let engine = AVAudioEngine()
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var latestText = ""
    private var deliver: ((String) -> Void)?
    private var finishTimer: Task<Void, Never>?
    private var sessionID = UUID()

    /// Starts recording; `submitDraftText` gets the words after the keys come up.
    func startPushToTalkFromKeyboardShortcut(currentDraftText: String,
                                             updateDraftText: @escaping (String) -> Void,
                                             submitDraftText: @escaping (String) -> Void) async {
        guard !isDictationInProgress else { return }
        isPreparingToRecord = true
        let mySession = UUID()
        sessionID = mySession

        guard await Self.ensurePermissions() else {
            isPreparingToRecord = false
            print("⚠️ Push-to-talk: microphone or speech recognition isn't allowed")
            return
        }
        guard sessionID == mySession, !Task.isCancelled else {
            isPreparingToRecord = false
            return
        }

        let localeIdentifier: String
        if case .fixed(let identifier) = ClickySettings.wakeLocaleSetting { localeIdentifier = identifier } else { localeIdentifier = Locale.current.identifier }
        let recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeIdentifier)) ?? SFSpeechRecognizer()
        guard let recognizer, recognizer.isAvailable else {
            isPreparingToRecord = false
            print("⚠️ Push-to-talk: speech recognition isn't available right now")
            return
        }
        self.recognizer = recognizer
        transcriptionProviderDisplayName = recognizer.supportsOnDeviceRecognition ? "Apple Speech (on this Mac)" : "Apple Speech"

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.contextualStrings = expectedPhrases + [ClickySettings.assistantName]
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
        self.request = request
        latestText = ""
        deliver = submitDraftText

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            Task { @MainActor in
                guard let self, self.sessionID == mySession else { return }
                if let text, !text.isEmpty {
                    self.latestText = text
                    updateDraftText(text)
                }
                if isFinal || error != nil, self.isFinalizingTranscript { self.finish() }
            }
        }

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            request.append(buffer)
            let level = Self.level(of: buffer)
            Task { @MainActor in
                guard let self else { return }
                self.currentAudioPowerLevel = self.currentAudioPowerLevel * 0.6 + level * 0.4
            }
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            reset()
            print("⚠️ Push-to-talk: the microphone didn't start: \(error.localizedDescription)")
            return
        }
        PushToTalkInputDeviceRecord.record(AudioInputDeviceInfo.current(of: input.audioUnit) ?? AudioInputDeviceInfo.defaultInput())
        isPreparingToRecord = false
        isRecordingFromKeyboardShortcut = true
    }

    /// The keys came up: stop the mic and wait (briefly) for the final words.
    func stopPushToTalkFromKeyboardShortcut() {
        guard isRecordingFromKeyboardShortcut || isPreparingToRecord else { return }
        if isPreparingToRecord && !isRecordingFromKeyboardShortcut {
            // Released before the mic opened: nothing was said.
            sessionID = UUID()
            reset()
            return
        }
        stopEngine()
        isRecordingFromKeyboardShortcut = false
        isFinalizingTranscript = true
        request?.endAudio()
        finishTimer?.cancel()
        finishTimer = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            guard !Task.isCancelled else { return }
            self?.finish()
        }
    }

    func cancelCurrentDictation(preserveDraftText: Bool = true) {
        sessionID = UUID()
        deliver = nil
        stopEngine()
        task?.cancel()
        reset()
    }

    private func finish() {
        guard isFinalizingTranscript else { return }
        finishTimer?.cancel()
        let text = latestText.trimmingCharacters(in: .whitespacesAndNewlines)
        let deliver = self.deliver
        task?.cancel()
        reset()
        if !text.isEmpty { deliver?(text) }
    }

    private func stopEngine() {
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
    }

    private func reset() {
        isPreparingToRecord = false
        isRecordingFromKeyboardShortcut = false
        isFinalizingTranscript = false
        currentAudioPowerLevel = 0
        request = nil
        task = nil
        deliver = nil
        finishTimer = nil
    }

    /// Root-mean-square of the first channel, mapped to 0…1 on a decibel scale.
    nonisolated private static func level(of buffer: AVAudioPCMBuffer) -> CGFloat {
        guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        var sum: Float = 0
        for index in 0..<Int(buffer.frameLength) { sum += samples[index] * samples[index] }
        let rms = sqrt(sum / Float(buffer.frameLength))
        let decibels = 20 * log10(max(rms, 0.000_01))
        return CGFloat(min(max((decibels + 55) / 50, 0), 1))
    }

    private static func ensurePermissions() async -> Bool {
        var microphone = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            microphone = await AVCaptureDevice.requestAccess(for: .audio)
        }
        var speech = SFSpeechRecognizer.authorizationStatus() == .authorized
        if SFSpeechRecognizer.authorizationStatus() == .notDetermined {
            speech = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
            }
        }
        return microphone && speech
    }
}
