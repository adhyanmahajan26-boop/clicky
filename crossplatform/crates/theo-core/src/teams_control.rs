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

use crate::control::{err, ok};
use crate::harness::Harness;
use crate::teams;
use serde_json::{json, Value};
use std::sync::Arc;

fn text(v: &Value, k: &str) -> Option<String> { v.get(k).and_then(|x| x.as_str()).map(str::to_string) }

fn is_ceo(h: &Harness, bot_id: &str) -> bool { h.bot(bot_id).map(|b| b.primary).unwrap_or(false) }

const CEO_STAYS_ON_TOP: &str = "The CEO stays on top of the sidebar and isn't filed in a category.";

pub async fn handle(h: &Arc<Harness>, name: &str, cmd: &Value) -> Value {
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
