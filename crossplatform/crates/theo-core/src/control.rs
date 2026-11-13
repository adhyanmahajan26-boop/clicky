//! The control inbox: JSON command files dropped in `control-inbox/`, answers written to `control-outbox/<same name>`. The same
//! commands the Swift app's test profile understands, so the existing Python suites can drive this engine. Also used by the
//! desktop app's UI through [`handle`] directly.

use crate::harness::{Harness, TEAM_ID};
use crate::model::*;
use serde_json::{json, Value};
use std::sync::Arc;
use std::time::Duration;

fn s(v: &Value, k: &str) -> Option<String> { v.get(k).and_then(|x| x.as_str()).map(str::to_string) }

pub fn ok(result: Value) -> Value { json!({"ok": true, "result": result}) }
pub fn err(e: &str) -> Value { json!({"ok": false, "error": e}) }

pub async fn handle(h: &Arc<Harness>, cmd: &Value) -> Value {
    let name = s(cmd, "cmd").unwrap_or_default();
    match name.as_str() {
        "ping" => ok(json!({"pid": std::process::id(), "os": std::env::consts::OS})),
        "botsState" | "uiState" => ok(h.state_report()),
        "botChat" => {
            let id = s(cmd, "id").unwrap_or_else(|| TEAM_ID.into());
            let limit = cmd.get("limit").and_then(|l| l.as_u64()).unwrap_or(10).min(5000) as usize;
            let c = h.conversation(&id);
            let start = c.messages.len().saturating_sub(limit);
            ok(Value::Array(c.messages[start..].iter().map(|m| {
                let mut e = json!({"id": m.id, "author": m.author, "text": m.text, "at": m.at.to_rfc3339()});
                if let Some(c) = &m.card { e["card"] = c.clone().into(); }
                if let Some(x) = &m.exchange_id { e["exchange"] = x.clone().into(); }
                if let Some(r) = &m.run_id { e["run"] = r.clone().into(); }
                e
            }).collect()))
        }
        "botSay" | "groupSay" => {
            let target = s(cmd, "bot").or_else(|| s(cmd, "group").map(|g| format!("group:{g}"))).unwrap_or_default();
            let Some(text) = s(cmd, "text").filter(|t| !t.is_empty()) else { return err("No text.") };
            if let Some(g) = target.strip_prefix("group:") {
                if h.group(g).is_none() { return err("No such group."); }
                h.send_to_group(&text, g);
            } else {
                let id = if target.is_empty() || target == TEAM_ID { h.primary().map(|b| b.id).unwrap_or_default() } else { target.clone() };
                if h.bot(&id).is_none() { return err("No such bot."); }
                h.send(&text, &id);
            }
            ok(json!({"sent": target}))
        }
        "botCreate" => {
            let Some(name) = s(cmd, "name").filter(|n| !n.is_empty()) else { return err("Needs a name.") };
            let provider = s(cmd, "provider").unwrap_or_else(|| "claude".into());
            let model = s(cmd, "model").unwrap_or_else(|| if provider == "claude" { "claude-sonnet-5-5".into() } else { "opencode/deepseek-v4.1-flash-free".into() });
            let mut bot = Bot::new(&name, &s(cmd, "description").unwrap_or_default(), &s(cmd, "instructions").unwrap_or_else(|| format!("You are {name}.")), &provider, &model);
            if let Some(a) = s(cmd, "authority").filter(|a| ["member", "lead", "ceo"].contains(&a.as_str())) { bot.authority = Some(a); }
            if let Some(list) = cmd.get("canMessage").and_then(|c| c.as_array()) { bot.can_message = Some(list.iter().filter_map(|x| x.as_str().map(str::to_string)).collect()); }
            if let Some(e) = cmd.get("enabled").and_then(|e| e.as_bool()) { bot.enabled = Some(e); }
            if let Some(e) = s(cmd, "effort") { bot.effort = if e.is_empty() { None } else { Some(e) }; }
            let bot = h.add_bot(bot);
            ok(json!({"id": bot.id}))
        }
        "botUpdate" => {
            let Some(mut bot) = s(cmd, "id").and_then(|id| h.bot(&id)) else { return err("No such bot.") };
            if let Some(e) = cmd.get("enabled").and_then(|e| e.as_bool()) { bot.enabled = Some(e); }
            if let Some(a) = s(cmd, "authority").filter(|a| ["member", "lead", "ceo"].contains(&a.as_str())) { bot.authority = Some(a); }
            if let Some(list) = cmd.get("canMessage").and_then(|c| c.as_array()) { bot.can_message = Some(list.iter().filter_map(|x| x.as_str().map(str::to_string)).collect()); }
            if let Some(p) = s(cmd, "provider").filter(|p| !p.is_empty()) { bot.provider = p; }
            if let Some(m) = s(cmd, "model").filter(|m| !m.is_empty()) { bot.model = m; bot.effort = None; }
            if let Some(i) = s(cmd, "instructions").filter(|i| !i.is_empty()) { bot.instructions = i; }
            if let Some(n) = s(cmd, "name").filter(|i| !i.is_empty()) { bot.name = n; }
            if let Some(d) = s(cmd, "description") { bot.description = d; }
            // Which connectors it may use, by server name in `claude mcp list`.
            if let Some(list) = cmd.get("apps").and_then(|a| a.as_array()) {
                let mut apps: Vec<String> = list.iter().filter_map(|x| x.as_str()).map(|x| x.trim().to_string()).filter(|x| !x.is_empty() && x.len() <= 120 && crate::connectors::tool_rule(x).is_some()).collect();
                apps.dedup();
                bot.apps = apps;
            }
            let id = bot.id.clone();
            let enabled = bot.is_on();
            h.save_bot(bot);
            ok(json!({"id": id, "enabled": enabled}))
        }
        "botDelete" => {
            let Some(id) = s(cmd, "id") else { return err("Needs id.") };
            h.delete_bot(&id);
            ok(json!({"deleted": id}))
        }
        "uiBotStop" | "botStop" => {
            let Some(id) = s(cmd, "bot").or_else(|| s(cmd, "id")) else { return err("Needs bot.") };
            h.stop(&id);
            ok(json!({"stopped": id}))
        }
        "uiGroupStop" | "groupStop" => {
            let Some(id) = s(cmd, "group").or_else(|| s(cmd, "id")) else { return err("Needs group.") };
            h.stop_group(&id);
            ok(json!({"stopped": id}))
        }
        "setupState" => ok(crate::setup::state(h).await),
        "setupDone" => {
            h.settings.set("setup.completed", true.into());
            ok(json!({"completed": true}))
        }
        "openTerminal" => {
            let which = s(cmd, "which").unwrap_or_default();
            match crate::setup::open_terminal(h, &which) {
                Ok(()) => ok(json!({"opened": which})),
                Err(e) => err(&e),
            }
        }
        "chatSeen" => {
            let Some(id) = s(cmd, "id") else { return err("Needs id.") };
            h.chat_seen(&id);
            ok(json!({"seen": id}))
        }
        "botRetry" => {
            let Some(id) = s(cmd, "id").filter(|id| h.bot(id).is_some()) else { return err("No such bot.") };
            ok(json!({"retried": h.retry(&id)}))
        }
        "answerCard" => {
            let (Some(room), Some(message), Some(choice)) = (s(cmd, "chat"), s(cmd, "message"), s(cmd, "choice")) else { return err("Needs chat, message and choice.") };
            match h.answer_card(&room, &message, &choice) {
                Ok(done) => ok(json!({"done": done})),
                Err(e) => err(&e),
            }
        }
        "connectors" => {
            let stale = h.with(|s| s.connectors_checked.map(|t| (chrono::Utc::now() - t).num_seconds() > 300).unwrap_or(true));
            if cmd.get("refresh").and_then(|r| r.as_bool()).unwrap_or(false) || stale {
                if let Err(e) = h.refresh_connectors().await {
                    return err(&e);
                }
            }
            let (list, at) = h.with(|s| (s.connectors.clone(), s.connectors_checked));
            ok(json!({"connectors": list, "checked": at.map(|t| t.to_rfc3339())}))
        }
        "botLook" => {
            let Some(mut bot) = s(cmd, "id").and_then(|id| h.bot(&id)) else { return err("No such bot.") };
            let Ok(look) = serde_json::from_value::<Look>(cmd.get("look").cloned().unwrap_or_default()) else { return err("Needs a look.") };
            // The app draws a look straight into its page, so only the parts it knows are kept.
            if !look.is_known() { return err("That look has a part Theo doesn't know.") };
            bot.look = Some(look);
            h.save_bot(bot);
            ok(json!({"saved": true}))
        }
        "botFresh" => {
            let Some(id) = s(cmd, "id").filter(|id| h.bot(id).is_some()) else { return err("No such bot.") };
            h.start_fresh_session(&id);
            ok(json!({"id": id}))
        }
        "groupSave" => {
            let (Some(id), Some(name)) = (s(cmd, "id").filter(|i| !i.is_empty()), s(cmd, "name")) else { return err("Needs id and name.") };
            let members = cmd.get("members").and_then(|m| m.as_array()).map(|a| a.iter().filter_map(|x| x.as_str().map(str::to_string)).collect()).unwrap_or_default();
            h.save_group(Group { id: id.clone(), name, head_id: s(cmd, "head"), member_ids: members });
            ok(json!({"saved": id}))
        }
        "groupDelete" => {
            let Some(id) = s(cmd, "id") else { return err("Needs id.") };
            h.delete_group(&id);
            ok(json!({"deleted": id}))
        }
        "routines" => {
            let id = s(cmd, "id").unwrap_or_default();
            match s(cmd, "action").as_deref().unwrap_or("list") {
                "pause" => h.set_paused(true, &id),
                "resume" => h.set_paused(false, &id),
                "run" => h.run_routine_now(&id),
                "delete" => h.delete_routine(&id),
                _ => {}
            }
            ok(serde_json::to_value(h.with(|s| s.routines.clone())).unwrap_or_default())
        }
        "routineAdd" => {
            let (Some(name), Some(target), Some(instruction), Some(when)) = (s(cmd, "name"), s(cmd, "target"), s(cmd, "do"), s(cmd, "when")) else { return err("Needs name, target, when and do.") };
            let Some(schedule) = crate::schedule::parse(&when) else { return err("Can't read when.") };
            if h.with(|s| s.routines.iter().any(|r| r.name == name && r.target == target)) { return ok(json!({"skipped": name})); }
            let mut routine = Routine::new(&name, &target, &instruction, schedule);
            // Tests can place the next slot directly (a slot missed while Theo was closed).
            if let Some(next) = s(cmd, "nextRunAt").and_then(|t| chrono::DateTime::parse_from_rfc3339(&t).ok()) { routine.next_run_at = Some(next.with_timezone(&chrono::Utc)); }
            let id = routine.id.clone();
            h.save_routine(routine);
            let next = h.with(|s| s.routines.iter().find(|r| r.id == id).and_then(|r| r.next_run_at)).map(|d| d.to_rfc3339()).unwrap_or_default();
            ok(json!({"added": name, "id": id, "next": next}))
        }
        "uiSetDefaults" | "setSetting" => {
            let Some(key) = s(cmd, "key") else { return err("Needs key.") };
            h.settings.set(&key, cmd.get("value").cloned().unwrap_or(Value::Null));
            if key.starts_with("v3.gateway") { crate::gateway::apply(h); }
            ok(json!({"key": key}))
        }
        "harnessSet" => {
            if let Some(m) = s(cmd, "codingModel") { h.settings.set("coding.model", m.into()); }
            if let Some(e) = s(cmd, "codingEffort") { h.settings.set("coding.effort", e.into()); }
            ok(json!({"codingTarget": "claude", "defaultHarness": "claude"}))
        }
        "uiRunStart" | "runStart" => {
            let (Some(prompt), Some(title)) = (s(cmd, "prompt"), s(cmd, "title")) else { return err("Needs prompt and title.") };
            if let Some(m) = s(cmd, "model") { h.settings.set("coding.model", m.into()); }
            let repo = s(cmd, "folder").map(std::path::PathBuf::from).filter(|p| p.join(".git").exists());
            let new_folder = s(cmd, "folder").filter(|_| repo.is_none());
            let room = s(cmd, "room").unwrap_or_else(|| h.primary().map(|b| b.id).unwrap_or_default());
            let id = crate::coding::start(h, prompt, title.clone(), repo, new_folder, room, None);
            ok(json!({"started": title, "id": id}))
        }
        "uiRunFollowup" | "runFollowup" => {
            let (Some(id), Some(text)) = (s(cmd, "run"), s(cmd, "text")) else { return err("Needs run and text.") };
            crate::coding::follow_up(h, &id, &text);
            ok(json!({"sent": id}))
        }
        "uiStopRun" | "runStop" => {
            let id = s(cmd, "id").unwrap_or_default();
            ok(json!({"stopped": crate::coding::stop_run(h, &id)}))
        }
        "botsUsage" => {
            let days = cmd.get("days").and_then(|d| d.as_i64()).unwrap_or(7);
            ok(json!({"days": days, "bots": h.usage_report(days)}))
        }
        "doctor" => {
            let f = h.doctor_findings();
            ok(json!({"findings": f.iter().map(|x| json!({"level": x.0, "check": x.1, "detail": x.2})).collect::<Vec<_>>(), "text": crate::harness::doctor_markdown(&f)}))
        }
        "gateway" => {
            match s(cmd, "action").as_deref().unwrap_or("state") {
                "on" => { h.settings.set("v3.gateway.enabled", true.into()); crate::gateway::apply(h); }
                "off" => { h.settings.set("v3.gateway.enabled", false.into()); crate::gateway::apply(h); }
                "token" => {
                    if !h.settings.is_test { return err("Copy the token in Settings."); }
                    return ok(json!({"token": crate::secrets::read(&h.paths.token_file(), true)}));
                }
                _ => {}
            }
            ok(h.gateway.report(h))
        }
        "status" => ok(json!({"os": std::env::consts::OS, "arch": std::env::consts::ARCH, "data": h.paths.root, "claude": h.executable("claude"), "version": env!("CARGO_PKG_VERSION"),
                                 "ownerName": h.settings.string("owner.name").unwrap_or_default()})),
        _ => err(&format!("Unknown command {name}")),
    }
}

/// Watches the inbox folder and answers each command. Runs until the process ends.
pub async fn serve_inbox(h: Arc<Harness>) {
    let inbox = h.paths.control_inbox();
    let outbox = h.paths.control_outbox();
    let _ = std::fs::create_dir_all(&inbox);
    let _ = std::fs::create_dir_all(&outbox);
    // Whatever is dropped in the inbox runs as the owner, and answers carry chats: this user's alone (the Swift inbox is 0700 too).
    crate::paths::make_private(&inbox);
    crate::paths::make_private(&outbox);
    loop {
        if let Ok(dir) = std::fs::read_dir(&inbox) {
            let mut files: Vec<_> = dir.flatten().map(|e| e.path()).filter(|p| p.extension().map(|e| e == "json").unwrap_or(false)).collect();
            files.sort();
            for file in files {
                let name = file.file_name().unwrap().to_owned();
                let data = std::fs::read(&file);
                let _ = std::fs::remove_file(&file);
                let Ok(data) = data else { continue };
                let h = h.clone();
                let outbox = outbox.clone();
                tokio::spawn(async move {
                    let answer = match serde_json::from_slice::<Value>(&data) {
                        Ok(cmd) => {
                            if cmd.get("cmd").and_then(|c| c.as_str()) == Some("quit") {
                                let _ = crate::store::write_atomic(&outbox.join(&name), &serde_json::to_vec(&ok(json!({"quitting": true}))).unwrap());
                                tokio::time::sleep(Duration::from_millis(200)).await;
                                h.shutdown();
                                std::process::exit(0);
                            }
                            handle(&h, &cmd).await
                        }
                        Err(e) => err(&format!("Bad JSON: {e}")),
                    };
                    let _ = crate::store::write_atomic(&outbox.join(&name), &serde_json::to_vec(&answer).unwrap_or_default());
                });
            }
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
}
