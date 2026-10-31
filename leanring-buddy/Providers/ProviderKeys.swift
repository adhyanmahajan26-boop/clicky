//
//  ProviderKeys.swift
//  leanring-buddy
//
//  API keys for third-party providers, kept in the macOS Keychain
//  (generic password, service "com.theo.providers", account = provider id).
//  Keys are never logged or put in UserDefaults.
//

import Combine
import Foundation
import Security

enum ProviderKeychain {
    static let service = "com.theo.providers"

    static func get(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
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

struct ProviderInfo: Identifiable, Equatable {
    let id: String
    let label: String
    let consoleURL: URL
    let keyHint: String
    /// What the cheapest authenticated test call does.
    let testDescription: String

    static let all: [ProviderInfo] = [
        ProviderInfo(id: "sarvam", label: "Sarvam AI", consoleURL: URL(string: "https://dashboard.sarvam.ai")!, keyHint: "sk_...", testDescription: "Translate one word"),
        ProviderInfo(id: "openai", label: "OpenAI", consoleURL: URL(string: "https://platform.openai.com/api-keys")!, keyHint: "sk-...", testDescription: "List models"),
        ProviderInfo(id: "anthropic", label: "Anthropic API", consoleURL: URL(string: "https://console.anthropic.com/settings/keys")!, keyHint: "sk-ant-...", testDescription: "List models"),
        ProviderInfo(id: "gemini", label: "Google Gemini", consoleURL: URL(string: "https://aistudio.google.com/apikey")!, keyHint: "AIza...", testDescription: "List models"),
        ProviderInfo(id: "elevenlabs", label: "ElevenLabs", consoleURL: URL(string: "https://elevenlabs.io/app/settings/api-keys")!, keyHint: "sk_... (32+ chars)", testDescription: "List models"),
        ProviderInfo(id: "groq", label: "Groq", consoleURL: URL(string: "https://console.groq.com/keys")!, keyHint: "gsk_...", testDescription: "List models"),
        ProviderInfo(id: "xai", label: "xAI", consoleURL: URL(string: "https://console.x.ai")!, keyHint: "xai-...", testDescription: "List models"),
        ProviderInfo(id: "openrouter", label: "OpenRouter", consoleURL: URL(string: "https://openrouter.ai/keys")!, keyHint: "sk-or-...", testDescription: "Check key"),
        ProviderInfo(id: "deepgram", label: "Deepgram", consoleURL: URL(string: "https://console.deepgram.com")!, keyHint: "40-char hex key", testDescription: "List projects"),
        ProviderInfo(id: "assemblyai", label: "AssemblyAI", consoleURL: URL(string: "https://www.assemblyai.com/dashboard/api-keys")!, keyHint: "32-char hex key", testDescription: "List transcripts")
    ]

    static func info(for id: String) -> ProviderInfo? { all.first { $0.id == id } }

    /// The cheapest authenticated GET (Sarvam: a one-word POST, built separately).
    /// Pure, so it can be unit tested without the network.
    static func testRequest(providerID: String, key: String) -> URLRequest? {
        func get(_ url: String, _ headers: [String: String]) -> URLRequest? {
            guard let u = URL(string: url) else { return nil }
            var r = URLRequest(url: u, timeoutInterval: 15)
            for (k, v) in headers { r.setValue(v, forHTTPHeaderField: k) }
            return r
        }
        switch providerID {
        case "sarvam":
            return SarvamClient.makeTranslateRequest(apiKey: key, input: "hi", source: "en-IN", target: "hi-IN")
        case "openai": return get("https://api.openai.com/v1/models", ["Authorization": "Bearer \(key)"])
        case "anthropic": return get("https://api.anthropic.com/v1/models?limit=1", ["x-api-key": key, "anthropic-version": "2023-06-01"])
        case "gemini": return get("https://generativelanguage.googleapis.com/v1beta/models?pageSize=1", ["x-goog-api-key": key])
        case "elevenlabs": return get("https://api.elevenlabs.io/v1/models", ["xi-api-key": key])
        case "groq": return get("https://api.groq.com/openai/v1/models", ["Authorization": "Bearer \(key)"])
        case "xai": return get("https://api.x.ai/v1/models", ["Authorization": "Bearer \(key)"])
        case "openrouter": return get("https://openrouter.ai/api/v1/key", ["Authorization": "Bearer \(key)"])
        case "deepgram": return get("https://api.deepgram.com/v1/projects", ["Authorization": "Token \(key)"])
        case "assemblyai": return get("https://api.assemblyai.com/v2/transcript?limit=1", ["Authorization": key])
        default: return nil
        }
    }

    /// Maps a status code (and optional JSON error body) to a short message; nil = ok.
    static func testFailure(statusCode: Int, body: Data) -> String? {
        if (200..<300).contains(statusCode) { return nil }
        if statusCode == 401 || statusCode == 403 { return "Key rejected (\(statusCode))" }
        if statusCode == 429 { return "Key works but is rate limited (429)" }
        let snippet = SarvamClient.errorMessage(from: body) ?? ""
        return "HTTP \(statusCode)" + (snippet.isEmpty ? "" : ": \(snippet.prefix(120))")
    }
}

@MainActor
final class ProviderKeys: ObservableObject {
    static let shared = ProviderKeys()

    struct TestResult: Equatable {
        let isOK: Bool
        let message: String
    }

    let providers = ProviderInfo.all
    /// Bumps when any key changes so views refresh.
    @Published private(set) var revision = 0
    @Published private(set) var testResults: [String: TestResult] = [:]
    @Published private(set) var testingIDs: Set<String> = []

    func key(for providerID: String) -> String? { ProviderKeychain.get(providerID) }
    func hasKey(for providerID: String) -> Bool { key(for: providerID) != nil }

    /// A masked preview of the stored key ("sk_...a1b2"); never the whole key.
    func maskedPreview(for providerID: String) -> String? {
        guard let key = key(for: providerID) else { return nil }
        return key.count > 8 ? "\(key.prefix(3))••••\(key.suffix(4))" : "••••"
    }

    @discardableResult
    func save(_ key: String, for providerID: String) -> Bool {
        let ok = ProviderKeychain.set(key, for: providerID)
        testResults[providerID] = nil
        revision += 1
        return ok
    }

    func remove(_ providerID: String) {
        ProviderKeychain.delete(providerID)
        testResults[providerID] = nil
        revision += 1
    }

    /// Cheapest authenticated call. Returns and publishes ok / error text.
    @discardableResult
    func test(_ providerID: String) async -> TestResult {
        guard let key = key(for: providerID) else {
            let result = TestResult(isOK: false, message: "No key saved")
            testResults[providerID] = result
            return result
        }
        guard let request = ProviderInfo.testRequest(providerID: providerID, key: key) else {
            return TestResult(isOK: false, message: "Unknown provider")
        }
        testingIDs.insert(providerID)
        defer { testingIDs.remove(providerID) }
        let result: TestResult
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if let failure = ProviderInfo.testFailure(statusCode: status, body: data) {
                result = TestResult(isOK: false, message: failure)
            } else {
                result = TestResult(isOK: true, message: "OK")
            }
        } catch {
            result = TestResult(isOK: false, message: (error as? URLError)?.localizedDescription ?? "Network error")
        }
        testResults[providerID] = result
        return result
    }
}
