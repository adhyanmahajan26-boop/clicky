//! Composio: one API key that reaches every app the owner connects on Composio (Gmail, Slack, GitHub, Notion, Google
//! Calendar, Linear and hundreds more).
//!
//! A Composio app is a `remote` app with `auth: "token"` (the pasted token is the Composio API key, kept in the vault like
//! any token), `url` the Composio API's address (`https://backend.composio.dev`) and a `composio` block. The hub opens a
//! Composio tool-router session for the owner (`POST /api/v3.1/tool_router/session`), which answers with an MCP address,
//! and then talks MCP to that address with the key in `x-api-key`. The session is kept in `state.json` and opened again
//! when Composio stops taking it. Apps are connected on Composio with a link: a bot gets one from Composio's own
//! connection tool in the chat, and the Connectors page gets one from `composio-link` (`POST …/session/<id>/link`).
//!
//! What a bot may do: a tool-router session offers a few tools of Composio's own, and one of them runs any app's tool by
//! its slug (`GMAIL_SEND_EMAIL`). So the hub can't judge those by their own names: each call is judged by the slugs it
//! runs, with the same word rule as every other app (`call_effect`). Running code in Composio's workbench counts as
//! irreversible, and so does a run whose slugs can't be read.

use serde_json::{json, Value};
use std::time::Duration;

use crate::files::HubPaths;
use crate::hub::ReachError;
use crate::mcp_client::{McpError, McpSession};
use crate::model::{AppEntry, ConnectorState, ToolEffect};
use crate::safety::{tool_effect, words_in_tool_name};
use crate::vault::Vault;

pub const DEFAULT_API_ADDRESS: &str = "https://backend.composio.dev";
pub const DEFAULT_USER_ID: &str = "vello";
/// The header Composio takes a project API key in.
const API_KEY_HEADER: &str = "x-api-key";
/// Newest first. Composio moved the tool router from `labs` to v3 to v3.1; an older or newer account may answer on another.
const SESSION_PATHS: &[&str] = &["/api/v3.1/tool_router/session", "/api/v3/tool_router/session", "/api/v3/labs/tool_router/session"];
const CONNECTED_ACCOUNT_PATHS: &[&str] = &["/api/v3.1/connected_accounts", "/api/v3/connected_accounts"];
const REQUEST_TIME_LIMIT: Duration = Duration::from_secs(30);

pub fn api_address(entry: &AppEntry) -> String {
    entry.url.clone().unwrap_or_else(|| DEFAULT_API_ADDRESS.to_string()).trim_end_matches('/').to_string()
}

pub fn user_id(entry: &AppEntry) -> String {
    entry
        .composio
        .as_ref()
        .and_then(|settings| settings.user_id.clone())
        .map(|text| text.trim().to_string())
        .filter(|text| !text.is_empty())
        .unwrap_or_else(|| DEFAULT_USER_ID.to_string())
}

/// The key only ever goes to Composio: the API's own host, another `*.composio.dev` host (the session's MCP address is on
/// `app.composio.dev`), or this computer (the tests' stand-in). A session address anywhere else is refused, so a changed
/// answer can never carry the key off.
pub fn may_send_key_to(address: &str, api_address: &str) -> bool {
    let Ok(parsed_address) = url::Url::parse(address) else { return false };
    let Some(host) = parsed_address.host_str().map(str::to_lowercase) else { return false };
    if crate::http::is_loopback_address(address) {
        return crate::http::is_loopback_address(api_address);
    }
    if parsed_address.scheme() != "https" {
        return false;
    }
    let api_host = url::Url::parse(api_address).ok().and_then(|parsed| parsed.host_str().map(str::to_lowercase));
    Some(host.clone()) == api_host || host == "composio.dev" || host.ends_with(".composio.dev")
}

/// `Google Calendar` → `googlecalendar`, Composio's way of naming a toolkit.
pub fn toolkit_slug(typed: &str) -> String {
    typed.trim().to_lowercase().chars().filter(|character| character.is_ascii_alphanumeric() || *character == '_').collect()
}

// ---------------------------------------------------------------------------------------------------------------------
// The REST calls

enum ApiFailure {
    /// 401 or 403: Composio didn't take the key.
    KeyRefused(u16),
    /// 404 or 410: no such route (or no such session).
    NotFound,
    /// 400 or 422: Composio didn't like what was asked.
    BadRequest(String),
    Other(String),
}

impl ApiFailure {
    fn sentence(&self) -> String {
        match self {
            ApiFailure::KeyRefused(status) => format!("Composio didn't take this API key ({status}). Paste a new key from your Composio dashboard."),
            ApiFailure::NotFound => "Composio answered 404: this address isn't Composio's API.".into(),
            ApiFailure::BadRequest(detail) | ApiFailure::Other(detail) => detail.clone(),
        }
    }
}

fn post_json(address: &str, api_key: &str, body: &Value) -> Result<Value, ApiFailure> {
    let request = crate::http::agent_for(address)
        .post(address)
        .timeout(REQUEST_TIME_LIMIT)
        .set("Content-Type", "application/json")
        .set("Accept", "application/json")
        .set(API_KEY_HEADER, api_key);
    answer_of(request.send_string(&body.to_string()))
}

fn get_json(address: &str, api_key: &str) -> Result<Value, ApiFailure> {
    let request = crate::http::agent_for(address).get(address).timeout(REQUEST_TIME_LIMIT).set("Accept", "application/json").set(API_KEY_HEADER, api_key);
    answer_of(request.call())
}

fn answer_of(outcome: Result<ureq::Response, ureq::Error>) -> Result<Value, ApiFailure> {
    match outcome {
        Ok(response) => {
            let body = response.into_string().map_err(|error| ApiFailure::Other(format!("Composio's answer was cut off: {error}")))?;
            serde_json::from_str(&body).map_err(|_| ApiFailure::Other("Composio's answer wasn't JSON.".into()))
        }
        Err(ureq::Error::Status(status @ (401 | 403), _)) => Err(ApiFailure::KeyRefused(status)),
        Err(ureq::Error::Status(404 | 410, _)) => Err(ApiFailure::NotFound),
        Err(ureq::Error::Status(status, response)) => {
            let detail: String = response.into_string().unwrap_or_default().chars().take(240).collect();
            let sentence = format!("Composio answered {status}{}", if detail.trim().is_empty() { String::new() } else { format!(": {}", detail.trim()) });
            if status == 400 || status == 422 {
                Err(ApiFailure::BadRequest(sentence))
            } else {
                Err(ApiFailure::Other(sentence))
            }
        }
        Err(ureq::Error::Transport(transport_error)) => Err(ApiFailure::Other(format!("couldn't reach Composio: {transport_error}"))),
    }
}

/// A tool-router session: its id and its MCP address.
#[derive(Debug, Clone, PartialEq)]
pub struct ComposioSession {
    pub id: String,
    pub mcp_address: String,
}

fn session_from_answer(answer: &Value) -> Option<ComposioSession> {
    let id = answer.get("session_id").or_else(|| answer.get("id")).and_then(Value::as_str)?.to_string();
    let mcp_address = answer
        .get("mcp")
        .and_then(|mcp| mcp.get("url"))
        .or_else(|| answer.get("mcp_url"))
        .or_else(|| answer.get("url"))
        .and_then(Value::as_str)?
        .to_string();
    Some(ComposioSession { id, mcp_address })
}

/// Opens a new session for the owner. Bots may connect apps (Composio's connection tool hands back a link) but not
/// disconnect them: that stays on Composio's own dashboard.
pub fn open_session(entry: &AppEntry, api_key: &str) -> Result<ComposioSession, String> {
    let api = api_address(entry);
    let full_request = json!({
        "user_id": user_id(entry),
        "mcp": true,
        "manage_connections": {"enable": true, "enable_connection_removal": false},
    });
    let plain_request = json!({"user_id": user_id(entry)});
    let mut last_failure = ApiFailure::NotFound;
    for path in SESSION_PATHS {
        let address = format!("{api}{path}");
        // If Composio refuses the settings (an older API), the plain request still gives a working session.
        let answer = match post_json(&address, api_key, &full_request) {
            Err(ApiFailure::BadRequest(_)) => post_json(&address, api_key, &plain_request),
            other => other,
        };
        match answer {
            Ok(answer) => {
                let session = session_from_answer(&answer).ok_or("Composio opened a session but didn't say its MCP address.")?;
                if !may_send_key_to(&session.mcp_address, &api) {
                    return Err(format!("Composio's session address ({}) isn't on composio.dev, so Vello won't send it your key.", session.mcp_address));
                }
                return Ok(session);
            }
            Err(ApiFailure::NotFound) => continue,
            Err(failure) => {
                last_failure = failure;
                break;
            }
        }
    }
    Err(last_failure.sentence())
}

/// The session to use: the one kept from last time, or a new one (kept for next time).
fn kept_or_new_session(paths: &HubPaths, entry: &AppEntry, api_key: &str, force_new: bool) -> Result<ComposioSession, String> {
    if !force_new {
        let record = ConnectorState::load(paths).apps.get(&entry.id).cloned().unwrap_or_default();
        if let (Some(id), Some(mcp_address)) = (record.composio_session_id, record.composio_session_url) {
            if may_send_key_to(&mcp_address, &api_address(entry)) {
                return Ok(ComposioSession { id, mcp_address });
            }
        }
    }
    let session = open_session(entry, api_key)?;
    let kept = session.clone();
    ConnectorState::record(paths, &entry.id, move |record| {
        record.composio_session_id = Some(kept.id);
        record.composio_session_url = Some(kept.mcp_address);
    });
    Ok(session)
}

fn api_key(vault: &Vault, entry: &AppEntry) -> Result<String, ReachError> {
    vault.read(&entry.id).pasted_token.filter(|key| !key.trim().is_empty()).ok_or(ReachError::NeedsSignIn)
}

/// Connects to the owner's Composio session over MCP. A kept session Composio no longer knows is replaced once.
pub fn connect(paths: &HubPaths, vault: &Vault, entry: &AppEntry, timeout: Duration) -> Result<McpSession, ReachError> {
    let key = api_key(vault, entry)?;
    let connect_to = |session: &ComposioSession| {
        McpSession::connect_http_with_headers(&session.mcp_address, None, vec![(API_KEY_HEADER.to_string(), key.clone())], timeout)
    };
    let session = kept_or_new_session(paths, entry, &key, false).map_err(ReachError::Failed)?;
    match connect_to(&session) {
        Ok(connection) => Ok(connection),
        Err(first_error) => {
            // An expired or forgotten session: open a new one and try once more. A refused key fails the same way again,
            // and then says so plainly.
            let fresh_session = kept_or_new_session(paths, entry, &key, true).map_err(ReachError::Failed)?;
            match connect_to(&fresh_session) {
                Ok(connection) => Ok(connection),
                Err(McpError::NeedsSignIn { .. }) => Err(ReachError::Failed("Composio didn't take this API key. Paste a new key from your Composio dashboard.".into())),
                Err(McpError::Refused { code, message }) => Err(ReachError::Failed(format!("refused ({code}): {message}"))),
                Err(McpError::Failed(reason)) => {
                    eprintln!("theo-connectors: Composio's kept session failed first: {first_error}");
                    Err(ReachError::Failed(reason))
                }
            }
        }
    }
}

/// A link that connects one app (a toolkit such as `gmail`) to the owner's Composio account. The owner opens it in the
/// browser and approves; from then on every bot with Composio can use that app.
pub fn connect_link(paths: &HubPaths, vault: &Vault, entry: &AppEntry, toolkit: &str) -> Result<String, String> {
    let key = api_key(vault, entry).map_err(|_| format!("Paste your Composio API key on {}'s row first.", entry.name))?;
    let slug = toolkit_slug(toolkit);
    if slug.is_empty() {
        return Err("Say which app to connect, such as gmail, slack or github.".into());
    }
    let api = api_address(entry);
    let ask_for_link = |session: &ComposioSession| -> Result<String, ApiFailure> {
        let mut last_failure = ApiFailure::NotFound;
        for path in SESSION_PATHS {
            let address = format!("{api}{path}/{}/link", session.id);
            match post_json(&address, &key, &json!({"toolkit": slug})) {
                Ok(answer) => {
                    return answer
                        .get("redirect_url")
                        .or_else(|| answer.get("redirectUrl"))
                        .or_else(|| answer.get("url"))
                        .and_then(Value::as_str)
                        .map(str::to_string)
                        .ok_or(ApiFailure::Other("Composio didn't give a link.".into()));
                }
                Err(ApiFailure::NotFound) => continue,
                Err(failure) => {
                    last_failure = failure;
                    break;
                }
            }
        }
        Err(last_failure)
    };
    let session = kept_or_new_session(paths, entry, &key, false)?;
    let link = match ask_for_link(&session) {
        Ok(link) => link,
        Err(ApiFailure::NotFound) => ask_for_link(&kept_or_new_session(paths, entry, &key, true)?).map_err(|failure| match failure {
            ApiFailure::NotFound | ApiFailure::BadRequest(_) => format!("Composio has no app called \"{slug}\". Use its name on composio.dev/toolkits, such as gmail, slack, github or googlecalendar."),
            failure => failure.sentence(),
        })?,
        Err(ApiFailure::BadRequest(_)) => {
            return Err(format!("Composio has no app called \"{slug}\". Use its name on composio.dev/toolkits, such as gmail, slack, github or googlecalendar."))
        }
        Err(failure) => return Err(failure.sentence()),
    };
    if url::Url::parse(&link).map(|parsed| parsed.scheme() != "https" && !crate::http::is_loopback_address(&link)).unwrap_or(true) {
        return Err("Composio's link wasn't a web address.".into());
    }
    Ok(link)
}

/// The apps connected on Composio for the owner (toolkit slugs, active ones only), and kept in the state for `list`.
pub fn connected_apps(paths: &HubPaths, vault: &Vault, entry: &AppEntry) -> Result<Vec<String>, String> {
    let key = api_key(vault, entry).map_err(|_| format!("Paste your Composio API key on {}'s row first.", entry.name))?;
    let api = api_address(entry);
    let owner = url::form_urlencoded::byte_serialize(user_id(entry).as_bytes()).collect::<String>();
    let mut last_failure = ApiFailure::NotFound;
    for path in CONNECTED_ACCOUNT_PATHS {
        let address = format!("{api}{path}?user_ids={owner}&statuses=ACTIVE&limit=100");
        match get_json(&address, &key) {
            Ok(answer) => {
                let mut slugs: Vec<String> = answer
                    .get("items")
                    .and_then(Value::as_array)
                    .map(|items| {
                        items
                            .iter()
                            .filter(|item| item.get("status").and_then(Value::as_str).map(|status| status.eq_ignore_ascii_case("active")).unwrap_or(true))
                            .filter(|item| !item.get("is_disabled").and_then(Value::as_bool).unwrap_or(false))
                            .filter_map(|item| item.get("toolkit").and_then(|toolkit| toolkit.get("slug")).and_then(Value::as_str).map(str::to_lowercase))
                            .collect()
                    })
                    .unwrap_or_default();
                slugs.sort();
                slugs.dedup();
                let kept = slugs.clone();
                ConnectorState::record(paths, &entry.id, move |record| record.composio_connected_apps = Some(kept));
                return Ok(slugs);
            }
            Err(ApiFailure::NotFound) => continue,
            Err(failure) => {
                last_failure = failure;
                break;
            }
        }
    }
    Err(last_failure.sentence())
}

// ---------------------------------------------------------------------------------------------------------------------
// What a bot may do

fn is_code_runner(tool_name: &str) -> bool {
    let words = words_in_tool_name(tool_name);
    words.iter().any(|word| matches!(word.as_str(), "workbench" | "bash" | "python" | "shell" | "sandbox"))
}

fn runs_other_tools(tool_name: &str) -> bool {
    words_in_tool_name(tool_name).iter().any(|word| word == "execute")
}

fn manages_connections(tool_name: &str) -> bool {
    let words = words_in_tool_name(tool_name);
    words.iter().any(|word| word == "manage" || word == "connect") && words.iter().any(|word| word.starts_with("connection"))
}

/// Whether the hub judges this tool by each call's arguments rather than once by its name.
pub fn is_judged_per_call(tool_name: &str) -> bool {
    !is_code_runner(tool_name) && (runs_other_tools(tool_name) || manages_connections(tool_name))
}

/// How a Composio tool is listed. A tool judged per call is offered at every level (a reading bot may run reading
/// tools through it); what it really does is decided when it's called.
pub fn listed_effect(tool_name: &str, annotations: Option<&Value>) -> ToolEffect {
    if is_code_runner(tool_name) {
        ToolEffect::Irreversible
    } else if is_judged_per_call(tool_name) {
        ToolEffect::Reads
    } else {
        tool_effect(tool_name, annotations)
    }
}

/// `GMAIL_SEND_EMAIL`: capitals and digits in two or more parts joined by `_`.
fn looks_like_a_slug(text: &str) -> bool {
    let parts: Vec<&str> = text.split('_').collect();
    parts.len() >= 2
        && text.chars().next().map(|character| character.is_ascii_uppercase()).unwrap_or(false)
        && parts.iter().all(|part| !part.is_empty() && part.chars().all(|character| character.is_ascii_uppercase() || character.is_ascii_digit()))
}

/// The app tool slugs a call runs (`GMAIL_SEND_EMAIL`), wherever they are in its arguments: under a key that names a tool,
/// and any other text that is a slug on its own (so a slug under a key the hub doesn't know still counts; at worst a slug
/// quoted in a message makes the call count for more, never for less).
pub fn slugs_in(arguments: &Value) -> Vec<String> {
    fn walk(value: &Value, found: &mut Vec<String>) {
        match value {
            Value::String(text) if looks_like_a_slug(text) => found.push(text.clone()),
            Value::Object(object) => {
                for (key, inner) in object {
                    let key_names_a_tool = matches!(key.as_str(), "tool_slug" | "toolSlug" | "slug" | "tool" | "tool_name" | "toolName" | "action" | "action_name");
                    if key_names_a_tool {
                        if let Some(text) = inner.as_str() {
                            found.push(text.to_string());
                            continue;
                        }
                    }
                    walk(inner, found);
                }
            }
            Value::Array(items) => items.iter().for_each(|item| walk(item, found)),
            _ => {}
        }
    }
    let mut found = vec![];
    walk(arguments, &mut found);
    found
}

/// An HTTP method in the arguments (Composio's proxy runs a raw request on an app's API).
fn http_methods_in(arguments: &Value) -> Vec<String> {
    fn walk(value: &Value, found: &mut Vec<String>) {
        match value {
            Value::Object(object) => {
                for (key, inner) in object {
                    if key.eq_ignore_ascii_case("method") {
                        if let Some(text) = inner.as_str() {
                            found.push(text.to_uppercase());
                            continue;
                        }
                    }
                    walk(inner, found);
                }
            }
            Value::Array(items) => items.iter().for_each(|item| walk(item, found)),
            _ => {}
        }
    }
    let mut found = vec![];
    walk(arguments, &mut found);
    found
}

/// What one call of a Composio tool does: the most a call runs, judged by the slugs it runs with the usual word rule.
pub fn call_effect(tool_name: &str, listed: ToolEffect, arguments: &Value) -> ToolEffect {
    if is_code_runner(tool_name) {
        return ToolEffect::Irreversible;
    }
    if manages_connections(tool_name) && !runs_other_tools(tool_name) {
        // Making a link to connect an app changes nothing until the owner approves it in the browser. Taking a
        // connection away can't be undone by a bot (sessions are opened with removal off, so this is the second lock).
        let words = arguments.to_string().to_lowercase();
        let takes_away = ["remove", "delete", "disconnect", "revoke"].iter().any(|word| words.contains(word));
        return if takes_away { ToolEffect::Irreversible } else { ToolEffect::Reads };
    }
    if !runs_other_tools(tool_name) {
        return listed;
    }
    let slugs = slugs_in(arguments);
    let methods = http_methods_in(arguments);
    if slugs.is_empty() && methods.is_empty() {
        // Nothing says what it runs: only a bot allowed everything may.
        return ToolEffect::Irreversible;
    }
    let slug_effects = slugs.iter().map(|slug| tool_effect(slug, None));
    let method_effects = methods.iter().map(|method| match method.as_str() {
        "GET" | "HEAD" | "OPTIONS" => ToolEffect::Reads,
        _ => ToolEffect::Irreversible,
    });
    slug_effects.chain(method_effects).max().unwrap_or(ToolEffect::Irreversible)
}

/// What to call a refused call in its refusal: the slugs it tried to run, else the tool itself.
pub fn call_words(tool_name: &str, arguments: &Value) -> String {
    let slugs = slugs_in(arguments);
    if runs_other_tools(tool_name) && !slugs.is_empty() {
        slugs.join(", ")
    } else {
        tool_name.to_string()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_key_only_goes_to_composio() {
        let api = DEFAULT_API_ADDRESS;
        assert!(may_send_key_to("https://app.composio.dev/tool_router/v3/trs_1/mcp", api));
        assert!(may_send_key_to("https://backend.composio.dev/tool_router/trs_1/mcp", api));
        assert!(!may_send_key_to("https://composio.dev.evil.example/mcp", api));
        assert!(!may_send_key_to("http://app.composio.dev/mcp", api));
        assert!(!may_send_key_to("https://example.com/mcp", api));
        assert!(!may_send_key_to("http://127.0.0.1:9/mcp", api));
        assert!(may_send_key_to("http://127.0.0.1:9/mcp", "http://127.0.0.1:9"));
    }

    #[test]
    fn typed_names_become_toolkit_slugs() {
        assert_eq!(toolkit_slug("Google Calendar"), "googlecalendar");
        assert_eq!(toolkit_slug(" Gmail "), "gmail");
        assert_eq!(toolkit_slug("google-sheets"), "googlesheets");
    }

    #[test]
    fn runs_are_judged_by_the_tools_they_run() {
        let execute = "COMPOSIO_MULTI_EXECUTE_TOOL";
        assert_eq!(listed_effect(execute, None), ToolEffect::Reads);
        let reading = json!({"tools": [{"tool_slug": "GMAIL_FETCH_EMAILS", "arguments": {"max_results": 5}}, {"tool_slug": "GOOGLECALENDAR_EVENTS_LIST", "arguments": {}}]});
        assert_eq!(call_effect(execute, ToolEffect::Reads, &reading), ToolEffect::Reads);
        let drafting = json!({"tools": [{"tool_slug": "GMAIL_FETCH_EMAILS"}, {"tool_slug": "GMAIL_CREATE_EMAIL_DRAFT"}]});
        assert_eq!(call_effect(execute, ToolEffect::Reads, &drafting), ToolEffect::Changes);
        let sending = json!({"tools": [{"tool_slug": "GMAIL_CREATE_EMAIL_DRAFT"}, {"tool_slug": "GMAIL_SEND_EMAIL", "arguments": {"to": "a@b.c"}}]});
        assert_eq!(call_effect(execute, ToolEffect::Reads, &sending), ToolEffect::Irreversible);
        assert_eq!(call_words(execute, &sending), "GMAIL_CREATE_EMAIL_DRAFT, GMAIL_SEND_EMAIL");
        assert_eq!(call_effect(execute, ToolEffect::Reads, &json!({"tools": [{"tool_slug": "SLACK_CHAT_POST_MESSAGE"}]})), ToolEffect::Irreversible);
        assert_eq!(call_effect(execute, ToolEffect::Reads, &json!({"tools": [{"tool_slug": "GITHUB_CREATE_AN_ISSUE"}]})), ToolEffect::Changes);
        // Nothing readable: only `full` runs it.
        assert_eq!(call_effect(execute, ToolEffect::Reads, &json!({"thought": "do it"})), ToolEffect::Irreversible);
    }

    #[test]
    fn the_proxy_reads_only_with_get() {
        let proxy = "COMPOSIO_PROXY_EXECUTE";
        assert_eq!(call_effect(proxy, ToolEffect::Reads, &json!({"toolkit_slug": "github", "endpoint": "/user/repos", "method": "GET"})), ToolEffect::Reads);
        assert_eq!(call_effect(proxy, ToolEffect::Reads, &json!({"toolkit_slug": "github", "endpoint": "/repos/a/b", "method": "DELETE"})), ToolEffect::Irreversible);
    }

    #[test]
    fn code_runs_need_full_and_connection_links_are_free() {
        assert_eq!(listed_effect("COMPOSIO_REMOTE_WORKBENCH", None), ToolEffect::Irreversible);
        assert_eq!(listed_effect("COMPOSIO_REMOTE_BASH_TOOL", None), ToolEffect::Irreversible);
        assert_eq!(listed_effect("COMPOSIO_SEARCH_TOOLS", None), ToolEffect::Reads);
        assert_eq!(listed_effect("COMPOSIO_GET_TOOL_SCHEMAS", None), ToolEffect::Reads);
        let manage = "COMPOSIO_MANAGE_CONNECTIONS";
        assert_eq!(listed_effect(manage, None), ToolEffect::Reads);
        assert_eq!(call_effect(manage, ToolEffect::Reads, &json!({"toolkits": ["gmail"]})), ToolEffect::Reads);
        assert_eq!(call_effect(manage, ToolEffect::Reads, &json!({"toolkits": ["gmail"], "action": "remove"})), ToolEffect::Irreversible);
    }

    #[test]
    fn sessions_are_read_from_either_shape() {
        let answer = json!({"session_id": "trs_1", "mcp": {"type": "http", "url": "https://app.composio.dev/tool_router/v3/trs_1/mcp"}});
        assert_eq!(session_from_answer(&answer), Some(ComposioSession { id: "trs_1".into(), mcp_address: "https://app.composio.dev/tool_router/v3/trs_1/mcp".into() }));
        assert_eq!(session_from_answer(&json!({"session_id": "trs_1"})), None);
    }
}
