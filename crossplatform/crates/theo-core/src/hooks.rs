//! Owner hooks: executable files in `Hooks/<event>/`, run when that happens with the details as JSON in a file named by
//! their first argument. Placing the file is the opt-in; a file anyone else can write to, or a link, doesn't run.

use std::path::{Path, PathBuf};
use std::time::Duration;

pub const EVENTS: [&str; 4] = ["app-started", "turn-finished", "routine-finished", "gateway-message"];
pub const TIME_LIMIT: Duration = Duration::from_secs(15);
pub const PER_EVENT: usize = 8;

/// Whether Theo will run this file, and if not, why.
pub fn check(path: &Path) -> Result<(), String> {
    let name = path.file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_default();
    if name.starts_with('.') || name.ends_with('~') {
        return Err("hidden or a backup".into());
    }
    let meta = std::fs::symlink_metadata(path).map_err(|e| e.to_string())?;
    if !meta.file_type().is_file() {
        return Err("not a regular file (a link or a folder)".into());
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::{MetadataExt, PermissionsExt};
        if meta.uid() != unsafe { libc::getuid() } {
            return Err("owned by another user".into());
        }
        let mode = meta.permissions().mode();
        if mode & 0o022 != 0 {
            return Err("others can write to it".into());
        }
        if mode & 0o100 == 0 {
            return Err("not executable".into());
        }
    }
    #[cfg(windows)]
    {
        let ext = path.extension().map(|e| e.to_string_lossy().to_lowercase()).unwrap_or_default();
        if !["exe", "cmd", "bat", "ps1", "py"].contains(&ext.as_str()) {
            return Err("not a program (.exe, .cmd, .bat, .ps1 or .py)".into());
        }
    }
    Ok(())
}

pub fn files(hooks_dir: &Path, event: &str) -> Vec<(PathBuf, Result<(), String>)> {
    let mut out: Vec<(PathBuf, Result<(), String>)> = std::fs::read_dir(hooks_dir.join(event)).map(|d| d.flatten().map(|e| {
        let p = e.path();
        let ok = check(&p);
        (p, ok)
    }).collect()).unwrap_or_default();
    out.sort_by(|a, b| a.0.cmp(&b.0));
    out
}

pub fn payload(event: &str, fields: &serde_json::Value) -> Vec<u8> {
    let mut object = serde_json::Map::new();
    object.insert("event".into(), event.into());
    object.insert("at".into(), chrono::Utc::now().to_rfc3339().into());
    if let Some(map) = fields.as_object() {
        for (k, v) in map {
            let v = match v {
                serde_json::Value::String(s) => serde_json::Value::String(s.chars().take(4000).collect()),
                other => other.clone(),
            };
            object.insert(k.clone(), v);
        }
    }
    serde_json::to_vec(&serde_json::Value::Object(object)).unwrap_or_default()
}

/// Runs every hook for an event in the background, each held to the time limit.
pub fn fire(hooks_dir: PathBuf, tmp_dir: PathBuf, event: &'static str, fields: serde_json::Value) {
    tokio::spawn(async move {
        let runnable: Vec<PathBuf> = files(&hooks_dir, event).into_iter().filter(|(_, ok)| ok.is_ok()).map(|(p, _)| p).take(PER_EVENT).collect();
        if runnable.is_empty() {
            return;
        }
        let data = payload(event, &fields);
        let file = tmp_dir.join(format!("hook-{}-{}.json", event, uuid::Uuid::new_v4().simple()));
        if crate::store::write_atomic(&file, &data).is_err() {
            return;
        }
        let mut waits = vec![];
        for hook in runnable {
            let file = file.clone();
            waits.push(tokio::spawn(async move {
                let ext = hook.extension().map(|e| e.to_string_lossy().to_lowercase()).unwrap_or_default();
                let (program, mut args) = if ext == "ps1" {
                    (PathBuf::from("powershell"), vec!["-NoProfile".to_string(), "-ExecutionPolicy".into(), "Bypass".into(), "-File".into(), hook.to_string_lossy().to_string()])
                } else {
                    crate::engine::command_for(&hook)
                };
                args.push(file.to_string_lossy().to_string());
                let mut cmd = tokio::process::Command::new(program);
                cmd.args(args).stdin(std::process::Stdio::null()).stdout(std::process::Stdio::null()).stderr(std::process::Stdio::null()).kill_on_drop(true);
                crate::procs::configure(&mut cmd);
                if let Ok(mut child) = cmd.spawn() {
                    let tree = crate::procs::ProcessTree::attach(&child).ok();
                    if tokio::time::timeout(TIME_LIMIT, child.wait()).await.is_err() {
                        if let Some(t) = &tree { t.kill(); }
                        let _ = child.kill().await;
                    }
                }
            }));
        }
        for w in waits {
            let _ = w.await;
        }
        let _ = std::fs::remove_file(file);
    });
}
