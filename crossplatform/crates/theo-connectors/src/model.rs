//! The list of apps (`connectors.json`) and what the hub last saw of each (`state.json`).
//!
//! The list is the user's: what they added, turned on or off. It never holds a token or a secret; those are in the vault.
//! The state is the hub's own record and can be thrown away at any time.

use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

use crate::files::{read_json_file, write_json_file, FileLock, HubPaths};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum AppKind {
    /// An MCP server at a URL (streamable HTTP).
    #[serde(rename = "remote")]
    Remote,
    /// An MCP server started as a command on this computer (stdio).
    #[serde(rename = "local")]
    Local,
    /// An app the user connected on claude.ai, reached through Claude Code.
    #[serde(rename = "claude-account")]
    ClaudeAccount,
}

impl AppKind {
    pub fn label(&self) -> &'static str {
        match self {
            AppKind::Remote => "remote",
            AppKind::Local => "local",
            AppKind::ClaudeAccount => "claude-account",
        }
    }
}

/// How a `remote` app is signed in to.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
pub enum RemoteSignIn {
    #[serde(rename = "none")]
    #[default]
    Nothing,
    /// OAuth 2.1 with PKCE, in the browser (`signin <id>`).
    #[serde(rename = "oauth")]
    OAuth,
    /// A token the user pasted (`set-secret <id>`, read from standard input).
    #[serde(rename = "token")]
    PastedToken,
}

/// For servers that don't let an app register itself (Google's, for one): the client the owner registered with the
/// provider. A client secret, if there is one, goes in the vault with `set-secret <id> --client-secret`, never here.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct OAuthClientSettings {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub client_id: Option<String>,
    /// The scopes to ask for. Without this, the server's own advertised scopes are used.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub scopes: Option<Vec<String>>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AppEntry {
    /// Lowercase letters, digits and dashes. Tools are offered to bots as `<id>__<tool>`.
    pub id: String,
    pub name: String,
    pub kind: AppKind,
    #[serde(default = "default_true")]
    pub enabled: bool,

    // remote
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub url: Option<String>,
    #[serde(default, skip_serializing_if = "is_default_sign_in")]
    pub auth: RemoteSignIn,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub oauth: Option<OAuthClientSettings>,

    // local
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub command: Option<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub args: Vec<String>,
    /// Plain settings for the command. Anything secret is set with `set-secret <id> --env NAME` instead.
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub env: BTreeMap<String, String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cwd: Option<String>,

    // claude-account
    /// Claude Code's own name for the server ("claude.ai Gmail"), as `claude mcp list` prints it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub server: Option<String>,
    /// The tools of a claude-account app that only read. They come from the starter catalog: Claude Code has no way to
    /// list a claude.ai app's tools without a model run.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub read_tools: Vec<String>,
    /// The tools of a claude-account app that change something.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub write_tools: Vec<String>,

    /// The starter catalog entry this app came from, if any.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub catalog_id: Option<String>,
    /// Fields a newer hub wrote that this one doesn't know: kept, so an older helper never loses them.
    #[serde(flatten)]
    pub fields_from_newer_versions: BTreeMap<String, serde_json::Value>,
}

fn default_true() -> bool {
    true
}

fn is_default_sign_in(sign_in: &RemoteSignIn) -> bool {
    *sign_in == RemoteSignIn::Nothing
}

pub fn is_valid_app_id(app_id: &str) -> bool {
    let first_character_is_letter_or_digit = app_id.chars().next().map(|c| c.is_ascii_lowercase() || c.is_ascii_digit()).unwrap_or(false);
    first_character_is_letter_or_digit
        && app_id.len() <= 40
        && app_id.chars().all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '-')
        && !app_id.ends_with('-')
}

impl AppEntry {
    /// Checks an entry before it is saved; the error is a sentence for the person adding the app.
    pub fn validate(&self) -> Result<(), String> {
        if !is_valid_app_id(&self.id) {
            return Err(format!("\"{}\" can't be an app id: use lowercase letters, digits and dashes (up to 40).", self.id));
        }
        if self.name.trim().is_empty() {
            return Err("The app needs a name.".into());
        }
        match self.kind {
            AppKind::Remote => {
                let Some(address) = self.url.as_deref() else { return Err("A remote app needs a url.".into()) };
                let parsed_address = url::Url::parse(address).map_err(|_| format!("\"{address}\" isn't a web address."))?;
                let is_loopback = matches!(parsed_address.host_str(), Some("127.0.0.1") | Some("localhost") | Some("[::1]") | Some("::1"));
                if parsed_address.scheme() != "https" && !(parsed_address.scheme() == "http" && is_loopback) {
                    return Err("A remote app's address must start with https:// (plain http only on this computer).".into());
                }
            }
            AppKind::Local => {
                if self.command.as_deref().map(str::trim).unwrap_or("").is_empty() {
                    return Err("A local app needs a command to start.".into());
                }
            }
            AppKind::ClaudeAccount => {
                if self.server.as_deref().map(str::trim).unwrap_or("").is_empty() {
                    return Err("A claude-account app needs Claude Code's name for it (server), such as \"claude.ai Gmail\".".into());
                }
            }
        }
        Ok(())
    }
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct ConnectorList {
    #[serde(default = "list_format_version")]
    pub version: u32,
    #[serde(default)]
    pub apps: Vec<AppEntry>,
}

fn list_format_version() -> u32 {
    1
}

impl ConnectorList {
    pub fn load(paths: &HubPaths) -> std::io::Result<ConnectorList> {
        Ok(read_json_file(&paths.connector_list_file())?.unwrap_or(ConnectorList { version: 1, apps: vec![] }))
    }

    pub fn save(&self, paths: &HubPaths) -> std::io::Result<()> {
        write_json_file(&paths.connector_list_file(), self)
    }

    /// Loads the list, lets `change` edit it, and saves it, with no other hub changing it in between.
    pub fn change<T>(paths: &HubPaths, change: impl FnOnce(&mut ConnectorList) -> Result<T, String>) -> Result<T, String> {
        let _lock = FileLock::acquire(&paths.lock_file("connectors"), std::time::Duration::from_secs(15)).map_err(|error| error.to_string())?;
        let mut list = ConnectorList::load(paths).map_err(|error| error.to_string())?;
        let result = change(&mut list)?;
        list.save(paths).map_err(|error| format!("Couldn't save the list of apps: {error}"))?;
        Ok(result)
    }

    pub fn app(&self, app_id: &str) -> Option<&AppEntry> {
        self.apps.iter().find(|app| app.id == app_id)
    }
}

/// What a bot may do with one app.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
pub enum AccessLevel {
    /// Only tools that look things up.
    #[serde(rename = "read")]
    Read,
    /// Look things up, write drafts and make changes that can be undone. Nothing that sends, deletes or shares.
    /// This is the default, and what bots could do before the hub.
    #[serde(rename = "readAndDraft")]
    ReadAndDraft,
    /// Everything the app offers.
    #[serde(rename = "full")]
    Full,
}

impl AccessLevel {
    pub fn label(&self) -> &'static str {
        match self {
            AccessLevel::Read => "read",
            AccessLevel::ReadAndDraft => "readAndDraft",
            AccessLevel::Full => "full",
        }
    }
}

/// What running one tool does to the world.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
pub enum ToolEffect {
    /// Only reads.
    #[serde(rename = "read")]
    Reads,
    /// Writes something that can be looked at and undone: a draft, a new page, a label.
    #[serde(rename = "change")]
    Changes,
    /// Can't be taken back: sends, replies, deletes, shares, cancels.
    #[serde(rename = "irreversible")]
    Irreversible,
}

impl AccessLevel {
    pub fn allows(&self, tool_effect: ToolEffect) -> bool {
        match tool_effect {
            ToolEffect::Reads => true,
            ToolEffect::Changes => *self >= AccessLevel::ReadAndDraft,
            ToolEffect::Irreversible => *self == AccessLevel::Full,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum AppStatus {
    #[serde(rename = "connected")]
    Connected,
    #[serde(rename = "needsSignIn")]
    NeedsSignIn,
    #[serde(rename = "failed")]
    Failed,
    #[serde(rename = "off")]
    Off,
    #[serde(rename = "unknown")]
    Unknown,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AppStateRecord {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub status: Option<AppStatus>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reason: Option<String>,
    /// The last time the app answered (RFC 3339).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_worked: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_checked: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tool_count: Option<usize>,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct ConnectorState {
    #[serde(default)]
    pub apps: BTreeMap<String, AppStateRecord>,
}

impl ConnectorState {
    pub fn load(paths: &HubPaths) -> ConnectorState {
        // The state is only a record of what was last seen: a damaged file is started over rather than stopping the hub.
        read_json_file(&paths.connector_state_file()).ok().flatten().unwrap_or_default()
    }

    /// Records what was just seen of one app, keeping what other hub processes recorded of the others.
    pub fn record(paths: &HubPaths, app_id: &str, update: impl FnOnce(&mut AppStateRecord)) {
        let Ok(_lock) = FileLock::acquire(&paths.lock_file("state"), std::time::Duration::from_secs(10)) else { return };
        let mut state = ConnectorState::load(paths);
        update(state.apps.entry(app_id.to_string()).or_default());
        let _ = write_json_file(&paths.connector_state_file(), &state);
    }

    pub fn forget(paths: &HubPaths, app_id: &str) {
        let Ok(_lock) = FileLock::acquire(&paths.lock_file("state"), std::time::Duration::from_secs(10)) else { return };
        let mut state = ConnectorState::load(paths);
        if state.apps.remove(app_id).is_some() {
            let _ = write_json_file(&paths.connector_state_file(), &state);
        }
    }
}

pub fn now_rfc3339() -> String {
    chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Secs, true)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn app_ids_are_plain() {
        assert!(is_valid_app_id("gmail"));
        assert!(is_valid_app_id("my-app-2"));
        assert!(!is_valid_app_id("My App"));
        assert!(!is_valid_app_id("a__b"));
        assert!(!is_valid_app_id("-a"));
        assert!(!is_valid_app_id("a-"));
        assert!(!is_valid_app_id(""));
    }

    #[test]
    fn levels_allow_what_they_say() {
        assert!(AccessLevel::Read.allows(ToolEffect::Reads));
        assert!(!AccessLevel::Read.allows(ToolEffect::Changes));
        assert!(AccessLevel::ReadAndDraft.allows(ToolEffect::Changes));
        assert!(!AccessLevel::ReadAndDraft.allows(ToolEffect::Irreversible));
        assert!(AccessLevel::Full.allows(ToolEffect::Irreversible));
    }

    #[test]
    fn unknown_fields_survive_a_round_trip() {
        let text = r#"{"id":"echo","name":"Echo","kind":"local","command":"python3","futureField":{"a":1}}"#;
        let entry: AppEntry = serde_json::from_str(text).unwrap();
        assert!(entry.enabled);
        let written = serde_json::to_value(&entry).unwrap();
        assert_eq!(written["futureField"]["a"], 1);
    }

    #[test]
    fn remote_addresses_must_be_https_unless_on_this_computer() {
        let mut entry: AppEntry = serde_json::from_str(r#"{"id":"x","name":"X","kind":"remote","url":"http://example.com/mcp"}"#).unwrap();
        assert!(entry.validate().is_err());
        entry.url = Some("http://127.0.0.1:9/mcp".into());
        assert!(entry.validate().is_ok());
        entry.url = Some("https://example.com/mcp".into());
        assert!(entry.validate().is_ok());
    }
}
