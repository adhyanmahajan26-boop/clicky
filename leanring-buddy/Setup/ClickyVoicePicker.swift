//
//  ClickyVoicePicker.swift
//  leanring-buddy
//
//  How Clicky sounds, in one place: Theo's own voice, Sarvam Bulbul (speaker, language, pace), good Mac voices and
//  ElevenLabs, each voice with its own play button. Clicking a voice picks it and a preview never changes the setting.
//

import AVFoundation
import ClickyCore
import Combine
import SwiftUI

/// Plays one sample at a time; a second press or another voice stops it at once.
@MainActor
final class VoicePreviewPlayer: NSObject, ObservableObject, AVAudioPlayerDelegate, AVSpeechSynthesizerDelegate {
    static let shared = VoicePreviewPlayer()

    /// The voice being previewed (or being fetched).
    @Published private(set) var playing: String?
    @Published private(set) var problem: String?
    /// Seconds from the press to the first sound, for the last preview.
    private(set) var lastSecondsToSound: TimeInterval?

    private var player: AVAudioPlayer?
    private let synthesizer = AVSpeechSynthesizer()
    private var fetch: Task<Void, Never>?

    override private init() {
        super.init()
        synthesizer.delegate = self
    }

    func stop() {
        fetch?.cancel()
        fetch = nil
        player?.stop()
        player = nil
        synthesizer.stopSpeaking(at: .immediate)
        playing = nil
    }

    func toggle(_ id: String, start: @escaping () -> Void) {
        if playing == id { stop(); return }
        stop()
        problem = nil
        playing = id
        lastSecondsToSound = nil
        start()
    }

    func previewSarvam(speaker: String, languageSetting: String, pace: Double) {
        toggle("sarvam:\(speaker)") { [weak self] in
            guard let self else { return }
            let pressed = Date()
            self.fetch = Task { @MainActor in
                do {
                    guard let client = SarvamClient.fromKeychain() else { throw SarvamError.missingKey }
                    let audio = try await client.synthesize(text: Self.sample(for: languageSetting), languageSetting: languageSetting, speaker: speaker, model: SarvamVoiceConfig.model, pace: pace)
                    try Task.checkCancellation()
                    self.play(audio)
                    self.lastSecondsToSound = Date().timeIntervalSince(pressed)
                } catch is CancellationError {
                } catch {
                    self.problem = error.localizedDescription
                    self.playing = nil
                }
            }
        }
    }

    func previewElevenLabs(voice: String) {
        toggle("elevenlabs:\(voice)") { [weak self] in
            guard let self else { return }
            self.fetch = Task { @MainActor in
                do {
                    let audio = try await ElevenLabsClient.synthesize(CompanionSpeechOutput.voicePreviewSentence, voice: voice)
                    try Task.checkCancellation()
                    self.play(audio)
                } catch is CancellationError {
                } catch {
                    self.problem = error.localizedDescription
                    self.playing = nil
                }
            }
        }
    }

    func previewMac(_ voice: AVSpeechSynthesisVoice) {
        toggle("mac:\(voice.identifier)") { [weak self] in
            let utterance = AVSpeechUtterance(string: voice.language.hasPrefix("hi") ? Self.sample(for: "hi-IN") : CompanionSpeechOutput.voicePreviewSentence)
            utterance.voice = voice
            if TheoProfile.isTest { utterance.volume = 0 }
            self?.synthesizer.speak(utterance)
        }
    }

    private func play(_ audio: Data) {
        do {
            let player = try AVAudioPlayer(data: audio)
            player.delegate = self
            if TheoProfile.isTest { player.volume = 0 }
            player.play()
            self.player = player
        } catch {
            problem = "Couldn't play that sample."
            playing = nil
        }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async { MainActor.assumeIsolated { self.playing = nil } }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { MainActor.assumeIsolated { self.playing = nil } }
    }

    static func sample(for languageSetting: String) -> String {
        switch languageSetting {
        case "hinglish": return "Hey, main Theo hoon. Main aapko aise answer dunga, simple aur clear."
        case "hi-IN": return "नमस्ते, मैं थियो हूँ। मैं आपको ऐसे जवाब दूँगा।"
        case "bn-IN": return "নমস্কার, আমি থিও। আমি এভাবেই আপনাকে উত্তর দেব।"
        case "gu-IN": return "નમસ્તે, હું થિયો છું. હું તમને આ રીતે જવાબ આપીશ."
        case "kn-IN": return "ನಮಸ್ಕಾರ, ನಾನು ಥಿಯೋ. ನಾನು ನಿಮಗೆ ಹೀಗೆ ಉತ್ತರಿಸುತ್ತೇನೆ."
        case "mr-IN": return "नमस्कार, मी थिओ आहे. मी तुम्हाला असं उत्तर देईन."
        case "pa-IN": return "ਸਤ ਸ੍ਰੀ ਅਕਾਲ, ਮੈਂ ਥੀਓ ਹਾਂ. ਮੈਂ ਤੁਹਾਨੂੰ ਇਸ ਤਰ੍ਹਾਂ ਜਵਾਬ ਦਿਆਂਗਾ."
        case "ta-IN": return "வணக்கம், நான் தியோ. நான் உங்களுக்கு இப்படித்தான் பதில் சொல்வேன்."
        case "te-IN": return "నమస్తే, నేను థియో. నేను మీకు ఇలా సమాధానం చెబుతాను."
        default: return CompanionSpeechOutput.voicePreviewSentence
        }
    }
}

struct ClickyVoicePicker: View {
    enum Source: String, CaseIterable, Identifiable {
        case theo, sarvam, mac, elevenlabs
        var id: String { rawValue }
        var title: String {
            switch self {
            case .theo: return "Theo's voice"
            case .sarvam: return "Sarvam Bulbul"
            case .mac: return "Mac voices"
            case .elevenlabs: return "ElevenLabs"
            }
        }
    }

    @AppStorage(SarvamVoiceSettings_Keys.engine) private var engine = ""
    @AppStorage(SarvamVoiceSettings_Keys.speaker) private var speaker = "shubh_enhi_companion"
    @AppStorage(SarvamVoiceSettings_Keys.language) private var language = "hinglish"
    @AppStorage(SarvamVoiceSettings_Keys.pace) private var pace = 1.0
    @AppStorage(SarvamVoiceSettings_Keys.model) private var model = "bulbul:v4-flash"
    @AppStorage(ElevenLabsClient.voiceKey) private var elevenVoice = ""
    @ObservedObject private var keys = ProviderKeys.shared
    @ObservedObject private var preview = VoicePreviewPlayer.shared
    @State private var usesQwen = CompanionManager.current?.speechOutputClient.usesQwenLocalVoice ?? QwenLocalTTSClient.isAvailable
    @State private var macVoice: String? = CompanionManager.current?.speechOutputClient.systemVoiceClient.selectedVoiceIdentifier
    @State private var elevenVoices: [ElevenLabsClient.Voice] = []
    @State private var elevenProblem: String?
    @State private var showing: Source?

    private var manager: CompanionManager? { CompanionManager.current }

    private var active: Source {
        switch engine {
        case "sarvam": return .sarvam
        case "elevenlabs": return .elevenlabs
        default: return usesQwen ? .theo : .mac
        }
    }

    private var shown: Source { showing ?? active }

    var body: some View {
        TheoSection(title: "Clicky's voice", hint: "It speaks sentence by sentence, so the first words come fast, and “stop” cuts it off at once.") {
            VStack(alignment: .leading, spacing: 12) {
                sourceChips
                switch shown {
                case .theo: theoPane
                case .sarvam: sarvamPane
                case .mac: macPane
                case .elevenlabs: elevenPane
                }
                if let problem = preview.problem {
                    Text(problem).font(TheoType.caption).foregroundColor(DS.Colors.warning).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(12)
        }
    }

    // MARK: Sources

    private var sourceChips: some View {
        HStack(spacing: 8) {
            ForEach(Source.allCases) { source in
                Button { showing = source } label: {
                    HStack(spacing: 7) {
                        sourceIcon(source)
                        Text(source.title).font(.system(size: 12.5, weight: shown == source ? .semibold : .regular)).lineLimit(1)
                        if active == source {
                            Image(systemName: "checkmark.circle.fill").font(.system(size: 11)).foregroundColor(DS.Colors.accent)
                        }
                    }
                    .foregroundColor(DS.Colors.textPrimary)
                    .padding(.horizontal, 11).frame(height: 34)
                    .frame(maxWidth: .infinity)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(shown == source ? DS.Colors.selected : DS.Colors.hover))
                    .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(shown == source ? DS.Colors.accent.opacity(0.7) : .clear, lineWidth: 1))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder private func sourceIcon(_ source: Source) -> some View {
        switch source {
        case .theo: Image(systemName: "waveform.circle.fill").font(.system(size: 13))
        case .mac: Image(systemName: "apple.logo").font(.system(size: 12))
        case .sarvam: BrandLogo(id: "sarvam", name: "Sarvam", size: 18)
        case .elevenlabs: BrandLogo(id: "elevenlabs", name: "ElevenLabs", size: 18)
        }
    }

    // MARK: Theo's voice

    private var theoPane: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Theo's own voice, made on this Mac").font(TheoType.bodyMedium).foregroundColor(DS.Colors.textPrimary)
                Text(QwenLocalTTSClient.isAvailable ? "Private and free. Other voices are in the voice gallery." : "Needs MLX Core, which isn't on this Mac.")
                    .font(TheoType.caption).foregroundColor(DS.Colors.textTertiary)
            }
            Spacer()
            Button("Gallery") { manager?.voiceGalleryController.showWindow(activatesClicky: true) }.buttonStyle(.theoSecondary).disabled(TheoProfile.isTest)
            useButton(active == .theo, enabled: QwenLocalTTSClient.isAvailable) {
                engine = ""
                usesQwen = true
                manager?.speechOutputClient.selectQwenLocalVoice()
            }
        }
    }

    private func useButton(_ inUse: Bool, enabled: Bool = true, action: @escaping () -> Void) -> some View {
        Group {
            if inUse {
                Label("In use", systemImage: "checkmark").font(.system(size: 12, weight: .semibold)).foregroundColor(DS.Colors.success)
            } else {
                Button("Use this", action: action).buttonStyle(.theoPrimary).disabled(!enabled)
            }
        }
    }

    // MARK: Sarvam

    private var currentGroup: SarvamClient.VoiceGroup {
        SarvamClient.v4VoiceGroups.first { $0.languageSetting == language } ?? SarvamClient.v4VoiceGroups[0]
    }

    private var sarvamPane: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !keys.hasKey(for: "sarvam") {
                HStack(spacing: 8) {
                    Image(systemName: "key.fill").font(.system(size: 11)).foregroundColor(DS.Colors.warning)
                    Text("Add your Sarvam key to hear these. Until then Clicky keeps its current voice.").font(TheoType.caption).foregroundColor(DS.Colors.textSecondary)
                    Spacer()
                    Button("Add a key") { TheoSettingsWindowController.show(section: .keys) }.buttonStyle(.theoSecondary)
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(DS.Colors.warning.opacity(0.1)))
            }
            HStack(spacing: 10) {
                Text("Language").font(TheoType.caption).foregroundColor(DS.Colors.textSecondary)
                Picker("Language", selection: Binding(get: { currentGroup.languageSetting }, set: { value in
                    language = value
                    speaker = SarvamClient.speaker(speaker, in: value)
                })) {
                    ForEach(SarvamClient.v4VoiceGroups) { Text("\($0.title) (\($0.speakers.count))").tag($0.languageSetting) }
                }
                .labelsHidden().frame(width: 180)
                Spacer()
                Text("Pace").font(TheoType.caption).foregroundColor(DS.Colors.textSecondary)
                Slider(value: $pace, in: 0.5...2.0, step: 0.05).frame(width: 130)
                Text(String(format: "%.2fx", pace)).font(.system(size: 11, weight: .medium, design: .monospaced)).foregroundColor(DS.Colors.textTertiary).frame(width: 40, alignment: .trailing)
            }
            ScrollView {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 6) {
                    ForEach(currentGroup.speakers, id: \.self) { id in sarvamRow(id) }
                }
            }
            .frame(height: 188)
            HStack(spacing: 8) {
                previewButton(playingID: "sarvam:\(speaker)", disabled: !keys.hasKey(for: "sarvam")) {
                    preview.previewSarvam(speaker: speaker, languageSetting: language, pace: pace)
                }
                Spacer()
                useButton(engine == "sarvam") { engine = "sarvam" }
            }
        }
    }

    private func sarvamRow(_ id: String) -> some View {
        let title = SarvamClient.voiceTitle(id)
        let picked = speaker == id
        return Button {
            speaker = id
            model = "bulbul:v4-flash"
        } label: {
            HStack(spacing: 7) {
                playDot("sarvam:\(id)", disabled: !keys.hasKey(for: "sarvam")) {
                    preview.previewSarvam(speaker: id, languageSetting: language, pace: pace)
                }
                VStack(alignment: .leading, spacing: 0) {
                    Text(title.name).font(.system(size: 12, weight: picked ? .semibold : .medium)).foregroundColor(DS.Colors.textPrimary).lineLimit(1)
                    Text(title.style).font(.system(size: 10)).foregroundColor(DS.Colors.textTertiary).lineLimit(1)
                }
                Spacer(minLength: 0)
                if picked { Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundColor(DS.Colors.accent) }
            }
            .padding(.horizontal, 7).frame(height: 40)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(picked ? DS.Colors.selected : DS.Colors.surface1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Mac

    private var goodMacVoices: [AVSpeechSynthesisVoice] {
        let hindi = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix("hi") }
        return SystemVoiceTTSClient.selectableEnglishVoices() + hindi
    }

    private var macPane: some View {
        let voices = goodMacVoices
        let hasGood = voices.contains { $0.quality != .default }
        return VStack(alignment: .leading, spacing: 10) {
            if !hasGood {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 11)).foregroundColor(DS.Colors.warning)
                    Text("These compact voices sound robotic. A free Premium voice is far better: System Settings › Accessibility › Spoken Content.")
                        .font(TheoType.caption).foregroundColor(DS.Colors.textSecondary).fixedSize(horizontal: false, vertical: true)
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(DS.Colors.warning.opacity(0.1)))
            }
            ScrollView {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 6) {
                    ForEach(voices, id: \.identifier) { voice in macRow(voice) }
                }
            }
            .frame(height: 188)
        }
    }

    private func macRow(_ voice: AVSpeechSynthesisVoice) -> some View {
        let picked = active == .mac && (macVoice == voice.identifier || (macVoice == nil && SystemVoiceTTSClient.automaticallyChosenVoice()?.identifier == voice.identifier))
        return Button {
            engine = ""
            usesQwen = false
            macVoice = voice.identifier
            manager?.speechOutputClient.selectSystemVoice(identifier: voice.identifier)
        } label: {
            HStack(spacing: 7) {
                playDot("mac:\(voice.identifier)") { preview.previewMac(voice) }
                VStack(alignment: .leading, spacing: 0) {
                    Text(voice.name).font(.system(size: 12, weight: picked ? .semibold : .medium)).foregroundColor(DS.Colors.textPrimary).lineLimit(1)
                    Text(voice.language + (voice.quality == .premium ? ", premium" : voice.quality == .enhanced ? ", enhanced" : ""))
                        .font(.system(size: 10)).foregroundColor(DS.Colors.textTertiary).lineLimit(1)
                }
                Spacer(minLength: 0)
                if picked { Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundColor(DS.Colors.accent) }
            }
            .padding(.horizontal, 7).frame(height: 40)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(picked ? DS.Colors.selected : DS.Colors.surface1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: ElevenLabs

    @ViewBuilder private var elevenPane: some View {
        if !keys.hasKey(for: "elevenlabs") {
            HStack(spacing: 8) {
                Image(systemName: "key.fill").font(.system(size: 11)).foregroundColor(DS.Colors.textTertiary)
                Text("Save an ElevenLabs key to use its voices.").font(TheoType.caption).foregroundColor(DS.Colors.textSecondary)
                Spacer()
                Button("Add a key") { TheoSettingsWindowController.show(section: .keys) }.buttonStyle(.theoSecondary)
            }
        } else {
            VStack(alignment: .leading, spacing: 10) {
                if let elevenProblem { Text(elevenProblem).font(TheoType.caption).foregroundColor(DS.Colors.warning) }
                ScrollView {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 6) {
                        ForEach(elevenVoices) { voice in
                            Button { elevenVoice = voice.id } label: {
                                HStack(spacing: 7) {
                                    playDot("elevenlabs:\(voice.id)") { preview.previewElevenLabs(voice: voice.id) }
                                    Text(voice.name).font(.system(size: 12, weight: .medium)).foregroundColor(DS.Colors.textPrimary).lineLimit(1)
                                    Spacer(minLength: 0)
                                    if elevenVoice == voice.id { Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundColor(DS.Colors.accent) }
                                }
                                .padding(.horizontal, 7).frame(height: 40)
                                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(elevenVoice == voice.id ? DS.Colors.selected : DS.Colors.surface1))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(height: 188)
                HStack {
                    Spacer()
                    useButton(engine == "elevenlabs", enabled: !elevenVoice.isEmpty) { engine = "elevenlabs" }
                }
            }
            .task {
                do {
                    elevenVoices = try await ElevenLabsClient.listVoices()
                    if elevenVoice.isEmpty, let first = elevenVoices.first { elevenVoice = first.id }
                } catch { elevenProblem = error.localizedDescription }
            }
        }
    }

    // MARK: Pieces

    private func playDot(_ id: String, disabled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: preview.playing == id ? "stop.fill" : "play.fill").font(.system(size: 9, weight: .bold))
                .foregroundColor(disabled ? DS.Colors.textDisabled : DS.Colors.textPrimary)
                .frame(width: 24, height: 24)
                .background(Circle().fill(DS.Colors.hover))
                .contentShape(Circle())
        }
        .buttonStyle(.plain).disabled(disabled).help("Preview")
    }

    private func previewButton(playingID: String, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(preview.playing == playingID ? "Stop" : "Preview", systemImage: preview.playing == playingID ? "stop.fill" : "play.fill")
        }
        .buttonStyle(.theoSecondary).disabled(disabled)
    }
}
