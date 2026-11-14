//! What the hub does, shared by the command line and `serve`: connect to an app, list its tools with what each does, run
//! one, check it, sign in and out, and keep the status up to date.

use serde::Serialize;
use serde_json::{json, Value};
use std::time::Duration;

use crate::claude_account::{call_claude_account_tool, claude_account_tool_effect, claude_account_tools, claude_code_servers};
use crate::files::HubPaths;
use crate::mcp_client::{LocalCommand, McpError, McpSession};
use crate::model::{now_rfc3339, AppEntry, AppKind, AppStatus, ConnectorList, ConnectorState, RemoteSignIn, ToolEffect};
use crate::oauth::{self, AccessTokenOutcome};
use crate::safety::tool_effect;
use crate::vault::{KeyStore, Vault};

const CONNECT_TIME_LIMIT_FOR_REMOTE_APPS: Duration = Duration::from_secs(30);
/// Longer for a local command: `npx` may be fetching the server the first time.
const CONNECT_TIME_LIMIT_FOR_LOCAL_APPS: Duration = Duration::from_secs(90);
pub const TOOL_CALL_TIME_LIMIT: Duration = Duration::from_secs(180);

pub struct Hub {
    pub paths: HubPaths,
    pub vault: Vault,
}

/// A tool as the hub offers it.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct HubTool {
    /// The app's own name for the tool.
    pub name: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub title: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub description: Option<String>,
    pub input_schema: Value,
    pub effect: ToolEffect,
    pub read_only: bool,
}

/// What checking one app found: its status, why it failed, and how many tools it has.
pub type CheckOutcome = (AppStatus, Option<String>, Option<usize>);

/// Why an app couldn't be reached.
#[derive(Debug, Clone)]
pub enum ReachError {
    NeedsSignIn,
    Off,
    Failed(String),
}

impl ReachError {
    pub fn sentence(&self, app_name: &str) -> String {
        match self {
            ReachError::NeedsSignIn => format!("{app_name} needs signing in."),
            ReachError::Off => format!("{app_name} is turned off."),
            ReachError::Failed(reason) => format!("{app_name} isn't answering: {reason}"),
        }
    }
}

/// An open connection to one app.
pub enum AppConnection {
    Mcp(McpSession),
    ClaudeAccount(AppEntry),
}

impl Hub {
    pub fn new(data_folder: impl Into<std::path::PathBuf>, key_store: KeyStore) -> Hub {
        let paths = HubPaths::new(data_folder);
        Hub { vault: Vault::new(paths.clone(), key_store), paths }
    }

    pub fn load_list(&self) -> Result<ConnectorList, String> {
        ConnectorList::load(&self.paths).map_err(|error| format!("The list of apps can't be read: {error}"))
    }

    pub fn app(&self, app_id: &str) -> Result<AppEntry, String> {
        self.load_list()?.app(app_id).cloned().ok_or_else(|| format!("There's no app called \"{app_id}\"."))
    }

    fn record_status(&self, app_id: &str, status: AppStatus, reason: Option<String>, tool_count: Option<usize>) {
        ConnectorState::record(&self.paths, app_id, |record| {
            let now = now_rfc3339();
            record.status = Some(status);
            record.reason = reason;
            record.last_checked = Some(now.clone());
            if status == AppStatus::Connected {
                record.last_worked = Some(now);
            }
            if tool_count.is_some() {
                record.tool_count = tool_count;
            }
        });
    }

    pub fn record_reach_error(&self, app_id: &str, error: &ReachError) {
        match error {
            ReachError::NeedsSignIn => self.record_status(app_id, AppStatus::NeedsSignIn, None, None),
            ReachError::Off => {}
            ReachError::Failed(reason) => self.record_status(app_id, AppStatus::Failed, Some(reason.clone()), None),
        }
    }

    pub fn record_worked(&self, app_id: &str, tool_count: Option<usize>) {
        self.record_status(app_id, AppStatus::Connected, None, tool_count);
    }

    /// Opens a connection to an app, signing in with what the vault holds.
    pub fn connect(&self, entry: &AppEntry) -> Result<AppConnection, ReachError> {
        if !entry.enabled {
            return Err(ReachError::Off);
        }
        match entry.kind {
            AppKind::ClaudeAccount => Ok(AppConnection::ClaudeAccount(entry.clone())),
            AppKind::Local => {
                let secrets = self.vault.read(&entry.id);
                let command_text = entry.command.clone().unwrap_or_default();
                let mut environment: Vec<(String, String)> = entry.env.iter().map(|(name, value)| (name.clone(), value.clone())).collect();
                environment.extend(secrets.secret_environment.iter().map(|(name, value)| (name.clone(), value.clone())));
                let command = LocalCommand {
                    program: std::path::PathBuf::from(command_text),
                    arguments: entry.args.clone(),
                    environment,
                    working_folder: entry.cwd.as_ref().map(std::path::PathBuf::from),
                    values_to_hide: secrets.secret_environment.values().cloned().collect(),
                };
                McpSession::start_local(command, CONNECT_TIME_LIMIT_FOR_LOCAL_APPS).map(AppConnection::Mcp).map_err(reach_error_from)
            }
            AppKind::Remote => {
                let server_address = entry.url.clone().unwrap_or_default();
                match entry.auth {
                    RemoteSignIn::Nothing => McpSession::connect_http(&server_address, None, CONNECT_TIME_LIMIT_FOR_REMOTE_APPS).map(AppConnection::Mcp).map_err(reach_error_from),
                    RemoteSignIn::PastedToken => {
                        let Some(token) = self.vault.read(&entry.id).pasted_token else { return Err(ReachError::NeedsSignIn) };
                        McpSession::connect_http(&server_address, Some(token), CONNECT_TIME_LIMIT_FOR_REMOTE_APPS).map(AppConnection::Mcp).map_err(reach_error_from)
                    }
                    RemoteSignIn::OAuth => {
                        let token = match oauth::usable_access_token(&entry.id, &self.vault, &self.paths, false).map_err(ReachError::Failed)? {
                            AccessTokenOutcome::Usable(token) => token,
                            AccessTokenOutcome::NeedsSignIn => return Err(ReachError::NeedsSignIn),
                        };
                        match McpSession::connect_http(&server_address, Some(token), CONNECT_TIME_LIMIT_FOR_REMOTE_APPS) {
                            Ok(session) => Ok(AppConnection::Mcp(session)),
                            // The server no longer takes the token (revoked early, or its clock disagrees): one refresh, then give up.
                            Err(McpError::NeedsSignIn { .. }) => {
                                let token = match oauth::usable_access_token(&entry.id, &self.vault, &self.paths, true).map_err(ReachError::Failed)? {
                                    AccessTokenOutcome::Usable(token) => token,
                                    AccessTokenOutcome::NeedsSignIn => return Err(ReachError::NeedsSignIn),
                                };
                                McpSession::connect_http(&server_address, Some(token), CONNECT_TIME_LIMIT_FOR_REMOTE_APPS).map(AppConnection::Mcp).map_err(reach_error_from)
                            }
                            Err(error) => Err(reach_error_from(error)),
                        }
                    }
                }
            }
        }
    }

    pub fn tools_of(&self, connection: &mut AppConnection) -> Result<Vec<HubTool>, ReachError> {
        match connection {
            AppConnection::ClaudeAccount(entry) => Ok(claude_account_tools(entry)
                .into_iter()
                .map(|(name, description, input_schema)| {
                    let effect = claude_account_tool_effect(entry, &name);
                    HubTool { read_only: effect == ToolEffect::Reads, effect, name, title: None, description: Some(description), input_schema }
                })
                .collect()),
            AppConnection::Mcp(session) => {
                let server_tools = session.list_tools(CONNECT_TIME_LIMIT_FOR_REMOTE_APPS).map_err(reach_error_from)?;
                Ok(server_tools
                    .into_iter()
                    .map(|tool| {
                        let effect = tool_effect(&tool.name, tool.annotations.as_ref());
                        HubTool { read_only: effect == ToolEffect::Reads, effect, name: tool.name, title: tool.title, description: tool.description, input_schema: tool.input_schema }
                    })
                    .collect())
            }
        }
    }

    /// Runs one tool. The caller has already checked the level; `level` is passed on so a claude-account run can deny
    /// what the level doesn't allow inside Claude Code too.
    pub fn call_on(&self, connection: &mut AppConnection, tool_name: &str, arguments: Value, level: crate::model::AccessLevel) -> Result<Value, ReachError> {
        match connection {
            AppConnection::ClaudeAccount(entry) => call_claude_account_tool(entry, tool_name, &arguments, level).map_err(ReachError::Failed),
            AppConnection::Mcp(session) => match session.call_tool(tool_name, arguments, TOOL_CALL_TIME_LIMIT) {
                Ok(result) => Ok(result),
                // A JSON-RPC error on a tool call is the tool failing, not the app: hand it back as a tool error.
                Err(McpError::Refused { code, message }) => Ok(json!({"content": [{"type": "text", "text": format!("The app refused ({code}): {message}")}], "isError": true})),
                Err(error) => Err(reach_error_from(error)),
            },
        }
    }

    /// Reconnects to one app and records what it found.
    pub fn check(&self, entry: &AppEntry) -> CheckOutcome {
        if !entry.enabled {
            return (AppStatus::Off, None, None);
        }
        if entry.kind == AppKind::ClaudeAccount {
            return self.check_claude_account_apps(std::slice::from_ref(entry)).into_iter().next().map(|(_, outcome)| outcome).unwrap_or((AppStatus::Unknown, None, None));
        }
        let outcome = self.connect(entry).and_then(|mut connection| self.tools_of(&mut connection));
        match outcome {
            Ok(tools) => {
                self.record_worked(&entry.id, Some(tools.len()));
                (AppStatus::Connected, None, Some(tools.len()))
            }
            Err(error) => {
                self.record_reach_error(&entry.id, &error);
                match error {
                    ReachError::NeedsSignIn => (AppStatus::NeedsSignIn, None, None),
                    ReachError::Off => (AppStatus::Off, None, None),
                    ReachError::Failed(reason) => (AppStatus::Failed, Some(reason), None),
                }
            }
        }
    }

    /// One `claude mcp list` for all the claude-account apps being checked.
    pub fn check_claude_account_apps(&self, entries: &[AppEntry]) -> Vec<(String, CheckOutcome)> {
        let servers = claude_code_servers();
        entries
            .iter()
            .map(|entry| {
                let outcome = match &servers {
                    Err(reason) => (AppStatus::Failed, Some(reason.clone()), None),
                    Ok(servers) => match servers.iter().find(|server| Some(server.server.as_str()) == entry.server.as_deref()) {
                        Some(server) => (server.status, server.reason.clone(), None),
                        None => (AppStatus::Failed, Some("Claude Code doesn't have this app any more. Connect it on claude.ai, or add it to Theo directly.".into()), None),
                    },
                };
                match outcome.0 {
                    AppStatus::Connected => self.record_worked(&entry.id, None),
                    status => self.record_status(&entry.id, status, outcome.1.clone(), None),
                }
                (entry.id.clone(), outcome)
            })
            .collect()
    }

    /// The list with each app's status, as `list` prints it. Nothing is contacted: the status is what was last seen,
    /// except what the hub knows without asking (turned off, never signed in).
    pub fn listing(&self) -> Result<Vec<Value>, String> {
        let list = self.load_list()?;
        let state = ConnectorState::load(&self.paths);
        Ok(list
            .apps
            .iter()
            .map(|entry| {
                let record = state.apps.get(&entry.id).cloned().unwrap_or_default();
                let secrets = self.vault.read(&entry.id);
                let has_sign_in = match (entry.kind, entry.auth) {
                    (AppKind::Remote, RemoteSignIn::OAuth) => secrets.oauth.as_ref().and_then(|record| record.tokens.as_ref()).is_some(),
                    (AppKind::Remote, RemoteSignIn::PastedToken) => secrets.pasted_token.is_some(),
                    _ => true,
                };
                let status = if !entry.enabled {
                    AppStatus::Off
                } else if !has_sign_in {
                    AppStatus::NeedsSignIn
                } else {
                    record.status.unwrap_or(AppStatus::Unknown)
                };
                let mut item = serde_json::to_value(entry).unwrap_or(Value::Null);
                item["status"] = serde_json::to_value(status).unwrap_or(Value::Null);
                if status == AppStatus::Failed {
                    item["reason"] = record.reason.clone().map(Value::String).unwrap_or(Value::Null);
                }
                item["lastWorked"] = record.last_worked.clone().map(Value::String).unwrap_or(Value::Null);
                item["lastChecked"] = record.last_checked.clone().map(Value::String).unwrap_or(Value::Null);
                if let Some(tool_count) = record.tool_count {
                    item["toolCount"] = json!(tool_count);
                }
                item["signedIn"] = json!(has_sign_in && matches!(entry.kind, AppKind::Remote) && entry.auth != RemoteSignIn::Nothing);
                item
            })
            .collect())
    }
}

pub fn reach_error_from(error: McpError) -> ReachError {
    match error {
        McpError::NeedsSignIn { .. } => ReachError::NeedsSignIn,
        McpError::Refused { code, message } => ReachError::Failed(format!("refused ({code}): {message}")),
        McpError::Failed(reason) => ReachError::Failed(reason),
    }
}
