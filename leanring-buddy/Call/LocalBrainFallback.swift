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
    /// Claude is standing by (not the local model alone).
    var hasClaude: Bool { fallback != nil }

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
    /// DuckDuckGo first; when it gives nothing (it starts showing a bot check after some use), news goes to GDELT's free
    /// headline index and anything else to Wikipedia, read from the top articles' leads.
    static func search(_ query: String) async -> [SpaceWebSearch.Result] {
        if let results = try? await duckDuckGo(query), !results.isEmpty { return results }
        if SpaceWebSearch.isNewsQuery(query), let news = try? await gdelt(query), !news.isEmpty { return news }
        return (try? await wikipedia(query)) ?? []
    }

    private static func gdelt(_ query: String) async throws -> [SpaceWebSearch.Result] {
        let topic = query.replacingOccurrences(of: #"(?i)\b(latest|today'?s?|top|breaking|news|headlines?)\b"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        var components = URLComponents(string: "https://api.gdeltproject.org/api/v2/doc/doc")!
        components.queryItems = [URLQueryItem(name: "query", value: (topic.isEmpty ? "India" : topic) + " sourcelang:english"),
                                 URLQueryItem(name: "mode", value: "artlist"), URLQueryItem(name: "maxrecords", value: "5"),
                                 URLQueryItem(name: "format", value: "json"), URLQueryItem(name: "sort", value: "datedesc"),
                                 URLQueryItem(name: "timespan", value: "1d")]
        guard let url = components.url else { return [] }
        return SpaceWebSearch.gdeltHeadlines(json: try await fetch(url))
    }

    private static func fetch(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: 4)
        // An honest, generic client name: Wikimedia blocks automated requests that pretend to be a browser.
        request.setValue("VelloSpaceBot/1.0 (local voice bot; occasional single queries)", forHTTPHeaderField: "User-Agent")
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
        // Full-text search on the query's keywords: the top five articles with matching snippets.
        var search = URLComponents(string: "https://en.wikipedia.org/w/api.php")!
        search.queryItems = [URLQueryItem(name: "action", value: "query"), URLQueryItem(name: "list", value: "search"),
                             URLQueryItem(name: "srsearch", value: SpaceWebSearch.keywords(query)), URLQueryItem(name: "srlimit", value: "5"),
                             URLQueryItem(name: "format", value: "json")]
        guard let searchURL = search.url else { return [] }
        let found = SpaceWebSearch.wikipediaFullText(json: try await fetch(searchURL))
        guard !found.isEmpty else { return [] }
        let pages = found
        // The top two articles' leads hold more than the search excerpts ("the final … Australia won by six wickets").
        var results: [SpaceWebSearch.Result] = []
        for page in pages.prefix(2) {
            let title = page.url.components(separatedBy: "/wiki/").last ?? page.title
            if let summaryURL = URL(string: "https://en.wikipedia.org/api/rest_v1/page/summary/" + (title.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? title)),
               let summary = SpaceWebSearch.wikipediaSummary(json: (try? await fetch(summaryURL)) ?? Data()) {
                results.append(summary)
            } else {
                results.append(page)
            }
        }
        // The top two articles' leads, then the other matches' snippets: five results in all.
        return results + pages.dropFirst(2)
    }
}
