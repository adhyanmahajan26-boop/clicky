//! A small MCP client: JSON-RPC over a local command's standard input and output, or over streamable HTTP.
//!
//! Written here rather than taken from the official Rust SDK (`rmcp`): the hub needs only `initialize`, `tools/list` and
//! `tools/call`, it runs without an async runtime, and the SDK's API changes between major versions faster than this
//! contract may. Everything follows the MCP specification (2025-06-18, accepting servers on 2025-03-26 and 2024-11-05).

use serde_json::{json, Value};
use std::io::{BufRead, BufReader, Read, Write};
use std::process::{Child, ChildStdin, Command, Stdio};
use std::sync::mpsc::{Receiver, RecvTimeoutError};
use std::time::{Duration, Instant};

pub const LATEST_PROTOCOL_VERSION: &str = "2025-06-18";
pub const SUPPORTED_PROTOCOL_VERSIONS: &[&str] = &["2025-06-18", "2025-03-26", "2024-11-05"];

#[derive(Debug, Clone)]
pub enum McpError {
    /// The server wants a sign-in (HTTP 401). Holds its `WWW-Authenticate` header, which says where to sign in.
    NeedsSignIn { www_authenticate: Option<String> },
    /// The server answered the request with a JSON-RPC error.
    Refused { code: i64, message: String },
    /// Anything else: couldn't start, couldn't connect, timed out, answered nonsense.
    Failed(String),
}

impl std::fmt::Display for McpError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            McpError::NeedsSignIn { .. } => write!(formatter, "the app needs signing in"),
            McpError::Refused { code, message } => write!(formatter, "the app refused ({code}): {message}"),
            McpError::Failed(reason) => write!(formatter, "{reason}"),
        }
    }
}

/// A tool as a server describes it.
#[derive(Debug, Clone)]
pub struct ServerTool {
    pub name: String,
    pub description: Option<String>,
    pub input_schema: Value,
    pub annotations: Option<Value>,
    pub title: Option<String>,
}

impl ServerTool {
    fn from_value(value: &Value) -> Option<ServerTool> {
        Some(ServerTool {
            name: value.get("name")?.as_str()?.to_string(),
            description: value.get("description").and_then(Value::as_str).map(str::to_string),
            input_schema: value.get("inputSchema").cloned().unwrap_or_else(|| json!({"type": "object"})),
            annotations: value.get("annotations").cloned().filter(|annotations| annotations.is_object()),
            title: value.get("title").and_then(Value::as_str).map(str::to_string),
        })
    }
}

pub struct LocalCommand {
    pub program: std::path::PathBuf,
    pub arguments: Vec<String>,
    pub environment: Vec<(String, String)>,
    pub working_folder: Option<std::path::PathBuf>,
    /// Values that must never appear in an error message (secret settings), cut out of the server's last words.
    pub values_to_hide: Vec<String>,
}

enum Transport {
    LocalProcess(LocalProcessTransport),
    StreamableHttp(HttpTransport),
}

pub struct McpSession {
    transport: Transport,
    next_request_id: u64,
    pub negotiated_protocol_version: String,
    pub server_name: Option<String>,
}

impl McpSession {
    pub fn start_local(command: LocalCommand, timeout: Duration) -> Result<McpSession, McpError> {
        let transport = Transport::LocalProcess(LocalProcessTransport::start(command)?);
        McpSession::initialize(transport, timeout)
    }

    pub fn connect_http(server_address: &str, bearer_token: Option<String>, timeout: Duration) -> Result<McpSession, McpError> {
        let transport = Transport::StreamableHttp(HttpTransport {
            server_address: server_address.to_string(),
            bearer_token,
            session_id: None,
            protocol_version: None,
        });
        McpSession::initialize(transport, timeout)
    }

    fn initialize(transport: Transport, timeout: Duration) -> Result<McpSession, McpError> {
        let mut session = McpSession { transport, next_request_id: 1, negotiated_protocol_version: LATEST_PROTOCOL_VERSION.into(), server_name: None };
        let result = session.request(
            "initialize",
            json!({
                "protocolVersion": LATEST_PROTOCOL_VERSION,
                "capabilities": {},
                "clientInfo": {"name": "theo-connectors", "title": "Theo", "version": env!("CARGO_PKG_VERSION")}
            }),
            timeout,
        )?;
        let server_version = result.get("protocolVersion").and_then(Value::as_str).unwrap_or(LATEST_PROTOCOL_VERSION).to_string();
        if !SUPPORTED_PROTOCOL_VERSIONS.contains(&server_version.as_str()) {
            return Err(McpError::Failed(format!("the app speaks MCP {server_version}, which Theo doesn't know yet")));
        }
        session.server_name = result.pointer("/serverInfo/name").and_then(Value::as_str).map(str::to_string);
        session.negotiated_protocol_version = server_version.clone();
        if let Transport::StreamableHttp(http) = &mut session.transport {
            http.protocol_version = Some(server_version);
        }
        session.notify("notifications/initialized", json!({}))?;
        Ok(session)
    }

    pub fn list_tools(&mut self, timeout: Duration) -> Result<Vec<ServerTool>, McpError> {
        let mut tools = vec![];
        let mut page_cursor: Option<String> = None;
        // A server that keeps handing back cursors forever is cut off after 50 pages.
        for _ in 0..50 {
            let parameters = match &page_cursor {
                Some(cursor) => json!({"cursor": cursor}),
                None => json!({}),
            };
            let result = self.request("tools/list", parameters, timeout)?;
            for tool_value in result.get("tools").and_then(Value::as_array).cloned().unwrap_or_default() {
                if let Some(tool) = ServerTool::from_value(&tool_value) {
                    tools.push(tool);
                }
            }
            page_cursor = result.get("nextCursor").and_then(Value::as_str).filter(|cursor| !cursor.is_empty()).map(str::to_string);
            if page_cursor.is_none() {
                break;
            }
        }
        Ok(tools)
    }

    /// Runs one tool and returns MCP's own result object (`content`, `isError`, `structuredContent`) untouched.
    pub fn call_tool(&mut self, tool_name: &str, arguments: Value, timeout: Duration) -> Result<Value, McpError> {
        self.request("tools/call", json!({"name": tool_name, "arguments": arguments}), timeout)
    }

    pub fn request(&mut self, method: &str, parameters: Value, timeout: Duration) -> Result<Value, McpError> {
        let request_id = self.next_request_id;
        self.next_request_id += 1;
        let message = json!({"jsonrpc": "2.0", "id": request_id, "method": method, "params": parameters});
        let reply = match &mut self.transport {
            Transport::LocalProcess(local) => local.exchange(&message, request_id, timeout)?,
            Transport::StreamableHttp(http) => http.exchange(&message, request_id, timeout)?,
        };
        if let Some(error) = reply.get("error") {
            return Err(McpError::Refused {
                code: error.get("code").and_then(Value::as_i64).unwrap_or(0),
                message: error.get("message").and_then(Value::as_str).unwrap_or("no reason given").to_string(),
            });
        }
        Ok(reply.get("result").cloned().unwrap_or(Value::Null))
    }

    pub fn notify(&mut self, method: &str, parameters: Value) -> Result<(), McpError> {
        let message = json!({"jsonrpc": "2.0", "method": method, "params": parameters});
        match &mut self.transport {
            Transport::LocalProcess(local) => local.send(&message),
            Transport::StreamableHttp(http) => http.send_notification(&message),
        }
    }
}

// ---------------------------------------------------------------------------------------------------------------------
// A local command (stdio)

struct LocalProcessTransport {
    child: Child,
    child_input: Option<ChildStdin>,
    lines_from_child: Receiver<String>,
    last_error_line: std::sync::Arc<std::sync::Mutex<String>>,
    values_to_hide: Vec<String>,
}

impl LocalProcessTransport {
    fn start(command: LocalCommand) -> Result<LocalProcessTransport, McpError> {
        let (program, leading_arguments) = resolve_program_to_start(&command.program);
        let mut process = Command::new(&program);
        process.args(&leading_arguments).args(&command.arguments);
        for (name, value) in &command.environment {
            process.env(name, value);
        }
        if let Some(folder) = &command.working_folder {
            process.current_dir(folder);
        }
        process.stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(Stdio::piped());
        hide_console_window(&mut process);
        let mut child = process.spawn().map_err(|error| McpError::Failed(format!("couldn't start {}: {error}", command.program.display())))?;
        let child_output = child.stdout.take().expect("stdout was piped");
        let child_errors = child.stderr.take().expect("stderr was piped");
        let (line_sender, lines_from_child) = std::sync::mpsc::channel();
        std::thread::spawn(move || {
            for line in BufReader::new(child_output).lines() {
                let Ok(line) = line else { break };
                if line_sender.send(line).is_err() {
                    break;
                }
            }
        });
        let last_error_line = std::sync::Arc::new(std::sync::Mutex::new(String::new()));
        let last_error_line_for_reader = last_error_line.clone();
        std::thread::spawn(move || {
            for line in BufReader::new(child_errors).lines() {
                let Ok(line) = line else { break };
                if !line.trim().is_empty() {
                    *last_error_line_for_reader.lock().unwrap() = line.chars().take(300).collect();
                }
            }
        });
        Ok(LocalProcessTransport { child_input: child.stdin.take(), child, lines_from_child, last_error_line, values_to_hide: command.values_to_hide })
    }

    fn send(&mut self, message: &Value) -> Result<(), McpError> {
        let child_input = self.child_input.as_mut().ok_or_else(|| McpError::Failed("the app's input is closed".into()))?;
        let mut line = serde_json::to_string(message).map_err(|error| McpError::Failed(error.to_string()))?;
        line.push('\n');
        child_input.write_all(line.as_bytes()).and_then(|_| child_input.flush()).map_err(|_| self.exited_error())
    }

    fn exchange(&mut self, message: &Value, request_id: u64, timeout: Duration) -> Result<Value, McpError> {
        self.send(message)?;
        let deadline = Instant::now() + timeout;
        loop {
            let time_left = deadline.saturating_duration_since(Instant::now());
            let line = match self.lines_from_child.recv_timeout(time_left) {
                Ok(line) => line,
                Err(RecvTimeoutError::Timeout) => return Err(McpError::Failed(format!("the app didn't answer within {} seconds", timeout.as_secs()))),
                Err(RecvTimeoutError::Disconnected) => return Err(self.exited_error()),
            };
            let Ok(incoming) = serde_json::from_str::<Value>(&line) else { continue };
            if incoming.get("method").is_some() {
                if let Some(reply) = answer_server_request(&incoming) {
                    self.send(&reply)?;
                }
                continue;
            }
            if incoming.get("id").and_then(Value::as_u64) == Some(request_id) {
                return Ok(incoming);
            }
        }
    }

    fn exited_error(&mut self) -> McpError {
        std::thread::sleep(Duration::from_millis(100));
        let exit_description = match self.child.try_wait() {
            Ok(Some(status)) => format!("the app's command stopped ({status})"),
            _ => "the app's command stopped answering".to_string(),
        };
        let mut last_words = self.last_error_line.lock().unwrap().clone();
        for value in &self.values_to_hide {
            if !value.is_empty() {
                last_words = last_words.replace(value.as_str(), "•••");
            }
        }
        if last_words.is_empty() {
            McpError::Failed(exit_description)
        } else {
            McpError::Failed(format!("{exit_description}: {last_words}"))
        }
    }
}

impl Drop for LocalProcessTransport {
    fn drop(&mut self) {
        // Closing its input is how MCP asks a stdio server to stop; one that doesn't is ended.
        self.child_input.take();
        let deadline = Instant::now() + Duration::from_millis(800);
        while Instant::now() < deadline {
            if let Ok(Some(_)) = self.child.try_wait() {
                return;
            }
            std::thread::sleep(Duration::from_millis(20));
        }
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

/// What a server may ask the client in the middle of an exchange. The hub offers no roots, sampling or elicitation, so
/// only `ping` gets a real answer.
fn answer_server_request(incoming: &Value) -> Option<Value> {
    let request_id = incoming.get("id")?.clone();
    let method = incoming.get("method").and_then(Value::as_str).unwrap_or("");
    Some(match method {
        "ping" => json!({"jsonrpc": "2.0", "id": request_id, "result": {}}),
        "roots/list" => json!({"jsonrpc": "2.0", "id": request_id, "result": {"roots": []}}),
        _ => json!({"jsonrpc": "2.0", "id": request_id, "error": {"code": -32601, "message": "Theo's connector hub doesn't offer this"}}),
    })
}

/// Starts a command the way the user typed it: a bare name is looked up on PATH, and on Windows with the extensions a
/// shell would try (`npx` is `npx.cmd`), since Rust only adds `.exe` by itself. A Python script is run with Python.
pub fn resolve_program_to_start(program: &std::path::Path) -> (std::path::PathBuf, Vec<String>) {
    let extension = program.extension().map(|extension| extension.to_string_lossy().to_lowercase()).unwrap_or_default();
    if extension == "py" {
        let python = if cfg!(windows) { "python" } else { "python3" };
        return (std::path::PathBuf::from(python), vec![program.to_string_lossy().to_string()]);
    }
    if program.components().count() == 1 {
        if let Some(found) = find_on_path(&program.to_string_lossy()) {
            return (found, vec![]);
        }
    }
    (program.to_path_buf(), vec![])
}

pub fn find_on_path(program_name: &str) -> Option<std::path::PathBuf> {
    let extensions: Vec<String> = if cfg!(windows) {
        let path_extensions = std::env::var("PATHEXT").unwrap_or_else(|_| ".COM;.EXE;.BAT;.CMD".into());
        let mut extensions: Vec<String> = vec![String::new()];
        extensions.extend(path_extensions.split(';').filter(|extension| !extension.is_empty()).map(|extension| extension.to_lowercase()));
        extensions
    } else {
        vec![String::new()]
    };
    let search_path = std::env::var_os("PATH")?;
    for folder in std::env::split_paths(&search_path) {
        for extension in &extensions {
            let candidate = folder.join(format!("{program_name}{extension}"));
            if candidate.is_file() {
                return Some(candidate);
            }
        }
    }
    None
}

/// On Windows a console program started from a window-less app would flash a console window: this stops that, the same
/// way `theo-core/src/procs.rs` starts engines.
#[cfg(windows)]
pub fn hide_console_window(process: &mut Command) {
    use std::os::windows::process::CommandExt;
    const CREATE_NO_WINDOW: u32 = 0x0800_0000;
    process.creation_flags(CREATE_NO_WINDOW);
}

#[cfg(not(windows))]
pub fn hide_console_window(_process: &mut Command) {}

// ---------------------------------------------------------------------------------------------------------------------
// Streamable HTTP

struct HttpTransport {
    server_address: String,
    bearer_token: Option<String>,
    session_id: Option<String>,
    protocol_version: Option<String>,
}

impl HttpTransport {
    fn post(&mut self, message: &Value, timeout: Duration) -> Result<ureq::Response, McpError> {
        let mut request = crate::http::agent_for(&self.server_address)
            .post(&self.server_address)
            .timeout(timeout)
            .set("Content-Type", "application/json")
            .set("Accept", "application/json, text/event-stream");
        if let Some(token) = &self.bearer_token {
            request = request.set("Authorization", &format!("Bearer {token}"));
        }
        if let Some(session_id) = &self.session_id {
            request = request.set("Mcp-Session-Id", session_id);
        }
        if let Some(protocol_version) = &self.protocol_version {
            request = request.set("MCP-Protocol-Version", protocol_version);
        }
        let body = serde_json::to_string(message).map_err(|error| McpError::Failed(error.to_string()))?;
        match request.send_string(&body) {
            Ok(response) => {
                if let Some(session_id) = response.header("Mcp-Session-Id") {
                    self.session_id = Some(session_id.to_string());
                }
                Ok(response)
            }
            Err(ureq::Error::Status(401, response)) => Err(McpError::NeedsSignIn { www_authenticate: response.header("WWW-Authenticate").map(str::to_string) }),
            Err(ureq::Error::Status(403, response)) => {
                // `insufficient_scope` means signing in again with more scopes; anything else is a plain refusal.
                let www_authenticate = response.header("WWW-Authenticate").map(str::to_string);
                if www_authenticate.as_deref().map(|header| header.contains("insufficient_scope")).unwrap_or(false) {
                    Err(McpError::NeedsSignIn { www_authenticate })
                } else {
                    Err(McpError::Failed("the app refused this account (403)".into()))
                }
            }
            Err(ureq::Error::Status(status, response)) => {
                let detail: String = response.into_string().unwrap_or_default().chars().take(200).collect();
                Err(McpError::Failed(format!("the app answered {status}{}", if detail.trim().is_empty() { String::new() } else { format!(": {}", detail.trim()) })))
            }
            Err(ureq::Error::Transport(transport_error)) => Err(McpError::Failed(format!("couldn't reach the app: {transport_error}"))),
        }
    }

    fn send_notification(&mut self, message: &Value) -> Result<(), McpError> {
        self.post(message, Duration::from_secs(30)).map(|_| ())
    }

    fn exchange(&mut self, message: &Value, request_id: u64, timeout: Duration) -> Result<Value, McpError> {
        let response = self.post(message, timeout)?;
        let content_type = response.content_type().to_lowercase();
        if content_type.starts_with("text/event-stream") {
            return read_reply_from_event_stream(response.into_reader(), request_id);
        }
        let body = response.into_string().map_err(|error| McpError::Failed(format!("the app's answer was cut off: {error}")))?;
        let reply: Value = serde_json::from_str(&body).map_err(|_| McpError::Failed("the app's answer wasn't JSON".into()))?;
        // A batch answer holds ours among others.
        if let Some(batch) = reply.as_array() {
            return batch
                .iter()
                .find(|item| item.get("id").and_then(Value::as_u64) == Some(request_id))
                .cloned()
                .ok_or_else(|| McpError::Failed("the app's answer didn't include this request".into()));
        }
        Ok(reply)
    }
}

/// Reads server-sent events until the one carrying the reply to `request_id`. Events for other messages (progress,
/// logging) are passed over.
fn read_reply_from_event_stream(stream: impl Read, request_id: u64) -> Result<Value, McpError> {
    let mut event_data = String::new();
    for line in BufReader::new(stream).lines() {
        let line = line.map_err(|error| McpError::Failed(format!("the app's event stream broke: {error}")))?;
        if line.is_empty() {
            if !event_data.is_empty() {
                if let Ok(message) = serde_json::from_str::<Value>(&event_data) {
                    if message.get("id").and_then(Value::as_u64) == Some(request_id) && message.get("method").is_none() {
                        return Ok(message);
                    }
                }
                event_data.clear();
            }
            continue;
        }
        if let Some(data) = line.strip_prefix("data:") {
            if !event_data.is_empty() {
                event_data.push('\n');
            }
            event_data.push_str(data.strip_prefix(' ').unwrap_or(data));
        }
    }
    if !event_data.is_empty() {
        if let Ok(message) = serde_json::from_str::<Value>(&event_data) {
            if message.get("id").and_then(Value::as_u64) == Some(request_id) {
                return Ok(message);
            }
        }
    }
    Err(McpError::Failed("the app's event stream ended without an answer".into()))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_reply_is_found_in_an_event_stream() {
        let stream = "event: message\ndata: {\"jsonrpc\":\"2.0\",\"method\":\"notifications/progress\",\"params\":{}}\n\n: comment\ndata: {\"jsonrpc\":\"2.0\",\ndata: \"id\":7,\"result\":{\"ok\":true}}\n\n";
        let reply = read_reply_from_event_stream(stream.as_bytes(), 7).unwrap();
        assert_eq!(reply["result"]["ok"], true);
        assert!(read_reply_from_event_stream(stream.as_bytes(), 8).is_err());
    }
}
