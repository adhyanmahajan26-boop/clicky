//! Bots that run straight on a model API with the owner's key (`api:<provider>` engines), with tools: their own memory folder
//! and the connector hub apps they were given, at the level they were given. The same behaviour as the Mac's `APIChat`,
//! `APIChatToolbox` and ClickyCore `APIChatToolCalling` (package 4 of `theo-fix-plan`):
//!
//! - Anthropic's Messages API (`tool_use` / `tool_result` blocks) and the OpenAI-style chat endpoint (`tools`, `tool_calls`,
//!   `role: tool`), both streamed, so the chat shows the words as they come.
//! - The loop: ask, run the tools the model asked for, send their answers back, ask again, until the model answers without
//!   asking for tools. After 8 rounds it is asked once more with tools switched off, so it answers with what it has.
//! - A provider or model that turns tools down gets today's words-only turn, and the chat says why once
//!   (`brains.modelsWithoutTools` remembers a model that has no tools at all).
//! - Hub apps go through `theo-connectors call` with a ticket written for this turn and deleted when it ends. A tool name the
//!   bot wasn't offered never reaches the hub. A turn not from the owner's own words never gets a tool that sends, shares or deletes.
//!
//! There is no engine session on an API: each turn's earlier messages are kept by Theo under `APISessions/<id>.json`, and the
//! id is the bot's session for that chat, like any engine's.

use crate::brains::{ApiProvider, WireStyle};
use crate::engine::Cancel;
use crate::harness::{Harness, RunError};
use crate::model::Bot;
use serde_json::{json, Value};
use std::collections::BTreeMap;
use std::io::BufRead;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;

/// Rounds of tool calls in one turn before the model is asked to answer with what it has.
pub const MAXIMUM_TOOL_ROUNDS: usize = 8;
/// A tool's answer is cut to this many characters before it goes back to the model.
pub const MAXIMUM_RESULT_CHARACTERS: usize = 20_000;
pub const MAXIMUM_OUTPUT_TOKENS: u64 = 8192;
const MAXIMUM_MEMORY_READ_CHARACTERS: usize = 100_000;
const MAXIMUM_MEMORY_WRITE_CHARACTERS: usize = 200_000;
const MAXIMUM_MEMORY_FILES_LISTED: usize = 200;
/// Earlier messages kept for a chat on an API key: enough for context, small enough for any model's window.
const HISTORY_MESSAGES_KEPT: usize = 40;
const HISTORY_CHARACTERS_KEPT: usize = 120_000;
/// Settings key: `<provider>/<model>` pairs that said they have no tool calling at all.
const MODELS_WITHOUT_TOOLS_SETTING: &str = "brains.modelsWithoutTools";

pub const MEMORY_LIST_TOOL: &str = "memory_list";
pub const MEMORY_READ_TOOL: &str = "memory_read";
pub const MEMORY_WRITE_TOOL: &str = "memory_write";

// MARK: The wire, for both API styles (pure, tested below)

#[derive(Clone, Debug, PartialEq)]
pub struct ToolDefinition {
    /// The name the model calls it by: letters, digits, `_` and `-`, up to 64 (both APIs refuse anything else).
    pub name: String,
    pub description: String,
    pub input_schema: Value,
}

#[derive(Clone, Debug, PartialEq)]
pub struct ToolCall {
    pub call_id: String,
    pub tool_name: String,
    /// The arguments as the model wrote them: JSON text, which can be empty or broken.
    pub arguments_json: String,
}

#[derive(Clone, Debug, PartialEq)]
pub struct ToolResult {
    pub call_id: String,
    pub text: String,
    pub is_error: bool,
}

/// One round inside a turn: what the model said and the tools it asked for, then what those tools answered.
#[derive(Clone, Debug, PartialEq)]
pub struct ToolRound {
    pub assistant_text: String,
    pub calls: Vec<ToolCall>,
    pub results: Vec<ToolResult>,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub enum ToolRefusal {
    /// The model or provider has no tool calling at all: remember it and stop offering tools to it.
    ModelHasNoTools,
    /// Something about these tools this time: answer in words this turn, try tools again next time.
    ThisRequestOnly,
}

/// One earlier message of the chat as the API sees it.
#[derive(Clone, Debug, PartialEq, serde::Serialize, serde::Deserialize)]
pub struct HistoryMessage {
    pub role: String,
    pub text: String,
}

pub fn is_usable_tool_name(name: &str) -> bool {
    !name.is_empty() && name.len() <= 64 && name.chars().all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '-')
}

/// A schema both APIs take: an object at the top level. Anything else becomes an empty object schema, so one odd tool can't
/// make the whole request fail.
fn input_schema_object(schema: &Value) -> Value {
    let empty = json!({"type": "object", "properties": {}});
    let Some(object) = schema.as_object() else { return empty };
    let mut object = object.clone();
    // "$schema" is only a label, and some OpenAI-style endpoints refuse keys they don't know at the top.
    object.remove("$schema");
    if !object.contains_key("type") {
        object.insert("type".into(), json!("object"));
    }
    if object.get("type").and_then(Value::as_str) != Some("object") {
        return empty;
    }
    object.entry("properties").or_insert_with(|| json!({}));
    Value::Object(object)
}

pub fn tools_field(definitions: &[ToolDefinition], style: WireStyle) -> Value {
    Value::Array(
        definitions
            .iter()
            .map(|definition| {
                let schema = input_schema_object(&definition.input_schema);
                match style {
                    WireStyle::Anthropic => json!({"name": definition.name, "description": definition.description, "input_schema": schema}),
                    WireStyle::OpenAI => json!({"type": "function", "function": {"name": definition.name, "description": definition.description, "parameters": schema}}),
                }
            })
            .collect(),
    )
}

/// `tool_choice` for the last go after the round cap: the tools stay listed (Anthropic refuses a conversation with tool
/// blocks and no tools), but the model may not call them.
pub fn tool_choice_none(style: WireStyle) -> Value {
    match style {
        WireStyle::Anthropic => json!({"type": "none"}),
        WireStyle::OpenAI => json!("none"),
    }
}

/// The arguments as an object, for Anthropic's `input` (it must be an object, even when the model wrote nothing).
pub fn arguments_object(arguments_json: &str) -> Value {
    match serde_json::from_str::<Value>(arguments_json) {
        Ok(Value::Object(object)) => Value::Object(object),
        _ => json!({}),
    }
}

fn arguments_text(arguments_json: &str) -> String {
    if arguments_json.trim().is_empty() { "{}".to_string() } else { arguments_json.to_string() }
}

/// The messages one finished round adds: the model's own message with its tool calls, then the answers.
pub fn round_messages(round: &ToolRound, style: WireStyle) -> Vec<Value> {
    match style {
        WireStyle::Anthropic => {
            let mut content = vec![];
            if !round.assistant_text.is_empty() {
                content.push(json!({"type": "text", "text": round.assistant_text}));
            }
            for call in &round.calls {
                content.push(json!({"type": "tool_use", "id": call.call_id, "name": call.tool_name, "input": arguments_object(&call.arguments_json)}));
            }
            let results: Vec<Value> = round
                .results
                .iter()
                .map(|result| {
                    let mut block = json!({"type": "tool_result", "tool_use_id": result.call_id, "content": result.text});
                    if result.is_error {
                        block["is_error"] = json!(true);
                    }
                    block
                })
                .collect();
            vec![json!({"role": "assistant", "content": content}), json!({"role": "user", "content": results})]
        }
        WireStyle::OpenAI => {
            let calls: Vec<Value> = round
                .calls
                .iter()
                .map(|call| json!({"id": call.call_id, "type": "function", "function": {"name": call.tool_name, "arguments": arguments_text(&call.arguments_json)}}))
                .collect();
            let mut messages = vec![json!({"role": "assistant", "content": if round.assistant_text.is_empty() { Value::Null } else { json!(round.assistant_text) }, "tool_calls": calls})];
            messages.extend(round.results.iter().map(|result| json!({"role": "tool", "tool_call_id": result.call_id, "content": result.text})));
            messages
        }
    }
}

/// The body of one request.
pub fn request_body(style: WireStyle, model: &str, system: &str, history: &[HistoryMessage], tools: &[ToolDefinition], rounds: &[ToolRound], may_call_tools: bool) -> Value {
    let round_messages: Vec<Value> = rounds.iter().flat_map(|round| round_messages(round, style)).collect();
    let earlier: Vec<Value> = history.iter().map(|message| json!({"role": message.role, "content": message.text})).collect();
    let mut body = match style {
        WireStyle::Anthropic => {
            let mut messages = earlier;
            messages.extend(round_messages);
            json!({"model": model, "max_tokens": MAXIMUM_OUTPUT_TOKENS, "stream": true, "system": system, "messages": messages})
        }
        WireStyle::OpenAI => {
            let mut messages = vec![];
            if !system.is_empty() {
                messages.push(json!({"role": "system", "content": system}));
            }
            messages.extend(earlier);
            messages.extend(round_messages);
            json!({"model": model, "stream": true, "messages": messages})
        }
    };
    if !tools.is_empty() {
        body["tools"] = tools_field(tools, style);
        if !may_call_tools {
            body["tool_choice"] = tool_choice_none(style);
        }
    }
    body
}

pub fn endpoint(provider: &ApiProvider) -> String {
    match provider.style {
        WireStyle::Anthropic => format!("{}/messages", provider.base_url),
        WireStyle::OpenAI => format!("{}/chat/completions", provider.base_url),
    }
}

/// Whether a refused request was refused because of its tools. Only asked when the request carried tools.
pub fn tool_refusal(status: u16, body: &str) -> Option<ToolRefusal> {
    // Sign-in, rate limits and server trouble are never about the tools.
    if !(400..500).contains(&status) || [401, 403, 408, 429].contains(&status) {
        return None;
    }
    let lower = body.to_lowercase();
    if !lower.contains("tool") && !lower.contains("function") {
        return None;
    }
    let no_tools_at_all = ["not support", "unsupported", "doesn't support", "no endpoints found that support", "not supported", "not enabled", "not available"].iter().any(|words| lower.contains(words));
    Some(if no_tools_at_all { ToolRefusal::ModelHasNoTools } else { ToolRefusal::ThisRequestOnly })
}

pub fn trimmed_result(text: &str) -> String {
    let count = text.chars().count();
    if count <= MAXIMUM_RESULT_CHARACTERS {
        return text.to_string();
    }
    format!("{}\n…(cut: the tool's answer was {count} characters long)", text.chars().take(MAXIMUM_RESULT_CHARACTERS).collect::<String>())
}

/// Two pieces of an answer, a blank line between them when both have words.
pub fn joined_answer(earlier: &str, later: &str) -> String {
    if earlier.trim().is_empty() {
        return later.to_string();
    }
    if later.trim().is_empty() {
        return earlier.to_string();
    }
    format!("{earlier}\n\n{later}")
}

/// A provider's error, whichever way it writes it ({"error": {"message": …}}, {"error": "…"} or {"message": …}).
pub fn error_message_in(body: &str) -> Option<String> {
    let parsed: Value = serde_json::from_str(body.trim()).ok()?;
    let parsed = if let Value::Array(items) = &parsed { items.first().cloned().unwrap_or(Value::Null) } else { parsed };
    parsed
        .pointer("/error/message")
        .and_then(Value::as_str)
        .or_else(|| parsed.get("error").and_then(Value::as_str))
        .or_else(|| parsed.get("message").and_then(Value::as_str))
        .map(|message| message.chars().take(400).collect())
}

/// What one server-sent line says.
#[derive(Debug, Default, PartialEq)]
pub struct LineReading {
    pub text: Option<String>,
    pub done: bool,
    pub error: Option<String>,
    pub stop_reason: Option<String>,
}

pub fn read_line(line: &str, style: WireStyle) -> LineReading {
    let mut reading = LineReading::default();
    let Some(payload) = line.strip_prefix("data:").map(str::trim) else { return reading };
    if payload == "[DONE]" {
        reading.done = true;
        return reading;
    }
    let Ok(event) = serde_json::from_str::<Value>(payload) else { return reading };
    if let Some(error) = event.get("error").filter(|error| !error.is_null()) {
        reading.done = true;
        reading.error = Some(error.get("message").and_then(Value::as_str).or_else(|| error.as_str()).unwrap_or("The provider reported an error.").to_string());
        return reading;
    }
    match style {
        WireStyle::Anthropic => match event["type"].as_str() {
            Some("content_block_delta") if event["delta"]["type"] == "text_delta" => reading.text = event["delta"]["text"].as_str().map(str::to_string),
            Some("message_delta") => reading.stop_reason = event["delta"]["stop_reason"].as_str().map(str::to_string),
            Some("message_stop") => reading.done = true,
            _ => {}
        },
        WireStyle::OpenAI => {
            let choice = &event["choices"][0];
            reading.text = choice["delta"]["content"].as_str().map(str::to_string);
            reading.stop_reason = choice["finish_reason"].as_str().map(str::to_string);
        }
    }
    reading
}

/// Puts a streamed answer's tool calls back together, one server-sent line at a time. Anthropic sends a
/// `content_block_start` with the tool's id and name, then the arguments in `input_json_delta` pieces; OpenAI-style
/// endpoints send `delta.tool_calls` pieces keyed by `index`.
#[derive(Default)]
pub struct ToolCallCollector {
    calls_by_stream_index: BTreeMap<i64, ToolCall>,
    starting_arguments: BTreeMap<i64, String>,
    order: Vec<i64>,
}

impl ToolCallCollector {
    /// The calls so far, in the order the model made them. A call with no name is dropped; one with no id gets one.
    pub fn calls(&self) -> Vec<ToolCall> {
        self.order
            .iter()
            .filter_map(|index| {
                let mut call = self.calls_by_stream_index.get(index)?.clone();
                if call.tool_name.is_empty() {
                    return None;
                }
                if call.call_id.is_empty() {
                    call.call_id = format!("call_{index}");
                }
                if call.arguments_json.is_empty() {
                    if let Some(starting) = self.starting_arguments.get(index) {
                        call.arguments_json = starting.clone();
                    }
                }
                Some(call)
            })
            .collect()
    }

    fn begin(&mut self, index: i64) -> &mut ToolCall {
        if !self.calls_by_stream_index.contains_key(&index) {
            self.order.push(index);
        }
        self.calls_by_stream_index.entry(index).or_insert_with(|| ToolCall { call_id: String::new(), tool_name: String::new(), arguments_json: String::new() })
    }

    pub fn take(&mut self, line: &str, style: WireStyle) {
        let Some(payload) = line.strip_prefix("data:").map(str::trim) else { return };
        let Ok(event) = serde_json::from_str::<Value>(payload) else { return };
        match style {
            WireStyle::Anthropic => {
                let index = event["index"].as_i64().unwrap_or(0);
                match event["type"].as_str() {
                    Some("content_block_start") if event["content_block"]["type"] == "tool_use" => {
                        let block = &event["content_block"];
                        let call = self.begin(index);
                        call.call_id = block["id"].as_str().unwrap_or("").to_string();
                        call.tool_name = block["name"].as_str().unwrap_or("").to_string();
                        if let Some(input) = block["input"].as_object().filter(|input| !input.is_empty()) {
                            self.starting_arguments.insert(index, Value::Object(input.clone()).to_string());
                        }
                    }
                    Some("content_block_delta") if event["delta"]["type"] == "input_json_delta" => {
                        if let (Some(call), Some(piece)) = (self.calls_by_stream_index.get_mut(&index), event["delta"]["partial_json"].as_str()) {
                            call.arguments_json.push_str(piece);
                        }
                    }
                    _ => {}
                }
            }
            WireStyle::OpenAI => {
                let Some(pieces) = event["choices"][0]["delta"]["tool_calls"].as_array() else { return };
                for (position, piece) in pieces.iter().enumerate() {
                    let index = piece["index"].as_i64().unwrap_or(position as i64);
                    let call = self.begin(index);
                    if let Some(id) = piece["id"].as_str().filter(|id| !id.is_empty()) {
                        call.call_id = id.to_string();
                    }
                    // The name comes once; a provider that repeats it in later pieces mustn't double it.
                    if let Some(name) = piece["function"]["name"].as_str().filter(|name| !name.is_empty()) {
                        if call.tool_name.is_empty() {
                            call.tool_name = name.to_string();
                        }
                    }
                    match &piece["function"]["arguments"] {
                        Value::String(text) => call.arguments_json.push_str(text),
                        // A few OpenAI-style servers send the arguments as an object rather than a string.
                        Value::Object(object) => call.arguments_json.push_str(&Value::Object(object.clone()).to_string()),
                        _ => {}
                    }
                }
            }
        }
    }
}

// MARK: Its own memory folder

/// The file `relative_path` names inside `folder`, or None when it would leave the folder: an absolute path, a drive, `~`,
/// `..`, or a symbolic link anywhere along the way.
pub fn resolve_memory_path(folder: &Path, relative_path: &str) -> Option<PathBuf> {
    let trimmed = relative_path.trim();
    if trimmed.is_empty() || trimmed.starts_with('/') || trimmed.starts_with('\\') || trimmed.starts_with('~') || trimmed.contains(':') {
        return None;
    }
    let parts: Vec<&str> = trimmed.split(['/', '\\']).filter(|part| !part.is_empty() && *part != ".").collect();
    if parts.is_empty() || parts.iter().any(|part| *part == "..") {
        return None;
    }
    let mut path = folder.to_path_buf();
    for part in parts {
        path.push(part);
        if std::fs::symlink_metadata(&path).map(|metadata| metadata.file_type().is_symlink()).unwrap_or(false) {
            return None;
        }
    }
    Some(path)
}

fn memory_tool_definitions() -> Vec<ToolDefinition> {
    vec![
        ToolDefinition {
            name: MEMORY_LIST_TOOL.into(),
            description: "List the files in your own memory folder (memory.md is what you remember; skills are skills/<name>/SKILL.md).".into(),
            input_schema: json!({"type": "object", "properties": {}}),
        },
        ToolDefinition {
            name: MEMORY_READ_TOOL.into(),
            description: "Read a file in your own memory folder.".into(),
            input_schema: json!({"type": "object", "properties": {"path": {"type": "string", "description": "Path inside your memory folder, for example memory.md"}}, "required": ["path"]}),
        },
        ToolDefinition {
            name: MEMORY_WRITE_TOOL.into(),
            description: "Write a file in your own memory folder: replace it, or add to its end with append. Keep memory.md short and current.".into(),
            input_schema: json!({"type": "object", "properties": {"path": {"type": "string", "description": "Path inside your memory folder, for example memory.md"}, "content": {"type": "string"}, "append": {"type": "boolean", "description": "Add to the end instead of replacing"}}, "required": ["path", "content"]}),
        },
    ]
}

fn list_memory(folder: &Path) -> (String, bool) {
    let mut found = vec![];
    let mut waiting = vec![folder.to_path_buf()];
    while let Some(current) = waiting.pop() {
        let Ok(entries) = std::fs::read_dir(&current) else { continue };
        for entry in entries.flatten() {
            let Ok(kind) = entry.file_type() else { continue };
            let name = entry.file_name().to_string_lossy().to_string();
            if name.starts_with('.') || kind.is_symlink() {
                continue;
            }
            if kind.is_dir() {
                waiting.push(entry.path());
            } else if kind.is_file() && found.len() < MAXIMUM_MEMORY_FILES_LISTED {
                let relative = entry.path().strip_prefix(folder).map(|p| p.to_string_lossy().replace('\\', "/")).unwrap_or(name);
                let size = entry.metadata().map(|m| m.len()).unwrap_or(0);
                found.push(format!("{relative} ({size} bytes)"));
            }
        }
    }
    found.sort();
    if found.is_empty() { ("Your memory folder is empty.".into(), false) } else { (found.join("\n"), false) }
}

fn read_memory(folder: &Path, path: &str) -> (String, bool) {
    let Some(file) = resolve_memory_path(folder, path) else { return (format!("{path} isn't in your memory folder. Use a path inside it, like memory.md."), true) };
    match std::fs::read_to_string(&file) {
        Ok(text) => {
            let count = text.chars().count();
            if count > MAXIMUM_MEMORY_READ_CHARACTERS {
                (format!("{}\n…(cut: the file is {count} characters long)", text.chars().take(MAXIMUM_MEMORY_READ_CHARACTERS).collect::<String>()), false)
            } else {
                (text, false)
            }
        }
        Err(_) => (format!("There's no readable text file at {path} in your memory folder."), true),
    }
}

fn write_memory(folder: &Path, path: &str, content: Option<&str>, append: bool) -> (String, bool) {
    let Some(file) = resolve_memory_path(folder, path) else { return (format!("{path} isn't in your memory folder. Use a path inside it, like memory.md."), true) };
    let Some(content) = content else { return ("Nothing to write: give content.".into(), true) };
    if content.chars().count() > MAXIMUM_MEMORY_WRITE_CHARACTERS {
        return (format!("That's too long to keep (over {MAXIMUM_MEMORY_WRITE_CHARACTERS} characters). Keep memory short."), true);
    }
    if let Some(parent) = file.parent() {
        if std::fs::create_dir_all(parent).is_err() {
            return (format!("Couldn't write {path}."), true);
        }
    }
    let mut text = content.to_string();
    if append {
        if let Ok(existing) = std::fs::read_to_string(&file) {
            text = if existing.is_empty() || existing.ends_with('\n') { existing + content } else { format!("{existing}\n{content}") };
        }
    }
    match crate::store::write_atomic(&file, text.as_bytes()) {
        Ok(()) => (if append { format!("Added to {path}.") } else { format!("Saved {path}.") }, false),
        Err(error) => (format!("Couldn't write {path}: {error}"), true),
    }
}

// MARK: The tools of one turn

/// One hub app tool offered to the model.
#[derive(Clone, Debug)]
struct HubTool {
    app_id: String,
    app_name: String,
    tool_name: String,
}

/// What a bot on an API key may call in one turn. Dropping it deletes the ticket, so the hub stops answering for the turn
/// however the turn ends.
pub struct Toolbox {
    pub definitions: Vec<ToolDefinition>,
    pub prompt_section: String,
    memory_folder: PathBuf,
    hub_tools: BTreeMap<String, HubTool>,
    ticket: Option<PathBuf>,
}

impl Drop for Toolbox {
    fn drop(&mut self) {
        if let Some(ticket) = &self.ticket {
            let _ = std::fs::remove_file(ticket);
        }
    }
}

/// `level` is the level that holds for this turn (`hub::level_for_turn`), so a turn not from the owner is never `full`.
fn level_words(level: &str, from_owner: bool) -> &'static str {
    match level {
        "full" => "everything its tools do",
        "read" => "look things up only",
        _ if !from_owner => "look things up and draft or change, never send, share or delete: this turn didn't come from the owner's own words",
        _ => "look things up and draft or change, never send, share or delete",
    }
}

impl Toolbox {
    /// The toolbox for one turn of `bot`: its memory tools, and the tools of each hub app it was given that its level allows
    /// (every app goes through the hub on an API key, Claude account ones too). Without the hub, or when nothing can be
    /// reached, it still has its memory tools.
    pub async fn for_turn(harness: &Harness, bot: &Bot, from_owner: bool) -> Toolbox {
        let memory_folder = harness.paths.memory_dir(&bot.id);
        let _ = std::fs::create_dir_all(&memory_folder);
        let mut toolbox = Toolbox { definitions: memory_tool_definitions(), prompt_section: String::new(), memory_folder, hub_tools: BTreeMap::new(), ticket: None };
        let mut apps_not_reachable: Vec<String> = vec![];
        let mut ticket_apps: BTreeMap<String, String> = BTreeMap::new();
        let mut described: Vec<String> = vec![];
        let mut hub_definitions: Vec<ToolDefinition> = vec![];
        if !bot.apps.is_empty() {
            let known = match harness.with(|state| state.hub_apps.clone()) {
                apps if bot.apps.iter().all(|id| apps.iter().any(|app| app["id"].as_str() == Some(id))) => apps,
                _ => crate::hub::list_apps(harness).await.unwrap_or_default(),
            };
            for app_id in &bot.apps {
                let Some(app) = known.iter().find(|app| app["id"].as_str() == Some(app_id.as_str())) else { continue };
                if app["enabled"].as_bool() == Some(false) {
                    continue;
                }
                let app_name = app["name"].as_str().unwrap_or(app_id).to_string();
                let level = crate::hub::level_for_turn(&crate::hub::level_of(bot, app_id), from_owner);
                match crate::hub::tools_of(harness, app_id).await {
                    Ok(tools) => {
                        let mut offered_any = false;
                        for tool in tools {
                            let (Some(name), Some(effect)) = (tool["name"].as_str(), tool["effect"].as_str()) else { continue };
                            let exposed = tool["exposedName"].as_str().map(str::to_string).unwrap_or_else(|| format!("{app_id}__{name}"));
                            // A tool the level doesn't allow is never offered (the hub refuses it too, if asked by name anyway).
                            if !crate::hub::effect_allowed(effect, level) || !is_usable_tool_name(&exposed) || toolbox.hub_tools.contains_key(&exposed) {
                                continue;
                            }
                            let words = tool["description"].as_str().or_else(|| tool["title"].as_str()).unwrap_or("");
                            let schema = tool.get("inputSchema").or_else(|| tool.get("input_schema")).cloned().unwrap_or_else(|| json!({}));
                            hub_definitions.push(ToolDefinition { name: exposed.clone(), description: format!("[{app_name}] {words}"), input_schema: schema });
                            toolbox.hub_tools.insert(exposed, HubTool { app_id: app_id.clone(), app_name: app_name.clone(), tool_name: name.to_string() });
                            offered_any = true;
                        }
                        if offered_any {
                            ticket_apps.insert(app_id.clone(), level.to_string());
                            described.push(format!("{app_name} ({})", level_words(level, from_owner)));
                        }
                    }
                    Err(error) => apps_not_reachable.push(format!("{app_name} ({})", error.chars().take(120).collect::<String>())),
                }
            }
        }
        if !ticket_apps.is_empty() {
            match crate::hub::write_ticket(harness, &bot.id, &ticket_apps, from_owner, None) {
                Ok(ticket) => {
                    toolbox.ticket = Some(ticket);
                    hub_definitions.sort_by(|a, b| a.name.cmp(&b.name));
                    toolbox.definitions.extend(hub_definitions);
                }
                Err(error) => {
                    apps_not_reachable.extend(described.drain(..).map(|name| format!("{name}: {error}")));
                    toolbox.hub_tools.clear();
                }
            }
        }
        let mut lines = vec![format!(
            "Your tools: {MEMORY_LIST_TOOL}, {MEMORY_READ_TOOL} and {MEMORY_WRITE_TOOL} reach your own memory folder and nothing else. Save what you'll need next time to memory.md there, short and current."
        )];
        if !described.is_empty() {
            lines.push(format!("Your apps, as tools named <app>__<tool>: {}. Use them when the request needs them, and only say something was done when the tool's answer shows it was.", described.join(", ")));
        }
        if !apps_not_reachable.is_empty() {
            apps_not_reachable.sort();
            lines.push(format!("These apps of yours can't be reached this turn: {}. If the request needs one, say so plainly rather than guessing.", apps_not_reachable.join("; ")));
        }
        toolbox.prompt_section = lines.join("\n");
        toolbox
    }

    /// Runs one call. Never fails: anything that goes wrong is an error result the model can read and work around.
    pub async fn run(&self, harness: &Harness, call: &ToolCall) -> ToolResult {
        let arguments = arguments_object(&call.arguments_json);
        let (text, is_error) = match call.tool_name.as_str() {
            MEMORY_LIST_TOOL => list_memory(&self.memory_folder),
            MEMORY_READ_TOOL => read_memory(&self.memory_folder, arguments["path"].as_str().unwrap_or("")),
            MEMORY_WRITE_TOOL => write_memory(&self.memory_folder, arguments["path"].as_str().unwrap_or(""), arguments["content"].as_str(), arguments["append"].as_bool().unwrap_or(false)),
            other => match (self.hub_tools.get(other), &self.ticket) {
                // Only a tool this bot was offered: a name it made up, or another bot's app, never reaches the hub.
                (Some(tool), Some(ticket)) => {
                    let words = vec!["call".to_string(), tool.app_id.clone(), tool.tool_name.clone(), "--args".into(), arguments.to_string(), "--ticket".into(), ticket.to_string_lossy().to_string()];
                    match crate::hub::run_hub_command(harness, &words, None, Duration::from_secs_f64(harness.settings.turn_limit_seconds().min(300.0))).await {
                        Ok(answer) => {
                            let result = &answer["result"];
                            let text = text_of_tool_result(result);
                            (if text.is_empty() { "(The tool returned nothing.)".to_string() } else { text }, result["isError"].as_bool().unwrap_or(false))
                        }
                        Err(error) => (format!("{} didn't run that: {error}", tool.app_name), true),
                    }
                }
                _ => (format!("There is no tool called {other} for you. Use only the tools you were given."), true),
            },
        };
        ToolResult { call_id: call.call_id.clone(), text: trimmed_result(&text), is_error }
    }
}

/// An MCP CallToolResult as words: its text parts, a note for anything else (an image, a file), else its structured content.
pub fn text_of_tool_result(result: &Value) -> String {
    let parts: Vec<String> = result["content"]
        .as_array()
        .into_iter()
        .flatten()
        .map(|part| match part["type"].as_str() {
            Some("text") => part["text"].as_str().unwrap_or("").to_string(),
            Some("resource") => part["resource"]["text"].as_str().map(str::to_string).unwrap_or_else(|| "[a file]".into()),
            Some(other) => format!("[{other}]"),
            None => String::new(),
        })
        .filter(|text| !text.is_empty())
        .collect();
    if !parts.is_empty() {
        return parts.join("\n");
    }
    match result.get("structuredContent") {
        Some(structured) if !structured.is_null() => structured.to_string(),
        _ => String::new(),
    }
}

// MARK: Sending

pub fn http_agent(address: &str) -> ureq::Agent {
    let local = address.starts_with("http://127.0.0.1") || address.starts_with("http://localhost") || address.starts_with("http://[::1]");
    ureq::AgentBuilder::new()
        .timeout_connect(Duration::from_secs(20))
        // A model can think quietly for a while before its first words; a stream that says nothing for this long is dead.
        .timeout_read(Duration::from_secs(240))
        .try_proxy_from_env(!local)
        .user_agent(concat!("theo/", env!("CARGO_PKG_VERSION")))
        .build()
}

pub fn authorize(request: ureq::Request, style: WireStyle, key: Option<&str>) -> ureq::Request {
    match (style, key) {
        (WireStyle::Anthropic, Some(key)) => request.set("x-api-key", key).set("anthropic-version", "2023-06-01"),
        (WireStyle::Anthropic, None) => request.set("anthropic-version", "2023-06-01"),
        (WireStyle::OpenAI, Some(key)) => request.set("Authorization", &format!("Bearer {key}")),
        (WireStyle::OpenAI, None) => request,
    }
}

/// A connection problem in words, without the address's query or anything secret.
pub fn transport_problem(error: &ureq::Error) -> String {
    match error {
        ureq::Error::Status(status, _) => format!("it answered {status}"),
        ureq::Error::Transport(transport) => transport.message().map(str::to_string).unwrap_or_else(|| format!("{:?}", transport.kind())),
    }
}

/// What one request brought back.
#[derive(Debug, Default)]
pub struct RoundReply {
    pub text: String,
    pub calls: Vec<ToolCall>,
    pub stop_reason: Option<String>,
    pub ended_cleanly: bool,
}

#[derive(Debug)]
enum RoundError {
    /// The provider said no: its status and what it said (cut short).
    Refused { status: u16, body: String },
    Failed(String),
    Cancelled,
}

/// One request, streamed: its words go to `on_round_text` as they come, and its tool calls are collected. Blocking: run on
/// a blocking thread. Stops at the next line once `cancel` is set.
fn send_round(provider: &ApiProvider, key: Option<&str>, body: &Value, cancel: &Cancel, on_round_text: &dyn Fn(&str)) -> Result<RoundReply, RoundError> {
    let address = endpoint(provider);
    let request = authorize(http_agent(&address).post(&address).set("Content-Type", "application/json").set("Accept", "text/event-stream"), provider.style, key);
    let response = match request.send_string(&body.to_string()) {
        Ok(response) => response,
        Err(ureq::Error::Status(status, response)) => {
            let mut text = String::new();
            let _ = std::io::Read::read_to_string(&mut std::io::Read::take(response.into_reader(), 8000), &mut text);
            return Err(RoundError::Refused { status, body: text });
        }
        Err(error) => return Err(RoundError::Failed(format!("Couldn't reach {}: {}", provider.label, transport_problem(&error)))),
    };
    let mut reply = RoundReply::default();
    let mut collector = ToolCallCollector::default();
    let mut not_streamed = String::new();
    let mut last_shown = std::time::Instant::now() - Duration::from_secs(1);
    let reader = std::io::BufReader::new(response.into_reader());
    for line in reader.lines() {
        if cancel.is_cancelled() {
            return Err(RoundError::Cancelled);
        }
        let line = match line {
            Ok(line) => line,
            Err(error) => {
                if reply.text.is_empty() && collector.calls().is_empty() {
                    return Err(RoundError::Failed(format!("{}'s answer broke off: {error}", provider.label)));
                }
                break;
            }
        };
        if !line.starts_with("data:") && !line.starts_with("event:") && not_streamed.len() < 4000 {
            not_streamed.push_str(&line);
        }
        let reading = read_line(&line, provider.style);
        if let Some(error) = reading.error {
            return Err(RoundError::Failed(format!("{}: {error}", provider.label)));
        }
        if reading.stop_reason.is_some() {
            reply.stop_reason = reading.stop_reason;
        }
        collector.take(&line, provider.style);
        if let Some(piece) = reading.text.filter(|piece| !piece.is_empty()) {
            reply.text.push_str(&piece);
            if last_shown.elapsed() >= Duration::from_millis(50) {
                on_round_text(&reply.text);
                last_shown = std::time::Instant::now();
            }
        }
        if reading.done {
            reply.ended_cleanly = true;
            break;
        }
    }
    reply.calls = collector.calls();
    // A server that answered with plain JSON instead of a stream (some local ones do when they can't stream).
    if reply.text.is_empty() && reply.calls.is_empty() && !not_streamed.trim().is_empty() {
        if let Ok(whole) = serde_json::from_str::<Value>(not_streamed.trim()) {
            if let Some(message) = error_message_in(not_streamed.trim()) {
                return Err(RoundError::Failed(format!("{}: {message}", provider.label)));
            }
            let text = whole["choices"][0]["message"]["content"].as_str().map(str::to_string).or_else(|| {
                whole["content"].as_array().map(|blocks| blocks.iter().filter_map(|block| block["text"].as_str()).collect::<Vec<_>>().join(""))
            });
            reply.text = text.unwrap_or_default();
            reply.ended_cleanly = true;
        }
    }
    if reply.stop_reason.is_some() {
        reply.ended_cleanly = true;
    }
    on_round_text(&reply.text);
    Ok(reply)
}

fn refused_sentence(provider: &ApiProvider, status: u16, body: &str) -> String {
    let said = error_message_in(body).unwrap_or_else(|| body.chars().take(200).collect::<String>().trim().to_string());
    let said = if said.is_empty() { "no reason given".to_string() } else { said };
    // The status stays in the words: the failover rules read 401, 429, 529 and the like from them.
    format!("{} answered {status}: {said}", provider.label)
}

struct LoopOutcome {
    answer: String,
    last_stop_reason: Option<String>,
    last_ended_cleanly: bool,
    stopped_at_round_cap: bool,
}

#[derive(Clone)]
struct TurnContext {
    provider: ApiProvider,
    key: Option<String>,
    model: String,
    system: String,
    history: Vec<HistoryMessage>,
    cancel: Arc<Cancel>,
}

async fn send_round_off_thread(context: &TurnContext, tools: &[ToolDefinition], rounds: &[ToolRound], may_call_tools: bool, text_before: String, on_text: Arc<dyn Fn(&str) + Send + Sync>) -> Result<RoundReply, RoundError> {
    let body = request_body(context.provider.style, &context.model, &context.system, &context.history, tools, rounds, may_call_tools);
    let context = context.clone();
    tokio::task::spawn_blocking(move || {
        let show = move |round_text: &str| on_text(&joined_answer(&text_before, round_text));
        send_round(&context.provider, context.key.as_deref(), &body, &context.cancel, &show)
    })
    .await
    .unwrap_or_else(|_| Err(RoundError::Failed("The request stopped unexpectedly.".into())))
}

/// Ask, run the tools the model asked for, send their answers back, and ask again, until it stops asking for tools.
async fn run_tool_loop(harness: &Harness, context: &TurnContext, tools: &[ToolDefinition], toolbox: Option<&Toolbox>, on_text: Arc<dyn Fn(&str) + Send + Sync>) -> Result<LoopOutcome, RoundError> {
    let mut rounds: Vec<ToolRound> = vec![];
    let mut text_before = String::new();
    loop {
        if context.cancel.is_cancelled() {
            return Err(RoundError::Cancelled);
        }
        let may_call_tools = rounds.len() < MAXIMUM_TOOL_ROUNDS;
        let reply = match send_round_off_thread(context, tools, &rounds, may_call_tools, text_before.clone(), on_text.clone()).await {
            // A refusal because of the tools only counts on the first request: after that the provider has taken them.
            Err(RoundError::Refused { status, body }) if !rounds.is_empty() || tools.is_empty() => {
                return Err(RoundError::Failed(refused_sentence(&context.provider, status, &body)));
            }
            other => other?,
        };
        if !may_call_tools || reply.calls.is_empty() || tools.is_empty() {
            return Ok(LoopOutcome { answer: joined_answer(&text_before, &reply.text), last_stop_reason: reply.stop_reason, last_ended_cleanly: reply.ended_cleanly, stopped_at_round_cap: !may_call_tools });
        }
        let mut results = vec![];
        for call in &reply.calls {
            if context.cancel.is_cancelled() {
                return Err(RoundError::Cancelled);
            }
            let mut result = match toolbox {
                Some(toolbox) => toolbox.run(harness, call).await,
                None => ToolResult { call_id: call.call_id.clone(), text: "No tools are available in this turn.".into(), is_error: true },
            };
            // Every call gets its own answer under its own id: both APIs refuse a round with an unanswered call.
            result.call_id = call.call_id.clone();
            results.push(result);
        }
        text_before = joined_answer(&text_before, &reply.text);
        rounds.push(ToolRound { assistant_text: reply.text, calls: reply.calls, results });
    }
}

fn model_has_no_tools(harness: &Harness, provider_id: &str, model: &str) -> bool {
    let pair = format!("{provider_id}/{model}");
    harness.settings.strings(MODELS_WITHOUT_TOOLS_SETTING).unwrap_or_default().iter().any(|known| known == &pair)
}

/// Remembers a model that has no tools. True the first time, so the chat says so once.
fn remember_model_has_no_tools(harness: &Harness, provider_id: &str, model: &str) -> bool {
    let pair = format!("{provider_id}/{model}");
    let mut known = harness.settings.strings(MODELS_WITHOUT_TOOLS_SETTING).unwrap_or_default();
    if known.contains(&pair) {
        return false;
    }
    known.push(pair);
    harness.settings.set(MODELS_WITHOUT_TOOLS_SETTING, json!(known));
    true
}

// MARK: Earlier messages

fn is_session_id(session: &str) -> bool {
    !session.is_empty() && session.len() <= 64 && session.chars().all(|c| c.is_ascii_alphanumeric() || c == '-')
}

fn history_file(harness: &Harness, session: &str) -> PathBuf {
    harness.paths.root.join("APISessions").join(format!("{session}.json"))
}

fn load_history(harness: &Harness, session: &str) -> Vec<HistoryMessage> {
    std::fs::read(history_file(harness, session)).ok().and_then(|data| serde_json::from_slice(&data).ok()).unwrap_or_default()
}

fn save_history(harness: &Harness, session: &str, mut messages: Vec<HistoryMessage>) {
    if messages.len() > HISTORY_MESSAGES_KEPT {
        messages.drain(..messages.len() - HISTORY_MESSAGES_KEPT);
    }
    while messages.len() > 2 && messages.iter().map(|m| m.text.len()).sum::<usize>() > HISTORY_CHARACTERS_KEPT {
        messages.drain(..2);
    }
    // Both APIs want the conversation to start with the owner's side.
    while messages.first().map(|m| m.role != "user").unwrap_or(false) {
        messages.remove(0);
    }
    let file = history_file(harness, session);
    if let Some(folder) = file.parent() {
        let _ = std::fs::create_dir_all(folder);
        crate::paths::make_private(folder);
    }
    let _ = crate::store::write_atomic(&file, &serde_json::to_vec(&messages).unwrap_or_default());
}

// MARK: One bot turn

/// One turn of a bot on an API key. Returns the answer and the session that holds this chat's earlier messages.
pub async fn run_bot_turn(harness: &Harness, bot: &Bot, model: &str, system: String, prompt: &str, session: Option<String>, from_owner: bool, cancel: Arc<Cancel>, on_text: impl Fn(&str) + Send + Sync + 'static) -> Result<(String, Option<String>), RunError> {
    let provider_id = crate::brains::api_provider_id(&bot.provider).unwrap_or("");
    let provider = crate::brains::api_provider(harness, provider_id).ok_or_else(|| RunError::Failed(format!("Theo doesn't know the provider \"{provider_id}\". Pick another brain for {}.", bot.name)))?;
    let key = crate::brains::api_key(harness, &provider.id);
    if key.is_none() && !provider.keyless {
        return Err(RunError::NotInstalled(format!("{} (no API key saved: add one in Settings › Brains)", provider.label)));
    }
    if model.trim().is_empty() {
        return Err(RunError::Failed(format!("{} has no model picked for {}. Pick one in its settings.", bot.name, provider.label)));
    }
    let session = session.filter(|s| is_session_id(s)).unwrap_or_else(|| uuid::Uuid::new_v4().to_string());
    let mut history = load_history(harness, &session);
    history.push(HistoryMessage { role: "user".into(), text: prompt.to_string() });
    let toolbox = Toolbox::for_turn(harness, bot, from_owner).await;
    let system = format!("{system}\n\n{}", toolbox.prompt_section);
    let context = TurnContext { provider: provider.clone(), key, model: model.to_string(), system, history: history.clone(), cancel: cancel.clone() };
    let on_text: Arc<dyn Fn(&str) + Send + Sync> = Arc::new(on_text);
    let mut tools = toolbox.definitions.clone();
    if model_has_no_tools(harness, &provider.id, model) {
        tools.clear();
    }
    let limit = Duration::from_secs_f64(harness.settings.turn_limit_seconds());
    let started = std::time::Instant::now();
    let mut words_only_note: Option<String> = None;
    let first = tokio::time::timeout(limit, run_tool_loop(harness, &context, &tools, Some(&toolbox), on_text.clone())).await;
    let outcome = match first {
        Err(_) => {
            cancel.cancel();
            return Err(RunError::Failed(format!("{} didn't finish within the turn's time limit, so Theo stopped it.", provider.label)));
        }
        Ok(Err(RoundError::Refused { status, body })) => match tool_refusal(status, &body) {
            Some(refusal) if !tools.is_empty() => {
                // Today's words-only turn, and the chat says why: once for a model with no tools, every time for a one-off.
                words_only_note = match refusal {
                    ToolRefusal::ModelHasNoTools => remember_model_has_no_tools(harness, &provider.id, model).then(|| format!("_({model} on {} can't use apps or tools, so on it this bot answers in words only.)_", provider.label)),
                    ToolRefusal::ThisRequestOnly => Some(format!("_({} turned down this bot's tools this time ({}), so it answered in words only.)_", provider.label, refused_sentence(&provider, status, &body).chars().take(160).collect::<String>())),
                };
                let left = limit.saturating_sub(started.elapsed()).max(Duration::from_secs(5));
                match tokio::time::timeout(left, run_tool_loop(harness, &context, &[], None, on_text.clone())).await {
                    Ok(result) => result,
                    Err(_) => {
                        cancel.cancel();
                        return Err(RunError::Failed(format!("{} didn't finish within the turn's time limit, so Theo stopped it.", provider.label)));
                    }
                }
            }
            _ => Err(RoundError::Failed(refused_sentence(&provider, status, &body))),
        },
        Ok(other) => other,
    };
    drop(toolbox);
    let outcome = match outcome {
        Ok(outcome) => outcome,
        Err(RoundError::Cancelled) => return Ok((String::new(), Some(session))),
        Err(RoundError::Failed(message)) => return Err(RunError::Failed(message)),
        Err(RoundError::Refused { status, body }) => return Err(RunError::Failed(refused_sentence(&provider, status, &body))),
    };
    let mut answer = outcome.answer;
    if answer.trim().is_empty() {
        return Err(RunError::Failed(format!("{} returned no answer.", provider.label)));
    }
    if matches!(outcome.last_stop_reason.as_deref(), Some("max_tokens") | Some("length")) {
        answer.push_str("\n\n_(That hit the length limit, so it stops there.)_");
    } else if !outcome.last_ended_cleanly {
        answer.push_str("\n\n_(The connection ended early, so this may be cut off.)_");
    }
    if outcome.stopped_at_round_cap {
        answer.push_str(&format!("\n\n_(Theo stopped the tools after {MAXIMUM_TOOL_ROUNDS} rounds, so this answer works from what they found so far.)_"));
    }
    if let Some(note) = words_only_note {
        answer.push_str(&format!("\n\n{note}"));
    }
    on_text(&answer);
    history.push(HistoryMessage { role: "assistant".into(), text: answer.clone() });
    save_history(harness, &session, history);
    Ok((answer, Some(session)))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn round() -> ToolRound {
        ToolRound {
            assistant_text: "Checking.".into(),
            calls: vec![ToolCall { call_id: "c1".into(), tool_name: "echo__echo".into(), arguments_json: "{\"text\":\"hi\"}".into() }],
            results: vec![ToolResult { call_id: "c1".into(), text: "echo: hi".into(), is_error: false }],
        }
    }

    #[test]
    fn the_request_carries_the_tools_for_both_styles() {
        let tools = vec![ToolDefinition { name: "echo__echo".into(), description: "[Echo] says it back".into(), input_schema: json!({"$schema": "x", "properties": {"text": {"type": "string"}}}) }];
        let history = vec![HistoryMessage { role: "user".into(), text: "hello".into() }];
        let anthropic = request_body(WireStyle::Anthropic, "claude-haiku-5-5", "be brief", &history, &tools, &[], true);
        assert_eq!(anthropic["tools"][0]["name"], "echo__echo");
        assert_eq!(anthropic["tools"][0]["input_schema"]["type"], "object");
        assert!(anthropic["tools"][0]["input_schema"].get("$schema").is_none());
        assert_eq!(anthropic["system"], "be brief");
        assert!(anthropic.get("tool_choice").is_none());
        let openai = request_body(WireStyle::OpenAI, "gpt", "be brief", &history, &tools, &[], false);
        assert_eq!(openai["tools"][0]["type"], "function");
        assert_eq!(openai["tools"][0]["function"]["parameters"]["properties"]["text"]["type"], "string");
        assert_eq!(openai["messages"][0]["role"], "system");
        assert_eq!(openai["tool_choice"], "none");
        // No tools: no tools field at all.
        assert!(request_body(WireStyle::OpenAI, "gpt", "", &history, &[], &[], true).get("tools").is_none());
    }

    #[test]
    fn a_round_goes_back_under_its_call_id() {
        let anthropic = round_messages(&round(), WireStyle::Anthropic);
        assert_eq!(anthropic[0]["content"][1]["type"], "tool_use");
        assert_eq!(anthropic[0]["content"][1]["input"]["text"], "hi");
        assert_eq!(anthropic[1]["content"][0]["tool_use_id"], "c1");
        let openai = round_messages(&round(), WireStyle::OpenAI);
        assert_eq!(openai[0]["tool_calls"][0]["function"]["arguments"], "{\"text\":\"hi\"}");
        assert_eq!(openai[1]["role"], "tool");
        assert_eq!(openai[1]["tool_call_id"], "c1");
    }

    #[test]
    fn streamed_tool_calls_are_put_back_together() {
        let mut anthropic = ToolCallCollector::default();
        for line in [
            r#"data: {"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"toolu_1","name":"echo__echo","input":{}}}"#,
            r#"data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\"te"}}"#,
            r#"data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"xt\":\"hi\"}"}}"#,
        ] {
            anthropic.take(line, WireStyle::Anthropic);
        }
        assert_eq!(anthropic.calls(), vec![ToolCall { call_id: "toolu_1".into(), tool_name: "echo__echo".into(), arguments_json: "{\"text\":\"hi\"}".into() }]);
        let mut openai = ToolCallCollector::default();
        for line in [
            r#"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_a","function":{"name":"memory_list","arguments":""}}]}}]}"#,
            r#"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"name":"memory_list","arguments":"{}"}}]}}]}"#,
            r#"data: {"choices":[{"delta":{"tool_calls":[{"index":1,"function":{"name":"echo__echo","arguments":"{\"text\":"}}]}}]}"#,
            r#"data: {"choices":[{"delta":{"tool_calls":[{"index":1,"function":{"arguments":"\"x\"}"}}]}}]}"#,
        ] {
            openai.take(line, WireStyle::OpenAI);
        }
        let calls = openai.calls();
        assert_eq!(calls.len(), 2);
        assert_eq!(calls[0].tool_name, "memory_list");
        assert_eq!(calls[1].call_id, "call_1");
        assert_eq!(calls[1].arguments_json, "{\"text\":\"x\"}");
    }

    #[test]
    fn lines_give_text_stops_and_errors() {
        assert_eq!(read_line(r#"data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hi"}}"#, WireStyle::Anthropic).text.as_deref(), Some("Hi"));
        assert_eq!(read_line(r#"data: {"type":"message_delta","delta":{"stop_reason":"max_tokens"}}"#, WireStyle::Anthropic).stop_reason.as_deref(), Some("max_tokens"));
        assert!(read_line("data: [DONE]", WireStyle::OpenAI).done);
        assert_eq!(read_line(r#"data: {"error":{"message":"Overloaded"}}"#, WireStyle::OpenAI).error.as_deref(), Some("Overloaded"));
        assert_eq!(read_line(r#"data: {"choices":[{"delta":{"content":"yo"},"finish_reason":null}]}"#, WireStyle::OpenAI).text.as_deref(), Some("yo"));
        assert_eq!(read_line("event: ping", WireStyle::Anthropic), LineReading::default());
    }

    #[test]
    fn refusals_because_of_tools() {
        assert_eq!(tool_refusal(400, r#"{"error":{"message":"llama3 does not support tools"}}"#), Some(ToolRefusal::ModelHasNoTools));
        assert_eq!(tool_refusal(400, r#"{"error":{"message":"tools.0.input_schema: bad"}}"#), Some(ToolRefusal::ThisRequestOnly));
        assert_eq!(tool_refusal(429, "tool rate limit"), None);
        assert_eq!(tool_refusal(500, "tool crashed"), None);
        assert_eq!(tool_refusal(400, "bad model"), None);
    }

    #[test]
    fn memory_paths_stay_in_the_folder() {
        let dir = tempfile::tempdir().unwrap();
        let folder = dir.path();
        assert_eq!(resolve_memory_path(folder, "memory.md"), Some(folder.join("memory.md")));
        assert_eq!(resolve_memory_path(folder, "skills/x/SKILL.md"), Some(folder.join("skills").join("x").join("SKILL.md")));
        for bad in ["", "/etc/passwd", "~/x", "../x", "a/../../x", "C:\\Windows\\x", "\\\\server\\share", "a\\..\\..\\x"] {
            assert!(resolve_memory_path(folder, bad).is_none(), "{bad}");
        }
        #[cfg(unix)]
        {
            std::os::unix::fs::symlink("/etc", folder.join("out")).unwrap();
            assert!(resolve_memory_path(folder, "out/passwd").is_none());
        }
        let (said, failed) = write_memory(folder, "memory.md", Some("one"), false);
        assert!(!failed, "{said}");
        write_memory(folder, "memory.md", Some("two"), true);
        assert_eq!(std::fs::read_to_string(folder.join("memory.md")).unwrap(), "one\ntwo");
        assert!(write_memory(folder, "../escape.md", Some("x"), false).1);
        assert!(list_memory(folder).0.contains("memory.md"));
    }

    #[test]
    fn tool_answers_are_cut_and_joined() {
        assert!(trimmed_result(&"x".repeat(MAXIMUM_RESULT_CHARACTERS + 5)).contains("cut: the tool's answer was"));
        assert_eq!(joined_answer("", "b"), "b");
        assert_eq!(joined_answer("a", " "), "a");
        assert_eq!(joined_answer("a", "b"), "a\n\nb");
        assert_eq!(text_of_tool_result(&json!({"content": [{"type": "text", "text": "hi"}, {"type": "image"}]})), "hi\n[image]");
        assert_eq!(error_message_in(r#"{"error":{"message":"bad key"}}"#).as_deref(), Some("bad key"));
        assert_eq!(error_message_in(r#"[{"error":{"message":"gemini says no"}}]"#).as_deref(), Some("gemini says no"));
    }
}
