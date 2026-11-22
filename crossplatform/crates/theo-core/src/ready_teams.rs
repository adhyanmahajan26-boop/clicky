//! Ready-made teams: a whole category at once, a manager and the bots who report to it, added in one click from Settings ›
//! Bot teams or by asking the CEO in chat (the Mac's ClickyCore `ReadyMadeTeams` and `ReadyMadeTeamLibrary`). Vello ships
//! a few (`ready_teams.json`, the very file the Mac's `ReadyMadeTeamsCatalog.swift` holds); the owner can change any of
//! them, make their own, save a category they already have as one, and pass them around as a file. Adding one goes through
//! the same `TeamBuildOrder` a ```team block does (`team_build::make`), so the bots are made exactly as the CEO makes them.

use crate::team_build::{self, listed_in_words, same_name, NewBot, NewCategory, TeamBuildOrder, MOST_BOTS, MOST_CATEGORIES};
use once_cell::sync::Lazy;
use regex::Regex;
use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};

/// The catalog, shared with the Mac.
pub const CATALOG_JSON: &str = include_str!("ready_teams.json");

/// A team is one category: its manager and at most this many bots under it, as many as one ```team block may make.
pub const MOST_WORKERS: usize = MOST_BOTS - 1;
/// At most this many ready-made teams from one answer in chat, as many categories as a block may make.
pub const MOST_TEAMS_AT_ONCE: usize = MOST_CATEGORIES;
pub const FILE_KIND: &str = "vello-bot-teams";

const LONGEST_BOT_NAME: usize = 40;
const LONGEST_CATEGORY_NAME: usize = 80;
const LONGEST_DOES: usize = 200;
const LONGEST_INSTRUCTIONS: usize = 4000;
const LONGEST_MODEL_WORDS: usize = 80;

/// Names a ready-made bot can't take: Vello and Pointer Assistant themselves.
const RESERVED_NAMES: [&str; 4] = ["Vello", "Theo", "Pointer Assistant", "Clicky"];

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, Default)]
pub struct Member {
    pub name: String,
    /// One line on its job: its description in the sidebar.
    #[serde(default)]
    pub does: String,
    /// Its own instructions. Empty: "You are <name>. <does>".
    #[serde(default)]
    pub instructions: String,
    /// The model it runs on, in the words a ```team block takes. None: the usual model.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub model: Option<String>,
    /// The brain it runs on. None: the CEO's.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub brain: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, Default)]
pub struct ReadyTeam {
    /// Stays the same when the team is renamed: a built-in team's id says which one the owner changed.
    #[serde(default)]
    pub id: String,
    pub name: String,
    /// One line on what the team is for. It's the category's purpose.
    #[serde(default)]
    pub purpose: String,
    pub manager: Member,
    #[serde(default)]
    pub workers: Vec<Member>,
}

impl ReadyTeam {
    /// The manager first, then the bots who report to it.
    pub fn members(&self) -> Vec<&Member> { std::iter::once(&self.manager).chain(self.workers.iter()).collect() }
}

#[derive(Deserialize, Serialize)]
struct TeamsFile {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    kind: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    version: Option<u32>,
    teams: Vec<ReadyTeam>,
}

/// The teams Vello ships with, in the order Settings shows them.
pub fn built_in() -> &'static [ReadyTeam] {
    static TEAMS: Lazy<Vec<ReadyTeam>> = Lazy::new(|| serde_json::from_str::<TeamsFile>(CATALOG_JSON).map(|f| f.teams).unwrap_or_default());
    &TEAMS
}

pub fn is_built_in(id: &str) -> bool { built_in().iter().any(|t| t.id == id) }

/// The built-in team with that id as Vello ships it, for Reset.
pub fn original(id: &str) -> Option<&'static ReadyTeam> { built_in().iter().find(|t| t.id == id) }

/// Whether the owner changed this built-in team from how Vello ships it.
pub fn is_changed(team: &ReadyTeam) -> bool { original(&team.id).map(|o| o != team).unwrap_or(false) }

// MARK: - The owner's library

/// What the owner changed: their versions of built-in teams (same id), their own teams, and the built-in teams they removed.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct Saved {
    #[serde(default)]
    pub teams: Vec<ReadyTeam>,
    #[serde(default)]
    pub hidden_built_in_ids: Vec<String>,
}

/// The teams Settings lists: the built-in ones in Vello's order (the owner's version where they changed one, none they
/// removed), then the owner's own.
pub fn library(saved: &Saved) -> Vec<ReadyTeam> {
    let mut teams: Vec<ReadyTeam> = built_in().iter()
        .filter(|t| !saved.hidden_built_in_ids.contains(&t.id))
        .map(|t| saved.teams.iter().find(|s| s.id == t.id).cloned().unwrap_or_else(|| t.clone()))
        .collect();
    teams.extend(saved.teams.iter().filter(|t| !is_built_in(&t.id)).cloned());
    teams
}

/// `saved` with `team` kept: a built-in team the same as Vello's is just Vello's again.
pub fn saving(team: &ReadyTeam, saved: &Saved) -> Saved {
    let mut result = saved.clone();
    result.hidden_built_in_ids.retain(|id| id != &team.id);
    match result.teams.iter_mut().find(|t| t.id == team.id) {
        Some(existing) => *existing = team.clone(),
        None => result.teams.push(team.clone()),
    }
    if original(&team.id) == Some(team) { result.teams.retain(|t| t.id != team.id); }
    result
}

/// `saved` without the team: the owner's own team goes, and a built-in one is hidden until it's put back.
pub fn removing(id: &str, saved: &Saved) -> Saved {
    let mut result = saved.clone();
    result.teams.retain(|t| t.id != id);
    if is_built_in(id) && !result.hidden_built_in_ids.iter().any(|h| h == id) { result.hidden_built_in_ids.push(id.to_string()); }
    result
}

/// `saved` with a built-in team as Vello ships it again, shown again if it was removed.
pub fn resetting(id: &str, saved: &Saved) -> Saved {
    let mut result = saved.clone();
    result.teams.retain(|t| t.id != id);
    result.hidden_built_in_ids.retain(|h| h != id);
    result
}

/// Every built-in team shown and as Vello ships it; the owner's own teams stay.
pub fn restoring_built_ins(saved: &Saved) -> Saved {
    Saved { teams: saved.teams.iter().filter(|t| !is_built_in(&t.id)).cloned().collect(), hidden_built_in_ids: vec![] }
}

/// A new id for an owner's team, not used by any team in `library`.
pub fn new_id(name: &str, library: &[ReadyTeam]) -> String {
    let slug: String = name.to_lowercase().chars().map(|c| if c.is_ascii_alphanumeric() { c } else { '-' }).collect();
    let slug: String = slug.split('-').filter(|p| !p.is_empty()).collect::<Vec<_>>().join("-").chars().take(40).collect();
    let base = format!("own-{}", if slug.is_empty() { "team" } else { &slug });
    let mut candidate = base.clone();
    let mut number = 2;
    while library.iter().any(|t| t.id == candidate) || is_built_in(&candidate) {
        candidate = format!("{base}-{number}");
        number += 1;
    }
    candidate
}

// MARK: - Checking and tidying

fn one_line(text: &str, longest: usize) -> String { text.replace('\n', " ").trim().chars().take(longest).collect::<String>().trim_end().to_string() }

fn tidy_member(member: &Member) -> Member {
    let words = |w: &Option<String>| w.as_deref().map(|w| one_line(w, LONGEST_MODEL_WORDS)).filter(|w| !w.is_empty());
    Member {
        name: one_line(&member.name, LONGEST_BOT_NAME),
        does: one_line(&member.does, LONGEST_DOES),
        instructions: member.instructions.trim().chars().take(LONGEST_INSTRUCTIONS).collect(),
        model: words(&member.model),
        brain: words(&member.brain),
    }
}

/// The team with every field trimmed and cut to the lengths a ```team block keeps, and empty bots left out.
pub fn tidied(team: &ReadyTeam) -> ReadyTeam {
    ReadyTeam {
        id: team.id.clone(),
        name: one_line(&team.name, LONGEST_CATEGORY_NAME),
        purpose: one_line(&team.purpose, LONGEST_DOES),
        manager: tidy_member(&team.manager),
        workers: team.workers.iter().map(tidy_member).filter(|m| !m.name.is_empty() || !m.does.is_empty() || !m.instructions.is_empty()).collect(),
    }
}

/// What's wrong with a team before it can be saved or added, in a sentence; None when it's fine.
pub fn problem(team: &ReadyTeam) -> Option<String> {
    let team = tidied(team);
    if team.name.is_empty() { return Some("Give the team a name.".into()); }
    if team.manager.name.is_empty() { return Some("Give the manager a name.".into()); }
    if let Some(n) = team.workers.iter().position(|w| w.name.is_empty()) { return Some(format!("Bot {} needs a name.", n + 1)); }
    if team.workers.len() > MOST_WORKERS { return Some(format!("A team can have at most {MOST_WORKERS} bots under its manager.")); }
    let mut seen: Vec<&str> = vec![];
    for member in team.members() {
        if seen.iter().any(|s| same_name(s, &member.name)) { return Some(format!("Two bots are called {}. Give each its own name.", member.name)); }
        seen.push(&member.name);
    }
    for member in team.members() {
        if RESERVED_NAMES.iter().any(|r| same_name(r, &member.name)) { return Some(format!("{} is a name Vello keeps for itself. Pick another.", member.name)); }
    }
    None
}

// MARK: - Adding a team

/// `name`, or `name 2`, `name 3`, … when one is taken (names match without regard to case). A name that already ends in a
/// number counts on from it: "Research Desk 2" taken gives "Research Desk 3", not "Research Desk 2 2".
pub fn unique_name(name: &str, taken: &[String], longest: usize) -> String {
    let is_taken = |candidate: &str| taken.iter().any(|t| same_name(t, candidate));
    if !is_taken(name) { return name.to_string(); }
    let (base, mut number) = match name.rsplit_once(' ') {
        Some((stem, tail)) if !stem.trim().is_empty() && !tail.is_empty() && tail.len() <= 3 && tail.chars().all(|c| c.is_ascii_digit()) => {
            (stem.trim().to_string(), tail.parse::<usize>().unwrap_or(1) + 1)
        }
        _ => (name.to_string(), 2),
    };
    loop {
        let suffix = format!(" {number}");
        let room = longest.saturating_sub(suffix.chars().count()).max(1);
        let candidate = format!("{}{suffix}", base.chars().take(room).collect::<String>().trim());
        if !is_taken(&candidate) { return candidate; }
        number += 1;
    }
}

/// `instructions` with each old name swapped for its new one, as a whole name only ("Web Scout" but not "Web Scouting" or a
/// "Web Scout 2" that's already numbered). Longest names first.
pub fn renamed(instructions: &str, renames: &[(String, String)]) -> String {
    if instructions.is_empty() { return String::new(); }
    let mut sorted: Vec<&(String, String)> = renames.iter().filter(|(old, _)| !old.is_empty()).collect();
    sorted.sort_by(|a, b| b.0.chars().count().cmp(&a.0.chars().count()));
    let mut result = instructions.to_string();
    for (old, new) in sorted {
        // The regex crate has no look-around: match the name with what follows it and keep that.
        let Ok(re) = Regex::new(&format!(r"(^|[^\p{{L}}\p{{N}}])({})($|[^\p{{L}}\p{{N}}])", regex::escape(old))) else { continue };
        let mut out = String::new();
        let mut last = 0;
        let mut at = 0;
        while let Some(found) = re.captures_at(&result, at) {
            let name = found.get(2).unwrap();
            let after = &result[name.end()..];
            // Already numbered ("Web Scout 2"): left alone.
            let numbered = after.starts_with(|c: char| c.is_whitespace()) && after.chars().nth(1).map(|c| c.is_ascii_digit()).unwrap_or(false);
            if !numbered {
                out.push_str(&result[last..name.start()]);
                out.push_str(new);
                last = name.end();
            }
            at = name.end();
            if at >= result.len() { break; }
        }
        out.push_str(&result[last..]);
        result = out;
    }
    result
}

/// The ```team order that makes `team` as a new category with its manager and bots. A name that's taken gets a number
/// ("Research Desk 2", "Web Scout 2"), in every bot's instructions too, so adding a team never moves or changes a bot the
/// owner has, and adding the same team twice makes a second copy.
pub fn order_for(team: &ReadyTeam, existing_bot_names: &[String], existing_category_names: &[String]) -> TeamBuildOrder {
    let team = tidied(team);
    let category = unique_name(&team.name, existing_category_names, LONGEST_CATEGORY_NAME);
    let mut taken: Vec<String> = existing_bot_names.to_vec();
    taken.extend(RESERVED_NAMES.iter().map(|r| r.to_string()));
    let mut names: Vec<String> = vec![];
    for member in team.members() {
        let name = unique_name(&member.name, &taken, LONGEST_BOT_NAME);
        taken.push(name.clone());
        names.push(name);
    }
    let mut renames: Vec<(String, String)> = team.members().iter().zip(&names).filter(|(m, n)| &m.name != *n).map(|(m, n)| (m.name.clone(), n.clone())).collect();
    if category != team.name { renames.push((team.name.clone(), category.clone())); }
    let bots = team.members().iter().zip(&names).map(|(member, name)| NewBot {
        name: name.clone(),
        does: member.does.clone(),
        instructions: renamed(&member.instructions, &renames),
        category: Some(category.clone()),
        model: member.model.clone(),
        brain: member.brain.clone(),
    }).collect();
    TeamBuildOrder {
        categories: vec![NewCategory { name: category, purpose: Some(team.purpose.clone()).filter(|p| !p.is_empty()), manager: names.first().cloned() }],
        bots,
        ready_made_teams: vec![],
    }
}

/// A ```team block's order with the ready-made teams it named added in, named so they don't clash with what's there or with
/// each other. The second part holds the names no team in `library` has.
pub fn expanding(order: TeamBuildOrder, library: &[ReadyTeam], existing_bot_names: &[String], existing_category_names: &[String]) -> (TeamBuildOrder, Vec<String>) {
    if order.ready_made_teams.is_empty() { return (order, vec![]); }
    let mut result = order.clone();
    result.ready_made_teams.clear();
    let mut missing = vec![];
    let mut bot_names: Vec<String> = existing_bot_names.to_vec();
    bot_names.extend(order.bots.iter().map(|b| b.name.clone()));
    let mut category_names: Vec<String> = existing_category_names.to_vec();
    category_names.extend(order.categories.iter().map(|c| c.name.clone()));
    for wanted in &order.ready_made_teams {
        let Some(team) = find(wanted, library) else { missing.push(wanted.clone()); continue };
        let made = order_for(&team, &bot_names, &category_names);
        bot_names.extend(made.bots.iter().map(|b| b.name.clone()));
        category_names.extend(made.categories.iter().map(|c| c.name.clone()));
        result.categories.extend(made.categories);
        result.bots.extend(made.bots);
    }
    (result, missing)
}

/// The team a name or id asks for: its name, its id, or its name without a leading "the" or a trailing "team".
pub fn find(asked: &str, library: &[ReadyTeam]) -> Option<ReadyTeam> {
    fn plain(text: &str) -> String {
        let lower = text.to_lowercase();
        let mut words: Vec<&str> = lower.split(|c: char| !c.is_alphanumeric()).filter(|w| !w.is_empty()).collect();
        if words.first() == Some(&"the") { words.remove(0); }
        if words.len() > 1 && words.last() == Some(&"team") { words.pop(); }
        words.join(" ")
    }
    if let Some(exact) = library.iter().find(|t| same_name(&t.name, asked) || t.id == asked) { return Some(exact.clone()); }
    let wanted = plain(asked);
    if wanted.is_empty() { return None; }
    library.iter().find(|t| plain(&t.name) == wanted).cloned()
}

// MARK: - From a category, and files

/// A team made from a category, led by its manager (or, with none, its first bot). None when it has no bots.
pub fn from_category(name: &str, purpose: Option<&str>, manager: Option<Member>, members: Vec<Member>, id: &str) -> Option<ReadyTeam> {
    let mut others = members;
    let lead = match manager {
        Some(manager) => { others.retain(|m| !same_name(&m.name, &manager.name)); manager }
        None => { if others.is_empty() { return None; } others.remove(0) }
    };
    others.truncate(MOST_WORKERS);
    Some(tidied(&ReadyTeam { id: id.to_string(), name: name.to_string(), purpose: purpose.unwrap_or_default().to_string(), manager: lead, workers: others }))
}

/// A team file, to keep or send to someone: {"kind": "vello-bot-teams", "version": 1, "teams": [...]}.
pub fn file_text(teams: &[ReadyTeam]) -> String {
    serde_json::to_string_pretty(&TeamsFile { kind: Some(FILE_KIND.into()), version: Some(1), teams: teams.to_vec() }).unwrap_or_default()
}

/// The teams in a file: a team file, one team on its own, or a ```team block's JSON (each category with its bots becomes a
/// team). Each comes back tidied; teams with no usable manager are left out.
pub fn teams_from_file(text: &str) -> Vec<ReadyTeam> {
    let found: Vec<ReadyTeam> = if let Ok(file) = serde_json::from_str::<TeamsFile>(text) {
        file.teams
    } else if let Ok(one) = serde_json::from_str::<ReadyTeam>(text) {
        vec![one]
    } else if let Some(order) = team_build::parse(text) {
        order.categories.iter().filter_map(|category| {
            let members: Vec<Member> = order.bots.iter().filter(|b| b.category.as_deref().map(|c| same_name(c, &category.name)).unwrap_or(false))
                .map(|b| Member { name: b.name.clone(), does: b.does.clone(), instructions: b.instructions.clone(), model: b.model.clone(), brain: b.brain.clone() })
                .collect();
            let manager = if category.wants_no_manager() { None } else {
                category.manager.as_deref().and_then(|name| members.iter().find(|m| same_name(&m.name, name)).cloned())
            };
            from_category(&category.name, category.purpose.as_deref(), manager, members, "")
        }).collect()
    } else {
        vec![]
    };
    found.iter().map(tidied).filter(|t| !t.name.is_empty() && !t.manager.name.is_empty()).collect()
}

/// What the CEO is told about the ready-made teams (ClickyCore `BotProtocol.readyMadeTeamsHowTo`). Empty when there are none.
pub fn how_to(owner: &str, names: &[String]) -> String {
    let Some(first) = names.first() else { return String::new() };
    format!(
        " Ready-made teams, each a category with a manager and its bots, all written already: {}. When {owner} asks for one of them (or for a team that one of them fits and they agree), put its name in the block's \"teams\" list, as {{\"teams\": [\"{first}\"]}}, rather than writing its bots out; it can go with the other lists. Adding one again makes a second copy with numbered names. These teams can be changed, and new ones made, in Settings › Bot teams.",
        listed_in_words(names)
    )
}

// MARK: - Saved on this computer

pub fn library_file(bots_dir: &Path) -> PathBuf { bots_dir.join("ready-made-teams.json") }

pub fn load(bots_dir: &Path) -> Saved {
    std::fs::read(library_file(bots_dir)).ok().and_then(|data| serde_json::from_slice(&data).ok()).unwrap_or_default()
}

pub fn store(bots_dir: &Path, saved: &Saved) -> std::io::Result<()> {
    std::fs::create_dir_all(bots_dir)?;
    std::fs::write(library_file(bots_dir), serde_json::to_vec_pretty(saved).unwrap_or_default())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn research() -> ReadyTeam { built_in().iter().find(|t| t.id == "research").unwrap().clone() }

    #[test]
    fn the_catalog_is_the_file_the_mac_has() {
        // A Windows checkout may turn line ends into CRLF, in either file.
        let mac = include_str!("../../../../Packages/ClickyCore/Sources/ClickyCore/Team/ReadyMadeTeamsCatalog.swift").replace("\r\n", "\n");
        let start = mac.find("#\"\"\"\n").unwrap() + 5;
        let end = mac.rfind("\n\"\"\"#").unwrap();
        assert_eq!(mac[start..end].trim(), CATALOG_JSON.replace("\r\n", "\n").trim());
    }

    #[test]
    fn every_built_in_team_has_a_manager_and_bots_with_their_own_names() {
        assert!(built_in().len() >= 8);
        let mut all: Vec<String> = vec![];
        for team in built_in() {
            assert_eq!(problem(team), None, "{}", team.name);
            assert!(!team.workers.is_empty());
            assert_eq!(&tidied(team), team, "{} is longer than a team block keeps", team.name);
            for member in team.members() {
                assert!(member.instructions.starts_with(&format!("You are {}", member.name)), "{}", member.name);
                assert!(!member.instructions.contains("Addy"));
                all.push(member.name.to_lowercase());
            }
        }
        let mut unique = all.clone();
        unique.sort();
        unique.dedup();
        assert_eq!(unique.len(), all.len());
        assert!(built_in().iter().any(|t| t.name == "Super Digger Squad" && t.manager.name == "Digger Boss"));
    }

    #[test]
    fn adding_a_team_makes_its_category_with_its_manager_first() {
        let order = order_for(&research(), &["Vello".into()], &[]);
        assert_eq!(order.categories, vec![NewCategory { name: "Research Desk".into(), purpose: Some(research().purpose), manager: Some("Research Lead".into()) }]);
        assert_eq!(order.bots.iter().map(|b| b.name.as_str()).collect::<Vec<_>>(), ["Research Lead", "Web Scout", "Fact Checker", "Brief Writer"]);
        assert!(order.bots.iter().all(|b| b.category.as_deref() == Some("Research Desk")));
    }

    #[test]
    fn adding_a_team_again_numbers_its_names_in_every_instruction() {
        let order = order_for(&research(), &["research lead".into(), "Web Scout".into(), "Web Scout 2".into()], &["Research Desk".into()]);
        assert_eq!(order.categories[0].name, "Research Desk 2");
        assert_eq!(order.categories[0].manager.as_deref(), Some("Research Lead 2"));
        assert_eq!(order.bots.iter().map(|b| b.name.as_str()).collect::<Vec<_>>(), ["Research Lead 2", "Web Scout 3", "Fact Checker", "Brief Writer"]);
        assert!(order.bots[1].instructions.starts_with("You are Web Scout 3 on the Research Desk 2."));
        assert!(order.bots[0].instructions.contains("Web Scout 3 finds sources"));
        assert!(order.bots[0].instructions.starts_with("You are Research Lead 2, the manager of the Research Desk 2."));
    }

    #[test]
    fn renaming_leaves_longer_words_and_numbered_names_alone() {
        let renames = vec![("Scout".to_string(), "Scout 2".to_string())];
        assert_eq!(renamed("Scout, Scouting and Scout 3. Ask Scout", &renames), "Scout 2, Scouting and Scout 3. Ask Scout 2");
    }

    #[test]
    fn a_numbered_name_counts_on() {
        assert_eq!(unique_name("Research Desk 2", &["Research Desk 2".into()], 80), "Research Desk 3");
        assert_eq!(unique_name("Desk 2024", &["Desk 2024".into()], 80), "Desk 2024 2");
    }

    #[test]
    fn a_numbered_name_stays_under_the_limit() {
        let long = "x".repeat(40);
        let name = unique_name(&long, &[long.clone()], 40);
        assert_eq!(name.chars().count(), 40);
        assert!(name.ends_with(" 2"));
    }

    #[test]
    fn the_library_keeps_the_owners_changes_and_own_teams() {
        let mut saved = Saved::default();
        let mut mine = research();
        mine.name = "My Research".into();
        mine.workers.pop();
        saved = saving(&mine, &saved);
        let own = ReadyTeam { id: new_id("Garden Club", &library(&saved)), name: "Garden Club".into(), purpose: "Plants".into(),
                              manager: Member { name: "Head Gardener".into(), ..Default::default() }, workers: vec![Member { name: "Weeder".into(), ..Default::default() }] };
        assert_eq!(own.id, "own-garden-club");
        saved = saving(&own, &saved);
        saved = removing("money", &saved);
        let lib = library(&saved);
        assert_eq!(lib[0].name, "My Research");
        assert!(is_changed(&lib[0]));
        assert!(!lib.iter().any(|t| t.id == "money"));
        assert_eq!(lib.last(), Some(&own));
        saved = resetting("research", &saved);
        saved = resetting("money", &saved);
        assert_eq!(library(&saved)[0], research());
        saved = removing(&own.id, &saved);
        assert_eq!(saved, Saved::default());
        assert!(saving(&research(), &Saved::default()).teams.is_empty());
    }

    #[test]
    fn problems_are_said_in_a_sentence() {
        let mut twins = research();
        twins.workers.push(Member { name: "RESEARCH LEAD".into(), ..Default::default() });
        assert!(problem(&twins).unwrap().starts_with("Two bots are called"));
        let mut vello = research();
        vello.workers.push(Member { name: "vello".into(), ..Default::default() });
        assert!(problem(&vello).unwrap().contains("keeps for itself"));
        let mut crowd = research();
        crowd.workers = (1..=20).map(|n| Member { name: format!("Worker {n}"), ..Default::default() }).collect();
        assert!(problem(&crowd).unwrap().starts_with("A team can have at most 19"));
        let mut blank_row = research();
        blank_row.workers.push(Member::default());
        assert_eq!(problem(&blank_row), None);
    }

    #[test]
    fn files_round_trip_and_read_the_macs_and_a_team_block() {
        let teams: Vec<ReadyTeam> = built_in()[..2].to_vec();
        assert_eq!(teams_from_file(&file_text(&teams)), teams);
        assert_eq!(teams_from_file(&serde_json::to_string(&research()).unwrap()), vec![research()]);
        // The Mac writes the same shape, keys sorted.
        let mac = r#"{"kind" : "vello-bot-teams", "teams" : [{"id" : "own-x", "manager" : {"does" : "Leads", "instructions" : "", "name" : "Rex"}, "name" : "X", "purpose" : "", "workers" : []}], "version" : 1}"#;
        assert_eq!(teams_from_file(mac)[0].manager.name, "Rex");
        let block = r#"{"categories": [{"name": "Sales", "manager": "Rex"}], "bots": [{"name": "Ada", "does": "Writes", "category": "Sales"}, {"name": "Rex", "does": "Leads", "category": "Sales", "model": "opus"}]}"#;
        let from_block = teams_from_file(block);
        assert_eq!(from_block[0].manager.name, "Rex");
        assert_eq!(from_block[0].manager.model.as_deref(), Some("opus"));
        assert_eq!(from_block[0].workers[0].name, "Ada");
        assert!(teams_from_file("not json").is_empty());
    }

    #[test]
    fn a_team_block_can_name_ready_made_teams_and_missing_ones_are_said() {
        let order = team_build::parse(r#"{"teams": ["Research Desk", {"name": "the sales team"}, "Moon Base", "Research Desk"], "bots": [{"name": "Web Scout", "does": "Mine"}]}"#).unwrap();
        assert_eq!(order.ready_made_teams, ["Research Desk", "the sales team", "Moon Base"]);
        let (expanded, missing) = expanding(order, &library(&Saved::default()), &["Vello".into()], &[]);
        assert_eq!(missing, ["Moon Base"]);
        assert_eq!(expanded.categories.iter().map(|c| c.name.as_str()).collect::<Vec<_>>(), ["Research Desk", "Sales Team"]);
        assert_eq!(expanded.bots.iter().take(3).map(|b| b.name.as_str()).collect::<Vec<_>>(), ["Web Scout", "Research Lead", "Web Scout 2"]);
        assert!(team_build::owner_asked("add the Super Digger Squad"));
        assert!(team_build::owner_asked("set up the money desk please"));
    }

    #[test]
    fn the_ceo_is_told_the_teams_by_name() {
        let text = how_to("the owner", &["Research Desk".into(), "Sales Team".into()]);
        assert!(text.contains("Research Desk and Sales Team"));
        assert!(text.contains(r#"{"teams": ["Research Desk"]}"#));
        assert_eq!(how_to("the owner", &[]), "");
    }

    #[test]
    fn a_category_without_a_manager_is_led_by_its_first_bot() {
        let team = from_category("Ops", None, None, vec![Member { name: "Ivy".into(), ..Default::default() }, Member { name: "Max".into(), ..Default::default() }], "own-ops").unwrap();
        assert_eq!(team.manager.name, "Ivy");
        assert_eq!(team.workers[0].name, "Max");
        assert!(from_category("Empty", None, None, vec![], "own-empty").is_none());
    }
}
