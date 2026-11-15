//! Teams: categories of bots, each with a manager or not. Ported from the Swift app's `BotsLayout.Section` and the team parts of
//! `BotsStore` (`assignManagerIfNeeded`, `setLeader`, `setHasManager`, `reachable`) and ClickyCore's `BotProtocol.reportingLine`.
//!
//! A category has a manager unless the owner switched it off (`wants_manager == Some(false)`): the first member who isn't the CEO
//! gets the job, on load and whenever the category changes. With one, each member's report goes to the manager's chat and the
//! manager rolls them up into the CEO's chat; without one, every member reports to the CEO directly. Saved as the Mac saves it
//! (`layout.json`, items "bot:<id>", `leaderID`), so the words and the rules are the same on every platform.

use crate::model::Bot;
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use std::collections::HashSet;

fn new_id() -> String { uuid::Uuid::new_v4().to_string().to_uppercase() }

/// What the sidebar shows where. Only the categories are used on this build.
#[derive(Clone, Debug, Default, Serialize, Deserialize, PartialEq)]
pub struct Layout {
    #[serde(default)]
    pub sections: Vec<Section>,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Section {
    #[serde(default = "new_id")]
    pub id: String,
    pub name: String,
    /// "bot:<id>" for each bot in it, in order.
    #[serde(default)]
    pub items: Vec<String>,
    #[serde(default, skip_serializing_if = "Option::is_none", rename = "parentID")]
    pub parent_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub collapsed: Option<bool>,
    /// The category's manager: members send it their reports, it rolls them up for the CEO. None: everyone reports to the CEO.
    #[serde(default, skip_serializing_if = "Option::is_none", rename = "leaderID")]
    pub leader_id: Option<String>,
    /// "Has a manager": true when switched on (even before a bot was picked), false when the owner switched it off. None (never
    /// chosen) means it gets a manager as soon as it has a bot to give the job to.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub wants_manager: Option<bool>,
    /// What this team is for, in a line.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub purpose: Option<String>,
    /// The last reports this team sent the CEO, newest last (10 at most).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reports: Option<Vec<Report>>,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct Report {
    #[serde(default = "new_id")]
    pub id: String,
    #[serde(default = "Utc::now")]
    pub at: DateTime<Utc>,
    pub author: String,
    pub text: String,
}

pub const REPORTS_KEPT: usize = 10;

pub fn item_for_bot(bot_id: &str) -> String { format!("bot:{bot_id}") }
pub fn bot_of_item(item: &str) -> Option<&str> { item.strip_prefix("bot:") }

impl Section {
    pub fn new(name: &str) -> Self {
        Section { id: new_id(), name: name.trim().to_string(), items: vec![], parent_id: None, collapsed: None, leader_id: None, wants_manager: None, purpose: None, reports: None }
    }

    pub fn has_manager(&self) -> bool { self.leader_id.is_some() || self.wants_manager == Some(true) }

    /// The bots filed here that still exist, in order.
    pub fn member_ids(&self, bots: &[Bot]) -> Vec<String> {
        self.items.iter().filter_map(|i| bot_of_item(i)).filter(|id| bots.iter().any(|b| b.id == *id)).map(str::to_string).collect()
    }

    pub fn contains(&self, bot_id: &str) -> bool { self.items.iter().any(|i| bot_of_item(i) == Some(bot_id)) }

    /// Every team has a manager unless the owner said it shouldn't: a category that never chose (or switched it on without
    /// picking) gets its first member who isn't the CEO, until the owner picks another. A category with no bots waits for one.
    pub fn assign_manager_if_needed(&mut self, bots: &[Bot]) {
        if let Some(leader) = &self.leader_id {
            if bots.iter().any(|b| &b.id == leader) { return; }
        }
        self.leader_id = None;
        if self.wants_manager == Some(false) { return; }
        let candidates: Vec<&Bot> = self.member_ids(bots).iter().filter_map(|id| bots.iter().find(|b| &b.id == id)).collect();
        if let Some(manager) = candidates.iter().find(|b| !b.primary) {
            self.leader_id = Some(manager.id.clone());
            self.wants_manager = Some(true);
        }
    }

    /// After any change: a leader always sits in its own team, a gone one is dropped, and the team gets a manager if it wants one.
    pub fn settle(&mut self, bots: &[Bot]) {
        let mut seen = HashSet::new();
        self.items.retain(|i| seen.insert(i.clone()));
        if let Some(leader) = self.leader_id.clone() {
            if !bots.iter().any(|b| b.id == leader) {
                self.leader_id = None;
            } else if !self.contains(&leader) {
                self.items.push(item_for_bot(&leader));
            }
        }
        self.assign_manager_if_needed(bots);
    }

    pub fn set_leader(&mut self, bot_id: Option<String>, bots: &[Bot]) {
        // Picking "No manager" is a choice, so the team isn't handed a new one straight away.
        self.wants_manager = Some(bot_id.is_some());
        self.leader_id = bot_id;
        self.settle(bots);
    }

    /// The "Has a manager" switch. On, the first non-CEO member takes the job until another is picked; off, everyone reports to
    /// the CEO directly.
    pub fn set_has_manager(&mut self, on: bool, bots: &[Bot]) {
        if !on {
            self.leader_id = None;
            self.wants_manager = Some(false);
        } else {
            self.wants_manager = Some(true);
            if self.leader_id.is_none() {
                self.leader_id = self.member_ids(bots).into_iter().find(|id| bots.iter().any(|b| &b.id == id && !b.primary));
            }
        }
        self.settle(bots);
    }

    pub fn add_member(&mut self, bot_id: &str, bots: &[Bot]) {
        if !self.contains(bot_id) { self.items.push(item_for_bot(bot_id)); }
        self.settle(bots);
    }

    pub fn remove_member(&mut self, bot_id: &str, bots: &[Bot]) {
        self.items.retain(|i| bot_of_item(i) != Some(bot_id));
        if self.leader_id.as_deref() == Some(bot_id) { self.leader_id = None; }
        self.settle(bots);
    }

    pub fn add_report(&mut self, author: &str, text: &str) {
        let mut reports = self.reports.take().unwrap_or_default();
        reports.push(Report { id: new_id(), at: Utc::now(), author: author.into(), text: text.into() });
        let extra = reports.len().saturating_sub(REPORTS_KEPT);
        reports.drain(..extra);
        self.reports = Some(reports);
    }
}

impl Layout {
    pub fn section(&self, id: &str) -> Option<&Section> { self.sections.iter().find(|s| s.id == id) }
    pub fn section_mut(&mut self, id: &str) -> Option<&mut Section> { self.sections.iter_mut().find(|s| s.id == id) }
    pub fn categories_of(&self, bot_id: &str) -> Vec<&Section> { self.sections.iter().filter(|s| s.contains(bot_id)).collect() }
    pub fn is_manager(&self, bot_id: &str) -> bool { self.sections.iter().any(|s| s.leader_id.as_deref() == Some(bot_id)) }

    /// "New category", then "New category 2", … as the Mac names a new one.
    pub fn next_name(&self) -> String {
        let count = self.sections.len();
        if count == 0 { "New category".into() } else { format!("New category {}", count + 1) }
    }

    pub fn add(&mut self, name: &str) -> Option<String> {
        let trimmed = name.trim();
        if trimmed.is_empty() { return None; }
        let section = Section::new(trimmed);
        let id = section.id.clone();
        self.sections.push(section);
        Some(id)
    }

    /// A bot filed in exactly this category (None: in none), as the sidebar's "Move to category" does.
    pub fn move_bot(&mut self, bot_id: &str, to: Option<&str>, bots: &[Bot]) {
        for s in self.sections.iter_mut() {
            if Some(s.id.as_str()) != to && s.contains(bot_id) { s.remove_member(bot_id, bots); }
        }
        if let Some(s) = to.and_then(|id| self.section_mut(id)) { s.add_member(bot_id, bots); }
    }

    /// A bot that's gone leaves every category.
    pub fn forget_bot(&mut self, bot_id: &str, bots: &[Bot]) {
        for s in self.sections.iter_mut() {
            s.items.retain(|i| bot_of_item(i) != Some(bot_id));
            if s.leader_id.as_deref() == Some(bot_id) { s.leader_id = None; }
            s.settle(bots);
        }
    }

    pub fn settle(&mut self, bots: &[Bot]) {
        for s in self.sections.iter_mut() { s.settle(bots); }
    }

    /// Who a bot may message because of its teams, when the owner has picked whom it may reach: a manager its team and the CEO,
    /// a member its manager, and a member of a team with no manager its teammates and the CEO.
    pub fn reach(&self, bot_id: &str, bots: &[Bot], ceo: Option<&str>) -> HashSet<String> {
        let mut allowed = HashSet::new();
        for team in self.categories_of(bot_id) {
            let members = team.member_ids(bots);
            match team.leader_id.as_deref() {
                Some(leader) if leader == bot_id => {
                    allowed.extend(members);
                    allowed.extend(ceo.map(str::to_string));
                }
                Some(leader) => { allowed.insert(leader.to_string()); }
                None => {
                    allowed.extend(members);
                    allowed.extend(ceo.map(str::to_string));
                }
            }
        }
        allowed.remove(bot_id);
        allowed
    }
}

/// One team a bot is on, for its reporting lines.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct TeamFacts {
    pub name: String,
    pub purpose: Option<String>,
    pub mates: Vec<String>,
    pub is_manager: bool,
    pub manager_name: Option<String>,
}

/// Who a bot reports to. Reports and messages go by [TELL:]; @Name is only for handing over inside a group chat.
pub fn reporting_line(team: &TeamFacts, ceo_name: &str) -> String {
    let mut line = format!("Your team: {}{}{}. ", team.name, team.purpose.as_ref().map(|p| format!(" ({p})")).unwrap_or_default(),
        if team.mates.is_empty() { String::new() } else { format!(", with {}", team.mates.join(", ")) });
    if team.is_manager {
        line.push_str(&format!("You are its manager: they send you their reports and messages. Give them work with a [TELL:] line, roll their reports up, and report to {ceo_name}, the CEO."));
    } else if let Some(manager) = &team.manager_name {
        line.push_str(&format!("{manager} is your manager: send your reports and messages to {manager} with a [TELL:] line, not to {ceo_name}. {manager} passes on what matters."));
    } else {
        line.push_str(&format!("It has no manager, so you report straight to {ceo_name}, the CEO, with a [TELL:] line when something is worth knowing."));
    }
    line
}

/// Who a bot reports to, in its instructions. The CEO also gets the whole picture of its teams.
pub fn reporting_lines(bot: &Bot, layout: &Layout, bots: &[Bot]) -> Vec<String> {
    let ceo = bots.iter().find(|b| b.primary).map(|b| b.name.clone()).unwrap_or_else(|| "the CEO".into());
    let name_of = |id: &str| bots.iter().find(|b| b.id == id).map(|b| b.name.clone());
    let mut lines: Vec<String> = layout.categories_of(&bot.id).iter().map(|team| {
        let mates: Vec<String> = team.member_ids(bots).iter().filter(|id| **id != bot.id).filter_map(|id| name_of(id)).collect();
        let is_manager = team.leader_id.as_deref() == Some(bot.id.as_str());
        let manager_name = if is_manager { None } else { team.leader_id.as_deref().and_then(name_of) };
        reporting_line(&TeamFacts { name: team.name.clone(), purpose: team.purpose.clone(), mates, is_manager, manager_name }, &ceo)
    }).collect();
    if bot.primary {
        let teams: Vec<String> = layout.sections.iter().filter(|s| s.parent_id.is_none()).filter_map(|team| {
            let members: Vec<String> = team.member_ids(bots).iter().filter(|id| **id != bot.id && Some(id.as_str()) != team.leader_id.as_deref()).filter_map(|id| name_of(id)).collect();
            if team.member_ids(bots).is_empty() { return None; }
            let members = members.join(", ");
            Some(match team.leader_id.as_deref().and_then(name_of) {
                Some(manager) => format!("{}: {manager} manages {members} and reports to you", team.name),
                None => format!("{}: no manager, {members} report to you directly", team.name),
            })
        }).collect();
        if !teams.is_empty() {
            lines.push(format!("Your teams: {}. To reach a managed team, go through its manager.", teams.join("; ")));
        }
    }
    lines
}

/// A bot's place on the team, in a few words, for whoever it's messaging.
pub fn role_line(bot: &Bot, layout: &Layout) -> Option<String> {
    if bot.primary { return Some("the CEO".into()); }
    if let Some(team) = layout.categories_of(&bot.id).first() {
        return Some(if team.leader_id.as_deref() == Some(bot.id.as_str()) { format!("manager of {}", team.name) } else { format!("on {}", team.name) });
    }
    if bot.description.is_empty() { None } else { Some(bot.description.chars().take(70).collect()) }
}

/// What a reporter reads: its role, the team's job, who to write for, and what it did lately.
pub fn report_prompt(role: &str, purpose: Option<&str>, reader: &str, owner: &str, activity: &str) -> String {
    format!("{role}{}. Write {reader} a short report: what got done, what's in progress, anything blocked or needing {owner}. Plain sentences or a few bullets, no preamble.\n\nRecent activity:\n\n{activity}",
        purpose.map(|p| format!(", whose job is: {p}")).unwrap_or_default())
}

/// The note at the top of the CEO's turn with what came in since it last spoke. Empty when nothing did.
pub fn waiting_reports_note(lines: &[String], owner: &str) -> String {
    if lines.is_empty() { return String::new(); }
    format!("(What came in since you last spoke, reports from your teams and any voice call with {owner}:\n\n{}\n\nUse it if it matters; don't recite it.)\n\n", lines.join("\n\n"))
}

pub const REPORT_MARK: &str = "\u{1F4CB}";

/// The schedules a team can report on, as the Mac's team page offers them.
pub fn report_schedule(choice: &str) -> Option<crate::model::Schedule> {
    use crate::model::{Schedule, ScheduleKind};
    let at = |kind, hour, weekday| Schedule { kind, hour, minute: 0, weekday, interval_minutes: 60 };
    match choice {
        "daily" => Some(at(ScheduleKind::Daily, 18, 2)),
        "weekdays" => Some(at(ScheduleKind::Weekdays, 18, 2)),
        "weekly" => Some(at(ScheduleKind::Weekly, 17, 6)),
        "every" => Some(Schedule { kind: ScheduleKind::Every, hour: 9, minute: 0, weekday: 2, interval_minutes: 120 }),
        _ => None,
    }
}

pub fn report_target(section_id: &str) -> String { format!("report:{section_id}") }

#[cfg(test)]
mod tests {
    use super::*;

    fn bots() -> Vec<Bot> {
        let mut theo = Bot::theo();
        theo.primary = true;
        let mut out = vec![theo];
        for name in ["Ana", "Ben", "Cy"] {
            let mut b = Bot::new(name, &format!("{name} does things"), "", "claude", "m");
            b.id = name.to_lowercase();
            out.push(b);
        }
        out
    }

    #[test]
    fn a_new_team_gets_its_first_member_who_isnt_the_ceo_as_manager() {
        let bots = bots();
        let mut s = Section::new("Ops");
        s.add_member("theo", &bots);
        assert_eq!(s.leader_id, None, "the CEO never manages a team");
        s.add_member("ben", &bots);
        s.add_member("ana", &bots);
        assert_eq!(s.leader_id.as_deref(), Some("ben"));
        assert!(s.has_manager());
    }

    #[test]
    fn no_manager_is_a_choice_that_sticks() {
        let bots = bots();
        let mut s = Section::new("Ops");
        s.add_member("ana", &bots);
        s.set_leader(None, &bots);
        s.add_member("ben", &bots);
        assert_eq!(s.leader_id, None);
        assert!(!s.has_manager());
        s.set_has_manager(true, &bots);
        assert_eq!(s.leader_id.as_deref(), Some("ana"));
        s.set_has_manager(false, &bots);
        assert_eq!(s.leader_id, None);
        assert_eq!(s.wants_manager, Some(false));
    }

    #[test]
    fn a_manager_removed_or_deleted_is_replaced_and_a_picked_one_joins_the_team() {
        let mut bots = bots();
        let mut s = Section::new("Ops");
        s.add_member("ana", &bots);
        s.add_member("ben", &bots);
        s.remove_member("ana", &bots);
        assert_eq!(s.leader_id.as_deref(), Some("ben"));
        s.set_leader(Some("cy".into()), &bots);
        assert!(s.contains("cy"));
        bots.retain(|b| b.id != "cy");
        let mut layout = Layout { sections: vec![s] };
        layout.forget_bot("cy", &bots);
        assert_eq!(layout.sections[0].leader_id.as_deref(), Some("ben"));
    }

    #[test]
    fn reporting_lines_say_who_reports_to_whom() {
        let bots = bots();
        let mut s = Section::new("Ops");
        s.purpose = Some("Inbox and calendar".into());
        s.add_member("ana", &bots);
        s.add_member("ben", &bots);
        let layout = Layout { sections: vec![s] };
        let ana = bots.iter().find(|b| b.id == "ana").unwrap();
        let ben = bots.iter().find(|b| b.id == "ben").unwrap();
        let theo = bots.iter().find(|b| b.id == "theo").unwrap();
        let manager = reporting_lines(ana, &layout, &bots).join(" ");
        assert!(manager.contains("You are its manager") && manager.contains("report to Vello, the CEO"), "{manager}");
        let member = reporting_lines(ben, &layout, &bots).join(" ");
        assert!(member.contains("Ana is your manager") && member.contains("(Inbox and calendar)"), "{member}");
        let ceo = reporting_lines(theo, &layout, &bots).join(" ");
        assert!(ceo.contains("Ops: Ana manages Ben and reports to you"), "{ceo}");
        assert_eq!(role_line(ana, &layout).as_deref(), Some("manager of Ops"));
        assert_eq!(role_line(ben, &layout).as_deref(), Some("on Ops"));
    }

    #[test]
    fn reach_follows_the_team() {
        let bots = bots();
        let mut managed = Section::new("Ops");
        managed.add_member("ana", &bots);
        managed.add_member("ben", &bots);
        let mut flat = Section::new("Flat");
        flat.set_has_manager(false, &bots);
        flat.add_member("cy", &bots);
        flat.add_member("ben", &bots);
        let layout = Layout { sections: vec![managed, flat] };
        let ana: HashSet<String> = ["ben", "theo"].iter().map(|s| s.to_string()).collect();
        assert_eq!(layout.reach("ana", &bots, Some("theo")), ana);
        let ben: HashSet<String> = ["ana", "cy", "theo"].iter().map(|s| s.to_string()).collect();
        assert_eq!(layout.reach("ben", &bots, Some("theo")), ben);
    }

    #[test]
    fn saved_like_the_mac() {
        let bots = bots();
        let mut s = Section::new("Ops");
        s.add_member("ana", &bots);
        let text = serde_json::to_string(&Layout { sections: vec![s] }).unwrap();
        assert!(text.contains("\"leaderID\":\"ana\"") && text.contains("\"items\":[\"bot:ana\"]") && text.contains("\"wantsManager\":true"), "{text}");
        let back: Layout = serde_json::from_str(&text).unwrap();
        assert_eq!(back.sections[0].leader_id.as_deref(), Some("ana"));
    }

    #[test]
    fn reports_keep_the_last_ten() {
        let mut s = Section::new("Ops");
        for i in 0..12 { s.add_report("ana", &format!("r{i}")); }
        let r = s.reports.unwrap();
        assert_eq!(r.len(), 10);
        assert_eq!(r.last().unwrap().text, "r11");
    }
}
