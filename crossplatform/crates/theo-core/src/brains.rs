//! Every brain a bot can think with on Windows and Linux, and which of them work on this computer.
//!
//! Two kinds, the same as on the Mac:
//! - command-line agents signed in with the owner's own subscription: Claude Code, OpenCode, Codex, Cursor Agent, Gemini CLI
//!   and Grok (a bot's `provider` is the agent's id), and
//! - model APIs on a key the owner pasted (`provider` is `api:<provider id>`, `model` the provider's model id). Keys live in
//!   the Credential Manager, the Keychain or a file only this user can read (`secrets::read_api_key`).
//!
//! None of them is required. Setup offers "paste an API key" first because it is the quickest start, then lists the agents.
//! The install and sign-in commands come from each tool's own docs, as the Mac's `HarnessCatalog.setups` has them.

use crate::harness::Harness;
use serde_json::{json, Value};
use std::time::Duration;

/// A command-line agent Theo can run a bot on.
pub struct CommandLineBrain {
    pub id: &'static str,
    pub label: &'static str,
    /// Program names to look for, in order (Cursor's agent is `cursor-agent`, newer installs also call it `agent`).
    pub programs: &'static [&'static str],
    pub install_on_windows: &'static str,
    pub install_elsewhere: &'static str,
    /// The agent's own sign-in arguments. Empty: signing in is part of running it (Gemini CLI asks on first start).
    pub sign_in_arguments: &'static [&'static str],
    /// What the owner does in the terminal that opens.
    pub sign_in_hint: &'static str,
    /// The model a new bot on it starts with. Empty: the agent's own default (no `-m` is passed).
    pub default_model: &'static str,
}

pub const COMMAND_LINE_BRAINS: [CommandLineBrain; 6] = [
    CommandLineBrain {
        id: "claude",
        label: "Claude Code",
        programs: &["claude"],
        install_on_windows: "irm https://claude.ai/install.ps1 | iex",
        install_elsewhere: "curl -fsSL https://claude.ai/install.sh | bash",
        sign_in_arguments: &["auth", "login"],
        sign_in_hint: "Your browser opens to sign in with your Claude account.",
        default_model: "claude-sonnet-5-5",
    },
    CommandLineBrain {
        id: "codex",
        label: "Codex",
        programs: &["codex"],
        install_on_windows: "npm install -g @openai/codex",
        install_elsewhere: "curl -fsSL https://chatgpt.com/codex/install.sh | sh",
        sign_in_arguments: &["login"],
        sign_in_hint: "Your browser opens to sign in with ChatGPT.",
        default_model: "",
    },
    CommandLineBrain {
        id: "cursor",
        label: "Cursor Agent",
        programs: &["cursor-agent", "agent"],
        install_on_windows: "irm 'https://cursor.com/install?win32=true' | iex",
        install_elsewhere: "curl https://cursor.com/install -fsS | bash",
        sign_in_arguments: &["login"],
        sign_in_hint: "Your browser opens to sign in with Cursor.",
        default_model: "",
    },
    CommandLineBrain {
        id: "gemini",
        label: "Gemini CLI",
        programs: &["gemini"],
        install_on_windows: "npm install -g @google/gemini-cli",
        install_elsewhere: "npm install -g @google/gemini-cli",
        sign_in_arguments: &[],
        sign_in_hint: "Choose \u{201C}Sign in with Google\u{201D} in the terminal, or use a Gemini API key.",
        default_model: "",
    },
    CommandLineBrain {
        id: "grok",
        label: "Grok",
        programs: &["grok"],
        install_on_windows: "irm https://x.ai/cli/install.ps1 | iex",
        install_elsewhere: "curl -fsSL https://x.ai/cli/install.sh | bash",
        sign_in_arguments: &["login"],
        sign_in_hint: "Your browser opens to sign in with your xAI account.",
        default_model: "",
    },
    CommandLineBrain {
        id: "opencode",
        label: "OpenCode",
        programs: &["opencode"],
        install_on_windows: "npm install -g opencode-ai",
        install_elsewhere: "curl -fsSL https://opencode.ai/install | bash",
        sign_in_arguments: &["auth", "login"],
        sign_in_hint: "Pick a provider in the terminal. OpenCode's free models need no sign-in.",
        default_model: "opencode/deepseek-v4.1-flash-free",
    },
];

pub fn command_line_brain(id: &str) -> Option<&'static CommandLineBrain> {
    COMMAND_LINE_BRAINS.iter().find(|brain| brain.id == id)
}

/// The environment variables each agent reads a saved API key from, as (provider id, variable): the Mac's
/// `HarnessCatalog.setups` key variables and `openCodeKeys`. Cursor's key is its own (not a model API key), so it has none here.
pub fn agent_key_variables(agent_id: &str) -> &'static [(&'static str, &'static str)] {
    match agent_id {
        "claude" => &[("anthropic", "ANTHROPIC_API_KEY")],
        "codex" => &[("openai", "OPENAI_API_KEY"), ("openai", "CODEX_API_KEY")],
        "grok" => &[("xai", "XAI_API_KEY")],
        "gemini" => &[("gemini", "GEMINI_API_KEY")],
        "opencode" => &[
            ("anthropic", "ANTHROPIC_API_KEY"), ("openai", "OPENAI_API_KEY"), ("gemini", "GOOGLE_GENERATIVE_AI_API_KEY"), ("xai", "XAI_API_KEY"),
            ("groq", "GROQ_API_KEY"), ("openrouter", "OPENROUTER_API_KEY"), ("mistral", "MISTRAL_API_KEY"), ("deepseek", "DEEPSEEK_API_KEY"),
            ("together", "TOGETHER_AI_API_KEY"), ("fireworks", "FIREWORKS_API_KEY"), ("cerebras", "CEREBRAS_API_KEY"),
        ],
        _ => &[],
    }
}

/// The owner's saved keys an agent can use, as environment variables. Only for an agent that isn't signed in: a key handed
/// to a signed-in agent would move its work from the owner's subscription to paid API use.
pub fn agent_key_environment(harness: &Harness, agent_id: &str) -> Vec<(String, String)> {
    agent_key_variables(agent_id)
        .iter()
        .filter_map(|(provider, variable)| api_key(harness, provider).map(|key| (variable.to_string(), key)))
        .collect()
}

/// How a model API takes requests: Anthropic's Messages API, or the OpenAI-style chat endpoint everyone else offers.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum WireStyle {
    Anthropic,
    OpenAI,
}

/// A model API Theo can chat with on the owner's key.
#[derive(Clone, Debug)]
pub struct ApiProvider {
    pub id: String,
    pub label: String,
    /// Where requests go, without a trailing slash (`/messages` or `/chat/completions` is added).
    pub base_url: String,
    pub style: WireStyle,
    /// Runs on this computer and needs no key.
    pub keyless: bool,
    pub key_hint: &'static str,
    pub key_page: &'static str,
    /// The model a new bot on it starts with when the provider's list of models can't be read.
    pub preferred_model: &'static str,
}

struct KnownProvider {
    id: &'static str,
    label: &'static str,
    base_url: &'static str,
    style: WireStyle,
    keyless: bool,
    key_hint: &'static str,
    key_page: &'static str,
    preferred_model: &'static str,
}

/// The chat providers the Mac's `ProviderInfo.all` lists (same ids, so a key means the same thing on both).
const KNOWN_PROVIDERS: [KnownProvider; 13] = [
    KnownProvider { id: "anthropic", label: "Anthropic", base_url: "https://api.anthropic.com/v1", style: WireStyle::Anthropic, keyless: false, key_hint: "sk-ant-…", key_page: "https://console.anthropic.com/settings/keys", preferred_model: "claude-sonnet-5-5" },
    KnownProvider { id: "openai", label: "OpenAI", base_url: "https://api.openai.com/v1", style: WireStyle::OpenAI, keyless: false, key_hint: "sk-…", key_page: "https://platform.openai.com/api-keys", preferred_model: "" },
    KnownProvider { id: "gemini", label: "Google Gemini", base_url: "https://generativelanguage.googleapis.com/v1beta/openai", style: WireStyle::OpenAI, keyless: false, key_hint: "AIza…", key_page: "https://aistudio.google.com/apikey", preferred_model: "" },
    KnownProvider { id: "xai", label: "xAI", base_url: "https://api.x.ai/v1", style: WireStyle::OpenAI, keyless: false, key_hint: "xai-…", key_page: "https://console.x.ai", preferred_model: "" },
    KnownProvider { id: "openrouter", label: "OpenRouter", base_url: "https://openrouter.ai/api/v1", style: WireStyle::OpenAI, keyless: false, key_hint: "sk-or-…", key_page: "https://openrouter.ai/keys", preferred_model: "" },
    KnownProvider { id: "groq", label: "Groq", base_url: "https://api.groq.com/openai/v1", style: WireStyle::OpenAI, keyless: false, key_hint: "gsk_…", key_page: "https://console.groq.com/keys", preferred_model: "" },
    KnownProvider { id: "mistral", label: "Mistral", base_url: "https://api.mistral.ai/v1", style: WireStyle::OpenAI, keyless: false, key_hint: "Your Mistral key", key_page: "https://console.mistral.ai/api-keys", preferred_model: "" },
    KnownProvider { id: "deepseek", label: "DeepSeek", base_url: "https://api.deepseek.com", style: WireStyle::OpenAI, keyless: false, key_hint: "sk-…", key_page: "https://platform.deepseek.com/api_keys", preferred_model: "" },
    KnownProvider { id: "together", label: "Together", base_url: "https://api.together.ai/v1", style: WireStyle::OpenAI, keyless: false, key_hint: "Your Together key", key_page: "https://api.together.ai/settings/api-keys", preferred_model: "" },
    KnownProvider { id: "fireworks", label: "Fireworks", base_url: "https://api.fireworks.ai/inference/v1", style: WireStyle::OpenAI, keyless: false, key_hint: "fw_…", key_page: "https://fireworks.ai/account/api-keys", preferred_model: "" },
    KnownProvider { id: "cerebras", label: "Cerebras", base_url: "https://api.cerebras.ai/v1", style: WireStyle::OpenAI, keyless: false, key_hint: "csk-…", key_page: "https://cloud.cerebras.ai", preferred_model: "" },
    KnownProvider { id: "ollama", label: "Ollama", base_url: "http://localhost:11434/v1", style: WireStyle::OpenAI, keyless: true, key_hint: "", key_page: "https://ollama.com/download", preferred_model: "" },
    KnownProvider { id: "lmstudio", label: "LM Studio", base_url: "http://localhost:1234/v1", style: WireStyle::OpenAI, keyless: true, key_hint: "", key_page: "https://lmstudio.ai", preferred_model: "" },
];

/// Settings key: a provider's address when the owner (or a test) moved it, `brains.apiBaseURL.<provider>`.
fn base_url_setting(provider_id: &str) -> String {
    format!("brains.apiBaseURL.{provider_id}")
}

/// A provider by id, with the address the owner set for it if any.
pub fn api_provider(harness: &Harness, provider_id: &str) -> Option<ApiProvider> {
    let known = KNOWN_PROVIDERS.iter().find(|provider| provider.id == provider_id)?;
    let base_url = harness
        .settings
        .string(&base_url_setting(provider_id))
        // Plain http only to this computer (a local model server, or a test's stand-in): a key never crosses a network unencrypted.
        .filter(|address| address.starts_with("https://") || ["http://127.0.0.1:", "http://127.0.0.1/", "http://localhost:", "http://localhost/"].iter().any(|local| address.starts_with(local)))
        .unwrap_or_else(|| known.base_url.to_string());
    Some(ApiProvider {
        id: known.id.to_string(),
        label: known.label.to_string(),
        base_url: base_url.trim_end_matches('/').to_string(),
        style: known.style,
        keyless: known.keyless,
        key_hint: known.key_hint,
        key_page: known.key_page,
        preferred_model: known.preferred_model,
    })
}

pub fn api_provider_ids() -> Vec<&'static str> {
    KNOWN_PROVIDERS.iter().map(|provider| provider.id).collect()
}

/// The provider id in a bot's `api:<provider>` engine.
pub fn api_provider_id(bot_provider: &str) -> Option<&str> {
    bot_provider.strip_prefix("api:").filter(|id| !id.is_empty())
}

/// What a bot's engine is called in the chat and in errors.
pub fn label(bot_provider: &str) -> String {
    if let Some(brain) = command_line_brain(bot_provider) {
        return brain.label.to_string();
    }
    if let Some(id) = api_provider_id(bot_provider) {
        let name = KNOWN_PROVIDERS.iter().find(|provider| provider.id == id).map(|provider| provider.label).unwrap_or(id);
        return format!("{name} (API key)");
    }
    bot_provider.to_string()
}

/// Whether a bot can be put on this engine at all (a known agent or a known API provider).
pub fn is_known_engine(bot_provider: &str) -> bool {
    command_line_brain(bot_provider).is_some() || api_provider_id(bot_provider).map(|id| KNOWN_PROVIDERS.iter().any(|provider| provider.id == id)).unwrap_or(false)
}

/// The key a provider's requests carry, if the owner saved one.
pub fn api_key(harness: &Harness, provider_id: &str) -> Option<String> {
    crate::secrets::read_api_key(&harness.paths.root, harness.settings.is_test, provider_id)
}

/// Can this computer think with `bot_provider` right now, without asking the program anything slow: an agent that is
/// installed, or an API provider with a key (or one that needs none). Sign-in is checked by `inventory`.
pub fn usable_without_asking(harness: &Harness, bot_provider: &str) -> bool {
    if command_line_brain(bot_provider).is_some() {
        return harness.executable(bot_provider).is_some();
    }
    match api_provider_id(bot_provider).and_then(|id| api_provider(harness, id)) {
        Some(provider) => provider.keyless || api_key(harness, &provider.id).is_some(),
        None => false,
    }
}

// MARK: Is each agent signed in

async fn output_of(program: &std::path::Path, arguments: &[&str], seconds: u64) -> Option<(i32, String)> {
    let (code, stdout, stderr) = crate::engine::run_briefly(program, arguments, &crate::paths::home(), Duration::from_secs(seconds)).await?;
    Some((code, stdout + &stderr))
}

/// Whether an installed agent is signed in: `Some(true)`, `Some(false)`, or `None` when its own check said nothing clear (a
/// check that timed out says nothing: the next one settles it). Never passes on an account's email or ids.
pub async fn signed_in(harness: &Harness, brain_id: &str, program: &std::path::Path) -> Option<bool> {
    let home = crate::paths::home();
    match brain_id {
        "claude" => {
            let (_, text) = output_of(program, &["auth", "status"], 30).await?;
            let start = text.find('{')?;
            let end = text.rfind('}').map(|end| end + 1).unwrap_or(text.len());
            serde_json::from_str::<Value>(&text[start..end]).ok().and_then(|parsed| parsed["loggedIn"].as_bool())
        }
        "codex" => {
            let (_, text) = output_of(program, &["login", "status"], 15).await?;
            let lower = text.to_lowercase();
            if lower.trim().is_empty() {
                return None;
            }
            Some(lower.contains("logged in") && !lower.contains("not logged in"))
        }
        "cursor" => {
            let (_, text) = output_of(program, &["status"], 20).await?;
            let lower = text.to_lowercase();
            if lower.trim().is_empty() {
                return None;
            }
            Some(lower.contains("logged in") && !lower.contains("not logged in") && !lower.contains("authentication required"))
        }
        "grok" => {
            // `grok models` prints "You are logged in with grok.com." before the list.
            let (_, text) = output_of(program, &["models"], 15).await?;
            let lower = text.to_lowercase();
            if lower.contains("not authenticated") || lower.contains("not logged in") {
                Some(false)
            } else if lower.contains("logged in") {
                Some(true)
            } else {
                None
            }
        }
        "gemini" => {
            let has_google_sign_in = home.join(".gemini").join("oauth_creds.json").is_file();
            let has_key = std::env::var_os("GEMINI_API_KEY").is_some();
            let settings_say = std::fs::read_to_string(home.join(".gemini").join("settings.json")).ok().map(|text| text.contains("selectedType")).unwrap_or(false);
            let _ = harness;
            Some(has_google_sign_in || has_key || settings_say)
        }
        // OpenCode's free models need no sign-in.
        "opencode" => Some(true),
        _ => None,
    }
}

/// Every brain and whether it works here, for Setup and Settings. Agents are checked at the same time, so the slowest one
/// sets how long this takes.
pub async fn inventory(harness: &Harness) -> Value {
    let brains = &COMMAND_LINE_BRAINS;
    // All six at once (each check is a short program run), so the slowest one sets how long this takes.
    let (first, second, third, fourth, fifth, sixth) = tokio::join!(
        agent_state(harness, &brains[0]),
        agent_state(harness, &brains[1]),
        agent_state(harness, &brains[2]),
        agent_state(harness, &brains[3]),
        agent_state(harness, &brains[4]),
        agent_state(harness, &brains[5]),
    );
    let agents = vec![first, second, third, fourth, fifth, sixth];
    let keys: Vec<Value> = KNOWN_PROVIDERS
        .iter()
        .filter_map(|known| api_provider(harness, known.id))
        .map(|provider| {
            let has_key = provider.keyless || api_key(harness, &provider.id).is_some();
            json!({"id": provider.id, "engine": format!("api:{}", provider.id), "label": provider.label, "kind": "api", "hasKey": has_key, "keyless": provider.keyless,
                   "ready": has_key && !provider.keyless, "keyHint": provider.key_hint, "keyPage": provider.key_page, "preferredModel": provider.preferred_model})
        })
        .collect();
    let any_ready = agents.iter().chain(keys.iter()).any(|brain| brain["ready"].as_bool() == Some(true));
    let coding = crate::coding::describe(harness, &agents);
    json!({"agents": agents, "apis": keys, "anyReady": any_ready, "standIn": harness.settings.string(STAND_IN_SETTING), "coding": coding})
}

async fn agent_state(harness: &Harness, brain: &CommandLineBrain) -> Value {
    let found = harness.executable(brain.id);
    let signed_in = match &found {
        Some(program) => signed_in(harness, brain.id, program).await,
        None => Some(false),
    };
    let install = if cfg!(windows) { brain.install_on_windows } else { brain.install_elsewhere };
    let ready = found.is_some() && signed_in != Some(false);
    // Signed out but with a saved key it reads: it can still do coding runs, on that key.
    let runs_on_key = found.is_some() && !ready && !agent_key_environment(harness, brain.id).is_empty();
    json!({
        "id": brain.id, "label": brain.label, "kind": "agent", "installed": found.is_some(), "signedIn": signed_in, "ready": ready,
        "codingReady": ready || runs_on_key, "runsOnKey": runs_on_key,
        "install": install, "signIn": sign_in_line(brain), "signInHint": brain.sign_in_hint, "defaultModel": brain.default_model,
    })
}

fn sign_in_line(brain: &CommandLineBrain) -> String {
    if brain.sign_in_arguments.is_empty() {
        return brain.programs[0].to_string();
    }
    format!("{} {}", brain.programs[0], brain.sign_in_arguments.join(" "))
}

/// The brain a new user's first bot (and an untouched Theo) starts on: a signed-in agent first (Claude Code on Sonnet
/// before the others, as on the Mac), then an API key on its preferred model. None when nothing here can think.
pub async fn starting_brain(harness: &Harness, inventory: &Value) -> Option<(String, String)> {
    for agent in inventory["agents"].as_array().into_iter().flatten() {
        if agent["ready"].as_bool() == Some(true) && agent["signedIn"].as_bool() == Some(true) {
            let id = agent["id"].as_str()?.to_string();
            let model = agent["defaultModel"].as_str().unwrap_or("").to_string();
            return Some((id, model));
        }
    }
    for api in inventory["apis"].as_array().into_iter().flatten() {
        if api["ready"].as_bool() == Some(true) {
            let id = api["id"].as_str()?.to_string();
            let model = model_for_new_bot(harness, &id).await.unwrap_or_default();
            if !model.is_empty() {
                return Some((format!("api:{id}"), model));
            }
        }
    }
    None
}

// MARK: Models on a key

/// Ids in a provider's list that aren't for chatting.
fn is_chat_model(model: &str) -> bool {
    let lower = model.to_lowercase();
    !["embed", "whisper", "tts", "dall-e", "image", "moderation", "audio", "transcribe", "rerank", "search", "realtime", "speech", "guard"].iter().any(|word| lower.contains(word))
}

/// The model a new bot on `provider_id` starts with: Anthropic's Sonnet when it is offered, else the first chat model in
/// the provider's list (the Mac's `APIModelDefaults.preferredChatModel`).
pub fn preferred_model(provider_id: &str, models: &[String]) -> Option<String> {
    if let Some(known) = KNOWN_PROVIDERS.iter().find(|provider| provider.id == provider_id) {
        if !known.preferred_model.is_empty() && (models.is_empty() || models.iter().any(|model| model == known.preferred_model)) {
            return Some(known.preferred_model.to_string());
        }
    }
    models.iter().find(|model| is_chat_model(model)).cloned()
}

pub async fn model_for_new_bot(harness: &Harness, provider_id: &str) -> Option<String> {
    let models = list_models(harness, provider_id).await.unwrap_or_default();
    preferred_model(provider_id, &models)
}

/// The provider's model ids (`GET <base>/models`), which also proves the key works. Err is a sentence for the owner,
/// never containing the key.
pub async fn list_models(harness: &Harness, provider_id: &str) -> Result<Vec<String>, String> {
    let provider = api_provider(harness, provider_id).ok_or("Theo doesn't know that provider.")?;
    let key = api_key(harness, provider_id);
    if key.is_none() && !provider.keyless {
        return Err(format!("{} needs an API key.", provider.label));
    }
    let address = format!("{}/models", provider.base_url);
    let label = provider.label.clone();
    let style = provider.style;
    tokio::task::spawn_blocking(move || {
        let mut request = crate::apichat::http_agent(&address).get(&address).timeout(Duration::from_secs(20));
        request = crate::apichat::authorize(request, style, key.as_deref());
        match request.call() {
            Ok(response) => {
                let body: Value = response.into_string().ok().and_then(|text| serde_json::from_str(&text).ok()).ok_or_else(|| format!("{label} answered, but not with a list of models."))?;
                let listed = body["data"].as_array().or_else(|| body["models"].as_array()).cloned().unwrap_or_default();
                Ok(listed.iter().filter_map(|model| model["id"].as_str().or_else(|| model["name"].as_str()).map(|id| id.trim_start_matches("models/").to_string())).collect())
            }
            Err(ureq::Error::Status(status, response)) => {
                let body = response.into_string().unwrap_or_default();
                Err(format!("{label} refused the key ({status}): {}", crate::apichat::error_message_in(&body).unwrap_or_else(|| "no reason given".into())))
            }
            Err(error) => Err(format!("Couldn't reach {label}: {}", crate::apichat::transport_problem(&error))),
        }
    })
    .await
    .map_err(|_| "The check stopped.".to_string())?
}

// MARK: The stand-in

/// Settings key: the brain that answers for a bot whose own engine keeps failing, as `<engine>|<model>` (the Mac's
/// `v3.bots.standInBrain`). Unset: Claude Code, but only when it is installed here.
pub const STAND_IN_SETTING: &str = "v3.bots.standInBrain";

/// The owner's stand-in as (engine, model), when it is set and not the engine that is failing.
pub fn chosen_stand_in(harness: &Harness, failing_engine: &str) -> Option<(String, String)> {
    let setting = harness.settings.string(STAND_IN_SETTING)?;
    let (engine, model) = setting.split_once('|').unwrap_or((setting.as_str(), ""));
    let engine = engine.trim();
    if engine.is_empty() || engine == failing_engine || !is_known_engine(engine) {
        return None;
    }
    Some((engine.to_string(), model.trim().to_string()))
}

/// The words for an agent whose plan ran out, with when it comes back if the agent said so. A port of the Mac's
/// `HarnessBotEngines.usageLimitMessage`: only Codex and Cursor print these in a way that can be read.
pub fn usage_limit_message(engine: &str, output: &str) -> Option<String> {
    use once_cell::sync::Lazy;
    use regex::Regex;
    static CODEX_LIMIT: Lazy<Regex> = Lazy::new(|| Regex::new(r"(?i)(hit|reached) your usage limit|usage limit (reached|exceeded)|quota exceeded").unwrap());
    static CURSOR_LIMIT: Lazy<Regex> = Lazy::new(|| Regex::new(r"(?i)out of usage|increase your limit").unwrap());
    static RESET_PHRASE: Lazy<Regex> = Lazy::new(|| Regex::new(r#"(?i)(try again|resets?|available again)[^.\n"]*"#).unwrap());
    let (limit_pattern, plan_name) = match engine {
        "codex" => (&*CODEX_LIMIT, "Codex's ChatGPT"),
        "cursor" => (&*CURSOR_LIMIT, "Cursor's"),
        _ => return None,
    };
    if !limit_pattern.is_match(output) {
        return None;
    }
    let when_it_resets = match RESET_PHRASE.find(output) {
        Some(found) => {
            let phrase = found.as_str().trim();
            let mut characters = phrase.chars();
            let first_letter = characters.next().map(|letter| letter.to_lowercase().collect::<String>()).unwrap_or_default();
            format!("; {}{}", first_letter, characters.as_str())
        }
        None => "; it resets later".to_string(),
    };
    Some(format!("{plan_name} usage limit is reached{when_it_resets}."))
}

/// The words for an agent that answered "you're not signed in", in Theo's own words with where to fix it. The patterns are
/// what each tool prints (Gemini CLI asks for an auth method, Grok says to run `grok login`, Codex "Not logged in", Cursor
/// "Authentication required").
pub fn sign_in_problem(engine: &str, output: &str) -> Option<String> {
    use once_cell::sync::Lazy;
    use regex::Regex;
    static GEMINI_SIGNED_OUT: Lazy<Regex> = Lazy::new(|| Regex::new(r"(?i)please set an auth method|auth(entication)? method|gemini_api_key|login required|not authenticated").unwrap());
    static GROK_SIGNED_OUT: Lazy<Regex> = Lazy::new(|| Regex::new(r"(?i)grok login|not (logged|signed) in|unauthori[sz]ed").unwrap());
    static CODEX_SIGNED_OUT: Lazy<Regex> = Lazy::new(|| Regex::new(r"(?i)not logged in|codex login|401 unauthorized").unwrap());
    static CURSOR_SIGNED_OUT: Lazy<Regex> = Lazy::new(|| Regex::new(r"(?i)authentication required|not authenticated|cursor-agent login|agent login").unwrap());
    let signed_out_pattern = match engine {
        "gemini" => &*GEMINI_SIGNED_OUT,
        "grok" => &*GROK_SIGNED_OUT,
        "codex" => &*CODEX_SIGNED_OUT,
        "cursor" => &*CURSOR_SIGNED_OUT,
        _ => return None,
    };
    if !signed_out_pattern.is_match(output) {
        return None;
    }
    Some(format!("{} isn't signed in on this computer. Sign in from Settings › Brains.", label(engine)))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_agent_has_an_install_and_a_label() {
        for brain in COMMAND_LINE_BRAINS.iter() {
            assert!(!brain.install_on_windows.is_empty() && !brain.install_elsewhere.is_empty(), "{}", brain.id);
            assert!(is_known_engine(brain.id));
        }
        assert_eq!(label("codex"), "Codex");
        assert_eq!(label("api:openai"), "OpenAI (API key)");
        assert!(is_known_engine("api:anthropic"));
        assert!(!is_known_engine("api:nobody"));
        assert!(!is_known_engine("api:"));
    }

    #[test]
    fn a_new_bot_on_a_key_starts_on_a_chat_model() {
        let listed = vec!["text-embedding-3".to_string(), "whisper-1".to_string(), "gpt-6-mini".to_string()];
        assert_eq!(preferred_model("openai", &listed).as_deref(), Some("gpt-6-mini"));
        assert_eq!(preferred_model("anthropic", &[]).as_deref(), Some("claude-sonnet-5-5"));
        assert_eq!(preferred_model("anthropic", &["claude-haiku-5-5".to_string()]).as_deref(), Some("claude-haiku-5-5"));
        assert_eq!(preferred_model("groq", &[]), None);
    }

    #[test]
    fn a_used_up_plan_and_a_signed_out_agent_are_said_plainly() {
        assert_eq!(
            usage_limit_message("codex", "ERROR: You've hit your usage limit. Try again in 3 hours."),
            Some("Codex's ChatGPT usage limit is reached; try again in 3 hours.".to_string())
        );
        assert_eq!(usage_limit_message("cursor", "You're out of usage"), Some("Cursor's usage limit is reached; it resets later.".to_string()));
        assert_eq!(usage_limit_message("claude", "usage limit reached"), None);
        assert!(sign_in_problem("gemini", "Please set an Auth method in your settings.json").unwrap().contains("Gemini"));
        assert!(sign_in_problem("grok", "Run `grok login` first").is_some());
        assert_eq!(sign_in_problem("codex", "all good"), None);
    }
}
