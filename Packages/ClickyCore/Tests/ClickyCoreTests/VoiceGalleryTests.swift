//
//  VoiceGalleryTests.swift
//  ClickyCoreTests
//
//  The voice gallery: manifest decoding (missing files → disabled entry),
//  gallery order (Qwen voices, current, Apple Enhanced/Premium), the spoken
//  commands and their negatives, next/previous cycling, what a selection
//  writes (an injected UserDefaults suite, never the app's defaults), the
//  Qwen reference-clip reload, the prompt line, and offscreen renders of the
//  gallery (light + dark) into ~/Library/Logs/Clicky/renders/voice/.
//  Nothing here plays audio.
//

import AppKit
import Foundation
import SwiftUI
import Testing
@testable import ClickyCore

enum VoiceGalleryFixtures {
    static let manifestJSON = """
    {
      "version": 1,
      "sampleText": "Here is the Wi-Fi setting you asked about.",
      "voices": [
        {"id": "voice1", "name": "Voice 1 · bright", "pitchHz": 222, "reference": "voice1-ref.wav", "sample": "voice1-sample.wav"},
        {"id": "voice2", "name": "Voice 2 · warm", "pitchHz": 211, "reference": "voice2-ref.wav", "sample": "voice2-sample.wav"},
        {"id": "voice3", "name": "Voice 3 · soft", "pitchHz": 205, "reference": "voice3-ref.wav", "sample": "voice3-sample.wav"},
        {"id": "voice4", "name": "Voice 4 · calm", "pitchHz": 129, "reference": "voice4-ref.wav", "sample": "voice4-sample.wav"},
        {"id": "voice5", "name": "Voice 5 · steady", "pitchHz": 123, "reference": "voice5-ref.wav", "sample": "voice5-sample.wav"},
        {"id": "voice6", "name": "Voice 6 · deep", "pitchHz": 113, "reference": "voice6-ref.wav", "sample": "voice6-sample.wav"}
      ],
      "current": {"id": "clicky-voice", "name": "Current Clicky voice", "pitchHz": 286, "reference": "../clicky-voice.wav", "extra": true}
    }
    """

    static let manifestDirectory = "/tmp/clicky-voice-fixture/candidates"

    static let appleVoices = [
        AppleVoiceDescriptor(identifier: "com.apple.ttsbundle.gryphon-neural_Riya_en-IN_premium", name: "Riya", language: "en-IN", quality: .premium),
        AppleVoiceDescriptor(identifier: "com.apple.siri.natural.Akash", name: "Akash", language: "en-IN", quality: .enhanced),
        AppleVoiceDescriptor(identifier: "com.apple.voice.compact.en-US.Samantha", name: "Samantha", language: "en-US", quality: .standard),
        AppleVoiceDescriptor(identifier: "com.apple.voice.premium.fr-FR.Amelie", name: "Amélie", language: "fr-FR", quality: .premium),
        AppleVoiceDescriptor(identifier: "com.apple.ttsbundle.gryphon-neural_Simone_en-US_premium", name: "Simone", language: "en-US", quality: .premium)
    ]

    static func manifest() throws -> VoiceGalleryManifest {
        try VoiceGalleryManifest.decode(Data(manifestJSON.utf8))
    }

    /// Every file exists except the ones named.
    static func gallery(missingFileNames: Set<String> = [], isQwenAvailable: Bool = true) throws -> VoiceGallery {
        VoiceGallery.build(manifest: try manifest(), manifestDirectory: manifestDirectory, appleVoices: appleVoices,
                           isQwenAvailable: isQwenAvailable, fileExists: { !missingFileNames.contains(($0 as NSString).lastPathComponent) })
    }

    static func freshDefaults(_ name: String = #function) -> UserDefaults {
        let suiteName = "clicky.voiceGalleryTests.\(name).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}

struct VoiceGalleryManifestTests {
    @Test func decodesTheCandidatesManifest() throws {
        let manifest = try VoiceGalleryFixtures.manifest()
        #expect(manifest.version == 1)
        #expect(manifest.voices.map(\.id) == ["voice1", "voice2", "voice3", "voice4", "voice5", "voice6"])
        #expect(manifest.voices[2].pitchHz == 205)
        #expect(manifest.voices[2].sample == "voice3-sample.wav")
        #expect(manifest.current?.id == "clicky-voice")
        #expect(manifest.current?.sample == nil)
        #expect(manifest.sampleText == "Here is the Wi-Fi setting you asked about.")
    }

    @Test func toleratesMissingOptionalFields() throws {
        let manifest = try VoiceGalleryManifest.decode(Data(#"{"voices": [{"id": "a", "name": "A", "reference": "a.wav"}]}"#.utf8))
        #expect(manifest.voices.count == 1)
        #expect(manifest.voices[0].pitchHz == nil && manifest.voices[0].sample == nil)
        #expect(manifest.current == nil && manifest.sampleText == nil)
        let gallery = VoiceGallery.build(manifest: manifest, manifestDirectory: "/x", appleVoices: [], isQwenAvailable: true, fileExists: { _ in true })
        #expect(gallery.sampleText == VoiceGallery.fallbackSampleText)
        #expect(gallery.entries[0].pitchLabel == "–")
        #expect(gallery.entries[0].previewAudioPath == "/x/a.wav")
        let empty = try VoiceGalleryManifest.decode(Data("{}".utf8))
        #expect(empty.voices.isEmpty)
    }

    @Test func resolvesPathsAgainstTheManifestFolder() throws {
        let gallery = try VoiceGalleryFixtures.gallery()
        #expect(gallery["voice3"]?.referencePath == "/tmp/clicky-voice-fixture/candidates/voice3-ref.wav")
        #expect(gallery["voice3"]?.previewAudioPath == "/tmp/clicky-voice-fixture/candidates/voice3-sample.wav")
        // "../clicky-voice.wav" → the voice folder itself.
        #expect(gallery["clicky-voice"]?.referencePath == "/tmp/clicky-voice-fixture/clicky-voice.wav")
        // No sample for the current voice: Play plays its reference.
        #expect(gallery["clicky-voice"]?.previewAudioPath == "/tmp/clicky-voice-fixture/clicky-voice.wav")
    }

    @Test func missingFilesDisableOnlyThatEntry() throws {
        let gallery = try VoiceGalleryFixtures.gallery(missingFileNames: ["voice2-ref.wav", "voice4-sample.wav"])
        let voice2 = try #require(gallery["voice2"])
        #expect(!voice2.isEnabled)
        #expect(voice2.disabledReason?.contains("voice2-ref.wav") == true)
        // A missing sample still plays the reference and stays selectable.
        let voice4 = try #require(gallery["voice4"])
        #expect(voice4.isEnabled)
        #expect(voice4.previewAudioPath?.hasSuffix("voice4-ref.wav") == true)
        #expect(gallery.entries.filter(\.isEnabled).count == gallery.entries.count - 1)
    }

    @Test func noMLXCoreDisablesTheQwenVoicesOnly() throws {
        let gallery = try VoiceGalleryFixtures.gallery(isQwenAvailable: false)
        #expect(gallery.entries.filter(\.isQwen).allSatisfy { !$0.isEnabled })
        #expect(gallery.entries.filter { !$0.isQwen }.allSatisfy { $0.isEnabled })
    }

    @Test func aMissingManifestLeavesTheAppleVoices() {
        let gallery = VoiceGallery.load(manifestPath: "/nonexistent/clicky/manifest.json", appleVoices: VoiceGalleryFixtures.appleVoices, isQwenAvailable: true)
        #expect(gallery.entries.map(\.name) == ["Riya", "Akash", "Simone"])
        #expect(gallery.entries.map(\.number) == [1, 2, 3])
    }

    /// The owner's real candidates (read only), when this Mac has them.
    @Test func theInstalledCandidatesManifestLoadsIfPresent() throws {
        let manifestPath = VoiceGallery.standardizedPath(VoiceGallery.defaultManifestPath)
        guard FileManager.default.fileExists(atPath: manifestPath) else { return }
        let gallery = VoiceGallery.load(appleVoices: [], isQwenAvailable: true)
        #expect(gallery.entries.count >= 2)
        #expect(gallery.entries.last?.detail == "Qwen · current voice")
        for entry in gallery.entries where entry.isEnabled {
            #expect(FileManager.default.fileExists(atPath: try #require(entry.referencePath)))
        }
    }

    @Test func loadsAManifestFromDisk() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("voice-gallery-\(UUID().uuidString)/candidates", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
        try Data(VoiceGalleryFixtures.manifestJSON.utf8).write(to: directory.appendingPathComponent("manifest.json"))
        // Only voice1's two files exist.
        try Data([0]).write(to: directory.appendingPathComponent("voice1-ref.wav"))
        try Data([0]).write(to: directory.appendingPathComponent("voice1-sample.wav"))
        let gallery = VoiceGallery.load(manifestPath: directory.appendingPathComponent("manifest.json").path, appleVoices: [], isQwenAvailable: true)
        #expect(gallery.entries.count == 7)
        #expect(gallery.entries.filter(\.isEnabled).map(\.id) == ["voice1"])
    }
}

struct VoiceGalleryOrderTests {
    @Test func qwenVoicesThenCurrentThenAppleEnhancedAndPremiumEnglish() throws {
        let gallery = try VoiceGalleryFixtures.gallery()
        #expect(gallery.entries.map(\.id) == [
            "voice1", "voice2", "voice3", "voice4", "voice5", "voice6", "clicky-voice",
            "apple:com.apple.ttsbundle.gryphon-neural_Riya_en-IN_premium", "apple:com.apple.siri.natural.Akash",
            "apple:com.apple.ttsbundle.gryphon-neural_Simone_en-US_premium"
        ])
        #expect(gallery.entries.map(\.number) == Array(1...10))
        #expect(gallery.entry(number: 3)?.name == "Voice 3 · soft")
        #expect(gallery.entry(number: 7)?.detail == "Qwen · current voice")
        #expect(gallery.entry(number: 8)?.detail == "Apple · en-IN · Premium")
        #expect(gallery.entry(number: 9)?.detail == "Apple · en-IN · Enhanced")
        #expect(gallery.entry(number: 0) == nil && gallery.entry(number: 11) == nil)
        #expect(gallery.entry(number: 1)?.pitchLabel == "222 Hz")
    }

    @Test func activeEntryFollowsTheSettings() throws {
        let gallery = try VoiceGalleryFixtures.gallery()
        #expect(gallery.activeEntryID(usesQwenVoice: true, referenceClipPath: "/tmp/clicky-voice-fixture/candidates/voice5-ref.wav", appleVoiceIdentifier: nil) == "voice5")
        // Another spelling of the same file still matches.
        #expect(gallery.activeEntryID(usesQwenVoice: true, referenceClipPath: "/tmp/clicky-voice-fixture/candidates/../clicky-voice.wav", appleVoiceIdentifier: nil) == "clicky-voice")
        #expect(gallery.activeEntryID(usesQwenVoice: true, referenceClipPath: "/elsewhere/custom.wav", appleVoiceIdentifier: nil) == nil)
        #expect(gallery.activeEntryID(usesQwenVoice: false, referenceClipPath: "/tmp/clicky-voice-fixture/candidates/voice5-ref.wav",
                                      appleVoiceIdentifier: "com.apple.siri.natural.Akash") == "apple:com.apple.siri.natural.Akash")
        #expect(gallery.activeEntryID(usesQwenVoice: false, referenceClipPath: "", appleVoiceIdentifier: "com.apple.voice.compact.en-US.Samantha") == nil)
    }
}

struct VoiceGalleryCommandTests {
    @Test(arguments: ["change voice", "Change your voice.", "next voice", "Hey Clicky, change your voice please", "switch voices",
                      "try a different voice", "another voice", "can you change your voice"])
    func nextPhrases(_ utterance: String) {
        #expect(VoiceGalleryCommand.parse(utterance) == .next)
    }

    @Test(arguments: ["previous voice", "go back to the old voice", "Go back to the old voice!", "old voice", "change your voice back",
                      "back to the previous voice", "use your old voice"])
    func previousPhrases(_ utterance: String) {
        #expect(VoiceGalleryCommand.parse(utterance) == .previous)
    }

    @Test(arguments: ["show voices", "voice gallery", "open the voice gallery", "Show me the voices.", "list voices"])
    func showPhrases(_ utterance: String) {
        #expect(VoiceGalleryCommand.parse(utterance) == .show)
    }

    @Test func selectByNumber() {
        #expect(VoiceGalleryCommand.parse("use voice 3") == .select(number: 3))
        #expect(VoiceGalleryCommand.parse("Use voice 3.") == .select(number: 3))
        #expect(VoiceGalleryCommand.parse("voice number three") == .select(number: 3))
        #expect(VoiceGalleryCommand.parse("voice three") == .select(number: 3))
        #expect(VoiceGalleryCommand.parse("switch to voice 2") == .select(number: 2))
        #expect(VoiceGalleryCommand.parse("let's try voice five") == .select(number: 5))
        #expect(VoiceGalleryCommand.parse("change voice to 4") == .select(number: 4))
        #expect(VoiceGalleryCommand.parse("use the third voice") == .select(number: 3))
        #expect(VoiceGalleryCommand.parse("voice #10") == .select(number: 10))
        #expect(VoiceGalleryCommand.parse("okay clicky use voice number eight please") == .select(number: 8))
    }

    @Test(arguments: ["your voice is nice", "I like your voice", "voice", "use voice", "what voice is this", "next", "go back",
                      "change the voice in this video", "voice 3 is better than voice 2", "use the voice memo app",
                      "turn on voice control", "voice number", "voice zero", "voice 0", "how do I change my voice in Zoom",
                      "show agents", "change voice to three hundred"])
    func notVoiceCommands(_ utterance: String) {
        #expect(VoiceGalleryCommand.parse(utterance) == nil)
    }

    @Test func boardCommandsAreUnaffected() {
        // "next" / "go back" stay board commands; the voice phrases aren't board commands.
        #expect(BoardVoiceCommand.parse("next") == .next)
        #expect(BoardVoiceCommand.parse("next voice") == nil)
        #expect(BoardVoiceCommand.parse("go back to the old voice") == nil)
    }

    @Test func promptLineIsInTheMainPrompt() {
        let prompt = SystemPromptBuilder.mainSystemPrompt(features: .current, sectionTexts: [:])
        #expect(prompt.contains(VoiceGalleryCommand.promptLine))
        #expect(VoiceGalleryCommand.promptLine.contains("next voice"))
        #expect(VoiceGalleryCommand.promptLine.contains("use voice 3"))
        #expect(VoiceGalleryCommand.promptLine.contains("show voices"))
        // Every phrase the line teaches really parses.
        for phrase in ["next voice", "change your voice", "use voice 3", "previous voice", "show voices"] {
            #expect(VoiceGalleryCommand.parse(phrase) != nil, "\(phrase)")
        }
    }
}

struct VoiceGalleryCyclingTests {
    @Test func nextWrapsRoundAndSkipsDisabled() throws {
        let gallery = try VoiceGalleryFixtures.gallery(missingFileNames: ["voice2-ref.wav"])
        #expect(gallery.nextEnabledEntry(after: "voice1")?.id == "voice3")
        #expect(gallery.nextEnabledEntry(after: "voice6")?.id == "clicky-voice")
        #expect(gallery.nextEnabledEntry(after: "apple:com.apple.ttsbundle.gryphon-neural_Simone_en-US_premium")?.id == "voice1")
        // Nothing active (a custom clip): the first enabled one.
        #expect(gallery.nextEnabledEntry(after: nil)?.id == "voice1")
        #expect(gallery.nextEnabledEntry(after: "unknown")?.id == "voice1")
        // Starting on a disabled entry still moves on.
        #expect(gallery.nextEnabledEntry(after: "voice2")?.id == "voice3")
    }

    @Test func previousWrapsRound() throws {
        let gallery = try VoiceGalleryFixtures.gallery(missingFileNames: ["voice2-ref.wav"])
        #expect(gallery.previousEnabledEntry(before: "voice3")?.id == "voice1")
        #expect(gallery.previousEnabledEntry(before: "voice1")?.id == "apple:com.apple.ttsbundle.gryphon-neural_Simone_en-US_premium")
        #expect(gallery.previousEnabledEntry(before: nil)?.id == "apple:com.apple.ttsbundle.gryphon-neural_Simone_en-US_premium")
    }

    @Test func aGalleryWithOneVoiceHasNoNext() {
        let gallery = VoiceGallery.build(manifest: nil, manifestDirectory: "/", appleVoices: [VoiceGalleryFixtures.appleVoices[0]], isQwenAvailable: true)
        #expect(gallery.nextEnabledEntry(after: gallery.entries[0].id) == nil)
        #expect(gallery.nextEnabledEntry(after: nil)?.id == gallery.entries[0].id)
    }
}

struct VoiceGallerySettingsTests {
    @Test func choosingAQwenVoiceWritesTheReferenceAndTurnsQwenOn() throws {
        let defaults = VoiceGalleryFixtures.freshDefaults()
        defaults.set(false, forKey: ClickySettings.LegacyKeys.usesQwenLocalVoice)
        defaults.set("com.apple.siri.natural.Akash", forKey: ClickySettings.LegacyKeys.selectedSpeechVoiceIdentifier)
        let store = VoiceGallerySettingsStore(defaults: defaults)
        let gallery = try VoiceGalleryFixtures.gallery()
        let before = store.activeEntryID(in: gallery, isQwenAvailable: true)
        #expect(before == "apple:com.apple.siri.natural.Akash")

        store.select(try #require(gallery["voice3"]), previouslyActiveEntryID: before)
        #expect(defaults.string(forKey: "v2.voice.qwen.referenceClip") == "/tmp/clicky-voice-fixture/candidates/voice3-ref.wav")
        #expect(defaults.object(forKey: "usesQwenLocalVoice") as? Bool == true)
        // The Apple pick is left alone for when Qwen is off again.
        #expect(defaults.string(forKey: "selectedSpeechVoiceIdentifier") == "com.apple.siri.natural.Akash")
        #expect(defaults.string(forKey: "v2.voice.gallery.previous") == "apple:com.apple.siri.natural.Akash")
        #expect(store.activeEntryID(in: gallery, isQwenAvailable: true) == "voice3")
    }

    @Test func choosingAnAppleVoiceWritesTheIdentifierAndTurnsQwenOff() throws {
        let defaults = VoiceGalleryFixtures.freshDefaults()
        let store = VoiceGallerySettingsStore(defaults: defaults)
        let gallery = try VoiceGalleryFixtures.gallery()
        // Unset settings: Qwen with the default clip (not the fixture's folder), so nothing matches.
        #expect(store.usesQwenVoice)
        #expect(store.referenceClipPath == QwenTuning.referenceClipDefaultPath)

        store.select(try #require(gallery.entry(number: 10)), previouslyActiveEntryID: "voice1")
        #expect(defaults.string(forKey: ClickySettings.LegacyKeys.selectedSpeechVoiceIdentifier) == "com.apple.ttsbundle.gryphon-neural_Simone_en-US_premium")
        #expect(defaults.object(forKey: ClickySettings.LegacyKeys.usesQwenLocalVoice) as? Bool == false)
        #expect(store.previousEntryID == "voice1")
        #expect(store.activeEntryID(in: gallery, isQwenAvailable: true) == "apple:com.apple.ttsbundle.gryphon-neural_Simone_en-US_premium")
    }

    @Test func reselectingTheSameVoiceKeepsPrevious() throws {
        let defaults = VoiceGalleryFixtures.freshDefaults()
        let store = VoiceGallerySettingsStore(defaults: defaults)
        let gallery = try VoiceGalleryFixtures.gallery()
        store.select(try #require(gallery["voice2"]), previouslyActiveEntryID: "voice1")
        store.select(try #require(gallery["voice2"]), previouslyActiveEntryID: "voice2")
        #expect(store.previousEntryID == "voice1")
    }

    @Test func commandsResolveAgainstTheActiveVoice() throws {
        let defaults = VoiceGalleryFixtures.freshDefaults()
        let store = VoiceGallerySettingsStore(defaults: defaults)
        let gallery = try VoiceGalleryFixtures.gallery(missingFileNames: ["voice4-ref.wav"])
        #expect(store.resolve(.next, in: gallery, activeEntryID: "voice3") == .select(try #require(gallery["voice5"])))
        #expect(store.resolve(.select(number: 2), in: gallery, activeEntryID: "voice3") == .select(try #require(gallery["voice2"])))
        #expect(store.resolve(.select(number: 4), in: gallery, activeEntryID: "voice3") == .unavailable("Voice 4 isn't available right now."))
        #expect(store.resolve(.select(number: 42), in: gallery, activeEntryID: "voice3") == .unavailable("There's no voice 42. I have 10."))
        #expect(store.resolve(.show, in: gallery, activeEntryID: nil) == .showGallery)
        // No saved previous: one step back in the gallery.
        #expect(store.resolve(.previous, in: gallery, activeEntryID: "voice3") == .select(try #require(gallery["voice2"])))
    }

    @Test func previousGoesBackToTheEarlierSelectionAndToggles() throws {
        let defaults = VoiceGalleryFixtures.freshDefaults()
        let store = VoiceGallerySettingsStore(defaults: defaults)
        let gallery = try VoiceGalleryFixtures.gallery()

        // Start on voice 1, "use voice 6", then "previous voice" → voice 1, again → voice 6.
        store.select(try #require(gallery["voice1"]), previouslyActiveEntryID: nil)
        var active = store.activeEntryID(in: gallery, isQwenAvailable: true)
        #expect(active == "voice1")
        guard case .select(let voice6) = store.resolve(.select(number: 6), in: gallery, activeEntryID: active) else { Issue.record("no voice 6"); return }
        store.select(voice6, previouslyActiveEntryID: active)
        active = store.activeEntryID(in: gallery, isQwenAvailable: true)
        #expect(active == "voice6")

        guard case .select(let backEntry) = store.resolve(.previous, in: gallery, activeEntryID: active) else { Issue.record("no previous"); return }
        #expect(backEntry.id == "voice1")
        store.select(backEntry, previouslyActiveEntryID: active)
        active = store.activeEntryID(in: gallery, isQwenAvailable: true)
        #expect(active == "voice1")
        guard case .select(let forwardAgain) = store.resolve(.previous, in: gallery, activeEntryID: active) else { Issue.record("no previous"); return }
        #expect(forwardAgain.id == "voice6")

        // "next voice" from Apple Simone wraps to voice 1.
        store.select(try #require(gallery.entry(number: 10)), previouslyActiveEntryID: active)
        active = store.activeEntryID(in: gallery, isQwenAvailable: true)
        #expect(store.resolve(.next, in: gallery, activeEntryID: active) == .select(try #require(gallery["voice1"])))
    }

    @Test func withoutQwenTheAppleVoiceIsActive() throws {
        let defaults = VoiceGalleryFixtures.freshDefaults()
        let store = VoiceGallerySettingsStore(defaults: defaults)
        let gallery = try VoiceGalleryFixtures.gallery(isQwenAvailable: false)
        // usesQwenLocalVoice unset (true) but no MLX Core: the automatic Apple voice speaks.
        #expect(store.activeEntryID(in: gallery, isQwenAvailable: false, automaticAppleVoiceIdentifier: "com.apple.siri.natural.Akash")
                == "apple:com.apple.siri.natural.Akash")
    }

    @Test func newKeyIsInTheCatalog() {
        #expect(ClickySettingsCatalog.entries.contains { $0.key == ClickySettings.Keys.voiceGalleryPrevious && $0.sectionName == "voice" })
    }
}

struct ReferenceClipCacheTests {
    @Test func readsOncePerPathAndReloadsWhenThePathChanges() {
        var reads: [String] = []
        let cache = ReferenceClipCache { path in
            reads.append(path)
            return "base64-of-" + (path as NSString).lastPathComponent
        }
        #expect(cache.base64(forPath: "/v/voice1-ref.wav") == "base64-of-voice1-ref.wav")
        #expect(cache.base64(forPath: "/v/voice1-ref.wav") == "base64-of-voice1-ref.wav")
        #expect(cache.loadCount == 1)
        // The setting changed: the next request reads the new clip.
        #expect(cache.base64(forPath: "/v/voice3-ref.wav") == "base64-of-voice3-ref.wav")
        #expect(cache.loadCount == 2)
        // Same file, other spelling: no re-read.
        #expect(cache.base64(forPath: "/v/x/../voice3-ref.wav") == "base64-of-voice3-ref.wav")
        #expect(cache.loadCount == 2)
        cache.invalidate()
        _ = cache.base64(forPath: "/v/voice3-ref.wav")
        #expect(cache.loadCount == 3)
        #expect(reads == ["/v/voice1-ref.wav", "/v/voice3-ref.wav", "/v/voice3-ref.wav"])
    }

    @Test func aMissingClipIsCachedAsNilUntilThePathChanges() {
        var loadCalls = 0
        let cache = ReferenceClipCache { path in
            loadCalls += 1
            return path.hasSuffix("good.wav") ? "ok" : nil
        }
        #expect(cache.base64(forPath: "/missing.wav") == nil)
        #expect(cache.base64(forPath: "/missing.wav") == nil)
        #expect(loadCalls == 1)
        #expect(cache.base64(forPath: "/good.wav") == "ok")
    }

    @Test func theDefaultLoaderOnlyAcceptsWAVs() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("clip-cache-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let notWAV = directory.appendingPathComponent("not.wav")
        try Data("hello".utf8).write(to: notWAV)
        #expect(ReferenceClipCache.loadWAVBase64(atPath: notWAV.path) == nil)
        #expect(ReferenceClipCache.loadWAVBase64(atPath: directory.appendingPathComponent("absent.wav").path) == nil)
        let wav = directory.appendingPathComponent("tone.wav")
        try Self.silentWAV(sampleCount: 2400).write(to: wav)
        #expect(ReferenceClipCache.loadWAVBase64(atPath: wav.path) == Self.silentWAV(sampleCount: 2400).base64EncodedString())
    }

    /// 16-bit mono 24 kHz silence.
    static func silentWAV(sampleCount: Int) -> Data {
        var data = Data()
        func append32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func append16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        let dataByteCount = UInt32(sampleCount * 2)
        data.append(contentsOf: Array("RIFF".utf8)); append32(36 + dataByteCount); data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); append32(16); append16(1); append16(1); append32(24_000); append32(48_000); append16(2); append16(16)
        data.append(contentsOf: Array("data".utf8)); append32(dataByteCount)
        data.append(Data(count: Int(dataByteCount)))
        return data
    }
}

// MARK: - Renders

/// Offscreen renders of VoiceGalleryView (ImageRenderer: no window, nothing
/// on screen, no audio) into ~/Library/Logs/Clicky/renders/voice/, light and
/// dark, with voice 3 active, voice 2 playing and voice 5's reference missing.
@MainActor
struct VoiceGalleryRenderTests {
    static let outputDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Clicky/renders/voice", isDirectory: true)

    static func render(appearanceName: NSAppearance.Name, colorScheme: ColorScheme) throws -> NSImage {
        let gallery = try VoiceGalleryFixtures.gallery(missingFileNames: ["voice5-ref.wav"])
        let content = VoiceGalleryView(gallery: gallery, activeEntryID: "voice3", playingEntryID: "voice2", actions: .inert, isScrollable: false)
            .frame(width: VoiceGalleryView.preferredWidth)
            .fixedSize(horizontal: false, vertical: true)
            .environment(\.colorScheme, colorScheme)
        let appearance = try #require(NSAppearance(named: appearanceName))
        var image: NSImage?
        appearance.performAsCurrentDrawingAppearance {
            let renderer = ImageRenderer(content: content)
            renderer.scale = 2
            image = renderer.nsImage
        }
        return try #require(image)
    }

    @Test func rendersLightAndDarkOffscreen() throws {
        let light = try Self.render(appearanceName: .aqua, colorScheme: .light)
        let dark = try Self.render(appearanceName: .darkAqua, colorScheme: .dark)
        #expect(light.size.width == VoiceGalleryView.preferredWidth)
        // Ten rows plus the header need a tall image.
        #expect(light.size.height > 500, "height \(light.size.height)")
        _ = try AgentsDashboardRenderTests.writePNGFile(light, to: Self.outputDirectory.appendingPathComponent("voice-gallery-light.png"))
        _ = try AgentsDashboardRenderTests.writePNGFile(dark, to: Self.outputDirectory.appendingPathComponent("voice-gallery-dark.png"))
        let lightLuminance = AgentsDashboardRenderTests.averageLuminance(light)
        let darkLuminance = AgentsDashboardRenderTests.averageLuminance(dark)
        #expect(lightLuminance > 0.7, "light luminance \(lightLuminance)")
        #expect(darkLuminance < 0.35, "dark luminance \(darkLuminance)")

        let empty = ImageRenderer(content: VoiceGalleryView(gallery: VoiceGallery(entries: [], sampleText: ""), activeEntryID: nil, playingEntryID: nil,
                                                            actions: .inert, isScrollable: false).frame(width: VoiceGalleryView.preferredWidth)).nsImage
        #expect(empty != nil)
    }
}

extension AgentsDashboardRenderTests {
    static func writePNGFile(_ image: NSImage, to fileURL: URL) throws -> URL {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let tiff = try #require(image.tiffRepresentation)
        let png = try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
        try png.write(to: fileURL)
        return fileURL
    }
}
