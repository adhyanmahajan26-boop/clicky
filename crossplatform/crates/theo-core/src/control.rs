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
            let provider = s(cmd, "provider").filter(|p| !p.is_empty()).unwrap_or_else(|| "claude".into());
            if !crate::brains::is_known_engine(&provider) { return err("Theo doesn't know that brain."); }
            // No model given: the agent's own starting model, or the key's preferred chat model.
            let model = match s(cmd, "model").filter(|m| !m.is_empty()) {
                Some(model) => model,
                None => match crate::brains::api_provider_id(&provider) {
                    Some(provider_id) => crate::brains::model_for_new_bot(h, provider_id).await.unwrap_or_default(),
                    None => crate::brains::command_line_brain(&provider).map(|brain| brain.default_model.to_string()).unwrap_or_default(),
                },
            };
            if model.is_empty() && provider.starts_with("api:") { return err("Pick a model for that key."); }
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
            if let Some(p) = s(cmd, "provider").filter(|p| !p.is_empty()) {
                if !crate::brains::is_known_engine(&p) { return err("Theo doesn't know that brain."); }
                bot.provider = p;
            }
            if let Some(m) = s(cmd, "model").filter(|m| !m.is_empty()) { bot.model = m; bot.effort = None; }
            if let Some(i) = s(cmd, "instructions").filter(|i| !i.is_empty()) { bot.instructions = i; }
            if let Some(n) = s(cmd, "name").filter(|i| !i.is_empty()) { bot.name = n; }
            if let Some(d) = s(cmd, "description") { bot.description = d; }
            // Which apps it may use: connector hub app ids, or (from older callers) Claude Code server names, which become
            // the hub apps for those servers.
            if let Some(list) = cmd.get("apps").and_then(|a| a.as_array()) {
                let wanted: Vec<String> = list.iter().filter_map(|x| x.as_str()).map(|x| x.trim().to_string()).filter(|x| !x.is_empty() && x.len() <= 120).collect();
                match crate::hub::hub_ids_for(h, &wanted).await {
                    Ok((ids, added_levels)) => {
                        for (id, level) in added_levels { bot.app_levels.entry(id).or_insert(level); }
                        bot.apps = ids;
                    }
                    Err(e) => return err(&e),
                }
            }
            if let Some(levels) = cmd.get("appLevels").and_then(|a| a.as_object()) {
                for (id, level) in levels {
                    if let Some(level) = level.as_str().filter(|l| crate::hub::LEVELS.contains(l)) { bot.app_levels.insert(id.clone(), level.to_string()); }
                }
            }
            let kept_apps = bot.apps.clone();
            bot.app_levels.retain(|id, _| kept_apps.contains(id));
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
            let moved = crate::setup::move_untouched_theo(h).await.map(|(engine, model)| json!({"engine": engine, "model": model}));
            ok(json!({"completed": true, "theoMovedTo": moved}))
        }
        // Every brain and whether it works here. Never includes a key, only whether one is saved.
        "brains" => ok(crate::brains::inventory(h).await),
        "apiKeySet" => {
            let Some(provider) = s(cmd, "provider").filter(|p| crate::brains::api_provider(h, p).is_some()) else { return err("Theo doesn't know that provider.") };
            let Some(key) = s(cmd, "key").map(|k| k.trim().to_string()).filter(|k| !k.is_empty() && k.len() <= 4096 && !k.chars().any(char::is_control)) else { return err("Paste the key.") };
            if let Err(e) = crate::secrets::write_api_key(&h.paths.root, h.settings.is_test, &provider, Some(&key)) { return err(&e.to_string()); }
            // The check is the provider's own model list: it proves the key works and gives the first bot a model.
            match crate::brains::list_models(h, &provider).await {
                Ok(models) => {
                    let preferred = crate::brains::preferred_model(&provider, &models);
                    ok(json!({"provider": provider, "saved": true, "works": true, "models": models, "preferredModel": preferred}))
                }
                Err(problem) => ok(json!({"provider": provider, "saved": true, "works": false, "problem": problem})),
            }
        }
        "apiKeyRemove" => {
            let Some(provider) = s(cmd, "provider").filter(|p| crate::secrets::is_provider_id(p)) else { return err("Theo doesn't know that provider.") };
            match crate::secrets::write_api_key(&h.paths.root, h.settings.is_test, &provider, None) {
                Ok(()) => ok(json!({"provider": provider, "removed": true})),
                Err(e) => err(&e.to_string()),
            }
        }
        "apiModels" => {
            let Some(provider) = s(cmd, "provider") else { return err("Needs provider.") };
            match crate::brains::list_models(h, &provider).await {
                Ok(models) => ok(json!({"provider": provider, "preferredModel": crate::brains::preferred_model(&provider, &models), "models": models})),
                Err(problem) => err(&problem),
            }
        }
        // The brain that answers when a bot's own keeps failing: `{engine, model}`, or an empty engine for Claude Code when
        // it is installed (the default).
        "standIn" => {
            let engine = s(cmd, "engine").unwrap_or_default();
            if engine.is_empty() {
                h.settings.set(crate::brains::STAND_IN_SETTING, Value::Null);
                return ok(json!({"standIn": null}));
            }
            if !crate::brains::is_known_engine(&engine) { return err("Theo doesn't know that brain."); }
            let model = s(cmd, "model").unwrap_or_default();
            if engine.starts_with("api:") && model.is_empty() { return err("Pick a model for that key."); }
            let value = format!("{engine}|{model}");
            h.settings.set(crate::brains::STAND_IN_SETTING, value.clone().into());
            ok(json!({"standIn": value}))
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
        // The Connectors page: the connector hub's apps (docs/CONNECTORS.md), which bots may use each, and sign-ins under way.
        "connectors" => {
            let stale = h.with(|s| s.connectors_checked.map(|t| (chrono::Utc::now() - t).num_seconds() > 300).unwrap_or(true));
            if cmd.get("refresh").and_then(|r| r.as_bool()).unwrap_or(false) || stale {
                if let Err(e) = h.refresh_connectors().await {
                    // A check that failed still leaves the list as the hub has it.
                    if crate::hub::list_apps(h).await.is_err() { return err(&e); }
                }
            } else if let Err(e) = crate::hub::list_apps(h).await {
                return err(&e);
            }
            ok(crate::hub::page_report(h))
        }
        "connectorCatalog" => match crate::hub::catalog(h).await {
            Ok(apps) => ok(json!({"apps": apps})),
            Err(e) => err(&e),
        },
        "connectorAdd" => {
            let words: Vec<String> = if let Some(id) = s(cmd, "catalog") {
                let mut w = vec!["add".to_string(), "--catalog".into(), id];
                if let Some(new_id) = s(cmd, "id") { w.push("--id".into()); w.push(new_id); }
                w
            } else if let Some(app) = cmd.get("app").filter(|a| a.is_object()) {
                vec!["add".into(), "--json".into(), app.to_string()]
            } else {
                return err("Needs an app or a catalog id.");
            };
            connector_change(h, words, None).await
        }
        "connectorRemove" => {
            let Some(id) = s(cmd, "id") else { return err("Needs id.") };
            let answer = connector_change(h, vec!["remove".into(), id.clone()], None).await;
            // No bot keeps an app that's gone.
            if answer.get("ok").and_then(|o| o.as_bool()) == Some(true) {
                for mut bot in h.bots().into_iter().filter(|b| b.apps.contains(&id)) {
                    bot.apps.retain(|a| a != &id);
                    bot.app_levels.remove(&id);
                    h.save_bot(bot);
                }
            }
            answer
        }
        "connectorEnable" => {
            let Some(id) = s(cmd, "id") else { return err("Needs id.") };
            let on = cmd.get("enabled").and_then(|e| e.as_bool()).unwrap_or(true);
            connector_change(h, vec![if on { "enable" } else { "disable" }.into(), id], None).await
        }
        "connectorCheck" => {
            let mut words = vec!["check".to_string()];
            if let Some(id) = s(cmd, "id") { words.push(id); }
            connector_change(h, words, None).await
        }
        // A pasted token (or a local app's secret setting), handed to the hub on its standard input: never on a command line,
        // never in a log, never in the answer.
        "connectorSecret" => {
            let Some(id) = s(cmd, "id") else { return err("Needs id.") };
            let value = s(cmd, "value").unwrap_or_default();
            let mut words = vec!["set-secret".to_string(), id];
            if let Some(name) = s(cmd, "env") { words.push("--env".into()); words.push(name); }
            if cmd.get("clientSecret").and_then(|c| c.as_bool()).unwrap_or(false) { words.push("--client-secret".into()); }
            let answer = connector_change(h, words.clone(), Some(value)).await;
            if answer.get("ok").and_then(|o| o.as_bool()) == Some(true) && words.len() == 2 {
                let _ = crate::hub::run_hub_command(h, &[String::from("check"), words[1].clone()], None, Duration::from_secs(60)).await;
                let _ = crate::hub::list_apps(h).await;
            }
            answer
        }
        "connectorSignIn" => {
            let Some(id) = s(cmd, "id") else { return err("Needs id.") };
            match crate::hub::start_sign_in(h, &id).await {
                Ok(url) => ok(json!({"app": id, "url": url})),
                Err(e) => err(&e),
            }
        }
        "connectorSignOut" => {
            let Some(id) = s(cmd, "id") else { return err("Needs id.") };
            h.with(|s| { s.sign_ins.remove(&id); });
            connector_change(h, vec!["signout".into(), id], None).await
        }
        "connectorTools" => {
            let Some(id) = s(cmd, "id") else { return err("Needs id.") };
            match crate::hub::tools_of(h, &id).await {
                Ok(tools) => ok(json!({"app": id, "tools": tools})),
                Err(e) => err(&e),
            }
        }
        // One bot's access to one app: off, read, readAndDraft or full.
        "botApp" => {
            let (Some(mut bot), Some(app)) = (s(cmd, "bot").and_then(|id| h.bot(&id)), s(cmd, "app")) else { return err("Needs bot and app.") };
            let level = s(cmd, "level").unwrap_or_else(|| crate::hub::DEFAULT_LEVEL.into());
            if level == "off" {
                bot.apps.retain(|a| a != &app);
                bot.app_levels.remove(&app);
            } else {
                if !crate::hub::LEVELS.contains(&level.as_str()) { return err("The level is read, readAndDraft, full or off."); }
                if !h.with(|s| s.hub_apps.iter().any(|a| a.get("id").and_then(|i| i.as_str()) == Some(app.as_str()))) && crate::hub::list_apps(h).await.map(|apps| !apps.iter().any(|a| a.get("id").and_then(|i| i.as_str()) == Some(app.as_str()))).unwrap_or(true) {
                    return err("There's no such app.");
                }
                if !bot.apps.contains(&app) { bot.apps.push(app.clone()); }
                bot.app_levels.insert(app.clone(), level.clone());
            }
            let id = bot.id.clone();
            h.save_bot(bot);
            ok(json!({"bot": id, "app": app, "level": level}))
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
            // The coding agent: an agent's id, or "auto" (or empty) for the first one ready. The coding model and effort are
            // that agent's, so a new pick starts on its own default unless they come with it.
            if let Some(target) = s(cmd, "codingTarget") {
                let target = target.trim().to_string();
                if !target.is_empty() && target != "auto" && !crate::coding::CODING_AGENTS.contains(&target.as_str()) { return err("Theo doesn't know that coding agent."); }
                let value = if target.is_empty() || target == "auto" { Value::Null } else { Value::from(target) };
                if h.settings.get(crate::coding::TARGET_SETTING).unwrap_or(Value::Null) != value {
                    h.settings.set(crate::coding::TARGET_SETTING, value);
                    h.settings.set("coding.model", Value::Null);
                    h.settings.set("coding.effort", Value::Null);
                }
            }
            if let Some(m) = s(cmd, "codingModel") { h.settings.set("coding.model", m.into()); }
            if let Some(e) = s(cmd, "codingEffort") { h.settings.set("coding.effort", e.into()); }
            let brains = crate::brains::inventory(h).await;
            let coding = brains["coding"].clone();
            ok(json!({"codingTarget": coding["target"].clone(), "defaultHarness": coding["target"].clone(), "coding": coding}))
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

/// Runs one hub command that changes the list, then reads the list again for the page and the prompts.
async fn connector_change(h: &Arc<Harness>, words: Vec<String>, standard_input: Option<String>) -> Value {
    let limit = if words.first().map(|w| w == "add" || w == "check").unwrap_or(false) { Duration::from_secs(150) } else { Duration::from_secs(30) };
    let answer = crate::hub::run_hub_command(h, &words, standard_input, limit).await;
    crate::hub::forget_kept_tools(h);
    let _ = crate::hub::list_apps(h).await;
    match answer {
        Ok(mut value) => {
            if let Some(object) = value.as_object_mut() { object.remove("ok"); }
            ok(value)
        }
        Err(e) => err(&e),
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
