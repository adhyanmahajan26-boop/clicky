//
//  ContextWindows.swift
//  leanring-buddy
//
//  How many tokens the model behind a provider can hold, for ClickyCore `ContextBudget`. A cloud model's window is
//  known by its name; a local server says what it loaded: LM Studio's `/api/v0/models/<id>` (`loaded_context_length`)
//  and Ollama's `/api/ps` (`context_length`). Asked once per model and kept for ten minutes, since the owner can
//  reload a model with another context length.
//

import ClickyCore
import Foundation

@MainActor
enum ContextWindows {
    private static var reported: [String: (tokens: Int?, askedAt: Date)] = [:]
    private static let keptSeconds: TimeInterval = 600

    private static func cacheKey(_ provider: ProviderInfo, _ model: String) -> String { "\(provider.id)/\(model)" }

    /// The window as known now, without waiting: a local server's last answer, else the usual guess.
    static func knownTokens(provider: ProviderInfo, model: String) -> Int {
        let isLocal = provider.group == .local
        if isLocal, reported[cacheKey(provider, model)] == nil { Task { _ = await tokens(provider: provider, model: model) } }
        return ContextBudget.windowTokens(model: model, isLocalServer: isLocal, reportedTokens: reported[cacheKey(provider, model)]?.tokens)
    }

    /// The window, asking a local server what it loaded when the last answer is old.
    static func tokens(provider: ProviderInfo, model: String) async -> Int {
        let isLocal = provider.group == .local
        guard isLocal else { return ContextBudget.windowTokens(model: model, isLocalServer: false) }
        let key = cacheKey(provider, model)
        if let saved = reported[key], Date().timeIntervalSince(saved.askedAt) < keptSeconds {
            return ContextBudget.windowTokens(model: model, isLocalServer: true, reportedTokens: saved.tokens)
        }
        let asked = await askLocalServer(baseURL: provider.baseURL, model: model)
        reported[key] = (asked, Date())
        if let asked { print("🧠 \(provider.label) has \(model) loaded with \(asked) tokens of context") }
        return ContextBudget.windowTokens(model: model, isLocalServer: true, reportedTokens: asked)
    }

    private static func askLocalServer(baseURL: String, model: String) async -> Int? {
        var root = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if root.hasSuffix("/v1") { root.removeLast(3) }
        let session = URLSession(configuration: .ephemeral)
        // LM Studio
        if let escaped = model.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
           let url = URL(string: "\(root)/api/v0/models/\(escaped)") {
            var request = URLRequest(url: url)
            request.timeoutInterval = 2
            if let (data, _) = try? await session.data(for: request),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let loaded = object["loaded_context_length"] as? Int, loaded > 0 {
                return loaded
            }
        }
        // Ollama
        if let url = URL(string: "\(root)/api/ps") {
            var request = URLRequest(url: url)
            request.timeoutInterval = 2
            if let (data, _) = try? await session.data(for: request),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let models = object["models"] as? [[String: Any]],
               let match = models.first(where: { ($0["name"] as? String) == model || ($0["model"] as? String) == model }),
               let length = match["context_length"] as? Int, length > 0 {
                return length
            }
        }
        return nil
    }
}
