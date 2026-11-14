import Foundation
import Testing
@testable import ClickyCore

/// Nothing assumes Claude Code: a Mac with only one API key, or only Codex, gets a working brain, helpers on that brain,
/// a stand-in that exists, and error words about the brain it actually uses.
@Suite struct BrainInventoryTests {
    let onlyOpenAIKey = BrainInventory(apiBrains: [.init(providerID: "openai", models: ["text-embedding-4", "gpt-6-mini", "gpt-6"])])
    let onlyCodex = BrainInventory(readyTools: [.codex])
    let claudeAndKey = BrainInventory(readyTools: [.claude], apiBrains: [.init(providerID: "anthropic", models: [])])

    @Test func nothingUsableMeansSetupIsNeeded() {
        #expect(!BrainInventory().hasUsableBrain)
        #expect(onlyOpenAIKey.hasUsableBrain)
        #expect(onlyCodex.hasUsableBrain)
    }

    @Test func aSettingIsUsableOnlyWhenItsBrainIsHere() {
        #expect(!onlyOpenAIKey.isUsable(ClickyModels.sonnet))
        #expect(onlyOpenAIKey.isUsable("api:openai/gpt-6"))
        #expect(!onlyOpenAIKey.isUsable("api:anthropic/claude-sonnet-5-5"))
        #expect(!onlyOpenAIKey.isUsable("api:openai"))
        #expect(onlyCodex.isUsable("codex:gpt-6-luna"))
        #expect(!onlyCodex.isUsable("cursor:sonnet-4.5"))
        #expect(claudeAndKey.isUsable(ClickyModels.sonnet))
    }

    @Test func theCurrentBrainStaysWhenItWorks() {
        #expect(claudeAndKey.startingModel(current: ClickyModels.opus) == ClickyModels.opus)
        #expect(onlyCodex.startingModel(current: "codex:gpt-6-luna") == "codex:gpt-6-luna")
    }

    @Test func aMacWithoutClaudeStartsOnWhatItHas() {
        // The default Sonnet setting doesn't work on a Mac with only an OpenAI key: the key's first chat model does.
        #expect(onlyOpenAIKey.startingModel(current: ClickyModels.sonnet) == "api:openai/gpt-6-mini")
        #expect(onlyCodex.startingModel(current: ClickyModels.sonnet, toolDefaultModels: [.codex: "gpt-6-luna"]) == "codex:gpt-6-luna")
        #expect(onlyCodex.startingModel(current: ClickyModels.sonnet) == "codex:")
        #expect(BrainInventory().startingModel(current: ClickyModels.sonnet) == nil)
    }

    @Test func aReadyToolComesBeforeAKey() {
        let both = BrainInventory(readyTools: [.opencode, .claude], apiBrains: [.init(providerID: "openai", models: ["gpt-6"])])
        #expect(both.startingModel(current: "api:groq/llama") == ClickyModels.sonnet)
        let noClaude = BrainInventory(readyTools: [.opencode], apiBrains: [.init(providerID: "openai", models: ["gpt-6"])])
        #expect(noClaude.startingModel(current: ClickyModels.sonnet, toolDefaultModels: [.opencode: "opencode/flash-free"]) == "opencode:opencode/flash-free")
    }

    @Test func anthropicKeysStartOnSonnetAndOthersOnAChatModel() {
        #expect(APIModelDefaults.preferredChatModel(providerID: "anthropic", models: []) == ClickyModels.sonnet)
        #expect(APIModelDefaults.preferredChatModel(providerID: "anthropic", models: ["claude-haiku-5-5", ClickyModels.sonnet]) == ClickyModels.sonnet)
        #expect(APIModelDefaults.preferredChatModel(providerID: "openai", models: ["whisper-2", "tts-1-hd", "gpt-6"]) == "gpt-6")
        #expect(APIModelDefaults.preferredChatModel(providerID: "openai", models: ["text-embedding-4"]) == nil)
        #expect(APIModelDefaults.preferredChatModel(providerID: "groq", models: []) == nil)
    }
}

@Suite struct HelperBrainTests {
    @Test func helpersAreACheapModelOfTheMainBrain() {
        #expect(HelperBrain.cheapModel(forMain: ClickyModels.opus) == ClickyModels.haiku)
        #expect(HelperBrain.cheapModel(forMain: "api:anthropic/claude-opus-5-5") == "api:anthropic/claude-haiku-5-5")
        #expect(HelperBrain.cheapModel(forMain: "api:openai/gpt-6") == "api:openai/gpt-6")
        #expect(HelperBrain.cheapModel(forMain: "codex:gpt-6-luna") == "codex:gpt-6-luna")
    }

    @Test func anEarlierSetupKeepsHaikuForItsHelpers() {
        let store = UserDefaults(suiteName: "helper-default-\(UUID().uuidString)")!
        ClickyModels.keepEarlierHelperDefaultOnce(setupWasCompleted: true, in: store)
        #expect(store.string(forKey: ClickySettings.Keys.modelsHelper) == ClickyModels.haiku)
    }

    @Test func aNewMacLetsHelpersFollowTheBrain() {
        let store = UserDefaults(suiteName: "helper-default-\(UUID().uuidString)")!
        ClickyModels.keepEarlierHelperDefaultOnce(setupWasCompleted: false, in: store)
        #expect(store.string(forKey: ClickySettings.Keys.modelsHelper) == nil)
        // Only once: finishing setup later doesn't pin Haiku on a Mac that never had it.
        ClickyModels.keepEarlierHelperDefaultOnce(setupWasCompleted: true, in: store)
        #expect(store.string(forKey: ClickySettings.Keys.modelsHelper) == nil)
    }

    @Test func aChosenHelperIsNeverReplaced() {
        let store = UserDefaults(suiteName: "helper-default-\(UUID().uuidString)")!
        store.set("codex:gpt-6-luna", forKey: ClickySettings.Keys.modelsHelper)
        ClickyModels.keepEarlierHelperDefaultOnce(setupWasCompleted: true, in: store)
        #expect(store.string(forKey: ClickySettings.Keys.modelsHelper) == "codex:gpt-6-luna")
    }
}

@Suite struct BotEngineChoiceTests {
    @Test func brainSettingsBecomeBotEngines() {
        #expect(BotEngineChoice(brainSetting: ClickyModels.sonnet) == BotEngineChoice(provider: "claude", model: ClickyModels.sonnet))
        #expect(BotEngineChoice(brainSetting: "api:openai/gpt-6") == BotEngineChoice(provider: "api:openai", model: "gpt-6"))
        #expect(BotEngineChoice(brainSetting: "codex:gpt-6-luna") == BotEngineChoice(provider: "codex", model: "gpt-6-luna"))
        #expect(BotEngineChoice(brainSetting: "opencode:lmstudio/qwen3") == BotEngineChoice(provider: "opencode", model: "lmstudio/qwen3"))
    }

    @Test func enginesGoBackToBrainSettings() {
        for setting in [ClickyModels.haiku, "api:openai/gpt-6", "codex:gpt-6-luna", "cursor:sonnet-4.5", "opencode:lmstudio/qwen3"] {
            #expect(BotEngineChoice(brainSetting: setting).brainSetting == setting)
        }
        #expect(BotEngineChoice(provider: "grok", model: "grok-4.7").brainSetting == nil)
    }
}

@Suite struct EngineStandInTests {
    let claudeReady = BrainInventory(readyTools: [.claude, .opencode])
    let noClaude = BrainInventory(readyTools: [.opencode], apiBrains: [.init(providerID: "openai", models: ["gpt-6"])])

    @Test func claudeStandsInOnlyWhenItIsReady() {
        #expect(EngineStandIn.pick(failingEngine: "opencode", chosen: nil, inventory: claudeReady, claudeModel: ClickyModels.haiku)
                == BotEngineChoice(provider: "claude", model: ClickyModels.haiku))
        #expect(EngineStandIn.pick(failingEngine: "opencode", chosen: nil, inventory: noClaude, claudeModel: ClickyModels.haiku) == nil)
    }

    @Test func theOwnersChoiceComesFirst() {
        #expect(EngineStandIn.pick(failingEngine: "opencode", chosen: "api:openai/gpt-6", inventory: noClaude, claudeModel: ClickyModels.haiku)
                == BotEngineChoice(provider: "api:openai", model: "gpt-6"))
        #expect(EngineStandIn.pick(failingEngine: "opencode", chosen: "api:openai/gpt-6", inventory: claudeReady, claudeModel: ClickyModels.haiku)
                == BotEngineChoice(provider: "claude", model: ClickyModels.haiku))
    }

    @Test func theFailingEngineNeverStandsInForItself() {
        #expect(EngineStandIn.pick(failingEngine: "api:openai", chosen: "api:openai/gpt-6", inventory: noClaude, claudeModel: ClickyModels.haiku) == nil)
        #expect(EngineStandIn.pick(failingEngine: "claude", chosen: nil, inventory: claudeReady, claudeModel: ClickyModels.haiku) == nil)
    }
}

@Suite struct BrainTroubleTests {
    @Test func signInWordsNameTheBrainInUse() {
        let failure = CLIStreamFailure.reportedError("401 Unauthorized: invalid api key")
        #expect(failure.spokenMessage == "I'm signed out of Claude. Run claude auth login in Terminal, then try again.")
        let openAI = failure.spokenMessage(brainName: "OpenAI", signInFix: BrainTrouble.signInFix(for: .api))
        #expect(openAI.contains("OpenAI"))
        #expect(!openAI.lowercased().contains("claude"))
        let codex = failure.spokenMessage(brainName: "Codex", signInFix: BrainTrouble.signInFix(for: .codex))
        #expect(codex.contains("codex login"))
        #expect(!codex.lowercased().contains("claude"))
    }

    @Test func otherFailuresNameTheBrainToo() {
        #expect(CLIStreamFailure.stalled.spokenMessage(brainName: "Codex", signInFix: "") == "Codex went quiet for too long, so I stopped it.")
        #expect(CLIStreamFailure.usageLimit(resetDescription: nil).spokenMessage(brainName: "Cursor", signInFix: "").contains("Cursor usage limit"))
        #expect(CLIStreamFailure.reportedError("model overloaded").spokenMessage(brainName: "OpenCode", signInFix: "") == "OpenCode ran into an error: model overloaded")
    }

    @Test func onlyClaudeIsToldToRunClaudeAuthLogin() {
        for provider in [BrainProvider.codex, .cursor, .opencode, .api] {
            #expect(!BrainTrouble.signInFix(for: provider).contains("claude"))
            #expect(!BrainTrouble.installFix(for: provider).lowercased().contains("claude"))
        }
        #expect(BrainTrouble.signInFix(for: .claude).contains("claude auth login"))
        #expect(BrainTrouble.notInstalled(brainName: "Codex", provider: .codex).hasPrefix("Codex isn't installed on this Mac."))
    }
}

@Suite struct BoardRepairOnAnyBrainTests {
    @Test func aPlainAnswerWithTheBoardIsRead() {
        let answer = """
            Here's the board:
            ```json
            {"title":"Fixed","dir":"TB","sections":[{"id":"q1","title":"One"}],"elements":[{"el":"box","id":"a","sec":"q1","text":"A"}],"steps":[{"show":["a"],"say":"hi"}]}
            ```
            """
        let outcome = WBRepairRequest.board(fromAnswerText: answer)
        #expect(outcome?.board.title == "Fixed")
        #expect(outcome?.board.elements.map(\.id) == ["a"])
        #expect(WBRepairRequest.board(fromAnswerText: "sorry, I can't") == nil)
        #expect(WBRepairRequest.board(fromAnswerText: "{not json}") == nil)
    }

    @Test func thePromptCarriesTheSchema() {
        #expect(WBRepairRequest.systemPromptTextForAnyBrain.hasPrefix(WBRepairRequest.systemPromptText))
        #expect(WBRepairRequest.systemPromptTextForAnyBrain.contains(WBRepairRequest.boardJSONSchema))
    }
}
