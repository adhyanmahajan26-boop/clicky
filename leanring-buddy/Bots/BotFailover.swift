//
//  BotFailover.swift
//  leanring-buddy
//
//  When a bot's engine fails the way that passes (overloaded, rate-limited, a 5xx), the turn is tried again on the
//  same model after a short wait, then on the next model in the fallback chain, and the reply says which model it
//  came from. A sign-in problem or anything else isn't retried. Hermes calls this fallback providers, OpenClaw model
//  failover. The policy is ClickyCore's `EngineFailoverPlan`.
//

import ClickyCore
import Foundation

extension BotRunner {
    /// The models a Claude bot moves to when its own keeps failing. Settings key `v3.bots.fallbackModels`; empty means the default chain.
    static var configuredFallbacks: [String]? {
        UserDefaults.standard.stringArray(forKey: "v3.bots.fallbackModels")
    }

    /// A test profile can make the waits short (`test.bots.retryDelays`).
    static var retryDelays: [Double] {
        if TheoProfile.isTest, let delays = UserDefaults.standard.array(forKey: "test.bots.retryDelays") as? [Double] { return delays }
        if TheoProfile.isTest, let delays = UserDefaults.standard.array(forKey: "test.bots.retryDelays") as? [String] { return delays.compactMap(Double.init) }
        return EngineFailoverPlan.defaultRetryDelays
    }

    static func failoverPlan(for bot: NativeBot) -> EngineFailoverPlan {
        // Only Claude Code's models are interchangeable on one session; other engines get the same-model retries.
        // `v3.bots.fallbackModels` = ["off"] keeps every bot on its own model.
        let fallbacks = bot.provider == "claude" && configuredFallbacks != ["off"] ? EngineFailoverPlan.chain(for: bot.model, configured: configuredFallbacks) : []
        return EngineFailoverPlan(retryDelays: retryDelays, fallbacks: fallbacks)
    }

    /// One turn, with retries and the fallback chain. The session carries over: Claude Code resumes a session on any of its models.
    static func runWithFailover(bot: NativeBot, prompt: String, session: String?, team: [NativeBot], readable: [String] = [], recall: [String] = [],
                                ownerAsked: Bool = false, onText: @escaping @MainActor (String) -> Void) async throws -> (text: String, session: String?) {
        let plan = failoverPlan(for: bot)
        let began = Date()
        var current = bot
        var attempt = 0
        var fallbackIndex: Int?
        var firstFailure: EngineFailure?
        while true {
            do {
                let result = try await runOnEngine(bot: current, prompt: prompt, session: session, team: team, readable: readable, recall: recall, ownerAsked: ownerAsked, onText: onText)
                guard current.model != bot.model, let reason = firstFailure else { return result }
                log("bot \(bot.id): answered on fallback \(current.model) after \(bot.model) failed")
                return (result.text + "\n\n" + EngineFailoverPlan.fallbackNote(from: BotModels.label(bot.model, on: bot.provider),
                                                                                 to: BotModels.label(current.model, on: bot.provider), reason: reason), result.session)
            } catch BotRunnerError.failed(let message) {
                let failure = EngineFailure.classify(message)
                guard !Task.isCancelled, !BotProcesses.shared.wasStopped(bot.id, since: began),
                      let next = plan.next(after: failure, model: current.model, attempt: attempt, fallbackIndex: fallbackIndex) else {
                    // Another engine that's still failing after its retries: Claude Code stands in for this turn, if it's here.
                    if bot.provider != "claude", failure == .transient || failure == .modelUnavailable, configuredFallbacks != ["off"],
                       !Task.isCancelled, !BotProcesses.shared.wasStopped(bot.id, since: began), executable(for: .claude) != nil {
                        log("bot \(bot.id): \(bot.provider) still failing; Claude Code stands in")
                        throw BotRunnerError.engineDown(String(message.prefix(300)))
                    }
                    throw BotRunnerError.failed(message)
                }
                if firstFailure == nil { firstFailure = failure }
                log("bot \(bot.id): \(current.model) failed (\(failure)): \(message.prefix(160)); next \(next.model) in \(next.delay)s")
                if next.isFallback { fallbackIndex = (fallbackIndex ?? -1) + 1 }
                attempt += 1
                if next.delay > 0 { try? await Task.sleep(nanoseconds: UInt64(next.delay * 1_000_000_000)) }
                // Stop pressed while waiting: the turn ends here.
                if Task.isCancelled || BotProcesses.shared.wasStopped(bot.id, since: began) { throw BotRunnerError.failed(message) }
                current.model = next.model
            }
        }
    }

    private static func log(_ line: String) {
        print("[failover] \(line)")
    }
}
