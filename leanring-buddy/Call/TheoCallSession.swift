//
//  TheoCallSession.swift
//  leanring-buddy
//
//  A voice call with Theo, like ChatGPT's voice mode.
//
//    mic → voice gate → ears (Sarvam or Apple) → Theo's brain on Sonnet, streaming → voice (Sarvam or Apple) → speaker
//
//  Theo's reply goes to the voice clause by clause as it's written (CallSpeechChunker), so the first sound comes well before the sentence is
//  finished. When Addy talks over it the voice stops at once, the brain's turn is interrupted and what was heard counts as
//  the next turn. Hindi, English and Hinglish: the ears work out which, and Theo answers in kind. The transcript lands in
//  Theo's chat when the call ends, so the chat knows what was said.
//

import ClickyCore
import Combine
import Foundation
import AVFoundation

enum CallSettings {
    static let modelKey = "v2.call.model"
    static let languageKey = "v2.call.language"
    static let hearKey = "v2.call.ears"

    static var model: String { UserDefaults.standard.string(forKey: modelKey) ?? "claude-sonnet-5-5" }

    enum Language: String, CaseIterable, Identifiable {
        case auto, hinglish, english, hindi
        var id: String { rawValue }
        var title: String {
            switch self {
            case .auto: return "Auto"
            case .hinglish: return "Hinglish"
            case .english: return "English"
            case .hindi: return "Hindi"
            }
        }
        /// What Apple's recognizer should expect.
        var appleLocale: String { self == .hindi ? "hi-IN" : "en-IN" }
        var sarvamListening: String {
            switch self {
            case .auto, .hinglish: return "auto"
            case .english: return "en-IN"
            case .hindi: return "hi-IN"
            }
        }
        /// (language code, v2.voice.sarvam.language value) for Sarvam's voice.
        var sarvamVoice: (code: String, setting: String) {
            switch self {
            case .auto, .hinglish: return ("hi-IN", "hinglish")
            case .english: return ("en-IN", "en-IN")
            case .hindi: return ("hi-IN", "hi-IN")
            }
        }
    }

    static var language: Language { UserDefaults.standard.string(forKey: languageKey).flatMap(Language.init(rawValue:)) ?? .auto }
}

/// What Theo is told for a call.
enum CallPrompt {
    static let fileName = "theo-call-system-prompt.txt"

    @MainActor
    static func system(store: BotsStore, usesSarvamVoice: Bool, language: CallSettings.Language) -> String {
        let theo = store.primary
        var parts = [theo?.instructions ?? "You are Theo."]
        var rules = """
        You are on a live voice call with Addy right now. Everything you write is read aloud at once by a voice.
        Talk the way you would on the phone: usually one to three short sentences, in plain words. Start with the answer; your first sentence should be short, because it's spoken while you're still writing the rest.
        No markdown, lists, headings, code, emoji or stage directions. Spell out what's awkward to read aloud. Numbers are fine.
        Addy may cut in at any time. If a message starts where your last answer was cut off, just carry on with what they said.
        You have no tools on this call. If Addy wants something done, say you'll do it right after the call; it goes in your chat with the transcript.
        """
        switch language {
        case .auto, .hinglish:
            rules += usesSarvamVoice
                ? "\nAnswer in the language Addy just used: English in English, Hindi in Hindi written in Devanagari, Hinglish as Hinglish with the Hindi in Devanagari and the English in Latin letters."
                : "\nAnswer in the language Addy just used: English in English, Hindi or Hinglish in Roman letters, the way people text it, since this voice reads Roman letters best."
        case .english: rules += "\nAnswer in English."
        case .hindi: rules += usesSarvamVoice ? "\nAnswer in Hindi, in Devanagari." : "\nAnswer in Hindi, in Devanagari, keeping it simple."
        }
        parts.append(rules)
        if let theo {
            parts += BotPrompts.reportingLines(for: theo, store: store)
            let recent = store.conversation(theo.id).messages.suffix(6).compactMap { message -> String? in
                guard message.author == "user" || message.author == theo.id else { return nil }
                return (message.author == "user" ? "Addy: " : "Theo: ") + String(message.text.replacingOccurrences(of: "\n", with: " ").prefix(240))
            }
            if !recent.isEmpty { parts.append("The end of your text chat with Addy, before this call:\n" + recent.joined(separator: "\n")) }
        }
        return parts.joined(separator: "\n\n")
    }

    /// What the voice shouldn't read: markdown marks and the like.
    static func speakable(_ text: String) -> String {
        text.replacingOccurrences(of: "```[a-zA-Z]*", with: "", options: .regularExpression)
            .replacingOccurrences(of: "[*_`#>]", with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\[([^\]]+)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

@MainActor
final class TheoCallSession: ObservableObject {
    enum State: Equatable {
        case connecting, listening, userSpeaking, thinking, speaking, ended
    }

    struct Line: Identifiable, Equatable {
        enum Who { case addy, theo }
        let id = UUID()
        let who: Who
        var text: String
        var isLive: Bool
        var wasCut = false
    }

    /// One turn's timings, from the moment Addy's voice stopped.
    struct TurnTiming {
        var heard: TimeInterval?
        var firstText: TimeInterval?
        var firstAudio: TimeInterval?
        var ears = ""
        var voice = ""
    }

    @Published private(set) var state: State = .connecting
    @Published private(set) var lines: [Line] = []
    @Published private(set) var isMuted = false
    @Published private(set) var micLevel: CGFloat = 0
    @Published private(set) var problem: String?
    @Published private(set) var earsName = ""
    @Published private(set) var voiceName = ""
    @Published private(set) var lastFirstAudio: TimeInterval?
    @Published var language = CallSettings.language
    let startedAt = Date()

    private let audio: CallAudio
    private let isLive: Bool
    private let store: BotsStore
    private var brain: ClaudeConversation?
    private var ears: CallEars?
    private var voice: CallVoice?
    private var gate = VoiceActivityGate(endSeconds: 0.55)
    private var chunker = CallSpeechChunker()
    private var flushTimer: Task<Void, Never>?
    private var replyInProgress = false
    private var speechEndedAt: Date?
    private var speechStartedAt: Date?
    private var heardAt: Date?
    private var firstTextAt: Date?
    private var pendingTurnTiming: TurnTiming?
    private(set) var timings: [TurnTiming] = []
    private(set) var bargeIns: [TimeInterval] = []
    private var heardBargeInAt: Date?
    private var theoLineID: UUID?
    private var turnNumber = 0

    init(store: BotsStore, hub: AudioEngineHub, isLive: Bool) {
        self.store = store
        self.isLive = isLive
        audio = CallAudio(hub: hub, isLive: isLive)
    }

    // MARK: Start and end

    func start() {
        audio.onBlock = { [weak self] block in self?.handle(block) }
        audio.onDrained = { [weak self] in self?.voiceDrained() }
        do {
            try audio.open()
        } catch {
            problem = "The microphone didn't start."
            print("📞 Call audio: \(error)")
        }
        // Theo's voice reaches the mic with no echo cancelling: it takes a much louder voice to count as a cut-in.
        if isLive && !audio.isEchoCancelled { gate.bargeInMarginDecibels = 34 }
        startVoice()
        startEars()
        let prompt = CallPrompt.system(store: store, usesSarvamVoice: voice is SarvamCallVoice, language: language)
        let brain = ClaudeConversation(model: CallSettings.model, systemPrompt: prompt, promptFileName: CallPrompt.fileName, effort: "low")
        brain.onEnded = { [weak self] message in self?.problem = message }
        self.brain = brain
        do {
            try brain.start()
        } catch {
            problem = error.localizedDescription
        }
        state = .listening
        // Theo says hello: it's what a call does, and it warms up the brain and the voice, so Addy's first question gets
        // the same quick answer as the rest.
        ask("(The call just connected. Say hello to Addy in a few words and stop there.)")
    }

    func end() {
        guard state != .ended else { return }
        state = .ended
        ears?.stop()
        voice?.shutDown()
        brain?.stop()
        audio.close()
        store.recordCall(lines.filter { !$0.text.isEmpty }.map { ($0.who == .addy, $0.text) }, startedAt: startedAt)
    }

    func setMuted(_ muted: Bool) {
        isMuted = muted
        micLevel = 0
    }

    private func startVoice() {
        // The call speaks with Sarvam whenever its key is saved, whichever voice Clicky uses.
        if let key = ProviderKeychain.get("sarvam") {
            let voiceLanguage = language.sarvamVoice
            let speaker = SarvamClient.speaker(SarvamVoiceConfig.speaker, in: voiceLanguage.setting)
            let sarvam = SarvamCallVoice(audio: audio, apiKey: key, speaker: speaker, languageCode: voiceLanguage.code, pace: SarvamVoiceConfig.pace)
            use(voice: sarvam)
        } else {
            use(voice: AppleCallVoice(audio: audio))
        }
    }

    private func use(voice newVoice: CallVoice) {
        voice = newVoice
        voiceName = newVoice.name
        newVoice.onFirstAudio = { [weak self] in self?.voiceStartedSounding() }
        newVoice.onFinished = { [weak self] in self?.voiceFinished() }
        newVoice.onFailed = { [weak self] message, pieces in self?.voiceFailed(message, pieces: pieces) }
        newVoice.prepare()
    }

    private func voiceFailed(_ message: String, pieces: [String]) {
        problem = "Sarvam's voice stopped (\(message)), using the Mac voice."
        let replacement = AppleCallVoice(audio: audio)
        use(voice: replacement)
        for piece in pieces { replacement.speak(piece) }
        if !replyInProgress { replacement.endOfTurn() }
    }

    private func startEars() {
        if let key = ProviderKeychain.get("sarvam") {
            use(ears: SarvamCallEars(apiKey: key, languageCode: language.sarvamListening))
        } else {
            use(ears: appleEars())
        }
    }

    private func appleEars() -> AppleCallEars {
        AppleCallEars(locale: language.appleLocale, phrases: ["Theo", "Clicky", "Sarvam", "Addy"] + store.bots.map(\.name))
    }

    private func use(ears newEars: CallEars) {
        ears?.stop()
        ears = newEars
        earsName = newEars.name
        newEars.onPartial = { [weak self] text in self?.heardPartial(text) }
        newEars.onFinal = { [weak self] text in self?.heardFinal(text) }
        newEars.onFailed = { [weak self] message in self?.earsFailed(message) }
        newEars.start()
    }

    private func earsFailed(_ message: String) {
        guard !(ears is AppleCallEars) else {
            problem = message
            return
        }
        problem = "Sarvam's listening stopped (\(message)), using Apple on this Mac."
        use(ears: appleEars())
    }

    func changeLanguage(_ new: CallSettings.Language) {
        guard new != language else { return }
        language = new
        UserDefaults.standard.set(new.rawValue, forKey: CallSettings.languageKey)
        // The new language takes hold from the next turn: new ears and voice, and Theo told in so many words.
        voice?.shutDown()
        startVoice()
        startEars()
        guard let brain, brain.isRunning, new != .auto else { return }
        pendingLanguageNote = "(From now on answer in \(new.title).) "
    }

    private var pendingLanguageNote = ""

    // MARK: Mic

    private func handle(_ block: CallAudioBlock) {
        guard state != .ended, state != .connecting else { return }
        if isMuted {
            // Muted: nothing heard, and nothing leaves the Mac. The ears hear silence so their socket stays open.
            ears?.feed(CallAudioBlock(pcm16: Data(count: block.pcm16.count), levelDecibels: -100), isSpeech: false)
            return
        }
        micLevel = CGFloat(min(max((block.levelDecibels + 55) / 40, 0), 1))
        let voiceIsOn = state == .speaking || audio.isVoicePlaying
        let event = gate.feed(levelDecibels: block.levelDecibels, seconds: CallAudioBlock.seconds, otherSideTalking: voiceIsOn)
        // The ears get the audio before the event is acted on, so the first words aren't missing.
        ears?.feed(block, isSpeech: gate.isSpeaking)
        switch event {
        case .speechStarted: speechStarted()
        case .speechEnded: speechEnded()
        case nil: break
        }
    }

    private func speechStarted() {
        speechStartedAt = Date()
        speechEndedAt = nil
        if audio.isVoicePlaying || replyInProgress || state == .speaking || state == .thinking {
            bargeIn()
        }
        state = .userSpeaking
        startAddyLine()
    }

    private func speechEnded() {
        // The gate waits out a stretch of quiet to be sure. The clock starts from the voice's real end, before that wait.
        if speechEndedAt == nil { speechEndedAt = Date().addingTimeInterval(-gate.endSeconds) }
        if state == .userSpeaking {
            // The ears may have given their words and the reply may even be done by now.
            let isWaiting = replyInProgress || audio.isVoicePlaying || lines.last?.isLive == true
            state = isWaiting ? (audio.isVoicePlaying ? .speaking : .thinking) : .listening
        }
        ears?.speechEnded()
    }

    /// Addy talked over Theo: the voice stops at once and the rest of the reply is dropped.
    private func bargeIn() {
        voice?.stopNow()
        if replyInProgress { brain?.interrupt() }
        replyInProgress = false
        flushTimer?.cancel()
        chunker = CallSpeechChunker()
        if let theoLineID, let index = lines.firstIndex(where: { $0.id == theoLineID }) {
            lines[index].isLive = false
            lines[index].wasCut = true
        }
        theoLineID = nil
        // How long a voice took to stop it: the gate's wait for a real voice (double while Theo talks), and this.
        if let speechStartedAt { bargeIns.append(Date().timeIntervalSince(speechStartedAt) + gate.startSeconds * 2) }
    }

    // MARK: Words in

    private func startAddyLine() {
        if let last = lines.last, last.who == .addy, last.isLive { return }
        lines.append(Line(who: .addy, text: "", isLive: true))
    }

    private func heardPartial(_ text: String) {
        startAddyLine()
        if let index = lines.lastIndex(where: { $0.who == .addy && $0.isLive }) { lines[index].text = text }
    }

    private func heardFinal(_ text: String) {
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // A server's own voice detection can beat the gate. Its default wait is half a second of quiet.
        if gate.isSpeaking, speechEndedAt == nil, !words.isEmpty { speechEndedAt = Date().addingTimeInterval(-0.5) }
        guard let index = lines.lastIndex(where: { $0.who == .addy && $0.isLive }) else {
            if !words.isEmpty {
                lines.append(Line(who: .addy, text: words, isLive: false))
                ask(words)
            }
            return
        }
        if words.isEmpty {
            // A cough, or the room. No turn; back to listening.
            lines.remove(at: index)
            if state == .thinking || state == .userSpeaking { state = .listening }
            return
        }
        lines[index].text = words
        lines[index].isLive = false
        ask(words)
    }

    // MARK: Words out

    private func ask(_ text: String) {
        guard let brain else { return }
        turnNumber += 1
        let turn = turnNumber
        state = gate.isSpeaking ? .userSpeaking : .thinking
        heardAt = Date()
        firstTextAt = nil
        var timing = TurnTiming(ears: earsName, voice: voiceName)
        if let speechEndedAt { timing.heard = Date().timeIntervalSince(speechEndedAt) }
        pendingTurnTiming = timing
        replyInProgress = true
        chunker = CallSpeechChunker()
        let line = Line(who: .theo, text: "", isLive: true)
        lines.append(line)
        theoLineID = line.id
        let note = pendingLanguageNote
        pendingLanguageNote = ""
        brain.send(note + text, onDelta: { [weak self] delta in
            guard let self, self.turnNumber == turn, self.replyInProgress else { return }
            self.replyDelta(delta)
        }, onDone: { [weak self] result in
            guard let self, self.turnNumber == turn, self.replyInProgress else { return }
            self.replyFinished(result)
        })
    }

    private func replyDelta(_ delta: String) {
        if firstTextAt == nil {
            firstTextAt = Date()
            if let speechEndedAt { pendingTurnTiming?.firstText = firstTextAt?.timeIntervalSince(speechEndedAt) }
        }
        if let theoLineID, let index = lines.firstIndex(where: { $0.id == theoLineID }) { lines[index].text += delta }
        for piece in chunker.feed(delta) { speak(piece) }
        // Nothing more for a moment and the sentence looks done: say it, rather than wait for the end of the reply.
        flushTimer?.cancel()
        flushTimer = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard !Task.isCancelled, let self, self.replyInProgress, let piece = self.chunker.flushFinishedSentence() else { return }
            self.speak(piece)
        }
    }

    private func speak(_ piece: String) {
        let text = CallPrompt.speakable(piece)
        guard !text.isEmpty else { return }
        voice?.speak(text)
    }

    private func replyFinished(_ result: Result<String, Error>) {
        replyInProgress = false
        if let theoLineID, let index = lines.firstIndex(where: { $0.id == theoLineID }) {
            lines[index].isLive = false
            if lines[index].text.isEmpty, case .success(let text) = result { lines[index].text = text }
        }
        theoLineID = nil
        switch result {
        case .success(let whole):
            // A reply that never streamed (a CLI that gave only its result) still gets spoken.
            flushTimer?.cancel()
            if firstTextAt == nil { for piece in chunker.feed(whole) { speak(piece) } }
            if let piece = chunker.finish() { speak(piece) }
            voice?.endOfTurn()
        case .failure(let error):
            problem = error.localizedDescription
            if state == .thinking { state = .listening }
        }
    }

    private func voiceStartedSounding() {
        if let speechEndedAt {
            let seconds = Date().timeIntervalSince(speechEndedAt)
            pendingTurnTiming?.firstAudio = seconds
            lastFirstAudio = seconds
        }
        if var timing = pendingTurnTiming, speechEndedAt != nil {
            timing.ears = earsName
            timing.voice = voiceName
            timings.append(timing)
            pendingTurnTiming = nil
        }
        if state == .thinking { state = .speaking }
    }

    private func voiceDrained() {
        (voice as? SarvamCallVoice)?.audioDrained()
        (voice as? AppleCallVoice)?.audioDrained()
    }

    private func voiceFinished() {
        if state == .speaking || state == .thinking { state = .listening }
    }

    // MARK: Test files

    /// `uiCallFeed`: a sound file in place of the mic, at real-time pace. With `trailingSilence` it's followed by quiet.
    func feed(fileURL: URL, trailingSilence: Double) async -> Bool {
        guard let file = try? AVAudioFile(forReading: fileURL) else { return false }
        let frames = AVAudioFrameCount(file.processingFormat.sampleRate * 0.05)
        while file.framePosition < file.length, state != .ended {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames), (try? file.read(into: buffer, frameCount: frames)) != nil, buffer.frameLength > 0 else { break }
            audio.feed(buffer)
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        let silence = Int(trailingSilence / 0.05)
        for _ in 0..<silence where state != .ended {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames) else { break }
            buffer.frameLength = frames
            // Room noise rather than digital silence, so the gate sees a real floor.
            if let channel = buffer.floatChannelData?[0] { for index in 0..<Int(frames) { channel[index] = Float.random(in: -0.0005...0.0005) } }
            audio.feed(buffer)
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return true
    }

    /// What `uiCallStatus` shows.
    func report() -> [String: Any] {
        [
            "state": String(describing: state), "ears": earsName, "voice": voiceName, "muted": isMuted, "problem": problem ?? "",
            "timings": timings.map { timing in
                ["heardSeconds": timing.heard as Any? ?? NSNull(), "firstTextSeconds": timing.firstText as Any? ?? NSNull(),
                 "firstAudioSeconds": timing.firstAudio as Any? ?? NSNull(), "ears": timing.ears, "voice": timing.voice] as [String: Any]
            },
            "bargeInSeconds": bargeIns,
            "lines": lines.map { ["who": $0.who == .addy ? "addy" : "theo", "text": $0.text, "live": $0.isLive, "cut": $0.wasCut] as [String: Any] },
        ]
    }
}
