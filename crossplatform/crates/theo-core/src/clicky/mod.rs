//! Clicky, the voice and screen companion, for Windows (and the parts that aren't Windows-only, everywhere): one turn is
//! what was said, a picture of every monitor, one request to Clicky's brain with the Mac's prompt, and an answer whose
//! [POINT]/[MARK] tags are mapped back onto the monitors for the overlay. The desktop app does the listening, the spark and
//! the speaking around it (`app/src-tauri/src/clicky.rs`).
//!
//! Any brain the owner has will do (the Mac's `ClickyModels` and `BrainChoice`):
//! - an API key: the pictures go in the request (Anthropic's `image` blocks, OpenAI-style `image_url` data URLs). A model
//!   that turns pictures down is asked again with words only, and remembered (`clicky.modelsWithoutImages`);
//! - Claude Code: `claude -p --input-format stream-json`, the pictures in the one user message (the Mac's `ClaudeCodeBridge`);
//! - Codex: `codex exec -i <pictures>`;
//! - Cursor Agent, Gemini CLI, Grok and OpenCode: words only. Clicky then answers from the words and says once that it
//!   can't see the screen on that brain.
//!
//! Settings (`settings.json`): `products.clicky` (on/off; missing = off), `clicky.brain` (`claude`, `codex`, `api:openai`…;
//! empty = the first that works here), `clicky.model`, `clicky.voice`, `clicky.rate` (-10 to 10), `clicky.shortcut`
//! (a theo-voice chord id, `ctrlAlt` by default), `clicky.spark` (`always` | `talking`).

pub mod desktop;
pub mod prompt;
pub mod screens;
pub mod speech;
pub mod tags;

use crate::engine::{Cancel, Format, Spec};
use crate::harness::Harness;
use once_cell::sync::Lazy;
use screens::{Monitor, Screen};
use serde_json::{json, Value};
use std::io::BufRead;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::time::Duration;

pub const PRODUCT_SETTING: &str = "products.clicky";
pub const BRAIN_SETTING: &str = "clicky.brain";
pub const MODEL_SETTING: &str = "clicky.model";
pub const VOICE_SETTING: &str = "clicky.voice";
pub const RATE_SETTING: &str = "clicky.rate";
pub const SHORTCUT_SETTING: &str = "clicky.shortcut";
pub const SPARK_SETTING: &str = "clicky.spark";
const MODELS_WITHOUT_IMAGES_SETTING: &str = "clicky.modelsWithoutImages";
const TOLD_CANT_SEE_SETTING: &str = "clicky.toldCantSee";

/// The longest one Clicky answer may take.
pub const TURN_LIMIT: Duration = Duration::from_secs(180);
const MAXIMUM_OUTPUT_TOKENS: u64 = 4096;
/// Claude Code's model for Clicky when none is picked (the Mac's default, Sonnet).
pub const CLAUDE_DEFAULT_MODEL: &str = "claude-sonnet-5-5";

/// Providers whose APIs take no pictures at all.
const TEXT_ONLY_PROVIDERS: [&str; 2] = ["deepseek", "cerebras"];
/// The order an API key is picked in when the owner hasn't picked Clicky's brain: the ones with good vision first.
const KEY_ORDER: [&str; 11] = ["anthropic", "openai", "gemini", "xai", "openrouter", "groq", "mistral", "together", "fireworks", "deepseek", "cerebras"];
/// Then the agents, after Claude Code: the one that takes pictures first.
const AGENT_ORDER: [&str; 5] = ["codex", "gemini", "cursor", "grok", "opencode"];

/// The words of the last exchanges, for the next question (text only, like the Mac).
static HISTORY: Lazy<Mutex<Vec<(String, String)>>> = Lazy::new(|| Mutex::new(vec![]));

pub fn is_on(h: &Harness) -> bool {
    // The products module (products.rs) reads the choice: a saved one wins, else Clicky starts off.
    crate::products::is_on(h, "clicky")
}

/// Forgets the conversation (a new session).
pub fn forget_history() {
    HISTORY.lock().unwrap().clear();
}

/// Clicky's brain for this turn.
#[derive(Clone, Debug, PartialEq)]
pub struct BrainPick {
    /// `claude`, `codex`, … or `api:<provider>`.
    pub engine: String,
    /// Empty: the agent's own default.
    pub model: String,
    pub automatic: bool,
}

impl BrainPick {
    pub fn label(&self) -> String {
        let name = crate::brains::label(&self.engine);
        if self.model.is_empty() { name } else { format!("{name}, {}", self.model) }
    }

    fn remembered_as(&self) -> String {
        format!("{}/{}", self.engine, self.model)
    }
}

/// Whether a brain takes pictures (before asking it).
pub fn takes_pictures(h: &Harness, pick: &BrainPick) -> bool {
    if let Some(provider) = crate::brains::api_provider_id(&pick.engine) {
        if TEXT_ONLY_PROVIDERS.contains(&provider) {
            return false;
        }
        let refused = h.settings.strings(MODELS_WITHOUT_IMAGES_SETTING).unwrap_or_default();
        return !refused.contains(&pick.remembered_as());
    }
    matches!(pick.engine.as_str(), "claude" | "codex")
}

/// The model on a key Clicky starts with: one that sees pictures when the provider's list shows one, else the provider's
/// preferred chat model.
pub fn vision_model(provider: &str, models: &[String]) -> Option<String> {
    let wanted: &[&str] = match provider {
        "anthropic" => &["claude-sonnet", "claude-opus", "claude-haiku"],
        "openai" => &["gpt-5", "gpt-4.1", "gpt-4o"],
        "gemini" => &["gemini-2.5-flash", "flash", "gemini"],
        "xai" => &["grok-4", "vision", "grok"],
        "openrouter" => &["anthropic/claude-sonnet", "openai/gpt-5", "google/gemini"],
        "groq" => &["llama-4-scout", "llama-4", "vision"],
        "mistral" => &["pixtral", "mistral-medium", "mistral-small"],
        "together" | "fireworks" => &["vision", "llama-4", "qwen2.5-vl"],
        _ => &[],
    };
    let chat: Vec<&String> = models.iter().filter(|model| crate::brains::preferred_model(provider, std::slice::from_ref(model)).is_some()).collect();
    for word in wanted {
        if let Some(model) = chat.iter().find(|model| model.to_lowercase().contains(word) && !model.to_lowercase().contains("audio")) {
            return Some(model.to_string());
        }
    }
    crate::brains::preferred_model(provider, models)
}

/// The brain Clicky thinks with: the owner's pick when it works here, else the first that does (Claude Code, then an API
/// key, then the other agents). None when nothing here can think.
pub async fn pick_brain(h: &Harness) -> Option<BrainPick> {
    let chosen_model = h.settings.string(MODEL_SETTING).unwrap_or_default();
    if let Some(engine) = h.settings.string(BRAIN_SETTING).filter(|engine| crate::brains::is_known_engine(engine)) {
        if crate::brains::usable_without_asking(h, &engine) {
            let model = if !chosen_model.is_empty() { chosen_model } else { default_model(h, &engine).await };
            return Some(BrainPick { engine, model, automatic: false });
        }
    }
    if h.executable("claude").is_some() {
        return Some(BrainPick { engine: "claude".into(), model: CLAUDE_DEFAULT_MODEL.into(), automatic: true });
    }
    for provider in KEY_ORDER {
        let engine = format!("api:{provider}");
        if crate::brains::api_key(h, provider).is_some() {
            let model = default_model(h, &engine).await;
            if !model.is_empty() {
                return Some(BrainPick { engine, model, automatic: true });
            }
        }
    }
    for agent in AGENT_ORDER {
        if h.executable(agent).is_some() {
            let model = crate::brains::command_line_brain(agent).map(|brain| brain.default_model.to_string()).unwrap_or_default();
            return Some(BrainPick { engine: agent.into(), model, automatic: true });
        }
    }
    None
}

async fn default_model(h: &Harness, engine: &str) -> String {
    if engine == "claude" {
        return CLAUDE_DEFAULT_MODEL.into();
    }
    match crate::brains::api_provider_id(engine) {
        Some(provider) => {
            let models = crate::brains::list_models(h, provider).await.unwrap_or_default();
            vision_model(provider, &models).unwrap_or_default()
        }
        None => crate::brains::command_line_brain(engine).map(|brain| brain.default_model.to_string()).unwrap_or_default(),
    }
}

/// What the brain said.
#[derive(Clone, Debug, Default)]
pub struct BrainAnswer {
    pub text: String,
    pub saw_screen: bool,
    /// Said to the owner once: the brain couldn't see the screen.
    pub note: Option<String>,
}

/// The user message's content: the conversation, then each screen's header and picture.
fn content_parts<'a>(conversation: &str, screens: &'a [Screen]) -> Vec<(String, Option<&'a Screen>)> {
    let mut parts = vec![(conversation.to_string(), None)];
    for screen in screens {
        parts.push((screen.header(), Some(screen)));
    }
    parts
}

/// One request to Clicky's brain. `on_text` gets the answer as it grows.
pub async fn ask_brain(h: &Harness, pick: &BrainPick, transcript: &str, screens: &[Screen], cancel: Arc<Cancel>, on_text: Arc<dyn Fn(&str) + Send + Sync>) -> Result<BrainAnswer, String> {
    let history = HISTORY.lock().unwrap().clone();
    let conversation = prompt::conversation_text(&history, transcript);
    let owner = h.settings.owner_name();
    let pictures = takes_pictures(h, pick) && !screens.is_empty();
    let mut answer = if let Some(provider_id) = crate::brains::api_provider_id(&pick.engine) {
        let provider = crate::brains::api_provider(h, provider_id).ok_or("Theo doesn't know that provider.")?;
        let key = crate::brains::api_key(h, provider_id);
        if key.is_none() && !provider.keyless {
            return Err(format!("{} needs an API key. Add one in Settings › Brains.", provider.label));
        }
        let images = if pictures { screens.to_vec() } else { vec![] };
        let first = ask_api(&provider, key.clone(), &pick.model, &prompt::system_prompt(&owner, pictures), &conversation, &images, cancel.clone(), on_text.clone()).await;
        match first {
            Err(ApiError::RefusedPictures(_)) if pictures => {
                // This model takes no pictures: remembered, then asked again with words only.
                let mut refused = h.settings.strings(MODELS_WITHOUT_IMAGES_SETTING).unwrap_or_default();
                if !refused.contains(&pick.remembered_as()) {
                    refused.push(pick.remembered_as());
                    h.settings.set(MODELS_WITHOUT_IMAGES_SETTING, json!(refused));
                }
                let text = ask_api(&provider, key, &pick.model, &prompt::system_prompt(&owner, false), &conversation, &[], cancel, on_text).await.map_err(ApiError::into_words)?;
                BrainAnswer { text, saw_screen: false, note: None }
            }
            Err(error) => return Err(error.into_words()),
            Ok(text) => BrainAnswer { text, saw_screen: pictures, note: None },
        }
    } else {
        let text = ask_agent(h, pick, &prompt::system_prompt(&owner, pictures), &conversation, if pictures { screens } else { &[] }, cancel, on_text).await?;
        BrainAnswer { text, saw_screen: pictures, note: None }
    };
    if !answer.saw_screen && !screens.is_empty() {
        let mut told = h.settings.strings(TOLD_CANT_SEE_SETTING).unwrap_or_default();
        if !told.contains(&pick.remembered_as()) {
            told.push(pick.remembered_as());
            h.settings.set(TOLD_CANT_SEE_SETTING, json!(told));
            answer.note = Some(format!("heads up: {} can't see your screen, so i'm going from your words. pick a brain that takes pictures in settings, clicky, to let me look.", crate::brains::label(&pick.engine).replace(" (API key)", "").to_lowercase()));
        }
    }
    Ok(answer)
}

#[derive(Debug)]
enum ApiError {
    RefusedPictures(String),
    Failed(String),
    Cancelled,
}

impl ApiError {
    fn into_words(self) -> String {
        match self {
            ApiError::RefusedPictures(words) | ApiError::Failed(words) => words,
            ApiError::Cancelled => "Stopped.".into(),
        }
    }
}

/// Whether a refusal was about the pictures.
pub fn refused_for_pictures(status: u16, body: &str) -> bool {
    if !(400..500).contains(&status) || [401, 403, 408, 429].contains(&status) {
        return false;
    }
    let lower = body.to_lowercase();
    ["image", "vision", "multimodal", "multi-modal", "content must be a string", "image_url"].iter().any(|word| lower.contains(word))
}

/// The request body for an API, with the pictures in the user's message.
pub fn api_request_body(style: crate::brains::WireStyle, model: &str, system: &str, conversation: &str, screens: &[Screen]) -> Value {
    use crate::brains::WireStyle;
    let parts = content_parts(conversation, screens);
    match style {
        WireStyle::Anthropic => {
            let mut content = vec![];
            for (text, screen) in &parts {
                content.push(json!({"type": "text", "text": text}));
                if let Some(screen) = screen {
                    content.push(json!({"type": "image", "source": {"type": "base64", "media_type": "image/jpeg", "data": screen.jpeg_base64()}}));
                }
            }
            json!({"model": model, "max_tokens": MAXIMUM_OUTPUT_TOKENS, "stream": true, "system": system, "messages": [{"role": "user", "content": content}]})
        }
        WireStyle::OpenAI => {
            let user = if screens.is_empty() {
                json!({"role": "user", "content": conversation})
            } else {
                let mut content = vec![];
                for (text, screen) in &parts {
                    content.push(json!({"type": "text", "text": text}));
                    if let Some(screen) = screen {
                        content.push(json!({"type": "image_url", "image_url": {"url": format!("data:image/jpeg;base64,{}", screen.jpeg_base64())}}));
                    }
                }
                json!({"role": "user", "content": content})
            };
            json!({"model": model, "stream": true, "messages": [{"role": "system", "content": system}, user]})
        }
    }
}

#[allow(clippy::too_many_arguments)]
async fn ask_api(provider: &crate::brains::ApiProvider, key: Option<String>, model: &str, system: &str, conversation: &str, screens: &[Screen], cancel: Arc<Cancel>, on_text: Arc<dyn Fn(&str) + Send + Sync>) -> Result<String, ApiError> {
    let body = api_request_body(provider.style, model, system, conversation, screens);
    let provider = provider.clone();
    let had_pictures = !screens.is_empty();
    tokio::task::spawn_blocking(move || send_streamed(&provider, key.as_deref(), &body, had_pictures, &cancel, &*on_text))
        .await
        .map_err(|_| ApiError::Failed("The request stopped.".into()))?
}

fn send_streamed(provider: &crate::brains::ApiProvider, key: Option<&str>, body: &Value, had_pictures: bool, cancel: &Cancel, on_text: &(dyn Fn(&str) + Send + Sync)) -> Result<String, ApiError> {
    use crate::apichat::{authorize, endpoint, error_message_in, http_agent, read_line, transport_problem};
    let address = endpoint(provider);
    let request = authorize(http_agent(&address).post(&address).set("Content-Type", "application/json").set("Accept", "text/event-stream"), provider.style, key);
    let response = match request.send_string(&body.to_string()) {
        Ok(response) => response,
        Err(ureq::Error::Status(status, response)) => {
            let mut text = String::new();
            let _ = std::io::Read::read_to_string(&mut std::io::Read::take(response.into_reader(), 8000), &mut text);
            let said = error_message_in(&text).unwrap_or_else(|| text.chars().take(200).collect::<String>().trim().to_string());
            let words = format!("{} answered {status}: {}", provider.label, if said.is_empty() { "no reason given".to_string() } else { said });
            if had_pictures && refused_for_pictures(status, &text) {
                return Err(ApiError::RefusedPictures(words));
            }
            return Err(ApiError::Failed(words));
        }
        Err(error) => return Err(ApiError::Failed(format!("Couldn't reach {}: {}", provider.label, transport_problem(&error)))),
    };
    let mut text = String::new();
    let mut not_streamed = String::new();
    for line in std::io::BufReader::new(response.into_reader()).lines() {
        if cancel.is_cancelled() {
            return Err(ApiError::Cancelled);
        }
        let Ok(line) = line else { break };
        if !line.starts_with("data:") && !line.starts_with("event:") && not_streamed.len() < 8000 {
            not_streamed.push_str(&line);
        }
        let reading = read_line(&line, provider.style);
        if let Some(error) = reading.error {
            return Err(ApiError::Failed(format!("{}: {error}", provider.label)));
        }
        if let Some(piece) = reading.text.filter(|piece| !piece.is_empty()) {
            text.push_str(&piece);
            on_text(&text);
        }
        if reading.done {
            break;
        }
    }
    // A server that answered with plain JSON instead of a stream.
    if text.is_empty() && !not_streamed.trim().is_empty() {
        if let Some(message) = error_message_in(not_streamed.trim()) {
            return Err(ApiError::Failed(format!("{}: {message}", provider.label)));
        }
        if let Ok(whole) = serde_json::from_str::<Value>(not_streamed.trim()) {
            text = whole["choices"][0]["message"]["content"].as_str().map(str::to_string).unwrap_or_else(|| {
                whole["content"].as_array().map(|blocks| blocks.iter().filter_map(|block| block["text"].as_str()).collect::<Vec<_>>().join("")).unwrap_or_default()
            });
        }
    }
    on_text(&text);
    Ok(text)
}

/// The stream-json line Claude Code reads: one user message with the conversation and every screen's picture.
pub fn claude_user_message(conversation: &str, screens: &[Screen]) -> String {
    let mut content = vec![];
    for (text, screen) in content_parts(conversation, screens) {
        content.push(json!({"type": "text", "text": text}));
        if let Some(screen) = screen {
            content.push(json!({"type": "image", "source": {"type": "base64", "media_type": "image/jpeg", "data": screen.jpeg_base64()}}));
        }
    }
    json!({"type": "user", "message": {"role": "user", "content": content}}).to_string() + "\n"
}

/// This turn's own folder (the system prompt, pictures for Codex, the agent's working folder), removed when it ends.
struct TurnFolder(PathBuf);

impl Drop for TurnFolder {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

/// Claude Code's settings for a Clicky turn: no hooks (written to a file, which the stand-in in the tests reads too).
pub const CLAUDE_SETTINGS: &str = r#"{"disableAllHooks":true}"#;

/// Claude Code's command line for Clicky (the Mac's ClickyCore `ClaudeArgs`): no tools, no MCP, no skills, no hooks, no
/// saved session, the system prompt from a file.
pub fn claude_arguments(model: &str, system_prompt_file: &std::path::Path, settings_file: &std::path::Path) -> Vec<String> {
    let mut arguments: Vec<String> = ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose", "--include-partial-messages"].iter().map(|a| a.to_string()).collect();
    if !model.is_empty() {
        arguments.extend(["--model".into(), model.to_string()]);
    }
    arguments.extend([
        "--system-prompt-file".into(),
        system_prompt_file.to_string_lossy().to_string(),
        "--tools".into(),
        String::new(),
        "--strict-mcp-config".into(),
        "--disable-slash-commands".into(),
        "--no-session-persistence".into(),
        "--setting-sources".into(),
        "user".into(),
        "--settings".into(),
        settings_file.to_string_lossy().to_string(),
    ]);
    arguments
}

async fn ask_agent(h: &Harness, pick: &BrainPick, system: &str, conversation: &str, screens: &[Screen], cancel: Arc<Cancel>, on_text: Arc<dyn Fn(&str) + Send + Sync>) -> Result<String, String> {
    let engine = pick.engine.as_str();
    let label = crate::brains::label(engine);
    let program = h.executable(engine).ok_or_else(|| format!("{label} isn't installed here. Pick another brain in Settings › Clicky."))?;
    let folder = TurnFolder(h.paths.turns_dir().join(format!("clicky-{}", uuid::Uuid::new_v4())));
    std::fs::create_dir_all(&folder.0).map_err(|e| format!("Couldn't make Clicky's turn folder: {e}"))?;
    let words = format!("{system}\n\n{conversation}");
    let model = pick.model.clone();
    let folder_text = folder.0.to_string_lossy().to_string();
    let mut env: Vec<(String, String)> = vec![("NO_COLOR".into(), "1".into())];
    let mut stdin = None;
    let mut codex_reply = None;
    let (args, format) = match engine {
        "claude" => {
            let prompt_file = folder.0.join("system-prompt.md");
            std::fs::write(&prompt_file, system).map_err(|e| format!("Couldn't write Clicky's prompt: {e}"))?;
            crate::paths::make_private(&prompt_file);
            env.push(("CLAUDE_CODE_DISABLE_CLAUDE_MDS".into(), "1".into()));
            stdin = Some(claude_user_message(conversation, screens));
            let settings_file = folder.0.join("settings.json");
            std::fs::write(&settings_file, CLAUDE_SETTINGS).map_err(|e| format!("Couldn't write Clicky's settings for Claude Code: {e}"))?;
            (claude_arguments(&model, &prompt_file, &settings_file), Format::Claude)
        }
        "codex" => {
            let reply = folder.0.join("codex-reply.txt");
            codex_reply = Some(reply.clone());
            let mut a: Vec<String> = vec!["exec".into(), "--json".into(), "--skip-git-repo-check".into(), "-c".into(), "check_for_update_on_startup=false".into(), "-s".into(), "read-only".into(), "-C".into(), folder_text.clone(), "-o".into(), reply.to_string_lossy().to_string()];
            if !model.is_empty() {
                a.extend(["-m".into(), model.clone()]);
            }
            let mut prompt_words = words.clone();
            for screen in screens {
                let file = folder.0.join(format!("screen-{}.jpg", screen.number));
                std::fs::write(&file, &screen.jpeg).map_err(|e| format!("Couldn't save the screenshot for Codex: {e}"))?;
                a.extend(["-i".into(), file.to_string_lossy().to_string()]);
                prompt_words.push_str(&format!("\n\nattached picture {}: {}", screen.number, screen.header()));
            }
            // `--` ends the pictures, then `-`: the prompt on standard input.
            a.extend(["--".into(), "-".into()]);
            stdin = Some(prompt_words);
            (a, Format::Codex)
        }
        "cursor" => {
            let mut a: Vec<String> = vec!["-p".into(), "--output-format".into(), "stream-json".into(), "--stream-partial-output".into(), "--mode".into(), "ask".into(), "--trust".into(), "--workspace".into(), folder_text.clone()];
            if !model.is_empty() {
                a.extend(["--model".into(), model.clone()]);
            }
            a.push(words);
            (a, Format::Cursor)
        }
        "gemini" => {
            let mut a: Vec<String> = vec!["-p".into(), String::new(), "--output-format".into(), "json".into()];
            if !model.is_empty() {
                a.extend(["-m".into(), model.clone()]);
            }
            stdin = Some(words);
            (a, Format::Gemini)
        }
        "grok" => {
            let mut a: Vec<String> = vec!["-p".into(), words, "--output-format".into(), "streaming-messages-json".into(), "--permission-mode".into(), "dontAsk".into(), "--tools".into(), "web_search,web_fetch".into(), "--no-subagents".into()];
            if !model.is_empty() {
                a.extend(["-m".into(), model.clone()]);
            }
            (a, Format::Grok)
        }
        _ => {
            let mut a: Vec<String> = vec!["run".into()];
            if !model.is_empty() {
                a.extend(["-m".into(), model.clone()]);
            }
            a.extend(["--format".into(), "json".into(), "--dir".into(), folder_text.clone(), words]);
            (a, Format::OpenCode)
        }
    };
    let spec = Spec {
        program,
        args,
        env,
        remove_env: ["CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_CODE_SSE_PORT", "ANTHROPIC_API_KEY_HELPER"].iter().map(|s| s.to_string()).collect(),
        cwd: folder.0.clone(),
        limit: TURN_LIMIT,
        format,
        stdin,
    };
    let shown = on_text.clone();
    let outcome = crate::engine::run(spec, cancel, None, move |text| shown(text)).await.map_err(|e| format!("Couldn't start {label}: {e}"))?;
    let mut text = outcome.text.trim().to_string();
    if text.is_empty() {
        if let Some(reply) = codex_reply.and_then(|file| std::fs::read_to_string(file).ok()) {
            text = reply.trim().to_string();
        }
    }
    match outcome.end {
        crate::engine::EndReason::Cancelled => return Err("Stopped.".into()),
        crate::engine::EndReason::Timeout => return Err(format!("{label} took longer than {} minutes to answer.", TURN_LIMIT.as_secs() / 60)),
        crate::engine::EndReason::Exited => {}
    }
    let everything = format!("{}\n{}\n{}\n{}", outcome.error.clone().unwrap_or_default(), outcome.stderr_tail, outcome.unread_output, text);
    if engine == "claude" && (everything.contains("Not logged in") || everything.contains("Please run /login")) {
        return Err("Claude Code isn't signed in on this computer. Sign in from Settings › Brains.".into());
    }
    if let Some(problem) = crate::brains::sign_in_problem(engine, &everything).or_else(|| crate::brains::usage_limit_message(engine, &everything)) {
        if text.is_empty() || outcome.error.is_some() {
            return Err(problem);
        }
    }
    if let Some(error) = outcome.error.filter(|_| text.is_empty()) {
        return Err(format!("{label}: {}", error.chars().take(300).collect::<String>()));
    }
    if text.is_empty() {
        let why = outcome.stderr_tail.lines().rev().find(|line| !line.trim().is_empty()).unwrap_or("it said nothing").trim().chars().take(200).collect::<String>();
        return Err(format!("{label} didn't answer: {why}"));
    }
    Ok(text)
}

/// A tag's place on the monitors: the screen it names (1 when none), mapped from that screen's image to physical pixels.
fn mapped(tag: &tags::Tag, screens: &[Screen]) -> Option<Value> {
    let screen = screens.iter().find(|screen| screen.number == tag.screen_number())?;
    let (image_width, image_height, monitor) = (screen.image_width, screen.image_height, &screen.monitor);
    let mut entry = json!({"screen": screen.number, "monitor": monitor.to_json()});
    match tag.target {
        tags::Target::Point { x, y } => {
            let (px, py) = screens::image_point_to_physical(x, y, image_width, image_height, monitor);
            entry["x"] = px.into();
            entry["y"] = py.into();
        }
        tags::Target::Box { x, y, width, height } => {
            let (bx, by, bw, bh) = screens::image_box_to_physical(x, y, width, height, image_width, image_height, monitor);
            entry["x"] = (bx + bw / 2).into();
            entry["y"] = (by + bh / 2).into();
            entry["box"] = json!({"x": bx, "y": by, "width": bw, "height": bh});
        }
        tags::Target::None => return None,
    }
    if let Some(name) = &tag.name {
        entry["label"] = name.clone().into();
    }
    if let Some(style) = tag.style {
        entry["style"] = style.name().into();
    }
    if let Some(text) = tag.display_text() {
        entry["text"] = text.into();
    }
    Some(entry)
}

/// What the overlay does with an answer: what to say, where to fly, what to draw. Positions are physical pixels.
pub fn overlay_plan(answer: &str, screens: &[Screen]) -> Value {
    let reply = tags::read_reply(answer);
    let point = reply.point.as_ref().and_then(|tag| mapped(tag, screens));
    let marks: Vec<Value> = reply.marks.iter().filter_map(|tag| mapped(tag, screens)).collect();
    json!({"speech": reply.speech, "point": point, "marks": marks, "clear": reply.clear})
}

/// One whole turn on the brain picked: the answer, its overlay plan, and the exchange remembered for the next question.
pub async fn turn(h: &Harness, transcript: &str, screens: &[Screen], cancel: Arc<Cancel>, on_text: Arc<dyn Fn(&str) + Send + Sync>) -> Result<Value, String> {
    let pick = pick_brain(h).await.ok_or("Clicky has no brain yet: add an API key or sign in to an agent in Settings › Brains.")?;
    let started = std::time::Instant::now();
    let answer = ask_brain(h, &pick, transcript, screens, cancel, on_text).await?;
    let mut plan = overlay_plan(&answer.text, screens);
    let mut speech = plan["speech"].as_str().unwrap_or("").to_string();
    if let Some(note) = &answer.note {
        speech = if speech.is_empty() { note.clone() } else { format!("{note} {speech}") };
        plan["speech"] = speech.clone().into();
    }
    {
        let mut history = HISTORY.lock().unwrap();
        history.push((transcript.to_string(), speech.clone()));
        let excess = history.len().saturating_sub(prompt::HISTORY_EXCHANGES * 2);
        history.drain(..excess);
    }
    plan["answer"] = answer.text.clone().into();
    plan["brain"] = pick.label().into();
    plan["engine"] = pick.engine.clone().into();
    plan["model"] = pick.model.clone().into();
    plan["automatic"] = pick.automatic.into();
    plan["sawScreen"] = answer.saw_screen.into();
    plan["note"] = answer.note.clone().map(Value::from).unwrap_or(Value::Null);
    plan["seconds"] = json!((started.elapsed().as_secs_f64() * 10.0).round() / 10.0);
    plan["screens"] = Value::Array(screens.iter().map(Screen::summary).collect());
    Ok(plan)
}

/// The settings page's view of Clicky.
pub async fn state(h: &Harness) -> Value {
    let pick = pick_brain(h).await;
    json!({
        "on": is_on(h),
        "brain": h.settings.string(BRAIN_SETTING).unwrap_or_default(),
        "model": h.settings.string(MODEL_SETTING).unwrap_or_default(),
        "voice": h.settings.string(VOICE_SETTING).unwrap_or_default(),
        "rate": h.settings.number(RATE_SETTING).unwrap_or(0.0),
        "shortcut": h.settings.string(SHORTCUT_SETTING).unwrap_or_else(|| "ctrlAlt".into()),
        "spark": h.settings.string(SPARK_SETTING).unwrap_or_else(|| "always".into()),
        "using": pick.as_ref().map(|pick| json!({"engine": pick.engine, "model": pick.model, "label": pick.label(), "automatic": pick.automatic, "seesScreen": takes_pictures(h, pick)})),
        "canSeeScreen": screens::can_capture(),
        "os": std::env::consts::OS,
    })
}

/// The desktop app's side of Clicky (the overlay, the voice, push-to-talk), when this engine runs inside the app.
pub trait Desktop: Send + Sync {
    /// Runs a whole turn as if `transcript` had been said: screenshots, the spark, the bubble and the voice.
    fn ask(&self, transcript: String) -> Value;
    /// Escape: speech stops, the answer is dropped, marks go.
    fn stop(&self) -> Value;
    /// What the overlay is doing.
    fn status(&self) -> Value;
}

static DESKTOP: once_cell::sync::OnceCell<Arc<dyn Desktop>> = once_cell::sync::OnceCell::new();

pub fn set_desktop(desktop: Arc<dyn Desktop>) {
    let _ = DESKTOP.set(desktop);
}

fn s(v: &Value, k: &str) -> Option<String> {
    v.get(k).and_then(|x| x.as_str()).map(str::to_string)
}

/// The control commands (from the settings page, tests and the tester kit):
/// - `clickyState`
/// - `clickyTest {text, image?|images?, monitors?, reply?, fresh?}`: one turn without a mic or a screen. `image(s)` are
///   picture files standing in for the monitors (`monitors` gives their geometry); `reply` skips the brain and reads that
///   answer; `fresh` forgets earlier exchanges first.
/// - `clickyCapture {save?}`: a real screenshot of every monitor (Windows), optionally saved as JPEGs in a folder.
/// - `clickyVoices`, `clickySpeak {text, voice?, toFile?}`
/// - `clickyAsk {text}`: in the app, a whole turn with the real screen, spark and voice (Settings' "Try it"); in theod, the
///   turn with the real screen, answered here. `clickyStop`: Escape. `clickyOverlay`: what the app's overlay is doing.
pub async fn control(h: &Arc<Harness>, name: &str, cmd: &Value) -> Value {
    use crate::control::{err, ok};
    match name {
        "clickyState" => {
            let mut result = state(h).await;
            result["desktop"] = DESKTOP.get().map(|desktop| desktop.status()).unwrap_or(Value::Null);
            ok(result)
        }
        "clickyAsk" => {
            let Some(text) = s(cmd, "text").filter(|t| !t.trim().is_empty()) else { return err("Needs text.") };
            if let Some(desktop) = DESKTOP.get() {
                return ok(desktop.ask(text));
            }
            let screens = if screens::can_capture() { tokio::task::spawn_blocking(screens::capture_all).await.ok().and_then(Result::ok).unwrap_or_default() } else { vec![] };
            match turn(h, &text, &screens, Cancel::new(), Arc::new(|_: &str| {})).await {
                Ok(plan) => ok(plan),
                Err(problem) => err(&problem),
            }
        }
        "clickyStop" => ok(DESKTOP.get().map(|desktop| desktop.stop()).unwrap_or_else(|| json!({"stopped": false}))),
        "clickyOverlay" => ok(DESKTOP.get().map(|desktop| desktop.status()).unwrap_or(Value::Null)),
        "clickyTest" => {
            let Some(text) = s(cmd, "text").filter(|t| !t.trim().is_empty()) else { return err("Needs text.") };
            if cmd["fresh"].as_bool() == Some(true) {
                forget_history();
            }
            let mut files: Vec<String> = cmd["images"].as_array().map(|a| a.iter().filter_map(|v| v.as_str().map(str::to_string)).collect()).unwrap_or_default();
            if let Some(one) = s(cmd, "image") {
                files.insert(0, one);
            }
            let monitors: Vec<Option<Monitor>> = cmd["monitors"].as_array().map(|a| a.iter().map(Monitor::from_json).collect()).unwrap_or_default();
            let mut screens = vec![];
            for (index, file) in files.iter().enumerate() {
                match screens::screen_from_file(std::path::Path::new(file), index + 1, monitors.get(index).cloned().flatten()) {
                    Ok(screen) => screens.push(screen),
                    Err(problem) => return err(&problem),
                }
            }
            if let Some(reply) = s(cmd, "reply") {
                let mut plan = overlay_plan(&reply, &screens);
                plan["answer"] = reply.into();
                plan["screens"] = Value::Array(screens.iter().map(Screen::summary).collect());
                return ok(plan);
            }
            match turn(h, &text, &screens, Cancel::new(), Arc::new(|_: &str| {})).await {
                Ok(plan) => ok(plan),
                Err(problem) => err(&problem),
            }
        }
        "clickyCapture" => {
            let started = std::time::Instant::now();
            let captured = tokio::task::spawn_blocking(screens::capture_all).await.unwrap_or_else(|_| Err("The capture stopped.".into()));
            match captured {
                Ok(screens) => {
                    if let Some(folder) = s(cmd, "save") {
                        let _ = std::fs::create_dir_all(&folder);
                        for screen in &screens {
                            let _ = std::fs::write(std::path::Path::new(&folder).join(format!("screen-{}.jpg", screen.number)), &screen.jpeg);
                        }
                    }
                    ok(json!({"screens": screens.iter().map(Screen::summary).collect::<Vec<_>>(), "milliseconds": started.elapsed().as_millis() as u64}))
                }
                Err(problem) => err(&problem),
            }
        }
        "clickyVoices" => match speech::voices().await {
            Ok(voices) => ok(json!({"voices": voices})),
            Err(problem) => err(&problem),
        },
        "clickySpeak" => {
            let text = s(cmd, "text").unwrap_or_else(|| "hi, i'm clicky.".into());
            let voice = s(cmd, "voice").or_else(|| h.settings.string(VOICE_SETTING)).unwrap_or_default();
            let rate = h.settings.number(RATE_SETTING).unwrap_or(0.0) as i32;
            let result = match s(cmd, "toFile") {
                Some(file) => speech::speak_to_file(&text, &voice, rate, std::path::Path::new(&file)).await,
                None => match speech::speak(&text, &voice, rate) {
                    Ok(speaking) => {
                        speaking.finished().await;
                        Ok(())
                    }
                    Err(problem) => Err(problem),
                },
            };
            match result {
                Ok(()) => ok(json!({"spoke": true})),
                Err(problem) => err(&problem),
            }
        }
        _ => err(&format!("Unknown command {name}")),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn screen(number: usize, monitor: Monitor) -> Screen {
        Screen { number, cursor_here: number == 1, position: "main".into(), image_width: 1568, image_height: 882, jpeg: vec![0xFF, 0xD8, 1, 2], monitor }
    }

    fn monitor(x: i32, width: u32, height: u32, scale: f64) -> Monitor {
        Monitor { x, y: 0, width, height, scale, primary: x == 0, name: "Display".into() }
    }

    #[test]
    fn overlay_plan_maps_tags_to_their_monitors() {
        let screens = vec![screen(1, monitor(0, 3840, 2160, 1.5)), screen(2, monitor(3840, 1568, 882, 1.0))];
        let plan = overlay_plan("over there. [MARK:1:100,100:first] [MARK:box:0,0,784,441:top left|here:screen2] [MARK:circle:5,5:nowhere:screen9] [POINT:784,441:middle:screen2]", &screens);
        assert_eq!(plan["speech"], "over there.");
        assert_eq!(plan["point"]["screen"], 2);
        assert_eq!((plan["point"]["x"].as_i64(), plan["point"]["y"].as_i64()), (Some(3840 + 784), Some(441)));
        let marks = plan["marks"].as_array().unwrap();
        assert_eq!(marks.len(), 2, "a mark on a screen that isn't there is dropped");
        assert_eq!(marks[0]["style"], "1");
        assert_eq!(marks[0]["text"], "first");
        assert_eq!((marks[0]["x"].as_i64(), marks[0]["y"].as_i64()), (Some(245), Some(245)));
        assert_eq!(marks[1]["box"]["width"], 784);
        assert_eq!(marks[1]["text"], "here");
    }

    #[test]
    fn pictures_go_in_each_wire_format() {
        let screens = vec![screen(1, monitor(0, 1920, 1080, 1.0))];
        let anthropic = api_request_body(crate::brains::WireStyle::Anthropic, "m", "sys", "USER SAID: \"hi\"", &screens);
        let content = anthropic["messages"][0]["content"].as_array().unwrap();
        assert_eq!(content[0]["text"], "USER SAID: \"hi\"");
        assert!(content[1]["text"].as_str().unwrap().starts_with("SCREEN 1 "));
        assert_eq!(content[2]["type"], "image");
        assert_eq!(content[2]["source"]["media_type"], "image/jpeg");
        assert_eq!(anthropic["system"], "sys");
        let openai = api_request_body(crate::brains::WireStyle::OpenAI, "m", "sys", "hi", &screens);
        assert_eq!(openai["messages"][0]["role"], "system");
        assert!(openai["messages"][1]["content"][2]["image_url"]["url"].as_str().unwrap().starts_with("data:image/jpeg;base64,/9g"));
        let words_only = api_request_body(crate::brains::WireStyle::OpenAI, "m", "sys", "hi", &[]);
        assert_eq!(words_only["messages"][1]["content"], "hi");
        let line = claude_user_message("hi", &screens);
        let parsed: Value = serde_json::from_str(line.trim()).unwrap();
        assert_eq!(parsed["type"], "user");
        assert_eq!(parsed["message"]["content"][2]["type"], "image");
    }

    #[test]
    fn claude_runs_isolated_like_the_mac() {
        let arguments = claude_arguments("claude-sonnet-5-5", std::path::Path::new("p.md"), std::path::Path::new("s.json"));
        for expected in ["--input-format", "stream-json", "--include-partial-messages", "--strict-mcp-config", "--no-session-persistence", "--system-prompt-file"] {
            assert!(arguments.iter().any(|a| a == expected), "{expected}");
        }
        let tools = arguments.iter().position(|a| a == "--tools").unwrap();
        assert_eq!(arguments[tools + 1], "");
        assert!(!arguments.iter().any(|a| a == "--bare"));
    }

    #[test]
    fn a_picture_refusal_is_told_apart() {
        assert!(refused_for_pictures(400, r#"{"error":{"message":"This model does not support image input"}}"#));
        assert!(refused_for_pictures(400, r#"{"error":{"message":"messages[1].content must be a string"}}"#));
        assert!(!refused_for_pictures(401, "image"));
        assert!(!refused_for_pictures(400, "max_tokens too large"));
    }

    #[test]
    fn a_vision_model_is_picked_from_the_list() {
        let listed: Vec<String> = ["text-embedding-3-large", "gpt-4o-audio-preview", "gpt-4o-mini", "gpt-5"].iter().map(|s| s.to_string()).collect();
        assert_eq!(vision_model("openai", &listed).as_deref(), Some("gpt-5"));
        assert_eq!(vision_model("anthropic", &[]).as_deref(), Some("claude-sonnet-5-5"));
        let groq: Vec<String> = ["whisper-large-v3", "llama-3.3-70b", "meta-llama/llama-4-scout-17b"].iter().map(|s| s.to_string()).collect();
        assert_eq!(vision_model("groq", &groq).as_deref(), Some("meta-llama/llama-4-scout-17b"));
    }
}
