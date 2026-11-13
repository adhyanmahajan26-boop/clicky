//! How bots write and what Theo reads out of their replies, as pure functions: [TELL:] lines, ```routine and ```prompt blocks,
//! @Name in group chats, the caps on private messages and who speaks next in a group chat. Ported from ClickyCore's
//! `BotProtocol`, `ClickyOrder`, `RoutineIntent` and `HarnessParity`.

use once_cell::sync::Lazy;
use regex::Regex;

/// A name as it's matched: lower case, letters and digits only.
pub fn search_name(name: &str) -> String {
    name.to_lowercase().chars().filter(|c| c.is_alphanumeric()).collect()
}

// MARK: Code spans

/// Byte ranges of fenced (```) and inline (`) code, where tags don't count.
pub fn code_spans(text: &str) -> Vec<(usize, usize)> {
    let mut spans = vec![];
    let bytes = text.as_bytes();
    let mut i = 0;
    while i < bytes.len() {
        if text[i..].starts_with("```") {
            let start = i;
            let end = text[i + 3..].find("```").map(|e| i + 3 + e + 3).unwrap_or(bytes.len());
            spans.push((start, end));
            i = end;
            continue;
        }
        if bytes[i] == b'`' {
            if let Some(e) = text[i + 1..].find('`') {
                let end = i + 1 + e + 1;
                if !text[i..end].contains('\n') {
                    spans.push((i, end));
                    i = end;
                    continue;
                }
            }
        }
        i += text[i..].chars().next().map(|c| c.len_utf8()).unwrap_or(1);
    }
    spans
}

// MARK: [TELL:] and [CLICKY:]

#[derive(Debug, Clone, PartialEq)]
pub enum Order {
    /// [TELL: name: message]
    Tell { name: String, message: String },
    /// [CLICKY: ...]: an order for Clicky, which this build doesn't have on every platform.
    Clicky(String),
}

static TAG_HEAD: Lazy<Regex> = Lazy::new(|| Regex::new(r"(?i)\[\s*(CLICKY|TELL)\s*:").unwrap());

fn closing_bracket(text: &str, from: usize) -> Option<usize> {
    let mut depth = 1;
    for (offset, c) in text[from..].char_indices() {
        match c {
            '[' => depth += 1,
            ']' => {
                depth -= 1;
                if depth == 0 {
                    return Some(from + offset);
                }
            }
            _ => {}
        }
    }
    None
}

/// Takes the orders out of a finished reply: what's left to show, and the orders in order.
pub fn extract_orders(text: &str) -> (String, Vec<Order>) {
    let spans = code_spans(text);
    let mut orders = vec![];
    let mut kept = String::new();
    let mut cursor = 0;
    let mut search = 0;
    while search < text.len() {
        let Some(m) = TAG_HEAD.captures_at(text, search) else { break };
        let whole = m.get(0).unwrap();
        if let Some(&(_, end)) = spans.iter().find(|(s, e)| *s <= whole.start() && whole.start() < *e) {
            search = end;
            continue;
        }
        let is_tell = m.get(1).unwrap().as_str().eq_ignore_ascii_case("TELL");
        let (body, end) = match closing_bracket(text, whole.end()) {
            Some(close) => (text[whole.end()..close].trim().to_string(), close + 1),
            None => {
                let paragraph_end = text[whole.end()..].find("\n\n").map(|p| whole.end() + p).unwrap_or(text.len());
                (text[whole.end()..paragraph_end].trim().to_string(), paragraph_end)
            }
        };
        kept.push_str(&text[cursor..whole.start()]);
        cursor = end;
        search = end;
        if is_tell {
            if let Some(colon) = body.find(':') {
                let name = body[..colon].trim().trim_matches(|c| c == '*' || c == '@').to_string();
                let message = body[colon + 1..].trim().to_string();
                if !name.is_empty() && !message.is_empty() {
                    orders.push(Order::Tell { name, message });
                }
            }
        } else if !body.is_empty() {
            orders.push(Order::Clicky(body));
        }
    }
    kept.push_str(&text[cursor..]);
    // Lines left empty by a removed tag go too.
    let cleaned = kept.lines().collect::<Vec<_>>().join("\n");
    static BLANKS: Lazy<Regex> = Lazy::new(|| Regex::new(r"\n{3,}").unwrap());
    (BLANKS.replace_all(cleaned.trim(), "\n\n").to_string(), orders)
}

// MARK: Blocks

/// The body of the first ```<kind> fenced block.
pub fn fenced_block(text: &str, kind: &str) -> Option<String> {
    let opener = format!("```{}", kind);
    let mut from = 0;
    while let Some(start) = text[from..].find(&opener) {
        let start = from + start;
        let after = start + opener.len();
        // ```prompt must not match ```promptly: the next character ends the word.
        if text[after..].chars().next().map(|c| c.is_alphanumeric()).unwrap_or(false) {
            from = after;
            continue;
        }
        let body_start = text[after..].find('\n').map(|n| after + n + 1).unwrap_or(after);
        let end = text[body_start..].find("```").map(|e| body_start + e).unwrap_or(text.len());
        let body = text[body_start..end].trim().to_string();
        return if body.is_empty() { None } else { Some(body) };
    }
    None
}

/// A labelled line such as "Project: x", "Repo: path", "New folder: name".
pub fn labeled(label: &str, text: &str) -> Option<String> {
    let pattern = format!(r"(?im)^\s*\**{}\**\s*:\**\s*(.+?)\s*$", regex::escape(label));
    let re = Regex::new(&pattern).ok()?;
    re.captures(text).map(|c| c[1].trim().trim_matches('`').trim_matches('*').trim().to_string()).filter(|s| !s.is_empty())
}

#[derive(Debug, Clone, PartialEq)]
pub struct RoutineRequest {
    pub name: String,
    pub when: String,
    pub schedule: crate::model::Schedule,
    pub instruction: String,
}

/// The ```routine block a bot writes to set one up: {"when": "weekdays 08:00", "do": "…", "name": "…"}.
pub fn routine_request(text: &str) -> Option<RoutineRequest> {
    let body = fenced_block(text, "routine")?;
    let object: serde_json::Value = serde_json::from_str(&body).ok()?;
    let when = object.get("when")?.as_str()?.to_string();
    let schedule = crate::schedule::parse(&when)?;
    let instruction = object.get("do")?.as_str()?.trim().to_string();
    if instruction.is_empty() {
        return None;
    }
    let name = object.get("name").and_then(|n| n.as_str()).map(str::to_string).unwrap_or_else(|| instruction.chars().take(40).collect());
    Some(RoutineRequest { name, when, schedule, instruction })
}

// MARK: Intent

pub const ROUTINE_RUN_PREFIX: &str = "\u{23F0} Routine";

pub fn is_routine_run(text: &str) -> bool { text.trim().starts_with(ROUTINE_RUN_PREFIX) }

/// The owner asked for something on a schedule, or to change one.
pub fn owner_asked_for_routine(text: &str) -> bool {
    if is_routine_run(text) {
        return false;
    }
    static PATTERNS: Lazy<Vec<Regex>> = Lazy::new(|| {
        let units = "minutes?|mins?|hours?|days?|nights?|mornings?|evenings?|afternoons?|weeks?|weekdays?|weekends?|months?|year|mondays?|tuesdays?|wednesdays?|thursdays?|fridays?|saturdays?|sundays?|mon|tue|wed|thu|fri|sat|sun";
        [
            r"\broutines?\b".to_string(),
            r"\bremind(er|ers)?\b".to_string(),
            r"\bschedul(e|ed|ing)\b".to_string(),
            r"\b(daily|nightly|weekly|hourly|monthly|fortnightly)\b".to_string(),
            format!(r"\b(every|each)\s+(\d+\s+|other\s+|single\s+|few\s+|couple of\s+)?({units})\b"),
            r"\bon\s+(mondays|tuesdays|wednesdays|thursdays|fridays|saturdays|sundays|weekdays|weekends)\b".to_string(),
            r"\b(once|twice)\s+a\s+(day|week|month)\b".to_string(),
            r"\b(recurring|repeat(ing)?|cron)\b".to_string(),
            r"\bevery\s+\d{1,2}(:\d{2})?\s*(am|pm)?\b".to_string(),
        ]
        .iter()
        .map(|p| Regex::new(p).unwrap())
        .collect()
    });
    let lower = text.to_lowercase();
    PATTERNS.iter().any(|re| re.is_match(&lower))
}

pub fn asks_for_schedule(text: &str) -> bool {
    static RE: Lazy<Regex> = Lazy::new(|| Regex::new(r"(?i)\b(every|each)\s+(day|morning|evening|night|weekday|week|monday|tuesday|wednesday|thursday|friday|saturday|sunday|hour|\d+\s*(min|minutes|hours?))\b|\b(daily|hourly|weekly|routine|schedule)\b").unwrap());
    RE.is_match(text)
}

pub fn asks_for_fresh_session(text: &str) -> bool {
    matches!(text.trim().to_lowercase().as_str(), "/new" | "/reset" | "/fresh")
}

pub fn asks_for_doctor(text: &str) -> bool {
    matches!(text.trim().to_lowercase().as_str(), "/doctor" | "/health")
}

/// Asked in so many words to build or change code, as opposed to "make me a prompt". The coding agent has full access,
/// so a word like "build" alone isn't enough: the words have to be about code.
pub fn owner_asked_to_build(text: &str) -> bool {
    if is_routine_run(text) {
        return false;
    }
    let lower = text.to_lowercase();
    if Regex::new(r"\bprompt\b").unwrap().is_match(&lower) {
        return false;
    }
    if Regex::new(r"(^|\s)@(code|t3)\b|^/run\s").unwrap().is_match(&lower) {
        return true;
    }
    static VERB: Lazy<Regex> = Lazy::new(|| Regex::new(r"\b(build|make|create|write|code|implement|fix|add|change|refactor|scaffold|set up|program|develop|ship|update)\b").unwrap());
    static CODE: Lazy<Regex> = Lazy::new(|| Regex::new(r"\b(app|website|web site|site|script|code|repo|repository|function|file|folder|page|api|cli|tool|program|feature|bug|tests?|component|module|library|class|endpoint|server|game|extension|plugin)\b|\b[\w-]+\.(txt|md|py|js|ts|tsx|jsx|rs|swift|go|rb|java|kt|c|cpp|h|html|css|json|yaml|yml|toml|sh)\b").unwrap());
    VERB.is_match(&lower) && CODE.is_match(&lower)
}

pub fn is_about_existing_code(text: &str) -> bool {
    Regex::new(r"(?i)\b(fix|change|update|refactor|bug|failing|broken|existing|our|my repo|the repo)\b").unwrap().is_match(text)
}

// MARK: @Name

fn is_word_char(c: char) -> bool { c.is_alphanumeric() || c == '-' || c == '_' }

fn without_code(text: &str) -> String {
    static FENCE: Lazy<Regex> = Lazy::new(|| Regex::new(r"(?s)```.*?(```|$)").unwrap());
    FENCE.replace_all(text, " ").to_string()
}

fn find_names(text: &str, bots: &[(String, String)], with_at: bool) -> Vec<String> {
    let lower = without_code(text).to_lowercase();
    let mut sorted: Vec<&(String, String)> = bots.iter().collect();
    sorted.sort_by_key(|b| std::cmp::Reverse(b.1.chars().count()));
    let mut taken: Vec<(usize, usize)> = vec![];
    let mut found: Vec<(usize, String)> = vec![];
    for (id, name) in sorted {
        let lname = name.to_lowercase();
        if lname.is_empty() {
            continue;
        }
        let needle = if with_at { format!("@{}", lname) } else { lname.clone() };
        let mut from = 0;
        while let Some(pos) = lower[from..].find(&needle) {
            let start = from + pos;
            let end = start + needle.len();
            from = end;
            let ends_word = lower[end..].chars().next().map(|c| !is_word_char(c)).unwrap_or(true);
            let starts_word = with_at || lower[..start].chars().next_back().map(|c| !is_word_char(c)).unwrap_or(true);
            if !ends_word || !starts_word || taken.iter().any(|&(s, e)| start < e && s < end) {
                continue;
            }
            taken.push((start, end));
            if !found.iter().any(|(_, f)| f == id) {
                found.push((start, id.clone()));
            }
        }
    }
    found.sort_by_key(|f| f.0);
    found.into_iter().map(|f| f.1).collect()
}

/// The ids of the bots @-named in `text`, in the order they're named, each once. Longest names win.
pub fn mentions_ordered(text: &str, bots: &[(String, String)]) -> Vec<String> { find_names(text, bots, true) }

/// Like `mentions_ordered`, but a name counts with or without the @ (only the head's turns use this).
pub fn mentions_named(text: &str, bots: &[(String, String)]) -> Vec<String> { find_names(text, bots, false) }

// MARK: Caps on private messages

pub const MAX_ROUND_TRIPS: u32 = 3;
pub const MAX_PER_OWNER_MESSAGE: u32 = 12;

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum Verdict { Send, RoundTripCap, TotalCap }

#[derive(Debug, Clone, Default)]
pub struct DmBudget { pub sent_since_owner_spoke: u32 }

impl DmBudget {
    pub fn owner_spoke(&mut self) { self.sent_since_owner_spoke = 0; }
    pub fn verdict(&self, round_trips_so_far: u32) -> Verdict {
        if self.sent_since_owner_spoke >= MAX_PER_OWNER_MESSAGE { return Verdict::TotalCap; }
        if round_trips_so_far >= MAX_ROUND_TRIPS { return Verdict::RoundTripCap; }
        Verdict::Send
    }
    pub fn note_sent(&mut self) { self.sent_since_owner_spoke += 1; }
}

pub fn cap_line(verdict: Verdict, sender: &str, target: &str) -> Option<String> {
    match verdict {
        Verdict::Send => None,
        Verdict::RoundTripCap => Some(format!("{sender} and {target} have gone back and forth {MAX_ROUND_TRIPS} times on this, which is the limit for one exchange, so {sender} didn't send another message.")),
        Verdict::TotalCap => Some(format!("The bots have sent {MAX_PER_OWNER_MESSAGE} private messages since your last message, which is the limit, so {sender}'s message to {target} didn't go. Tell me if you want them to keep going.")),
    }
}

// MARK: Group turns

#[derive(Debug, Clone, PartialEq)]
pub enum Step { Speak { bot: String, wrap_up: bool }, Finished }

/// Members take turns one at a time, in the order the head named them, then the head writes one wrap-up and it stops.
#[derive(Debug, Clone)]
pub struct GroupTurnPlan {
    pub head: String,
    pub queue: Vec<String>,
    pub turns_taken: u32,
    pub spoke: std::collections::HashMap<String, u32>,
    pub wrapping_up: bool,
    pub finished: bool,
    pub needs_wrap_up: bool,
}

impl GroupTurnPlan {
    pub const MAX_TURNS: u32 = 8;
    pub const MAX_TURNS_PER_BOT: u32 = 2;

    pub fn new(head: &str, first: &[String]) -> Self {
        let mut seen = std::collections::HashSet::new();
        let list: Vec<String> = if first.is_empty() { vec![head.to_string()] } else { first.to_vec() };
        let unique: Vec<String> = list.into_iter().filter(|x| seen.insert(x.clone())).collect();
        let queue = if unique.iter().any(|x| x == head) {
            std::iter::once(head.to_string()).chain(unique.into_iter().filter(|x| x != head)).collect()
        } else {
            unique
        };
        Self { head: head.into(), queue, turns_taken: 0, spoke: Default::default(), wrapping_up: false, finished: false, needs_wrap_up: false }
    }

    pub fn start(&mut self) -> Step { self.next() }

    pub fn turn_ended(&mut self, by: &str, mentions: &[String], can_hand_out: bool, others: &[String]) -> Step {
        self.turns_taken += 1;
        *self.spoke.entry(by.to_string()).or_default() += 1;
        if by != self.head { self.needs_wrap_up = true; }
        if self.wrapping_up {
            self.finished = true;
            self.queue.clear();
            return Step::Finished;
        }
        if can_hand_out {
            let wanted: Vec<String> = mentions.iter().filter(|id| {
                id.as_str() != by && id.as_str() != self.head && others.contains(id) && !self.queue.contains(id)
                    && self.spoke.get(*id).copied().unwrap_or(0) < Self::MAX_TURNS_PER_BOT
            }).cloned().collect();
            if by == self.head {
                self.queue.extend(wanted);
            } else {
                let rest = std::mem::take(&mut self.queue);
                self.queue = wanted.into_iter().chain(rest).collect();
            }
        }
        self.next()
    }

    pub fn finish(&mut self) {
        self.finished = true;
        self.queue.clear();
    }

    fn next(&mut self) -> Step {
        if self.finished { return Step::Finished; }
        if self.turns_taken >= Self::MAX_TURNS - if self.needs_wrap_up { 1 } else { 0 } { self.queue.clear(); }
        if !self.queue.is_empty() {
            return Step::Speak { bot: self.queue.remove(0), wrap_up: false };
        }
        if self.needs_wrap_up {
            self.wrapping_up = true;
            return Step::Speak { bot: self.head.clone(), wrap_up: true };
        }
        self.finished = true;
        Step::Finished
    }
}

// MARK: Routines

pub const QUIET_MARKER: &str = "[SILENT]";

pub fn is_quiet(answer: Option<&str>) -> bool {
    let Some(answer) = answer else { return false };
    let trimmed = answer.trim().trim_matches(|c| "`*_.".contains(c)).to_uppercase();
    matches!(trimmed.as_str(), "[SILENT]" | "SILENT" | "NO_REPLY" | "[NO_REPLY]")
}

pub fn quiet_how_to(owner: &str) -> String {
    format!("If this run is a check and nothing has changed that's worth {owner}'s attention, answer with exactly {QUIET_MARKER} and nothing else: nothing is posted. Never answer {QUIET_MARKER} when the job is to deliver something (a brief, a report, a summary).")
}

/// How late a missed slot may still run: half the period, 2 minutes to 2 hours.
pub fn catch_up_window(period_seconds: f64) -> f64 { (period_seconds / 2.0).clamp(120.0, 7200.0) }

#[derive(Debug, PartialEq)]
pub enum CatchUp { NotYet, Fire, Missed }

pub fn catch_up(due: chrono::DateTime<chrono::Utc>, now: chrono::DateTime<chrono::Utc>, period_seconds: f64) -> CatchUp {
    let late = (now - due).num_milliseconds() as f64 / 1000.0;
    if late < 0.0 { CatchUp::NotYet } else if late <= catch_up_window(period_seconds) { CatchUp::Fire } else { CatchUp::Missed }
}

/// Drops a "**Name:**" or "Name here." opener a bot adds to its own message.
pub fn without_name_heading(text: &str, name: &str) -> String {
    let pattern = format!(r"(?i)^\s*\*{{0,2}}{}( here)?[:.]?\*{{0,2}}[:.]?\s*", regex::escape(name));
    match Regex::new(&pattern) {
        Ok(re) => {
            // Only a heading, never the whole reply: "Ledger." alone stays.
            let out = re.replace(text, "").to_string();
            if out.trim().is_empty() { text.to_string() } else { out }
        }
        Err(_) => text.to_string(),
    }
}

/// A session the engine doesn't have any more.
pub fn says_session_is_lost(text: &str) -> bool {
    static RE: Lazy<Regex> = Lazy::new(|| Regex::new(r"(?i)no conversation found|session[^\n]{0,60}not found|no such session|unknown session|could not find (the )?session|no (saved )?session|invalid session|valid session|thread[^\n]{0,40}not found").unwrap());
    RE.is_match(text)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tells_come_out() {
        let (text, orders) = extract_orders("Asking.\n[TELL: Mirror: is 391 prime?]\nDone [x].");
        assert_eq!(orders, vec![Order::Tell { name: "Mirror".into(), message: "is 391 prime?".into() }]);
        assert_eq!(text, "Asking.\n\nDone [x].");
    }

    #[test]
    fn tags_in_code_stay() {
        let (_, orders) = extract_orders("```\n[TELL: A: b]\n```");
        assert!(orders.is_empty());
    }

    #[test]
    fn nested_brackets() {
        let (_, orders) = extract_orders("[TELL: Coder: is arr[0] safe?]");
        assert_eq!(orders, vec![Order::Tell { name: "Coder".into(), message: "is arr[0] safe?".into() }]);
    }

    #[test]
    fn budget() {
        let mut b = DmBudget::default();
        for _ in 0..12 { assert_eq!(b.verdict(0), Verdict::Send); b.note_sent(); }
        assert_eq!(b.verdict(0), Verdict::TotalCap);
        b.owner_spoke();
        assert_eq!(b.verdict(3), Verdict::RoundTripCap);
    }

    #[test]
    fn group_plan_order() {
        let mut plan = GroupTurnPlan::new("h", &[]);
        assert_eq!(plan.start(), Step::Speak { bot: "h".into(), wrap_up: false });
        let others = vec!["a".to_string(), "b".to_string()];
        assert_eq!(plan.turn_ended("h", &["b".into(), "a".into()], true, &others), Step::Speak { bot: "b".into(), wrap_up: false });
        assert_eq!(plan.turn_ended("b", &["a".into()], true, &others), Step::Speak { bot: "a".into(), wrap_up: false });
        assert_eq!(plan.turn_ended("a", &["b".into()], true, &others), Step::Speak { bot: "b".into(), wrap_up: false });
        assert_eq!(plan.turn_ended("b", &[], true, &others), Step::Speak { bot: "h".into(), wrap_up: true });
        assert_eq!(plan.turn_ended("h", &["a".into()], false, &others), Step::Finished);
    }

    #[test]
    fn hijacker_cannot_loop() {
        let mut plan = GroupTurnPlan::new("h", &[]);
        plan.start();
        let others = vec!["a".to_string(), "b".to_string()];
        let mut step = plan.turn_ended("h", &["a".into()], true, &others);
        let mut turns = 1;
        while let Step::Speak { bot, wrap_up } = step.clone() {
            turns += 1;
            let mentions: Vec<String> = others.iter().filter(|o| **o != bot).cloned().collect();
            step = plan.turn_ended(&bot, &mentions, !wrap_up, &others);
        }
        assert!(turns <= GroupTurnPlan::MAX_TURNS);
    }

    #[test]
    fn mentions() {
        let bots = vec![("1".to_string(), "Coder".to_string()), ("2".to_string(), "Coder 2".to_string())];
        assert_eq!(mentions_ordered("hi @Coder 2 and @Coder", &bots), vec!["2", "1"]);
        assert_eq!(mentions_named("Coder first", &bots), vec!["1"]);
    }

    #[test]
    fn routine_block() {
        let r = routine_request("ok\n```routine\n{\"name\":\"x\",\"when\":\"daily 08:00\",\"do\":\"brief\"}\n```").unwrap();
        assert_eq!(r.name, "x");
        assert!(owner_asked_for_routine("send me a brief every morning"));
        assert!(!owner_asked_for_routine("summarise this file"));
    }

    #[test]
    fn quiet() {
        assert!(is_quiet(Some(" [SILENT] ")));
        assert!(!is_quiet(Some("all quiet today")));
    }

    #[test]
    fn build_words() {
        assert!(owner_asked_to_build("Build it: in a new folder called liar-1, make liar.txt containing the word liar."));
        assert!(!owner_asked_to_build("what's the fix for a squeaky door?"));
        assert!(!owner_asked_to_build("write me a prompt for an app"));
    }
}
