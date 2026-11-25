//! Tokens and cost per bot and day.

use chrono::{DateTime, Duration, Local, Utc};
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

#[derive(Clone, Debug, Default, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct TurnUsage {
    pub input_tokens: u64,
    pub output_tokens: u64,
    pub cache_read_tokens: u64,
    pub cache_write_tokens: u64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cost_usd: Option<f64>,
}

impl TurnUsage {
    pub fn is_empty(&self) -> bool {
        self.input_tokens == 0 && self.output_tokens == 0 && self.cache_read_tokens == 0 && self.cache_write_tokens == 0 && self.cost_usd.is_none()
    }
    pub fn total_tokens(&self) -> u64 { self.input_tokens + self.output_tokens + self.cache_read_tokens + self.cache_write_tokens }
    /// Claude Code's final `result` event.
    pub fn from_claude_result(event: &serde_json::Value) -> Option<Self> {
        let usage = event.get("usage");
        let n = |k: &str| usage.and_then(|u| u.get(k)).and_then(|v| v.as_u64()).unwrap_or(0);
        let result = Self {
            input_tokens: n("input_tokens"),
            output_tokens: n("output_tokens"),
            cache_read_tokens: n("cache_read_input_tokens"),
            cache_write_tokens: n("cache_creation_input_tokens"),
            cost_usd: event.get("total_cost_usd").and_then(|v| v.as_f64()),
        };
        if result.is_empty() { None } else { Some(result) }
    }
    pub fn add(&mut self, other: &TurnUsage) {
        self.input_tokens += other.input_tokens;
        self.output_tokens += other.output_tokens;
        self.cache_read_tokens += other.cache_read_tokens;
        self.cache_write_tokens += other.cache_write_tokens;
        self.cost_usd = match (self.cost_usd, other.cost_usd) {
            (None, None) => None,
            (a, b) => Some(a.unwrap_or(0.0) + b.unwrap_or(0.0)),
        };
    }
}

/// OpenAI-style servers that only say what a streamed request used when asked with `stream_options.include_usage`, and take
/// that option. Others say it unasked or not at all, and an unknown option could be refused. The Mac's `APIStreamUsage`.
pub fn asks_for_usage(provider_id: &str) -> bool { matches!(provider_id, "openai" | "xai" | "openrouter" | "deepseek" | "together") }

/// What one API request used, from its server-sent lines. Anthropic says the input in `message_start` and the output so far in each
/// `message_delta`; an OpenAI-style server says it all in one chunk near the end (`usage`, or Groq's `x_groq.usage`). Numbers that
/// repeat are running totals, so the largest seen is kept.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct StreamUsage {
    pub usage: TurnUsage,
}

impl StreamUsage {
    pub fn take(&mut self, line: &str) {
        let Some(payload) = line.strip_prefix("data:") else { return };
        let payload = payload.trim();
        if !payload.contains("usage") {
            return;
        }
        let Ok(object) = serde_json::from_str::<serde_json::Value>(payload) else { return };
        let found = [&object["message"]["usage"], &object["usage"], &object["x_groq"]["usage"]].into_iter().find(|u| u.is_object()).cloned();
        let Some(found) = found else { return };
        let n = |v: &serde_json::Value| v.as_u64().unwrap_or(0);
        let seen = if found.get("prompt_tokens").is_some() || found.get("completion_tokens").is_some() {
            // OpenAI style: cached input is part of prompt_tokens.
            let cached = n(&found["prompt_tokens_details"]["cached_tokens"]) + n(&found["prompt_cache_hit_tokens"]);
            TurnUsage { input_tokens: n(&found["prompt_tokens"]).saturating_sub(cached), output_tokens: n(&found["completion_tokens"]), cache_read_tokens: cached, cache_write_tokens: 0, cost_usd: None }
        } else {
            TurnUsage { input_tokens: n(&found["input_tokens"]), output_tokens: n(&found["output_tokens"]), cache_read_tokens: n(&found["cache_read_input_tokens"]), cache_write_tokens: n(&found["cache_creation_input_tokens"]), cost_usd: None }
        };
        self.usage.input_tokens = self.usage.input_tokens.max(seen.input_tokens);
        self.usage.output_tokens = self.usage.output_tokens.max(seen.output_tokens);
        self.usage.cache_read_tokens = self.usage.cache_read_tokens.max(seen.cache_read_tokens);
        self.usage.cache_write_tokens = self.usage.cache_write_tokens.max(seen.cache_write_tokens);
    }
}

#[derive(Clone, Debug, Default, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Day {
    pub turns: u64,
    pub usage: TurnUsage,
    pub turns_without_cost: u64,
}

#[derive(Clone, Debug, Default, Serialize, Deserialize, PartialEq)]
pub struct Ledger {
    /// Bot id → "yyyy-mm-dd" → that day's totals.
    pub days: BTreeMap<String, BTreeMap<String, Day>>,
}

pub fn day_key(date: DateTime<Utc>) -> String { date.with_timezone(&Local).format("%Y-%m-%d").to_string() }

impl Ledger {
    pub fn record(&mut self, bot: &str, usage: &TurnUsage, at: DateTime<Utc>) {
        let days = self.days.entry(bot.to_string()).or_default();
        let day = days.entry(day_key(at)).or_default();
        day.turns += 1;
        day.usage.add(usage);
        if usage.cost_usd.is_none() {
            day.turns_without_cost += 1;
        }
        let oldest = day_key(at - Duration::days(400));
        days.retain(|k, _| *k >= oldest);
    }

    pub fn total(&self, bot: &str, days: i64, now: DateTime<Utc>) -> Day {
        let first = day_key(now - Duration::days(days.max(1) - 1));
        let mut sum = Day::default();
        if let Some(by_day) = self.days.get(bot) {
            for (_, day) in by_day.iter().filter(|(k, _)| **k >= first) {
                sum.turns += day.turns;
                sum.usage.add(&day.usage);
                sum.turns_without_cost += day.turns_without_cost;
            }
        }
        sum
    }
}

#[cfg(test)]
mod stream_usage_tests {
    use super::*;

    #[test]
    fn anthropic_input_from_the_start_and_output_from_the_last_delta() {
        let mut meter = StreamUsage::default();
        meter.take(r#"data: {"type":"message_start","message":{"usage":{"input_tokens":1200,"cache_creation_input_tokens":300,"cache_read_input_tokens":4000,"output_tokens":1}}}"#);
        meter.take(r#"data: {"type":"message_delta","usage":{"output_tokens":15}}"#);
        meter.take(r#"data: {"type":"message_delta","usage":{"output_tokens":42}}"#);
        assert_eq!(meter.usage, TurnUsage { input_tokens: 1200, output_tokens: 42, cache_read_tokens: 4000, cache_write_tokens: 300, cost_usd: None });
    }

    #[test]
    fn openai_style_splits_cached_input_out_and_ignores_a_null_usage() {
        let mut meter = StreamUsage::default();
        meter.take(r#"data: {"choices":[{"delta":{"content":"x"}}],"usage":null}"#);
        assert!(meter.usage.is_empty());
        meter.take(r#"data: {"choices":[],"usage":{"prompt_tokens":900,"completion_tokens":80,"prompt_tokens_details":{"cached_tokens":600}}}"#);
        meter.take("data: [DONE]");
        assert_eq!(meter.usage, TurnUsage { input_tokens: 300, output_tokens: 80, cache_read_tokens: 600, cache_write_tokens: 0, cost_usd: None });
        let mut groq = StreamUsage::default();
        groq.take(r#"data: {"choices":[],"x_groq":{"usage":{"prompt_tokens":50,"completion_tokens":7}}}"#);
        assert_eq!(groq.usage.input_tokens, 50);
        assert!(asks_for_usage("openai") && !asks_for_usage("lmstudio"));
    }
}
