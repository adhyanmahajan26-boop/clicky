//! What a bot may do on its engine, written as Claude Code permission rules. Only the allowed tools run (`dontAsk`): reading and
//! the web, writing only in its own memory folder, reading the project folders and what the owner's own words named. No shell,
//! no scheduling, no sub-agents, nothing that sends. Secrets and Theo's own records can't be read. Same rules as the Swift app's
//! `BotRunner.claudeAllowedTools`, `irreversibleTools` and `secretReadRules`.

use crate::paths::{rule_path, Paths};
use std::path::{Path, PathBuf};

pub const IRREVERSIBLE: [&str; 8] = ["CronCreate", "CronDelete", "CronList", "ScheduleWakeup", "RemoteTrigger", "Skill", "Agent", "Task"];

pub fn allowed_tools(paths: &Paths, bot_id: &str, readable: &[PathBuf], recall: &[PathBuf]) -> Vec<String> {
    let memory = format!("{}/**", rule_path(&paths.memory_dir(bot_id)));
    let projects = format!("{}/**", rule_path(&paths.projects_dir()));
    let mut tools = vec!["WebSearch".to_string(), "WebFetch".to_string(), format!("Edit({memory})"), format!("Write({memory})")];
    for place in [&memory, &projects] {
        tools.push(format!("Read({place})"));
        tools.push(format!("Grep({place})"));
        tools.push(format!("Glob({place})"));
    }
    for path in readable {
        let rule = rule_path(path);
        let rule = if path.is_dir() { format!("{rule}/**") } else { rule };
        tools.push(format!("Read({rule})"));
        tools.push(format!("Grep({rule})"));
        tools.push(format!("Glob({rule})"));
    }
    for file in recall {
        let rule = rule_path(file);
        tools.push(format!("Read({rule})"));
        tools.push(format!("Grep({rule})"));
    }
    tools
}

/// Files no bot reads: sign-ins and keys, shell history, browser and mail stores, and Theo's own records. `recall`: the saved
/// chats this bot may search; every other chat file is denied one by one.
pub fn secret_read_rules(paths: &Paths, recall: &[PathBuf]) -> Vec<String> {
    let home = crate::paths::home();
    let mut denied: Vec<String> = [
        ".ssh/**", ".aws/**", ".gnupg/**", ".config/gh/**", ".config/gcloud/**", ".azure/**", ".kube/**", ".docker/config.json", ".netrc", ".npmrc",
        ".pypirc", ".git-credentials", ".zsh_history", ".bash_history", ".claude.json", ".claude/.credentials.json", ".codex/auth.json", ".grok/**",
        ".gemini/**", ".cursor/**", ".local/share/opencode/auth.json", ".local/share/keyrings/**", ".mozilla/**", ".config/google-chrome/**",
        "Library/Keychains/**", "Library/Cookies/**", "Library/Mail/**", "Library/Messages/**", "Library/Application Support/Google/Chrome/**",
        "AppData/Roaming/Microsoft/Credentials/**", "AppData/Local/Google/Chrome/User Data/**",
    ]
    .iter()
    .map(|p| format!("{}/{}", rule_path(&home), p))
    .collect();
    let bots = rule_path(&paths.bots_dir());
    let root = rule_path(&paths.root);
    let mine: Vec<PathBuf> = recall.iter().map(|p| p.to_path_buf()).collect();
    if mine.is_empty() {
        denied.push(format!("{bots}/chats/**"));
    } else if let Ok(dir) = std::fs::read_dir(paths.chats_dir()) {
        for entry in dir.flatten() {
            let path = entry.path();
            if !mine.iter().any(|m| m == &path) {
                denied.push(rule_path(&path));
            }
        }
    }
    denied.extend([format!("{bots}/*.json"), format!("{bots}/*.json.*"), format!("{bots}/*.lastgood"), format!("{root}/*.json"), format!("{root}/gateway-token"), format!("{root}/control-*/**"), "//**/.env".to_string(), "//**/.env.*".to_string()]);
    denied.into_iter().map(|p| format!("Read({p})")).collect()
}

/// Every other bot's memory folder: the engine's working folder holds them all, and a working folder is readable without a rule.
pub fn other_bots_folders(paths: &Paths, bot_id: &str) -> Vec<String> {
    let mut out = vec![];
    if let Ok(dir) = std::fs::read_dir(paths.memory_root()) {
        for entry in dir.flatten() {
            let name = entry.file_name().to_string_lossy().to_string();
            if name != bot_id && name != "skills" && entry.path().is_dir() {
                out.push(format!("Read({}/**)", rule_path(&entry.path())));
            }
        }
    }
    out
}

/// The whole argument list for a Claude Code bot turn.
pub fn claude_args(paths: &Paths, bot: &crate::model::Bot, model: &str, persona: &str, prompt: &str, session: Option<&str>, new_session: Option<&str>, readable: &[PathBuf], recall: &[PathBuf]) -> Vec<String> {
    let mut args: Vec<String> = ["-p", "--output-format", "stream-json", "--verbose", "--include-partial-messages", "--model", model, "--permission-mode", "dontAsk", "--append-system-prompt", persona]
        .iter()
        .map(|s| s.to_string())
        .collect();
    args.push("--allowedTools".into());
    args.extend(allowed_tools(paths, &bot.id, readable, recall));
    args.push("--disallowedTools".into());
    args.extend(IRREVERSIBLE.iter().map(|s| s.to_string()));
    args.extend(secret_read_rules(paths, recall));
    // Bash outright: Claude Code lets read-only commands run in the working folder without a rule.
    args.push("Bash".into());
    args.push("PowerShell".into());
    args.extend(other_bots_folders(paths, &bot.id));
    if let Some(effort) = bot.effort.as_deref().filter(|e| !e.is_empty()) {
        args.push("--effort".into());
        args.push(effort.into());
    }
    match (session, new_session) {
        (Some(s), _) => {
            args.push("--resume".into());
            args.push(s.into());
        }
        (None, Some(id)) => {
            args.push("--session-id".into());
            args.push(id.into());
        }
        _ => {}
    }
    args.push("--".into());
    args.push(prompt.into());
    args
}

/// Paths the owner's own words named this turn ("read ~/notes/plan.md"), which the bot may read too.
pub fn paths_in_words(words: &str) -> Vec<PathBuf> {
    let home = crate::paths::home();
    let mut out = vec![];
    for raw in words.split_whitespace() {
        let token = raw.trim_matches(|c: char| "\"'`()[]{}<>,;!?".contains(c)).trim_end_matches('.');
        let path = if let Some(rest) = token.strip_prefix("~/") {
            home.join(rest)
        } else if token.starts_with('/') || (token.len() > 2 && token.as_bytes()[1] == b':' && (token.as_bytes()[2] == b'\\' || token.as_bytes()[2] == b'/')) {
            PathBuf::from(token)
        } else {
            continue;
        };
        if path.exists() && !is_sensitive(&path) {
            out.push(path);
        }
    }
    out
}

fn is_sensitive(path: &Path) -> bool {
    let text = path.to_string_lossy();
    [".ssh", ".aws", ".gnupg", "Keychains", ".env", "credentials"].iter().any(|s| text.contains(s))
}
