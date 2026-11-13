//
//  ProviderKeys.swift
//  leanring-buddy
//
//  Bring your own key: every AI and voice provider Theo can use, the keys for them in the macOS Keychain (generic
//  password, service "com.theo.providers", account = provider id), a real test call for each, and their live model
//  lists. Keys are never logged, never put in UserDefaults, and only ever sent to that provider's own address.
//

import Combine
import ClickyCore
import Foundation
import Security

enum ProviderKeychain {
    static let service = "com.theo.providers" + TheoProfile.keychainSuffix

    static func get(_ account: String) -> String? {
        // A live Sarvam test reads the owner's key where it lies: nothing is copied or shown.
        let usesOwnersKey = TheoProfile.isTest && account == "sarvam" && UserDefaults.standard.bool(forKey: "test.sarvam.useOwnerKey")
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: usesOwnersKey ? "com.theo.providers" : service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8), !value.isEmpty else { return nil }
        return value
    }

    @discardableResult
    static func set(_ value: String, for account: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return delete(account) }
        let match: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let updateStatus = SecItemUpdate(match as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if updateStatus == errSecSuccess { return true }
        var add = match
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    static func delete(_ account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}

struct ProviderInfo: Identifiable, Equatable, Codable {
    enum Protocol_: String, Codable {
        /// Anthropic's Messages API.
        case anthropic
        /// POST <base>/chat/completions with `Authorization: Bearer`, streamed.
        case openAICompatible
        /// A key that isn't for chat: voice, listening, or a service with its own API.
        case other
    }
    enum Group: String, Codable { case models, voice, local, custom }

    var id: String
    var label: String
    /// What it's good for, on one line.
    var blurb: String
    var group: Group
    var kind: Protocol_
    /// The API's base address (for openAICompatible, without /chat/completions).
    var baseURL: String
    var consoleURL: String?
    var keyHint: String
    /// Needs no key (a server on this Mac).
    var keyless = false
    /// GET path that lists models, relative to the base. Nil: the provider has no such endpoint.
    var modelsPath: String? = "/models"
    /// Shown when the live list isn't available.
    var knownModels: [String] = []
    /// A path used only to check a key, when listing models isn't how this provider does it.
    var testPath: String? = nil

    var canChat: Bool { kind != .other }

    static let builtIn: [ProviderInfo] = [
        ProviderInfo(id: "anthropic", label: "Anthropic", blurb: "Claude models, billed to your API account", group: .models, kind: .anthropic,
                     baseURL: "https://api.anthropic.com/v1", consoleURL: "https://console.anthropic.com/settings/keys", keyHint: "sk-ant-…",
                     knownModels: ["claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5", "claude-fable-5-1"]),
        ProviderInfo(id: "openai", label: "OpenAI", blurb: "GPT models and Codex on an API key", group: .models, kind: .openAICompatible,
                     baseURL: "https://api.openai.com/v1", consoleURL: "https://platform.openai.com/api-keys", keyHint: "sk-…"),
        ProviderInfo(id: "gemini", label: "Google Gemini", blurb: "Gemini models and Gemini CLI on an API key", group: .models, kind: .openAICompatible,
                     baseURL: "https://generativelanguage.googleapis.com/v1beta/openai", consoleURL: "https://aistudio.google.com/apikey", keyHint: "AIza…"),
        ProviderInfo(id: "xai", label: "xAI", blurb: "Grok models and Grok Build on an API key", group: .models, kind: .openAICompatible,
                     baseURL: "https://api.x.ai/v1", consoleURL: "https://console.x.ai", keyHint: "xai-…"),
        ProviderInfo(id: "openrouter", label: "OpenRouter", blurb: "One key for hundreds of models", group: .models, kind: .openAICompatible,
                     baseURL: "https://openrouter.ai/api/v1", consoleURL: "https://openrouter.ai/keys", keyHint: "sk-or-…", testPath: "/key"),
        ProviderInfo(id: "groq", label: "Groq", blurb: "Very fast open models", group: .models, kind: .openAICompatible,
                     baseURL: "https://api.groq.com/openai/v1", consoleURL: "https://console.groq.com/keys", keyHint: "gsk_…"),
        ProviderInfo(id: "mistral", label: "Mistral", blurb: "Mistral's own models", group: .models, kind: .openAICompatible,
                     baseURL: "https://api.mistral.ai/v1", consoleURL: "https://console.mistral.ai/api-keys", keyHint: "Your Mistral key"),
        ProviderInfo(id: "deepseek", label: "DeepSeek", blurb: "DeepSeek's reasoning and flash models", group: .models, kind: .openAICompatible,
                     baseURL: "https://api.deepseek.com", consoleURL: "https://platform.deepseek.com/api_keys", keyHint: "sk-…"),
        ProviderInfo(id: "sarvam", label: "Sarvam AI", blurb: "Indian-language chat, Bulbul voices, Saaras listening and Prism fast decisions", group: .models, kind: .openAICompatible,
                     baseURL: "https://api.sarvam.ai/v2", consoleURL: "https://dashboard.sarvam.ai", keyHint: "sk_…",
                     knownModels: ["sarvam-105b", "glm5.3", "gemma4", "deepseekv4.1-flash-1017"]),
        ProviderInfo(id: "together", label: "Together", blurb: "Hosted open models", group: .models, kind: .openAICompatible,
                     baseURL: "https://api.together.ai/v1", consoleURL: "https://api.together.ai/settings/api-keys", keyHint: "Your Together key"),
        ProviderInfo(id: "fireworks", label: "Fireworks", blurb: "Hosted open models", group: .models, kind: .openAICompatible,
                     baseURL: "https://api.fireworks.ai/inference/v1", consoleURL: "https://fireworks.ai/account/api-keys", keyHint: "fw_…"),
        ProviderInfo(id: "cerebras", label: "Cerebras", blurb: "Very fast open models", group: .models, kind: .openAICompatible,
                     baseURL: "https://api.cerebras.ai/v1", consoleURL: "https://cloud.cerebras.ai", keyHint: "csk-…"),
        ProviderInfo(id: "perplexity", label: "Perplexity", blurb: "Key only: its new Agent API isn't chat-compatible, so bots can't run on it yet", group: .models, kind: .other,
                     baseURL: "https://api.perplexity.ai/v1", consoleURL: "https://www.perplexity.ai/settings/api", keyHint: "pplx-…", modelsPath: nil),
        ProviderInfo(id: "cursor", label: "Cursor", blurb: "Runs Cursor Agent on a key, and Cursor's cloud agents", group: .models, kind: .other,
                     baseURL: "https://api.cursor.com", consoleURL: "https://cursor.com/dashboard?tab=integrations", keyHint: "key_…", modelsPath: nil, testPath: "/v0/me"),

        ProviderInfo(id: "elevenlabs", label: "ElevenLabs", blurb: "Natural voices for Clicky and Theo", group: .voice, kind: .other,
                     baseURL: "https://api.elevenlabs.io", consoleURL: "https://elevenlabs.io/app/settings/api-keys", keyHint: "sk_…", modelsPath: nil, testPath: "/v2/voices?page_size=1"),
        ProviderInfo(id: "deepgram", label: "Deepgram", blurb: "Hears what you say to Clicky", group: .voice, kind: .other,
                     baseURL: "https://api.deepgram.com", consoleURL: "https://console.deepgram.com", keyHint: "40-character key", modelsPath: nil, testPath: "/v1/projects"),
        ProviderInfo(id: "assemblyai", label: "AssemblyAI", blurb: "Hears what you say to Clicky", group: .voice, kind: .other,
                     baseURL: "https://api.assemblyai.com", consoleURL: "https://www.assemblyai.com/dashboard/api-keys", keyHint: "32-character key", modelsPath: nil, testPath: "/v2/transcript?limit=1"),

        ProviderInfo(id: "ollama", label: "Ollama", blurb: "Models running on this Mac, no key needed", group: .local, kind: .openAICompatible,
                     baseURL: "http://localhost:11434/v1", consoleURL: "https://ollama.com/download", keyHint: "", keyless: true),
        ProviderInfo(id: "lmstudio", label: "LM Studio", blurb: "Models running on this Mac, no key needed", group: .local, kind: .openAICompatible,
                     baseURL: "http://localhost:1234/v1", consoleURL: "https://lmstudio.ai", keyHint: "Optional", keyless: true),
    ]

    /// Provider ids that have a bundled logo (custom ones show their first letter).
    static func info(for id: String) -> ProviderInfo? {
        builtIn.first { $0.id == id }.map { ProviderOverrides.applied(to: $0) } ?? CustomProviders.all.first { $0.id == id }
    }

    /// The request that proves a key works. Pure, so it can be tested without the network.
    static func testRequest(for provider: ProviderInfo, key: String?) -> URLRequest? {
        guard let path = provider.testPath ?? provider.modelsPath, let url = URL(string: provider.baseURL + path) else {
            // Perplexity has nothing to list; the smallest real call is its Agent API.
            guard provider.id == "perplexity", let url = URL(string: provider.baseURL + "/agent") else { return nil }
            var request = URLRequest(url: url, timeoutInterval: 20)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            authorize(&request, provider: provider, key: key)
            request.httpBody = try? JSONSerialization.data(withJSONObject: ["model": "sonar", "input": "hi"])
            return request
        }
        var request = URLRequest(url: url, timeoutInterval: 20)
        authorize(&request, provider: provider, key: key)
        return request
    }

    /// Puts the key where this provider wants it.
    static func authorize(_ request: inout URLRequest, provider: ProviderInfo, key: String?) {
        guard let key, !key.isEmpty else { return }
        switch provider.id {
        case "anthropic":
            request.setValue(key, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        case "sarvam": request.setValue(key, forHTTPHeaderField: "api-subscription-key")
        case "elevenlabs": request.setValue(key, forHTTPHeaderField: "xi-api-key")
        case "deepgram": request.setValue("Token \(key)", forHTTPHeaderField: "Authorization")
        case "assemblyai": request.setValue(key, forHTTPHeaderField: "Authorization")
        case "cursor": request.setValue("Basic " + Data("\(key):".utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
        default: request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
    }

    /// A short message for a failed call; nil when it worked.
    static func testFailure(statusCode: Int, body: Data) -> String? {
        if (200..<300).contains(statusCode) { return nil }
        let detail = errorMessage(from: body)
        if statusCode == 401 || statusCode == 403 { return "Key rejected (\(statusCode))" + (detail.map { ": \($0.prefix(120))" } ?? "") }
        if statusCode == 429 { return "The key works, but it's rate limited right now" }
        return "HTTP \(statusCode)" + (detail.map { ": \($0.prefix(120))" } ?? "")
    }

    /// The provider's own words from an error body.
    static func errorMessage(from body: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: body) else {
            let text = String(decoding: body.prefix(200), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty || text.hasPrefix("<") ? nil : text
        }
        if let list = object as? [[String: Any]], let first = list.first { return message(in: first) }
        return (object as? [String: Any]).flatMap(message(in:))
    }

    private static func message(in object: [String: Any]) -> String? {
        if let error = object["error"] as? [String: Any] { return error["message"] as? String ?? error["code"] as? String }
        if let error = object["error"] as? String { return error }
        if let detail = object["detail"] as? [String: Any] { return detail["message"] as? String }
        return object["message"] as? String ?? object["detail"] as? String ?? object["err_msg"] as? String
    }

    /// Model ids from a provider's list reply: `data[].id`, `models[].name`, or a plain array.
    static func modelIDs(from body: Data) -> [String] {
        guard let object = try? JSONSerialization.jsonObject(with: body) else { return [] }
        let list: [Any]
        if let top = object as? [String: Any] { list = top["data"] as? [Any] ?? top["models"] as? [Any] ?? [] } else { list = object as? [Any] ?? [] }
        let ids = list.compactMap { entry -> String? in
            if let name = entry as? String { return name }
            guard let item = entry as? [String: Any] else { return nil }
            return item["id"] as? String ?? item["name"] as? String
        }
        // Gemini's list says "models/gemini-…"; its chat endpoint wants the bare name.
        return ids.map { $0.hasPrefix("models/") ? String($0.dropFirst(7)) : $0 }
    }
}

/// Base addresses the owner changed (a local server on another port).
enum ProviderOverrides {
    private static func key(_ id: String) -> String { "theo.providers.baseURL.\(id)" }
    static func baseURL(_ id: String) -> String? { UserDefaults.standard.string(forKey: key(id)).flatMap { $0.isEmpty ? nil : $0 } }
    static func setBaseURL(_ url: String?, for id: String) { UserDefaults.standard.set(url, forKey: key(id)) }
    static func applied(to provider: ProviderInfo) -> ProviderInfo {
        var provider = provider
        if let url = baseURL(provider.id) { provider.baseURL = url }
        return provider
    }
}

/// "Custom OpenAI-compatible": a name and base URL in UserDefaults, the key in the Keychain.
enum CustomProviders {
    private static let storageKey = "theo.providers.custom"

    static var all: [ProviderInfo] {
        get {
            guard let data = UserDefaults.standard.data(forKey: storageKey) else { return [] }
            return (try? JSONDecoder().decode([ProviderInfo].self, from: data)) ?? []
        }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: storageKey) }
    }

    /// Makes a provider out of a name and base URL. Nil when the address isn't a web address.
    static func make(name: String, baseURL: String) -> ProviderInfo? {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var address = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while address.hasSuffix("/") { address.removeLast() }
        guard !trimmedName.isEmpty, let url = URL(string: address), let scheme = url.scheme, ["http", "https"].contains(scheme), url.host != nil else { return nil }
        var id = "custom-" + BotsT3.slug(trimmedName)
        var suffix = 2
        while all.contains(where: { $0.id == id }) { id = "custom-\(BotsT3.slug(trimmedName))-\(suffix)"; suffix += 1 }
        return ProviderInfo(id: id, label: trimmedName, blurb: address, group: .custom, kind: .openAICompatible, baseURL: address,
                            consoleURL: nil, keyHint: "Leave empty if it needs no key")
    }
}

@MainActor
final class ProviderKeys: ObservableObject {
    static let shared = ProviderKeys()

    /// A provider whose row should open, with its key field ready, on the Models & API keys page.
    @Published var rowToOpen: String?

    struct TestResult: Equatable {
        let isOK: Bool
        let message: String
    }

    /// Bumps when any key changes so views refresh.
    @Published private(set) var revision = 0
    @Published private(set) var testResults: [String: TestResult] = [:]
    @Published private(set) var testingIDs: Set<String> = []
    /// Live model lists from the last successful test or refresh.
    @Published private(set) var modelLists: [String: [String]] = [:]
    /// Which providers have a saved key, kept here so drawing a screen never touches the Keychain.
    @Published private(set) var savedIDs: Set<String> = []
    private var masks: [String: String] = [:]

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.modelsKey), let lists = try? JSONDecoder().decode([String: [String]].self, from: data) {
            modelLists = lists
        }
        reloadSaved()
    }

    private static let modelsKey = "theo.providers.models"

    var providers: [ProviderInfo] { ProviderInfo.builtIn.map(ProviderOverrides.applied(to:)) + CustomProviders.all }

    /// After the Keychain changed behind the store's back (a test key): what's saved and its masks, read again.
    func refreshSaved() {
        reloadSaved()
        revision += 1
    }

    private func reloadSaved() {
        var saved: Set<String> = []
        var newMasks: [String: String] = [:]
        for provider in providers {
            guard let key = ProviderKeychain.get(provider.id) else { continue }
            saved.insert(provider.id)
            newMasks[provider.id] = Self.mask(key)
        }
        savedIDs = saved
        masks = newMasks
    }

    /// "sk_…a1b2": never the whole key.
    static func mask(_ key: String) -> String {
        key.count > 8 ? "\(key.prefix(3))••••\(key.suffix(4))" : "••••"
    }

    func key(for providerID: String) -> String? { ProviderKeychain.get(providerID) }
    func hasKey(for providerID: String) -> Bool { savedIDs.contains(providerID) }
    func maskedPreview(for providerID: String) -> String? { masks[providerID] }

    /// Whether Theo can use this provider now: a saved key, or a local server that answered its last test.
    func isUsable(_ provider: ProviderInfo) -> Bool {
        guard provider.canChat else { return false }
        // A key its provider just turned down isn't one to offer in the pickers.
        if testResults[provider.id]?.isOK == false { return false }
        if provider.keyless || provider.group == .custom { return hasKey(for: provider.id) || testResults[provider.id]?.isOK == true || !(modelLists[provider.id] ?? []).isEmpty }
        return hasKey(for: provider.id)
    }

    /// Providers bots, Theo and Clicky can run on right now.
    var usableChatProviders: [ProviderInfo] { providers.filter(isUsable) }

    /// The ones the owner left on for this kind of picker.
    func usableChatProviders(for use: ProviderUse) -> [ProviderInfo] {
        usableChatProviders.filter { ProviderUses.allows(use, providerID: $0.id) }
    }

    func setUse(_ use: ProviderUse, isOn: Bool, for providerID: String) {
        ProviderUses.set(isOn, use: use, providerID: providerID)
        revision += 1
    }

    func models(for provider: ProviderInfo) -> [String] {
        let live = modelLists[provider.id] ?? []
        return live.isEmpty ? provider.knownModels : live
    }

    @discardableResult
    func save(_ key: String, for providerID: String) -> Bool {
        let ok = ProviderKeychain.set(key, for: providerID)
        testResults[providerID] = nil
        reloadSaved()
        revision += 1
        return ok
    }

    func remove(_ providerID: String) {
        ProviderKeychain.delete(providerID)
        ProviderUses.forget(providerID: providerID)
        testResults[providerID] = nil
        modelLists[providerID] = nil
        storeModels()
        reloadSaved()
        revision += 1
    }

    func addCustom(_ provider: ProviderInfo) {
        CustomProviders.all.append(provider)
        revision += 1
    }

    func deleteCustom(_ providerID: String) {
        remove(providerID)
        CustomProviders.all.removeAll { $0.id == providerID }
        revision += 1
    }

    private func storeModels() {
        UserDefaults.standard.set(try? JSONEncoder().encode(modelLists), forKey: Self.modelsKey)
    }

    /// A real call with `draft` (what's typed in the field) or the saved key. Lists the models when it can.
    @discardableResult
    func test(_ providerID: String, draft: String? = nil) async -> TestResult {
        guard let provider = ProviderInfo.info(for: providerID) else { return TestResult(isOK: false, message: "Unknown provider") }
        let typed = draft?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let key = typed.isEmpty ? self.key(for: providerID) : typed
        guard key != nil || provider.keyless || provider.group == .custom else {
            let result = TestResult(isOK: false, message: "Paste a key first")
            testResults[providerID] = result
            return result
        }
        guard let request = ProviderInfo.testRequest(for: provider, key: key) else {
            return TestResult(isOK: false, message: "This provider has no way to test a key")
        }
        testingIDs.insert(providerID)
        defer { testingIDs.remove(providerID) }
        let result: TestResult
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if let failure = ProviderInfo.testFailure(statusCode: status, body: data) {
                // Some providers quote the key they were sent back in their error.
                result = TestResult(isOK: false, message: key.map { failure.replacingOccurrences(of: $0, with: "that key") } ?? failure)
            } else {
                var models = provider.modelsPath != nil && provider.testPath == nil ? ProviderInfo.modelIDs(from: data) : []
                if models.isEmpty, provider.testPath != nil, provider.canChat, let path = provider.modelsPath, let url = URL(string: provider.baseURL + path) {
                    // OpenRouter checks the key at /key; its list is a second call.
                    var list = URLRequest(url: url, timeoutInterval: 20)
                    ProviderInfo.authorize(&list, provider: provider, key: key)
                    if let (listData, _) = try? await URLSession.shared.data(for: list) { models = ProviderInfo.modelIDs(from: listData) }
                }
                if !models.isEmpty {
                    modelLists[providerID] = models
                    storeModels()
                }
                result = TestResult(isOK: true, message: models.isEmpty ? "Works" : "Works · \(models.count) model\(models.count == 1 ? "" : "s")")
            }
        } catch {
            let isRefused = (error as? URLError)?.code == .cannotConnectToHost
            result = TestResult(isOK: false, message: isRefused && provider.keyless ? "\(provider.label) isn't running on this Mac" : ((error as? URLError)?.localizedDescription ?? "Network error"))
        }
        testResults[providerID] = result
        return result
    }
}
