//
//  VoiceGallery.swift
//  ClickyCore
//
//  The voice gallery: the cloned Qwen voices prepared in
//  ~/.clicky/voice/candidates/manifest.json (voice1…voice6, then the
//  current Clicky voice) followed by the installed Apple Enhanced/Premium
//  English voices. Numbers are 1-based in that order, so "use voice 3" is
//  the third row the gallery shows. Pure Foundation: the app enumerates the
//  Apple voices and plays samples; this file decodes the manifest, builds
//  the entries, works out which one is active from the settings, cycles
//  next/previous, and writes a selection into an injected UserDefaults.
//
//  Choosing a Qwen voice copies nothing: v2.voice.qwen.referenceClip points
//  at that candidate's reference WAV (absolute path) and usesQwenLocalVoice
//  turns on. Choosing an Apple voice sets selectedSpeechVoiceIdentifier and
//  turns usesQwenLocalVoice off. The selection that was active before is
//  kept in v2.voice.gallery.previous for "previous voice".
//

import Foundation

// MARK: - Manifest

/// manifest.json as written by the candidate-prep script. Unknown keys are
/// ignored; a voice without a sample still decodes (its Play falls back to
/// the reference clip).
public struct VoiceGalleryManifest: Decodable, Equatable, Sendable {
    public struct Voice: Decodable, Equatable, Sendable {
        public let id: String
        public let name: String
        public let pitchHz: Double?
        /// Relative to the manifest's folder (or absolute).
        public let reference: String
        public let sample: String?

        public init(id: String, name: String, pitchHz: Double?, reference: String, sample: String?) {
            self.id = id
            self.name = name
            self.pitchHz = pitchHz
            self.reference = reference
            self.sample = sample
        }
    }

    public let version: Int?
    public let sampleText: String?
    public let voices: [Voice]
    public let current: Voice?

    public init(version: Int?, sampleText: String?, voices: [Voice], current: Voice?) {
        self.version = version
        self.sampleText = sampleText
        self.voices = voices
        self.current = current
    }

    private enum CodingKeys: String, CodingKey {
        case version, sampleText, voices, current
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version)
        sampleText = try container.decodeIfPresent(String.self, forKey: .sampleText)
        voices = try container.decodeIfPresent([Voice].self, forKey: .voices) ?? []
        current = try container.decodeIfPresent(Voice.self, forKey: .current)
    }

    public static func decode(_ manifestData: Data) throws -> VoiceGalleryManifest {
        try JSONDecoder().decode(VoiceGalleryManifest.self, from: manifestData)
    }
}

// MARK: - Entries

/// One installed Apple voice, as the app reads it from AVSpeechSynthesisVoice.
public struct AppleVoiceDescriptor: Equatable, Sendable {
    public enum Quality: String, Sendable {
        case standard, enhanced, premium
    }

    public let identifier: String
    public let name: String
    public let language: String
    public let quality: Quality

    public init(identifier: String, name: String, language: String, quality: Quality) {
        self.identifier = identifier
        self.name = name
        self.language = language
        self.quality = quality
    }
}

public struct VoiceGalleryEntry: Identifiable, Equatable, Sendable {
    public enum Engine: Equatable, Sendable {
        /// The absolute path of the WAV Qwen clones.
        case qwen(referencePath: String)
        case apple(voiceIdentifier: String)
    }

    /// "voice3", "clicky-voice", or "apple:<identifier>".
    public let id: String
    /// 1-based position in the gallery ("voice 3").
    public let number: Int
    public let name: String
    /// A short second line: "Qwen · cloned", "Qwen · current voice", "Apple · en-IN · Premium".
    public let detail: String
    public let pitchHz: Double?
    public let engine: Engine
    /// What Play plays for a Qwen voice (the sample, else the reference). nil for Apple voices.
    public let previewAudioPath: String?
    public let isEnabled: Bool
    /// Why it can't be chosen (a missing reference WAV, no MLX Core).
    public let disabledReason: String?

    public init(id: String, number: Int, name: String, detail: String, pitchHz: Double?, engine: Engine,
                previewAudioPath: String?, isEnabled: Bool, disabledReason: String?) {
        self.id = id
        self.number = number
        self.name = name
        self.detail = detail
        self.pitchHz = pitchHz
        self.engine = engine
        self.previewAudioPath = previewAudioPath
        self.isEnabled = isEnabled
        self.disabledReason = disabledReason
    }

    public var isQwen: Bool {
        if case .qwen = engine { return true }
        return false
    }

    public var referencePath: String? {
        if case .qwen(let referencePath) = engine { return referencePath }
        return nil
    }

    public var appleVoiceIdentifier: String? {
        if case .apple(let voiceIdentifier) = engine { return voiceIdentifier }
        return nil
    }

    /// "222 Hz", or "–" when unknown (Apple voices).
    public var pitchLabel: String {
        guard let pitchHz else { return "–" }
        return "\(Int(pitchHz.rounded())) Hz"
    }

    public static func appleEntryID(voiceIdentifier: String) -> String { "apple:" + voiceIdentifier }
}

// MARK: - Gallery

public struct VoiceGallery: Equatable, Sendable {
    public static let defaultManifestPath = "~/.clicky/voice/candidates/manifest.json"
    public static let fallbackSampleText = "Here is the Wi-Fi setting you asked about. Click the blue button on the right, then pick your network, and you are done."
    /// Said in the new voice after a spoken switch.
    public static let confirmationLine = "How's this voice?"

    public let entries: [VoiceGalleryEntry]
    /// What Apple voices say when their Play is pressed.
    public let sampleText: String

    public init(entries: [VoiceGalleryEntry], sampleText: String) {
        self.entries = entries
        self.sampleText = sampleText
    }

    /// Manifest Qwen voices first (in manifest order), then the current
    /// voice, then the Apple Enhanced/Premium English voices in the order
    /// given. A Qwen entry whose reference WAV is missing (or with no MLX
    /// Core) is listed but disabled. `fileExists` is injected for tests.
    public static func build(manifest: VoiceGalleryManifest?, manifestDirectory: String, appleVoices: [AppleVoiceDescriptor],
                             isQwenAvailable: Bool, fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> VoiceGallery {
        var entries: [VoiceGalleryEntry] = []
        var seenIDs: Set<String> = []

        func addQwenVoice(_ voice: VoiceGalleryManifest.Voice, isCurrent: Bool) {
            guard !seenIDs.contains(voice.id) else { return }
            seenIDs.insert(voice.id)
            let referencePath = resolve(voice.reference, relativeTo: manifestDirectory)
            let samplePath = voice.sample.map { resolve($0, relativeTo: manifestDirectory) }
            let hasReference = fileExists(referencePath)
            let previewAudioPath = [samplePath, hasReference ? referencePath : nil].compactMap { $0 }.first(where: fileExists)
            var disabledReason: String?
            if !hasReference {
                disabledReason = "Reference clip missing: \((referencePath as NSString).lastPathComponent)"
            } else if !isQwenAvailable {
                disabledReason = "Needs the local Qwen voice (MLX Core isn't installed)"
            }
            entries.append(VoiceGalleryEntry(id: voice.id, number: entries.count + 1, name: voice.name,
                                             detail: isCurrent ? "Qwen · current voice" : "Qwen · cloned",
                                             pitchHz: voice.pitchHz, engine: .qwen(referencePath: referencePath),
                                             previewAudioPath: previewAudioPath, isEnabled: disabledReason == nil, disabledReason: disabledReason))
        }

        if let manifest {
            manifest.voices.forEach { addQwenVoice($0, isCurrent: false) }
            if let currentVoice = manifest.current { addQwenVoice(currentVoice, isCurrent: true) }
        }

        for appleVoice in appleVoices where appleVoice.quality != .standard && appleVoice.language.lowercased().hasPrefix("en") {
            let entryID = VoiceGalleryEntry.appleEntryID(voiceIdentifier: appleVoice.identifier)
            guard !seenIDs.contains(entryID) else { continue }
            seenIDs.insert(entryID)
            let qualityName = appleVoice.quality == .premium ? "Premium" : "Enhanced"
            entries.append(VoiceGalleryEntry(id: entryID, number: entries.count + 1, name: appleVoice.name,
                                             detail: "Apple · \(appleVoice.language) · \(qualityName)", pitchHz: nil,
                                             engine: .apple(voiceIdentifier: appleVoice.identifier), previewAudioPath: nil,
                                             isEnabled: true, disabledReason: nil))
        }

        let sampleText = manifest?.sampleText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return VoiceGallery(entries: entries, sampleText: sampleText.isEmpty ? fallbackSampleText : sampleText)
    }

    /// Reads and decodes the manifest at `manifestPath`; a missing or broken
    /// manifest gives a gallery of just the Apple voices.
    public static func load(manifestPath: String = defaultManifestPath, appleVoices: [AppleVoiceDescriptor], isQwenAvailable: Bool) -> VoiceGallery {
        let expandedManifestPath = standardizedPath(manifestPath)
        let manifest = FileManager.default.contents(atPath: expandedManifestPath).flatMap { try? VoiceGalleryManifest.decode($0) }
        return build(manifest: manifest, manifestDirectory: (expandedManifestPath as NSString).deletingLastPathComponent,
                     appleVoices: appleVoices, isQwenAvailable: isQwenAvailable)
    }

    /// `~` expanded, `..` and `.` removed, so two spellings of a path compare equal.
    public static func standardizedPath(_ path: String) -> String {
        let expandedPath = (path.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expandedPath).standardizedFileURL.path
    }

    static func resolve(_ path: String, relativeTo directory: String) -> String {
        let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedPath.hasPrefix("/") || trimmedPath.hasPrefix("~") { return standardizedPath(trimmedPath) }
        return standardizedPath((directory as NSString).appendingPathComponent(trimmedPath))
    }

    // MARK: Lookup

    public subscript(entryID: String) -> VoiceGalleryEntry? {
        entries.first { $0.id == entryID }
    }

    /// "voice 3" → the third entry (1-based, as shown).
    public func entry(number: Int) -> VoiceGalleryEntry? {
        guard number >= 1, number <= entries.count else { return nil }
        return entries[number - 1]
    }

    /// The Qwen entry cloning `referencePath`, or the Apple entry for `appleVoiceIdentifier`.
    public func activeEntryID(usesQwenVoice: Bool, referenceClipPath: String, appleVoiceIdentifier: String?) -> String? {
        if usesQwenVoice {
            let activeReferencePath = Self.standardizedPath(referenceClipPath)
            return entries.first { $0.referencePath == activeReferencePath }?.id
        }
        guard let appleVoiceIdentifier else { return nil }
        return self[VoiceGalleryEntry.appleEntryID(voiceIdentifier: appleVoiceIdentifier)]?.id
    }

    // MARK: Cycling

    /// The next enabled entry after `entryID`, wrapping round; the first
    /// enabled one when nothing in the gallery is active.
    public func nextEnabledEntry(after entryID: String?) -> VoiceGalleryEntry? {
        step(from: entryID, forward: true)
    }

    /// The enabled entry before `entryID`, wrapping round.
    public func previousEnabledEntry(before entryID: String?) -> VoiceGalleryEntry? {
        step(from: entryID, forward: false)
    }

    private func step(from entryID: String?, forward: Bool) -> VoiceGalleryEntry? {
        let enabledEntries = entries.filter(\.isEnabled)
        guard !enabledEntries.isEmpty else { return nil }
        guard let entryID, let startIndex = entries.firstIndex(where: { $0.id == entryID }) else {
            return forward ? enabledEntries.first : enabledEntries.last
        }
        for offset in 1...entries.count {
            let candidateIndex = forward
                ? (startIndex + offset) % entries.count
                : (startIndex - offset + entries.count * 2) % entries.count
            let candidate = entries[candidateIndex]
            if candidate.isEnabled && candidate.id != entryID { return candidate }
        }
        return nil
    }
}

// MARK: - Settings

/// Reads and writes the gallery's settings in one UserDefaults (the app's
/// standard defaults; a suite in tests).
public struct VoiceGallerySettingsStore {
    public let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// The legacy default is true (Qwen whenever MLX Core is installed).
    public var usesQwenVoice: Bool {
        defaults.object(forKey: ClickySettings.LegacyKeys.usesQwenLocalVoice) as? Bool ?? true
    }

    /// The reference path the Qwen client clones (the default when unset).
    public var referenceClipPath: String {
        let path = (defaults.string(forKey: ClickySettings.Keys.qwenReferenceClip) ?? "").trimmingCharacters(in: .whitespaces)
        return path.isEmpty ? QwenTuning.referenceClipDefaultPath : path
    }

    public var appleVoiceIdentifier: String? {
        defaults.string(forKey: ClickySettings.LegacyKeys.selectedSpeechVoiceIdentifier)
    }

    public var previousEntryID: String? {
        let entryID = defaults.string(forKey: ClickySettings.Keys.voiceGalleryPrevious) ?? ""
        return entryID.isEmpty ? nil : entryID
    }

    /// The active entry. With Qwen unavailable the Apple voice is what speaks,
    /// and an unset Apple voice is the automatic one the app passes in.
    public func activeEntryID(in gallery: VoiceGallery, isQwenAvailable: Bool, automaticAppleVoiceIdentifier: String? = nil) -> String? {
        let usesQwen = usesQwenVoice && isQwenAvailable
        return gallery.activeEntryID(usesQwenVoice: usesQwen, referenceClipPath: referenceClipPath,
                                     appleVoiceIdentifier: appleVoiceIdentifier ?? automaticAppleVoiceIdentifier)
    }

    /// Writes `entry` as the voice; the one active before it becomes "previous".
    public func select(_ entry: VoiceGalleryEntry, previouslyActiveEntryID: String?) {
        switch entry.engine {
        case .qwen(let referencePath):
            defaults.set(referencePath, forKey: ClickySettings.Keys.qwenReferenceClip)
            defaults.set(true, forKey: ClickySettings.LegacyKeys.usesQwenLocalVoice)
        case .apple(let voiceIdentifier):
            defaults.set(voiceIdentifier, forKey: ClickySettings.LegacyKeys.selectedSpeechVoiceIdentifier)
            defaults.set(false, forKey: ClickySettings.LegacyKeys.usesQwenLocalVoice)
        }
        if let previouslyActiveEntryID, previouslyActiveEntryID != entry.id {
            defaults.set(previouslyActiveEntryID, forKey: ClickySettings.Keys.voiceGalleryPrevious)
        }
    }

    /// The entry a command picks, or why there isn't one.
    public func resolve(_ command: VoiceGalleryCommand, in gallery: VoiceGallery, activeEntryID: String?) -> VoiceGalleryResolution {
        switch command {
        case .show:
            return .showGallery
        case .next:
            guard let nextEntry = gallery.nextEnabledEntry(after: activeEntryID) else { return .unavailable(VoiceGalleryLines.noOtherVoice) }
            return .select(nextEntry)
        case .previous:
            if let previousEntryID, previousEntryID != activeEntryID, let previousEntry = gallery[previousEntryID], previousEntry.isEnabled {
                return .select(previousEntry)
            }
            guard let previousEntry = gallery.previousEnabledEntry(before: activeEntryID) else { return .unavailable(VoiceGalleryLines.noOtherVoice) }
            return .select(previousEntry)
        case .select(let number):
            guard let chosenEntry = gallery.entry(number: number) else {
                return .unavailable(VoiceGalleryLines.noSuchVoice(number: number, count: gallery.entries.count))
            }
            guard chosenEntry.isEnabled else { return .unavailable(VoiceGalleryLines.voiceUnavailable(number: number)) }
            return .select(chosenEntry)
        }
    }
}

public enum VoiceGalleryResolution: Equatable, Sendable {
    case select(VoiceGalleryEntry)
    case showGallery
    /// Nothing changes; the line is said in the current voice.
    case unavailable(String)
}

public enum VoiceGalleryLines {
    public static let noOtherVoice = "There's no other voice to switch to."
    public static func noSuchVoice(number: Int, count: Int) -> String {
        count == 0 ? "I don't have any other voices yet." : "There's no voice \(number). I have \(count)."
    }
    public static func voiceUnavailable(number: Int) -> String { "Voice \(number) isn't available right now." }
}

// MARK: - Reference clip cache

/// The Qwen client's reference clip as base64, loaded once per path: when
/// v2.voice.qwen.referenceClip changes, the next request reads the new
/// file. `invalidate()` forces a re-read of the same path.
public final class ReferenceClipCache {
    private let loadBase64: (String) -> String?
    private var cachedPath: String?
    private var cachedBase64: String?
    /// How many times a file was read (tests).
    public private(set) var loadCount = 0

    public init(loadBase64: @escaping (String) -> String? = ReferenceClipCache.loadWAVBase64) {
        self.loadBase64 = loadBase64
    }

    public func base64(forPath path: String) -> String? {
        let standardizedPath = VoiceGallery.standardizedPath(path)
        if let cachedPath, cachedPath == standardizedPath { return cachedBase64 }
        loadCount += 1
        cachedBase64 = loadBase64(standardizedPath)
        cachedPath = standardizedPath
        return cachedBase64
    }

    public func invalidate() {
        cachedPath = nil
        cachedBase64 = nil
    }

    /// The file as base64 if it is a WAV the client can send; nil otherwise.
    public static func loadWAVBase64(atPath path: String) -> String? {
        guard let clipData = FileManager.default.contents(atPath: path), PCMAudio(wavData: clipData) != nil else { return nil }
        return clipData.base64EncodedString()
    }
}
