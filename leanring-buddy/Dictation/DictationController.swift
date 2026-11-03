//
//  DictationController.swift
//  leanring-buddy
//
//  System-wide dictation, like Wispr Flow: hold the chord (Control + Fn by default) in any app, talk, let go, and the
//  tidied-up words are typed where the cursor is.
//
//    keys down   the mic opens, the pill shows a live waveform, a Haiku process is made ready if none is
//    keys up     the words: Sarvam when its key is saved, else Apple on this Mac, and Apple's result if Sarvam fails
//    clean-up    the instant local pass, then Haiku if it's quick enough. If it isn't, the raw words go in, and
//                Haiku's version replaces them when it lands if the field hasn't moved on
//    insert      Accessibility first (no clipboard, no focus change), else clipboard and Paste, clipboard put back
//
//  It stays out of Clicky's way: Clicky's push-to-talk is Control + Option, and the wake listener yields the mic while
//  this holds it. The test profile has no mic or key tap: `dictationFeed` runs a sound file through the same path.
//

import AppKit
import AVFoundation
import ClickyCore
import Combine
import Speech

enum DictationSettings {
    static let enabledKey = "v2.dictation.enabled"
    static let shortcutKey = "v2.dictation.shortcut"
    static let engineKey = "v2.dictation.engine"
    static let cleanupKey = "v2.dictation.cleanup"
    static let languageKey = "v2.dictation.language"
    static let dictionaryKey = "v2.dictation.dictionary"

    enum Engine: String, CaseIterable, Identifiable {
        case automatic, sarvam, apple
        var id: String { rawValue }
    }

    /// The languages it can be told to expect. "auto" lets Sarvam work it out and Apple use this Mac's language.
    static let languages: [(id: String, title: String, sarvam: String, apple: String?)] = [
        ("auto", "Detect it", "unknown", nil),
        ("hinglish", "Hinglish", "hi-IN", "en-IN"),
        ("en-IN", "English (India)", "en-IN", "en-IN"),
        ("en-US", "English (US)", "en-IN", "en-US"),
        ("hi-IN", "Hindi", "hi-IN", "hi-IN"),
        ("bn-IN", "Bengali", "bn-IN", nil), ("gu-IN", "Gujarati", "gu-IN", nil), ("kn-IN", "Kannada", "kn-IN", nil),
        ("ml-IN", "Malayalam", "ml-IN", nil), ("mr-IN", "Marathi", "mr-IN", nil), ("od-IN", "Odia", "od-IN", nil),
        ("pa-IN", "Punjabi", "pa-IN", nil), ("ta-IN", "Tamil", "ta-IN", nil), ("te-IN", "Telugu", "te-IN", nil),
    ]

    static var isEnabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
    static var shortcut: DictationShortcut { UserDefaults.standard.string(forKey: shortcutKey).flatMap(DictationShortcut.init(rawValue:)) ?? .controlFn }
    static var engine: Engine { UserDefaults.standard.string(forKey: engineKey).flatMap(Engine.init(rawValue:)) ?? .automatic }
    static var usesCleanup: Bool { UserDefaults.standard.object(forKey: cleanupKey) as? Bool ?? true }
    static var language: String { UserDefaults.standard.string(forKey: languageKey) ?? "auto" }
    static var dictionaryLines: [String] {
        (UserDefaults.standard.string(forKey: dictionaryKey) ?? "").components(separatedBy: .newlines)
    }
    static var dictionary: DictationDictionary { DictationDictionary(lines: dictionaryLines) }

    /// Which service listens now: Sarvam needs its key; anything else is Apple on this Mac.
    static var usesSarvam: Bool { engine != .apple && ProviderKeychain.get("sarvam") != nil }

    static var currentLanguage: (id: String, title: String, sarvam: String, apple: String?) {
        languages.first { $0.id == language } ?? languages[0]
    }
}

/// Watches for the chord through a listen-only event tap. Nothing is swallowed, so the keys still do what they did.
@MainActor
final class DictationKeys {
    let transitions = PassthroughSubject<DictationChordDetector.Transition, Never>()

    private var detector = DictationChordDetector(required: DictationSettings.shortcut.modifiers)
    private var tap: CFMachPort?
    private var tapSource: CFRunLoopSource?

    var isRunning: Bool { tap != nil }

    func useCurrentShortcut() {
        detector = DictationChordDetector(required: DictationSettings.shortcut.modifiers)
    }

    func start() {
        guard tap == nil, !TheoProfile.isTest else { return }
        let mask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let keys = Unmanaged<DictationKeys>.fromOpaque(userInfo).takeUnretainedValue()
            MainActor.assumeIsolated { keys.handle(type: type, event: event) }
            return Unmanaged.passUnretained(event)
        }
        guard let newTap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
                                             eventsOfInterest: CGEventMask(mask), callback: callback,
                                             userInfo: Unmanaged.passUnretained(self).toOpaque()),
              let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, newTap, 0) else {
            print("⚠️ Dictation: the keyboard listener couldn't start (Accessibility?)")
            return
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: newTap, enable: true)
        tap = newTap
        tapSource = source
    }

    func stop() {
        if let tapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), tapSource, .commonModes) }
        if let tap { CFMachPortInvalidate(tap) }
        tap = nil
        tapSource = nil
        useCurrentShortcut()
    }

    private func handle(type: CGEventType, event: CGEvent) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        case .keyDown:
            if let transition = detector.keyDown() { transitions.send(transition) }
        case .flagsChanged:
            if let transition = detector.flagsChanged(Self.modifiers(of: event.flags)) { transitions.send(transition) }
        default:
            break
        }
    }

    static func modifiers(of flags: CGEventFlags) -> ChordModifiers {
        var modifiers: ChordModifiers = []
        if flags.contains(.maskControl) { modifiers.insert(.control) }
        if flags.contains(.maskAlternate) { modifiers.insert(.option) }
        if flags.contains(.maskShift) { modifiers.insert(.shift) }
        if flags.contains(.maskCommand) { modifiers.insert(.command) }
        if flags.contains(.maskSecondaryFn) { modifiers.insert(.function) }
        return modifiers
    }
}

/// The audio of one dictation: Apple's recognizer listens along for a result that never needs the network, and the
/// tape keeps the words for Sarvam.
@MainActor
final class DictationCapture {
    private let engine = AVAudioEngine()
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var appleFinished: CheckedContinuation<Void, Never>?
    private(set) var appleText = ""
    private(set) var appleError: String?
    private var hasTap = false
    /// For tests: behaves as a Mac with no usable mic, with nothing opened.
    var pretendsNoUsableMicrophone = false
    let tape = DictationTape()
    var onLevel: ((CGFloat) -> Void)?
    /// The recognizer's words so far, each time they change.
    var onWords: ((String) -> Void)?

    /// Starts Apple's recognizer, on this Mac when it can. False when it isn't allowed or has no such language.
    @discardableResult
    func startRecognizer(localeIdentifier: String?, phrases: [String]) -> Bool {
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else {
            appleError = "Speech recognition isn't allowed"
            return false
        }
        let recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeIdentifier ?? Locale.current.identifier)) ?? SFSpeechRecognizer()
        guard let recognizer, recognizer.isAvailable else {
            appleError = "No recognizer for this language"
            return false
        }
        self.recognizer = recognizer
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.contextualStrings = Array(phrases.prefix(50))
        request.addsPunctuation = true
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
        self.request = request
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let failure = error?.localizedDescription
            Task { @MainActor in
                guard let self else { return }
                if let text, !text.isEmpty {
                    self.appleText = text
                    self.onWords?(text)
                }
                if let failure { self.appleError = failure }
                if isFinal || failure != nil { self.finishApple() }
            }
        }
        return true
    }

    private func finishApple() {
        appleFinished?.resume()
        appleFinished = nil
    }

    /// Opens the microphone. With no usable mic it throws before touching a tap: a tap on an empty format raises an
    /// Objective-C exception, and the app crashes seconds later.
    func startMicrophone() throws {
        guard !pretendsNoUsableMicrophone, engine.inputNode.hasUsableMicFormat else { throw DictationMicError.noUsableMicrophone }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        hasTap = true
        let request = self.request
        let tape = self.tape
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            request?.append(buffer)
            tape.append(buffer)
            let level = DictationTape.level(of: buffer)
            Task { @MainActor in self?.onLevel?(level) }
        }
        engine.prepare()
        try engine.start()
    }

    private func closeMicrophone() {
        guard hasTap else { return }
        hasTap = false
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
    }

    /// Takes one buffer from a test file, in place of the mic.
    func feed(_ buffer: AVAudioPCMBuffer) {
        request?.append(buffer)
        tape.append(buffer)
        onLevel?(DictationTape.level(of: buffer))
    }

    /// The mic closes; Apple gets a moment to finish its last words.
    func finish() async {
        closeMicrophone()
        guard let request else { return }
        request.endAudio()
        await withTaskGroup(of: Void.self) { group in
            group.addTask { @MainActor in
                await withCheckedContinuation { continuation in
                    if self.task == nil { continuation.resume() } else { self.appleFinished = continuation }
                }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 1_100_000_000)
                await MainActor.run { self.finishApple() }
            }
            // Whichever comes first: Apple's last words or the time limit.
            await group.next()
            group.cancelAll()
        }
        task?.cancel()
        task = nil
        self.request = nil
    }

    func cancel() {
        closeMicrophone()
        task?.cancel()
        task = nil
        request = nil
        finishApple()
    }
}

/// The dictated audio as 16 kHz mono samples, and cut to Sarvam's 30 s limit when it runs long. Fed from the audio thread.
final class DictationTape: @unchecked Sendable {
    private let tape = PushToTalkAudioTape()
    var isEmpty: Bool { tape.isEmpty }

    func append(_ buffer: AVAudioPCMBuffer) { tape.append(buffer) }

    /// WAV files of at most `maxSeconds` each.
    func wavChunks(maxSeconds: Int = 28) -> [Data] {
        let samples = tape.pcm16
        let chunkBytes = maxSeconds * PushToTalkAudioTape.sampleRate * 2
        guard samples.count > chunkBytes else { return [CloudListening.wavFile(pcm16: samples, sampleRate: PushToTalkAudioTape.sampleRate)] }
        return stride(from: 0, to: samples.count, by: chunkBytes).map { start in
            let end = min(start + chunkBytes, samples.count)
            return CloudListening.wavFile(pcm16: samples.subdata(in: start..<end), sampleRate: PushToTalkAudioTape.sampleRate)
        }
    }

    /// RMS of the first channel on a decibel scale, mapped to 0…1 for the waveform.
    nonisolated static func level(of buffer: AVAudioPCMBuffer) -> CGFloat {
        guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        var sum: Float = 0
        for index in 0..<Int(buffer.frameLength) { sum += samples[index] * samples[index] }
        let rms = sqrt(sum / Float(buffer.frameLength))
        let decibels = 20 * log10(max(rms, 0.000_01))
        return CGFloat(min(max((decibels + 55) / 45, 0), 1))
    }
}

/// Whichever comes first gets to resume.
final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false
    func claim() -> Bool {
        lock.withLock {
            guard !claimed else { return false }
            claimed = true
            return true
        }
    }
}

@MainActor
final class DictationController: ObservableObject {
    enum Phase: Equatable {
        case idle
        case listening
        case transcribing
        case typed
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    /// The last few levels, newest last, for the waveform.
    @Published private(set) var levels: [CGFloat] = Array(repeating: 0, count: DictationController.levelCount)
    static let levelCount = 18

    /// How long the words wait for Haiku before going in as they are.
    static let cleanupBudgetSeconds: TimeInterval = 1.8

    let keys = DictationKeys()
    private let hub: AudioEngineHub
    private let speech: CompanionSpeechOutput
    /// One Haiku process kept open between dictations, so all but the first skip its start-up (about 1 s to its first words).
    private var cleaner: ClaudeConversation?
    private var cleanerPrompt = ""
    private var cleanerTurns = 0
    private var cleanerIdle: Task<Void, Never>?
    private static let cleanerIdleSeconds: UInt64 = 300
    private static let cleanerMaxTurns = 30
    private(set) lazy var pill = DictationPillController(controller: self)
    private var capture: DictationCapture?
    private var pressedAt = Date()
    private var keysCancellable: AnyCancellable?
    private var hideTask: Task<Void, Never>?
    private var session = UUID()
    /// What the last dictation did, for `dictationStatus`. Never the words.
    private(set) var lastReport: [String: Any] = [:]
    /// Something else needs the mic (a call): the chord does nothing.
    var isBlocked: () -> Bool = { false }

    init(hub: AudioEngineHub, speech: CompanionSpeechOutput) {
        self.hub = hub
        self.speech = speech
        keysCancellable = keys.transitions.receive(on: DispatchQueue.main).sink { [weak self] transition in
            switch transition {
            case .pressed: self?.keysPressed()
            case .released: self?.keysReleased()
            case .cancelled: self?.keysCancelled()
            }
        }
    }

    // MARK: Keys

    /// Follows the permission and the setting; called whenever either may have changed.
    func refresh(accessibilityGranted: Bool) {
        if accessibilityGranted && DictationSettings.isEnabled { keys.start() } else { keys.stop() }
    }

    private func keysPressed() {
        guard !isBlocked(), capture == nil, !ComposerDictation.shared.isActive else { return }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            showFailure("Theo needs the microphone")
            return
        }
        hideTask?.cancel()
        pressedAt = Date()
        session = UUID()
        let capture = DictationCapture()
        capture.onLevel = { [weak self] level in self?.noteLevel(level) }
        capture.startRecognizer(localeIdentifier: DictationSettings.currentLanguage.apple, phrases: Self.expectedPhrases())
        self.capture = capture
        hub.claimMicrophone(for: .dictation)
        // Clicky talking over the dictation would end up in it.
        speech.stopVoicesNow()
        phase = .listening
        levels = Array(repeating: 0, count: Self.levelCount)
        pill.show()
        warmCleaner()
        do {
            try capture.startMicrophone()
        } catch {
            hub.releaseMicrophone(for: .dictation)
            capture.cancel()
            self.capture = nil
            showFailure(error is DictationMicError ? "No usable microphone" : "The microphone didn't start")
        }
    }

    private func keysReleased() {
        guard let capture else { return }
        // Just brushed the keys.
        if Date().timeIntervalSince(pressedAt) < DictationHoldPolicy.minimumSeconds { keysCancelled(); return }
        self.capture = nil
        hub.releaseMicrophone(for: .dictation)
        let session = self.session
        Task { @MainActor [weak self] in
            await self?.finish(capture, target: .frontmost, session: session)
        }
    }

    private func keysCancelled() {
        guard let capture else { return }
        self.capture = nil
        capture.cancel()
        hub.releaseMicrophone(for: .dictation)
        stopCleanerWhenIdle()
        phase = .idle
        pill.hide()
    }

    private static func expectedPhrases() -> [String] {
        ["Theo", "Clicky", "Claude", "Sarvam"] + DictationSettings.dictionary.words
    }

    private func noteLevel(_ level: CGFloat) {
        guard phase == .listening else { return }
        levels = Array(levels.dropFirst()) + [level]
    }

    private func warmCleaner() {
        guard DictationSettings.usesCleanup else {
            stopCleaner()
            return
        }
        cleanerIdle?.cancel()
        let prompt = DictationCleanup.systemPrompt(dictionary: DictationSettings.dictionary)
        if cleaner?.isRunning == true, prompt == cleanerPrompt, cleanerTurns < Self.cleanerMaxTurns { return }
        stopCleaner()
        let conversation = ClaudeConversation(model: ClickyModels.haiku, systemPrompt: prompt, promptFileName: DictationCleanup.systemPromptFileName)
        conversation.onEnded = { [weak self] _ in self?.cleaner = nil }
        do {
            try conversation.start()
            cleaner = conversation
            cleanerPrompt = prompt
            cleanerTurns = 0
        } catch {
            print("⚠️ Dictation: Haiku didn't start: \(error.localizedDescription)")
        }
    }

    private func stopCleaner() {
        cleanerIdle?.cancel()
        cleaner?.stop()
        cleaner = nil
    }

    private func stopCleanerWhenIdle() {
        cleanerIdle?.cancel()
        cleanerIdle = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.cleanerIdleSeconds * 1_000_000_000)
            guard !Task.isCancelled else { return }
            self?.stopCleaner()
        }
    }

    private func showFailure(_ message: String) {
        phase = .failed(message)
        pill.show()
        hideSoon(after: 1.6)
    }

    private func hideSoon(after seconds: TimeInterval) {
        hideTask?.cancel()
        hideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.phase = .idle
            self?.pill.hide()
        }
    }

    // MARK: From words to text

    private func finish(_ capture: DictationCapture, target: DictationInserter.Target, session: UUID) async {
        let started = Date()
        phase = .transcribing
        // Someone is waiting: no App Nap or timer coalescing while Theo sits in the background.
        let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical], reason: "Dictation")
        defer { ProcessInfo.processInfo.endActivity(activity) }
        await capture.finish()
        let appleSeconds = Date().timeIntervalSince(started)
        let appleText = capture.appleText.trimmingCharacters(in: .whitespacesAndNewlines)

        var engine = "apple"
        var words = appleText
        var engineProblem = capture.appleError
        if DictationSettings.usesSarvam, !capture.tape.isEmpty {
            do {
                let sarvamWords = try await sarvamTranscript(of: capture.tape)
                if !sarvamWords.isEmpty {
                    words = sarvamWords
                    engine = "sarvam"
                    engineProblem = nil
                }
            } catch {
                // What Apple heard goes in instead, so a failed call never loses the dictation.
                engineProblem = error.localizedDescription
                print("⚠️ Dictation: Sarvam failed, using Apple's words: \(error.localizedDescription)")
            }
        }
        let heardSeconds = Date().timeIntervalSince(started)
        defer { stopCleanerWhenIdle() }
        guard !words.isEmpty else {
            lastReport = ["engine": engine, "heard": false, "problem": engineProblem ?? "", "appleSeconds": appleSeconds]
            showFailure("Didn't catch that")
            return
        }

        let dictionary = DictationSettings.dictionary
        let raw = DictationCleanup.localPass(words, dictionary: dictionary)
        var text = raw
        var cleanupNote = "off"
        var lateCleanup: Task<String?, Never>?
        if DictationSettings.usesCleanup, DictationCleanup.needsModelPass(raw) {
            let cleanupStart = Date()
            let cleaning = cleanupTask(for: raw)
            if let cleaned = await Self.value(of: cleaning, within: Self.cleanupBudgetSeconds) {
                if let cleaned { text = cleaned; cleanupNote = "haiku" } else { cleanupNote = "kept raw" }
            } else {
                // Slow: the raw words go in now and Haiku's version follows if the field is still as we left it.
                cleanupNote = "late"
                lateCleanup = cleaning
            }
            lastCleanupSeconds = Date().timeIntervalSince(cleanupStart)
        }
        guard self.session == session else { return }
        let outcome = await DictationInserter.insert(text, into: target)
        let totalSeconds = Date().timeIntervalSince(started)
        lastReport = ["engine": engine, "heard": true, "appleSeconds": appleSeconds, "heardSeconds": heardSeconds,
                      "cleanup": cleanupNote, "cleanupSeconds": lastCleanupSeconds, "cleanupModelSeconds": lastCleanupModelSeconds, "totalSeconds": totalSeconds,
                      "method": outcome.method, "inserted": outcome.didInsert, "problem": engineProblem ?? "",
                      "characters": text.count]
        if !outcome.didInsert {
            showFailure(outcome.message ?? "Couldn't type there")
            return
        }
        phase = .typed
        hideSoon(after: 0.7)
        if let lateCleanup {
            Task { @MainActor [weak self] in
                let cleaned = await lateCleanup.value
                self?.lastReport["cleanupModelSeconds"] = self?.lastCleanupModelSeconds ?? 0
                guard let cleaned else { return }
                let replaced = DictationInserter.replace(text, with: cleaned, target: outcome.element)
                self?.lastReport["cleanup"] = replaced ? "haiku, replaced late" : "too late, kept raw"
            }
        }
    }

    private var lastCleanupSeconds: TimeInterval = 0
    private var lastCleanupModelSeconds: TimeInterval = 0

    private func cleanupTask(for text: String) -> Task<String?, Never> {
        warmCleaner()
        guard let cleaner else { return Task { nil } }
        cleanerTurns += 1
        return Task { @MainActor in
            let reply: String? = await withCheckedContinuation { continuation in
                let sent = Date()
                cleaner.send(DictationCleanup.userMessage(text), onDelta: { _ in }, onDone: { [weak self] result in
                    self?.lastCleanupModelSeconds = Date().timeIntervalSince(sent)
                    continuation.resume(returning: try? result.get())
                })
            }
            return reply.flatMap { DictationCleanup.accept(reply: $0, for: text) }
        }
    }

    /// The task's result, or nil if it wasn't ready in time (it keeps running, for a late swap).
    private static func value(of task: Task<String?, Never>, within seconds: TimeInterval) async -> String?? {
        await withCheckedContinuation { (continuation: CheckedContinuation<String??, Never>) in
            let once = ResumeOnce()
            Task { @MainActor in
                let value = await task.value
                if once.claim() { continuation.resume(returning: .some(value)) }
            }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                if once.claim() { continuation.resume(returning: nil) }
            }
        }
    }

    private func sarvamTranscript(of tape: DictationTape, language: (id: String, title: String, sarvam: String, apple: String?) = DictationSettings.currentLanguage) async throws -> String {
        guard let client = SarvamClient.fromKeychain() else { throw SarvamError.missingKey }
        // Hinglish needs its own mode: Hindi and English each stay in their own words.
        let mode: SarvamClient.STTMode = language.id == "hinglish" || language.id == "auto" ? .codemix : .transcribe
        let keyterms = DictationSettings.dictionary.words
        var pieces: [String] = []
        for chunk in tape.wavChunks() {
            let result = try await client.transcribe(audio: chunk, mode: mode, languageCode: language.sarvam, keyterms: keyterms)
            pieces.append(result.transcript)
        }
        return pieces.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: The composer

    var isCapturing: Bool { capture != nil }

    func warmCleanerForComposer() { warmCleaner() }

    /// The composer's final words: Sarvam if it's in use (what Apple heard if that fails), then the same clean-up as the
    /// chord. A slow clean-up doesn't hold the words back.
    func composerWords(heard: String, tape: DictationTape, language: (id: String, title: String, sarvam: String, apple: String?)) async -> String {
        defer { stopCleanerWhenIdle() }
        var words = heard
        if DictationSettings.usesSarvam, !tape.isEmpty {
            do {
                let sarvamWords = try await sarvamTranscript(of: tape, language: language)
                if !sarvamWords.isEmpty { words = sarvamWords }
            } catch {
                print("⚠️ Dictation: Sarvam failed, using Apple's words: \(error.localizedDescription)")
            }
        }
        words = words.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else { return "" }
        let raw = DictationCleanup.localPass(words, dictionary: DictationSettings.dictionary)
        guard DictationSettings.usesCleanup, DictationCleanup.needsModelPass(raw) else { return raw }
        if let cleaned = await Self.value(of: cleanupTask(for: raw), within: Self.cleanupBudgetSeconds), let cleaned { return cleaned }
        return raw
    }

    // MARK: Test files

    /// `dictationFeed`: a sound file through the whole path as if it were held and let go, typed into the given target.
    func feed(fileURL: URL, target: DictationInserter.Target, realTime: Bool) async -> (ok: Bool, result: [String: Any], error: String?) {
        guard let file = try? AVAudioFile(forReading: fileURL) else { return (false, [:], "Can't read that file") }
        hideTask?.cancel()
        session = UUID()
        let capture = DictationCapture()
        capture.onLevel = { [weak self] level in self?.noteLevel(level) }
        capture.startRecognizer(localeIdentifier: DictationSettings.currentLanguage.apple, phrases: Self.expectedPhrases())
        phase = .listening
        levels = Array(repeating: 0, count: Self.levelCount)
        pill.show()
        warmCleaner()
        let blockFrames = AVAudioFrameCount(file.processingFormat.sampleRate * 0.05)
        while file.framePosition < file.length {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: blockFrames), (try? file.read(into: buffer, frameCount: blockFrames)) != nil, buffer.frameLength > 0 else { break }
            capture.feed(buffer)
            if realTime { try? await Task.sleep(nanoseconds: 50_000_000) } else { await Task.yield() }
        }
        await finish(capture, target: target, session: session)
        return (true, statusReport(), nil)
    }

    /// `uiDictationPill`: the pill in a given state, for a screenshot of it.
    func showForTest(state: String) {
        hideTask?.cancel()
        switch state {
        case "listening":
            phase = .listening
            levels = (0..<Self.levelCount).map { index in 0.15 + 0.75 * abs(sin(CGFloat(index) * 0.7)) * CGFloat(index + 4) / CGFloat(Self.levelCount + 4) }
        case "transcribing": phase = .transcribing
        case "typed": phase = .typed
        case "failed": phase = .failed("Didn't catch that")
        default:
            phase = .idle
            pill.hide()
            return
        }
        pill.show()
    }

    /// What `dictationStatus` shows; never the words.
    func statusReport() -> [String: Any] {
        var report = lastReport
        report["phase"] = String(describing: phase)
        report["enabled"] = DictationSettings.isEnabled
        report["shortcut"] = DictationSettings.shortcut.rawValue
        report["usesSarvam"] = DictationSettings.usesSarvam
        report["usesCleanup"] = DictationSettings.usesCleanup
        report["keyTap"] = keys.isRunning
        report["accessibility"] = AXIsProcessTrusted()
        report["speechAuthorized"] = SFSpeechRecognizer.authorizationStatus() == .authorized
        report["globeKeyAction"] = Self.globeKeyAction.rawValue
        return report
    }

    /// What this Mac does when Fn / Globe is pressed alone (System Settings › Keyboard).
    enum GlobeKeyAction: Int {
        case nothing = 0, inputSource = 1, emoji = 2, dictation = 3
        var sentence: String? {
            switch self {
            case .nothing: return nil
            case .inputSource: return "This Mac's Globe key changes the input source."
            case .emoji: return "This Mac's Globe key opens Emoji & Symbols."
            case .dictation: return "This Mac's Globe key starts Apple's own Dictation."
            }
        }
    }

    static var globeKeyAction: GlobeKeyAction {
        let stored = UserDefaults(suiteName: "com.apple.HIToolbox")?.object(forKey: "AppleFnUsageType") as? Int
        return GlobeKeyAction(rawValue: stored ?? 1) ?? .inputSource
    }
}
