import Foundation
import Testing
@testable import ClickyCore

/// The Diagnostics settings list (ClickySettingsCatalog) against the keys in ClickySettings.swift:
/// a new `v2.` key that nobody lists here fails this test, and every default fits its control.
struct ClickySettingsCatalogTests {
    static let settingsSourceURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/ClickyCore/Settings/ClickySettings.swift")

    /// Every `"v2.…"` string literal in ClickySettings.swift.
    static func v2KeyLiteralsInSettingsSource() throws -> Set<String> {
        let source = try String(contentsOf: settingsSourceURL, encoding: .utf8)
        let keyPattern = try NSRegularExpression(pattern: #""(v2\.[A-Za-z0-9.]+)""#)
        let matches = keyPattern.matches(in: source, range: NSRange(source.startIndex..., in: source))
        return Set(matches.compactMap { match in
            Range(match.range(at: 1), in: source).map { String(source[$0]) }
        })
    }

    @Test func everyV2KeyInSettingsSourceIsListed() throws {
        let listedKeys = Set(ClickySettingsCatalog.entries.map(\.key))
        let sourceKeys = try Self.v2KeyLiteralsInSettingsSource()
        #expect(!sourceKeys.isEmpty)
        #expect(sourceKeys.subtracting(listedKeys).isEmpty, "v2 keys missing from the catalog: \(sourceKeys.subtracting(listedKeys).sorted())")
    }

    @Test func legacyKeysAreListed() {
        let listedKeys = Set(ClickySettingsCatalog.entries.map(\.key))
        #expect(listedKeys.contains(ClickySettings.LegacyKeys.usesQwenLocalVoice))
        #expect(listedKeys.contains(ClickySettings.LegacyKeys.selectedSpeechVoiceIdentifier))
    }

    @Test func keysAreUniqueAndNamedInTheSettingsNamespace() {
        let keys = ClickySettingsCatalog.entries.map(\.key)
        #expect(Set(keys).count == keys.count)
        let reusedLegacyKeys: Set<String> = [ClickySettings.LegacyKeys.usesQwenLocalVoice, ClickySettings.LegacyKeys.selectedSpeechVoiceIdentifier]
        for key in keys { #expect(key.hasPrefix("v2.") || reusedLegacyKeys.contains(key), "\(key) is not a v2 or reused key") }
    }

    @Test func defaultsFitTheirControls() {
        for entry in ClickySettingsCatalog.entries {
            switch entry.kind {
            case .choice(let options, let defaultValue):
                #expect(options.contains(defaultValue), "\(entry.key) default \(defaultValue) isn't an option")
            case .integer(let defaultValue, let range, let step):
                #expect(range.contains(defaultValue) && step > 0, "\(entry.key) default is outside its range")
            case .number(let defaultValue, let range, let step):
                #expect(range.contains(defaultValue) && step > 0, "\(entry.key) default is outside its range")
            case .toggle, .text, .textList, .internalData:
                break
            }
        }
    }

    @Test func choiceDefaultsMatchTheAccessors() {
        // The accessors fall back to these same values when a key is unset.
        #expect(ClickySettingsCatalog.entries.first { $0.key == ClickySettings.Keys.voiceEchoMode }?.kind == .choice(options: ["open", "halfDuplex", "aec"], defaultValue: "open"))
        #expect(ClickySettingsCatalog.entries.first { $0.key == ClickySettings.Keys.whiteboardTheme }?.kind == .choice(options: ["paper", "chalk", "dark"], defaultValue: "dark"))
        #expect(ClickySettingsCatalog.entries.first { $0.key == ClickySettings.Keys.captionMaxLines }?.kind == .integer(defaultValue: 4, range: 1...10, step: 1))
    }

    @Test func sectionNamesComeFromTheKeyPath() {
        let voiceRate = ClickySettingsCatalog.entries.first { $0.key == ClickySettings.Keys.voiceRate }
        #expect(voiceRate?.sectionName == "voice")
        let legacy = ClickySettingsCatalog.entries.first { $0.key == ClickySettings.LegacyKeys.usesQwenLocalVoice }
        #expect(legacy?.sectionName == "pre-v2")
    }
}

struct SilentModeCommandTests {
    @Test func silentModePhrasesParse() {
        #expect(WakeListeningCommand.parse("hey claudia silent mode") == .silentModeOn)
        #expect(WakeListeningCommand.parse("just listen") == .silentModeOn)
        #expect(WakeListeningCommand.parse("okay you can talk again") == .silentModeOff)
        #expect(WakeListeningCommand.parse("silent mode off") == .silentModeOff)
        #expect(WakeListeningCommand.parse("what is silent mode in iOS") == nil)
    }
}
