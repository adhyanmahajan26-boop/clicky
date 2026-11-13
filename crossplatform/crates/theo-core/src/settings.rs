//! Settings, kept in one JSON file (the Swift app uses UserDefaults; the keys are the same).
//!
//! Keys the harness reads: `test.engine.claude`, `test.engine.opencode` (a stand-in engine, tests only), `test.bots.turnLimit`,
//! `test.bots.retryDelays`, `test.routines.run`, `v3.bots.fallbackModels`, `v3.bots.parallelMessages`, `v3.gateway.enabled`,
//! `v3.gateway.port`, `owner.name`.

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

    pub fn owner_name(&self) -> String {
        self.string("owner.name").unwrap_or_else(|| "Addy".to_string())
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
