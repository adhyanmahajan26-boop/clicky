//! `theo-connectors`: the command line the Mac and Windows apps use to reach the hub. Every command prints one JSON
//! object on one line (`signin` prints two: where to open, then the result). Failures print `{"ok":false,"error":"…"}`
//! and exit with 1. See `crossplatform/docs/CONNECTORS.md`.

use serde_json::{json, Value};
use std::io::Read;
use std::path::PathBuf;
use std::time::Duration;

use theo_connectors::catalog::{catalog_entry, load_catalog};
use theo_connectors::claude_account::claude_code_servers;
use theo_connectors::hub::{AppConnection, Hub};
use theo_connectors::mcp_client::McpSession;
use theo_connectors::model::{now_rfc3339, AppEntry, AppKind, AppStatus, ConnectorList, ConnectorState, RemoteSignIn};
use theo_connectors::oauth;
use theo_connectors::serve::{effect_words, exposed_tool_name, level_words, serve};
use theo_connectors::ticket::{issue_ticket, load_ticket, remove_stale_tickets, revoke_ticket, Ticket};
use theo_connectors::vault::KeyStore;

const USAGE: &str = "usage: theo-connectors --data <Theo's data folder> [--key-store system|file] <command>
commands:
  catalog                                   the starter catalog
  list [--check]                            every app with its status
  add --json '<app>' | --catalog <id>       add an app (then checks it, unless --no-check)
  remove <id> | enable <id> | disable <id>  change the list
  set-secret <id> [--env NAME | --client-secret]
                                            store a secret read from standard input (empty input removes it)
  signin <id> [--timeout <seconds>]         sign in to an OAuth app in the browser
  signout <id>                              forget the app's tokens
  check [<id>]                              reconnect and refresh the status
  tools <id>                                the app's tools, each with what it does
  call <id> <tool> --args '<json>' --ticket <file>
                                            run one tool for a bot
  serve --ticket <file>                     an MCP server on standard input and output, for one bot turn
  ticket issue --json '<ticket>' | ticket revoke <file>
  discover-claude                           the apps Claude Code has, as claude-account entries to add";

struct CommandLine {
    data_folder: Option<PathBuf>,
    key_store: KeyStore,
    words: Vec<String>,
}

impl CommandLine {
    fn parse(raw_arguments: Vec<String>) -> Result<CommandLine, String> {
        let mut data_folder = std::env::var_os("THEO_DATA").filter(|value| !value.is_empty()).map(PathBuf::from);
        let mut key_store = std::env::var("THEO_CONNECTORS_KEY_STORE").ok().and_then(|text| KeyStore::parse(&text)).unwrap_or(KeyStore::System);
        let mut words = vec![];
        let mut arguments = raw_arguments.into_iter();
        while let Some(argument) = arguments.next() {
            match argument.as_str() {
                "--data" => data_folder = Some(PathBuf::from(arguments.next().ok_or("--data needs a folder")?)),
                "--key-store" => {
                    let text = arguments.next().ok_or("--key-store needs system or file")?;
                    key_store = KeyStore::parse(&text).ok_or("--key-store is system or file")?;
                }
                _ => words.push(argument),
            }
        }
        Ok(CommandLine { data_folder, key_store, words })
    }

    fn option(&self, name: &str) -> Option<String> {
        self.words.iter().position(|word| word == name).and_then(|index| self.words.get(index + 1).cloned())
    }

    fn flag(&self, name: &str) -> bool {
        self.words.iter().any(|word| word == name)
    }

    /// The words that aren't options or option values, after the command.
    fn positional(&self, index: usize) -> Option<String> {
        let options_with_values = ["--json", "--catalog", "--env", "--timeout", "--args", "--ticket", "--id"];
        let mut positional_words = vec![];
        let mut skip_next = false;
        for word in self.words.iter().skip(1) {
            if skip_next {
                skip_next = false;
                continue;
            }
            if options_with_values.contains(&word.as_str()) {
                skip_next = true;
                continue;
            }
            if word.starts_with("--") {
                continue;
            }
            positional_words.push(word.clone());
        }
        positional_words.get(index).cloned()
    }
}

fn print_line(value: &Value) {
    println!("{value}");
}

fn main() {
    let outcome = run(std::env::args().skip(1).collect());
    match outcome {
        Ok(Some(answer)) => print_line(&answer),
        Ok(None) => {}
        Err(error) => {
            print_line(&json!({"ok": false, "error": error}));
            std::process::exit(1);
        }
    }
}

fn run(raw_arguments: Vec<String>) -> Result<Option<Value>, String> {
    let command_line = CommandLine::parse(raw_arguments)?;
    let Some(command) = command_line.words.first().cloned() else { return Err(USAGE.into()) };
    if command == "catalog" {
        return Ok(Some(json!({"ok": true, "catalog": load_catalog()})));
    }
    if command == "help" || command == "--help" {
        println!("{USAGE}");
        return Ok(None);
    }
    let data_folder = command_line.data_folder.clone().ok_or("Say where Theo's data folder is with --data <folder>.")?;
    let hub = Hub::new(data_folder, command_line.key_store);
    let app_id_argument = || command_line.positional(0).ok_or_else(|| format!("{command} needs an app id."));

    match command.as_str() {
        "list" => {
            if command_line.flag("--check") {
                check_apps(&hub, None)?;
            }
            Ok(Some(json!({"ok": true, "apps": hub.listing()?})))
        }
        "add" => add_app(&hub, &command_line),
        "remove" => {
            let app_id = app_id_argument()?;
            ConnectorList::change(&hub.paths, |list| {
                let count_before = list.apps.len();
                list.apps.retain(|app| app.id != app_id);
                if list.apps.len() == count_before {
                    return Err(format!("There's no app called \"{app_id}\"."));
                }
                Ok(())
            })?;
            hub.vault.forget(&app_id)?;
            ConnectorState::forget(&hub.paths, &app_id);
            Ok(Some(json!({"ok": true, "removed": app_id})))
        }
        "enable" | "disable" => {
            let app_id = app_id_argument()?;
            let turn_on = command == "enable";
            ConnectorList::change(&hub.paths, |list| {
                let app = list.apps.iter_mut().find(|app| app.id == app_id).ok_or_else(|| format!("There's no app called \"{app_id}\"."))?;
                app.enabled = turn_on;
                Ok(())
            })?;
            Ok(Some(json!({"ok": true, "app": app_id, "enabled": turn_on})))
        }
        "set-secret" => {
            let app_id = app_id_argument()?;
            let entry = hub.app(&app_id)?;
            let mut secret_value = String::new();
            std::io::stdin().read_to_string(&mut secret_value).map_err(|error| format!("Couldn't read the secret from standard input: {error}"))?;
            let secret_value = secret_value.trim().to_string();
            let mut secrets = hub.vault.read(&app_id);
            let what = if let Some(variable_name) = command_line.option("--env") {
                if entry.kind != AppKind::Local {
                    return Err("Secret settings (--env) are for local apps.".into());
                }
                if secret_value.is_empty() {
                    secrets.secret_environment.remove(&variable_name);
                } else {
                    secrets.secret_environment.insert(variable_name.clone(), secret_value);
                }
                format!("env {variable_name}")
            } else if command_line.flag("--client-secret") {
                secrets.owner_client_secret = Some(secret_value).filter(|value| !value.is_empty());
                "client secret".to_string()
            } else {
                if entry.kind != AppKind::Remote || entry.auth != RemoteSignIn::PastedToken {
                    return Err("A pasted token is for remote apps whose auth is \"token\".".into());
                }
                secrets.pasted_token = Some(secret_value).filter(|value| !value.is_empty());
                "token".to_string()
            };
            hub.vault.write(&app_id, &secrets)?;
            Ok(Some(json!({"ok": true, "app": app_id, "saved": what})))
        }
        "signin" => sign_in(&hub, &app_id_argument()?, &command_line),
        "signout" => {
            let app_id = app_id_argument()?;
            let entry = hub.app(&app_id)?;
            let mut secrets = hub.vault.read(&app_id);
            secrets.pasted_token = None;
            if let Some(record) = secrets.oauth.as_mut() {
                record.tokens = None;
            }
            hub.vault.write(&app_id, &secrets)?;
            if entry.kind == AppKind::Remote && entry.auth != RemoteSignIn::Nothing {
                ConnectorState::record(&hub.paths, &app_id, |record| {
                    record.status = Some(AppStatus::NeedsSignIn);
                    record.reason = None;
                    record.last_checked = Some(now_rfc3339());
                });
            }
            Ok(Some(json!({"ok": true, "app": app_id, "status": "needsSignIn"})))
        }
        "check" => {
            let results = check_apps(&hub, command_line.positional(0))?;
            Ok(Some(json!({"ok": true, "apps": results})))
        }
        "tools" => {
            let app_id = app_id_argument()?;
            let entry = hub.app(&app_id)?;
            let tools = hub.connect(&entry).and_then(|mut connection| hub.tools_of(&mut connection));
            match tools {
                Ok(tools) => {
                    hub.record_worked(&app_id, Some(tools.len()));
                    let listed: Vec<Value> = tools
                        .iter()
                        .map(|tool| {
                            let mut item = serde_json::to_value(tool).unwrap_or(Value::Null);
                            item["exposedName"] = Value::String(exposed_tool_name(&app_id, &tool.name));
                            item
                        })
                        .collect();
                    Ok(Some(json!({"ok": true, "app": app_id, "tools": listed})))
                }
                Err(error) => {
                    hub.record_reach_error(&app_id, &error);
                    Err(error.sentence(&entry.name))
                }
            }
        }
        "call" => call_tool(&hub, &command_line),
        "serve" => {
            let ticket_file = command_line.option("--ticket").ok_or("serve needs --ticket <file>.")?;
            serve(hub, PathBuf::from(ticket_file))?;
            Ok(None)
        }
        "ticket" => match command_line.positional(0).as_deref() {
            Some("issue") => {
                let ticket_text = command_line.option("--json").ok_or("ticket issue needs --json '<ticket>'.")?;
                let ticket: Ticket = serde_json::from_str(&ticket_text).map_err(|error| format!("That ticket isn't valid: {error}"))?;
                remove_stale_tickets(&hub.paths);
                let ticket_file = issue_ticket(&hub.paths, &ticket)?;
                Ok(Some(json!({"ok": true, "ticket": ticket_file})))
            }
            Some("revoke") => {
                let ticket_file = command_line.positional(1).ok_or("ticket revoke needs the ticket's file.")?;
                revoke_ticket(&hub.paths, std::path::Path::new(&ticket_file))?;
                Ok(Some(json!({"ok": true})))
            }
            _ => Err("ticket issue --json '<ticket>' or ticket revoke <file>".into()),
        },
        "discover-claude" => {
            let servers = claude_code_servers()?;
            let catalog = load_catalog();
            let suggestions: Vec<Value> = servers
                .iter()
                .map(|server| {
                    let from_catalog = catalog.apps.iter().filter(|entry| entry.app.kind == AppKind::ClaudeAccount && entry.app.server.as_deref() == Some(server.server.as_str())).map(|entry| entry.app.id.clone()).collect::<Vec<_>>();
                    json!({
                        "server": server.server,
                        "target": server.target,
                        "status": server.status,
                        "catalogIds": from_catalog,
                        "suggestedId": suggested_app_id(&server.server),
                        "name": server.server.strip_prefix("claude.ai ").unwrap_or(&server.server),
                    })
                })
                .collect();
            Ok(Some(json!({"ok": true, "servers": suggestions})))
        }
        _ => Err(format!("Unknown command {command}.\n{USAGE}")),
    }
}

/// "claude.ai Hostinger Connector" → "hostinger-connector".
fn suggested_app_id(server: &str) -> String {
    let name = server.strip_prefix("claude.ai ").unwrap_or(server).to_lowercase();
    let mut app_id = String::new();
    for character in name.chars() {
        if character.is_ascii_alphanumeric() {
            app_id.push(character);
        } else if !app_id.ends_with('-') && !app_id.is_empty() {
            app_id.push('-');
        }
    }
    app_id.trim_end_matches('-').chars().take(40).collect::<String>().trim_end_matches('-').to_string()
}

/// Keys that look like a secret, refused in `add` so a token never lands in the list file.
fn looks_like_a_secret_field(field_name: &str) -> bool {
    let lowercase_name = field_name.to_lowercase();
    ["token", "secret", "password", "apikey", "api_key", "credential"].iter().any(|word| lowercase_name.contains(word))
}

fn add_app(hub: &Hub, command_line: &CommandLine) -> Result<Option<Value>, String> {
    let mut entry: AppEntry = if let Some(catalog_id) = command_line.option("--catalog") {
        let mut app_from_catalog = catalog_entry(&catalog_id).ok_or_else(|| format!("The catalog has no app called \"{catalog_id}\"."))?.app;
        app_from_catalog.catalog_id = Some(catalog_id);
        app_from_catalog
    } else {
        let entry_text = command_line.option("--json").ok_or("add needs --json '<app>' or --catalog <id>.")?;
        let entry_value: Value = serde_json::from_str(&entry_text).map_err(|error| format!("That app isn't valid JSON: {error}"))?;
        if let Some(secret_field) = entry_value.as_object().and_then(|object| object.keys().find(|key| looks_like_a_secret_field(key)).cloned()) {
            return Err(format!("Secrets don't go in the list of apps (\"{secret_field}\"). Add the app, then use set-secret, which reads the secret from standard input."));
        }
        if let Some(environment) = entry_value.get("env").and_then(Value::as_object) {
            if let Some(secret_variable) = environment.keys().find(|key| looks_like_a_secret_field(key)) {
                return Err(format!("\"{secret_variable}\" looks like a secret. Add the app without it, then use set-secret {} --env {secret_variable}.", entry_value.get("id").and_then(Value::as_str).unwrap_or("<id>")));
            }
        }
        serde_json::from_value(entry_value).map_err(|error| format!("That app isn't valid: {error}"))?
    };
    if let Some(new_app_id) = command_line.option("--id") {
        entry.id = new_app_id;
    }
    entry.validate()?;
    let entry_for_list = entry.clone();
    ConnectorList::change(&hub.paths, move |list| {
        if list.app(&entry_for_list.id).is_some() {
            return Err(format!("There's already an app called \"{}\".", entry_for_list.id));
        }
        list.apps.push(entry_for_list);
        Ok(())
    })?;
    if command_line.flag("--no-check") {
        return Ok(Some(json!({"ok": true, "app": entry.id, "status": "unknown"})));
    }
    let (status, reason, tool_count) = hub.check(&entry);
    Ok(Some(json!({"ok": true, "app": entry.id, "status": status, "reason": reason, "toolCount": tool_count})))
}

fn check_apps(hub: &Hub, only_app_id: Option<String>) -> Result<Vec<Value>, String> {
    let list = hub.load_list()?;
    let entries: Vec<AppEntry> = match &only_app_id {
        Some(app_id) => vec![list.app(app_id).cloned().ok_or_else(|| format!("There's no app called \"{app_id}\"."))?],
        None => list.apps.clone(),
    };
    let claude_account_entries: Vec<AppEntry> = entries.iter().filter(|entry| entry.enabled && entry.kind == AppKind::ClaudeAccount).cloned().collect();
    let mut claude_account_outcomes = if claude_account_entries.is_empty() { vec![] } else { hub.check_claude_account_apps(&claude_account_entries) };
    let mut results = vec![];
    for entry in &entries {
        let (status, reason, tool_count) = if entry.enabled && entry.kind == AppKind::ClaudeAccount {
            let position = claude_account_outcomes.iter().position(|(app_id, _)| *app_id == entry.id);
            position.map(|index| claude_account_outcomes.remove(index).1).unwrap_or((AppStatus::Unknown, None, None))
        } else {
            hub.check(entry)
        };
        results.push(json!({"id": entry.id, "status": status, "reason": reason, "toolCount": tool_count}));
    }
    Ok(results)
}

fn sign_in(hub: &Hub, app_id: &str, command_line: &CommandLine) -> Result<Option<Value>, String> {
    let entry = hub.app(app_id)?;
    if entry.kind != AppKind::Remote || entry.auth != RemoteSignIn::OAuth {
        return Err(match entry.kind {
            AppKind::ClaudeAccount => format!("{} is connected through your Claude account: sign in to it on claude.ai.", entry.name),
            _ => format!("{} doesn't sign in in the browser.", entry.name),
        });
    }
    let server_address = entry.url.clone().unwrap_or_default();
    // An unauthenticated request tells us where to sign in (MCP's 401 with resource_metadata).
    let challenge = match McpSession::connect_http(&server_address, None, Duration::from_secs(20)) {
        Err(theo_connectors::mcp_client::McpError::NeedsSignIn { www_authenticate: Some(header) }) => oauth::parse_www_authenticate(&header),
        _ => oauth::WwwAuthenticateChallenge::default(),
    };
    let mut server = oauth::discover_authorization_server(&server_address, &challenge)?;
    if let Some(scopes) = entry.oauth.as_ref().and_then(|settings| settings.scopes.clone()) {
        server.scopes_to_ask_for = Some(scopes.join(" ")).filter(|scopes| !scopes.is_empty());
    }
    let pending_sign_in = oauth::begin_sign_in(&entry, &hub.vault, server)?;
    print_line(&json!({"event": "open", "app": app_id, "url": pending_sign_in.address_to_open}));
    let wait_at_most = Duration::from_secs(command_line.option("--timeout").and_then(|text| text.parse().ok()).unwrap_or(300));
    if let Err(error) = pending_sign_in.finish(app_id, &hub.vault, wait_at_most) {
        ConnectorState::record(&hub.paths, app_id, |record| {
            record.status = Some(AppStatus::NeedsSignIn);
            record.reason = None;
            record.last_checked = Some(now_rfc3339());
        });
        return Err(error);
    }
    let (status, reason, tool_count) = hub.check(&entry);
    Ok(Some(json!({"ok": true, "event": "done", "app": app_id, "status": status, "reason": reason, "toolCount": tool_count})))
}

fn call_tool(hub: &Hub, command_line: &CommandLine) -> Result<Option<Value>, String> {
    let app_id = command_line.positional(0).ok_or("call needs an app id and a tool.")?;
    let tool_name = command_line.positional(1).ok_or("call needs a tool name.")?;
    let ticket_file = command_line.option("--ticket").ok_or("call needs --ticket <file>: tools only run for a bot's turn.")?;
    let arguments: Value = match command_line.option("--args") {
        Some(text) => serde_json::from_str(&text).map_err(|error| format!("--args isn't valid JSON: {error}"))?,
        None => json!({}),
    };
    if !arguments.is_object() {
        return Err("--args must be a JSON object.".into());
    }
    let ticket = load_ticket(&hub.paths, std::path::Path::new(&ticket_file))?;
    let entry = hub.app(&app_id)?;
    let level = ticket.level_for(&app_id).ok_or_else(|| format!("This bot wasn't given {}.", entry.name))?;
    let mut connection: AppConnection = match hub.connect(&entry) {
        Ok(connection) => connection,
        Err(error) => {
            hub.record_reach_error(&app_id, &error);
            return Err(error.sentence(&entry.name));
        }
    };
    let tools = match hub.tools_of(&mut connection) {
        Ok(tools) => tools,
        Err(error) => {
            hub.record_reach_error(&app_id, &error);
            return Err(error.sentence(&entry.name));
        }
    };
    let tool = tools.iter().find(|tool| tool.name == tool_name).ok_or_else(|| format!("{} has no tool called {tool_name}.", entry.name))?;
    if !level.allows(tool.effect) {
        let why = if ticket.is_held_back_only_because_owner_did_not_ask(&app_id, tool.effect) { " This turn didn't come from the owner's own words, so nothing is sent, shared or deleted." } else { "" };
        return Err(format!("Not allowed: {tool_name} {}, and this bot may {} in {}.{why}", effect_words(tool.effect), level_words(level), entry.name));
    }
    match hub.call_on(&mut connection, &tool_name, arguments, level) {
        Ok(result) => {
            hub.record_worked(&app_id, None);
            Ok(Some(json!({"ok": true, "app": app_id, "tool": tool_name, "result": result})))
        }
        Err(error) => {
            hub.record_reach_error(&app_id, &error);
            Err(error.sentence(&entry.name))
        }
    }
}
