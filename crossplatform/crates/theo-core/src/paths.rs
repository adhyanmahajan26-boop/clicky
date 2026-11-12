//! Where Theo keeps its files on each platform.
//!
//! The desktop build never shares a folder with the Swift app: on a Mac it uses `Theo-Desktop`, not `Theo`.

use std::path::{Path, PathBuf};

pub const APP_FOLDER: &str = "Theo-Desktop";

/// The platform's per-user data folder for Theo, unless `THEO_DATA` says otherwise.
pub fn default_root() -> PathBuf {
    if let Ok(dir) = std::env::var("THEO_DATA") {
        if !dir.is_empty() {
            return PathBuf::from(dir);
        }
    }
    platform_root()
}

#[cfg(target_os = "macos")]
fn platform_root() -> PathBuf {
    home().join("Library/Application Support").join(APP_FOLDER)
}

#[cfg(target_os = "windows")]
fn platform_root() -> PathBuf {
    std::env::var_os("APPDATA").map(PathBuf::from).unwrap_or_else(|| home().join("AppData/Roaming")).join(APP_FOLDER)
}

#[cfg(all(unix, not(target_os = "macos")))]
fn platform_root() -> PathBuf {
    let base = std::env::var_os("XDG_DATA_HOME").map(PathBuf::from).filter(|p| p.is_absolute()).unwrap_or_else(|| home().join(".local/share"));
    base.join("theo-desktop")
}

pub fn home() -> PathBuf {
    #[cfg(windows)]
    {
        if let Some(p) = std::env::var_os("USERPROFILE") {
            return PathBuf::from(p);
        }
    }
    std::env::var_os("HOME").map(PathBuf::from).unwrap_or_else(|| PathBuf::from("."))
}

/// Every place under one root, named the way the Swift app names them.
#[derive(Clone, Debug)]
pub struct Paths {
    pub root: PathBuf,
}

impl Paths {
    pub fn new(root: impl Into<PathBuf>) -> Self {
        Self { root: root.into() }
    }
    pub fn bots_dir(&self) -> PathBuf { self.root.join("Bots") }
    pub fn bots_file(&self) -> PathBuf { self.bots_dir().join("bots.json") }
    pub fn groups_file(&self) -> PathBuf { self.bots_dir().join("groups.json") }
    pub fn routines_file(&self) -> PathBuf { self.bots_dir().join("routines.json") }
    pub fn runs_file(&self) -> PathBuf { self.bots_dir().join("runs.json") }
    pub fn usage_file(&self) -> PathBuf { self.bots_dir().join("usage.json") }
    pub fn chats_dir(&self) -> PathBuf { self.bots_dir().join("chats") }
    /// Bots run here: the folder that holds every bot's memory folder.
    pub fn memory_root(&self) -> PathBuf { self.bots_dir().join("memory") }
    pub fn memory_dir(&self, bot_id: &str) -> PathBuf { self.memory_root().join(bot_id) }
    pub fn memory_file(&self, bot_id: &str) -> PathBuf { self.memory_dir(bot_id).join("memory.md") }
    pub fn shared_skills_dir(&self) -> PathBuf { self.memory_root().join("skills") }
    pub fn skills_dir(&self, bot_id: &str) -> PathBuf { self.memory_dir(bot_id).join("skills") }
    pub fn projects_dir(&self) -> PathBuf { self.root.join("Projects") }
    pub fn hooks_dir(&self) -> PathBuf { self.root.join("Hooks") }
    pub fn settings_file(&self) -> PathBuf { self.root.join("settings.json") }
    pub fn engines_running_file(&self) -> PathBuf { self.root.join("engines-running.json") }
    pub fn logs_dir(&self) -> PathBuf { self.root.join("Logs") }
    pub fn control_inbox(&self) -> PathBuf { self.root.join("control-inbox") }
    pub fn control_outbox(&self) -> PathBuf { self.root.join("control-outbox") }
    pub fn pid_file(&self) -> PathBuf { self.root.join("theod.pid") }
    pub fn token_file(&self) -> PathBuf { self.root.join("gateway-token") }

    /// A chat's file. A colon is awkward in a file name, so "dm:a+b" is saved as "dm-a+b".
    pub fn chat_file(&self, conversation_id: &str) -> PathBuf {
        self.chats_dir().join(format!("{}.json", conversation_id.replace(':', "-")))
    }

    pub fn ensure(&self) -> std::io::Result<()> {
        for dir in [self.bots_dir(), self.chats_dir(), self.memory_root(), self.shared_skills_dir(), self.projects_dir(), self.hooks_dir(), self.logs_dir()] {
            std::fs::create_dir_all(dir)?;
        }
        Ok(())
    }
}

/// A path written the way Claude Code's permission rules want an absolute path: two slashes in front, forward slashes,
/// and on Windows the drive as a folder (`C:\Users\a` is `//c/Users/a`).
pub fn rule_path(path: &Path) -> String {
    let text = path.to_string_lossy().replace('\\', "/");
    let bytes = text.as_bytes();
    if bytes.len() >= 2 && bytes[1] == b':' && bytes[0].is_ascii_alphabetic() {
        let drive = (bytes[0] as char).to_ascii_lowercase();
        return format!("//{}{}", drive, &text[2..]);
    }
    if text.starts_with('/') { format!("/{}", text) } else { text }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn rule_paths() {
        assert_eq!(rule_path(Path::new("/Users/a/x")), "//Users/a/x");
        assert_eq!(rule_path(Path::new("C:\\Users\\a\\x")), "//c/Users/a/x");
    }
}
