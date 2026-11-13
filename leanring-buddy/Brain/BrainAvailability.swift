//
//  BrainAvailability.swift
//  leanring-buddy
//
//  What can think on this Mac right now, as ClickyCore's `BrainInventory`: the command-line agents that are installed and
//  not signed out (from HarnessCenter's last check, or whether the command exists before the first check), and the API
//  keys Theo can chat with. Setup, the first bot, helpers, calls, dictation and the stand-in all ask here instead of
//  assuming Claude Code.
//

import ClickyCore
import Foundation

@MainActor
enum BrainAvailability {
    /// The harness id HarnessCenter checks for each command-line brain.
    private static func harnessID(for provider: BrainProvider) -> String { provider.rawValue }

    /// What can think here now. Doesn't run any command-line tool: it reads HarnessCenter's last check, and before
    /// the first check only looks for the command.
    static var inventory: BrainInventory {
        let center = HarnessCenter.shared
        let missingInTestProfile = TheoProfile.isTest ? Set(UserDefaults.standard.stringArray(forKey: "test.engines.missing") ?? []) : []
        var readyTools: Set<BrainProvider> = []
        for provider in BrainProvider.allCases {
            let harness = harnessID(for: provider)
            // A test profile can make a brain count as missing, so the no-Claude path can be tried on a Mac that has it.
            if missingInTestProfile.contains(harness) { continue }
            if center.hasStatus(for: harness) {
                if center.status(for: harness).ready { readyTools.insert(provider) }
            } else if BrainCLIRunner.locateExecutable(for: provider) != nil {
                readyTools.insert(provider)
            }
        }
        let keys = ProviderKeys.shared
        let apiBrains = keys.usableChatProviders(for: .clicky).map { BrainInventory.APIBrain(providerID: $0.id, models: keys.models(for: $0)) }
        return BrainInventory(readyTools: readyTools, apiBrains: apiBrains)
    }

    /// Claude Code is installed and not signed out: the only time anything falls back to Claude by itself.
    static var isClaudeReady: Bool { inventory.readyTools.contains(.claude) }

    /// Each command-line brain's own default model, for a brain picked automatically.
    static var toolDefaultModels: [BrainProvider: String] {
        var defaults: [BrainProvider: String] = [:]
        let center = HarnessCenter.shared
        for provider in [BrainProvider.codex, .cursor, .opencode] {
            if let model = center.resolvedModel(for: harnessID(for: provider)) { defaults[provider] = model }
        }
        return defaults
    }

    /// The brain to answer with when `current` doesn't work here (nil: nothing here can think yet).
    static func startingModel(current: String) -> String? {
        inventory.startingModel(current: current, toolDefaultModels: toolDefaultModels)
    }

    /// "Claude", "Codex", "OpenAI": the brain a model setting runs on, as the owner knows it (an API key: its provider).
    static func name(of setting: String) -> String {
        let model = BrainModel(setting: setting)
        switch model.provider {
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .cursor: return "Cursor"
        case .opencode: return "OpenCode"
        case .api:
            let providerID = BrainInventory.apiProviderID(of: model) ?? model.modelIdentifier
            return ProviderInfo.info(for: providerID)?.label ?? providerID
        }
    }

    /// The fix for a brain that turned down its sign-in or key.
    static func signInFix(for setting: String) -> String {
        BrainTrouble.signInFix(for: BrainModel(setting: setting).provider)
    }
}

extension BotsStore {
    /// Bots a fresh setup made before any brain was set up (Theo on Claude Sonnet, Clicky's team on Claude Haiku) move
    /// to a brain that works here, once Setup finishes. Nothing moves on a Mac where Claude Code is ready, and a bot the
    /// owner changed stays exactly as it is.
    func moveUntouchedStartersToWorkingBrain() {
        let inventory = BrainAvailability.inventory
        guard !inventory.readyTools.contains(.claude) else { return }
        let untouchedTheo = BotImport.starterEngineBeforeAnyBrain
        if var theo = bots.first(where: { $0.id == "theo" && $0.primary }), theo.provider == untouchedTheo.provider, theo.model == untouchedTheo.model {
            let engine = BotImport.starterEngine
            if engine != untouchedTheo, let setting = engine.brainSetting, inventory.isUsable(setting) {
                theo.provider = engine.provider
                theo.model = engine.model
                save(theo)
            }
        }
        let teamEngine = Self.clickyTeamEngine
        guard teamEngine.provider != "claude" else { return }
        for var teamBot in clickyTeam where teamBot.provider == "claude" && teamBot.model == ClickyDuty.model {
            teamBot.provider = teamEngine.provider
            teamBot.model = teamEngine.model
            save(teamBot)
        }
    }

    /// New bots on Clicky's team start on the helper brain, so a Mac without Claude Code still gets a team that answers.
    static var clickyTeamEngine: BotEngineChoice {
        let helper = BotEngineChoice(brainSetting: ClickyModels.helper)
        guard let setting = helper.brainSetting, BrainAvailability.inventory.isUsable(setting) else {
            return BotEngineChoice(provider: "claude", model: ClickyDuty.model)
        }
        return helper
    }
}
