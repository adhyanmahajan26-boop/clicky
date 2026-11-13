//! `claude-account` apps: the apps a user connected on claude.ai, reached through Claude Code. This is how every connector
//! worked before the hub, kept as one option among three, so nothing a Claude user set up is lost.
//!
//! Status comes from `claude mcp list` (the parser is the one in `theo-core/src/connectors.rs`, checked against Claude
//! Code's real output). A tool runs as a short Claude Code run that may use only that one tool, the way `ConnectorBridge`
//! in `leanring-buddy/T3/ClaudiaMCPServer.swift` does it: `dontAsk` permission mode refuses anything not allowed, no
//! built-in tools, and every changing tool the level doesn't allow is denied outright as well.

use serde_json::{json, Value};
use std::path::PathBuf;
use std::process::{Command, Stdio};
use std::time::Duration;

use crate::model::{AccessLevel, AppEntry, AppStatus, ToolEffect};
use crate::safety::tool_effect;

/// Tells the hub where Claude Code is, instead of looking for it (tests point this at a stand-in).
pub const CLAUDE_CODE_LOCATION_VARIABLE: &str = "THEO_CONNECTORS_CLAUDE";
/// The model for claude-account tool runs. Claude Code's alias, so it follows whatever Claude Code calls its small model.
const CLAUDE_MODEL_FOR_LOOKUPS: &str = "haiku";
/// The name of the tool every claude-account app offers: a plain-words lookup, as `claudia_app` does today.
pub const ASK_TOOL_NAME: &str = "ask";

#[derive(Debug, Clone, PartialEq)]
pub struct ClaudeCodeServer {
    /// The server's own name ("claude.ai Gmail").
    pub server: String,
    pub target: String,
    pub status: AppStatus,
    pub reason: Option<String>,
}

/// Reads `claude mcp list`. Lines look like `claude.ai Notion: https://mcp.notion.com/mcp - ✔ Connected`,
/// `… - ! Needs authentication`, or a failure mark and a reason.
pub fn parse_claude_mcp_list(output: &str) -> Vec<ClaudeCodeServer> {
    let mut servers = vec![];
    for line in output.lines() {
        let line = line.trim();
        // The status starts at the first " - " followed by a status mark or word: a failure's reason can hold " - " too,
        // and Windows prints √ and × for ✔ and ✘.
        let status_at = line.match_indices(" - ").map(|(index, _)| index).find(|&index| {
            let rest = line[index + 3..].trim_start();
            rest.starts_with(['✔', '✓', '√', '✘', '✗', '×', '✖', '!', '⚠', '‼'])
                || ["connected", "failed", "needs", "error"].iter().any(|word| rest.to_lowercase().starts_with(word))
        });
        let Some(dash_at) = status_at.or_else(|| line.rfind(" - ")) else { continue };
        let (head, status_text) = (&line[..dash_at], line[dash_at + 3..].trim());
        let Some(colon_at) = head.find(": ") else { continue };
        let (server_name, target) = (head[..colon_at].trim(), head[colon_at + 2..].trim());
        if server_name.is_empty() {
            continue;
        }
        let lowercase_status = status_text.to_lowercase();
        let (status, reason) = if lowercase_status.contains("needs auth") || lowercase_status.contains("sign in") || lowercase_status.contains("login") {
            (AppStatus::NeedsSignIn, None)
        } else if lowercase_status.contains("connected") && !lowercase_status.contains("not connected") && !lowercase_status.contains("failed") {
            (AppStatus::Connected, None)
        } else if lowercase_status.contains("fail") || lowercase_status.contains("error") || status_text.starts_with(['✘', '✗', '×']) {
            (AppStatus::Failed, Some(status_text.trim_start_matches(|c: char| !c.is_alphanumeric()).trim().to_string()))
        } else {
            (AppStatus::Unknown, None)
        };
        servers.push(ClaudeCodeServer { server: server_name.to_string(), target: target.to_string(), status, reason });
    }
    servers
}

/// Claude Code names a server's tools `mcp__<server>__<tool>`, with anything but letters, digits, `_` and `-` turned
/// into `_` ("claude.ai Gmail" → `mcp__claude_ai_Gmail`).
pub fn claude_tool_prefix(server: &str) -> Option<String> {
    let cleaned: String = server.trim().chars().map(|c| if c.is_ascii_alphanumeric() || c == '_' || c == '-' { c } else { '_' }).collect();
    if cleaned.is_empty() || cleaned.chars().all(|c| c == '_') {
        return None;
    }
    Some(format!("mcp__{cleaned}"))
}

/// Where Claude Code is: the override, then PATH, then where its installers put it.
pub fn locate_claude_code() -> Option<PathBuf> {
    if let Some(location) = std::env::var_os(CLAUDE_CODE_LOCATION_VARIABLE).filter(|location| !location.is_empty()) {
        return Some(PathBuf::from(location));
    }
    if let Some(found) = crate::mcp_client::find_on_path("claude") {
        return Some(found);
    }
    let home_folder = std::env::var_os(if cfg!(windows) { "USERPROFILE" } else { "HOME" }).map(PathBuf::from)?;
    let mut candidate_folders = vec![
        home_folder.join(".local").join("bin"),
        home_folder.join(".claude").join("local"),
        home_folder.join(".npm-global").join("bin"),
        home_folder.join(".bun").join("bin"),
        PathBuf::from("/opt/homebrew/bin"),
        PathBuf::from("/usr/local/bin"),
    ];
    if let Some(application_data) = std::env::var_os("APPDATA") {
        candidate_folders.push(PathBuf::from(application_data).join("npm"));
    }
    let extensions: &[&str] = if cfg!(windows) { &[".exe", ".cmd", ""] } else { &[""] };
    candidate_folders
        .into_iter()
        .flat_map(|folder| extensions.iter().map(move |extension| folder.join(format!("claude{extension}"))))
        .find(|candidate| candidate.is_file())
}

fn claude_code_command(claude_code: &std::path::Path) -> Command {
    let (program, leading_arguments) = crate::mcp_client::resolve_program_to_start(claude_code);
    let mut command = Command::new(program);
    command.args(leading_arguments);
    command.env("NO_COLOR", "1");
    crate::mcp_client::hide_console_window(&mut command);
    command
}

/// Runs a command with a time limit and returns (exit code, standard output).
fn run_with_time_limit(mut command: Command, time_limit: Duration) -> Result<(i32, String), String> {
    command.stdin(Stdio::null()).stdout(Stdio::piped()).stderr(Stdio::null());
    let mut child = command.spawn().map_err(|error| format!("Couldn't start Claude Code: {error}"))?;
    let mut child_output = child.stdout.take().expect("stdout was piped");
    let output_reader = std::thread::spawn(move || {
        let mut text = String::new();
        let _ = std::io::Read::read_to_string(&mut child_output, &mut text);
        text
    });
    let deadline = std::time::Instant::now() + time_limit;
    loop {
        match child.try_wait() {
            Ok(Some(status)) => {
                let output = output_reader.join().unwrap_or_default();
                return Ok((status.code().unwrap_or(-1), output));
            }
            Ok(None) if std::time::Instant::now() > deadline => {
                let _ = child.kill();
                let _ = child.wait();
                return Err(format!("Claude Code didn't finish within {} seconds.", time_limit.as_secs()));
            }
            Ok(None) => std::thread::sleep(Duration::from_millis(50)),
            Err(error) => return Err(error.to_string()),
        }
    }
}

/// Every server Claude Code knows, with its status. Err when Claude Code isn't installed or didn't answer.
pub fn claude_code_servers() -> Result<Vec<ClaudeCodeServer>, String> {
    let claude_code = locate_claude_code().ok_or("Claude Code isn't installed, so apps connected through a Claude account can't be reached.")?;
    let mut command = claude_code_command(&claude_code);
    command.args(["mcp", "list"]);
    if let Some(home_folder) = std::env::var_os(if cfg!(windows) { "USERPROFILE" } else { "HOME" }) {
        command.current_dir(home_folder);
    }
    let (_, output) = run_with_time_limit(command, Duration::from_secs(90))?;
    Ok(parse_claude_mcp_list(&output))
}

/// What one claude-account tool does. `ask` is a plain-words lookup limited to the app's reading tools, so it is a read
/// when those are known (the catalog lists them). When they aren't, it has to be given the whole server and nothing can
/// stop it using a tool that sends or deletes, so it counts as irreversible and only a `full` bot gets it.
pub fn claude_account_tool_effect(entry: &AppEntry, tool_name: &str) -> ToolEffect {
    if tool_name == ASK_TOOL_NAME {
        return if entry.read_tools.is_empty() { ToolEffect::Irreversible } else { ToolEffect::Reads };
    }
    let effect_from_name = tool_effect(tool_name, None);
    if entry.write_tools.iter().any(|write_tool| write_tool == tool_name) {
        return effect_from_name.max(ToolEffect::Changes);
    }
    effect_from_name
}

/// The tools a claude-account app offers through the hub: `ask`, plus each listed tool on its own.
pub fn claude_account_tools(entry: &AppEntry) -> Vec<(String, String, Value)> {
    let mut tools = vec![(
        ASK_TOOL_NAME.to_string(),
        format!("Look something up in {} in plain words (\"emails from Sam this week\"). Answers with the facts found.", entry.name),
        json!({"type": "object", "properties": {"request": {"type": "string", "description": "What to look up."}}, "required": ["request"]}),
    )];
    for tool_name in entry.read_tools.iter().chain(entry.write_tools.iter()) {
        tools.push((tool_name.clone(), format!("{}'s {} tool, through your Claude account.", entry.name, tool_name), json!({"type": "object", "additionalProperties": true})));
    }
    tools
}

/// Runs one claude-account tool at the given level and returns an MCP tool result.
pub fn call_claude_account_tool(entry: &AppEntry, tool_name: &str, arguments: &Value, level: AccessLevel) -> Result<Value, String> {
    let server = entry.server.as_deref().ok_or("This app has no Claude Code server name.")?;
    let prefix = claude_tool_prefix(server).ok_or("This app's Claude Code server name can't be used.")?;
    let qualified = |tool: &str| format!("{prefix}__{tool}");

    let denied_tools: Vec<String> = entry
        .write_tools
        .iter()
        .filter(|write_tool| !level.allows(claude_account_tool_effect(entry, write_tool)))
        .map(|write_tool| qualified(write_tool))
        .collect();
    let (allowed_tools, request_text, system_text) = if tool_name == ASK_TOOL_NAME {
        let request = arguments.get("request").and_then(Value::as_str).unwrap_or("").trim().to_string();
        if request.is_empty() {
            return Err("Say what to look up (the request argument).".into());
        }
        let allowed: Vec<String> = if entry.read_tools.is_empty() {
            vec![prefix.clone()]
        } else {
            // A lookup only ever reads: drafting and changing are the app's own tools, called one at a time.
            entry.read_tools.iter().filter(|tool| claude_account_tool_effect(entry, tool) == ToolEffect::Reads).map(|tool| qualified(tool)).collect()
        };
        let system = format!(
            "You fetch information from the user's {} for another assistant. Use only your {} tools, answer with the facts found (names, dates, links, short quotes) and nothing else. Never send, delete or change anything.",
            entry.name, entry.name
        );
        (allowed, request, system)
    } else {
        if !entry.read_tools.iter().chain(entry.write_tools.iter()).any(|tool| tool == tool_name) {
            return Err(format!("{} has no tool called {tool_name}.", entry.name));
        }
        let request = format!(
            "Call the tool {} exactly once with exactly these arguments: {}\nThen reply with only what the tool returned, unchanged.",
            qualified(tool_name),
            arguments
        );
        let system = "You run exactly one tool call for another assistant and pass its result back unchanged. Do nothing else.".to_string();
        (vec![qualified(tool_name)], request, system)
    };

    let claude_code = locate_claude_code().ok_or("Claude Code isn't installed, so this app (connected through a Claude account) can't be reached. Add the app to Theo directly instead.")?;
    let mut command = claude_code_command(&claude_code);
    command.args(["-p", "--model", CLAUDE_MODEL_FOR_LOOKUPS, "--output-format", "json", "--permission-mode", "dontAsk", "--tools", ""]);
    if !denied_tools.is_empty() {
        command.arg("--disallowedTools").args(&denied_tools);
    }
    command.arg("--allowedTools").args(&allowed_tools);
    command.args(["--append-system-prompt", &system_text, "--", &request_text]);
    if let Some(home_folder) = std::env::var_os(if cfg!(windows) { "USERPROFILE" } else { "HOME" }) {
        command.current_dir(home_folder);
    }
    let (_, output) = run_with_time_limit(command, Duration::from_secs(240))?;
    let answer: Value = serde_json::from_str(output.trim()).map_err(|_| format!("{} lookup didn't finish.", entry.name))?;
    let result_text = answer.get("result").and_then(Value::as_str).ok_or_else(|| format!("{} lookup didn't finish.", entry.name))?;
    let is_error = answer.get("is_error").and_then(Value::as_bool).unwrap_or(false);
    Ok(json!({"content": [{"type": "text", "text": result_text}], "isError": is_error}))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_claude_mcp_list_like_theo_core_does() {
        let text = "Checking MCP server health…\n\nclaude.ai Notion: https://mcp.notion.com/mcp - ✔ Connected\nclaude.ai Runway (runway.team): https://mcp.runway.team - ! Needs authentication\nplugin:theo:theo: /x/theo-mcp  - ✔ Connected\ntheo-broken: C:\\nope.exe  - × Failed to connect — spawn C:\\nope.exe - x ENOENT\n";
        let servers = parse_claude_mcp_list(text);
        assert_eq!(servers.len(), 4);
        assert_eq!((servers[0].server.as_str(), servers[0].status), ("claude.ai Notion", AppStatus::Connected));
        assert_eq!(servers[1].status, AppStatus::NeedsSignIn);
        assert_eq!(servers[2].server, "plugin:theo:theo");
        assert_eq!(servers[3].status, AppStatus::Failed);
        assert!(servers[3].reason.as_deref().unwrap().ends_with("x ENOENT"));
    }

    #[test]
    fn tool_prefixes_follow_claude_codes_names() {
        assert_eq!(claude_tool_prefix("claude.ai Gmail").as_deref(), Some("mcp__claude_ai_Gmail"));
        assert_eq!(claude_tool_prefix("theo-echo").as_deref(), Some("mcp__theo-echo"));
        assert_eq!(claude_tool_prefix("*"), None);
    }

    #[test]
    fn ask_is_only_a_read_when_the_tools_are_known() {
        let mut entry: AppEntry = serde_json::from_str(r#"{"id":"hostinger","name":"Hostinger","kind":"claude-account","server":"claude.ai Hostinger Connector"}"#).unwrap();
        assert_eq!(claude_account_tool_effect(&entry, ASK_TOOL_NAME), ToolEffect::Irreversible);
        entry.read_tools = vec!["search_threads".into()];
        entry.write_tools = vec!["create_draft".into(), "send_message".into()];
        assert_eq!(claude_account_tool_effect(&entry, ASK_TOOL_NAME), ToolEffect::Reads);
        assert_eq!(claude_account_tool_effect(&entry, "create_draft"), ToolEffect::Changes);
        assert_eq!(claude_account_tool_effect(&entry, "send_message"), ToolEffect::Irreversible);
    }
}
