//! Retrying a failing engine, then moving along a chain of other models. Same model first, never on a sign-in problem.

use once_cell::sync::Lazy;
use regex::Regex;

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum Failure {
    /// Overloaded, rate-limited, a 5xx or a dropped connection.
    Transient,
    /// The model isn't there: another model might work.
    ModelUnavailable,
    /// Signed out, a bad key: nothing is retried.
    Auth,
    Other,
}

pub fn classify(text: &str) -> Failure {
    static AUTH: Lazy<Regex> = Lazy::new(|| Regex::new(r"invalid api key|invalid x-api-key|authentication_error|please run /login|not logged in|unauthori[sz]ed|\b401\b|oauth token (has )?expired|credit balance is too low|permission_error|\b403\b|isn.t signed in|not signed in|no api key").unwrap());
    static MODEL: Lazy<Regex> = Lazy::new(|| Regex::new(r"model[^\n]{0,60}(not found|does not exist|isn't available|is not available|not supported|retired|deprecated)|not_found_error[^\n]{0,80}model|unknown model|invalid model|no such model|model_not_found|there's an issue with the selected model|may not exist or you may not have access").unwrap());
    static TRANSIENT: Lazy<Regex> = Lazy::new(|| Regex::new(r"overloaded|\b529\b|\b429\b|rate.?limit|too many requests|\b50[0234]\b|internal server error|bad gateway|service unavailable|gateway time-?out|api_error|econnreset|etimedout|socket hang up|connection (reset|refused|error)|network error|fetch failed|request timed out|temporarily unavailable").unwrap());
    let lower = text.to_lowercase();
    if AUTH.is_match(&lower) { Failure::Auth } else if MODEL.is_match(&lower) { Failure::ModelUnavailable } else if TRANSIENT.is_match(&lower) { Failure::Transient } else { Failure::Other }
}

pub const DEFAULT_CLAUDE_CHAIN: [&str; 3] = ["claude-sonnet-5-5", "claude-haiku-5-5", "claude-opus-5-5"];

#[derive(Debug, Clone)]
pub struct Plan {
    pub retry_delays: Vec<f64>,
    pub fallbacks: Vec<String>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct Attempt {
    pub model: String,
    pub delay: f64,
    pub is_fallback: bool,
}

impl Plan {
    pub fn chain(model: &str, configured: Option<&[String]>) -> Vec<String> {
        let mut seen = std::collections::HashSet::from([model.to_lowercase()]);
        let list: Vec<String> = match configured {
            Some(c) if !c.is_empty() => c.to_vec(),
            _ => DEFAULT_CLAUDE_CHAIN.iter().map(|s| s.to_string()).collect(),
        };
        list.into_iter().map(|s| s.trim().to_string()).filter(|s| !s.is_empty() && seen.insert(s.to_lowercase())).collect()
    }

    pub fn next(&self, failure: Failure, model: &str, attempt: usize, fallback_index: Option<usize>) -> Option<Attempt> {
        match failure {
            Failure::Auth | Failure::Other => None,
            Failure::Transient if fallback_index.is_none() && attempt < self.retry_delays.len() => {
                Some(Attempt { model: model.to_string(), delay: self.retry_delays[attempt], is_fallback: false })
            }
            Failure::Transient | Failure::ModelUnavailable => {
                let index = fallback_index.map(|i| i + 1).unwrap_or(0);
                let model = self.fallbacks.get(index)?.clone();
                Some(Attempt { model, delay: if failure == Failure::Transient { 1.0 } else { 0.0 }, is_fallback: true })
            }
        }
    }
}

pub fn model_label(model: &str) -> String {
    let lower = model.to_lowercase();
    for (key, name) in [("opus", "Opus"), ("sonnet", "Sonnet"), ("haiku", "Haiku")] {
        if lower.contains(key) {
            return name.to_string();
        }
    }
    model.to_string()
}

pub fn fallback_note(original: &str, used: &str, reason: Failure) -> String {
    let why = if reason == Failure::ModelUnavailable { "wasn't available" } else { "kept failing (overloaded or rate-limited)" };
    format!("_({} {}, so this reply came from {}.)_", model_label(original), why, model_label(used))
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn plan() {
        assert_eq!(classify("API Error: 529 Overloaded"), Failure::Transient);
        assert_eq!(classify("Invalid API key · Please run /login"), Failure::Auth);
        let plan = Plan { retry_delays: vec![3.0, 10.0], fallbacks: Plan::chain("claude-haiku-5-5", None) };
        assert_eq!(plan.fallbacks, vec!["claude-sonnet-5-5", "claude-opus-5-5"]);
        assert_eq!(plan.next(Failure::Transient, "h", 0, None).unwrap().delay, 3.0);
        assert!(plan.next(Failure::Transient, "h", 2, None).unwrap().is_fallback);
        assert!(plan.next(Failure::Auth, "h", 0, None).is_none());
        assert!(plan.next(Failure::Transient, "h", 2, Some(1)).is_none());
    }
}
