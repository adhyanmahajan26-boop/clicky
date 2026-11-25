//! "About you": one file about the owner that every bot reads (Hermes's and OpenClaw's USER.md), in the memory folder as
//! `about-you.md`. The owner writes it in Settings; a bot adds a fact with an `[ABOUT YOU: …]` line, only on a turn the owner's own
//! words started. The Mac's ClickyCore `OwnerProfile` has the same rules.

use crate::settings::OWNER_UNSET;

pub const FILE_NAME: &str = "about-you.md";
/// Characters that go into every prompt.
pub const LIMIT: usize = 3_000;
pub const TAG_EXAMPLE: &str = "[ABOUT YOU: one short fact]";
pub const NEW_FILE: &str = "<!-- About you: every bot reads this. Write what they should know about you, one line each. -->\n";
pub const FULL_NOTE: &str = "About you is full, so nothing new was saved. Tidy it in Settings › About.";

/// The section every bot's persona carries, right after its own instructions. Over the limit, the start goes in.
pub fn section(text: &str, path: &str, owner: &str) -> String {
    let who = if owner == OWNER_UNSET { "the owner".to_string() } else { owner.to_string() };
    let body = without_comment(text).trim().to_string();
    let how_to = format!(
        "When {who} tells you something lasting about themselves (their work, the people around them, what they like, how they want answers), \
         end your reply with one line {TAG_EXAMPLE} and Vello adds it here for every bot. Only facts they told you; never secrets, keys or passwords."
    );
    if body.is_empty() {
        return format!("About {who}: nothing is saved yet ({path}, shared by every bot). {how_to}");
    }
    let shown = if body.chars().count() > LIMIT { format!("{}\n[… cut at {LIMIT} characters …]", body.chars().take(LIMIT).collect::<String>()) } else { body };
    format!("About {who}, shared by every bot ({path}):\n<about-owner>\n{shown}\n</about-owner>\n{how_to}")
}

/// `[ABOUT YOU: …]` lines taken out of a reply: the reply without them, and the facts, empty ones left out.
pub fn extract(reply: &str) -> (String, Vec<String>) {
    let mut facts = vec![];
    let mut kept = vec![];
    let mut found = false;
    for line in reply.split('\n') {
        match fact_in_line(line.trim()) {
            Some(fact) => {
                found = true;
                if !fact.is_empty() {
                    facts.push(fact);
                }
            }
            None => kept.push(line),
        }
    }
    if !found {
        return (reply.to_string(), vec![]);
    }
    (kept.join("\n").trim().to_string(), facts)
}

fn fact_in_line(line: &str) -> Option<String> {
    let upper = line.to_uppercase();
    if !(upper.starts_with("[ABOUT YOU:") || upper.starts_with("[ABOUT ME:")) || !line.ends_with(']') {
        return None;
    }
    let colon = line.find(':')?;
    let inside = &line[colon + 1..line.len() - 1];
    Some(inside.trim().chars().take(300).collect())
}

#[derive(Debug, PartialEq)]
pub enum Addition {
    Added { text: String, facts: Vec<String> },
    AlreadyKnown,
    Full,
}

/// The file with the facts added as "- " lines at its end, each only once (any case, any punctuation at the end).
pub fn adding(facts: &[String], text: &str) -> Addition {
    let mut seen: std::collections::HashSet<String> = text.split('\n').map(normalised).collect();
    let mut new = vec![];
    for fact in facts {
        let key = normalised(fact);
        if key.is_empty() || seen.contains(&key) {
            continue;
        }
        seen.insert(key);
        new.push(fact.clone());
    }
    if new.is_empty() {
        return Addition::AlreadyKnown;
    }
    let mut result = text.trim().to_string();
    if !result.is_empty() {
        result.push('\n');
    }
    result.push_str(&new.iter().map(|f| format!("- {f}")).collect::<Vec<_>>().join("\n"));
    result.push('\n');
    if without_comment(&result).chars().count() > LIMIT {
        return Addition::Full;
    }
    Addition::Added { text: result, facts: new }
}

pub fn added_note(facts: &[String]) -> String {
    let list = facts.iter().map(|f| format!("\"{f}\"")).collect::<Vec<_>>().join(", ");
    format!("Saved to About you, which every bot reads: {list}. Change or remove it in Settings › About.")
}

/// The text without a first-line `<!-- … -->` comment.
pub fn without_comment(text: &str) -> String {
    let mut lines = text.split('\n');
    match lines.next().map(str::trim) {
        Some(first) if first.starts_with("<!--") && first.ends_with("-->") => lines.collect::<Vec<_>>().join("\n"),
        _ => text.to_string(),
    }
}

fn normalised(line: &str) -> String {
    let mut text = line.trim().to_lowercase();
    if text.starts_with("- ") || text.starts_with("* ") {
        text = text[2..].to_string();
    }
    while text.ends_with(['.', '!', ';', ',']) {
        text.pop();
    }
    text.trim().to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_section_carries_the_file_without_its_comment() {
        let s = section(&format!("{NEW_FILE}- Runs a studio in Pune\n"), "/m/about-you.md", "Addy");
        assert!(s.starts_with("About Addy, shared by every bot (/m/about-you.md):"));
        assert!(s.contains("<about-owner>\n- Runs a studio in Pune\n</about-owner>"));
        assert!(!s.contains("<!--"));
        assert!(section(NEW_FILE, "p", OWNER_UNSET).starts_with("About the owner: nothing is saved yet"));
    }

    #[test]
    fn facts_are_taken_out_and_added_once() {
        let (text, facts) = extract("Noted.\n[ABOUT YOU: Prefers short answers]\n  [about you: Cofounder is Riya ]\n[ABOUT YOU: ]");
        assert_eq!(text, "Noted.");
        assert_eq!(facts, vec!["Prefers short answers".to_string(), "Cofounder is Riya".to_string()]);
        assert_eq!(extract("inline [ABOUT YOU: x] stays").0, "inline [ABOUT YOU: x] stays");
        let start = format!("{NEW_FILE}- Prefers short answers.\n");
        match adding(&["prefers short answers".into(), "Lives in Pune".into(), "Lives in Pune".into()], &start) {
            Addition::Added { text, facts } => {
                assert_eq!(facts, vec!["Lives in Pune".to_string()]);
                assert!(text.ends_with("- Prefers short answers.\n- Lives in Pune\n"));
                assert_eq!(adding(&["Lives in Pune!".into()], &text), Addition::AlreadyKnown);
            }
            other => panic!("expected an addition, got {other:?}"),
        }
        assert_eq!(adding(&["new".into()], &"x".repeat(LIMIT)), Addition::Full);
    }
}
