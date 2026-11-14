//! Running one engine process: start it in its own process tree, read its stream, enforce the time limit, stop it.

use crate::procs::{ProcessTree, Registry};
use crate::usage::TurnUsage;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::Duration;
use tokio::io::AsyncReadExt;
use tokio::sync::Notify;

/// The most of one output line that's looked at. An engine can print an 8 MB line.
pub const MAX_LINE: usize = 1 << 20;
/// The most reply text kept in memory.
pub const MAX_TEXT: usize = 4 << 20;

#[derive(Default)]
pub struct Cancel {
    flag: AtomicBool,
    notify: Notify,
}

impl Cancel {
    pub fn new() -> Arc<Self> { Arc::new(Self::default()) }
    pub fn cancel(&self) {
        self.flag.store(true, Ordering::SeqCst);
        self.notify.notify_waiters();
    }
    pub fn is_cancelled(&self) -> bool { self.flag.load(Ordering::SeqCst) }
    pub async fn cancelled(&self) {
        loop {
            let waiter = self.notify.notified();
            if self.is_cancelled() {
                return;
            }
            waiter.await;
        }
    }
}

/// The shape of an engine's output: Claude Code's and OpenCode's stream-json, Codex's `exec --json` events, Cursor Agent's
/// stream-json, Gemini CLI's one JSON object (`--output-format json`) and Grok's `streaming-messages-json`.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Format { Claude, OpenCode, Codex, Cursor, Gemini, Grok }

pub struct Spec {
    pub program: PathBuf,
    pub args: Vec<String>,
    pub env: Vec<(String, String)>,
    pub remove_env: Vec<String>,
    pub cwd: PathBuf,
    pub limit: Duration,
    pub format: Format,
    /// Written to the engine's standard input, then closed. The prompt goes here rather than on the command line: Windows
    /// caps a command line at 32,767 characters (8,191 through cmd.exe) and cmd.exe cuts an argument at its first line break.
    pub stdin: Option<String>,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub enum EndReason { Exited, Timeout, Cancelled }

#[derive(Debug)]
pub struct Outcome {
    pub text: String,
    pub session_id: Option<String>,
    pub error: Option<String>,
    pub exit_code: Option<i32>,
    pub end: EndReason,
    pub stderr_tail: String,
    pub usage: Option<TurnUsage>,
    pub truncated: bool,
    /// What the engine printed that wasn't read as a reply or an error (Gemini's plain output), for the error words.
    pub unread_output: String,
}

/// Reads an engine's stream-json lines into a reply.
#[derive(Default)]
pub struct StreamParser {
    pub text: String,
    pub session_id: Option<String>,
    pub error: Option<String>,
    pub usage: Option<TurnUsage>,
    pub saw_delta: bool,
    pub truncated: bool,
    final_text: Option<String>,
    /// Cursor: a tool ran since the last words, so the next words start a new paragraph.
    tool_since_text: bool,
    /// Gemini: its whole output, read as one JSON object at the end.
    raw: String,
    /// Cursor: the result's text replaces what streamed.
    final_wins: bool,
}

impl StreamParser {
    fn push(&mut self, piece: &str) {
        if self.text.len() + piece.len() > MAX_TEXT {
            let room = MAX_TEXT.saturating_sub(self.text.len());
            let mut cut = room.min(piece.len());
            while cut > 0 && !piece.is_char_boundary(cut) {
                cut -= 1;
            }
            self.text.push_str(&piece[..cut]);
            self.truncated = true;
        } else {
            self.text.push_str(piece);
        }
    }

    /// One line. True when the visible text changed.
    pub fn consume(&mut self, line: &str, format: Format) -> bool {
        if format == Format::Gemini {
            // One JSON object over many lines: kept whole and read in `finish`.
            if self.raw.len() + line.len() < MAX_TEXT {
                self.raw.push_str(line);
                self.raw.push('\n');
            }
            return false;
        }
        let line = line.trim();
        if !line.starts_with('{') {
            return false;
        }
        let Ok(event) = serde_json::from_str::<serde_json::Value>(line) else { return false };
        let kind = event.get("type").and_then(|t| t.as_str()).unwrap_or("");
        if let Some(id) = event.get("session_id").or_else(|| event.get("sessionID")).or_else(|| if format == Format::Codex && kind == "thread.started" { event.get("thread_id") } else { None }).and_then(|s| s.as_str()) {
            if !id.is_empty() {
                self.session_id = Some(id.to_string());
            }
        }
        match format {
            Format::Claude => match kind {
                "stream_event" => {
                    let inner = &event["event"];
                    match inner["type"].as_str() {
                        Some("content_block_delta") if inner["delta"]["type"] == "text_delta" => {
                            if let Some(piece) = inner["delta"]["text"].as_str() {
                                self.saw_delta = true;
                                self.push(piece);
                                return true;
                            }
                        }
                        // A new text block after a tool call reads as a new paragraph.
                        Some("content_block_start") if inner["content_block"]["type"] == "text" => {
                            if !self.text.is_empty() && !self.text.ends_with('\n') {
                                self.push("\n\n");
                            }
                        }
                        _ => {}
                    }
                }
                // Claude Code's own message about a failed request (signed out, no credit, the API down) comes as an assistant
                // message marked with `error`. It's not the bot speaking, so it's the turn's error, not its reply.
                "assistant" if event.get("error").map(|e| !e.is_null()).unwrap_or(false) => {
                    let said: Vec<&str> = event["message"]["content"].as_array().into_iter().flatten().filter_map(|b| b["text"].as_str()).collect();
                    let said = said.join("\n");
                    let code = event["error"].as_str().unwrap_or("error");
                    self.error = Some(if said.trim().is_empty() { format!("Claude Code reported an error ({code}).") } else { said });
                }
                "assistant" if !self.saw_delta => {
                    if let Some(blocks) = event["message"]["content"].as_array() {
                        for block in blocks {
                            if block["type"] == "text" {
                                if let Some(t) = block["text"].as_str() {
                                    if !self.text.is_empty() {
                                        self.push("\n\n");
                                    }
                                    self.push(t);
                                }
                            }
                        }
                        return true;
                    }
                }
                "result" => {
                    self.usage = TurnUsage::from_claude_result(&event);
                    let result = event.get("result").and_then(|r| r.as_str()).map(str::to_string);
                    if event.get("is_error").and_then(|e| e.as_bool()).unwrap_or(false) || event.get("subtype").and_then(|s| s.as_str()).map(|s| s.starts_with("error")).unwrap_or(false) {
                        let reported = self.error.take();
                        self.error = Some(result.filter(|r| !r.trim().is_empty()).or(reported).unwrap_or_else(|| "Claude reported an error.".to_string()));
                    } else {
                        self.final_text = result;
                    }
                }
                _ => {}
            },
            Format::OpenCode => match kind {
                "text" => {
                    if let Some(t) = event["part"]["text"].as_str() {
                        if !self.text.is_empty() {
                            self.push("\n\n");
                        }
                        self.push(t);
                        return true;
                    }
                }
                "error" => {
                    let message = event["error"]["data"]["message"].as_str().or_else(|| event["error"]["message"].as_str()).unwrap_or("OpenCode reported an error.");
                    self.error = Some(message.to_string());
                }
                "step_finish" => {
                    let part = &event["part"];
                    let tokens = &part["tokens"];
                    let n = |v: &serde_json::Value| v.as_u64().unwrap_or(0);
                    let step = TurnUsage {
                        input_tokens: n(&tokens["input"]),
                        output_tokens: n(&tokens["output"]) + n(&tokens["reasoning"]),
                        cache_read_tokens: n(&tokens["cache"]["read"]),
                        cache_write_tokens: n(&tokens["cache"]["write"]),
                        cost_usd: part["cost"].as_f64(),
                    };
                    if !step.is_empty() {
                        self.usage.get_or_insert_with(TurnUsage::default).add(&step);
                    }
                }
                _ => {}
            },
            Format::Codex => match kind {
                // Only the agent's messages are the reply, and the last one is the answer (earlier ones say what it's about
                // to do); "error" items are warnings.
                "item.completed" if event["item"]["type"] == "agent_message" => {
                    if let Some(message) = event["item"]["text"].as_str().filter(|m| !m.is_empty()) {
                        self.text.clear();
                        self.push(message);
                        return true;
                    }
                }
                "turn.completed" => {
                    let usage = &event["usage"];
                    let n = |v: &serde_json::Value| v.as_u64().unwrap_or(0);
                    let step = TurnUsage { input_tokens: n(&usage["input_tokens"]), output_tokens: n(&usage["output_tokens"]), cache_read_tokens: n(&usage["cached_input_tokens"]), cache_write_tokens: 0, cost_usd: None };
                    if !step.is_empty() {
                        self.usage.get_or_insert_with(TurnUsage::default).add(&step);
                    }
                }
                "turn.failed" => self.error = Some(event["error"]["message"].as_str().unwrap_or("Codex reported an error.").to_string()),
                "error" => {
                    if let Some(message) = event["message"].as_str() {
                        self.error = Some(message.to_string());
                    }
                }
                _ => {}
            },
            Format::Cursor => match kind {
                "assistant" => {
                    let chunk: String = event["message"]["content"].as_array().into_iter().flatten().filter(|b| b["type"] == "text").filter_map(|b| b["text"].as_str()).collect();
                    if chunk.is_empty() {
                        return false;
                    }
                    // With --stream-partial-output the pieces carry timestamp_ms; the whole message repeats at the end without one.
                    if event.get("timestamp_ms").is_some() {
                        self.saw_delta = true;
                    } else if self.saw_delta {
                        return false;
                    }
                    if self.tool_since_text && !self.text.is_empty() {
                        self.push("\n\n");
                    }
                    self.tool_since_text = false;
                    self.push(&chunk);
                    return true;
                }
                "tool_call" => {
                    if !self.text.is_empty() {
                        self.tool_since_text = true;
                    }
                }
                "result" => {
                    let failed = event["is_error"].as_bool().unwrap_or(false) || event["subtype"].as_str().map(|s| s != "success").unwrap_or(false);
                    if failed {
                        self.error = Some(event["result"].as_str().filter(|r| !r.trim().is_empty()).unwrap_or("Cursor Agent reported an error.").to_string());
                    } else if let Some(result) = event["result"].as_str().filter(|r| !r.is_empty()) {
                        self.final_text = Some(result.to_string());
                        self.final_wins = true;
                    }
                }
                _ => {}
            },
            // Only the final message is the reply; the notes Grok writes between tool calls are left out.
            Format::Grok => {
                if kind == "result" {
                    if event["is_error"].as_bool().unwrap_or(false) {
                        self.error = Some(grok_error(&event).unwrap_or_else(|| "Grok reported an error.".to_string()));
                    } else if let Some(result) = event["result"].as_str() {
                        self.text.clear();
                        self.push(result);
                        return true;
                    }
                }
            }
            Format::Gemini => {}
        }
        false
    }

    pub fn finish(&mut self) {
        if !self.raw.is_empty() {
            let raw = std::mem::take(&mut self.raw);
            if let (Some(start), Some(end)) = (raw.find('{'), raw.rfind('}')) {
                if let Ok(object) = serde_json::from_str::<serde_json::Value>(&raw[start..=end]) {
                    if let Some(response) = object["response"].as_str().filter(|r| !r.trim().is_empty()) {
                        self.text.clear();
                        self.push(response.trim());
                    } else if let Some(message) = object["error"]["message"].as_str() {
                        self.error = Some(message.to_string());
                    }
                    if let Some(id) = object["session_id"].as_str().filter(|id| !id.is_empty()) {
                        self.session_id = Some(id.to_string());
                    }
                }
            }
            if self.text.is_empty() && self.error.is_none() {
                self.raw = raw;
            }
        }
        // Cursor's whole answer at the end is the reply when it has one (the Mac's `final ?? streamed`).
        if self.final_wins {
            if let Some(t) = self.final_text.take().filter(|t| !t.trim().is_empty()) {
                self.text = t;
            }
        }
        if self.text.trim().is_empty() {
            if let Some(t) = self.final_text.take() {
                self.text = t;
            }
        }
    }

    /// What the engine printed when it gave no reply and no error of its own (Gemini's raw output), for the error words.
    pub fn unread_output(&self) -> &str {
        &self.raw
    }
}

/// Grok's own words for a failed turn. It puts them in the result event's `errors` list, often as `Internal error: {"message":
/// "API error (status 402 …): …", …}`, so the innermost message is read out (the Mac's `EngineFailureText.grok`).
fn grok_error(event: &serde_json::Value) -> Option<String> {
    let mut candidates: Vec<&str> = event["errors"].as_array().into_iter().flatten().filter_map(|e| e.as_str()).collect();
    if let Some(result) = event["result"].as_str() {
        candidates.push(result);
    }
    candidates.into_iter().map(innermost_message).find(|text| !text.is_empty())
}

fn innermost_message(text: &str) -> String {
    let cut = |t: &str| t.trim().chars().take(300).collect::<String>();
    if let (Some(start), Some(end)) = (text.find('{'), text.rfind('}')) {
        if start < end {
            if let Ok(object) = serde_json::from_str::<serde_json::Value>(&text[start..=end]) {
                for found in [&object["message"], &object["error"]["message"], &object["error"]] {
                    if let Some(message) = found.as_str().filter(|m| !m.trim().is_empty()) {
                        return cut(message);
                    }
                }
            }
        }
    }
    cut(text)
}

/// How a program is started: a Python stand-in through Python; anything else as itself.
///
/// An npm-installed program on Windows is a `.cmd` shim (`%APPDATA%\npm\claude.cmd`). Going through cmd.exe would cut every
/// argument at its first line break and cap the whole command at 8,191 characters, so the shim is read and what it points
/// at is started directly: the package's own `.exe`, or its script with Node.
pub fn command_for(program: &std::path::Path) -> (PathBuf, Vec<String>) {
    let ext = program.extension().map(|e| e.to_string_lossy().to_lowercase()).unwrap_or_default();
    if ext == "py" {
        let python = if cfg!(windows) { "python" } else { "python3" };
        return (PathBuf::from(python), vec![program.to_string_lossy().to_string()]);
    }
    if cfg!(windows) && (ext == "cmd" || ext == "bat") {
        if let Some(direct) = std::fs::read_to_string(program).ok().and_then(|text| npm_shim_target(&text, program.parent().unwrap_or(std::path::Path::new(".")))) {
            return direct;
        }
        // Any other batch file is started as itself: Rust runs it through cmd.exe with cmd's own quoting (and refuses an
        // argument it can't pass safely), where a hand-made `cmd /C` line breaks on a space in the path.
        return (program.to_path_buf(), vec![]);
    }
    (program.to_path_buf(), vec![])
}

/// What an npm `.cmd` shim runs, read from the shim itself: `"%dp0%\node_modules\pkg\bin\tool.exe" %*` is that `.exe`;
/// `"%_prog%" "%dp0%\node_modules\pkg\cli.js" %*` is that script with Node (the shim's own `node.exe` beside it if there
/// is one, as npm does). None when the shim isn't npm's or what it names isn't there.
pub fn npm_shim_target(shim_text: &str, shim_dir: &std::path::Path) -> Option<(PathBuf, Vec<String>)> {
    if shim_text.len() > 64 * 1024 {
        return None;
    }
    let mut target: Option<String> = None;
    for marker in ["\"%dp0%\\", "\"%~dp0\\"] {
        let mut rest = shim_text;
        while let Some(start) = rest.find(marker) {
            let after = &rest[start + marker.len()..];
            let Some(end) = after.find('"') else { break };
            let candidate = &after[..end];
            // The program the shim runs is the last quoted path in it; the ones before are the `node.exe` checks.
            if !candidate.eq_ignore_ascii_case("node.exe") && !candidate.eq_ignore_ascii_case("node") {
                target = Some(candidate.to_string());
            }
            rest = &after[end..];
        }
    }
    let relative = target?;
    if relative.split(['\\', '/']).any(|part| part == "..") {
        return None;
    }
    let mut path = shim_dir.to_path_buf();
    for part in relative.split(['\\', '/']).filter(|p| !p.is_empty()) {
        path.push(part);
    }
    if !path.is_file() {
        return None;
    }
    let ext = path.extension().map(|e| e.to_string_lossy().to_lowercase()).unwrap_or_default();
    match ext.as_str() {
        "exe" => Some((path, vec![])),
        "js" | "cjs" | "mjs" => {
            let beside = shim_dir.join("node.exe");
            let node = if beside.is_file() { beside } else { locate("node").unwrap_or_else(|| PathBuf::from("node")) };
            Some((node, vec![path.to_string_lossy().to_string()]))
        }
        _ => None,
    }
}

/// Splits a byte stream into lines, keeping at most `MAX_LINE` of each.
struct LineSplitter {
    buffer: Vec<u8>,
    overflowing: bool,
}

impl LineSplitter {
    fn feed(&mut self, chunk: &[u8], out: &mut Vec<String>) {
        for &byte in chunk {
            if byte == b'\n' {
                if !self.overflowing {
                    out.push(String::from_utf8_lossy(&self.buffer).to_string());
                }
                self.buffer.clear();
                self.overflowing = false;
            } else if self.buffer.len() < MAX_LINE {
                self.buffer.push(byte);
            } else {
                // A line that never ends is dropped whole: half of a JSON object is noise.
                self.overflowing = true;
            }
        }
    }
}

pub async fn run(spec: Spec, cancel: Arc<Cancel>, registry: Option<Arc<Registry>>, on_text: impl Fn(&str) + Send + Sync + 'static) -> std::io::Result<Outcome> {
    let (program, mut pre_args) = command_for(&spec.program);
    pre_args.extend(spec.args.iter().cloned());
    let mut cmd = tokio::process::Command::new(&program);
    if cfg!(windows) {
        cmd.env("PATH", child_path());
    }
    cmd.args(&pre_args).current_dir(&spec.cwd).stdin(if spec.stdin.is_some() { std::process::Stdio::piped() } else { std::process::Stdio::null() }).stdout(std::process::Stdio::piped()).stderr(std::process::Stdio::piped());
    for key in &spec.remove_env {
        cmd.env_remove(key);
    }
    for (k, v) in &spec.env {
        cmd.env(k, v);
    }
    cmd.kill_on_drop(false);
    crate::procs::configure(&mut cmd);
    let mut child = cmd.spawn()?;
    let tree = match ProcessTree::attach(&child) {
        Ok(tree) => Arc::new(tree),
        Err(e) => {
            // Not tracked means it couldn't be stopped later: end it now rather than leave it running.
            let _ = child.start_kill();
            return Err(e);
        }
    };
    if let Some(r) = &registry {
        r.add(&tree);
    }
    if let (Some(text), Some(mut input)) = (spec.stdin.clone(), child.stdin.take()) {
        // Written on its own task: an engine that answers before it has read everything mustn't block on a full pipe.
        tokio::spawn(async move {
            use tokio::io::AsyncWriteExt;
            let _ = input.write_all(text.as_bytes()).await;
            let _ = input.shutdown().await;
        });
    }
    let stdout = child.stdout.take().unwrap();
    let stderr = child.stderr.take().unwrap();
    let format = spec.format;
    let on_text = Arc::new(on_text);

    let parser = Arc::new(std::sync::Mutex::new(StreamParser::default()));
    let reader = {
        let parser = parser.clone();
        let on_text = on_text.clone();
        tokio::spawn(async move {
            let mut stdout = stdout;
            let mut splitter = LineSplitter { buffer: vec![], overflowing: false };
            let mut chunk = vec![0u8; 64 * 1024];
            let mut last_shown = std::time::Instant::now() - Duration::from_secs(1);
            loop {
                let n = match stdout.read(&mut chunk).await {
                    Ok(0) | Err(_) => break,
                    Ok(n) => n,
                };
                let mut lines = vec![];
                splitter.feed(&chunk[..n], &mut lines);
                let mut changed = false;
                {
                    let mut p = parser.lock().unwrap();
                    for line in &lines {
                        changed |= p.consume(line, format);
                    }
                }
                // The live text is shown at most 20 times a second, however fast the engine floods.
                if changed && last_shown.elapsed() >= Duration::from_millis(50) {
                    let text = parser.lock().unwrap().text.chars().take(20_000).collect::<String>();
                    on_text(&text);
                    last_shown = std::time::Instant::now();
                }
            }
            if !splitter.buffer.is_empty() && !splitter.overflowing {
                let line = String::from_utf8_lossy(&splitter.buffer).to_string();
                parser.lock().unwrap().consume(&line, format);
            }
        })
    };
    let err_reader = tokio::spawn(async move {
        let mut stderr = stderr;
        let mut tail: Vec<u8> = vec![];
        let mut chunk = vec![0u8; 16 * 1024];
        loop {
            match stderr.read(&mut chunk).await {
                Ok(0) | Err(_) => break,
                Ok(n) => {
                    tail.extend_from_slice(&chunk[..n]);
                    if tail.len() > 256 * 1024 {
                        tail.drain(..tail.len() - 64 * 1024);
                    }
                }
            }
        }
        String::from_utf8_lossy(&tail).to_string()
    });

    let mut end = EndReason::Exited;
    let status = tokio::select! {
        s = child.wait() => s.ok(),
        _ = tokio::time::sleep(spec.limit) => { end = EndReason::Timeout; None }
        _ = cancel.cancelled() => { end = EndReason::Cancelled; None }
    };
    let status = match status {
        Some(s) => Some(s),
        None => {
            // Asked nicely first, then made to stop: something that ignores SIGTERM still ends.
            tree.terminate();
            match tokio::time::timeout(Duration::from_secs(3), child.wait()).await {
                Ok(s) => {
                    tree.kill();
                    s.ok()
                }
                Err(_) => {
                    tree.kill();
                    tokio::time::timeout(Duration::from_secs(5), child.wait()).await.ok().and_then(|s| s.ok())
                }
            }
        }
    };
    // The engine is done. Whatever it left in its tree (a tool child that ignores SIGTERM) goes with it, and a child that
    // slipped out and still holds the output pipe can't hold the turn open: reading stops shortly after.
    if tree.alive() {
        tree.terminate();
        tokio::time::sleep(Duration::from_millis(300)).await;
        tree.kill();
    }
    let _ = tokio::time::timeout(Duration::from_millis(1500), reader).await;
    let stderr_tail = tokio::time::timeout(Duration::from_millis(500), err_reader).await.ok().and_then(|r| r.ok()).unwrap_or_default();
    if let Some(r) = &registry {
        r.remove(&tree);
    }
    let mut p = std::mem::take(&mut *parser.lock().unwrap());
    p.finish();
    on_text(&p.text.chars().take(20_000).collect::<String>());
    let unread_output: String = p.unread_output().chars().take(20_000).collect();
    Ok(Outcome {
        text: p.text,
        session_id: p.session_id,
        error: p.error,
        exit_code: status.and_then(|s| s.code()),
        end,
        stderr_tail: stderr_tail.chars().rev().take(20_000).collect::<Vec<_>>().into_iter().rev().collect(),
        usage: p.usage,
        truncated: p.truncated,
        unread_output,
    })
}

/// The folders programs are looked for in, in order: this process's PATH and, on Windows, PATH as it is now in the registry
/// (for you and for the machine) plus where Node, Git and the GitHub CLI install. Theo keeps running in the tray for days, so
/// something installed since it started (Node, Git, Claude Code's own installer adding `.local\bin`) is found without
/// quitting it. Also the PATH every engine and tool Theo starts gets, so Claude Code finds Git Bash and npm's shims find Node.
pub fn search_dirs() -> Vec<PathBuf> {
    let mut dirs: Vec<PathBuf> = std::env::var_os("PATH").map(|p| std::env::split_paths(&p).collect()).unwrap_or_default();
    #[cfg(windows)]
    {
        for user in [true, false] {
            if let Some(path) = registry_path(user) {
                dirs.extend(std::env::split_paths(&std::ffi::OsString::from(path)));
            }
        }
        for (var, rest) in [("ProgramFiles", "nodejs"), ("ProgramFiles", "Git\\cmd"), ("ProgramFiles", "GitHub CLI"), ("LOCALAPPDATA", "Programs\\Git\\cmd"), ("APPDATA", "npm")] {
            if let Some(base) = std::env::var_os(var) {
                dirs.push(PathBuf::from(base).join(rest));
            }
        }
        dirs.push(crate::paths::home().join(".local").join("bin"));
    }
    let mut seen = std::collections::HashSet::new();
    dirs.retain(|d| !d.as_os_str().is_empty() && seen.insert(if cfg!(windows) { d.to_string_lossy().to_lowercase() } else { d.to_string_lossy().to_string() }));
    dirs
}

/// The PATH for a program Theo starts (see `search_dirs`).
pub fn child_path() -> std::ffi::OsString {
    std::env::join_paths(search_dirs()).unwrap_or_else(|_| std::env::var_os("PATH").unwrap_or_default())
}

/// PATH as saved in the registry, for this user or for the machine, with %VARIABLES% expanded.
#[cfg(windows)]
fn registry_path(user: bool) -> Option<String> {
    use windows_sys::Win32::System::Environment::ExpandEnvironmentStringsW;
    use windows_sys::Win32::System::Registry::*;
    let (root, key) = if user { (HKEY_CURRENT_USER, "Environment") } else { (HKEY_LOCAL_MACHINE, "SYSTEM\\CurrentControlSet\\Control\\Session Manager\\Environment") };
    let key: Vec<u16> = key.encode_utf16().chain(Some(0)).collect();
    let name: Vec<u16> = "Path".encode_utf16().chain(Some(0)).collect();
    unsafe {
        let mut bytes: u32 = 0;
        if RegGetValueW(root, key.as_ptr(), name.as_ptr(), RRF_RT_REG_SZ | RRF_RT_REG_EXPAND_SZ | RRF_NOEXPAND, std::ptr::null_mut(), std::ptr::null_mut(), &mut bytes) != 0 || bytes == 0 {
            return None;
        }
        let mut raw = vec![0u16; bytes as usize / 2 + 1];
        let mut size = (raw.len() * 2) as u32;
        if RegGetValueW(root, key.as_ptr(), name.as_ptr(), RRF_RT_REG_SZ | RRF_RT_REG_EXPAND_SZ | RRF_NOEXPAND, std::ptr::null_mut(), raw.as_mut_ptr() as *mut _, &mut size) != 0 {
            return None;
        }
        let needed = ExpandEnvironmentStringsW(raw.as_ptr(), std::ptr::null_mut(), 0);
        if needed == 0 {
            return None;
        }
        let mut expanded = vec![0u16; needed as usize];
        let written = ExpandEnvironmentStringsW(raw.as_ptr(), expanded.as_mut_ptr(), needed);
        if written == 0 {
            return None;
        }
        let end = expanded.iter().position(|&c| c == 0).unwrap_or(expanded.len());
        Some(String::from_utf16_lossy(&expanded[..end]))
    }
}

/// A command for a program Theo starts in the background: no console window on Windows, its own process group, and the
/// PATH from `child_path`. `program` may be an npm shim or a Python stand-in (`command_for`).
pub fn background_command(program: &std::path::Path) -> tokio::process::Command {
    let (program, pre) = command_for(program);
    let mut cmd = tokio::process::Command::new(program);
    cmd.args(pre);
    if cfg!(windows) {
        cmd.env("PATH", child_path());
    }
    crate::procs::configure(&mut cmd);
    cmd
}

/// Runs a short background program to its end and returns its exit code and output (stdout, then stderr), or None if it
/// couldn't start or took longer than `limit`. Everything it started (Claude Code's MCP servers, say) ends with it.
pub async fn run_briefly(program: &std::path::Path, args: &[&str], cwd: &std::path::Path, limit: Duration) -> Option<(i32, String, String)> {
    let mut cmd = background_command(program);
    cmd.args(args).current_dir(cwd).env("NO_COLOR", "1").stdin(std::process::Stdio::null()).stdout(std::process::Stdio::piped()).stderr(std::process::Stdio::piped()).kill_on_drop(true);
    let child = cmd.spawn().ok()?;
    let tree = ProcessTree::attach(&child).ok();
    let result = tokio::time::timeout(limit, child.wait_with_output()).await;
    if let Some(tree) = &tree {
        // Whatever it left behind (or all of it, after a timeout).
        if tree.alive() {
            tree.kill();
        }
    }
    let out = result.ok()?.ok()?;
    Some((out.status.code().unwrap_or(-1), String::from_utf8_lossy(&out.stdout).to_string(), String::from_utf8_lossy(&out.stderr).to_string()))
}

/// Where an engine's program is: on PATH, or where its installer puts it.
pub fn locate(name: &str) -> Option<PathBuf> {
    let home = crate::paths::home();
    let exts: Vec<&str> = if cfg!(windows) { vec![".exe", ".cmd", ".bat", ""] } else { vec![""] };
    let mut dirs = search_dirs();
    // Each part joined on its own, so a Windows path reads C:\Users\me\.local\bin, never .local/bin.
    dirs.extend([
        home.join(".local").join("bin"),
        home.join(format!(".{name}")).join("local"),
        home.join(format!(".{name}")).join("bin"),
        home.join(".npm-global").join("bin"),
        home.join(".bun").join("bin"),
        PathBuf::from("/opt/homebrew/bin"),
        PathBuf::from("/usr/local/bin"),
        PathBuf::from("/usr/bin"),
    ]);
    if let Some(appdata) = std::env::var_os("APPDATA") {
        dirs.push(PathBuf::from(appdata).join("npm"));
    }
    for dir in dirs {
        for ext in &exts {
            let candidate = dir.join(format!("{name}{ext}"));
            if candidate.is_file() {
                return Some(candidate);
            }
        }
    }
    None
}

#[cfg(test)]
mod tests {

    #[test]
    fn grok_says_its_own_error_not_a_generic_one() {
        let mut parser = StreamParser::default();
        let line = r#"{"type":"result","is_error":true,"result":"","errors":["Internal error: {\"message\": \"API error (status 402 Payment Required): Grok Build usage balance exhausted\", \"http_status\": 402}"]}"#;
        parser.consume(line, Format::Grok);
        assert_eq!(parser.error.as_deref(), Some("API error (status 402 Payment Required): Grok Build usage balance exhausted"));
        let mut bare = StreamParser::default();
        bare.consume(r#"{"type":"result","is_error":true}"#, Format::Grok);
        assert_eq!(bare.error.as_deref(), Some("Grok reported an error."));
    }
    use super::*;

    // What npm (cmd-shim) writes to %APPDATA%\npm\claude.cmd for a package whose bin is an .exe, and for one whose bin is a
    // Node script.
    const EXE_SHIM: &str = "@ECHO off\r\nGOTO start\r\n:find_dp0\r\nSET dp0=%~dp0\r\nEXIT /b\r\n:start\r\nSETLOCAL\r\nCALL :find_dp0\r\n\"%dp0%\\node_modules\\@anthropic-ai\\claude-code\\bin\\claude.exe\"   %*\r\n";
    const JS_SHIM: &str = "@ECHO off\r\nGOTO start\r\n:find_dp0\r\nSET dp0=%~dp0\r\nEXIT /b\r\n:start\r\nSETLOCAL\r\nCALL :find_dp0\r\n\r\nIF EXIST \"%dp0%\\node.exe\" (\r\n  SET \"_prog=%dp0%\\node.exe\"\r\n) ELSE (\r\n  SET \"_prog=node\"\r\n  SET PATHEXT=%PATHEXT:;.JS;=;%\r\n)\r\n\r\nendLocal & goto #_undefined_# 2>NUL || title %COMSPEC% & \"%_prog%\"  \"%dp0%\\node_modules\\opencode-ai\\bin\\opencode.js\" %*\r\n";

    #[test]
    fn npm_shims_run_their_target_directly() {
        let dir = tempfile::tempdir().unwrap();
        let exe = dir.path().join("node_modules/@anthropic-ai/claude-code/bin/claude.exe");
        std::fs::create_dir_all(exe.parent().unwrap()).unwrap();
        std::fs::write(&exe, b"").unwrap();
        let (program, pre) = npm_shim_target(EXE_SHIM, dir.path()).expect("the exe shim resolves");
        assert_eq!(program, exe);
        assert!(pre.is_empty());

        let script = dir.path().join("node_modules/opencode-ai/bin/opencode.js");
        std::fs::create_dir_all(script.parent().unwrap()).unwrap();
        std::fs::write(&script, b"").unwrap();
        std::fs::write(dir.path().join("node.exe"), b"").unwrap();
        let (program, pre) = npm_shim_target(JS_SHIM, dir.path()).expect("the script shim resolves");
        assert_eq!(program, dir.path().join("node.exe"));
        assert_eq!(pre.len(), 1);
        assert_eq!(PathBuf::from(&pre[0]), script);
    }

    #[test]
    fn other_batch_files_are_left_to_cmd() {
        let dir = tempfile::tempdir().unwrap();
        assert!(npm_shim_target("@echo off\r\necho hi %*\r\n", dir.path()).is_none());
        // A shim whose target isn't there, or that climbs out of its folder, isn't followed.
        assert!(npm_shim_target(EXE_SHIM, dir.path()).is_none());
        assert!(npm_shim_target("\"%dp0%\\..\\..\\evil.exe\" %*", dir.path()).is_none());
    }
}
