//! What Theo saves: bots, chat messages, chats, group chats, routines and coding runs.

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;

pub const NOTE_AUTHOR: &str = "note";
pub const OWNER_AUTHOR: &str = "user";
pub const ROUTINE_AUTHOR: &str = "routine";

fn new_id() -> String {
    uuid::Uuid::new_v4().to_string().to_uppercase()
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Bot {
    pub id: String,
    pub name: String,
    #[serde(default)]
    pub description: String,
    #[serde(default)]
    pub instructions: String,
    /// "claude", "opencode", or "api:<provider>" (not on this build yet).
    #[serde(default = "default_provider")]
    pub provider: String,
    #[serde(default = "default_model")]
    pub model: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub effort: Option<String>,
    /// Theo, the CEO.
    #[serde(default)]
    pub primary: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub enabled: Option<bool>,
    /// "member", "lead" or "ceo".
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub authority: Option<String>,
    /// Who this bot may message; nil means anyone.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub can_message: Option<Vec<String>>,
    #[serde(default)]
    pub apps: Vec<String>,
    /// How its Pixel face looks; None draws one picked from its id.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub look: Option<Look>,
    /// Its most recent turn or run that failed, until the owner has seen it or it worked since. Kept with the bot so the
    /// red face survives a restart.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_failure: Option<LastFailure>,
}

/// A Pixel face: finish (shell colour), trim, eye style, what's on top (an antenna or a hat) and an extra.
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct Look {
    pub fin: String,
    pub trim: String,
    pub eye: String,
    pub top: String,
    pub extra: String,
}

impl Look {
    const FINS: [&'static str; 9] = ["bone", "graphite", "onyx", "sand", "sky", "lilac", "blush", "slate", "cocoa"];
    const TRIMS: [&'static str; 7] = ["#FF7A45", "#F06FB0", "#45C8E6", "#5B8DEF", "#9B7BF0", "#F4F4F5", "#F4D7C4"];
    const EYES: [&'static str; 5] = ["block", "round", "tall", "wide", "heart"];
    const TOPS: [&'static str; 14] = ["none", "ball", "twin", "handle", "dish", "flag", "bolt", "hardhat", "cap", "beanie", "beret", "tophat", "crown", "headset"];
    const EXTRAS: [&'static str; 7] = ["none", "bowtie", "tie", "scarf", "bezel", "pencil", "star"];

    /// Every part the app can draw (theo-pixel.js: FIN, TRIMS, EYES, TOPS and HATS, EXTRAS). Anything else would break
    /// the drawing, or put text of its own into the page.
    pub fn is_known(&self) -> bool {
        const KNOWN_TOPS: [&str; 15] = ["none", "ball", "twin", "handle", "dish", "flag", "bolt", "heart", "hardhat", "cap", "beanie", "beret", "tophat", "crown", "headset"];
        Self::FINS.contains(&self.fin.as_str())
            && Self::TRIMS.contains(&self.trim.as_str())
            && Self::EYES.contains(&self.eye.as_str())
            && KNOWN_TOPS.contains(&self.top.as_str())
            && Self::EXTRAS.contains(&self.extra.as_str())
    }

    /// Theo's own face, and a stable one for any other bot from its id. No finish or trim is a status colour.
    pub fn for_bot(id: &str) -> Look {
        if id == "theo" {
            return Look { fin: "onyx".into(), trim: "#FF7A45".into(), eye: "block".into(), top: "ball".into(), extra: "tie".into() };
        }
        let mut h: u64 = 1469598103934665603;
        for b in id.bytes() {
            h = (h ^ b as u64).wrapping_mul(1099511628211);
        }
        let pick = |n: usize, shift: u32| ((h >> shift) as usize) % n;
        Look {
            fin: Self::FINS[pick(9, 0)].into(),
            trim: Self::TRIMS[pick(7, 8)].into(),
            eye: Self::EYES[pick(5, 16)].into(),
            top: Self::TOPS[pick(14, 24)].into(),
            extra: Self::EXTRAS[pick(7, 32)].into(),
        }
    }
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct LastFailure {
    /// "signin" (the engine is signed out or missing: yellow, the owner can fix it) or "failed" (red).
    pub kind: String,
    pub reason: String,
    pub at: DateTime<Utc>,
}

fn default_provider() -> String { "claude".into() }
fn default_model() -> String { "claude-sonnet-5-5".into() }

impl Bot {
    pub fn new(name: &str, description: &str, instructions: &str, provider: &str, model: &str) -> Self {
        let slug: String = name.to_lowercase().chars().filter(|c| c.is_ascii_alphanumeric()).collect();
        let id = if slug.is_empty() { new_id().to_lowercase() } else { format!("{}-{}", slug, &new_id().to_lowercase()[..6]) };
        Self {
            id,
            name: name.to_string(),
            description: description.to_string(),
            instructions: instructions.to_string(),
            provider: provider.to_string(),
            model: model.to_string(),
            effort: None,
            primary: false,
            enabled: None,
            authority: None,
            can_message: None,
            apps: vec![],
            look: None,
            last_failure: None,
        }
    }
    pub fn theo() -> Self {
        let mut bot = Self::new("Theo", "Your CEO: runs the team", "You are Theo, the owner's CEO bot. You run the team of bots, answer directly when you can, and hand work to the right bot when that's better.", "claude", "claude-sonnet-5-5");
        bot.id = "theo".into();
        bot.primary = true;
        bot
    }
    pub fn is_on(&self) -> bool { self.enabled.unwrap_or(true) }
    pub fn authority_level(&self) -> &str {
        self.authority.as_deref().unwrap_or(if self.primary { "ceo" } else { "member" })
    }
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct ChatMessage {
    #[serde(default = "new_id")]
    pub id: String,
    /// A bot id, "user" (the owner), "note" (Theo's own line) or "routine".
    pub author: String,
    pub text: String,
    #[serde(default = "Utc::now")]
    pub at: DateTime<Utc>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub card: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub exchange_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub run_id: Option<String>,
}

impl ChatMessage {
    pub fn new(author: &str, text: impl Into<String>) -> Self {
        Self { id: new_id(), author: author.into(), text: text.into(), at: Utc::now(), card: None, exchange_id: None, run_id: None }
    }
    pub fn note(text: impl Into<String>) -> Self { Self::new(NOTE_AUTHOR, text) }
    pub fn with_exchange(mut self, exchange: Option<String>) -> Self {
        self.exchange_id = exchange;
        self
    }
}

/// One chat: a bot's chat with the owner, a group chat ("group-<id>") or a private thread between two bots ("dm:a+b").
#[derive(Clone, Debug, Default, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Conversation {
    #[serde(default)]
    pub messages: Vec<ChatMessage>,
    /// Each bot's engine session for this chat.
    #[serde(default)]
    pub sessions: HashMap<String, String>,
    /// In a group chat: how many messages each bot has read.
    #[serde(default)]
    pub seen: HashMap<String, usize>,
    /// The last message each bot's finished turn took in.
    #[serde(default)]
    pub heard: HashMap<String, String>,
    /// In a group chat: the answers each bot wrote itself since it last read the chat.
    #[serde(default)]
    pub own_answers: HashMap<String, Vec<String>>,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Group {
    pub id: String,
    pub name: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub head_id: Option<String>,
    #[serde(default)]
    pub member_ids: Vec<String>,
}

impl Group {
    pub fn room_id(&self) -> String { format!("group-{}", self.id) }
    /// The head first, then the members.
    pub fn all_ids(&self) -> Vec<String> {
        let mut ids: Vec<String> = self.head_id.iter().cloned().collect();
        ids.extend(self.member_ids.iter().filter(|m| Some(*m) != self.head_id.as_ref()).cloned());
        ids
    }
}

#[derive(Clone, Copy, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum ScheduleKind { Daily, Weekdays, Weekly, Hourly, Every }

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Schedule {
    pub kind: ScheduleKind,
    #[serde(default = "nine")]
    pub hour: u32,
    #[serde(default)]
    pub minute: u32,
    /// 1 = Sunday … 7 = Saturday, for weekly.
    #[serde(default = "two")]
    pub weekday: u32,
    #[serde(default = "sixty")]
    pub interval_minutes: u32,
}
fn nine() -> u32 { 9 }
fn two() -> u32 { 2 }
fn sixty() -> u32 { 60 }

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct RoutineRun {
    #[serde(default = "new_id")]
    pub id: String,
    pub started_at: DateTime<Utc>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub finished_at: Option<DateTime<Utc>>,
    /// running, done, failed, skipped, quiet or missed.
    pub status: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub summary: Option<String>,
}

impl RoutineRun {
    pub fn running() -> Self { Self { id: new_id(), started_at: Utc::now(), finished_at: None, status: "running".into(), summary: None } }
    pub fn finished(status: &str, summary: impl Into<String>) -> Self {
        let now = Utc::now();
        Self { id: new_id(), started_at: now, finished_at: Some(now), status: status.into(), summary: Some(summary.into()) }
    }
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Routine {
    #[serde(default = "new_id")]
    pub id: String,
    pub name: String,
    /// A bot id, or "group:<id>".
    pub target: String,
    pub instruction: String,
    pub schedule: Schedule,
    #[serde(default)]
    pub paused: bool,
    #[serde(default = "Utc::now")]
    pub created_at: DateTime<Utc>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub next_run_at: Option<DateTime<Utc>>,
    #[serde(default)]
    pub runs: Vec<RoutineRun>,
}

impl Routine {
    pub fn new(name: &str, target: &str, instruction: &str, schedule: Schedule) -> Self {
        Self { id: new_id(), name: name.into(), target: target.into(), instruction: instruction.into(), schedule, paused: false, created_at: Utc::now(), next_run_at: None, runs: vec![] }
    }
}

/// A coding run: a coding agent working in its own folder or branch.
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct CodingRun {
    #[serde(default = "new_id")]
    pub id: String,
    pub title: String,
    /// running, done, failed or stopped.
    pub phase: String,
    pub folder: String,
    #[serde(default)]
    pub room: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub branch: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pull_request: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub session_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub harness: Option<String>,
    /// The pitch message it came from, so a repeated answer can't start it twice.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub prompt_digest: Option<String>,
    #[serde(default = "Utc::now")]
    pub started_at: DateTime<Utc>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub summary: Option<String>,
}

/// Private threads between two bots.
pub mod dm {
    pub const PREFIX: &str = "dm:";
    pub fn id(a: &str, b: &str) -> String {
        let mut pair = [a, b];
        pair.sort();
        format!("{}{}+{}", PREFIX, pair[0], pair[1])
    }
    pub fn is_thread(id: &str) -> bool { id.starts_with(PREFIX) }
    pub fn members(id: &str) -> Option<(String, String)> {
        let rest = id.strip_prefix(PREFIX)?;
        let parts: Vec<&str> = rest.split('+').collect();
        if parts.len() == 2 && !parts[0].is_empty() && !parts[1].is_empty() { Some((parts[0].into(), parts[1].into())) } else { None }
    }
    pub fn partner(bot: &str, id: &str) -> Option<String> {
        let (a, b) = members(id)?;
        if a == bot { Some(b) } else if b == bot { Some(a) } else { None }
    }
    pub fn card(exchange: &str, target: &str) -> String { format!("{}{}:{}", PREFIX, exchange, target) }
    pub fn thread_from_file_name(name: &str) -> Option<String> {
        let rest = name.strip_prefix("dm-")?;
        let id = format!("{}{}", PREFIX, rest);
        members(&id).map(|_| id)
    }
}

#[cfg(test)]
mod look_tests {
    use super::*;

    #[test]
    fn every_picked_look_is_one_the_app_can_draw() {
        for id in ["theo", "a", "researcher", "bot-42", "Ünïcode"] {
            assert!(Look::for_bot(id).is_known(), "{id}");
        }
    }

    #[test]
    fn a_look_with_unknown_parts_is_refused() {
        let good = Look::for_bot("x");
        assert!(!Look { trim: "#FFF\"><b>".into(), ..good.clone() }.is_known());
        assert!(!Look { fin: "gold".into(), ..good.clone() }.is_known());
        assert!(!Look { top: "<img>".into(), ..good }.is_known());
    }
}
