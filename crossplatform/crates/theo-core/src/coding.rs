//! Coding runs: a coding agent (any of Claude Code, Codex, Cursor Agent, OpenCode, Grok or Gemini CLI, with write access in
//! its own folder) does the work the owner asked for. An existing git repo gets its own branch and worktree, so two runs never
//! touch each other's files; the result is committed, pushed and opened as a draft pull request when the repo has a remote and
//! `gh` is signed in. Only the owner's own words start one.
//!
//! Which agent: the owner's pick (`coding.target`, Settings › Coding runs) when it is installed here, else the first one that
//! is ready (installed and signed in, or signed out with a saved API key it reads), in the Mac's order, else the first one
//! installed (the Mac's `CodingTargetDefault`). None is required: without one, the run says which to install.

use crate::engine::{self, Cancel, Format, Spec};
use serde_json::{json, Value};
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

/// The coding agents in the order Theo tries them when the owner hasn't picked one (the Mac's harness catalog order).
pub const CODING_AGENTS: [&str; 6] = ["claude", "codex", "cursor", "opencode", "grok", "gemini"];

/// Settings key: the agent the owner picked for coding runs. Unset: automatic.
pub const TARGET_SETTING: &str = "coding.target";

/// One agent as the choice sees it.
#[derive(Clone, Debug, PartialEq)]
pub struct AgentReadiness {
    pub id: String,
    pub installed: bool,
    /// Installed and signed in, or signed out with a saved key it reads.
    pub ready: bool,
}

/// The agent a coding run uses, and whether that is not the one the owner picked (theirs isn't installed here).
pub fn pick(picked: Option<&str>, agents: &[AgentReadiness]) -> Option<(String, bool)> {
    let find = |id: &str| agents.iter().find(|agent| agent.id == id);
    let picked = picked.filter(|id| CODING_AGENTS.contains(id));
    if let Some(id) = picked {
        if find(id).map(|agent| agent.installed).unwrap_or(false) {
            return Some((id.to_string(), false));
        }
    }
    let fell_back = picked.is_some();
    let ordered = CODING_AGENTS.iter().filter_map(|id| find(id));
    if let Some(agent) = ordered.clone().find(|agent| agent.ready) {
        return Some((agent.id.clone(), fell_back));
    }
    ordered.clone().find(|agent| agent.installed).map(|agent| (agent.id.clone(), fell_back))
}

/// Which agent coding runs use, from the brains inventory's agents (no program is asked anything), for Setup and Settings.
pub fn describe(h: &Harness, inventory_agents: &[Value]) -> Value {
    let agents: Vec<AgentReadiness> = inventory_agents
        .iter()
        .map(|agent| AgentReadiness {
            id: agent["id"].as_str().unwrap_or_default().to_string(),
            installed: agent["installed"].as_bool().unwrap_or(false),
            ready: agent["codingReady"].as_bool().or_else(|| agent["ready"].as_bool()).unwrap_or(false),
        })
        .collect();
    let picked = h.settings.string(TARGET_SETTING);
    let chosen = pick(picked.as_deref(), &agents);
    let target = chosen.as_ref().map(|(id, _)| id.clone());
    let ready = target.as_ref().map(|id| agents.iter().any(|agent| &agent.id == id && agent.ready)).unwrap_or(false);
    json!({
        "target": target, "label": target.as_deref().map(crate::brains::label), "ready": ready, "picked": picked,
        "pickedMissing": chosen.as_ref().map(|(_, fell_back)| *fell_back).unwrap_or(picked.is_some()),
        "choices": CODING_AGENTS.iter().map(|id| json!({"id": id, "label": crate::brains::label(id)})).collect::<Vec<_>>(),
    })
}

/// The same choice for a run that is starting, checked with the agents themselves (installed, signed in, or a key). The
/// owner's pick wins when it is installed; otherwise the agents are asked in order and the first ready one settles it.
async fn choose_agent(h: &Harness) -> Option<(String, bool)> {
    let picked = h.settings.string(TARGET_SETTING).filter(|id| CODING_AGENTS.contains(&id.as_str()));
    if let Some(id) = &picked {
        if h.executable(id).is_some() {
            return Some((id.clone(), false));
        }
    }
    let mut agents = vec![];
    for id in CODING_AGENTS {
        let found = h.executable(id);
        let ready = match &found {
            Some(program) => crate::brains::signed_in(h, id, program).await != Some(false) || !crate::brains::agent_key_environment(h, id).is_empty(),
            None => false,
        };
        agents.push(AgentReadiness { id: id.to_string(), installed: found.is_some(), ready });
        if ready {
            break;
        }
    }
    pick(picked.as_deref(), &agents)
}

/// The model and effort for a run on `agent`: the owner's coding model and effort are for the agent they set them for (Claude
/// Code when no agent is picked, as before), since another agent would refuse to start on them; else the agent's own default.
fn model_and_effort(h: &Harness, agent: &str) -> (Option<String>, Option<String>) {
    let configured_for = h.settings.string(TARGET_SETTING).unwrap_or_else(|| "claude".into());
    let (model, effort) = if configured_for == agent { (h.settings.string("coding.model"), h.settings.string("coding.effort")) } else { (None, None) };
    let default_model = crate::brains::command_line_brain(agent).map(|brain| brain.default_model).filter(|model| !model.is_empty()).map(str::to_string);
    (model.filter(|m| !m.is_empty()).or(default_model), effort.filter(|e| !e.is_empty()))
}

/// The command line for one coding turn on `agent`, with write access in `folder` and nobody there to approve anything. The
/// Mac's `HarnessCoding.headlessArguments`, in each agent's streaming format. Returns the arguments, what goes on standard
/// input, and the output format.
#[allow(clippy::too_many_arguments)]
pub fn coding_arguments(agent: &str, model: Option<&str>, effort: Option<&str>, folder: &Path, prompt: &str, prompt_argument: &str, session: Option<&str>, codex_reply_file: &Path) -> (Vec<String>, Option<String>, Format) {
    let folder_text = folder.to_string_lossy().to_string();
    let mut args: Vec<String> = vec![];
    let mut push = |items: &[&str]| args.extend(items.iter().map(|item| item.to_string()));
    match agent {
        "codex" => {
            let reply = codex_reply_file.to_string_lossy().to_string();
            match session {
                // `exec resume` has no -C or -s: the folder is the process's, the sandbox a config override.
                Some(_) => push(&["exec", "resume", "--json", "--skip-git-repo-check"]),
                None => push(&["exec", "--json", "--skip-git-repo-check", "-C", &folder_text]),
            }
            if let Some(model) = model {
                push(&["-m", model]);
            }
            if let Some(effort) = effort {
                push(&["-c", &format!("model_reasoning_effort={}", crate::hub::toml_string(effort))]);
            }
            push(&["-c", "check_for_update_on_startup=false"]);
            match session {
                Some(session) => push(&["-c", "sandbox_mode=\"workspace-write\"", "-o", &reply, "--", session, "-"]),
                None => push(&["-s", "workspace-write", "-o", &reply, "-"]),
            }
            (args, Some(prompt.to_string()), Format::Codex)
        }
        "cursor" => {
            push(&["-p", "--output-format", "stream-json", "--stream-partial-output", "--force", "--trust", "--workspace", &folder_text]);
            if let Some(session) = session {
                push(&["--resume", session]);
            }
            if let Some(model) = model {
                push(&["--model", model]);
            }
            push(&[prompt_argument]);
            (args, None, Format::Cursor)
        }
        "opencode" => {
            push(&["run", "--format", "json", "--dir", &folder_text]);
            if let Some(session) = session {
                push(&["-s", session]);
            }
            if let Some(model) = model {
                push(&["-m", model]);
            }
            if let Some(effort) = effort {
                push(&["--variant", effort]);
            }
            push(&[prompt_argument]);
            (args, None, Format::OpenCode)
        }
        "grok" => {
            push(&["-p", prompt_argument, "--output-format", "streaming-messages-json", "--permission-mode", "auto"]);
            if let Some(session) = session {
                push(&["--resume", session]);
            }
            if let Some(model) = model {
                push(&["-m", model]);
            }
            if let Some(effort) = effort {
                push(&["--reasoning-effort", effort]);
            }
            (args, None, Format::Grok)
        }
        // Gemini CLI: the prompt on standard input (`-p` adds its words after it). Its sessions can't be resumed by id, so a
        // follow-up starts afresh in the same folder, where the earlier work already is.
        "gemini" => {
            push(&["-p", "", "--output-format", "json", "--approval-mode", "auto_edit"]);
            if let Some(model) = model {
                push(&["-m", model]);
            }
            (args, Some(prompt.to_string()), Format::Gemini)
        }
        _ => {
            push(&["-p", "--output-format", "stream-json", "--verbose", "--permission-mode", "bypassPermissions"]);
            if let Some(model) = model {
                push(&["--model", model]);
            }
            if let Some(effort) = effort {
                push(&["--effort", effort]);
            }
            if let Some(session) = session {
                push(&["--resume", session]);
            }
            (args, Some(prompt.to_string()), Format::Claude)
        }
    }
}

/// What a stranger reads when no coding agent is here: what to install, with the one that needs no account first.
fn no_agent_words() -> String {
    "No coding agent is installed on this computer. Coding runs need one: Claude Code, Codex, Cursor Agent, OpenCode, Grok or Gemini CLI. Add one in Settings › Brains (OpenCode's free models need no account), then ask again.".to_string()
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
        // Chosen when the run starts (asking the agents takes a moment): see `choose_agent`.
        harness: None,
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
    // The agent: the one this run was on for a follow-up (its session lives there), else the choice.
    let earlier = run.harness.clone().filter(|id| follow_up && CODING_AGENTS.contains(&id.as_str()));
    let (agent, fell_back) = match earlier {
        Some(id) => (id, false),
        None => match choose_agent(&h).await {
            Some(chosen) => chosen,
            None => {
                let words = no_agent_words();
                set_phase(&h, &run.id, "failed", Some(words.clone()));
                h.post(ChatMessage::note(format!("\"{}\" couldn't start: {words}", run.title)), &run.room);
                return;
            }
        },
    };
    let label = crate::brains::label(&agent);
    let Some(program) = h.executable(&agent) else {
        let words = format!("{label} isn't installed on this computer any more, so the follow-up can't run there. Install it again in Settings › Brains.");
        set_phase(&h, &run.id, "failed", Some(words.clone()));
        h.post(ChatMessage::note(format!("\"{}\" couldn't go on: {words}", run.title)), &run.room);
        return;
    };
    if run.harness.as_deref() != Some(agent.as_str()) {
        // A different agent can't resume another's session.
        let session_belongs_elsewhere = run.harness.is_some();
        h.with(|s| if let Some(r) = s.runs.iter_mut().find(|r| r.id == run.id) {
            r.harness = Some(agent.clone());
            if session_belongs_elsewhere { r.session_id = None; }
        });
        h.write_runs();
    }
    if fell_back {
        let picked = h.settings.string(TARGET_SETTING).map(|id| crate::brains::label(&id)).unwrap_or_default();
        h.post(ChatMessage::note(format!("{picked}, your pick for coding runs, isn't installed here, so {label} does \"{}\".", run.title)), &run.room);
    }
    let (model, effort) = model_and_effort(&h, &agent);
    // Gemini CLI can't resume by id: every turn starts afresh.
    let session = if agent == "gemini" { None } else { h.with(|s| s.runs.iter().find(|r| r.id == run.id).and_then(|r| r.session_id.clone())).or(run.session_id.clone()).filter(|_| run.harness.as_deref().map(|was| was == agent).unwrap_or(true)) };
    let turn_folder = h.paths.turns_dir().join(format!("coding-{}", uuid::Uuid::new_v4()));
    let _ = std::fs::create_dir_all(&turn_folder);
    let _remove_turn_folder = RemoveFolderWhenDone(turn_folder.clone());
    let codex_reply_file = turn_folder.join("codex-reply.txt");
    let prompt_argument = h.prompt_as_argument(&prompt, &turn_folder);
    let (args, stdin, format) = coding_arguments(&agent, model.as_deref(), effort.as_deref(), &folder, &prompt, &prompt_argument, session.as_deref(), &codex_reply_file);
    let mut env: Vec<(String, String)> = vec![("NO_COLOR".into(), "1".into()), ("THEO_CODING_RUN".into(), "1".into())];
    if agent == "gemini" {
        // An untrusted folder would put Gemini CLI back to asking for every edit, with nobody there to answer.
        env.push(("GEMINI_CLI_TRUST_WORKSPACE".into(), "true".into()));
    }
    // A signed-out agent works on the owner's saved key, the Mac's "use my API key". A signed-in one keeps its subscription.
    let signed_in = crate::brains::signed_in(&h, &agent, &program).await;
    if signed_in == Some(false) {
        env.extend(crate::brains::agent_key_environment(&h, &agent));
    }
    let cancel = Cancel::new();
    h.coding_procs.lock().unwrap().insert(run.id.clone(), cancel.clone());
    let spec = Spec {
        program,
        args,
        env,
        remove_env: ["CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_CODE_SSE_PORT", "ANTHROPIC_API_KEY_HELPER"].iter().map(|s| s.to_string()).collect(),
        cwd: folder.clone(),
        limit: Duration::from_secs(3600),
        format,
        stdin,
    };
    let outcome = engine::run(spec, cancel.clone(), Some(h.registry.clone()), |_| {}).await;
    h.coding_procs.lock().unwrap().remove(&run.id);
    if cancel.is_cancelled() {
        set_phase(&h, &run.id, "stopped", Some("Stopped.".into()));
        h.post(ChatMessage::note(format!("\"{}\" was stopped, and nothing of it is still running.", run.title)), &run.room);
        return;
    }
    let mut outcome = match outcome {
        Ok(o) => o,
        Err(e) => {
            let words = format!("{label} couldn't start: {e}");
            set_phase(&h, &run.id, "failed", Some(words.clone()));
            h.post(ChatMessage::note(format!("\"{}\" failed: {words}", run.title)), &run.room);
            return;
        }
    };
    if outcome.text.trim().is_empty() {
        if let Some(saved) = std::fs::read_to_string(&codex_reply_file).ok().map(|t| t.trim().to_string()).filter(|t| !t.is_empty()) {
            outcome.text = saved;
        }
    }
    if let Some(sid) = outcome.session_id.clone().filter(|_| agent != "gemini") {
        h.with(|s| if let Some(r) = s.runs.iter_mut().find(|r| r.id == run.id) { r.session_id = Some(sid); });
    }
    let failure = if outcome.text.trim().is_empty() {
        let everything = format!("{}\n{}\n{}", outcome.error.clone().unwrap_or_default(), outcome.unread_output, outcome.stderr_tail);
        crate::brains::usage_limit_message(&agent, &everything)
            .or_else(|| crate::brains::sign_in_problem(&agent, &everything))
            .or_else(|| outcome.error.clone())
            .or_else(|| (outcome.exit_code.unwrap_or(0) != 0).then(|| {
                let last = outcome.stderr_tail.lines().rev().find(|line| !line.trim().is_empty()).unwrap_or("").trim().chars().take(300).collect::<String>();
                if last.is_empty() { format!("{label} stopped (exit {}).", outcome.exit_code.unwrap_or(-1)) } else { format!("{label} stopped: {last}") }
            }))
    } else {
        None
    };
    if let Some(err) = failure {
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
    let mut note = ChatMessage::note(format!("\"{}\" is done{} ({label}).\n\n{}\n\n{}", run.title, if follow_up { " with the follow-up" } else { "" }, said.trim(), lines.join(" ")));
    note.run_id = Some(run.id.clone());
    h.post(note, &run.room);
}

/// The run's own folder for files an agent writes on the side (Codex's last message, a long prompt), removed when it ends.
struct RemoveFolderWhenDone(PathBuf);

impl Drop for RemoveFolderWhenDone {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn agent(id: &str, installed: bool, ready: bool) -> AgentReadiness {
        AgentReadiness { id: id.into(), installed, ready }
    }

    #[test]
    fn the_coding_agent_is_the_owners_pick_else_the_first_ready_else_the_first_installed() {
        let agents = vec![agent("claude", false, false), agent("codex", true, false), agent("cursor", false, false), agent("opencode", true, true), agent("grok", false, false), agent("gemini", true, true)];
        assert_eq!(pick(None, &agents), Some(("opencode".to_string(), false)));
        assert_eq!(pick(Some("gemini"), &agents), Some(("gemini".to_string(), false)));
        // Picked but installed and signed out still wins (it says so in the chat when it fails), as on the Mac.
        assert_eq!(pick(Some("codex"), &agents), Some(("codex".to_string(), false)));
        // Picked and not here: the first ready one, and the run says the pick isn't installed.
        assert_eq!(pick(Some("claude"), &agents), Some(("opencode".to_string(), true)));
        assert_eq!(pick(Some("nonsense"), &agents), Some(("opencode".to_string(), false)));
        let none_ready = vec![agent("claude", false, false), agent("gemini", true, false), agent("codex", true, false)];
        assert_eq!(pick(None, &none_ready), Some(("codex".to_string(), false)));
        assert_eq!(pick(None, &[agent("claude", false, false)]), None);
        assert_eq!(pick(Some("claude"), &[]), None);
    }

    #[test]
    fn every_agent_gets_write_access_in_the_runs_folder() {
        let folder = Path::new("/work/tree");
        let reply = Path::new("/turns/codex-reply.txt");
        let (args, stdin, format) = coding_arguments("codex", Some("gpt-6"), Some("high"), folder, "do it", "do it", None, reply);
        assert_eq!(format, Format::Codex);
        assert_eq!(stdin.as_deref(), Some("do it"));
        assert!(args.windows(2).any(|w| w == ["-C", "/work/tree"]) && args.windows(2).any(|w| w == ["-s", "workspace-write"]) && args.last().unwrap() == "-");
        let (args, _, _) = coding_arguments("codex", None, None, folder, "more", "more", Some("thread-1"), reply);
        assert_eq!(&args[..2], ["exec", "resume"]);
        assert!(args.ends_with(&["--".to_string(), "thread-1".to_string(), "-".to_string()]) && args.contains(&"sandbox_mode=\"workspace-write\"".to_string()));
        let (args, stdin, format) = coding_arguments("cursor", None, None, folder, "do it", "do it", Some("chat-1"), reply);
        assert!(format == Format::Cursor && stdin.is_none() && args.contains(&"--force".to_string()) && args.windows(2).any(|w| w == ["--workspace", "/work/tree"]) && args.windows(2).any(|w| w == ["--resume", "chat-1"]));
        let (args, _, format) = coding_arguments("opencode", Some("opencode/x"), None, folder, "do it", "do it", Some("ses_1"), reply);
        assert!(format == Format::OpenCode && args[0] == "run" && args.windows(2).any(|w| w == ["--dir", "/work/tree"]) && args.windows(2).any(|w| w == ["-s", "ses_1"]) && args.last().unwrap() == "do it");
        let (args, _, format) = coding_arguments("grok", None, None, folder, "do it", "do it", None, reply);
        assert!(format == Format::Grok && args.windows(2).any(|w| w == ["--permission-mode", "auto"]));
        let (args, stdin, format) = coding_arguments("gemini", None, None, folder, "do it", "do it", Some("ignored"), reply);
        assert!(format == Format::Gemini && stdin.is_some() && args.windows(2).any(|w| w == ["--approval-mode", "auto_edit"]) && !args.contains(&"--resume".to_string()));
        let (args, stdin, format) = coding_arguments("claude", Some("claude-haiku-5-5"), None, folder, "do it", "do it", Some("s1"), reply);
        assert!(format == Format::Claude && stdin.is_some() && args.contains(&"bypassPermissions".to_string()) && args.windows(2).any(|w| w == ["--resume", "s1"]));
    }

    #[test]
    fn a_new_folder_is_never_dots() {
        assert_eq!(super::new_folder_name("make it in a new folder called liar-1.", ""), Some("liar-1".to_string()));
        assert_eq!(super::new_folder_name("put it in a new folder called ..", "New folder: tidy"), Some("tidy".to_string()));
        assert_eq!(super::new_folder_name("a new folder named .", ""), None);
    }
}
