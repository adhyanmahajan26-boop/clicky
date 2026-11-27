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
    private let fallback: ConversationBrain
    /// No word from the local model in this long: the turn goes to Claude.
    static let firstWordLimitSeconds: Double = 4
    /// The next turn goes straight to Claude (a web search). Reset after each turn.
    var nextTurnToFallback = false
    /// What Claude is given for this turn if it answers it: the turn with the note and ideology the local model has in its
    /// system prompt. Reset after each turn.
    var claudeText: String?
    /// Which side answered each turn lately, for `ownAccountStatus`.
    private(set) var answeredBy: [String] = []
    private var current: ConversationBrain?
    var onEnded: ((String) -> Void)?

    init(primary: ConversationBrain, fallback: ConversationBrain) {
        self.primary = primary
        self.fallback = fallback
        fallback.onEnded = { [weak self] message in self?.onEnded?(message) }
    }

    var isRunning: Bool { primary.isRunning || fallback.isRunning }

    func start() throws {
        // Claude is kept warm for a fallback; the local server only needs to answer.
        try? fallback.start()
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
            try? await Task.sleep(nanoseconds: UInt64(Self.firstWordLimitSeconds * 1_000_000_000))
            guard let self, !Task.isCancelled, !gotWords, !switched else { return }
            switched = true
            self.primary.interrupt()
            self.sendToFallback(forClaude, images: images, onDelta: onDelta, onDone: onDone, why: "no word in \(Int(Self.firstWordLimitSeconds)) s")
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
        fallback.stop()
    }

    /// Switching back to Claude alone: the local side stops, Claude's (kept warm) carries on.
    func stopLocalOnly() { primary.stop() }
}
