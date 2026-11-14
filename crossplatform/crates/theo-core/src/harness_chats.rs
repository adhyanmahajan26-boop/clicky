//! The chats a coding agent already has in a folder, newest first, read from where that agent keeps them (the Mac's
//! `HarnessChats` and ClickyCore `HarnessChatFiles`), so a coding run can carry on in one rather than start a new one. Nothing
//! here runs a turn or changes anything; an agent with no way to list them simply has none, and the card offers a new chat.
//!
//! Never `cursor-agent ls` (with no terminal it hangs until killed, and it rewrites files in old chats) and never
//! `gemini --list-sessions` (it can spend a model call, and it writes). Gemini CLI can't carry on a chat by id here at all,
//! so it lists none.

use chrono::{DateTime, TimeZone, Utc};
use serde::Serialize;
use serde_json::Value;
use std::path::{Path, PathBuf};
use std::time::Duration;

pub const MAXIMUM_SHOWN: usize = 20;

/// The agents whose chats Theo can carry on by id on this build: what `coding::coding_arguments` resumes.
pub const CONTINUABLE: [&str; 5] = ["claude", "codex", "cursor", "opencode", "grok"];

#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Chat {
    /// What the agent resumes it by.
    pub id: String,
    pub title: String,
    pub updated_at: DateTime<Utc>,
}

/// A chat's title in the menu: its first words, without what Theo adds to a prompt or markup (`HarnessChatText.title`).
pub fn title(text: &str, limit: usize) -> Option<String> {
    let mut lines: Vec<&str> = text.lines().map(str::trim).filter(|l| !l.is_empty()).collect();
    if lines.first().map(|l| l.starts_with("You are already in a git worktree")).unwrap_or(false) { lines.remove(0); }
    let line = lines.into_iter().find(|l| !l.starts_with('<') && !l.starts_with('[') && !l.starts_with('('))?;
    let line = line.replace("**", "").replace('`', "");
    if line.is_empty() { return None; }
    if line.chars().count() > limit {
        Some(format!("{}\u{2026}", line.chars().take(limit - 1).collect::<String>().trim()))
    } else {
        Some(line)
    }
}

fn title60(text: &str) -> Option<String> { title(text, 60) }

fn date(text: Option<&str>) -> Option<DateTime<Utc>> {
    text.and_then(|t| DateTime::parse_from_rfc3339(t).ok()).map(|d| d.with_timezone(&Utc))
}

fn millis(value: Option<&Value>) -> Option<DateTime<Utc>> {
    value.and_then(|v| v.as_f64()).and_then(|ms| Utc.timestamp_millis_opt(ms as i64).single())
}

fn modified(path: &Path) -> DateTime<Utc> {
    std::fs::metadata(path).and_then(|m| m.modified()).map(DateTime::<Utc>::from).unwrap_or_else(|_| Utc.timestamp_opt(0, 0).unwrap())
}

/// The ways a folder's path can be spelled: as given, and as the system resolves it (without Windows' `\\?\`).
pub fn spellings(folder: &str) -> Vec<String> {
    let mut paths = vec![folder.trim_end_matches(['/', '\\']).to_string()];
    if let Ok(real) = std::fs::canonicalize(folder) {
        let real = real.to_string_lossy().to_string();
        let real = real.strip_prefix(r"\\?\").map(str::to_string).unwrap_or(real);
        if !paths.contains(&real) { paths.push(real); }
    }
    paths
}

fn newest_first(mut chats: Vec<Chat>) -> Vec<Chat> {
    chats.sort_by(|a, b| b.updated_at.cmp(&a.updated_at));
    let mut seen = std::collections::HashSet::new();
    chats.retain(|c| seen.insert(c.id.clone()));
    chats.truncate(MAXIMUM_SHOWN);
    chats
}

/// Every chat `agent` has in `folder`, newest first, at most twenty. Agents it can't read have none.
pub async fn list(home: &Path, agent: &str, folder: &str, opencode: Option<PathBuf>) -> Vec<Chat> {
    let paths = spellings(folder);
    let home = home.to_path_buf();
    let agent_id = agent.to_string();
    let found = match agent {
        "opencode" => match opencode { Some(program) => open_code(&program, &paths).await, None => vec![] },
        _ => tokio::task::spawn_blocking(move || match agent_id.as_str() {
            "claude" => claude(&home, &paths),
            "codex" => codex(&home, &paths),
            "cursor" => paths.iter().flat_map(|p| cursor(&home, p)).collect(),
            "grok" => paths.iter().flat_map(|p| grok(&home, p)).collect(),
            _ => vec![],
        }).await.unwrap_or_default(),
    };
    newest_first(found)
}

// MARK: Claude Code

/// ~/.claude/projects/<this>: the folder's path with everything but letters and digits as "-", each UTF-16 unit, as Claude
/// Code does it. On Windows `C:\Users\me\app` is `C--Users-me-app`.
pub fn claude_folder_name(path: &str) -> String {
    path.encode_utf16().map(|unit| if (48..=57).contains(&unit) || (65..=90).contains(&unit) || (97..=122).contains(&unit) { char::from_u32(unit as u32).unwrap() } else { '-' }).collect()
}

pub const CLAUDE_FOLDER_NAME_LIMIT: usize = 200;

/// A session file's lines, for this folder: its given title, else its first real message from the owner. None for another
/// folder's session, or one with nothing said in it.
pub fn claude_session(id: &str, lines: &[String], folders: &[String], modified_at: DateTime<Utc>) -> Option<Chat> {
    let (mut custom, mut ai_title, mut summary, mut last_prompt, mut first_asked, mut cwd) = (None, None, None, None, None, None);
    let mut has_conversation = false;
    for line in lines {
        let Ok(event) = serde_json::from_str::<Value>(line) else { continue };
        let Some(kind) = event.get("type").and_then(|t| t.as_str()) else { continue };
        if cwd.is_none() {
            if let Some(there) = event.get("cwd").and_then(|c| c.as_str()) { cwd = Some(event.get("relocatedCwd").and_then(|c| c.as_str()).unwrap_or(there).to_string()); }
        }
        let text = |key: &str| event.get(key).and_then(|v| v.as_str()).map(str::to_string);
        match kind {
            "custom-title" => custom = text("customTitle").or(custom),
            "ai-title" => ai_title = text("aiTitle").or(ai_title),
            "summary" => summary = text("summary").or(summary),
            "last-prompt" => last_prompt = text("lastPrompt").or(last_prompt),
            "user" => {
                has_conversation = true;
                let meta = event.get("isMeta").and_then(|m| m.as_bool()).unwrap_or(false) || event.get("isSidechain").and_then(|m| m.as_bool()).unwrap_or(false);
                if first_asked.is_none() && !meta {
                    let content = event.get("message").and_then(|m| m.get("content"));
                    let words = match content {
                        Some(Value::String(s)) => Some(s.clone()),
                        Some(Value::Array(blocks)) => blocks.iter().find(|b| b.get("type").and_then(|t| t.as_str()) == Some("text")).and_then(|b| b.get("text")).and_then(|t| t.as_str()).map(str::to_string),
                        _ => None,
                    };
                    first_asked = words.as_deref().and_then(title60);
                }
            }
            "assistant" => has_conversation = true,
            _ => {}
        }
    }
    if !has_conversation { return None; }
    if let Some(cwd) = &cwd {
        if !folders.is_empty() && !folders.iter().any(|f| f == cwd) { return None; }
    }
    let given = [custom, ai_title, summary].into_iter().flatten().next().as_deref().and_then(title60);
    let title = given.or(first_asked).or(last_prompt.as_deref().and_then(title60)).unwrap_or_else(|| "Untitled chat".into());
    Some(Chat { id: id.into(), title, updated_at: modified_at })
}

/// The first and last 64 KB of a transcript: a title can be at either end.
fn start_and_end_lines(path: &Path) -> Vec<String> {
    let Ok(data) = std::fs::read(path) else { return vec![] };
    const KEEP: usize = 65_536;
    if data.len() <= KEEP * 2 { return String::from_utf8_lossy(&data).lines().map(str::to_string).collect(); }
    let mut lines: Vec<String> = String::from_utf8_lossy(&data[..KEEP]).lines().map(str::to_string).collect();
    lines.pop();
    let tail: Vec<String> = String::from_utf8_lossy(&data[data.len() - KEEP..]).lines().skip(1).map(str::to_string).collect();
    lines.extend(tail);
    lines
}

fn newest_files(directory: &Path, suffix: &str) -> Vec<(PathBuf, DateTime<Utc>)> {
    let mut files: Vec<(PathBuf, DateTime<Utc>)> = std::fs::read_dir(directory).map(|d| d.flatten().map(|e| e.path()).filter(|p| p.to_string_lossy().ends_with(suffix)).map(|p| { let m = modified(&p); (p, m) }).collect()).unwrap_or_default();
    files.sort_by(|a, b| b.1.cmp(&a.1));
    files.truncate(MAXIMUM_SHOWN);
    files
}

fn claude(home: &Path, paths: &[String]) -> Vec<Chat> {
    let projects = home.join(".claude").join("projects");
    let mut directories = vec![];
    for path in paths {
        let name = claude_folder_name(path);
        if name.chars().count() <= CLAUDE_FOLDER_NAME_LIMIT {
            directories.push(projects.join(name));
        } else {
            // Cut at 200 with a hash after it: the cut name finds it, and each session's own folder says if it's the one.
            let cut: String = name.chars().take(CLAUDE_FOLDER_NAME_LIMIT).collect();
            if let Ok(all) = std::fs::read_dir(&projects) {
                directories.extend(all.flatten().map(|e| e.path()).filter(|p| p.file_name().map(|n| n.to_string_lossy().starts_with(&cut)).unwrap_or(false)));
            }
        }
    }
    directories.iter().flat_map(|directory| {
        newest_files(directory, ".jsonl").into_iter().filter_map(|(file, at)| {
            let id = file.file_stem()?.to_string_lossy().to_string();
            claude_session(&id, &start_and_end_lines(&file), paths, at)
        }).collect::<Vec<_>>()
    }).collect()
}

// MARK: Codex

/// A rollout file's first line: its id and the folder it's in.
pub fn codex_meta(first_line: &str) -> Option<(String, String)> {
    let event: Value = serde_json::from_str(first_line).ok()?;
    let payload = event.get("payload")?;
    let cwd = payload.get("cwd")?.as_str()?.to_string();
    let id = payload.get("id").or_else(|| payload.get("session_id"))?.as_str()?.to_string();
    Some((id, cwd))
}

/// ~/.codex/session_index.jsonl: the names Codex gave its threads. A later line wins.
pub fn codex_titles(index: &str) -> std::collections::HashMap<String, String> {
    let mut titles = std::collections::HashMap::new();
    for line in index.lines() {
        let Ok(entry) = serde_json::from_str::<Value>(line) else { continue };
        if let (Some(id), Some(name)) = (entry.get("id").and_then(|v| v.as_str()), entry.get("thread_name").and_then(|v| v.as_str())) {
            if !name.is_empty() { titles.insert(id.to_string(), name.to_string()); }
        }
    }
    titles
}

/// The first thing asked in a rollout, for a thread with no name.
pub fn codex_first_ask(lines: &[String]) -> Option<String> {
    for line in lines {
        let Ok(event) = serde_json::from_str::<Value>(line) else { continue };
        let Some(payload) = event.get("payload") else { continue };
        let kind = event.get("type").and_then(|t| t.as_str());
        if kind == Some("event_msg") && payload.get("type").and_then(|t| t.as_str()) == Some("user_message") {
            if let Some(text) = payload.get("message").and_then(|m| m.as_str()) { return title60(text); }
        }
    }
    None
}

fn codex(home: &Path, paths: &[String]) -> Vec<Chat> {
    let codex = home.join(".codex");
    let titles = codex_titles(&std::fs::read_to_string(codex.join("session_index.jsonl")).unwrap_or_default());
    let mut rollouts = vec![];
    let mut stack = vec![codex.join("sessions")];
    while let Some(dir) = stack.pop() {
        let Ok(entries) = std::fs::read_dir(&dir) else { continue };
        for entry in entries.flatten() {
            let path = entry.path();
            if path.is_dir() { stack.push(path); continue; }
            let name = path.file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_default();
            if name.starts_with("rollout-") && name.ends_with(".jsonl") { let m = modified(&path); rollouts.push((path, m)); }
        }
    }
    rollouts.sort_by(|a, b| b.1.cmp(&a.1));
    let mut found = vec![];
    for (file, at) in rollouts.into_iter().take(200) {
        let Ok(data) = std::fs::read(&file) else { continue };
        let head = &data[..data.len().min(200_000)];
        let lines: Vec<String> = String::from_utf8_lossy(head).lines().map(str::to_string).collect();
        let Some((id, cwd)) = lines.first().and_then(|l| codex_meta(l)) else { continue };
        if !paths.contains(&cwd) { continue; }
        let title = titles.get(&id).and_then(|t| title60(t)).or_else(|| codex_first_ask(&lines)).unwrap_or_else(|| "Untitled chat".into());
        found.push(Chat { id, title, updated_at: at });
        if found.len() >= MAXIMUM_SHOWN { break; }
    }
    found
}

// MARK: Cursor

/// ~/.cursor/chats/<this>/<chat id>: the MD5 of the folder's path.
pub fn cursor_folder_name(path: &str) -> String { md5_hex(path.as_bytes()) }

/// A chat's meta.json. None for one with no conversation in it.
pub fn cursor_chat(id: &str, meta: &str, first_prompt: Option<&str>, modified_at: DateTime<Utc>) -> Option<Chat> {
    let meta: Value = serde_json::from_str(meta).ok()?;
    if meta.get("hasConversation").and_then(|v| v.as_bool()) == Some(false) || meta.get("isSubagent").and_then(|v| v.as_bool()) == Some(true) { return None; }
    let updated_at = millis(meta.get("updatedAtMs")).unwrap_or(modified_at);
    let title = meta.get("title").and_then(|t| t.as_str()).and_then(title60).or_else(|| first_prompt.and_then(title60)).unwrap_or_else(|| "Untitled chat".into());
    Some(Chat { id: id.into(), title, updated_at })
}

fn cursor(home: &Path, folder: &str) -> Vec<Chat> {
    let directory = home.join(".cursor").join("chats").join(cursor_folder_name(folder));
    let Ok(entries) = std::fs::read_dir(&directory) else { return vec![] };
    entries.flatten().filter_map(|entry| {
        let chat = entry.path();
        let meta = std::fs::read_to_string(chat.join("meta.json")).ok()?;
        let prompts: Option<Vec<String>> = std::fs::read(chat.join("prompt_history.json")).ok().and_then(|d| serde_json::from_slice(&d).ok());
        cursor_chat(&entry.file_name().to_string_lossy(), &meta, prompts.as_ref().and_then(|p| p.first()).map(String::as_str), modified(&chat))
    }).collect()
}

// MARK: OpenCode

/// `opencode session list --format json`, which lists every folder's: only this one's come back.
pub fn open_code_sessions(json: &str, folders: &[String]) -> Vec<Chat> {
    let Some(start) = json.find('[') else { return vec![] };
    let Ok(Value::Array(items)) = serde_json::from_str::<Value>(&json[start..]) else { return vec![] };
    items.iter().filter_map(|item| {
        let id = item.get("id")?.as_str()?;
        let directory = item.get("directory")?.as_str()?;
        if !folders.iter().any(|f| f == directory) { return None; }
        let updated_at = millis(item.get("updated").or_else(|| item.get("created"))).unwrap_or_else(|| Utc.timestamp_opt(0, 0).unwrap());
        let title = item.get("title").and_then(|t| t.as_str()).and_then(title60).unwrap_or_else(|| "Untitled chat".into());
        Some(Chat { id: id.into(), title, updated_at })
    }).collect()
}

async fn open_code(program: &Path, paths: &[String]) -> Vec<Chat> {
    let Some(folder) = paths.first() else { return vec![] };
    if !Path::new(folder).is_dir() { return vec![]; }
    let mut command = crate::engine::background_command(program);
    command.args(["session", "list", "--format", "json", "-n", "300"]).current_dir(folder).env("NO_COLOR", "1")
        .stdin(std::process::Stdio::null()).stderr(std::process::Stdio::null()).kill_on_drop(true);
    match tokio::time::timeout(Duration::from_secs(15), command.output()).await {
        Ok(Ok(out)) if out.status.success() => open_code_sessions(&String::from_utf8_lossy(&out.stdout), paths),
        _ => vec![],
    }
}

// MARK: Grok

/// ~/.grok/sessions/<this>/<session id>: the folder's path, percent-encoded.
pub fn grok_folder_name(path: &str) -> String {
    path.bytes().map(|b| if b.is_ascii_alphanumeric() || b"-._~".contains(&b) { (b as char).to_string() } else { format!("%{b:02X}") }).collect()
}

/// A session's summary.json: its generated title, else the first thing asked in it.
pub fn grok_chat(id: &str, summary: Option<&str>, first_prompt: Option<&str>, modified_at: DateTime<Utc>) -> Option<Chat> {
    let summary: Option<Value> = summary.and_then(|s| serde_json::from_str(s).ok());
    if summary.as_ref().and_then(|s| s.get("session_kind")).and_then(|k| k.as_str()) == Some("subagent") { return None; }
    let given = summary.as_ref().and_then(|s| s.get("generated_title").or_else(|| s.get("session_summary"))).and_then(|t| t.as_str());
    let title = given.and_then(title60).or_else(|| first_prompt.and_then(title60))?;
    let updated_at = date(summary.as_ref().and_then(|s| s.get("last_active_at")).and_then(|v| v.as_str()))
        .or_else(|| date(summary.as_ref().and_then(|s| s.get("updated_at")).and_then(|v| v.as_str()))).unwrap_or(modified_at);
    Some(Chat { id: id.into(), title, updated_at })
}

fn grok(home: &Path, folder: &str) -> Vec<Chat> {
    let directory = home.join(".grok").join("sessions").join(grok_folder_name(folder));
    let mut first_prompts = std::collections::HashMap::new();
    for line in std::fs::read_to_string(directory.join("prompt_history.jsonl")).unwrap_or_default().lines() {
        let Ok(entry) = serde_json::from_str::<Value>(line) else { continue };
        if let (Some(id), Some(prompt)) = (entry.get("session_id").and_then(|v| v.as_str()), entry.get("prompt").and_then(|v| v.as_str())) {
            first_prompts.entry(id.to_string()).or_insert_with(|| prompt.to_string());
        }
    }
    let Ok(entries) = std::fs::read_dir(&directory) else { return vec![] };
    entries.flatten().filter(|e| e.path().is_dir()).filter_map(|entry| {
        let id = entry.file_name().to_string_lossy().to_string();
        let summary = std::fs::read_to_string(entry.path().join("summary.json")).ok();
        grok_chat(&id, summary.as_deref(), first_prompts.get(&id).map(String::as_str), modified(&entry.path()))
    }).collect()
}

// MARK: MD5, for Cursor's folder names

pub fn md5_hex(input: &[u8]) -> String {
    const S: [u32; 64] = [7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20,
        4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21];
    let k: Vec<u32> = (0..64).map(|i| ((i as f64 + 1.0).sin().abs() * 4294967296.0) as u32).collect();
    let (mut a0, mut b0, mut c0, mut d0) = (0x67452301u32, 0xefcdab89u32, 0x98badcfeu32, 0x10325476u32);
    let mut message = input.to_vec();
    let bit_length = (input.len() as u64).wrapping_mul(8);
    message.push(0x80);
    while message.len() % 64 != 56 { message.push(0); }
    message.extend_from_slice(&bit_length.to_le_bytes());
    for chunk in message.chunks(64) {
        let m: Vec<u32> = chunk.chunks(4).map(|w| u32::from_le_bytes([w[0], w[1], w[2], w[3]])).collect();
        let (mut a, mut b, mut c, mut d) = (a0, b0, c0, d0);
        for i in 0..64 {
            let (f, g) = match i / 16 {
                0 => ((b & c) | (!b & d), i),
                1 => ((d & b) | (!d & c), (5 * i + 1) % 16),
                2 => (b ^ c ^ d, (3 * i + 5) % 16),
                _ => (c ^ (b | !d), (7 * i) % 16),
            };
            let f = f.wrapping_add(a).wrapping_add(k[i]).wrapping_add(m[g]);
            a = d;
            d = c;
            c = b;
            b = b.wrapping_add(f.rotate_left(S[i]));
        }
        a0 = a0.wrapping_add(a);
        b0 = b0.wrapping_add(b);
        c0 = c0.wrapping_add(c);
        d0 = d0.wrapping_add(d);
    }
    [a0, b0, c0, d0].iter().flat_map(|w| w.to_le_bytes()).map(|b| format!("{b:02x}")).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn at(seconds: i64) -> DateTime<Utc> { Utc.timestamp_opt(seconds, 0).unwrap() }

    #[test]
    fn md5_matches_the_standard_vectors() {
        assert_eq!(md5_hex(b""), "d41d8cd98f00b204e9800998ecf8427e");
        assert_eq!(md5_hex(b"The quick brown fox jumps over the lazy dog"), "9e107d9d372bb6826bd81d3542a419d6");
        assert_eq!(md5_hex(&[b'a'; 200]), md5_hex(&[b'a'; 200]));
        assert_eq!(md5_hex(b"12345678901234567890123456789012345678901234567890123456789012345678901234567890"), "57edf4a22be3c955ac49da2e2107b67a");
    }

    #[test]
    fn folder_names_are_spelled_as_each_agent_does() {
        assert_eq!(claude_folder_name(r"C:\Users\me\moon-site"), "C--Users-me-moon-site");
        assert_eq!(claude_folder_name("/home/me/app_1"), "-home-me-app-1");
        assert_eq!(grok_folder_name("/home/me/my app"), "%2Fhome%2Fme%2Fmy%20app");
        assert_eq!(cursor_folder_name("/tmp/x").len(), 32);
    }

    #[test]
    fn a_claude_session_is_titled_and_kept_to_its_folder() {
        let lines: Vec<String> = [
            r#"{"type":"user","cwd":"/work/app","message":{"content":"Fix the **login** bug\nmore"}}"#,
            r#"{"type":"assistant","message":{"content":[{"type":"text","text":"ok"}]}}"#,
        ].iter().map(|s| s.to_string()).collect();
        let chat = claude_session("s1", &lines, &["/work/app".into()], at(5)).unwrap();
        assert_eq!(chat.title, "Fix the login bug");
        assert!(claude_session("s1", &lines, &["/elsewhere".into()], at(5)).is_none());
        let titled: Vec<String> = lines.iter().cloned().chain([r#"{"type":"ai-title","aiTitle":"Login fix"}"#.to_string()]).collect();
        assert_eq!(claude_session("s1", &titled, &[], at(5)).unwrap().title, "Login fix");
        assert!(claude_session("s2", &[r#"{"type":"summary","summary":"x"}"#.to_string()], &[], at(5)).is_none());
    }

    #[test]
    fn codex_cursor_opencode_and_grok_files_are_read() {
        assert_eq!(codex_meta(r#"{"type":"session_meta","payload":{"id":"t-1","cwd":"/w"}}"#), Some(("t-1".into(), "/w".into())));
        assert_eq!(codex_titles("{\"id\":\"t-1\",\"thread_name\":\"Old\"}\n{\"id\":\"t-1\",\"thread_name\":\"New\"}")["t-1"], "New");
        assert_eq!(codex_first_ask(&[r#"{"type":"event_msg","payload":{"type":"user_message","message":"Add tests"}}"#.to_string()]), Some("Add tests".into()));
        assert_eq!(cursor_chat("c1", r#"{"title":"Refactor","updatedAtMs":1700000000000}"#, None, at(0)).unwrap().updated_at.timestamp(), 1_700_000_000);
        assert!(cursor_chat("c1", r#"{"hasConversation":false}"#, None, at(0)).is_none());
        assert_eq!(cursor_chat("c1", "{}", Some("First words"), at(0)).unwrap().title, "First words");
        let sessions = open_code_sessions(r#"[{"id":"ses_1","directory":"/w","title":"One","updated":1700000000000},{"id":"ses_2","directory":"/other","title":"Two"}]"#, &["/w".into()]);
        assert_eq!(sessions.len(), 1);
        assert_eq!(sessions[0].id, "ses_1");
        assert_eq!(grok_chat("g1", Some(r#"{"generated_title":"Ship it"}"#), None, at(0)).unwrap().title, "Ship it");
        assert!(grok_chat("g1", Some(r#"{"session_kind":"subagent","generated_title":"x"}"#), None, at(0)).is_none());
        assert!(grok_chat("g1", None, None, at(0)).is_none());
    }

    #[test]
    fn titles_skip_theos_own_opening_and_are_cut() {
        assert_eq!(title("You are already in a git worktree.\nMake the page blue", 60), Some("Make the page blue".into()));
        assert_eq!(title(&"word ".repeat(30), 20).unwrap().chars().count(), 20);
        assert_eq!(title("<context>\n[x]\n", 60), None);
    }

    #[tokio::test]
    async fn claudes_chats_in_a_folder_are_listed_newest_first() {
        let home = tempfile::tempdir().unwrap();
        let work = tempfile::tempdir().unwrap();
        let folder = work.path().to_string_lossy().to_string();
        let store = home.path().join(".claude").join("projects").join(claude_folder_name(&folder));
        std::fs::create_dir_all(&store).unwrap();
        std::fs::write(store.join("abc.jsonl"), format!("{{\"type\":\"user\",\"cwd\":{},\"message\":{{\"content\":\"Build the page\"}}}}\n", serde_json::to_string(&folder).unwrap())).unwrap();
        let chats = list(home.path(), "claude", &folder, None).await;
        assert_eq!(chats.len(), 1);
        assert_eq!((chats[0].id.as_str(), chats[0].title.as_str()), ("abc", "Build the page"));
        assert!(list(home.path(), "gemini", &folder, None).await.is_empty());
    }
}
