//! `serve --ticket <file>`: the hub as one MCP server on standard input and output, for a command-line brain (Claude
//! Code, Codex, Cursor, Gemini, OpenCode, Grok) during one bot turn.
//!
//! It offers the tools of the apps the ticket names, as `<app id>__<tool>`, leaving out the ones the turn's level
//! doesn't allow. Every call reads the ticket again, so deleting it or letting it expire stops the apps at once, and a
//! call for a tool the level doesn't allow is refused even if the brain asks for it by name.

use serde_json::{json, Value};
use std::collections::HashMap;
use std::io::{BufRead, Write};
use std::path::PathBuf;
use std::sync::{Arc, Mutex};

use crate::hub::{AppConnection, Hub, HubTool, ReachError};
use crate::mcp_client::{LATEST_PROTOCOL_VERSION, SUPPORTED_PROTOCOL_VERSIONS};
use crate::model::{AccessLevel, AppEntry, ToolEffect};
use crate::ticket::{load_ticket, Ticket};

/// The name a brain sees: `<app id>__<tool>`, with anything a brain wouldn't accept in a tool name turned into `_`.
pub fn exposed_tool_name(app_id: &str, tool_name: &str) -> String {
    let cleaned_tool_name: String = tool_name.chars().map(|c| if c.is_ascii_alphanumeric() || c == '_' || c == '-' { c } else { '_' }).collect();
    format!("{app_id}__{cleaned_tool_name}")
}

pub fn effect_words(tool_effect: ToolEffect) -> &'static str {
    match tool_effect {
        ToolEffect::Reads => "only reads",
        ToolEffect::Changes => "changes something",
        ToolEffect::Irreversible => "can't be taken back (it sends, deletes or shares)",
    }
}

pub fn level_words(level: AccessLevel) -> &'static str {
    match level {
        AccessLevel::Read => "only read",
        AccessLevel::ReadAndDraft => "read and draft, but not send, delete or share",
        AccessLevel::Full => "do anything",
    }
}

struct ServerState {
    hub: Hub,
    ticket_file: PathBuf,
    connections: Mutex<HashMap<String, Arc<Mutex<Option<AppConnection>>>>>,
    /// Exposed name → (app id, the app's own tool name, what it does).
    tool_names: Mutex<HashMap<String, (String, String, ToolEffect)>>,
    output: Mutex<std::io::Stdout>,
}

impl ServerState {
    fn send(&self, message: &Value) {
        let mut output = self.output.lock().unwrap();
        let _ = writeln!(output, "{message}");
        let _ = output.flush();
    }

    fn connection_slot(&self, app_id: &str) -> Arc<Mutex<Option<AppConnection>>> {
        self.connections.lock().unwrap().entry(app_id.to_string()).or_insert_with(|| Arc::new(Mutex::new(None))).clone()
    }

    /// Runs `work` on the app's open connection, opening it first if needed. When `may_try_again` and a connection that
    /// was already open turns out to be broken (the app's command stopped, its session expired), it is opened once more
    /// and the work tried again. Only work that can safely run twice may: a call that sends could have gone through
    /// before the connection broke.
    fn with_connection<T>(&self, entry: &AppEntry, may_try_again: bool, work: impl Fn(&Hub, &mut AppConnection) -> Result<T, ReachError>) -> Result<T, ReachError> {
        let slot = self.connection_slot(&entry.id);
        let mut connection_guard = slot.lock().unwrap();
        let connection_was_already_open = connection_guard.is_some();
        if connection_guard.is_none() {
            *connection_guard = Some(self.hub.connect(entry)?);
        }
        let outcome = work(&self.hub, connection_guard.as_mut().unwrap());
        match outcome {
            Err(ReachError::Failed(_)) if may_try_again && connection_was_already_open => {
                *connection_guard = Some(self.hub.connect(entry)?);
                let second_outcome = work(&self.hub, connection_guard.as_mut().unwrap());
                if second_outcome.is_err() {
                    *connection_guard = None;
                }
                second_outcome
            }
            Err(error) => {
                *connection_guard = None;
                Err(error)
            }
            success => success,
        }
    }

    fn current_ticket(&self) -> Result<Ticket, String> {
        load_ticket(&self.hub.paths, &self.ticket_file)
    }

    fn list_tools(&self) -> Value {
        let ticket = match self.current_ticket() {
            Ok(ticket) => ticket,
            Err(_) => return json!({"tools": []}),
        };
        let list = self.hub.load_list().unwrap_or_default();
        let mut offered_tools = vec![];
        for app_id in ticket.apps.keys() {
            let Some(entry) = list.app(app_id).cloned() else { continue };
            let Some(level) = ticket.level_for(app_id) else { continue };
            let tools: Vec<HubTool> = match self.with_connection(&entry, true, |hub, connection| hub.tools_of(connection)) {
                Ok(tools) => {
                    self.hub.record_worked(&entry.id, Some(tools.len()));
                    tools
                }
                Err(error) => {
                    self.hub.record_reach_error(&entry.id, &error);
                    eprintln!("theo-connectors: {}", error.sentence(&entry.name));
                    continue;
                }
            };
            for tool in tools {
                if !level.allows(tool.effect) {
                    continue;
                }
                let exposed_name = exposed_tool_name(&entry.id, &tool.name);
                self.tool_names.lock().unwrap().insert(exposed_name.clone(), (entry.id.clone(), tool.name.clone(), tool.effect));
                let description = format!("[{}] {}", entry.name, tool.description.clone().unwrap_or_default()).trim().to_string();
                let mut offered = json!({
                    "name": exposed_name,
                    "description": description,
                    "inputSchema": tool.input_schema,
                    "annotations": {"readOnlyHint": tool.effect == ToolEffect::Reads, "destructiveHint": tool.effect == ToolEffect::Irreversible},
                });
                if let Some(title) = tool.title {
                    offered["title"] = Value::String(format!("{}: {title}", entry.name));
                }
                offered_tools.push(offered);
            }
        }
        json!({"tools": offered_tools})
    }

    fn call_tool(&self, parameters: &Value) -> Value {
        let refusal = |text: String| json!({"content": [{"type": "text", "text": text}], "isError": true});
        let exposed_name = parameters.get("name").and_then(Value::as_str).unwrap_or("").to_string();
        let arguments = parameters.get("arguments").cloned().unwrap_or_else(|| json!({}));
        let ticket = match self.current_ticket() {
            Ok(ticket) => ticket,
            Err(reason) => return refusal(reason),
        };
        if self.tool_names.lock().unwrap().get(&exposed_name).is_none() {
            // A brain may call a tool it remembers from an earlier turn without listing first: list now.
            let _ = self.list_tools();
        }
        let Some((app_id, tool_name, tool_effect)) = self.tool_names.lock().unwrap().get(&exposed_name).cloned() else {
            return refusal(format!("There's no tool called {exposed_name} for this bot."));
        };
        let list = self.hub.load_list().unwrap_or_default();
        let Some(entry) = list.app(&app_id).cloned() else { return refusal(format!("The app {app_id} was removed.")) };
        let Some(level) = ticket.level_for(&app_id) else {
            return refusal(format!("This bot wasn't given {}.", entry.name));
        };
        if !level.allows(tool_effect) {
            let why = if ticket.owner_asked { String::new() } else { " This turn didn't come from the owner's own words, so apps are read-only.".to_string() };
            return refusal(format!("Not allowed: {tool_name} {}, and this bot may {} in {}.{why}", effect_words(tool_effect), level_words(level), entry.name));
        }
        match self.with_connection(&entry, tool_effect == ToolEffect::Reads, |hub, connection| hub.call_on(connection, &tool_name, arguments.clone(), level)) {
            Ok(result) => {
                self.hub.record_worked(&entry.id, None);
                result
            }
            Err(error) => {
                self.hub.record_reach_error(&entry.id, &error);
                refusal(error.sentence(&entry.name))
            }
        }
    }

    fn handle(&self, message: Value) {
        let Some(method) = message.get("method").and_then(Value::as_str) else { return };
        let Some(request_id) = message.get("id").cloned() else { return };
        let parameters = message.get("params").cloned().unwrap_or(Value::Null);
        let result = match method {
            "initialize" => {
                let asked_version = parameters.get("protocolVersion").and_then(Value::as_str).unwrap_or(LATEST_PROTOCOL_VERSION);
                let answered_version = if SUPPORTED_PROTOCOL_VERSIONS.contains(&asked_version) { asked_version } else { LATEST_PROTOCOL_VERSION };
                json!({
                    "protocolVersion": answered_version,
                    "capabilities": {"tools": {"listChanged": false}},
                    "serverInfo": {"name": "theo", "title": "Theo's apps", "version": env!("CARGO_PKG_VERSION")},
                    "instructions": "These are the owner's apps that Theo gave this bot for this turn. Each tool is named <app>__<tool>."
                })
            }
            "ping" => json!({}),
            "tools/list" => self.list_tools(),
            "tools/call" => self.call_tool(&parameters),
            _ => {
                self.send(&json!({"jsonrpc": "2.0", "id": request_id, "error": {"code": -32601, "message": format!("Theo's apps don't offer {method}")}}));
                return;
            }
        };
        self.send(&json!({"jsonrpc": "2.0", "id": request_id, "result": result}));
    }
}

/// Serves until standard input closes. Refuses to start without a valid ticket.
pub fn serve(hub: Hub, ticket_file: PathBuf) -> Result<(), String> {
    load_ticket(&hub.paths, &ticket_file)?;
    let state = Arc::new(ServerState {
        hub,
        ticket_file,
        connections: Mutex::new(HashMap::new()),
        tool_names: Mutex::new(HashMap::new()),
        output: Mutex::new(std::io::stdout()),
    });
    let mut running_requests = vec![];
    for line in std::io::stdin().lock().lines() {
        let Ok(line) = line else { break };
        if line.trim().is_empty() {
            continue;
        }
        let Ok(message) = serde_json::from_str::<Value>(&line) else {
            state.send(&json!({"jsonrpc": "2.0", "id": null, "error": {"code": -32700, "message": "Parse error"}}));
            continue;
        };
        // Each request gets its own thread, so a slow app doesn't hold up a quick one. Calls to the same app still take
        // turns on its one connection.
        let state_for_request = state.clone();
        running_requests.push(std::thread::spawn(move || state_for_request.handle(message)));
        running_requests.retain(|request| !request.is_finished());
    }
    for request in running_requests {
        let _ = request.join();
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn exposed_names_are_safe_for_every_brain() {
        assert_eq!(exposed_tool_name("gmail", "search_threads"), "gmail__search_threads");
        assert_eq!(exposed_tool_name("notion", "notion-search"), "notion__notion-search");
        assert_eq!(exposed_tool_name("x", "a.b/c d"), "x__a_b_c_d");
    }
}
