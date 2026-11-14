//! The card under a bot's final prompt (the Mac's `RunChoices`): which coding agent, which folder, which chat, and Start. The
//! folder list is the projects folder's (`coding.projectsFolder`, the Mac's `v2.code.projectsFolder`), the folders earlier runs
//! used first; a new folder is made there with git and an empty first commit (`BotsT3.makeProject`). The chat list is the
//! agent's own chats in that folder (`harness_chats`). Two Macs and T3 Code have no part here.

use crate::coding::{self, Choice, CODING_AGENTS};
use crate::control::{err, ok};
use crate::harness::Harness;
use crate::protocol;
use serde_json::{json, Value};
use std::path::{Path, PathBuf};
use std::sync::Arc;

fn text(cmd: &Value, key: &str) -> Option<String> { cmd.get(key).and_then(|v| v.as_str()).map(str::to_string).filter(|s| !s.trim().is_empty()) }

/// A folder name the owner typed: one plain name, no way out of the projects folder.
pub fn clean_folder_name(name: &str) -> Option<String> {
    let name = name.trim();
    if name.is_empty() || name.chars().count() > 80 || name.chars().all(|c| c == '.') { return None; }
    if name.chars().any(|c| matches!(c, '/' | '\\' | ':' | '*' | '?' | '"' | '<' | '>' | '|') || c.is_control()) { return None; }
    // Windows won't make these, whatever the case or the extension.
    let stem = name.split('.').next().unwrap_or("").to_uppercase();
    if ["CON", "PRN", "AUX", "NUL", "COM1", "COM2", "COM3", "COM4", "LPT1", "LPT2", "LPT3"].contains(&stem.as_str()) { return None; }
    Some(name.trim_end_matches(['.', ' ']).to_string())
}

/// The folders the card offers: those earlier runs used (newest first, still there), then every other folder in the projects folder.
pub fn project_list(projects: &Path, used: &[String]) -> (Vec<Value>, Vec<Value>) {
    let mut recent: Vec<Value> = vec![];
    let mut seen = std::collections::HashSet::new();
    for folder in used {
        let path = Path::new(folder);
        // A run's own worktree isn't somewhere to start the next run.
        if folder.contains(".worktrees") || !path.is_dir() || !seen.insert(folder.clone()) { continue; }
        recent.push(json!({"name": path.file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_else(|| folder.clone()), "path": folder}));
    }
    let mut others: Vec<(String, String)> = std::fs::read_dir(projects).map(|d| d.flatten()
        .filter(|e| e.path().is_dir())
        .map(|e| (e.file_name().to_string_lossy().to_string(), e.path().to_string_lossy().to_string()))
        .filter(|(name, path)| !name.starts_with('.') && !seen.contains(path))
        .collect()).unwrap_or_default();
    others.sort_by_key(|(name, _)| name.to_lowercase());
    (recent, others.into_iter().map(|(name, path)| json!({"name": name, "path": path})).collect())
}

/// `runChoices`: the coding agents (installed, ready), the projects folder and its folders.
pub async fn choices(h: &Arc<Harness>) -> Value {
    let inventory = crate::brains::inventory(h).await;
    let agents: Vec<Value> = CODING_AGENTS.iter().map(|id| {
        let agent = inventory["agents"].as_array().and_then(|list| list.iter().find(|a| a["id"].as_str() == Some(id))).cloned().unwrap_or(Value::Null);
        json!({"id": id, "label": crate::brains::label(id), "installed": agent["installed"].as_bool().unwrap_or(false), "ready": agent["codingReady"].as_bool().or(agent["ready"].as_bool()).unwrap_or(false),
               "continues": crate::harness_chats::CONTINUABLE.contains(id)})
    }).collect();
    let projects = coding::projects_folder(h);
    let used: Vec<String> = h.with(|s| s.runs.iter().rev().map(|r| r.folder.clone()).collect());
    let (recent, others) = project_list(&projects, &used);
    ok(json!({"agents": agents, "coding": inventory["coding"].clone(), "projectsFolder": projects.to_string_lossy(), "projectsFolderIsDefault": h.settings.string(coding::PROJECTS_SETTING).is_none(),
              "recent": recent, "others": others}))
}

/// `runChats {harness, folder}`: that agent's chats in that folder, newest first.
pub async fn chats(h: &Arc<Harness>, cmd: &Value) -> Value {
    let (Some(agent), Some(folder)) = (text(cmd, "harness"), text(cmd, "folder")) else { return err("Needs harness and folder.") };
    if !Path::new(&folder).is_dir() { return ok(json!({"chats": [], "continues": false})); }
    let continues = crate::harness_chats::CONTINUABLE.contains(&agent.as_str());
    let opencode = if agent == "opencode" { h.executable("opencode") } else { None };
    // A test profile can point at a stand-in home holding the agents' chat stores; everyone else reads their own.
    let home = h.settings.string("test.home").filter(|_| h.settings.is_test).map(PathBuf::from).unwrap_or_else(crate::paths::home);
    let found = if continues { crate::harness_chats::list(&home, &agent, &folder, opencode).await } else { vec![] };
    ok(json!({"chats": found, "continues": continues}))
}

/// `projectMake {name}`: a new folder in the projects folder, with git and an empty first commit.
pub async fn make_project(h: &Arc<Harness>, cmd: &Value) -> Value {
    let Some(name) = text(cmd, "name").as_deref().and_then(clean_folder_name) else { return err("Use a plain folder name, like moon-site.") };
    let projects = coding::projects_folder(h);
    let folder = projects.join(&name);
    if folder.exists() { return err(&format!("You already have {name}. Pick it from the list, or use another name.")); }
    if let Err(e) = std::fs::create_dir_all(&folder) { return err(&format!("Couldn't make that folder: {e}")); }
    if coding::git(&folder, &["init", "-q"]).await.is_ok() {
        let _ = coding::git(&folder, &["-c", "user.name=Vello", "-c", "user.email=theo@localhost", "commit", "-q", "--allow-empty", "-m", "First commit"]).await;
    }
    ok(json!({"name": name, "path": folder.to_string_lossy()}))
}

/// `projectsFolderSet {path}`: where new projects go. Empty goes back to Theo's own Projects folder.
pub fn set_projects_folder(h: &Arc<Harness>, cmd: &Value) -> Value {
    match text(cmd, "path") {
        None => h.settings.set(coding::PROJECTS_SETTING, Value::Null),
        Some(path) => {
            let path = path.trim().to_string();
            let folder = PathBuf::from(&path);
            if !folder.is_absolute() { return err("Give the whole path, like C:\\Users\\you\\Projects."); }
            if folder.exists() && !folder.is_dir() { return err("That's a file, not a folder."); }
            // Made now, so the card can list it; nothing goes in it until a project does.
            if let Err(e) = std::fs::create_dir_all(&folder) { return err(&format!("Couldn't use that folder: {e}")); }
            h.settings.set(coding::PROJECTS_SETTING, path.into());
        }
    }
    ok(json!({"projectsFolder": coding::projects_folder(h).to_string_lossy()}))
}

/// `runChoiceStart {room, message, harness, folder, chat, chatTitle}`: Start on the card. The message is a bot's answer with a
/// ```prompt block, or the "Start this coding run?" card under it, which folds as answered.
pub async fn start(h: &Arc<Harness>, cmd: &Value) -> Value {
    let (Some(room), Some(message_id)) = (text(cmd, "room"), text(cmd, "message")) else { return err("Needs room and message.") };
    let conversation = h.conversation(&room);
    let Some(index) = conversation.messages.iter().position(|m| m.id == message_id) else { return err("That message isn't in this chat.") };
    let message = conversation.messages[index].clone();
    let card = message.card.as_deref().and_then(|c| c.strip_prefix("ask:")).and_then(|raw| serde_json::from_str::<Value>(raw).ok()).filter(|p| p["kind"] == "run");
    let (prompt, answer, digest) = match &card {
        Some(payload) => (payload["prompt"].as_str().unwrap_or_default().to_string(), payload["answer"].as_str().unwrap_or_default().to_string(), format!("card-{message_id}")),
        None => {
            if message.card.as_deref().map(|c| c.starts_with("answered:")).unwrap_or(false) { return err("That card was already answered."); }
            let Some(prompt) = protocol::fenced_block(&message.text, "prompt") else { return err("That message has no prompt to start.") };
            (prompt, message.text.clone(), format!("choice-{message_id}"))
        }
    };
    if prompt.trim().is_empty() { return err("That message has no prompt to start."); }
    // Started already: from this card, or by itself from the owner's words before it (the pitch).
    let pitch_message = conversation.messages[..index].iter().rev().find(|m| m.author == crate::model::OWNER_AUTHOR);
    let pitch = pitch_message.map(|m| m.id.clone());
    let owner_words = pitch_message.map(|m| m.text.clone()).unwrap_or_default();
    if let Some(existing) = h.with(|s| s.runs.iter().find(|r| r.prompt_digest.as_deref() == Some(digest.as_str()) || (card.is_none() && pitch.is_some() && r.prompt_digest == pitch)).map(|r| r.title.clone())) {
        return err(&format!("That prompt already started \"{existing}\"."));
    }
    let harness = text(cmd, "harness").filter(|h| h != "auto");
    if let Some(agent) = &harness {
        if !CODING_AGENTS.contains(&agent.as_str()) { return err("Vello doesn't know that coding agent."); }
        if h.executable(agent).is_none() { return err(&format!("{} isn't installed on this computer. Pick another agent, or install it in Settings › Brains.", crate::brains::label(agent))); }
    }
    let folder = text(cmd, "folder").map(PathBuf::from);
    if let Some(folder) = &folder {
        if !folder.is_absolute() || !folder.is_dir() { return err(&format!("There's no folder at {} on this computer.", folder.to_string_lossy())); }
    }
    let chat = text(cmd, "chat").map(|id| (id.clone(), text(cmd, "chatTitle").unwrap_or(id)));
    if chat.is_some() {
        let Some(agent) = &harness else { return err("Pick the agent whose chat it is.") };
        if !crate::harness_chats::CONTINUABLE.contains(&agent.as_str()) { return err(&format!("{} can't carry on a chat here; start a new one.", crate::brains::label(agent))); }
        if folder.is_none() { return err("Pick the folder the chat is in."); }
    }
    let title = protocol::labeled("Project", &answer).unwrap_or_else(|| prompt.split_whitespace().take(6).collect::<Vec<_>>().join(" "));
    let (repo, new_folder) = match &folder {
        Some(f) if chat.is_some() || f.join(".git").exists() => (Some(f.clone()), None),
        Some(f) => (None, Some(f.to_string_lossy().to_string())),
        // No pick: where the owner's words and the bot's answer said, as a run that starts by itself would go.
        None => match coding::named_repo(&owner_words) {
            Some(repo) => (Some(repo), None),
            None => (None, coding::new_folder_name(&owner_words, &answer)),
        },
    };
    let id = coding::start_with(h, prompt, title.clone(), repo, new_folder, room.clone(), Some(digest), Choice { harness, chat });
    // The "Start this coding run?" card folds to its answered line; the run already has its digest, so this starts nothing more.
    if card.is_some() {
        let _ = h.answer_card(&room, &message_id, "yes");
    }
    ok(json!({"started": title, "id": id}))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn folder_names_are_one_plain_name() {
        assert_eq!(clean_folder_name(" moon-site "), Some("moon-site".into()));
        assert_eq!(clean_folder_name("My App."), Some("My App".into()));
        for bad in ["", "..", ".", "a/b", "a\\b", "C:", "con", "NUL.txt", "x?"] { assert_eq!(clean_folder_name(bad), None, "{bad}"); }
    }

    #[test]
    fn used_folders_come_first_and_worktrees_never() {
        let projects = tempfile::tempdir().unwrap();
        for name in ["beta", "alpha", ".hidden", "gamma"] { std::fs::create_dir_all(projects.path().join(name)).unwrap(); }
        let gamma = projects.path().join("gamma").to_string_lossy().to_string();
        let worktree = projects.path().join(".worktrees").join("x").to_string_lossy().to_string();
        let (recent, others) = project_list(projects.path(), &[gamma.clone(), worktree, gamma.clone(), "/nowhere/at/all".into()]);
        assert_eq!(recent.len(), 1);
        assert_eq!(recent[0]["name"], "gamma");
        let names: Vec<&str> = others.iter().map(|o| o["name"].as_str().unwrap()).collect();
        assert_eq!(names, vec!["alpha", "beta"]);
    }
}
