//
//  APIStreamUsage.swift
//  ClickyCore
//
//  What a bot's turn on an API key used, read from the stream itself, so it counts in its usage like a Claude Code or OpenCode
//  turn does (Hermes's /usage, OpenClaw's usage tracking).
//

import Foundation

/// One request's usage, from its server-sent lines. Anthropic says the input in `message_start` and the output so far in each
/// `message_delta`; an OpenAI-style server says it all in one chunk near the end (`usage`, or Groq's `x_groq.usage`). Numbers
/// that repeat are running totals, so the largest seen is kept.
public struct APIStreamUsage: Equatable, Sendable {
    public private(set) var usage = BotTurnUsage()

    public init() {}

    /// OpenAI-style servers that only say what a streamed request used when asked with `stream_options.include_usage`, and
    /// take that option. Others (Mistral, Groq, local servers) say it unasked or not at all, and an unknown option could be refused.
    public static func asksForUsage(providerID: String) -> Bool {
        ["openai", "xai", "openrouter", "deepseek", "together"].contains(providerID)
    }

    public mutating func take(line: String) {
        guard line.hasPrefix("data:") else { return }
        let payload = line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
        guard payload.contains("usage"), let data = payload.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        let nested = (object["message"] as? [String: Any])?["usage"] as? [String: Any]
        let groq = (object["x_groq"] as? [String: Any])?["usage"] as? [String: Any]
        guard let found = nested ?? (object["usage"] as? [String: Any]) ?? groq else { return }
        func int(_ value: Any?) -> Int { (value as? NSNumber)?.intValue ?? 0 }
        if found["prompt_tokens"] != nil || found["completion_tokens"] != nil {
            // OpenAI style: cached input is part of prompt_tokens.
            let cached = int((found["prompt_tokens_details"] as? [String: Any])?["cached_tokens"]) + int(found["prompt_cache_hit_tokens"])
            keepLargest(BotTurnUsage(inputTokens: max(0, int(found["prompt_tokens"]) - cached), outputTokens: int(found["completion_tokens"]),
                                     cacheReadTokens: cached))
        } else {
            keepLargest(BotTurnUsage(inputTokens: int(found["input_tokens"]), outputTokens: int(found["output_tokens"]),
                                     cacheReadTokens: int(found["cache_read_input_tokens"]), cacheWriteTokens: int(found["cache_creation_input_tokens"])))
        }
    }

    private mutating func keepLargest(_ seen: BotTurnUsage) {
        usage = BotTurnUsage(inputTokens: max(usage.inputTokens, seen.inputTokens), outputTokens: max(usage.outputTokens, seen.outputTokens),
                             cacheReadTokens: max(usage.cacheReadTokens, seen.cacheReadTokens),
                             cacheWriteTokens: max(usage.cacheWriteTokens, seen.cacheWriteTokens))
    }
}
