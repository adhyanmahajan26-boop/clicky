//
//  BrainChoice.swift
//  ClickyCore
//
//  Which brain Theo uses when the owner hasn't said, so nothing assumes Claude Code. A brain is a command-line agent
//  that is installed and not signed out (Claude Code, Codex, Cursor Agent, OpenCode) or an API key Theo can chat with.
//  The app builds a `BrainInventory` from what it finds on this Mac; the rules that read it live here so they're tested:
//
//  - Setup opens at launch only when no brain at all is usable.
//  - The first bot (Theo) and Clicky start on a brain that works here.
//  - Helpers default to a cheap model of the main brain (Haiku on Claude).
//  - A failing bot engine is stood in for by the owner's chosen fallback brain, and by Claude only when Claude is ready.
//  - Error words name the brain that failed and its own fix.
//

import Foundation

/// What can think on this Mac right now.
public struct BrainInventory: Equatable, Sendable {
    /// An API provider Theo can chat with (a saved key, or a local server that answered), and the models it offers.
    public struct APIBrain: Equatable, Sendable {
        public var providerID: String
        public var models: [String]

        public init(providerID: String, models: [String]) {
            self.providerID = providerID
            self.models = models
        }
    }

    /// Command-line brains that are installed and not known to be signed out.
    public var readyTools: Set<BrainProvider>
    /// API providers in the owner's order.
    public var apiBrains: [APIBrain]

    public init(readyTools: Set<BrainProvider> = [], apiBrains: [APIBrain] = []) {
        self.readyTools = readyTools
        self.apiBrains = apiBrains
    }

    /// Something can answer: a ready tool or a usable key.
    public var hasUsableBrain: Bool { !readyTools.isEmpty || !apiBrains.isEmpty }

    /// Whether a model setting ("claude-sonnet-5-5", "codex:gpt-6", "api:openai/gpt-6-mini") can run here now.
    public func isUsable(_ setting: String) -> Bool {
        let model = BrainModel(setting: setting)
        if model.provider == .api {
            guard let providerID = Self.apiProviderID(of: model) else { return false }
            return apiBrains.contains { $0.providerID == providerID }
        }
        return readyTools.contains(model.provider)
    }

    /// "api:openai/gpt-6" → "openai". Nil for anything that isn't an API setting with a provider.
    public static func apiProviderID(of model: BrainModel) -> String? {
        guard model.provider == .api else { return nil }
        let parts = model.modelIdentifier.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        return parts[0]
    }

    /// The order tools are tried in when nothing chosen works: a subscription the owner already pays for comes before a key.
    public static let toolOrder: [BrainProvider] = [.claude, .codex, .cursor, .opencode]

    /// The brain to answer with: `current` when it works here; else the first ready tool on its default model (Claude:
    /// Sonnet); else the first API key on its preferred model. Nil when nothing here can think.
    /// `toolDefaultModels` is each tool's own default model id ("" or missing: the tool picks).
    public func startingModel(current: String, toolDefaultModels: [BrainProvider: String] = [:]) -> String? {
        if isUsable(current) { return current }
        for tool in Self.toolOrder where readyTools.contains(tool) {
            if tool == .claude { return ClickyModels.sonnet }
            return BrainModel(provider: tool, modelIdentifier: toolDefaultModels[tool] ?? "").setting
        }
        for apiBrain in apiBrains {
            guard let model = APIModelDefaults.preferredChatModel(providerID: apiBrain.providerID, models: apiBrain.models) else { continue }
            return BrainModel(provider: .api, modelIdentifier: "\(apiBrain.providerID)/\(model)").setting
        }
        return nil
    }
}

/// Which model an API key starts on when the owner hasn't picked one.
public enum APIModelDefaults {
    /// Ids in a provider's model list that aren't for chatting (speech, pictures, search indexes, safety filters).
    static let notChatWords = ["embed", "tts", "whisper", "audio", "transcribe", "realtime", "image", "dall-e", "moderation",
                               "rerank", "guard", "speech", "search", "sora", "veo", "imagen"]

    /// Anthropic starts on Sonnet (the same default Claude Code gives); any other provider on the first model in its
    /// list that is for chatting. Nil when the list has none.
    public static func preferredChatModel(providerID: String, models: [String]) -> String? {
        if providerID == "anthropic" {
            if models.isEmpty || models.contains(ClickyModels.sonnet) { return ClickyModels.sonnet }
        }
        return models.first { model in
            let lowercased = model.lowercased()
            return !notChatWords.contains { lowercased.contains($0) }
        }
    }
}

/// The model hidden helpers run on when the owner hasn't picked one: a cheap model of the main brain.
public enum HelperBrain {
    /// Claude (subscription or Anthropic key) → Haiku on the same sign-in. Other brains have no cheaper model Theo can
    /// be sure of, so helpers use the main model itself: slower than Haiku, but it works for someone without Claude.
    public static func cheapModel(forMain mainSetting: String) -> String {
        let model = BrainModel(setting: mainSetting)
        switch model.provider {
        case .claude:
            return ClickyModels.haiku
        case .api:
            if BrainInventory.apiProviderID(of: model) == "anthropic" {
                return BrainModel(provider: .api, modelIdentifier: "anthropic/\(ClickyModels.haiku)").setting
            }
            return model.setting
        case .codex, .cursor, .opencode:
            return model.setting
        }
    }
}

/// A brain setting as a bot's engine: `NativeBot.provider` and `NativeBot.model` in the app.
public struct BotEngineChoice: Equatable, Sendable {
    /// "claude", "codex", "cursor", "opencode" or "api:<provider id>".
    public var provider: String
    public var model: String

    public init(provider: String, model: String) {
        self.provider = provider
        self.model = model
    }

    /// "claude-sonnet-5-5" → claude / claude-sonnet-5-5; "api:openai/gpt-6" → api:openai / gpt-6;
    /// "codex:gpt-6-luna" → codex / gpt-6-luna; "opencode:lmstudio/qwen" → opencode / lmstudio/qwen.
    public init(brainSetting: String) {
        let model = BrainModel(setting: brainSetting)
        switch model.provider {
        case .claude:
            self.init(provider: "claude", model: model.modelIdentifier)
        case .api:
            let parts = model.modelIdentifier.split(separator: "/", maxSplits: 1).map(String.init)
            if parts.count == 2 {
                self.init(provider: "api:\(parts[0])", model: parts[1])
            } else {
                self.init(provider: "api:\(model.modelIdentifier)", model: "")
            }
        case .codex, .cursor, .opencode:
            self.init(provider: model.provider.rawValue, model: model.modelIdentifier)
        }
    }

    /// The same engine as a brain setting, so the inventory can say whether it runs here. Nil for an engine that isn't
    /// a brain (Grok, Gemini CLI).
    public var brainSetting: String? {
        if provider == "claude" { return BrainModel(provider: .claude, modelIdentifier: model).setting }
        if provider.hasPrefix("api:") {
            return BrainModel(provider: .api, modelIdentifier: "\(provider.dropFirst("api:".count))/\(model)").setting
        }
        guard let brain = BrainProvider(rawValue: provider), brain != .api else { return nil }
        return BrainModel(provider: brain, modelIdentifier: model).setting
    }
}

/// Who answers for a bot whose engine keeps failing.
public enum EngineStandIn {
    /// Settings key for the owner's chosen stand-in brain (a brain setting; empty or missing: none chosen).
    public static let settingKey = "v3.bots.standInBrain"

    /// The owner's chosen brain when it runs here and isn't the engine that's failing; else Claude on `claudeModel`, but
    /// only when Claude Code is ready and isn't the one failing; else nil (the bot's own error stands, with its own fix).
    public static func pick(failingEngine: String, chosen: String?, inventory: BrainInventory, claudeModel: String) -> BotEngineChoice? {
        if let chosen, !chosen.isEmpty, chosen != "off", inventory.isUsable(chosen) {
            let engine = BotEngineChoice(brainSetting: chosen)
            if engine.provider != failingEngine { return engine }
        }
        if failingEngine != "claude", inventory.readyTools.contains(.claude) {
            return BotEngineChoice(provider: "claude", model: claudeModel)
        }
        return nil
    }
}

/// The plain words for a brain that can't answer: which brain, and its own fix. Nobody who doesn't use Claude is told
/// to run `claude auth login`.
public enum BrainTrouble {
    /// How to sign in again (or fix the key) for this kind of brain.
    public static func signInFix(for provider: BrainProvider) -> String {
        switch provider {
        case .claude: return "Run claude auth login in Terminal, or sign in from Settings \u{203A} Harnesses."
        case .codex: return "Run codex login in Terminal, or sign in from Settings \u{203A} Harnesses."
        case .cursor: return "Run cursor-agent login in Terminal, or sign in from Settings \u{203A} Harnesses."
        case .opencode: return "Run opencode auth login in Terminal, or sign in from Settings \u{203A} Harnesses."
        case .api: return "Check its key in Settings \u{203A} Models & API keys."
        }
    }

    /// How to get a brain that isn't on this Mac.
    public static func installFix(for provider: BrainProvider) -> String {
        switch provider {
        case .api: return "Add a key in Settings \u{203A} Models & API keys, or pick another brain."
        default: return "Install it from Settings \u{203A} Harnesses, or pick another brain (an API key works too)."
        }
    }

    /// One sentence for a brain that isn't there: "Codex isn't installed on this Mac. Install it from …".
    public static func notInstalled(brainName: String, provider: BrainProvider) -> String {
        "\(brainName) isn't installed on this Mac. \(installFix(for: provider))"
    }

    /// Words in an error that mean the brain turned down the sign-in or the key.
    public static func isSignInProblem(_ message: String) -> Bool {
        let lowercased = message.lowercased()
        return ["auth", "login", "log in", "sign in", "signed out", "401", "api key", "unauthorized", "invalid key"].contains { lowercased.contains($0) }
    }
}
