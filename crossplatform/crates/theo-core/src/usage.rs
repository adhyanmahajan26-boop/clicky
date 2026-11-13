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
