//
//  BotUsage.swift
//  leanring-buddy
//
//  What each bot's turns have used, by day: tokens and, when the engine says, dollars (Claude Code reports what a turn
//  would cost even on a subscription). Shown in a bot's settings, and through the control inbox (`botsUsage`) and the
//  local API (`GET /v1/usage`). The ledger itself is ClickyCore's `BotUsageLedger`; this keeps it in Bots/usage.json.
//

import ClickyCore
import Combine
import Foundation

@MainActor
final class BotUsage: ObservableObject {
    static let shared = BotUsage()

    @Published private(set) var ledger = BotUsageLedger()
    private var file: URL { BotMemory.root.deletingLastPathComponent().appendingPathComponent("usage.json") }

    private init() {
        if let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode(BotUsageLedger.self, from: data) { ledger = saved }
    }

    func record(botID: String, usage: BotTurnUsage?) {
        ledger.record(botID: botID, usage: usage ?? BotTurnUsage(), at: Date())
        if let data = try? JSONEncoder().encode(ledger) { try? data.write(to: file, options: .atomic) }
    }

    func total(botID: String, days: Int) -> BotUsageLedger.Day { ledger.total(botID: botID, days: days, now: Date()) }

    /// Every bot's totals over `days`, for the control inbox and the local API.
    func report(days: Int, names: [String: String]) -> [[String: Any]] {
        ledger.days.keys.sorted().map { id in
            let day = total(botID: id, days: days)
            return ["bot": id, "name": names[id] ?? id, "turns": day.turns, "inputTokens": day.usage.inputTokens, "outputTokens": day.usage.outputTokens,
                    "cacheReadTokens": day.usage.cacheReadTokens, "cacheWriteTokens": day.usage.cacheWriteTokens,
                    "costUSD": day.usage.costUSD ?? NSNull(), "turnsWithoutCost": day.turnsWithoutCost]
        }
    }
}
