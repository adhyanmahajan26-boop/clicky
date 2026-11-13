//! The connector hub (`theo-connectors`, `crates/theo-connectors`) as the harness uses it.
//!
//! Before the hub, the Connectors page was the output of `claude mcp list`, a bot's `apps` were Claude Code server names,
//! and a computer without Claude Code had no apps at all. Now Theo's own list of apps, their sign-ins and the rule for
//! what a bot may do live in the hub, a helper program shipped beside the app. This file is everything the engine needs
//! from it, through the command-line contract in `docs/CONNECTORS.md`:
//!
//! - finding the helper and running one command of it (`run_hub_command`),
//! - the Connectors page's list, kept in memory so a bot's prompt can name its apps without starting a process,
//! - moving a bot's old Claude server names ("claude.ai Gmail") onto hub apps so nothing a user set up is lost,
//! - picking up what the user already has in Claude Code, once per server, as `claude-account` apps,
//! - and, for each bot turn, the ticket and the tool rules ([`TurnApps`]).
//!
//! The rule for each turn: a Claude Code bot keeps its direct route to an app on the owner's Claude account (Claude Code's
//! own `mcp__claude_ai_*` tools, allowed tool by tool for the bot's level), because it is faster. Every other app, and
//! every app of a bot on another engine, goes through the hub's `serve` with a ticket the hub checks on every call.

use crate::engine;
use crate::harness::Harness;
use chrono::Utc;
use serde_json::{json, Value};
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::time::Duration;

/// The name the hub's MCP server goes by in Claude Code's and OpenCode's config for a turn, so Claude Code calls its tools
/// `mcp__theo__<app>__<tool>`.
pub const HUB_SERVER_NAME: &str = "theo";

/// The name it goes by for Codex, Cursor, Gemini and Grok: their per-turn settings are merged with the owner's own config by
/// server name, and the Mac's Theo already has a server called `theo` there. The Mac app uses the same name
/// (`ConnectorHubWiring.serverName`).
pub const SHARED_HUB_SERVER_NAME: &str = "theo_apps";

/// The ticket file a Grok turn uses. Grok only reads MCP servers from its own config file, so the hub's entry there names a
/// ticket of fixed name that only exists while one of its turns runs.
pub const GROK_TICKET_NAME: &str = "grok-turn.json";

/// The three levels a bot can have for an app, weakest first.
pub const LEVELS: [&str; 3] = ["read", "readAndDraft", "full"];

/// What a bot gets when it is given an app and nothing more is said: read, and write things that can be undone.
pub const DEFAULT_LEVEL: &str = "readAndDraft";

/// Settings key: the Claude Code servers already offered once as apps, so one the owner removed doesn't come back.
const ADOPTED_CLAUDE_SERVERS_SETTING: &str = "connectors.claudeServersAdopted";

/// Settings key: every bot's old Claude server names have been moved onto hub apps (see `move_old_app_names`).
const MOVED_ONTO_HUB_SETTING: &str = "connectors.movedOntoHub";

const QUICK_COMMAND_LIMIT: Duration = Duration::from_secs(30);
/// `check` starts every app (and one `claude mcp list` for the Claude account ones, which can take a minute by itself).
const CHECK_COMMAND_LIMIT: Duration = Duration::from_secs(150);
const SIGN_IN_LIMIT_SECONDS: u64 = 300;

// MARK: Finding and running the helper

/// The helper's file name on this platform.
fn helper_file_name() -> String {
    format!("theo-connectors{}", std::env::consts::EXE_SUFFIX)
}

/// Where the hub helper is: `THEO_CONNECTORS_BIN` (tests and scripts), next to this program (the installed app and the
/// installers put it there; Tauri also names a development copy `theo-connectors-<target>`), else on PATH.
pub fn helper_path() -> Option<PathBuf> {
    if let Some(path) = std::env::var_os("THEO_CONNECTORS_BIN").map(PathBuf::from).filter(|p| p.is_file()) {
        return Some(path);
    }
    if let Some(folder) = std::env::current_exe().ok().and_then(|exe| exe.parent().map(Path::to_path_buf)) {
        let beside = folder.join(helper_file_name());
        if beside.is_file() {
            return Some(beside);
        }
        // `tauri dev` copies a sidecar with its target triple in the name.
        if let Ok(entries) = std::fs::read_dir(&folder) {
            for entry in entries.flatten() {
                let name = entry.file_name().to_string_lossy().to_string();
                if name.starts_with("theo-connectors-") && name.ends_with(std::env::consts::EXE_SUFFIX) && entry.path().is_file() {
                    return Some(entry.path());
                }
            }
        }
    }
    engine::locate("theo-connectors")
}

/// The words that go before every command: where Theo's data is, and in a test profile a key kept in a file, so tests never
/// touch the real Keychain or Credential Manager.
fn common_arguments(harness: &Harness) -> Vec<String> {
    let mut arguments = vec!["--data".to_string(), harness.paths.root.to_string_lossy().to_string()];
    if harness.settings.is_test {
        arguments.push("--key-store".into());
        arguments.push("file".into());
    }
    arguments
}

/// Settings the helper reads from its environment: the Claude Code Theo found (a test profile's stand-in, or the installed
/// one), for apps on the owner's Claude account.
fn helper_environment(harness: &Harness) -> Vec<(String, String)> {
    let mut environment = vec![];
    if let Some(claude) = harness.executable("claude") {
        environment.push(("THEO_CONNECTORS_CLAUDE".to_string(), claude.to_string_lossy().to_string()));
    }
    environment
}

fn missing_helper_message() -> String {
    format!("Theo's connector helper ({}) isn't next to Theo. Reinstall Theo to put it back.", helper_file_name())
}

/// Runs one hub command to its end and returns its JSON answer. `standard_input` carries a secret (a pasted token) so it
/// never shows in a process list. A failure is the hub's own sentence for the user.
pub async fn run_hub_command(harness: &Harness, command_words: &[String], standard_input: Option<String>, time_limit: Duration) -> Result<Value, String> {
    let helper = helper_path().ok_or_else(missing_helper_message)?;
    let mut command = engine::background_command(&helper);
    command
        .args(common_arguments(harness))
        .args(command_words)
        .envs(helper_environment(harness))
        .current_dir(&harness.paths.root)
        .stdin(if standard_input.is_some() { std::process::Stdio::piped() } else { std::process::Stdio::null() })
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        .kill_on_drop(true);
    let mut child = command.spawn().map_err(|error| format!("Theo's connector helper couldn't start: {error}"))?;
    let process_tree = crate::procs::ProcessTree::attach(&child).ok();
    if let Some(text) = standard_input {
        use tokio::io::AsyncWriteExt;
        if let Some(mut pipe) = child.stdin.take() {
            let _ = pipe.write_all(text.as_bytes()).await;
            drop(pipe);
        }
    }
    let finished = tokio::time::timeout(time_limit, child.wait_with_output()).await;
    if let Some(process_tree) = &process_tree {
        // The apps it started to check them end with it, even after a timeout.
        if process_tree.alive() {
            process_tree.kill();
        }
    }
    let output = finished
        .map_err(|_| "Theo's connector helper took too long to answer.".to_string())?
        .map_err(|error| format!("Theo's connector helper failed: {error}"))?;
    let printed = String::from_utf8_lossy(&output.stdout);
    let answer = last_json_line(&printed).ok_or_else(|| {
        // Its diagnostics never hold a secret (the hub's own rule), so the last of them can go in a log.
        let detail = String::from_utf8_lossy(&output.stderr).lines().last().unwrap_or("").to_string();
        log_helper_problem(harness, &detail);
        "Theo's connector helper gave no answer.".to_string()
    })?;
    if answer.get("ok").and_then(Value::as_bool) == Some(false) {
        return Err(answer.get("error").and_then(Value::as_str).unwrap_or("The connector helper couldn't do that.").to_string());
    }
    Ok(answer)
}

fn last_json_line(printed: &str) -> Option<Value> {
    printed.lines().rev().map(str::trim).filter(|line| line.starts_with('{')).find_map(|line| serde_json::from_str(line).ok())
}

fn log_helper_problem(harness: &Harness, detail: &str) {
    if detail.is_empty() {
        return;
    }
    let folder = harness.paths.logs_dir();
    let _ = std::fs::create_dir_all(&folder);
    use std::io::Write;
    if let Ok(mut file) = std::fs::OpenOptions::new().create(true).append(true).open(folder.join("connectors.log")) {
        let _ = writeln!(file, "{} {}", Utc::now().to_rfc3339(), detail.chars().take(400).collect::<String>());
    }
}

fn words(list: &[&str]) -> Vec<String> {
    list.iter().map(|word| word.to_string()).collect()
}

// MARK: The list of apps

/// What the page and the turns need of one app from `list`. The whole entry is kept as the hub printed it.
fn app_id(app: &Value) -> &str {
    app.get("id").and_then(Value::as_str).unwrap_or("")
}

fn app_kind(app: &Value) -> &str {
    app.get("kind").and_then(Value::as_str).unwrap_or("")
}

fn app_server(app: &Value) -> Option<&str> {
    app.get("server").and_then(Value::as_str)
}

fn app_is_enabled(app: &Value) -> bool {
    app.get("enabled").and_then(Value::as_bool).unwrap_or(true)
}

/// The hub's list, read from its files (nothing is contacted), and kept for prompts.
pub async fn list_apps(harness: &Harness) -> Result<Vec<Value>, String> {
    let answer = run_hub_command(harness, &words(&["list"]), None, QUICK_COMMAND_LIMIT).await?;
    let apps = answer.get("apps").and_then(Value::as_array).cloned().unwrap_or_default();
    harness.with(|state| state.hub_apps = apps.clone());
    Ok(apps)
}

/// The starter catalog, once per run of Theo (it is built into the helper).
pub async fn catalog(harness: &Harness) -> Result<Vec<Value>, String> {
    if let Some(known) = harness.with(|state| state.hub_catalog.clone()) {
        return Ok(known);
    }
    let answer = run_hub_command(harness, &words(&["catalog"]), None, QUICK_COMMAND_LIMIT).await?;
    let entries = answer.pointer("/catalog/apps").and_then(Value::as_array).cloned().unwrap_or_default();
    harness.with(|state| state.hub_catalog = Some(entries.clone()));
    Ok(entries)
}

/// An app's tools with what each does (`read`, `change`, `irreversible`). Kept until the list changes: a claude-account
/// app's come from the catalog, and a local or remote app's only change when the app does.
pub async fn tools_of(harness: &Harness, app_id: &str) -> Result<Vec<Value>, String> {
    if let Some(known) = harness.with(|state| state.hub_tools.get(app_id).cloned()) {
        return Ok(known);
    }
    let answer = run_hub_command(harness, &words(&["tools", app_id]), None, CHECK_COMMAND_LIMIT).await?;
    let tools = answer.get("tools").and_then(Value::as_array).cloned().unwrap_or_default();
    harness.with(|state| {
        state.hub_tools.insert(app_id.to_string(), tools.clone());
    });
    Ok(tools)
}

/// Something about the list changed: what was kept of tools is stale.
pub fn forget_kept_tools(harness: &Harness) {
    harness.with(|state| state.hub_tools.clear());
}

/// Checks every app (or one), then reads the list again. Only one check of everything runs at a time, because each one
/// starts every app and a `claude mcp list`: a second caller waits for the first one's result.
pub async fn refresh(harness: &Harness) -> Result<(), String> {
    let started_here = harness.with(|state| {
        if state.connectors_refreshing {
            false
        } else {
            state.connectors_refreshing = true;
            true
        }
    });
    if !started_here {
        let deadline = std::time::Instant::now() + CHECK_COMMAND_LIMIT + Duration::from_secs(5);
        while harness.with(|state| state.connectors_refreshing) && std::time::Instant::now() < deadline {
            tokio::time::sleep(Duration::from_millis(250)).await;
        }
        return Ok(());
    }
    struct ClearWhenDone<'a>(&'a Harness);
    impl Drop for ClearWhenDone<'_> {
        fn drop(&mut self) {
            self.0.with(|state| state.connectors_refreshing = false);
        }
    }
    let _clear = ClearWhenDone(harness);
    // What the owner already has in Claude Code shows up as apps without being added again by hand.
    let claude_status = adopt_claude_code_servers(harness).await;
    let checked = run_hub_command(harness, &words(&["check"]), None, CHECK_COMMAND_LIMIT).await;
    forget_kept_tools(harness);
    list_apps(harness).await?;
    harness.with(|state| {
        state.connectors_checked = Some(Utc::now());
        state.claude_code_note = claude_status.err();
    });
    checked.map(|_| ())
}

/// A hub app id: lowercase letters, digits and dashes, up to 40 (the hub's own rule).
pub fn is_app_id(text: &str) -> bool {
    !text.is_empty() && text.len() <= 40 && text.chars().all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '-') && !text.starts_with('-')
}

/// An id made from a Claude server's name, as `discover-claude` suggests: "claude.ai Hostinger Connector" → "hostinger-connector".
pub fn id_for_server(server: &str) -> String {
    let name = server.strip_prefix("claude.ai ").unwrap_or(server);
    let mut id = String::new();
    for character in name.chars() {
        if character.is_ascii_alphanumeric() {
            id.push(character.to_ascii_lowercase());
        } else if !id.ends_with('-') && !id.is_empty() {
            id.push('-');
        }
    }
    let id: String = id.trim_end_matches('-').chars().take(36).collect();
    let id = id.trim_end_matches('-').to_string();
    if id.is_empty() { "claude-app".into() } else { id }
}

fn free_id(wanted: &str, taken: &[String]) -> String {
    if !taken.iter().any(|id| id == wanted) {
        return wanted.to_string();
    }
    (2..).map(|n| format!("{wanted}-{n}")).find(|candidate| !taken.iter().any(|id| id == candidate)).unwrap_or_else(|| wanted.to_string())
}

/// Adds a claude-account app for one Claude Code server: the catalog's entry when one is for that server (it knows the
/// app's tools), else a plain entry. Returns its id.
async fn add_claude_account_app(harness: &Harness, server: &str, display_name: Option<&str>, apps: &[Value]) -> Result<String, String> {
    let taken: Vec<String> = apps.iter().map(|app| app_id(app).to_string()).collect();
    let catalog_entry = catalog(harness).await.unwrap_or_default().into_iter().find(|entry| app_server(entry) == Some(server));
    if let Some(entry) = catalog_entry {
        let catalog_id = app_id(&entry).to_string();
        let id = free_id(&catalog_id, &taken);
        run_hub_command(harness, &words(&["add", "--catalog", &catalog_id, "--id", &id, "--no-check"]), None, QUICK_COMMAND_LIMIT).await?;
        return Ok(id);
    }
    let id = free_id(&id_for_server(server), &taken);
    let name = display_name.map(str::to_string).unwrap_or_else(|| server.strip_prefix("claude.ai ").unwrap_or(server).to_string());
    let app = json!({"id": id, "name": name, "kind": "claude-account", "server": server});
    run_hub_command(harness, &words(&["add", "--json", &app.to_string(), "--no-check"]), None, QUICK_COMMAND_LIMIT).await?;
    Ok(id)
}

/// Offers each server Claude Code has as an app, once: a server the owner later removes in Theo stays removed. Err when
/// Claude Code isn't there or couldn't list its servers (a note for the page, not a failure: Theo works without it).
async fn adopt_claude_code_servers(harness: &Harness) -> Result<(), String> {
    if harness.executable("claude").is_none() {
        return Err("Claude Code isn't installed, so apps on a Claude account aren't listed. Apps added here work without it.".into());
    }
    let discovered = run_hub_command(harness, &words(&["discover-claude"]), None, CHECK_COMMAND_LIMIT).await?;
    let servers = discovered.get("servers").and_then(Value::as_array).cloned().unwrap_or_default();
    let mut adopted = harness.settings.strings(ADOPTED_CLAUDE_SERVERS_SETTING).unwrap_or_default();
    let mut apps = list_apps(harness).await?;
    let mut changed = false;
    for found in servers {
        let Some(server) = found.get("server").and_then(Value::as_str) else { continue };
        // Theo's own hub, if the owner ever added it to Claude Code, isn't an app.
        if server == HUB_SERVER_NAME || adopted.iter().any(|known| known == server) {
            continue;
        }
        if !apps.iter().any(|app| app_server(app) == Some(server)) {
            match add_claude_account_app(harness, server, found.get("name").and_then(Value::as_str), &apps).await {
                Ok(_) => apps = list_apps(harness).await?,
                Err(error) => {
                    log_helper_problem(harness, &format!("couldn't add {server}: {error}"));
                    continue;
                }
            }
        }
        adopted.push(server.to_string());
        changed = true;
    }
    if changed {
        harness.settings.set(ADOPTED_CLAUDE_SERVERS_SETTING, json!(adopted));
    }
    Ok(())
}

// MARK: Moving old choices onto the hub

/// A bot's apps as hub ids, with the level for any it had to add. Before the hub, `apps` held Claude Code server names
/// ("claude.ai Gmail", "theo-echo"), and a bot given one got all of that server's tools. Each becomes the hub app for the
/// same server: the catalog's (whose tools the hub knows, so the bot gets read and draft as on the Mac), or a plain
/// claude-account app at `full`, since Theo can't tell its tools apart and that is what the bot had.
pub async fn hub_ids_for(harness: &Harness, wanted: &[String]) -> Result<(Vec<String>, BTreeMap<String, String>), String> {
    let mut apps = harness.with(|state| state.hub_apps.clone());
    if apps.is_empty() || wanted.iter().any(|entry| !apps.iter().any(|app| app_id(app) == entry)) {
        apps = list_apps(harness).await?;
    }
    let mut ids = vec![];
    let mut added_levels = BTreeMap::new();
    for entry in wanted {
        let entry = entry.trim();
        if entry.is_empty() {
            continue;
        }
        let id = if let Some(app) = apps.iter().find(|app| app_id(app) == entry) {
            app_id(app).to_string()
        } else if let Some(app) = apps.iter().find(|app| app_server(app) == Some(entry)) {
            app_id(app).to_string()
        } else if crate::connectors::tool_rule(entry).is_some() {
            let id = add_claude_account_app(harness, entry, None, &apps).await?;
            apps = list_apps(harness).await?;
            let knows_tools = apps.iter().find(|app| app_id(app) == id).map(|app| app.get("readTools").is_some() || app.get("writeTools").is_some()).unwrap_or(false);
            if !knows_tools {
                added_levels.insert(id.clone(), "full".to_string());
            }
            id
        } else {
            continue;
        };
        if !ids.contains(&id) {
            ids.push(id);
        }
    }
    Ok((ids, added_levels))
}

/// Whether a bot still holds a name from before the hub.
pub fn has_old_app_names(harness: &Harness, bot: &crate::model::Bot) -> bool {
    let apps = harness.with(|state| state.hub_apps.clone());
    bot.apps.iter().any(|entry| !apps.iter().any(|app| app_id(app) == entry))
}

/// Moves every bot's old names onto hub apps and saves the bots that changed. Leaves a bot as it is when the hub can't be
/// reached, so nothing is lost; the next start or turn tries again.
pub async fn move_old_app_names(harness: &Harness) {
    if harness.settings.bool(MOVED_ONTO_HUB_SETTING) || list_apps(harness).await.is_err() {
        return;
    }
    let mut all_moved = true;
    for bot in harness.bots() {
        if bot.apps.is_empty() || !has_old_app_names(harness, &bot) {
            continue;
        }
        all_moved &= move_bot_onto_hub(harness, bot).await.is_ok();
    }
    // Once done, an id a bot still holds that the hub no longer has is an app the owner removed, never an old name.
    if all_moved {
        harness.settings.set(MOVED_ONTO_HUB_SETTING, json!(true));
    }
}

/// One bot's old names onto hub apps; returns the bot as saved.
pub async fn move_bot_onto_hub(harness: &Harness, mut bot: crate::model::Bot) -> Result<crate::model::Bot, String> {
    let (ids, added_levels) = hub_ids_for(harness, &bot.apps).await?;
    for (id, level) in added_levels {
        bot.app_levels.entry(id).or_insert(level);
    }
    // Every name it held meant the whole server. Where Theo can't tell that server's tools apart (an app on the Claude
    // account that isn't in the catalog), the bot keeps the whole of it, even when the app was already in the hub.
    let apps = harness.with(|state| state.hub_apps.clone());
    for id in &ids {
        let unknown_tools = apps.iter().find(|app| app_id(app) == id).map(|app| app_kind(app) == "claude-account" && app.get("readTools").is_none() && app.get("writeTools").is_none()).unwrap_or(false);
        if unknown_tools {
            bot.app_levels.entry(id.clone()).or_insert_with(|| "full".to_string());
        }
    }
    bot.apps = ids;
    bot.app_levels.retain(|id, _| bot.apps.contains(id));
    harness.save_bot(bot.clone());
    Ok(bot)
}

/// A bot's level for one of its apps.
pub fn level_of(bot: &crate::model::Bot, app_id: &str) -> String {
    bot.app_levels.get(app_id).filter(|level| LEVELS.contains(&level.as_str())).cloned().unwrap_or_else(|| DEFAULT_LEVEL.to_string())
}

/// The level that holds for this turn: a turn that didn't come from the owner's own words (a routine, another bot, the
/// local API) never gets more than `read`.
pub fn level_for_turn(granted_level: &str, from_owner: bool) -> &'static str {
    let granted = LEVELS.iter().position(|level| *level == granted_level).unwrap_or(1);
    let most = if from_owner { 2 } else { 0 };
    LEVELS[granted.min(most)]
}

/// Whether a tool with this effect may run at this level (the hub's own table).
pub fn effect_allowed(effect: &str, level: &str) -> bool {
    match level {
        "full" => true,
        "readAndDraft" => effect == "read" || effect == "change",
        _ => effect == "read",
    }
}

// MARK: Each bot turn

/// What one bot turn gets of its apps. Dropping it deletes the ticket, so the hub stops answering for the turn however
/// the turn ends.
#[derive(Default)]
pub struct TurnApps {
    /// Claude Code permission rules to add.
    pub allow: Vec<String>,
    pub deny: Vec<String>,
    /// The `--mcp-config` file for a Claude Code turn that has hub apps.
    pub claude_mcp_config: Option<PathBuf>,
    /// `OPENCODE_CONFIG_CONTENT` for an OpenCode turn that has hub apps.
    pub opencode_config: Option<String>,
    /// How to start the hub as this turn's MCP server (program, arguments, environment), for the engines that take it in
    /// their own config shape (Codex, Cursor, Gemini, Grok).
    pub launch: Option<HubLaunch>,
    /// The hub app ids this turn reaches through the hub, with the level each has this turn.
    pub through_hub: BTreeMap<String, String>,
    pub ticket: Option<PathBuf>,
    /// For the prompt: each app's name and the level this turn has.
    pub named: Vec<(String, String)>,
}

impl Drop for TurnApps {
    fn drop(&mut self) {
        if let Some(ticket) = &self.ticket {
            let _ = std::fs::remove_file(ticket);
        }
    }
}

/// The ticket folder the hub reads (`<data>/Connectors/tickets`), private to this user.
fn ticket_folder(harness: &Harness) -> PathBuf {
    harness.paths.root.join("Connectors").join("tickets")
}

/// How an engine starts the hub for one turn.
#[derive(Clone, Debug)]
pub struct HubLaunch {
    pub command: String,
    pub arguments: Vec<String>,
    pub environment: Vec<(String, String)>,
}

/// Writes the turn's ticket in the hub's shape (`docs/CONNECTORS.md`, Tickets). It lasts as long as the turn may, plus a
/// little; the turn deletes it when it ends. `fixed_name`: a ticket file name an engine's static config names (Grok).
pub fn write_ticket(harness: &Harness, bot_id: &str, apps: &BTreeMap<String, String>, from_owner: bool, fixed_name: Option<&str>) -> Result<PathBuf, String> {
    let folder = ticket_folder(harness);
    std::fs::create_dir_all(&folder).map_err(|error| format!("Couldn't make the ticket folder: {error}"))?;
    crate::paths::make_private(&harness.paths.root.join("Connectors"));
    crate::paths::make_private(&folder);
    let lasts = Duration::from_secs_f64(harness.settings.turn_limit_seconds()) + Duration::from_secs(120);
    let expires_at = Utc::now() + chrono::Duration::from_std(lasts).unwrap_or_else(|_| chrono::Duration::minutes(10));
    let ticket = json!({"botId": bot_id, "apps": apps, "ownerAsked": from_owner, "expiresAt": expires_at.to_rfc3339_opts(chrono::SecondsFormat::Secs, true)});
    let safe_bot_id: String = bot_id.chars().map(|c| if c.is_ascii_alphanumeric() || c == '-' { c } else { '_' }).take(40).collect();
    let file = match fixed_name {
        Some(name) => folder.join(name),
        None => folder.join(format!("{safe_bot_id}-{}.json", uuid::Uuid::new_v4().simple())),
    };
    crate::store::write_atomic(&file, &serde_json::to_vec(&ticket).unwrap_or_default()).map_err(|error| format!("Couldn't write the ticket: {error}"))?;
    crate::paths::make_private(&file);
    Ok(file)
}

/// The command that runs the hub as this turn's MCP server.
fn serve_command(harness: &Harness, helper: &Path, ticket: &Path) -> (String, Vec<String>) {
    let mut arguments = common_arguments(harness);
    arguments.extend(["serve".to_string(), "--ticket".to_string(), ticket.to_string_lossy().to_string()]);
    (helper.to_string_lossy().to_string(), arguments)
}

/// Works out a bot turn's apps: which go straight to Claude Code, which go through the hub, the rules, the ticket and the
/// engine's config. `turn_folder` is the turn's own folder (removed when it ends) for the MCP config file.
pub async fn wire_turn(harness: &Harness, bot: &crate::model::Bot, from_owner: bool, turn_folder: &Path) -> Result<TurnApps, String> {
    // API-key bots call the hub themselves, tool by tool (`apichat::Toolbox`).
    if bot.provider.starts_with("api:") {
        return Ok(TurnApps::default());
    }
    let mut turn = TurnApps::default();
    if bot.apps.is_empty() {
        return Ok(turn);
    }
    let still_moving = !harness.settings.bool(MOVED_ONTO_HUB_SETTING);
    let bot = if still_moving && has_old_app_names(harness, bot) { move_bot_onto_hub(harness, bot.clone()).await? } else { bot.clone() };
    let apps = match harness.with(|state| state.hub_apps.clone()) {
        apps if bot.apps.iter().all(|id| apps.iter().any(|app| app_id(app) == id)) => apps,
        _ => list_apps(harness).await?,
    };
    let is_claude = bot.provider == "claude";
    let mut through_hub: BTreeMap<String, String> = BTreeMap::new();
    for id in &bot.apps {
        let Some(app) = apps.iter().find(|app| app_id(app) == id) else { continue };
        if !app_is_enabled(app) {
            continue;
        }
        let level = level_for_turn(&level_of(&bot, id), from_owner);
        let name = app.get("name").and_then(Value::as_str).unwrap_or(id).to_string();
        turn.named.push((name, level.to_string()));
        match (is_claude, app_kind(app), app_server(app)) {
            (true, "claude-account", Some(server)) => {
                let (allow, deny) = direct_rules(harness, id, server, level).await;
                turn.allow.extend(allow);
                turn.deny.extend(deny);
            }
            _ => {
                through_hub.insert(id.clone(), level.to_string());
            }
        }
    }
    if through_hub.is_empty() {
        return Ok(turn);
    }
    let helper = helper_path().ok_or_else(missing_helper_message)?;
    let fixed_name = (bot.provider == "grok").then_some(GROK_TICKET_NAME);
    let ticket = write_ticket(harness, &bot.id, &through_hub, from_owner, fixed_name)?;
    turn.ticket = Some(ticket.clone());
    turn.through_hub = through_hub.clone();
    let (command, arguments) = serve_command(harness, &helper, &ticket);
    turn.launch = Some(HubLaunch { command: command.clone(), arguments: arguments.clone(), environment: helper_environment(harness) });
    let environment: serde_json::Map<String, Value> = helper_environment(harness).into_iter().map(|(name, value)| (name, Value::String(value))).collect();
    if !is_claude && bot.provider != "opencode" {
        // Codex, Cursor, Gemini and Grok: each engine's own config shape is written by the harness from `launch`.
        return Ok(turn);
    }
    if is_claude {
        let config = json!({"mcpServers": {HUB_SERVER_NAME: {"type": "stdio", "command": command, "args": arguments, "env": environment}}});
        let file = turn_folder.join("mcp.json");
        std::fs::create_dir_all(turn_folder)
            .and_then(|_| std::fs::write(&file, serde_json::to_vec_pretty(&config).unwrap_or_default()))
            .map_err(|error| format!("Couldn't write the bot's apps for its engine: {error}"))?;
        turn.claude_mcp_config = Some(file);
        // The hub only offers and only runs what the ticket allows, so the whole server is allowed here.
        turn.allow.push(format!("mcp__{HUB_SERVER_NAME}"));
    } else {
        let mut command_line = vec![command];
        command_line.extend(arguments);
        turn.opencode_config = Some(json!({"mcp": {HUB_SERVER_NAME: {"type": "local", "command": command_line, "enabled": true, "environment": environment}}}).to_string());
    }
    Ok(turn)
}

/// Claude Code's own rules for a claude-account app: each tool the level allows, by name, and a deny for each one it
/// doesn't, so an allow rule in the owner's own Claude settings can't open it. An app whose tools Theo doesn't know can
/// only be allowed whole, which only `full` gets.
async fn direct_rules(harness: &Harness, app_id: &str, server: &str, level: &str) -> (Vec<String>, Vec<String>) {
    let Some(server_rule) = crate::connectors::tool_rule(server) else { return (vec![], vec![]) };
    let tools = tools_of(harness, app_id).await.unwrap_or_default();
    let named: Vec<(String, String)> = tools
        .iter()
        .filter_map(|tool| Some((tool.get("name")?.as_str()?.to_string(), tool.get("effect")?.as_str()?.to_string())))
        .filter(|(name, _)| name != "ask")
        .collect();
    if named.is_empty() {
        return if level == "full" { (vec![server_rule], vec![]) } else { (vec![], vec![server_rule]) };
    }
    let (mut allow, mut deny) = (vec![], vec![]);
    for (name, effect) in named {
        let rule = format!("{server_rule}__{name}");
        if effect_allowed(&effect, level) { allow.push(rule) } else { deny.push(rule) }
    }
    (allow, deny)
}

// MARK: The hub in each engine's own config

/// A TOML basic string: quotes and backslashes escaped, control characters as escapes.
pub fn toml_string(text: &str) -> String {
    let mut escaped = String::from("\"");
    for character in text.chars() {
        match character {
            '\\' => escaped.push_str("\\\\"),
            '"' => escaped.push_str("\\\""),
            '\n' => escaped.push_str("\\n"),
            '\r' => escaped.push_str("\\r"),
            '\t' => escaped.push_str("\\t"),
            c if (c as u32) < 0x20 || c as u32 == 0x7f => escaped.push_str(&format!("\\u{:04X}", c as u32)),
            c => escaped.push(c),
        }
    }
    escaped.push('"');
    escaped
}

/// Codex takes config overrides per run (`-c key=value`, the value read as TOML), which never touch `~/.codex/config.toml`.
/// Tool calls are approved up front: nobody is there to approve them, and the hub decides what the bot may run.
pub fn codex_arguments(launch: &HubLaunch) -> Vec<String> {
    let name = SHARED_HUB_SERVER_NAME;
    let mut overrides = vec![
        format!("mcp_servers.{name}.command={}", toml_string(&launch.command)),
        format!("mcp_servers.{name}.args=[{}]", launch.arguments.iter().map(|argument| toml_string(argument)).collect::<Vec<_>>().join(",")),
        format!("mcp_servers.{name}.default_tools_approval_mode=\"approve\""),
    ];
    if !launch.environment.is_empty() {
        let pairs: Vec<String> = launch.environment.iter().map(|(key, value)| format!("{key}={}", toml_string(value))).collect();
        overrides.push(format!("mcp_servers.{name}.env={{{}}}", pairs.join(",")));
    }
    overrides.into_iter().flat_map(|value| ["-c".to_string(), value]).collect()
}

fn stdio_server(launch: &HubLaunch) -> Value {
    let environment: serde_json::Map<String, Value> = launch.environment.iter().map(|(key, value)| (key.clone(), Value::String(value.clone()))).collect();
    json!({"type": "stdio", "command": launch.command, "args": launch.arguments, "env": environment})
}

/// Cursor Agent reads `.cursor/mcp.json` in the folder it works in: Theo's own bots folder, never the owner's projects.
pub fn cursor_mcp_file(launch: &HubLaunch) -> String {
    serde_json::to_string_pretty(&json!({"mcpServers": {SHARED_HUB_SERVER_NAME: stdio_server(launch)}})).unwrap_or_default()
}

/// Gemini CLI's `.gemini/settings.json` in the folder it works in (Theo's own bots folder), read with that folder trusted
/// for the run (`GEMINI_CLI_TRUST_WORKSPACE=true`; an untrusted folder gets no MCP servers at all). `trust` lets the hub's
/// tools run in a headless turn: the hub decides what may run.
pub fn gemini_settings(launch: &HubLaunch) -> String {
    let mut server = stdio_server(launch);
    server["trust"] = json!(true);
    serde_json::to_string_pretty(&json!({"mcpServers": {SHARED_HUB_SERVER_NAME: server}})).unwrap_or_default()
}

/// The hub's entry in Grok's own config.
pub fn grok_config_block(launch: &HubLaunch) -> String {
    let name = SHARED_HUB_SERVER_NAME;
    let mut block = format!(
        "\n[mcp_servers.{name}]\ncommand = {}\nargs = [{}]\nenabled = true\n",
        toml_string(&launch.command),
        launch.arguments.iter().map(|argument| toml_string(argument)).collect::<Vec<_>>().join(", ")
    );
    if !launch.environment.is_empty() {
        block.push_str(&format!("[mcp_servers.{name}.env]\n"));
        for (key, value) in &launch.environment {
            block.push_str(&format!("{key} = {}\n", toml_string(value)));
        }
    }
    block
}

/// Puts the hub's entry into a Grok config text, replacing an older entry of ours (from before Theo moved), and leaves
/// everything else as it was. Returns None when it is already there as it should be.
pub fn grok_config_with_hub(current: &str, launch: &HubLaunch) -> Option<String> {
    let block = grok_config_block(launch);
    if current.contains(&block) {
        return None;
    }
    let header = format!("[mcp_servers.{SHARED_HUB_SERVER_NAME}");
    let mut kept: Vec<&str> = vec![];
    let mut inside_ours = false;
    for line in current.split('\n') {
        let trimmed = line.trim();
        if trimmed.starts_with('[') {
            inside_ours = trimmed.starts_with(&format!("{header}]")) || trimmed.starts_with(&format!("{header}."));
        }
        if !inside_ours {
            kept.push(line);
        }
    }
    let mut updated = kept.join("\n");
    while updated.ends_with("\n\n") {
        updated.pop();
    }
    Some(updated + &block)
}

/// Cursor, Gemini and Grok read the hub's server from a file all their runs share, so only one of their turns with apps
/// runs at a time per engine: another waits for it, and gets its own ticket.
pub fn shared_config_lock(engine: &str) -> std::sync::Arc<tokio::sync::Mutex<()>> {
    static LOCKS: once_cell::sync::Lazy<std::sync::Mutex<std::collections::HashMap<String, std::sync::Arc<tokio::sync::Mutex<()>>>>> = once_cell::sync::Lazy::new(Default::default);
    LOCKS.lock().unwrap().entry(engine.to_string()).or_default().clone()
}

// MARK: Signing in

/// Starts `signin` for an app and returns the address to open as soon as the hub prints it. The rest runs on: when the
/// browser comes back the result lands in `state.sign_ins`, which the Connectors page reads. In a test profile the
/// address is written to `Logs/opened.log` instead of opening a browser.
pub async fn start_sign_in(harness: &std::sync::Arc<Harness>, app_id: &str) -> Result<String, String> {
    use tokio::io::AsyncBufReadExt;
    let helper = helper_path().ok_or_else(missing_helper_message)?;
    let mut command = engine::background_command(&helper);
    command
        .args(common_arguments(harness))
        .args(["signin", app_id, "--timeout", &SIGN_IN_LIMIT_SECONDS.to_string()])
        .envs(helper_environment(harness))
        .current_dir(&harness.paths.root)
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::null())
        .kill_on_drop(true);
    let mut child = command.spawn().map_err(|error| format!("Theo's connector helper couldn't start: {error}"))?;
    let stdout = child.stdout.take().ok_or("Theo's connector helper gave no answer.")?;
    let mut lines = tokio::io::BufReader::new(stdout).lines();
    let first = tokio::time::timeout(Duration::from_secs(60), lines.next_line())
        .await
        .map_err(|_| "The sign-in didn't start in time.".to_string())?
        .map_err(|error| error.to_string())?
        .and_then(|line| serde_json::from_str::<Value>(&line).ok())
        .ok_or("The sign-in didn't start.")?;
    if first.get("ok").and_then(Value::as_bool) == Some(false) {
        return Err(first.get("error").and_then(Value::as_str).unwrap_or("The sign-in didn't start.").to_string());
    }
    let address = first.get("url").and_then(Value::as_str).ok_or("The sign-in didn't say where to go.")?.to_string();
    harness.with(|state| {
        state.sign_ins.insert(app_id.to_string(), json!({"state": "waiting", "url": address, "since": Utc::now().to_rfc3339()}));
    });
    open_in_browser(harness, &address);
    let harness = harness.clone();
    let app_id = app_id.to_string();
    tokio::spawn(async move {
        let limit = Duration::from_secs(SIGN_IN_LIMIT_SECONDS + 15);
        let result = tokio::time::timeout(limit, async {
            let mut last = None;
            while let Ok(Some(line)) = lines.next_line().await {
                if let Ok(value) = serde_json::from_str::<Value>(&line) {
                    last = Some(value);
                }
            }
            last
        })
        .await
        .ok()
        .flatten();
        let _ = child.kill().await;
        let outcome = match result {
            Some(answer) if answer.get("ok").and_then(Value::as_bool) == Some(true) => json!({"state": "done", "status": answer.get("status").cloned().unwrap_or(Value::Null), "at": Utc::now().to_rfc3339()}),
            Some(answer) => json!({"state": "failed", "error": answer.get("error").and_then(Value::as_str).unwrap_or("The sign-in didn't finish."), "at": Utc::now().to_rfc3339()}),
            None => json!({"state": "failed", "error": "The sign-in didn't finish in time.", "at": Utc::now().to_rfc3339()}),
        };
        harness.with(|state| {
            state.sign_ins.insert(app_id.clone(), outcome);
        });
        forget_kept_tools(&harness);
        let _ = list_apps(&harness).await;
    });
    Ok(address)
}

/// Opens an address in the owner's browser. A test profile records it in `Logs/opened.log` instead (one address a line), so
/// a test can play the browser.
pub fn open_in_browser(harness: &Harness, address: &str) {
    if !(address.starts_with("https://") || address.starts_with("http://")) {
        return;
    }
    if harness.settings.is_test {
        let folder = harness.paths.logs_dir();
        let _ = std::fs::create_dir_all(&folder);
        use std::io::Write;
        if let Ok(mut file) = std::fs::OpenOptions::new().create(true).append(true).open(folder.join("opened.log")) {
            let _ = writeln!(file, "{address}");
        }
        return;
    }
    // rundll32 hands the address to the default browser without going through cmd.exe, which would cut it at each "&".
    #[cfg(windows)]
    let opener = ("rundll32", vec!["url.dll,FileProtocolHandler", address]);
    #[cfg(target_os = "macos")]
    let opener = ("open", vec![address]);
    #[cfg(all(unix, not(target_os = "macos")))]
    let opener = ("xdg-open", vec![address]);
    let mut command = std::process::Command::new(opener.0);
    command.args(&opener.1).stdin(std::process::Stdio::null()).stdout(std::process::Stdio::null()).stderr(std::process::Stdio::null());
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        command.creation_flags(0x0800_0000);
    }
    let _ = command.spawn();
}

// MARK: The page

/// Each app as the Connectors page shows it: the hub's entry, the fields the page had before the hub (`server`, `target`,
/// `lastConnected`), which bots may use it and at what level, and a sign-in under way.
pub fn page_report(harness: &Harness) -> Value {
    let (apps, checked, note, sign_ins) = harness.with(|state| (state.hub_apps.clone(), state.connectors_checked, state.claude_code_note.clone(), state.sign_ins.clone()));
    let bots = harness.bots();
    let shown: Vec<Value> = apps
        .into_iter()
        .map(|mut app| {
            let id = app_id(&app).to_string();
            let target = app.get("url").or_else(|| app.get("server")).and_then(Value::as_str).map(str::to_string).or_else(|| app.get("command").and_then(Value::as_str).map(str::to_string)).unwrap_or_default();
            let last_worked = app.get("lastWorked").cloned().unwrap_or(Value::Null);
            let users: Vec<Value> = bots.iter().filter(|bot| bot.apps.contains(&id)).map(|bot| json!({"bot": bot.id, "level": level_of(bot, &id)})).collect();
            if let Some(entry) = app.as_object_mut() {
                entry.insert("target".into(), Value::String(target));
                entry.insert("lastConnected".into(), last_worked);
                entry.insert("bots".into(), Value::Array(users));
                if let Some(sign_in) = sign_ins.get(&id) {
                    entry.insert("signIn".into(), sign_in.clone());
                }
            }
            app
        })
        .collect();
    json!({"connectors": shown, "checked": checked.map(|time| time.to_rfc3339()), "claudeCode": harness.executable("claude").is_some(), "note": note, "helper": helper_path().is_some()})
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ids_for_old_claude_server_names() {
        assert_eq!(id_for_server("claude.ai Gmail"), "gmail");
        assert_eq!(id_for_server("claude.ai Hostinger Connector"), "hostinger-connector");
        assert_eq!(id_for_server("theo-echo"), "theo-echo");
        assert_eq!(id_for_server("plugin:theo:theo"), "plugin-theo-theo");
        assert_eq!(id_for_server("claude.ai Runway (runway.team)"), "runway-runway-team");
        assert_eq!(id_for_server("!!!"), "claude-app");
        assert!(is_app_id(&id_for_server("claude.ai A Very Long Name That Goes On And On Forever And Ever")));
    }

    #[test]
    fn ids_follow_the_hubs_rule() {
        assert!(is_app_id("gmail"));
        assert!(is_app_id("theo-echo"));
        assert!(!is_app_id("claude.ai Gmail"));
        assert!(!is_app_id("Gmail"));
        assert!(!is_app_id(""));
        assert!(!is_app_id("-x"));
    }

    #[test]
    fn free_ids_never_collide() {
        let taken = vec!["gmail".to_string(), "gmail-2".to_string()];
        assert_eq!(free_id("gmail", &taken), "gmail-3");
        assert_eq!(free_id("notion", &taken), "notion");
    }

    #[test]
    fn turns_not_from_the_owner_only_read() {
        assert_eq!(level_for_turn("full", true), "full");
        assert_eq!(level_for_turn("readAndDraft", true), "readAndDraft");
        assert_eq!(level_for_turn("read", true), "read");
        assert_eq!(level_for_turn("full", false), "read");
        assert_eq!(level_for_turn("readAndDraft", false), "read");
        assert_eq!(level_for_turn("nonsense", true), "readAndDraft");
    }

    #[test]
    fn levels_match_the_hubs_table() {
        assert!(effect_allowed("read", "read"));
        assert!(!effect_allowed("change", "read"));
        assert!(effect_allowed("change", "readAndDraft"));
        assert!(!effect_allowed("irreversible", "readAndDraft"));
        assert!(effect_allowed("irreversible", "full"));
    }

    #[test]
    fn the_last_json_line_is_the_answer() {
        assert_eq!(last_json_line("noise\n{\"ok\":true,\"a\":1}\n\n").unwrap()["a"], 1);
        assert!(last_json_line("nothing here").is_none());
    }
}
