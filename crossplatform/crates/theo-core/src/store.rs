//! Reading and writing Theo's files without losing them.
//!
//! Writes go to a temporary file that's then renamed over the old one, so a crash leaves either the old file or the new one.
//! A file that's there but can't be read (cut short, damaged by hand, written by a newer build) is moved aside, never
//! overwritten, and the longest readable start of it or the last copy that read fine is used instead.

use serde::de::DeserializeOwned;
use std::collections::HashSet;
use std::path::{Path, PathBuf};
use std::sync::Mutex;

pub fn write_atomic(path: &Path, data: &[u8]) -> std::io::Result<()> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    let tmp = path.with_extension(format!("tmp-{}", uuid::Uuid::new_v4().simple()));
    std::fs::write(&tmp, data)?;
    #[cfg(windows)]
    {
        // Rename over an existing file can fail briefly on Windows while something else (an antivirus scan) has it open.
        for attempt in 0..20 {
            match std::fs::rename(&tmp, path) {
                Ok(()) => return Ok(()),
                Err(e) if attempt < 19 => {
                    let _ = e;
                    std::thread::sleep(std::time::Duration::from_millis(25));
                }
                Err(e) => {
                    let _ = std::fs::remove_file(&tmp);
                    return Err(e);
                }
            }
        }
        Ok(())
    }
    #[cfg(not(windows))]
    {
        std::fs::rename(&tmp, path)
    }
}

pub fn last_good(path: &Path) -> PathBuf {
    let mut name = path.file_name().unwrap_or_default().to_os_string();
    name.push(".lastgood");
    path.with_file_name(name)
}

/// What went wrong while loading, said once to the owner.
pub struct LoadProblems {
    kept: Mutex<HashSet<PathBuf>>,
    pub problems: Mutex<Vec<String>>,
}

impl Default for LoadProblems {
    fn default() -> Self { Self { kept: Mutex::new(HashSet::new()), problems: Mutex::new(vec![]) } }
}

impl LoadProblems {
    fn keep_good(&self, data: &[u8], file: &Path) {
        let mut kept = self.kept.lock().unwrap();
        if kept.insert(file.to_path_buf()) {
            let _ = write_atomic(&last_good(file), data);
        }
    }
    fn note(&self, line: String) {
        eprintln!("[store] {line}");
        self.problems.lock().unwrap().push(line);
    }

    /// The decoded file; None when there's no file, or it was unreadable and nothing could stand in for it.
    pub fn load<T: DeserializeOwned>(&self, file: &Path, what: &str) -> Option<T> {
        let data = std::fs::read(file).ok()?;
        if let Ok(value) = serde_json::from_slice::<T>(&data) {
            self.keep_good(&data, file);
            return Some(value);
        }
        let stamp = chrono::Utc::now().format("%Y-%m-%dT%H%M%SZ");
        let aside = file.with_file_name(format!("{}.unreadable-{}", file.file_name().unwrap_or_default().to_string_lossy(), stamp));
        let _ = std::fs::rename(file, &aside);
        let aside_name = aside.file_name().unwrap_or_default().to_string_lossy().to_string();
        let rescued = readable_part::<T>(&data);
        let old = std::fs::read(last_good(file)).ok().and_then(|d| serde_json::from_slice::<T>(&d).ok().map(|v| (d, v)));
        if let Some((rescued_data, value)) = rescued {
            if rescued_data.len() >= old.as_ref().map(|o| o.0.len()).unwrap_or(0) {
                let _ = write_atomic(file, &rescued_data);
                self.note(format!("Theo couldn't read all of {what}, so it kept everything that could still be read. The damaged file is kept as {aside_name}."));
                return Some(value);
            }
        }
        if let Some((good, value)) = old {
            let _ = write_atomic(file, &good);
            self.note(format!("Theo couldn't read {what}, so it used the last copy that read fine. The unreadable file is kept as {aside_name}."));
            return Some(value);
        }
        self.note(format!("Theo couldn't read {what} and had no earlier copy to use. Nothing was deleted: the file is kept as {aside_name}."));
        None
    }
}

/// The longest start of damaged JSON that still decodes: cut after a whole record in a list, with every bracket still open
/// closed. Tries the latest cuts first, 64 at most.
pub fn readable_part<T: DeserializeOwned>(data: &[u8]) -> Option<(Vec<u8>, T)> {
    let mut stack: Vec<u8> = vec![];
    let mut in_string = false;
    let mut escaped = false;
    let mut cuts: Vec<(usize, Vec<u8>)> = vec![];
    for (index, &byte) in data.iter().enumerate() {
        if in_string {
            if escaped { escaped = false } else if byte == b'\\' { escaped = true } else if byte == b'"' { in_string = false }
            continue;
        }
        match byte {
            b'"' => in_string = true,
            b'[' | b'{' => stack.push(byte),
            b']' | b'}' => {
                stack.pop();
                // Just closed a record that sits inside a list: everything up to here can stand.
                if stack.last() == Some(&b'[') {
                    let closers: Vec<u8> = stack.iter().rev().map(|&c| if c == b'[' { b']' } else { b'}' }).collect();
                    cuts.push((index + 1, closers));
                }
            }
            _ => {}
        }
    }
    for (end, closers) in cuts.into_iter().rev().take(64) {
        let mut candidate = data[..end].to_vec();
        candidate.extend_from_slice(&closers);
        if let Ok(value) = serde_json::from_slice::<T>(&candidate) {
            return Some((candidate, value));
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::Conversation;

    #[test]
    fn rescues_a_chat_cut_short() {
        let full = r#"{"messages":[{"id":"1","author":"user","text":"a","at":"2026-01-01T00:00:00Z"},{"id":"2","author":"x","text":"b","at":"2026-01-01T00:00:00Z"},{"id":"3","au"#;
        let (_, chat): (Vec<u8>, Conversation) = readable_part(full.as_bytes()).unwrap();
        assert_eq!(chat.messages.len(), 2);
    }

    #[test]
    fn damaged_file_uses_last_good() {
        let dir = tempfile::tempdir().unwrap();
        let file = dir.path().join("bots.json");
        std::fs::write(&file, b"[1,2,3]").unwrap();
        let problems = LoadProblems::default();
        let v: Vec<i32> = problems.load(&file, "x").unwrap();
        assert_eq!(v, vec![1, 2, 3]);
        std::fs::write(&file, b"garbage{{{").unwrap();
        let v: Vec<i32> = problems.load(&file, "x").unwrap();
        assert_eq!(v, vec![1, 2, 3]);
        assert!(std::fs::read_dir(dir.path()).unwrap().any(|e| e.unwrap().file_name().to_string_lossy().contains("unreadable")));
    }
}
