//
//  LocalBrainFallback.swift
//  leanring-buddy
//
//  The X Space bot's brain when the owner picks the local one (XAccountSettings.brain "local"): a model on this Mac's LM
//  Studio server, with Claude Code standing by. A turn goes to Claude instead when the local server fails, when no word
//  has come from it in 4 s, or when it's a web search (only Claude's side can search).
//

import ClickyCore
import Foundation

@MainActor
final class FallbackConversation: ConversationBrain {
    private let primary: ConversationBrain
    /// Claude, standing by; nil when the owner wants the local model alone (`XAccountSettings.localOnly`): a turn it can't
    /// answer in time is then let pass quietly.
    private let fallback: ConversationBrain?
    /// No word from the local model in this long: the turn goes to Claude, or passes when there's no Claude.
    let firstWordLimitSeconds: Double
    /// The next turn goes straight to Claude (a web search). Reset after each turn.
    var nextTurnToFallback = false
    /// What Claude is given for this turn if it answers it: the turn with the note and ideology the local model has in its
    /// system prompt. Reset after each turn.
    var claudeText: String?
    /// Which side answered each turn lately, for `ownAccountStatus`.
    private(set) var answeredBy: [String] = []
    private var current: ConversationBrain?
    var onEnded: ((String) -> Void)?

    init(primary: ConversationBrain, fallback: ConversationBrain?, firstWordLimitSeconds: Double = 4) {
        self.primary = primary
        self.fallback = fallback
        self.firstWordLimitSeconds = firstWordLimitSeconds
        fallback?.onEnded = { [weak self] message in self?.onEnded?(message) }
    }

    var isRunning: Bool { primary.isRunning || fallback?.isRunning == true }

    func start() throws {
        // Claude is kept warm for a fallback; the local server only needs to answer.
        try? fallback?.start()
        do { try primary.start() } catch { callLog("📞 Space: the local brain isn't there (\(error.localizedDescription)), Claude answers") }
    }

    func send(_ text: String, images: [ClaudeContentBlock], onDelta: @escaping (String) -> Void, onDone: @escaping (Result<String, Error>) -> Void) {
        let forClaude = claudeText ?? text
        claudeText = nil
        if nextTurnToFallback || !primary.isRunning {
            nextTurnToFallback = false
            sendToFallback(forClaude, images: images, onDelta: onDelta, onDone: onDone, why: "a search")
            return
        }
        var gotWords = false
        var switched = false
        current = primary
        let timer = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64((self?.firstWordLimitSeconds ?? 4) * 1_000_000_000))
            guard let self, !Task.isCancelled, !gotWords, !switched else { return }
            switched = true
            self.primary.interrupt()
            self.sendToFallback(forClaude, images: images, onDelta: onDelta, onDone: onDone, why: "no word in \(Int(self.firstWordLimitSeconds)) s")
        }
        primary.send(text, images: images, onDelta: { delta in
            guard !switched else { return }
            if !gotWords { gotWords = true; timer.cancel() }
            onDelta(delta)
        }, onDone: { [weak self] result in
            timer.cancel()
            guard let self, !switched else { return }
            if case .failure(let error) = result, !gotWords {
                switched = true
                self.sendToFallback(forClaude, images: images, onDelta: onDelta, onDone: onDone, why: "it failed (\(error.localizedDescription))")
                return
            }
            self.note("local")
            onDone(result)
        })
    }

    private func sendToFallback(_ text: String, images: [ClaudeContentBlock], onDelta: @escaping (String) -> Void,
                                onDone: @escaping (Result<String, Error>) -> Void, why: String) {
        guard let fallback else {
            // The local model alone: the turn passes quietly.
            callLog("📞 Space: the local model let this turn pass (\(why))")
            note("passed")
            onDone(.success(CallGroupMode.passMarker))
            return
        }
        callLog("📞 Space: Claude answers this turn (\(why))")
        current = fallback
        fallback.send(text, images: images, onDelta: onDelta, onDone: { [weak self] result in
            self?.note("claude")
            onDone(result)
        })
    }

    private func note(_ side: String) {
        answeredBy.append(side)
        if answeredBy.count > 20 { answeredBy.removeFirst(answeredBy.count - 20) }
    }

    func interrupt() { (current ?? primary).interrupt() }
    func forgetTheTurnBeingAnswered() { (current ?? primary).forgetTheTurnBeingAnswered() }
    func stop() {
        primary.stop()
        fallback?.stop()
    }

    /// Switching back to Claude alone: the local side stops, Claude's (kept warm) carries on.
    func stopLocalOnly() { primary.stop() }
}

/// The web search for the local model: DuckDuckGo's plain results page, then Wikipedia's API when that finds nothing.
/// Both are free and need no key or install. A few seconds at most.
enum SpaceSearchClient {
    static func search(_ query: String) async -> [SpaceWebSearch.Result] {
        if let results = try? await duckDuckGo(query), !results.isEmpty { return results }
        return (try? await wikipedia(query)) ?? []
    }

    private static func fetch(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: 4)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
                         forHTTPHeaderField: "User-Agent")
        let (data, _) = try await URLSession.shared.data(for: request)
        return data
    }

    private static func duckDuckGo(_ query: String) async throws -> [SpaceWebSearch.Result] {
        var components = URLComponents(string: "https://html.duckduckgo.com/html/")!
        components.queryItems = [URLQueryItem(name: "q", value: query)]
        guard let url = components.url else { return [] }
        return SpaceWebSearch.duckDuckGoResults(html: String(decoding: try await fetch(url), as: UTF8.self))
    }

    private static func wikipedia(_ query: String) async throws -> [SpaceWebSearch.Result] {
        var components = URLComponents(string: "https://en.wikipedia.org/w/rest.php/v1/search/page")!
        components.queryItems = [URLQueryItem(name: "q", value: query), URLQueryItem(name: "limit", value: "3")]
        guard let url = components.url else { return [] }
        return SpaceWebSearch.wikipediaResults(json: try await fetch(url))
    }
}
