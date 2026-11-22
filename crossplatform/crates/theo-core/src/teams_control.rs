//! Control commands for teams (categories), a bot's whole settings and who's the CEO. Reached from `control::handle` for any
//! command it doesn't know itself, so the window and the test suites use the same ones.
//!
//! - `teams`: every category with its members, manager, purpose, report schedule and last reports.
//! - `teamAdd {name?, members?}`: a new category ("New category", "New category 2", … when no name is given).
//! - `teamUpdate {id, name?, purpose?, collapsed?, hasManager?, leader?}`: `leader` null or "" means "No manager".
//! - `teamDelete {id}`: the category goes; its bots move to "Other bots".
//! - `teamMember {id, bot, action: add|remove}`, `teamMove {bot, team}`: `team` null files the bot nowhere.
//! - `teamReport {id}`: everyone on the team reports now (through the manager when there is one).
//! - `teamReportSchedule {id, schedule: off|daily|weekdays|weekly|every}`.
//! - `botGet {id}`: everything the bot settings page shows. `botMakePrimary {id}`: that bot becomes the CEO.
//! - Ready-made teams (Settings › Bot teams, `ready_teams.rs`): `readyTeams` lists them; `readyTeamAdd {id}` makes one's category,
//!   manager and bots; `readyTeamSave {team}` keeps an edited or new one; `readyTeamBlank`, `readyTeamDuplicate {id}`,
//!   `readyTeamRemove {id}`, `readyTeamReset {id}`, `readyTeamRestore`; `readyTeamFromCategory {id}` keeps a category as a team;
//!   `readyTeamImport {text}` reads a team file; `readyTeamExport {id?, save?: "downloads"}` gives one (or all) as a file.

use crate::control::{err, ok};
use crate::harness::Harness;
use crate::teams;
use crate::{ready_teams, team_build};
use serde_json::{json, Value};
use std::sync::Arc;

fn text(v: &Value, k: &str) -> Option<String> { v.get(k).and_then(|x| x.as_str()).map(str::to_string) }

fn is_ceo(h: &Harness, bot_id: &str) -> bool { h.bot(bot_id).map(|b| b.primary).unwrap_or(false) }

const CEO_STAYS_ON_TOP: &str = "The CEO stays on top of the sidebar and isn't filed in a category.";

/// The commands this file answers; control.rs asks before handing one over.
pub fn handles(name: &str) -> bool {
    matches!(name, "teams" | "teamAdd" | "teamUpdate" | "teamDelete" | "teamMember" | "teamMove" | "teamReport" | "teamReportSchedule" | "botGet" | "botMakePrimary")
        || name.starts_with("readyTeam")
}

/// Every ready-made team, as Settings › Bot teams draws it.
fn ready_teams_report(h: &Harness) -> Value {
    let saved = ready_teams::load(&h.paths.bots_dir());
    let teams: Vec<Value> = ready_teams::library(&saved).iter().map(|t| {
        let mut v = serde_json::to_value(t).unwrap_or_default();
        v["builtIn"] = ready_teams::is_built_in(&t.id).into();
        v["changed"] = ready_teams::is_changed(t).into();
        v
    }).collect();
    json!({"teams": teams, "hasRemoved": !saved.hidden_built_in_ids.is_empty(), "mostWorkers": ready_teams::MOST_WORKERS})
}

fn change_ready_teams(h: &Harness, change: impl FnOnce(&ready_teams::Saved) -> ready_teams::Saved) -> Result<(), String> {
    let dir = h.paths.bots_dir();
    let next = change(&ready_teams::load(&dir));
    ready_teams::store(&dir, &next).map_err(|e| format!("Vello couldn't save the teams: {e}"))
}

async fn handle_ready_team(h: &Arc<Harness>, name: &str, cmd: &Value) -> Value {
    let library = h.ready_teams();
    let wanted = || text(cmd, "id").and_then(|id| library.iter().find(|t| t.id == id).cloned());
    let done = |result: Result<(), String>, extra: Value| match result {
        Ok(()) => { let mut v = ready_teams_report(h); v["result"] = extra; ok(v) }
        Err(why) => err(&why),
    };
    match name {
        "readyTeams" => ok(ready_teams_report(h)),
        "readyTeamAdd" => {
            let Some(team) = wanted() else { return err("No such team.") };
            if let Some(problem) = ready_teams::problem(&team) { return err(&problem); }
            match team_build::add_ready_team(h, &team).await {
                Ok(note) => ok(json!({"note": note, "teams": h.teams_report()})),
                Err(why) => err(&why),
            }
        }
        "readyTeamSave" => {
            let Some(mut team) = cmd.get("team").and_then(|t| serde_json::from_value::<ready_teams::ReadyTeam>(t.clone()).ok()) else { return err("Needs a team.") };
            if let Some(problem) = ready_teams::problem(&team) { return err(&problem); }
            if team.id.is_empty() { team.id = ready_teams::new_id(&team.name, &library); }
            let team = ready_teams::tidied(&team);
            let id = team.id.clone();
            done(change_ready_teams(h, |saved| ready_teams::saving(&team, saved)), json!({"id": id}))
        }
        "readyTeamBlank" => {
            let blank = ready_teams::ReadyTeam { id: ready_teams::new_id("New team", &library), workers: vec![Default::default()], ..Default::default() };
            ok(serde_json::to_value(blank).unwrap_or_default())
        }
        "readyTeamDuplicate" => {
            let Some(mut copy) = wanted() else { return err("No such team.") };
            let names: Vec<String> = library.iter().map(|t| t.name.clone()).collect();
            copy.name = ready_teams::unique_name(&format!("{} copy", copy.name), &names, 80);
            copy.id = ready_teams::new_id(&copy.name, &library);
            let id = copy.id.clone();
            done(change_ready_teams(h, |saved| ready_teams::saving(&copy, saved)), json!({"id": id}))
        }
        "readyTeamRemove" => {
            let Some(id) = text(cmd, "id") else { return err("Needs id.") };
            done(change_ready_teams(h, |saved| ready_teams::removing(&id, saved)), Value::Null)
        }
        "readyTeamReset" => {
            let Some(id) = text(cmd, "id") else { return err("Needs id.") };
            done(change_ready_teams(h, |saved| ready_teams::resetting(&id, saved)), Value::Null)
        }
        "readyTeamRestore" => done(change_ready_teams(h, ready_teams::restoring_built_ins), Value::Null),
        "readyTeamFromCategory" => {
            let Some(section) = text(cmd, "id").and_then(|id| h.layout().section(&id).cloned()) else { return err("No such category.") };
            let bots = h.bots();
            let members: Vec<ready_teams::Member> = section.member_ids(&bots).iter().filter_map(|id| bots.iter().find(|b| &b.id == id))
                .filter(|b| !b.primary)
                .map(|b| ready_teams::Member { name: b.name.clone(), does: b.description.clone(), instructions: b.instructions.clone(),
                                               model: Some(b.model.clone()).filter(|m| !m.is_empty()), brain: None })
                .collect();
            let manager = section.leader_id.as_deref().and_then(|id| bots.iter().find(|b| b.id == id))
                .and_then(|leader| members.iter().find(|m| m.name == leader.name).cloned());
            let names: Vec<String> = library.iter().map(|t| t.name.clone()).collect();
            let team_name = ready_teams::unique_name(&section.name, &names, 80);
            let id = ready_teams::new_id(&team_name, &library);
            let Some(team) = ready_teams::from_category(&team_name, section.purpose.as_deref(), manager, members, &id) else { return err("That category has no bots to keep.") };
            let summary = json!({"id": team.id, "name": team.name, "manager": team.manager.name, "count": team.workers.len() + 1});
            done(change_ready_teams(h, |saved| ready_teams::saving(&team, saved)), summary)
        }
        "readyTeamImport" => {
            let Some(file) = text(cmd, "text") else { return err("Needs the file's text.") };
            let mut added: Vec<String> = vec![];
            let result = change_ready_teams(h, |saved| {
                let mut next = saved.clone();
                for mut team in ready_teams::teams_from_file(&file).into_iter().filter(|t| ready_teams::problem(t).is_none()) {
                    let here = ready_teams::library(&next);
                    let names: Vec<String> = here.iter().map(|t| t.name.clone()).collect();
                    team.name = ready_teams::unique_name(&team.name, &names, 80);
                    team.id = ready_teams::new_id(&team.name, &here);
                    added.push(team.name.clone());
                    next = ready_teams::saving(&team, &next);
                }
                next
            });
            if result.is_ok() && added.is_empty() { return err("That file has no team Vello can read. A team file comes from Export, here or in Vello on a Mac."); }
            done(result, json!({"added": added}))
        }
        "readyTeamExport" => {
            let teams: Vec<ready_teams::ReadyTeam> = match text(cmd, "id") {
                Some(_) => match wanted() { Some(team) => vec![team], None => return err("No such team.") },
                None => library.clone(),
            };
            let file = ready_teams::file_text(&teams);
            let file_name = format!("{}.json", if teams.len() == 1 { teams[0].name.replace(['/', '\\', ':'], " ") } else { "Vello teams".into() });
            if text(cmd, "save").as_deref() == Some("downloads") {
                let folder = crate::files::folder(h, crate::files::Place::Downloads);
                if let Err(e) = std::fs::create_dir_all(&folder) { return err(&format!("Vello couldn't reach Downloads: {e}")); }
                let free = crate::files::free_name(&file_name, |n| folder.join(n).exists());
                let path = folder.join(free);
                return match std::fs::write(&path, &file) {
                    Ok(()) => ok(json!({"text": file, "name": file_name, "saved": path.to_string_lossy()})),
                    Err(e) => err(&format!("Vello couldn't write the file: {e}")),
                };
            }
            ok(json!({"text": file, "name": file_name}))
        }
        _ => err(&format!("Unknown command {name}")),
    }
}

pub async fn handle(h: &Arc<Harness>, name: &str, cmd: &Value) -> Value {
    if name.starts_with("readyTeam") { return handle_ready_team(h, name, cmd).await; }
    match name {
        "teams" => ok(h.teams_report()),
        "teamAdd" => {
            let wanted = text(cmd, "name").map(|n| n.trim().to_string()).filter(|n| !n.is_empty()).unwrap_or_else(|| h.layout().next_name());
            if wanted.chars().count() > 80 { return err("Keep the name under 80 characters."); }
            let members: Vec<String> = cmd.get("members").and_then(|m| m.as_array()).map(|a| a.iter().filter_map(|x| x.as_str().map(str::to_string)).collect()).unwrap_or_default();
            if members.iter().any(|m| is_ceo(h, m)) { return err(CEO_STAYS_ON_TOP); }
            let id = h.change_layout(|layout, bots| {
                let id = layout.add(&wanted)?;
                for m in &members {
                    if bots.iter().any(|b| &b.id == m) { layout.move_bot(m, Some(&id), bots); }
                }
                Some(id)
            });
            match id {
                Some(id) => ok(json!({"id": id, "name": wanted})),
                None => err("Needs a name."),
            }
        }
        "teamUpdate" => {
            let Some(id) = text(cmd, "id").filter(|id| h.layout().section(id).is_some()) else { return err("No such category.") };
            if let Some(leader) = text(cmd, "leader").filter(|l| !l.is_empty()) {
                if h.bot(&leader).is_none() { return err("No such bot."); }
                if is_ceo(h, &leader) { return err("The CEO can't manage a category: pick another bot."); }
            }
            if let Some(n) = text(cmd, "name") {
                if n.trim().is_empty() { return err("Needs a name."); }
                if n.chars().count() > 80 { return err("Keep the name under 80 characters."); }
            }
            h.change_layout(|layout, bots| {
                let Some(section) = layout.section_mut(&id) else { return };
                if let Some(n) = text(cmd, "name") { section.name = n.trim().to_string(); }
                if let Some(p) = cmd.get("purpose") {
                    section.purpose = p.as_str().map(|p| p.trim().to_string()).filter(|p| !p.is_empty());
                }
                if let Some(c) = cmd.get("collapsed").and_then(|c| c.as_bool()) { section.collapsed = if c { Some(true) } else { None }; }
                if let Some(on) = cmd.get("hasManager").and_then(|c| c.as_bool()) { section.set_has_manager(on, bots); }
                if let Some(leader) = cmd.get("leader") {
                    section.set_leader(leader.as_str().filter(|l| !l.is_empty()).map(str::to_string), bots);
                }
            });
            ok(json!({"id": id}))
        }
        "teamDelete" => {
            let Some(id) = text(cmd, "id").filter(|id| h.layout().section(id).is_some()) else { return err("No such category.") };
            h.delete_section(&id);
            ok(json!({"deleted": id}))
        }
        "teamMember" => {
            let Some(id) = text(cmd, "id").filter(|id| h.layout().section(id).is_some()) else { return err("No such category.") };
            let Some(bot) = text(cmd, "bot").filter(|b| h.bot(b).is_some()) else { return err("No such bot.") };
            let action = text(cmd, "action").unwrap_or_else(|| "add".into());
            if action == "add" && is_ceo(h, &bot) { return err(CEO_STAYS_ON_TOP); }
            h.change_layout(|layout, bots| {
                let Some(section) = layout.section_mut(&id) else { return };
                if action == "remove" { section.remove_member(&bot, bots) } else { section.add_member(&bot, bots) }
            });
            ok(json!({"id": id, "bot": bot, "action": action}))
        }
        "teamMove" => {
            let Some(bot) = text(cmd, "bot").filter(|b| h.bot(b).is_some()) else { return err("No such bot.") };
            let team = text(cmd, "team").filter(|t| !t.is_empty());
            if let Some(t) = &team {
                if h.layout().section(t).is_none() { return err("No such category."); }
                if is_ceo(h, &bot) { return err(CEO_STAYS_ON_TOP); }
            }
            h.change_layout(|layout, bots| layout.move_bot(&bot, team.as_deref(), bots));
            ok(json!({"bot": bot, "team": team}))
        }
        "teamReport" => {
            let Some(id) = text(cmd, "id") else { return err("Needs id.") };
            match h.report_to_ceo(&id) {
                Ok(()) => ok(json!({"reporting": id})),
                Err(why) => err(&why),
            }
        }
        "teamReportSchedule" => {
            let (Some(id), Some(choice)) = (text(cmd, "id"), text(cmd, "schedule")) else { return err("Needs id and schedule.") };
            match h.set_report_schedule(&id, &choice) {
                Ok(()) => ok(json!({"id": id, "schedule": choice, "routine": h.report_routine(&id).map(|r| r.id)})),
                Err(why) => err(&why),
            }
        }
        "botGet" => {
            let Some(bot) = text(cmd, "id").and_then(|id| h.bot(&id)) else { return err("No such bot.") };
            let layout = h.layout();
            let mut v = serde_json::to_value(&bot).unwrap_or_default();
            v["enabled"] = bot.is_on().into();
            v["authorityLevel"] = bot.authority_level().into();
            v["teams"] = Value::Array(layout.categories_of(&bot.id).iter().map(|s| json!({"id": s.id, "name": s.name, "manager": s.leader_id.as_deref() == Some(bot.id.as_str())})).collect());
            v["role"] = teams::role_line(&bot, &layout).map(Value::from).unwrap_or(Value::Null);
            v["deletable"] = (!bot.primary && bot.id != "theo").into();
            // The hub's apps as last read (a quick list, never a check of every app), for the apps and their levels.
            let mut apps = h.with(|s| s.hub_apps.clone());
            if apps.is_empty() { apps = crate::hub::list_apps(h).await.unwrap_or_default(); }
            v["hubApps"] = Value::Array(apps.iter().map(|a| json!({"id": a.get("id"), "name": a.get("name").or(a.get("id"))})).collect());
            ok(v)
        }
        "botMakePrimary" => {
            let Some(id) = text(cmd, "id") else { return err("Needs id.") };
            // The new CEO leaves its categories: it sits on top.
            if let Err(why) = h.make_primary(&id) { return err(&why); }
            h.change_layout(|layout, bots| layout.forget_bot(&id, bots));
            ok(json!({"primary": id}))
        }
        _ => err(&format!("Unknown command {name}")),
    }
}
