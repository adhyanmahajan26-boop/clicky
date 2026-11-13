//! Coding runs: a coding agent (Claude Code with full access, in its own folder) does the work the owner asked for. An existing
//! git repo gets its own branch and worktree, so two runs never touch each other's files; the result is committed, pushed and
//! opened as a draft pull request when the repo has a remote and `gh` is signed in. Only the owner's own words start one.

use crate::engine::{self, Cancel, Format, Spec};
use crate::harness::Harness;
use crate::model::{ChatMessage, CodingRun};
use crate::protocol;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;

fn slug(text: &str) -> String {
    let s: String = text.to_lowercase().chars().map(|c| if c.is_ascii_alphanumeric() { c } else { '-' }).collect();
    let s = s.split('-').filter(|p| !p.is_empty()).collect::<Vec<_>>().join("-");
    let s: String = s.chars().take(40).collect();
    if s.is_empty() { "project".into() } else { s.trim_end_matches('-').to_string() }
}

/// "a new folder called liar-1", "New folder: x".
fn new_folder_name(owner_words: &str, answer: &str) -> Option<String> {
    let re = regex::Regex::new(r#"(?i)\bnew folder (?:called|named)\s+[`"']?([A-Za-z0-9._-]+)"#).unwrap();
    if let Some(c) = re.captures(owner_words) {
        let name = c[1].trim_end_matches('.').to_string();
        // "." or ".." would put a full-access coding agent in the projects folder itself or in Theo's own data folder.
        if !name.is_empty() && !name.chars().all(|ch| ch == '.') {
            return Some(name);
        }
    }
    protocol::labeled("New folder", answer).map(|n| slug(&n))
}

/// An existing folder the owner's own words named.
fn named_repo(owner_words: &str) -> Option<PathBuf> {
    crate::policy::paths_in_words(owner_words).into_iter().find(|p| p.is_dir())
}

async fn git(dir: &Path, args: &[&str]) -> Result<String, String> {
    let git = engine::locate("git").unwrap_or_else(|| PathBuf::from("git"));
    let mut cmd = engine::background_command(&git);
    // Never wait on a password prompt nobody can see: a push without credentials fails instead of hanging the run.
    cmd.args(args).current_dir(dir).env("GIT_TERMINAL_PROMPT", "0").env("GCM_INTERACTIVE", "never").stdin(std::process::Stdio::null()).kill_on_drop(true);
    let out = match tokio::time::timeout(std::time::Duration::from_secs(600), cmd.output()).await {
        Ok(result) => result.map_err(|e| e.to_string())?,
        Err(_) => return Err(format!("git {} took more than 10 minutes and was stopped.", args.first().unwrap_or(&""))),
    };
    if out.status.success() { Ok(String::from_utf8_lossy(&out.stdout).trim().to_string()) } else { Err(String::from_utf8_lossy(&out.stderr).trim().to_string()) }
}

pub fn start_from_answer(h: &Arc<Harness>, prompt: &str, answer: &str, owner_words: &str, room: &str, pitch_id: &str) -> String {
    let title = protocol::labeled("Project", answer).unwrap_or_else(|| prompt.split_whitespace().take(6).collect::<Vec<_>>().join(" "));
    let repo = named_repo(owner_words);
    let new_folder = if repo.is_none() { Some(new_folder_name(owner_words, answer).unwrap_or_else(|| slug(&title))) } else { None };
    start(h, prompt.to_string(), title.clone(), repo, new_folder, room.to_string(), Some(pitch_id.to_string()));
    title
}

pub fn start(h: &Arc<Harness>, prompt: String, title: String, repo: Option<PathBuf>, new_folder: Option<String>, room: String, digest: Option<String>) -> String {
    // The same pitch never starts twice, even after a restart.
    if let Some(d) = &digest {
        if let Some(existing) = h.with(|s| s.runs.iter().find(|r| r.prompt_digest.as_deref() == Some(d)).map(|r| r.id.clone())) {
            return existing;
        }
    }
    let id = uuid::Uuid::new_v4().to_string().to_uppercase();
    let short = id[..6].to_lowercase();
    let folder = match (&repo, &new_folder) {
        (Some(_), _) => h.paths.projects_dir().join(".worktrees").join(format!("{}-{}", slug(&title), short)).to_string_lossy().to_string(),
        (None, Some(name)) if Path::new(name).is_absolute() => name.clone(),
        (None, Some(name)) => h.paths.projects_dir().join(name).to_string_lossy().to_string(),
        _ => h.paths.projects_dir().join(slug(&title)).to_string_lossy().to_string(),
    };
    let run = CodingRun {
        id: id.clone(),
        title: title.clone(),
        phase: "running".into(),
        folder: folder.clone(),
        room: room.clone(),
        branch: repo.as_ref().map(|_| format!("theo/{}-{}", slug(&title), short)),
        pull_request: None,
        session_id: None,
        harness: Some("claude".into()),
        prompt_digest: digest,
        started_at: chrono::Utc::now(),
        summary: None,
    };
    h.with(|s| s.runs.push(run.clone()));
    h.write_runs();
    let mut card = ChatMessage::note(format!("Theo started the coding run \"{title}\" in {folder}."));
    card.run_id = Some(id.clone());
    h.post(card, &room);
    let me = h.clone();
    tokio::spawn(async move { execute(me, run, repo, prompt, false).await });
    id
}

pub fn follow_up(h: &Arc<Harness>, run_id: &str, text: &str) {
    let Some(mut run) = h.with(|s| s.runs.iter().find(|r| r.id == run_id).cloned()) else { return };
    if run.phase == "running" {
        h.post(ChatMessage::note(format!("\"{}\" is still running; the change goes in once it's done.", run.title)), &run.room);
    }
    let me = h.clone();
    let text = text.to_string();
    tokio::spawn(async move {
        while me.with(|s| s.runs.iter().any(|r| r.id == run.id && r.phase == "running")) {
            tokio::time::sleep(Duration::from_millis(500)).await;
        }
        run = me.with(|s| s.runs.iter().find(|r| r.id == run.id).cloned()).unwrap_or(run);
        set_phase(&me, &run.id, "running", None);
        execute(me, run, None, text, true).await;
    });
}

pub fn stop_run(h: &Arc<Harness>, run_id: &str) -> bool {
    let cancel = h.coding_procs.lock().unwrap().get(run_id).cloned();
    if let Some(c) = cancel {
        c.cancel();
        set_phase(h, run_id, "stopped", Some("Stopped.".into()));
        return true;
    }
    false
}

fn set_phase(h: &Harness, id: &str, phase: &str, summary: Option<String>) {
    // A run that fails turns the bot of its chat red until the owner has seen it.
    if phase == "failed" {
        if let Some(room) = h.with(|s| s.runs.iter().find(|r| r.id == id).map(|r| r.room.clone())) {
            if h.bot(&room).is_some() {
                h.set_failure(&room, Some(crate::model::LastFailure { kind: "failed".into(), reason: format!("A coding run failed: {}", summary.clone().unwrap_or_default()), at: chrono::Utc::now() }));
            }
        }
    }
    h.with(|s| {
        if let Some(r) = s.runs.iter_mut().find(|r| r.id == id) {
            // A stopped run stays stopped.
            if r.phase == "stopped" && phase != "running" { return; }
            r.phase = phase.into();
            if summary.is_some() { r.summary = summary; }
        }
    });
    h.write_runs();
}

async fn execute(h: Arc<Harness>, run: CodingRun, repo: Option<PathBuf>, prompt: String, follow_up: bool) {
    let folder = PathBuf::from(&run.folder);
    // The place: a new worktree on its own branch for an existing repo, a new folder (made a repo) otherwise.
    if !follow_up {
        let prepared: Result<(), String> = async {
            if let (Some(repo), Some(branch)) = (&repo, &run.branch) {
                std::fs::create_dir_all(folder.parent().unwrap()).map_err(|e| e.to_string())?;
                git(repo, &["worktree", "add", "-b", branch, &folder.to_string_lossy()]).await?;
            } else {
                std::fs::create_dir_all(&folder).map_err(|e| e.to_string())?;
                if !folder.join(".git").exists() {
                    git(&folder, &["init", "-q"]).await?;
                }
            }
            Ok(())
        }.await;
        if let Err(e) = prepared {
            set_phase(&h, &run.id, "failed", Some(format!("Couldn't set up the folder: {e}")));
            h.post(ChatMessage::note(format!("\"{}\" couldn't start: {e}", run.title)), &run.room);
            return;
        }
    }
    let Some(program) = h.executable("claude") else {
        set_phase(&h, &run.id, "failed", Some("Claude Code isn't installed.".into()));
        h.post(ChatMessage::note(format!("\"{}\" couldn't start: Claude Code isn't installed on this computer.", run.title)), &run.room);
        return;
    };
    let model = h.settings.string("coding.model").unwrap_or_else(|| "claude-sonnet-5-5".into());
    let mut args: Vec<String> = ["-p", "--output-format", "stream-json", "--verbose", "--model", &model, "--permission-mode", "bypassPermissions"].iter().map(|s| s.to_string()).collect();
    if let Some(effort) = h.settings.string("coding.effort") {
        args.push("--effort".into());
        args.push(effort);
    }
    if let Some(session) = &run.session_id {
        args.push("--resume".into());
        args.push(session.clone());
    }
    let cancel = Cancel::new();
    h.coding_procs.lock().unwrap().insert(run.id.clone(), cancel.clone());
    let spec = Spec { program, args, env: vec![("NO_COLOR".into(), "1".into())], remove_env: vec!["CLAUDECODE".into(), "CLAUDE_CODE_ENTRYPOINT".into()], cwd: folder.clone(), limit: Duration::from_secs(3600), format: Format::Claude, stdin: Some(prompt) };
    let outcome = engine::run(spec, cancel.clone(), Some(h.registry.clone()), |_| {}).await;
    h.coding_procs.lock().unwrap().remove(&run.id);
    if cancel.is_cancelled() {
        set_phase(&h, &run.id, "stopped", Some("Stopped.".into()));
        h.post(ChatMessage::note(format!("\"{}\" was stopped, and nothing of it is still running.", run.title)), &run.room);
        return;
    }
    let outcome = match outcome {
        Ok(o) => o,
        Err(e) => {
            set_phase(&h, &run.id, "failed", Some(e.to_string()));
            return;
        }
    };
    if let Some(sid) = outcome.session_id.clone() {
        h.with(|s| if let Some(r) = s.runs.iter_mut().find(|r| r.id == run.id) { r.session_id = Some(sid); });
    }
    if let Some(err) = outcome.error.filter(|_| outcome.text.is_empty()) {
        set_phase(&h, &run.id, "failed", Some(err.clone()));
        h.post(ChatMessage::note(format!("\"{}\" failed: {err}", run.title)), &run.room);
        return;
    }
    // Commit what it did, push and open a draft PR when there's somewhere to push.
    let mut lines = vec![];
    let _ = git(&folder, &["add", "-A"]).await;
    let changed = git(&folder, &["status", "--porcelain"]).await.map(|s| !s.is_empty()).unwrap_or(false);
    if changed {
        let message = if follow_up { format!("{} (follow-up)", run.title) } else { run.title.clone() };
        match git(&folder, &["-c", "user.name=Theo", "-c", "user.email=theo@localhost", "commit", "-q", "-m", &message]).await {
            Ok(_) => lines.push("Committed the changes.".to_string()),
            Err(e) => lines.push(format!("Couldn't commit: {e}")),
        }
    } else {
        lines.push("No file changes to commit.".into());
    }
    let has_remote = git(&folder, &["remote"]).await.map(|r| !r.is_empty()).unwrap_or(false);
    if has_remote {
        if let Some(branch) = &run.branch {
            match git(&folder, &["push", "-q", "-u", "origin", branch]).await {
                Ok(_) => {
                    lines.push(format!("Pushed {branch}."));
                    let existing = h.with(|s| s.runs.iter().find(|r| r.id == run.id).and_then(|r| r.pull_request.clone()));
                    if existing.is_none() {
                        let gh = h.settings.string("test.engine.gh").map(PathBuf::from).or_else(|| engine::locate("gh"));
                        if let Some(gh) = gh {
                            let mut cmd = engine::background_command(&gh);
                            cmd.args(["pr", "create", "--draft", "--title", &run.title, "--body", "Opened by Theo's coding run.", "--head", branch]).current_dir(&folder).env("GH_PROMPT_DISABLED", "1").stdin(std::process::Stdio::null()).kill_on_drop(true);
                            let out = cmd.output().await;
                            match out {
                                Ok(o) if o.status.success() => {
                                    let url = String::from_utf8_lossy(&o.stdout).trim().lines().last().unwrap_or("").to_string();
                                    h.with(|s| if let Some(r) = s.runs.iter_mut().find(|r| r.id == run.id) { r.pull_request = Some(url.clone()); });
                                    lines.push(format!("Draft pull request: {url}"));
                                }
                                Ok(o) => lines.push(format!("Couldn't open a pull request: {}", String::from_utf8_lossy(&o.stderr).trim())),
                                Err(e) => lines.push(format!("Couldn't open a pull request: {e}")),
                            }
                        }
                    }
                }
                Err(e) => lines.push(format!("Couldn't push: {e}")),
            }
        }
    }
    let said: String = outcome.text.chars().take(1200).collect();
    set_phase(&h, &run.id, "done", Some(said.chars().take(300).collect()));
    let mut note = ChatMessage::note(format!("\"{}\" is done{}.\n\n{}\n\n{}", run.title, if follow_up { " with the follow-up" } else { "" }, said.trim(), lines.join(" ")));
    note.run_id = Some(run.id.clone());
    h.post(note, &run.room);
}

#[cfg(test)]
mod tests {
    #[test]
    fn a_new_folder_is_never_dots() {
        assert_eq!(super::new_folder_name("make it in a new folder called liar-1.", ""), Some("liar-1".to_string()));
        assert_eq!(super::new_folder_name("put it in a new folder called ..", "New folder: tidy"), Some("tidy".to_string()));
        assert_eq!(super::new_folder_name("a new folder named .", ""), None);
    }
}
