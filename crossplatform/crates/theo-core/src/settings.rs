//! Settings, kept in one JSON file (the Swift app uses UserDefaults; the keys are the same).
//!
//! Keys the harness reads: `test.engine.<brain>` (claude, opencode, codex, cursor, gemini, grok: a stand-in engine, tests only), `brains.apiBaseURL.<provider>` (a provider moved, such as a test's stand-in API), `test.bots.turnLimit`,
//! `test.bots.retryDelays`, `test.routines.run`, `v3.bots.fallbackModels`, `v3.bots.parallelMessages`, `v3.gateway.enabled`,
//! `v3.gateway.port`, `owner.name` (empty or missing: prompts say "the owner").

use serde_json::{Map, Value};
use std::path::PathBuf;
use std::sync::Mutex;

pub struct Settings {
    file: PathBuf,
    values: Mutex<Map<String, Value>>,
    /// A test profile: only then do the `test.*` keys count.
    pub is_test: bool,
}

impl Settings {
    pub fn load(file: PathBuf, is_test: bool) -> Self {
        let values = std::fs::read(&file).ok().and_then(|d| serde_json::from_slice::<Map<String, Value>>(&d).ok()).unwrap_or_default();
        Self { file, values: Mutex::new(values), is_test }
    }

    pub fn get(&self, key: &str) -> Option<Value> {
        if key.starts_with("test.") && !self.is_test {
            return None;
        }
        self.values.lock().unwrap().get(key).cloned()
    }

    pub fn set(&self, key: &str, value: Value) {
        let mut values = self.values.lock().unwrap();
        if value.is_null() { values.remove(key); } else { values.insert(key.to_string(), value); }
        let data = serde_json::to_vec_pretty(&*values).unwrap_or_default();
        let _ = crate::store::write_atomic(&self.file, &data);
    }

    pub fn string(&self, key: &str) -> Option<String> {
        self.get(key).and_then(|v| v.as_str().map(str::to_string)).filter(|s| !s.is_empty())
    }
    pub fn number(&self, key: &str) -> Option<f64> {
        match self.get(key)? {
            Value::Number(n) => n.as_f64(),
            Value::String(s) => s.parse().ok(),
            Value::Bool(b) => Some(if b { 1.0 } else { 0.0 }),
            _ => None,
        }
    }
    pub fn bool(&self, key: &str) -> bool {
        match self.get(key) {
            Some(Value::Bool(b)) => b,
            Some(Value::Number(n)) => n.as_f64().unwrap_or(0.0) != 0.0,
            Some(Value::String(s)) => matches!(s.as_str(), "1" | "true" | "yes"),
            _ => false,
        }
    }
    pub fn strings(&self, key: &str) -> Option<Vec<String>> {
        match self.get(key)? {
            Value::Array(items) => Some(items.iter().filter_map(|v| match v {
                Value::String(s) => Some(s.clone()),
                Value::Number(n) => Some(n.to_string()),
                _ => None,
            }).collect()),
            Value::String(s) => Some(s.split(',').map(|x| x.trim().to_string()).filter(|x| !x.is_empty()).collect()),
            _ => None,
        }
    }

    /// What the bots call the owner: the name from Setup or Settings, or "the owner" until one is given.
    pub fn owner_name(&self) -> String {
        owner_name_from(self.string("owner.name").as_deref())
    }

    /// The longest one bot turn may take: 7 minutes, or `test.bots.turnLimit` in a test profile.
    pub fn turn_limit_seconds(&self) -> f64 {
        match self.number("test.bots.turnLimit") {
            Some(limit) if limit > 0.0 => limit,
            _ => 420.0,
        }
    }

    pub fn retry_delays(&self) -> Vec<f64> {
        self.strings("test.bots.retryDelays").map(|v| v.iter().filter_map(|s| s.parse().ok()).collect()).unwrap_or_else(|| vec![3.0, 10.0])
    }

    pub fn parallel_messages(&self) -> usize {
        match self.number("v3.bots.parallelMessages") {
            Some(n) if n >= 1.0 => (n as usize).min(8),
            _ => 4,
        }
    }

    pub fn gateway_enabled(&self) -> bool { self.bool("v3.gateway.enabled") }
    pub fn gateway_port(&self) -> u16 {
        self.number("v3.gateway.port").map(|n| n as u16).filter(|p| *p > 0).unwrap_or(47380)
    }
}

/// What prompts say before the owner has given a name.
pub const OWNER_UNSET: &str = "the owner";

/// Names go into many prompts, so a long one is cut.
pub const OWNER_NAME_MAXIMUM_CHARACTERS: usize = 40;

/// A saved name, tidied; "the owner" when nothing usable is saved.
pub fn owner_name_from(saved: Option<&str>) -> String {
    let trimmed = saved.unwrap_or("").trim();
    if trimmed.is_empty() { return OWNER_UNSET.to_string(); }
    trimmed.chars().take(OWNER_NAME_MAXIMUM_CHARACTERS).collect()
}

/// The owner's name at the start of a sentence: "The owner sees…" rather than "the owner sees…".
pub fn owner_starting_sentence(owner: &str) -> String {
    if owner == OWNER_UNSET { "The owner".to_string() } else { owner.to_string() }
}

/// What Setup's name field starts with: the computer account's name, capitalised ("sam" → "Sam"), or empty.
pub fn suggested_owner_name() -> String {
    let account = std::env::var("USERNAME").or_else(|_| std::env::var("USER")).unwrap_or_default();
    suggested_owner_name_from(&account)
}

pub fn suggested_owner_name_from(account: &str) -> String {
    let trimmed = account.trim();
    if trimmed.is_empty() || trimmed.eq_ignore_ascii_case("root") || trimmed.eq_ignore_ascii_case("administrator") { return String::new(); }
    let mut characters = trimmed.chars();
    let first = characters.next().map(|c| c.to_uppercase().collect::<String>()).unwrap_or_default();
    (first + characters.as_str()).chars().take(OWNER_NAME_MAXIMUM_CHARACTERS).collect()
}

#[cfg(test)]
mod owner_name_tests {
    use super::*;

    #[test]
    fn nothing_saved_means_the_owner() {
        assert_eq!(owner_name_from(None), "the owner");
        assert_eq!(owner_name_from(Some("   ")), "the owner");
        assert_eq!(owner_name_from(Some("  Sam ")), "Sam");
        assert_eq!(owner_name_from(Some(&"x".repeat(90))).chars().count(), OWNER_NAME_MAXIMUM_CHARACTERS);
    }

    #[test]
    fn a_settings_file_without_a_name_says_the_owner() {
        let dir = tempfile::tempdir().unwrap();
        let settings = Settings::load(dir.path().join("settings.json"), false);
        assert_eq!(settings.owner_name(), "the owner");
        settings.set("owner.name", "Priya".into());
        assert_eq!(settings.owner_name(), "Priya");
    }

    #[test]
    fn the_owner_starts_a_sentence_with_a_capital() {
        assert_eq!(owner_starting_sentence(OWNER_UNSET), "The owner");
        assert_eq!(owner_starting_sentence("Sam"), "Sam");
    }

    #[test]
    fn setup_suggests_the_account_name() {
        assert_eq!(suggested_owner_name_from("priya"), "Priya");
        assert_eq!(suggested_owner_name_from("Administrator"), "");
        assert_eq!(suggested_owner_name_from(""), "");
    }
}
