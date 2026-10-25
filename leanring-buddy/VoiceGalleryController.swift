//
//  VoiceGalleryController.swift
//  leanring-buddy
//
//  The voice gallery in the app: builds ClickyCore's VoiceGallery from
//  ~/.clicky/voice/candidates/manifest.json plus the installed Apple
//  Enhanced/Premium English voices, shows it in the "Voices" window, plays a
//  voice's sample only when its Play button is pressed (the sample WAV via
//  AVAudioPlayer for a cloned voice, the manifest's sampleText spoken with
//  that voice for an Apple one), and applies a choice: a Qwen voice points
//  v2.voice.qwen.referenceClip at its reference WAV and turns Qwen on (the
//  client re-reads the clip on its next request); an Apple voice sets
//  selectedSpeechVoiceIdentifier and turns Qwen off.
//
//  Spoken switches ("next voice", "use voice 3", "previous voice", "show
//  voices") come here from CompanionManager without a brain turn. After a
//  switch Clicky says one short line in the new voice, and only when the
//  turn speaks (a debug ask with speak:false stays silent).
//

import AppKit
import AVFoundation
import ClickyCore
import Combine
import SwiftUI

@MainActor
final class VoiceGalleryController: NSObject, ObservableObject {
    @Published private(set) var gallery = VoiceGallery(entries: [], sampleText: VoiceGallery.fallbackSampleText)
    @Published private(set) var activeEntryID: String?
    /// The entry whose preview is playing (the button shows Stop).
    @Published private(set) var playingEntryID: String?

    private let speechOutput: CompanionSpeechOutput
    private let settingsStore = VoiceGallerySettingsStore(defaults: .standard)
    private var samplePlayer: AVAudioPlayer?
    private let previewSynthesizer = AVSpeechSynthesizer()
    private var window: NSWindow?

    init(speechOutput: CompanionSpeechOutput) {
        self.speechOutput = speechOutput
        super.init()
        previewSynthesizer.delegate = self
    }

    private var isQwenAvailable: Bool { QwenLocalTTSClient.isAvailableOnThisMac }

    /// Re-reads the manifest, the installed voices and the settings.
    func refresh() {
        let appleVoices = SystemVoiceTTSClient.selectableEnglishVoices().map { voice in
            AppleVoiceDescriptor(identifier: voice.identifier, name: voice.name, language: voice.language, quality: Self.quality(of: voice))
        }
        gallery = VoiceGallery.load(appleVoices: appleVoices, isQwenAvailable: isQwenAvailable)
        activeEntryID = currentActiveEntryID()
    }

    private func currentActiveEntryID() -> String? {
        settingsStore.activeEntryID(in: gallery, isQwenAvailable: isQwenAvailable,
                                    automaticAppleVoiceIdentifier: SystemVoiceTTSClient.automaticallyChosenVoice()?.identifier)
    }

    private static func quality(of voice: AVSpeechSynthesisVoice) -> AppleVoiceDescriptor.Quality {
        switch voice.quality {
        case .premium: return .premium
        case .enhanced: return .enhanced
        default: return .standard
        }
    }

    // MARK: - Choosing

    /// Makes `entry` the voice. Says the confirmation line in it only when asked to.
    func select(_ entry: VoiceGalleryEntry, speaksConfirmation: Bool) {
        guard entry.isEnabled else { return }
        stopPlaying()
        let previouslyActiveEntryID = currentActiveEntryID()
        settingsStore.select(entry, previouslyActiveEntryID: previouslyActiveEntryID)
        switch entry.engine {
        case .qwen:
            // The settings store already wrote the reference path; this syncs
            // the published engine choice and warms the server if needed.
            speechOutput.selectQwenLocalVoice()
            speechOutput.qwenLocalVoiceClient.reloadReferenceClip()
            speechOutput.qwenServerSupervisor.refreshReadyStatus()
        case .apple(let voiceIdentifier):
            speechOutput.selectSystemVoice(identifier: voiceIdentifier)
        }
        activeEntryID = currentActiveEntryID()
        print("🗣️ Voice gallery: \(entry.number) \(entry.name) (\(entry.id))")
        if speaksConfirmation {
            speakNow(VoiceGallery.confirmationLine)
        }
    }

    /// A spoken voice command: no brain turn. `speaks` false for silent debug asks.
    func perform(_ command: VoiceGalleryCommand, speaks: Bool) {
        refresh()
        print("🗣️ Voice gallery command: \(command)")
        switch settingsStore.resolve(command, in: gallery, activeEntryID: activeEntryID) {
        case .select(let entry):
            select(entry, speaksConfirmation: speaks)
        case .showGallery:
            showWindow(activatesClicky: false)
        case .unavailable(let line):
            if speaks { speakNow(line) }
        }
    }

    private func speakNow(_ line: String) {
        speechOutput.stopPlayback()
        Task { [speechOutput] in
            try? await speechOutput.speakText(line)
        }
    }

    // MARK: - Preview (only from the Play button)

    func play(_ entry: VoiceGalleryEntry) {
        stopPlaying()
        speechOutput.stopPlayback()
        switch entry.engine {
        case .qwen:
            guard let previewAudioPath = entry.previewAudioPath else { return }
            do {
                let player = try AVAudioPlayer(contentsOf: URL(fileURLWithPath: previewAudioPath))
                player.delegate = self
                samplePlayer = player
                playingEntryID = entry.id
                player.play()
            } catch {
                print("⚠️ Voice gallery: couldn't play \(previewAudioPath): \(error)")
                playingEntryID = nil
            }
        case .apple(let voiceIdentifier):
            let utterance = AVSpeechUtterance(string: gallery.sampleText)
            utterance.voice = AVSpeechSynthesisVoice(identifier: voiceIdentifier)
            utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.95
            playingEntryID = entry.id
            previewSynthesizer.speak(utterance)
        }
    }

    func stopPlaying() {
        samplePlayer?.stop()
        samplePlayer = nil
        if previewSynthesizer.isSpeaking { previewSynthesizer.stopSpeaking(at: .immediate) }
        playingEntryID = nil
    }

    private func previewDidFinish() {
        samplePlayer = nil
        playingEntryID = nil
    }

    // MARK: - Window

    /// `activatesClicky` for a click (the window becomes key); a voice request
    /// only orders it front so the user's typing keeps focus.
    func showWindow(activatesClicky: Bool) {
        refresh()
        let galleryWindow = window ?? makeWindow()
        window = galleryWindow
        if !galleryWindow.isVisible { galleryWindow.center() }
        if activatesClicky {
            NSApp.activate(ignoringOtherApps: true)
            galleryWindow.makeKeyAndOrderFront(nil)
        } else {
            galleryWindow.orderFrontRegardless()
        }
    }

    private func makeWindow() -> NSWindow {
        let hostingController = NSHostingController(rootView: VoiceGalleryHostView(controller: self))
        hostingController.sizingOptions = []
        let galleryWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: VoiceGalleryView.preferredWidth, height: 720),
                                     styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                     backing: .buffered, defer: false)
        galleryWindow.contentViewController = hostingController
        galleryWindow.title = "Voices"
        galleryWindow.isReleasedWhenClosed = false
        galleryWindow.hidesOnDeactivate = false
        galleryWindow.contentMinSize = NSSize(width: VoiceGalleryView.preferredWidth, height: 360)
        galleryWindow.collectionBehavior = [.fullScreenAuxiliary]
        galleryWindow.setContentSize(NSSize(width: VoiceGalleryView.preferredWidth, height: 720))
        galleryWindow.delegate = self
        return galleryWindow
    }

    // MARK: - Debug

    /// The gallery and the active voice, for the debug inbox's voiceGallery.
    func debugSnapshot() -> [String: Any] {
        refresh()
        let entryObjects: [[String: Any]] = gallery.entries.map { entry in
            var entryObject: [String: Any] = [
                "number": entry.number, "id": entry.id, "name": entry.name, "detail": entry.detail,
                "engine": entry.isQwen ? "qwen" : "apple", "enabled": entry.isEnabled,
                "pitchHz": entry.pitchHz ?? NSNull(), "active": entry.id == activeEntryID
            ]
            entryObject["reference"] = entry.referencePath ?? NSNull()
            entryObject["preview"] = entry.previewAudioPath ?? NSNull()
            entryObject["voiceIdentifier"] = entry.appleVoiceIdentifier ?? NSNull()
            entryObject["disabledReason"] = entry.disabledReason ?? NSNull()
            return entryObject
        }
        return [
            "entries": entryObjects,
            "active": activeEntryID ?? NSNull(),
            "activeNumber": activeEntryID.flatMap { gallery[$0]?.number } ?? NSNull(),
            "previous": settingsStore.previousEntryID ?? NSNull(),
            "usesQwenLocalVoice": speechOutput.usesQwenLocalVoice,
            "referenceClip": ClickySettings.qwenReferenceClipPath,
            "selectedSpeechVoiceIdentifier": settingsStore.appleVoiceIdentifier ?? NSNull(),
            "sampleText": gallery.sampleText,
            "manifest": VoiceGallery.standardizedPath(VoiceGallery.defaultManifestPath)
        ]
    }

    /// voiceSelect {index|id}: the same choice as "Use this voice", never spoken.
    func debugSelect(number: Int?, entryID: String?) -> (VoiceGalleryEntry?, String?) {
        refresh()
        let chosenEntry = number.flatMap { gallery.entry(number: $0) } ?? entryID.flatMap { gallery[$0] }
        guard let chosenEntry else { return (nil, "no gallery voice for \(number.map(String.init) ?? entryID ?? "nothing")") }
        guard chosenEntry.isEnabled else { return (chosenEntry, chosenEntry.disabledReason ?? "voice is disabled") }
        select(chosenEntry, speaksConfirmation: false)
        return (chosenEntry, nil)
    }
}

extension VoiceGalleryController: NSWindowDelegate {
    /// Closing the window stops a preview that's still playing.
    func windowWillClose(_ notification: Notification) {
        stopPlaying()
    }
}

extension VoiceGalleryController: AVAudioPlayerDelegate, AVSpeechSynthesizerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            guard let self, self.samplePlayer === player else { return }
            self.previewDidFinish()
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in
            guard let self, self.samplePlayer == nil else { return }
            self.previewDidFinish()
        }
    }
}

/// Re-renders the gallery whenever the controller changes.
private struct VoiceGalleryHostView: View {
    @ObservedObject var controller: VoiceGalleryController

    var body: some View {
        VoiceGalleryView(
            gallery: controller.gallery,
            activeEntryID: controller.activeEntryID,
            playingEntryID: controller.playingEntryID,
            actions: VoiceGalleryActions(
                play: { entry in controller.play(entry) },
                stopPlaying: { controller.stopPlaying() },
                use: { entry in controller.select(entry, speaksConfirmation: false) }
            )
        )
    }
}
