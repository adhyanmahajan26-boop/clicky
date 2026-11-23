import Foundation
import Testing
@testable import ClickyCore

struct ModelFreshnessTests {
    private func freshStore() -> UserDefaults {
        let name = "ModelFreshnessTests-\(UUID().uuidString)"
        let store = UserDefaults(suiteName: name)!
        store.removePersistentDomain(forName: name)
        return store
    }

    @Test func idsReadAsAFamilyAndVersions() {
        let sonnet = ModelVersionShape(modelID: "claude-sonnet-5-5")
        #expect(sonnet?.family == "claude-sonnet-#")
        #expect(sonnet?.versions == [[5, 5]])
        #expect(ModelVersionShape(modelID: "claude-sonnet-5")?.family == "claude-sonnet-#")
        let grok = ModelVersionShape(modelID: "grok-4.7-build-fast")
        #expect(grok?.family == "grok-#-build-fast")
        #expect(grok?.versions == [[4, 7]])
        #expect(ModelVersionShape(modelID: "gpt-4o-mini")?.family == "gpt-#o-mini")
        #expect(ModelVersionShape(modelID: "qwen3-235b")?.versions == [[3], [235]])
        #expect(ModelVersionShape(modelID: "deepseekv4.1-flash-1017")?.isSnapshot == true)
        #expect(ModelVersionShape(modelID: "claude-sonnet-4-5-20250929")?.isSnapshot == true)
        #expect(ModelVersionShape(modelID: "gpt-4o-2024-08-06")?.family == "gpt-#o")
        #expect(ModelVersionShape(modelID: "gemini-3-flash-preview")?.isPreview == true)
        #expect(ModelVersionShape(modelID: "anthropic/claude-opus-5-5")?.family == "anthropic/claude-opus-#")
    }

    @Test func aModelMovesOnlyToANewerOneOfItsOwnFamily() {
        let claude = ["claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5", "claude-fable-5-2", "claude-opus-4-8", "claude-sonnet-5"]
        #expect(ModelUpgrade.newer(than: "claude-sonnet-5", in: claude) == "claude-sonnet-5-5")
        #expect(ModelUpgrade.newer(than: "claude-opus-4-8", in: claude) == "claude-opus-5-5")
        #expect(ModelUpgrade.newer(than: "claude-fable-5-1", in: claude) == "claude-fable-5-2")
        #expect(ModelUpgrade.newer(than: "claude-sonnet-5-5", in: claude) == nil)
        #expect(ModelUpgrade.newer(than: "claude-haiku-4-5", in: claude) == "claude-haiku-5-5")
        // Never across families or sizes.
        #expect(ModelUpgrade.newer(than: "gpt-6-mini", in: ["gpt-6.1", "gpt-7"]) == nil)
        #expect(ModelUpgrade.newer(than: "gpt-6", in: ["gpt-6.1-mini", "gpt-6.1"]) == "gpt-6.1")
        #expect(ModelUpgrade.newer(than: "grok-4.6", in: ["grok-4.7-build-fast", "grok-4.7", "grok-4.5"]) == "grok-4.7")
        #expect(ModelUpgrade.newer(than: "qwen3-235b", in: ["qwen4-30b"]) == nil)
        #expect(ModelUpgrade.newer(than: "qwen3-235b", in: ["qwen4-235b"]) == "qwen4-235b")
        // Never onto a snapshot or a preview, and a pinned snapshot stays.
        #expect(ModelUpgrade.newer(than: "gemini-2.5-flash", in: ["gemini-3-flash-preview"]) == nil)
        #expect(ModelUpgrade.newer(than: "gpt-6", in: ["gpt-6.1-2026-10-01"]) == nil)
        #expect(ModelUpgrade.newer(than: "claude-sonnet-4-5-20250929", in: claude) == nil)
        // Not across providers in a shared list.
        #expect(ModelUpgrade.newer(than: "anthropic/claude-sonnet-5", in: ["claude-sonnet-5-5", "anthropic/claude-sonnet-5-5"]) == "anthropic/claude-sonnet-5-5")
        #expect(ModelUpgrade.newer(than: "opus", in: claude) == nil)
    }

    @Test func listsPutEachFamilysNewestFirst() {
        #expect(ModelUpgrade.newestFirst(["grok-4.5", "grok-4.7", "grok-4.6"]) == ["grok-4.7", "grok-4.6", "grok-4.5"])
        #expect(ModelUpgrade.newestFirst(["claude-sonnet-5", "claude-opus-5-5", "claude-sonnet-5-5"])
                == ["claude-sonnet-5-5", "claude-sonnet-5", "claude-opus-5-5"])
        #expect(ModelUpgrade.newestOfEachFamily(["claude-sonnet-5", "claude-opus-4-8", "claude-sonnet-5-5", "claude-opus-5-5", "claude-sonnet-4-5-20250929"])
                == ["claude-sonnet-5-5", "claude-opus-5-5"])
    }

    @Test func onlyChatModelsAreOffered() {
        let listed = ["gpt-6", "text-embedding-3-large", "gpt-4o-mini-tts", "whisper-1", "dall-e-3", "gpt-image-1", "omni-moderation-latest", "gpt-6", "gpt-6.1"]
        #expect(ModelListFilter.chatModels(listed) == ["gpt-6.1", "gpt-6"])
    }

    @Test func fastModeIsForOpusAndFable() {
        #expect(ClaudeFastMode.supports(model: "claude-opus-5-5"))
        #expect(ClaudeFastMode.supports(model: "claude-opus-5"))
        #expect(ClaudeFastMode.supports(model: "claude-opus-6"))
        #expect(ClaudeFastMode.supports(model: "claude-fable-5-2"))
        #expect(!ClaudeFastMode.supports(model: "claude-fable-5-1"))
        #expect(!ClaudeFastMode.supports(model: "claude-opus-4-8"))
        #expect(!ClaudeFastMode.supports(model: "claude-sonnet-5-5"))
        #expect(!ClaudeFastMode.supports(model: "claude-haiku-5-5"))
        #expect(!ClaudeFastMode.supports(model: "gpt-6"))
        #expect(ClaudeFastMode.supports(model: "opus"))
    }

    @Test func claudeCodesFirstLineNamesTheModel() {
        #expect(ClaudeAliasProbe.modelID(fromStreamLine: #"{"type":"system","subtype":"init","model":"claude-opus-5-5","tools":[]}"#) == "claude-opus-5-5")
        #expect(ClaudeAliasProbe.modelID(fromStreamLine: #"{"type":"system","subtype":"init","model":"claude-opus-5-5[1m]"}"#) == "claude-opus-5-5")
        #expect(ClaudeAliasProbe.modelID(fromStreamLine: #"{"type":"assistant","model":"claude-opus-5-5"}"#) == nil)
        #expect(ClaudeAliasProbe.modelID(fromStreamLine: #"{"type":"system","subtype":"init","model":"opus"}"#) == nil)
        #expect(ClaudeAliasProbe.modelID(fromStreamLine: "not json") == nil)
    }

    @Test func claudeModelsFoundLaterAreOfferedBesideTheBundledOnes() {
        let store = freshStore()
        #expect(ClaudeModelList.current(discovered: []) == ClickyModels.bundledIdentifiers)
        #expect(ClaudeModelList.remember(["claude-opus-6", "claude-sonnet-5-5", "gpt-6"], in: store))
        #expect(!ClaudeModelList.remember(["claude-opus-6"], in: store))
        let current = ClaudeModelList.current(discovered: ClaudeModelList.discovered(in: store))
        #expect(current == ["claude-opus-6", "claude-sonnet-5-5", "claude-haiku-5-5", "claude-fable-5-2"])
        #expect(ClaudeModelList.newest(family: "opus", discovered: ClaudeModelList.discovered(in: store)) == "claude-opus-6")
        #expect(ClaudeModelList.shortLabel(for: "claude-opus-6") == "Opus 6")
        #expect(ClaudeModelList.shortLabel(for: "claude-fable-5-2") == "Fable 5.2")
    }

    @Test func theSwitchIsOnUntilTurnedOffAndTheRecordKeepsTheNewestFirst() {
        let store = freshStore()
        #expect(ModelAutoUpgrade.isOn(in: store))
        ModelAutoUpgrade.setOn(false, in: store)
        #expect(!ModelAutoUpgrade.isOn(in: store))
        ModelAutoUpgrade.record(["A: one → two"], at: Date(timeIntervalSince1970: 100), in: store)
        ModelAutoUpgrade.record(["B: three → four"], at: Date(timeIntervalSince1970: 200), in: store)
        #expect(ModelAutoUpgrade.history(in: store).map(\.line) == ["B: three → four", "A: one → two"])
        #expect(ModelAutoUpgrade.isCheckDue(in: store))
        store.set(Date(), forKey: ModelAutoUpgrade.lastCheckKey)
        #expect(!ModelAutoUpgrade.isCheckDue(in: store))
        #expect(ModelAutoUpgrade.isCheckDue(now: Date().addingTimeInterval(13 * 3600), in: store))
    }

    @Test func aBareFamilyNameMeansItsNewestModel() {
        #expect(CodingIntent.claudeModelID(forHint: "fable") == ClickyModels.resolve("fable"))
        #expect(CodingIntent.claudeModelID(forHint: "opus 4.8") == "claude-opus-4-8")
    }
}
