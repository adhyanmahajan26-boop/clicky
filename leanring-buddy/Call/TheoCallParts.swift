//
//  TheoCallParts.swift
//  leanring-buddy
//
//  What a call is made of besides the sound: its brain, its ears and its voices.
//
//  The brain is one `claude -p` process kept open for the whole call. Each turn is one line on its stdin, so after the
//  first turn there is no start-up at all (first words in about a second), and an interrupt stops it at once and keeps the
//  conversation.
//
//  Ears: Sarvam's realtime socket, then its standard socket if realtime is refused, then Apple on this Mac. Voices: Sarvam's
//  socket, sentence by sentence, then Apple's voices rendered to samples. Either way what plays goes through CallAudio.
//

import AVFoundation
import ClickyCore
import Foundation
import Speech

// MARK: - Brain

/// One Claude conversation in one long-lived process.
@MainActor
final class ClaudeConversation {
    private final class Turn {
        let onDelta: (String) -> Void
        let onDone: (Result<String, Error>) -> Void
        var text = ""
        var isCancelled = false
        init(onDelta: @escaping (String) -> Void, onDone: @escaping (Result<String, Error>) -> Void) {
            self.onDelta = onDelta
            self.onDone = onDone
        }
    }

    enum Failure: LocalizedError {
        case notInstalled, ended(String)
        var errorDescription: String? {
            switch self {
            case .notInstalled: return "Claude Code isn't installed."
            case .ended(let detail): return detail
            }
        }
    }

    private let model: String
    private let systemPrompt: String
    private let promptFileName: String
    private let effort: String?
    private var process: StandbyCLIProcess?
    private var turns: [Turn] = []
    private var requestCounter = 0
    /// The process ended by itself (signed out, crashed).
    var onEnded: ((String) -> Void)?

    /// `effort` nil keeps the model's own. Thinking is always off: nobody waits for it on a call or while dictating.
    init(model: String, systemPrompt: String, promptFileName: String, effort: String? = nil) {
        self.model = model
        self.systemPrompt = systemPrompt
        self.promptFileName = promptFileName
        self.effort = effort
    }

    var isRunning: Bool { process?.isRunning == true }

    /// Starts it now and leaves it waiting, so the first turn only has to send the words.
    func start() throws {
        guard !isRunning else { return }
        guard let executable = ClaudeCodeBridge.locateClaudeCodeExecutable() else { throw Failure.notInstalled }
        let promptFile = try ClaudeArgs.writePromptFile(named: promptFileName, contents: systemPrompt)
        let folder = ClaudeArgs.sessionWorkingDirectoryURL
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var arguments = ClaudeArgs(model: model, systemPromptFileURL: promptFile, effortLevel: effort).arguments
        if let settings = arguments.firstIndex(of: "--settings"), arguments.indices.contains(settings + 1) {
            arguments[settings + 1] = #"{"disableAllHooks":true,"alwaysThinkingEnabled":false}"#
        }
        var environment = ClaudeArgs.environment()
        environment["MAX_THINKING_TOKENS"] = "0"
        let spec = CLILaunchSpec(executableURL: executable, arguments: arguments, environment: environment, workingDirectoryURL: folder, systemPromptText: systemPrompt)
        let launched = try StandbyCLIProcess.spawn(spec)
        process = launched
        // A blocking read on its own thread: FileHandle.bytes hands over stream output in lumps, seconds late.
        let handle = launched.standardOutputHandle
        DispatchQueue(label: "theo.claude-conversation").async { [weak self] in
            var reader = LineReader()
            var chunk = [UInt8](repeating: 0, count: 65_536)
            while true {
                let count = read(handle.fileDescriptor, &chunk, chunk.count)
                guard count > 0 else { break }
                let lines = reader.append(Data(chunk[0..<count]))
                guard !lines.isEmpty else { continue }
                DispatchQueue.main.async { MainActor.assumeIsolated { lines.forEach { self?.handle($0) } } }
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.processEnded(launched) } }
        }
    }

    /// Sends one message; the reply streams in. Turns stay in order if one is still finishing.
    func send(_ text: String, onDelta: @escaping (String) -> Void, onDone: @escaping (Result<String, Error>) -> Void) {
        do { try start() } catch {
            onDone(.failure(error))
            return
        }
        let message: [String: Any] = ["type": "user", "message": ["role": "user", "content": [["type": "text", "text": text]]] as [String: Any]]
        guard let process, let data = try? JSONSerialization.data(withJSONObject: message) else {
            onDone(.failure(Failure.ended("Couldn't write the message.")))
            return
        }
        turns.append(Turn(onDelta: onDelta, onDone: onDone))
        do {
            try process.standardInputHandle.write(contentsOf: data + Data("\n".utf8))
        } catch {
            turns.removeLast()
            onDone(.failure(Failure.ended("The brain closed.")))
        }
    }

    /// Stops the reply in progress; the conversation stays, with what was said so far.
    func interrupt() {
        guard let process, let current = turns.first else { return }
        _ = current
        for turn in turns { turn.isCancelled = true }
        requestCounter += 1
        let request: [String: Any] = ["type": "control_request", "request_id": "interrupt-\(requestCounter)", "request": ["subtype": "interrupt"]]
        if let data = try? JSONSerialization.data(withJSONObject: request) {
            try? process.standardInputHandle.write(contentsOf: data + Data("\n".utf8))
        }
    }

    func stop() {
        process?.reap()
        process = nil
        let waiting = turns
        turns = []
        for turn in waiting { turn.onDone(.failure(Failure.ended("The call ended."))) }
    }

    private func handle(_ line: Data) {
        guard let event = CLIStreamEvent.parse(line) else { return }
        switch event {
        case .textDelta(let delta):
            guard let turn = turns.first, !turn.isCancelled else { return }
            turn.text += delta
            turn.onDelta(delta)
        case .result(let text, let isError, _):
            guard !turns.isEmpty else { return }
            let turn = turns.removeFirst()
            if turn.isCancelled {
                turn.onDone(.success(turn.text))
            } else if isError {
                turn.onDone(.failure(Failure.ended(text)))
            } else {
                turn.onDone(.success(turn.text.isEmpty ? text : turn.text))
            }
        default:
            break
        }
    }

    private func processEnded(_ ended: StandbyCLIProcess) {
        guard process === ended else { return }
        process = nil
        let waiting = turns
        turns = []
        for turn in waiting { turn.onDone(.failure(Failure.ended("The brain stopped."))) }
        onEnded?("The brain stopped.")
    }
}

// MARK: - Ears

/// Hears the call. It's fed every mic block; it says when words come.
@MainActor
protocol CallEars: AnyObject {
    var name: String { get }
    var hasOwnEndpointing: Bool { get }
    var onPartial: ((String) -> Void)? { get set }
    var onFinal: ((String) -> Void)? { get set }
    /// It can't go on; the session moves to the next ears.
    var onFailed: ((String) -> Void)? { get set }
    func start()
    func feed(_ block: CallAudioBlock, isSpeech: Bool)
    /// The gate heard the speech end; ears that wait for this give their words.
    func speechEnded()
    func stop()
}

/// Apple on this Mac: one recognition per utterance, opened when the gate hears a voice, with a little audio from before.
@MainActor
final class AppleCallEars: CallEars {
    let name = "Apple"
    let hasOwnEndpointing = false
    var onPartial: ((String) -> Void)?
    var onFinal: ((String) -> Void)?
    var onFailed: ((String) -> Void)?

    private let locale: String
    private let phrases: [String]
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var latest = ""
    private var preroll: [CallAudioBlock] = []
    private var hasDelivered = true
    private var finishTimer: Task<Void, Never>?
    private let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Double(CallAudioBlock.sampleRate), channels: 1, interleaved: true)!
    private static let prerollBlocks = 8
    /// How long the last words may take after the voice stops.
    private static let finishSeconds = 0.45

    init(locale: String, phrases: [String]) {
        self.locale = locale
        self.phrases = phrases
    }

    func start() {
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else {
            onFailed?("Speech recognition isn't allowed.")
            return
        }
        recognizer = SFSpeechRecognizer(locale: Locale(identifier: locale)) ?? SFSpeechRecognizer()
        if recognizer?.isAvailable != true { onFailed?("No speech recognizer for \(locale).") }
    }

    private func beginUtterance() {
        guard let recognizer else { return }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.contextualStrings = phrases
        request.addsPunctuation = true
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
        self.request = request
        latest = ""
        hasDelivered = false
        let thisRequest = request
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let failed = error != nil
            Task { @MainActor in
                guard let self, self.request === thisRequest else { return }
                if let text, !text.isEmpty {
                    self.latest = text
                    self.onPartial?(text)
                }
                if isFinal || failed { self.deliver() }
            }
        }
        for block in preroll { append(block) }
        preroll = []
    }

    private func append(_ block: CallAudioBlock) {
        let frames = AVAudioFrameCount(block.pcm16.count / 2)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames), let channel = buffer.int16ChannelData?[0] else { return }
        block.pcm16.withUnsafeBytes { raw in
            if let base = raw.bindMemory(to: Int16.self).baseAddress { channel.update(from: base, count: Int(frames)) }
        }
        buffer.frameLength = frames
        request?.append(buffer)
    }

    func feed(_ block: CallAudioBlock, isSpeech: Bool) {
        if request == nil {
            if isSpeech { beginUtterance(); append(block); return }
            preroll.append(block)
            if preroll.count > Self.prerollBlocks { preroll.removeFirst() }
            return
        }
        append(block)
    }

    func speechEnded() {
        request?.endAudio()
        finishTimer?.cancel()
        finishTimer = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.finishSeconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.deliver()
        }
    }

    private func deliver() {
        guard !hasDelivered else { return }
        hasDelivered = true
        finishTimer?.cancel()
        task?.cancel()
        task = nil
        request = nil
        onFinal?(latest.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func stop() {
        finishTimer?.cancel()
        task?.cancel()
        task = nil
        request = nil
        hasDelivered = true
    }
}

/// Sarvam's sockets: realtime first (partial words), the standard one if realtime refuses.
@MainActor
final class SarvamCallEars: CallEars {
    private(set) var name = "Sarvam"
    private(set) var hasOwnEndpointing = true
    var onPartial: ((String) -> Void)?
    var onFinal: ((String) -> Void)?
    var onFailed: ((String) -> Void)?

    private let apiKey: String
    private let languageCode: String
    private var socket: SarvamSocket?
    private var usingRealtime = true
    private var hasBegun = false
    private var pendingAudio = Data()
    /// Words came in before the gate said the voice stopped.
    private var waitingFinal: Task<Void, Never>?
    private var latestPartial = ""
    private var isStopped = false
    private static let sendBytes = 3200

    /// `languageCode`: a Sarvam code, or "auto".
    init(apiKey: String, languageCode: String) {
        self.apiKey = apiKey
        self.languageCode = languageCode
    }

    func start() {
        connectRealtime()
    }

    private func connectRealtime() {
        guard let url = SarvamWire.realtimeSTTURL(languageCode: languageCode) else { return onFailed?("Bad address.") ?? () }
        usingRealtime = true
        name = "Sarvam realtime"
        hasBegun = false
        let socket = SarvamSocket(request: SarvamWire.socketRequest(url, apiKey: apiKey))
        socket.onText = { [weak self] text in self?.handle(SarvamWire.parseRealtimeSTT(text)) }
        socket.onClose = { [weak self] reason in self?.closed(reason) }
        self.socket = socket
        socket.open()
    }

    private func connectStandard() {
        guard let url = SarvamWire.standardSTTURL(languageCode: languageCode == "auto" ? "unknown" : languageCode) else { return onFailed?("Bad address.") ?? () }
        usingRealtime = false
        name = "Sarvam"
        hasBegun = true
        let socket = SarvamSocket(request: SarvamWire.socketRequest(url, apiKey: apiKey))
        socket.onText = { [weak self] text in self?.handle(SarvamWire.parseStandardSTT(text)) }
        socket.onClose = { [weak self] reason in self?.closed(reason) }
        self.socket = socket
        socket.open()
    }

    private func closed(_ reason: String?) {
        guard !isStopped else { return }
        // Realtime refused or never began: the standard socket has no beta to be let into.
        if usingRealtime && !hasBegun {
            print("📞 Sarvam realtime didn't open (\(reason ?? "closed")), trying the standard socket")
            connectStandard()
            return
        }
        onFailed?(reason ?? "Sarvam's listening closed.")
    }

    private func handle(_ event: SarvamWire.STTEvent) {
        switch event {
        case .began:
            hasBegun = true
        case .partial(let text):
            latestPartial = text
            if !text.isEmpty { onPartial?(text) }
        case .final(let text, _):
            waitingFinal?.cancel()
            waitingFinal = nil
            latestPartial = ""
            onFinal?(text.trimmingCharacters(in: .whitespacesAndNewlines))
        case .error(let message, let fatal):
            print("📞 Sarvam listening: \(message)")
            if fatal {
                if usingRealtime && !hasBegun {
                    socket?.close()
                    connectStandard()
                } else {
                    socket?.close()
                    onFailed?(message)
                }
            }
        case .speechStarted, .speechEnded, .other:
            break
        }
    }

    func feed(_ block: CallAudioBlock, isSpeech: Bool) {
        pendingAudio.append(block.pcm16)
        guard pendingAudio.count >= Self.sendBytes else { return }
        socket?.send(usingRealtime ? SarvamWire.realtimeAudio(pendingAudio) : SarvamWire.standardAudio(pendingAudio))
        pendingAudio.removeAll(keepingCapacity: true)
    }

    func speechEnded() {
        // The server ends the turn by itself. If nothing comes, the partial words count; the standard socket gets a nudge.
        if !usingRealtime { socket?.send(SarvamWire.standardFlush) }
        waitingFinal?.cancel()
        waitingFinal = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard !Task.isCancelled, let self else { return }
            let words = self.latestPartial
            self.latestPartial = ""
            self.onFinal?(words.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    func stop() {
        isStopped = true
        waitingFinal?.cancel()
        socket?.close()
        socket = nil
    }
}

// MARK: - Voices

/// Speaks the call's answers. Text comes in as it's written.
@MainActor
protocol CallVoice: AnyObject {
    var name: String { get }
    /// The first sound of this turn is on its way to the speaker.
    var onFirstAudio: (() -> Void)? { get set }
    /// Everything of this turn has played.
    var onFinished: (() -> Void)? { get set }
    /// It can't go on; what's left goes to the next voice.
    var onFailed: ((String, [String]) -> Void)? { get set }
    func prepare()
    func speak(_ text: String)
    func endOfTurn()
    func stopNow()
    func shutDown()
}

/// Sarvam's socket: each piece goes in with a flush, and audio comes back chunk by chunk.
@MainActor
final class SarvamCallVoice: CallVoice {
    let name = "Sarvam"
    var onFirstAudio: (() -> Void)?
    var onFinished: (() -> Void)?
    var onFailed: ((String, [String]) -> Void)?

    private let audio: CallAudio
    private let apiKey: String
    private let speaker: String
    private let languageCode: String
    private let pace: Double
    private var codec = "linear16"
    private var socket: SarvamSocket?
    private var decoder = CallAudioDecoder(sampleRate: 24000)
    private var isTurnActive = false
    private var turnEnded = false
    private var gotAudio = false
    private var piecesSent = 0
    private var piecesDone = 0
    private var unspoken: [String] = []
    private var quietTimer: Task<Void, Never>?

    init(audio: CallAudio, apiKey: String, speaker: String, languageCode: String, pace: Double) {
        self.audio = audio
        self.apiKey = apiKey
        self.speaker = speaker
        self.languageCode = languageCode
        self.pace = pace
    }

    func prepare() {
        guard socket == nil, let url = SarvamWire.ttsURL() else { return }
        let socket = SarvamSocket(request: SarvamWire.socketRequest(url, apiKey: apiKey))
        socket.onText = { [weak self] text in self?.handle(SarvamWire.parseTTS(text)) }
        socket.onClose = { [weak self] reason in self?.closed(reason) }
        self.socket = socket
        decoder = CallAudioDecoder(sampleRate: 24000)
        socket.open(pingMessage: SarvamWire.ttsPing)
        socket.send(SarvamWire.ttsConfig(speaker: speaker, languageCode: languageCode, pace: pace, codec: codec))
    }

    func speak(_ text: String) {
        prepare()
        if !isTurnActive {
            isTurnActive = true
            turnEnded = false
            gotAudio = false
            piecesSent = 0
            piecesDone = 0
            unspoken = []
        }
        unspoken.append(text)
        piecesSent += 1
        socket?.send(SarvamWire.ttsText(text))
        socket?.send(SarvamWire.ttsFlush)
    }

    func endOfTurn() {
        turnEnded = true
        if !isTurnActive { onFinished?(); return }
        checkFinished()
    }

    private func handle(_ event: SarvamWire.TTSEvent) {
        switch event {
        case .audio(let data, let contentType):
            guard isTurnActive else { return }
            let buffers = decoder.decode(data, contentType: contentType)
            guard !buffers.isEmpty else { return }
            if !gotAudio {
                gotAudio = true
                onFirstAudio?()
            }
            for buffer in buffers { audio.play(buffer) }
            // Once audio is flowing, what was asked for is on its way.
            unspoken = []
            armQuietTimer()
        case .final:
            piecesDone += 1
            checkFinished()
        case .error(let message):
            if codec == "linear16" && message.lowercased().contains("codec") {
                // The socket's own description says MP3 only today, the list says more. Honour what it says at run time.
                codec = "mp3"
                let pieces = unspoken
                socket?.close()
                socket = nil
                prepare()
                for piece in pieces {
                    socket?.send(SarvamWire.ttsText(piece))
                    socket?.send(SarvamWire.ttsFlush)
                }
                return
            }
            fail(message)
        case .other:
            break
        }
    }

    /// `final` comes per flush if at all; a stretch of quiet after the end of the turn counts too.
    private func armQuietTimer() {
        quietTimer?.cancel()
        quietTimer = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled, let self, self.turnEnded, !self.audio.isVoicePlaying else { return }
            self.finishTurn()
        }
    }

    private func checkFinished() {
        guard isTurnActive, turnEnded, piecesDone >= piecesSent, !audio.isVoicePlaying else {
            if isTurnActive && turnEnded { armQuietTimer() }
            return
        }
        finishTurn()
    }

    /// CallAudio says the queue ran out: finished if nothing more is coming.
    func audioDrained() {
        checkFinished()
    }

    private func finishTurn() {
        guard isTurnActive else { return }
        isTurnActive = false
        quietTimer?.cancel()
        onFinished?()
    }

    private func closed(_ reason: String?) {
        socket = nil
        if isTurnActive { fail(reason ?? "Sarvam's voice closed.") }
    }

    private func fail(_ message: String) {
        print("📞 Sarvam voice: \(message)")
        let pieces = unspoken
        socket?.close()
        socket = nil
        let wasActive = isTurnActive
        isTurnActive = false
        if wasActive { onFailed?(message, pieces) }
    }

    func stopNow() {
        isTurnActive = false
        quietTimer?.cancel()
        unspoken = []
        audio.stopVoice()
        // No cancel in this protocol: drop the socket so its chunks stop, and have the next one ready.
        socket?.close()
        socket = nil
        prepare()
    }

    func shutDown() {
        quietTimer?.cancel()
        isTurnActive = false
        socket?.close()
        socket = nil
    }
}

/// Apple's voices, written to samples one piece at a time so they go through the echo canceller like any other voice.
@MainActor
final class AppleCallVoice: CallVoice {
    let name = "Mac voice"
    var onFirstAudio: (() -> Void)?
    var onFinished: (() -> Void)?
    var onFailed: ((String, [String]) -> Void)?

    private let audio: CallAudio
    private var synthesizer = AVSpeechSynthesizer()
    /// Loaded and waiting: a synthesizer takes seconds to load its voice, and keeps writing long after being told to stop, so
    /// a cut-off answer hands over to this one.
    private var spare = AVSpeechSynthesizer()
    private var queue: [String] = []
    private var rendering = false
    private var turnEnded = false
    private var gotAudio = false
    private var generation = 0

    init(audio: CallAudio) {
        self.audio = audio
    }

    /// A voice takes a second or more to load the first time it's used, so it loads now, before anyone is waiting.
    func prepare() {
        warm(synthesizer)
        warm(spare)
    }

    private func warm(_ target: AVSpeechSynthesizer) {
        guard let voice = Self.voice(for: "Hello") else { return }
        let line = AVSpeechUtterance(string: "Hi.")
        line.voice = voice
        target.write(line) { _ in }
    }

    func speak(_ text: String) {
        queue.append(text)
        renderNext()
    }

    func endOfTurn() {
        turnEnded = true
        checkFinished()
    }

    private func renderNext() {
        guard !rendering, !queue.isEmpty else { return }
        rendering = true
        let text = queue.removeFirst()
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = Self.voice(for: text)
        let turn = generation
        synthesizer.write(utterance) { [weak self] output in
            guard let buffer = output as? AVAudioPCMBuffer else { return }
            let isEnd = buffer.frameLength == 0
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.generation == turn else { return }
                    if isEnd {
                        self.rendering = false
                        self.renderNext()
                        self.checkFinished()
                        return
                    }
                    if !self.gotAudio {
                        self.gotAudio = true
                        self.onFirstAudio?()
                    }
                    self.audio.play(buffer)
                }
            }
        }
    }

    /// The right voice for the script: Devanagari goes to a Hindi voice. The rest goes to Indian English when the call
    /// is in Hinglish, else to the computer's own language, when there's a voice for it.
    static func voice(for text: String) -> AVSpeechSynthesisVoice? {
        if DictationCleanup.containsDevanagari(text), let hindi = best(language: "hi") { return hindi }
        let callLanguage = CallSettings.language
        let spokenLocale = callLanguage.meansHinglish ? "en-IN" : callLanguage.appleLocale
        return best(language: spokenLocale) ?? best(language: "en-IN") ?? SystemVoiceTTSClient.automaticallyChosenVoice()
    }

    private static func best(language: String) -> AVSpeechSynthesisVoice? {
        AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix(language) && !$0.voiceTraits.contains(.isNoveltyVoice) }
            .max { $0.quality.rawValue < $1.quality.rawValue }
    }

    func audioDrained() {
        checkFinished()
    }

    private func checkFinished() {
        guard turnEnded, !rendering, queue.isEmpty, !audio.isVoicePlaying else { return }
        turnEnded = false
        gotAudio = false
        onFinished?()
    }

    func stopNow() {
        generation += 1
        synthesizer.stopSpeaking(at: .immediate)
        synthesizer = spare
        spare = AVSpeechSynthesizer()
        warm(spare)
        queue = []
        rendering = false
        turnEnded = false
        gotAudio = false
        audio.stopVoice()
    }

    func shutDown() {
        stopNow()
    }
}
