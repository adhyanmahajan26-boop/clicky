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
        // Windows' own places for the same things.
        "AppData/Local/Microsoft/Credentials/**", "AppData/Local/Microsoft/Vault/**", "AppData/Roaming/Microsoft/Protect/**",
        "AppData/Roaming/Microsoft/Windows/PowerShell/PSReadLine/**", "AppData/Roaming/GitHub CLI/**", "AppData/Roaming/gcloud/**",
        "AppData/Local/Microsoft/Edge/User Data/**", "AppData/Roaming/Mozilla/**", "AppData/Local/BraveSoftware/**",
        "AppData/Roaming/Opera Software/**", "AppData/Roaming/Thunderbird/**",
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
    denied.extend([format!("{bots}/*.json"), format!("{bots}/*.json.*"), format!("{bots}/*.lastgood"), format!("{root}/*.json"), format!("{root}/gateway-token"), format!("{root}/control-*/**"), format!("{root}/Turns/**"),
        // The connector hub's sign-ins, its vault key (in a file on Linux) and the turns' tickets.
        format!("{root}/Connectors/**"),
        // API keys kept in a file (Linux and test profiles), API bots' chat history, and a test profile's Grok config.
        format!("{root}/Keys/**"), format!("{root}/APISessions/**"), format!("{root}/test-grok-config.toml"), "//**/.env".to_string(), "//**/.env.*".to_string()]);
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

/// The whole argument list for a Claude Code bot turn, and the permission rules that go with it. The bot's system prompt is read
/// from `persona_file`, the owner's message goes in on standard input, and the rules go in a settings file (`settings_file`,
/// written by the caller from what this returns): each can be long (one rule per saved chat), and Windows caps a whole command
/// line at 32,767 characters. Rules from `--settings` are the same allow and deny rules as `--allowedTools` and
/// `--disallowedTools`; a deny still wins over any allow.
///
/// `apps` is what the connector hub wired for this turn (`hub::wire_turn`): the rules for the bot's apps, and the hub's MCP
/// server for this turn only (`--mcp-config`). The owner's own Claude Code servers stay loaded, which is how a claude.ai app
/// is reached directly, but only the tools allowed here run.
#[allow(clippy::too_many_arguments)]
pub fn claude_turn(paths: &Paths, bot: &crate::model::Bot, model: &str, persona_file: &Path, settings_file: &Path, session: Option<&str>, new_session: Option<&str>, readable: &[PathBuf], recall: &[PathBuf], apps: &crate::hub::TurnApps) -> (Vec<String>, serde_json::Value) {
    let persona_file = persona_file.to_string_lossy().to_string();
    let settings_path = settings_file.to_string_lossy().to_string();
    let mut args: Vec<String> = ["-p", "--output-format", "stream-json", "--verbose", "--include-partial-messages", "--model", model, "--permission-mode", "dontAsk", "--append-system-prompt-file", &persona_file, "--settings", &settings_path]
        .iter()
        .map(|s| s.to_string())
        .collect();
    let mut allow = allowed_tools(paths, &bot.id, readable, recall);
    for rule in &apps.allow {
        if !allow.contains(rule) {
            allow.push(rule.clone());
        }
    }
    if let Some(config) = &apps.claude_mcp_config {
        args.push("--mcp-config".into());
        args.push(config.to_string_lossy().to_string());
    }
    let mut deny: Vec<String> = IRREVERSIBLE.iter().map(|s| s.to_string()).collect();
    deny.extend(secret_read_rules(paths, recall));
    // Bash outright: Claude Code lets read-only commands run in the working folder without a rule.
    deny.push("Bash".into());
    deny.push("PowerShell".into());
    deny.extend(other_bots_folders(paths, &bot.id));
    deny.extend(apps.deny.iter().cloned());
    let settings = serde_json::json!({"permissions": {"allow": allow, "deny": deny}});
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
    (args, settings)
}

/// Paths the owner's own words named this turn ("read ~/notes/plan.md"), which the bot may read too. Too-broad ones (the whole
/// disk, the whole home, a system folder) and any with `..` are left out, as in the Swift `BotReadScope.isNarrowEnough`: a stray
/// "/" or "~/" in a message must not open the whole disk to a bot that can also send requests anywhere.
pub fn paths_in_words(words: &str) -> Vec<PathBuf> {
    paths_in_words_with_home(words, &crate::paths::home())
}

fn paths_in_words_with_home(words: &str, home: &Path) -> Vec<PathBuf> {
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
        if is_narrow_enough(&path, home) && path.exists() && !is_sensitive(&path) && !out.contains(&path) {
            out.push(path);
        }
    }
    out
}

/// Folders at the top of a disk that are the system's own, on macOS, Linux and Windows (compared without case).
const SYSTEM_FOLDERS: [&str; 20] = [
    "system", "library", "private", "etc", "var", "usr", "bin", "sbin", "dev", "cores", "proc", "sys", "boot", "root", "lib", "lib64",
    "run", "windows", "program files", "programdata",
];

/// The whole disk, the whole home, a top-level system folder or anything with `..` would open far more than the owner meant.
fn is_narrow_enough(path: &Path, home: &Path) -> bool {
    use std::path::Component;
    if path.components().any(|c| matches!(c, Component::ParentDir)) {
        return false;
    }
    // Windows also splits on '/', but a path typed with '/' on Linux must still be read with '/'.
    let names: Vec<String> = path
        .components()
        .filter_map(|c| match c { Component::Normal(name) => Some(name.to_string_lossy().to_string()), _ => None })
        .collect();
    if names.len() < 2 {
        return false;
    }
    // Compared part by part, and on Windows without case ("c:/users/me" is the home "C:\\Users\\Me").
    let parts = |p: &Path| -> Vec<String> {
        p.components()
            .map(|c| c.as_os_str().to_string_lossy().replace('\\', "/"))
            .map(|c| if cfg!(windows) { c.to_lowercase() } else { c })
            .collect()
    };
    let (path_parts, home_parts) = (parts(path), parts(home));
    if path_parts.starts_with(&home_parts) {
        return path_parts.len() > home_parts.len();
    }
    let top = names[0].to_lowercase();
    !SYSTEM_FOLDERS.contains(&top.as_str()) && !top.starts_with("program files")
}

fn is_sensitive(path: &Path) -> bool {
    // Without case: Windows and the Mac's disks don't care about it either (".SSH" is ".ssh").
    let text = path.to_string_lossy().to_lowercase();
    [".ssh", ".aws", ".gnupg", "keychains", ".env", "credentials", "protect", "psreadline", "user data"].iter().any(|s| text.contains(s))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn broad_paths_in_words_are_left_out() {
        let dir = tempfile::tempdir().unwrap();
        let home = dir.path().join("home").join("me");
        std::fs::create_dir_all(home.join("notes")).unwrap();
        std::fs::write(home.join("notes").join("plan.md"), "x").unwrap();
        let plan = home.join("notes").join("plan.md");
        // A stray slash, the home itself, and climbing out are never taken.
        assert!(paths_in_words_with_home("yes / no, and ~/ and ~", &home).is_empty());
        assert!(paths_in_words_with_home(&format!("read {}", home.display()), &home).is_empty());
        assert!(paths_in_words_with_home("look at ~/notes/../../..", &home).is_empty());
        assert!(paths_in_words_with_home("check /etc/hosts and /usr/bin", &home).is_empty());
        // A real file the owner named is.
        assert_eq!(paths_in_words_with_home("read ~/notes/plan.md.", &home), vec![plan.clone()]);
        assert_eq!(paths_in_words_with_home(&format!("read `{}`", plan.display()), &home), vec![plan]);
    }

    #[test]
    fn narrow_enough_matches_the_swift_rule() {
        let home = Path::new("/home/me");
        assert!(!is_narrow_enough(Path::new("/"), home));
        assert!(!is_narrow_enough(Path::new("/home"), home));
        assert!(!is_narrow_enough(Path::new("/home/me"), home));
        assert!(is_narrow_enough(Path::new("/home/me/x"), home));
        assert!(!is_narrow_enough(Path::new("/etc/ssh"), home));
        assert!(is_narrow_enough(Path::new("/opt/thing"), home));
        assert!(!is_narrow_enough(Path::new("/opt"), home));
        assert!(!is_narrow_enough(Path::new("/home/me/a/../../.."), home));
    }

    #[cfg(windows)]
    #[test]
    fn narrow_enough_on_windows() {
        let home = Path::new("C:\\Users\\Me");
        assert!(!is_narrow_enough(Path::new("C:\\"), home));
        assert!(!is_narrow_enough(Path::new("c:/users/me"), home));
        assert!(is_narrow_enough(Path::new("c:/users/me/notes"), home));
        assert!(!is_narrow_enough(Path::new("C:\\Windows\\System32"), home));
        assert!(!is_narrow_enough(Path::new("C:\\Program Files (x86)\\Thing"), home));
        assert!(is_narrow_enough(Path::new("D:\\Work\\proj"), home));
    }
}
