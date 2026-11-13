//! Which Pixel face a bot shows: green working, yellow needs you, red failed, and the quieter states. One pure function, so
//! the rule order is tested on its own (the kit's `TP.PRIORITY`, spec section 3).

/// What's true of a bot right now.
#[derive(Debug, Default, Clone)]
pub struct Facts {
    pub enabled: bool,
    pub primary: bool,
    /// The kind of its last failure: "signin" or "failed".
    pub failure: Option<String>,
    /// A card in its chat waits for the owner (a yes/no, a choice).
    pub asks: bool,
    pub replying: bool,
    pub streamed: bool,
    pub queued: bool,
    pub run_live: bool,
    /// Its newest message hasn't been seen.
    pub unread: bool,
    /// Seconds since its last message.
    pub answered_ago: Option<i64>,
    /// Seconds since anything happened in its chat.
    pub active_ago: Option<i64>,
}

pub const DONE_SECONDS: i64 = 120;
pub const DOZE_SECONDS: i64 = 600;

/// First match wins: off, needs, failed, (talking, listening: voice, not on this build), working, thinking, done, awake, idle.
pub fn state(f: &Facts) -> &'static str {
    if !f.enabled {
        return "off";
    }
    if f.failure.as_deref() == Some("signin") || f.asks {
        return "needs";
    }
    if f.failure.as_deref() == Some("failed") {
        return "failed";
    }
    if f.run_live || (f.replying && f.streamed) {
        return "working";
    }
    if f.replying || f.queued {
        return "thinking";
    }
    if f.unread || f.answered_ago.map(|a| a < DONE_SECONDS).unwrap_or(false) {
        return "done";
    }
    if f.primary || f.active_ago.map(|a| a < DOZE_SECONDS).unwrap_or(false) {
        return "awake";
    }
    "idle"
}

pub fn word(state: &str) -> &'static str {
    match state {
        "working" => "Working",
        "thinking" => "Thinking",
        "needs" => "Needs you",
        "failed" => "Failed",
        "done" => "Done",
        "awake" => "Ready",
        "talking" => "Talking",
        "listening" => "Listening",
        "idle" => "Asleep",
        _ => "Off",
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn on() -> Facts { Facts { enabled: true, ..Default::default() } }

    #[test]
    fn off_beats_everything() {
        assert_eq!(state(&Facts { enabled: false, failure: Some("failed".into()), replying: true, ..Default::default() }), "off");
    }
    #[test]
    fn needs_beats_failed_and_working() {
        assert_eq!(state(&Facts { asks: true, failure: Some("failed".into()), replying: true, streamed: true, ..on() }), "needs");
        assert_eq!(state(&Facts { failure: Some("signin".into()), ..on() }), "needs");
    }
    #[test]
    fn failed_is_red_only_for_failures() {
        assert_eq!(state(&Facts { failure: Some("failed".into()), replying: true, ..on() }), "failed");
    }
    #[test]
    fn working_needs_words_or_a_run() {
        assert_eq!(state(&Facts { replying: true, streamed: true, ..on() }), "working");
        assert_eq!(state(&Facts { run_live: true, ..on() }), "working");
    }
    #[test]
    fn thinking_before_the_first_words() {
        assert_eq!(state(&Facts { replying: true, ..on() }), "thinking");
        assert_eq!(state(&Facts { queued: true, ..on() }), "thinking");
    }
    #[test]
    fn done_while_new() {
        assert_eq!(state(&Facts { unread: true, ..on() }), "done");
        assert_eq!(state(&Facts { answered_ago: Some(30), ..on() }), "done");
    }
    #[test]
    fn awake_then_asleep() {
        assert_eq!(state(&Facts { answered_ago: Some(300), active_ago: Some(300), ..on() }), "awake");
        assert_eq!(state(&Facts { primary: true, ..on() }), "awake");
        assert_eq!(state(&on()), "idle");
    }
}
