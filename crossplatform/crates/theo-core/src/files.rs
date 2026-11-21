//! Files a bot made, shown in the chat as attachment cards, and copies of them on the owner's Desktop or in Downloads (the Mac's
//! `BotFileCards.swift` and ClickyCore `BotFileOrder`). A bot writes the file in its memory folder and adds a line:
//!   [FILE: report.md]                    the file goes in the chat as a card (Open, Show in folder, Save to Desktop or Downloads).
//!   [SAVE FILE: report.pdf -> Desktop]   Vello copies it there, only on a turn the owner's own words started.
//! Bots can't write outside their memory folder, so this is how a file reaches the owner.

use crate::harness::Harness;
use crate::model::{Bot, ChatMessage};
use once_cell::sync::Lazy;
use regex::Regex;
use serde_json::json;
use std::path::{Path, PathBuf};

pub const MAXIMUM_ATTACHED_PER_REPLY: usize = 5;
pub const MAXIMUM_SAVED_PER_REPLY: usize = 5;

/// What a bot is told about files (ClickyCore `BotFileOrder.howTo`).
pub fn how_to(owner: &str) -> String {
    format!(
        "To give {owner} a file you made, write it in your memory folder and put a line [FILE: file name] in your reply: \
         Vello shows it in the chat as an attachment {owner} can open, drag out or save. \
         When {owner} asks for a file on the Desktop or in Downloads, add a line [SAVE FILE: file name -> Desktop] (or -> Downloads): \
         Vello copies it there from your memory folder, so don't hand that to Pointer Assistant or tell {owner} to copy it by hand. \
         A PDF you asked for with [PDF:] is in your memory folder too, under its own name ending .pdf. \
         Say a file is there only once Vello's line says so."
    )
}

/// Where a copy can go. Only these two: a bot never picks any other folder on the owner's computer.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Place {
    Desktop,
    Downloads,
}

impl Place {
    pub const ALL: [Place; 2] = [Place::Desktop, Place::Downloads];

    pub fn folder_name(self) -> &'static str {
        match self {
            Place::Desktop => "Desktop",
            Place::Downloads => "Downloads",
        }
    }

    /// "Desktop", "my desktop", "the Downloads folder", "downloads".
    pub fn named(words: &str) -> Option<Place> {
        let lowered = words.to_lowercase();
        if lowered.contains("desktop") { return Some(Place::Desktop); }
        if lowered.contains("download") { return Some(Place::Downloads); }
        None
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SaveOrder {
    pub file: String,
    pub place: Place,
}

static ATTACH_TAG: Lazy<Regex> = Lazy::new(|| Regex::new(r"(?i)\[\s*FILE\s*:\s*([^\]\n]{1,240}?)\s*\]").unwrap());
static SAVE_TAG: Lazy<Regex> = Lazy::new(|| Regex::new(r"(?i)\[\s*SAVE\s+FILE\s*:\s*([^\]\n]{1,280}?)\s*\]").unwrap());

/// The reply without its [FILE:] and [SAVE FILE:] lines, the files to show (at most five) and the copies asked for (at most five).
pub fn extract(text: &str) -> (String, Vec<String>, Vec<SaveOrder>) {
    if !ATTACH_TAG.is_match(text) && !SAVE_TAG.is_match(text) { return (text.to_string(), vec![], vec![]); }
    let saves: Vec<SaveOrder> = SAVE_TAG.captures_iter(text).filter_map(|c| save_order(&c[1])).take(MAXIMUM_SAVED_PER_REPLY).collect();
    let without_saves = SAVE_TAG.replace_all(text, "").to_string();
    let attached: Vec<String> = ATTACH_TAG.captures_iter(&without_saves).map(|c| c[1].trim().to_string()).filter(|f| !f.is_empty()).take(MAXIMUM_ATTACHED_PER_REPLY).collect();
    let without = ATTACH_TAG.replace_all(&without_saves, "");
    // A line that held only a tag goes with it.
    let mut lines: Vec<&str> = vec![];
    for line in without.lines() {
        if line.trim().is_empty() && lines.last().map(|l: &&str| l.trim().is_empty()).unwrap_or(true) { continue; }
        lines.push(line);
    }
    while lines.last().map(|l| l.trim().is_empty()).unwrap_or(false) { lines.pop(); }
    (lines.join("\n"), attached, saves)
}

/// "report.pdf -> Desktop", "report.pdf to Downloads", "report.pdf: desktop". None without a place Vello knows.
fn save_order(body: &str) -> Option<SaveOrder> {
    // Lower case only to find " to " in "Report TO Desktop"; the original is kept when lowering would change byte offsets.
    let lowered = body.to_lowercase();
    let haystack = if lowered.len() == body.len() { lowered.as_str() } else { body };
    for separator in ["->", "→", "=>", " to ", ":"] {
        let Some(at) = haystack.rfind(separator) else { continue };
        let file = body[..at].trim();
        let place_words = body[at + separator.len()..].trim();
        if let (false, Some(place)) = (file.is_empty(), Place::named(place_words)) {
            return Some(SaveOrder { file: file.to_string(), place });
        }
    }
    None
}

/// A name that isn't taken in the folder yet: "report.pdf", then "report 2.pdf", "report 3.pdf". Nothing already there is replaced.
pub fn free_name(name: &str, is_taken: impl Fn(&str) -> bool) -> String {
    if !is_taken(name) { return name.to_string(); }
    let path = Path::new(name);
    let extension = path.extension().map(|e| e.to_string_lossy().to_string()).unwrap_or_default();
    let stem = if extension.is_empty() { name.to_string() } else { name[..name.len() - extension.len() - 1].to_string() };
    for number in 2..1000 {
        let candidate = if extension.is_empty() { format!("{stem} {number}") } else { format!("{stem} {number}.{extension}") };
        if !is_taken(&candidate) { return candidate; }
    }
    let tail = &uuid::Uuid::new_v4().simple().to_string()[..8];
    if extension.is_empty() { format!("{stem} {tail}") } else { format!("{stem} {tail}.{extension}") }
}

/// The owner's Desktop or Downloads. A test profile gets folders inside its own data folder, so tests never touch the real ones.
pub fn folder(h: &Harness, place: Place) -> PathBuf {
    if h.settings.is_test { return h.paths.root.join("test-home").join(place.folder_name()); }
    user_folder(place)
}

#[cfg(windows)]
fn user_folder(place: Place) -> PathBuf {
    // Desktop and Downloads can be moved (OneDrive does it to the Desktop), and Explorer keeps where in the registry.
    let value = match place {
        Place::Desktop => "Desktop",
        Place::Downloads => "{374DE290-123F-4565-9164-39C4925E467B}",
    };
    let read = |key: &str| crate::setup::windows_sign_in::read_string(key, value).map(PathBuf::from).filter(|p| p.is_absolute());
    read("Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\User Shell Folders")
        .or_else(|| read("Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Shell Folders"))
        .unwrap_or_else(|| crate::paths::home().join(place.folder_name()))
}

#[cfg(target_os = "macos")]
fn user_folder(place: Place) -> PathBuf { crate::paths::home().join(place.folder_name()) }

#[cfg(all(unix, not(target_os = "macos")))]
fn user_folder(place: Place) -> PathBuf {
    // ~/.config/user-dirs.dirs names them on most desktops, in the owner's own language: XDG_DESKTOP_DIR="$HOME/Schreibtisch".
    let home = crate::paths::home();
    let config = std::env::var_os("XDG_CONFIG_HOME").map(PathBuf::from).filter(|p| p.is_absolute()).unwrap_or_else(|| home.join(".config"));
    let key = match place { Place::Desktop => "XDG_DESKTOP_DIR", Place::Downloads => "XDG_DOWNLOAD_DIR" };
    std::fs::read_to_string(config.join("user-dirs.dirs")).ok()
        .and_then(|text| xdg_user_dir(&text, key, &home))
        .unwrap_or_else(|| home.join(place.folder_name()))
}

/// One folder from a user-dirs.dirs file. Only "$HOME/…" or an absolute path; a folder that is the home folder itself means it's unset.
#[cfg_attr(any(windows, target_os = "macos"), allow(dead_code))]
fn xdg_user_dir(text: &str, key: &str, home: &Path) -> Option<PathBuf> {
    let line = text.lines().map(str::trim).find(|l| l.starts_with(key) && l[key.len()..].trim_start().starts_with('='))?;
    let value = line.split_once('=')?.1.trim().trim_matches('"');
    let path = if let Some(rest) = value.strip_prefix("$HOME") { home.join(rest.trim_start_matches('/')) } else { PathBuf::from(value) };
    (path.is_absolute() && path != home).then_some(path)
}

/// Copies a file Vello made (inside its data folder) into the Desktop or Downloads, under a name that isn't taken there yet.
pub fn save_copy(h: &Harness, file: &Path, place: Place) -> Result<PathBuf, String> {
    let source = inside_data_folder(h, file).ok_or_else(|| "Vello only copies files it or its bots made.".to_string())?;
    let destination = folder(h, place);
    std::fs::create_dir_all(&destination).map_err(|e| format!("Your {} folder couldn't be opened: {e}", place.folder_name()))?;
    let name = source.file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_else(|| "file".into());
    let name = free_name(&name, |candidate| destination.join(candidate).exists());
    let copy = destination.join(name);
    std::fs::copy(&source, &copy).map_err(|e| e.to_string())?;
    Ok(copy)
}

/// The file, only if it's a file inside the bots' memory folders (what a bot wrote, a PDF Vello made), never Vello's settings or sign-ins.
fn inside_data_folder(h: &Harness, file: &Path) -> Option<PathBuf> {
    let wanted = std::fs::canonicalize(file).ok()?;
    let root = std::fs::canonicalize(h.paths.memory_root()).ok()?;
    (wanted.starts_with(&root) && wanted.is_file()).then_some(wanted)
}

/// Shows the file selected in Explorer, Finder or the file manager. Only a file Vello made, or a copy it put on the Desktop or in
/// Downloads. A test profile records it in `Logs/opened.log` instead.
pub fn reveal(h: &Harness, path: &str) -> Result<(), String> {
    let wanted = std::fs::canonicalize(path).map_err(|_| "That file isn't there any more.".to_string())?;
    let mut allowed: Vec<PathBuf> = vec![h.paths.root.clone()];
    allowed.extend(Place::ALL.iter().map(|p| folder(h, *p)));
    let inside = allowed.iter().filter_map(|a| std::fs::canonicalize(a).ok()).any(|a| wanted.starts_with(&a));
    if !inside || !wanted.is_file() { return Err("Vello only shows files it made.".into()); }
    if h.settings.is_test {
        let logs = h.paths.logs_dir();
        let _ = std::fs::create_dir_all(&logs);
        use std::io::Write;
        if let Ok(mut file) = std::fs::OpenOptions::new().create(true).append(true).open(logs.join("opened.log")) {
            let _ = writeln!(file, "reveal:{}", wanted.to_string_lossy());
        }
        return Ok(());
    }
    let shown = wanted.to_string_lossy().to_string();
    #[cfg(windows)]
    let mut command = {
        use std::os::windows::process::CommandExt;
        // The path canonicalize gives starts with \\?\, which Explorer doesn't take; and /select, wants the path quoted after it.
        let shown = shown.trim_start_matches(r"\\?\").to_string();
        let mut command = std::process::Command::new("explorer");
        command.raw_arg(format!("/select,\"{shown}\""));
        command
    };
    #[cfg(target_os = "macos")]
    let mut command = {
        let mut command = std::process::Command::new("open");
        command.args(["-R", &shown]);
        command
    };
    #[cfg(all(unix, not(target_os = "macos")))]
    let mut command = {
        // No one way to select a file across Linux file managers: open the folder it's in.
        let parent = wanted.parent().map(|p| p.to_string_lossy().to_string()).unwrap_or(shown);
        let mut command = std::process::Command::new("xdg-open");
        command.arg(parent);
        command
    };
    command.stdin(std::process::Stdio::null()).stdout(std::process::Stdio::null()).stderr(std::process::Stdio::null());
    command.spawn().map(|_| ()).map_err(|e| e.to_string())
}

/// The chat card for a file: `file:{"path", "name", "bot", "source"?, "place"?}`. `source` is the file in Theo's folder a copy was made
/// from, which is what Open opens.
pub fn card(path: &Path, bot: &Bot, source: Option<&Path>, place: Option<Place>) -> String {
    let name = path.file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_default();
    let mut value = json!({"path": path.to_string_lossy(), "name": name, "bot": bot.id});
    if let Some(source) = source { value["source"] = json!(source.to_string_lossy()); }
    if let Some(place) = place { value["place"] = json!(place.folder_name()); }
    format!("file:{value}")
}

/// After a turn: each file the reply shared as a card, and each copy it asked for made (only on the owner's own turn) or why not.
pub fn carry_out_for_turn(h: &Harness, bot: &Bot, attached: &[String], saves: &[SaveOrder], room: &str, exchange: Option<String>, from_owner: bool) {
    let folder = h.paths.memory_dir(&bot.id);
    for name in attached {
        let message = match crate::pdf::file_named(name, &folder) {
            Some(file) => {
                let shown = file.file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_default();
                let mut m = ChatMessage::note(format!("{} shared {shown}.", bot.name));
                m.card = Some(card(&file, bot, None, None));
                m
            }
            None => ChatMessage::note(format!("{} wanted to share {name}, but there's no file by that name in its memory folder.", bot.name)),
        };
        h.post(message.with_exchange(exchange.clone()), room);
    }
    for save in saves {
        let place = save.place.folder_name();
        let message = if !from_owner {
            ChatMessage::note(format!("{} asked to copy {} to your {place}, but you didn't ask for that on this turn, so Vello didn't copy it.", bot.name, save.file))
        } else {
            match crate::pdf::file_named(&save.file, &folder) {
                None => ChatMessage::note(format!("Vello couldn't copy {} to your {place}: there's no file by that name in {}'s memory folder.", save.file, bot.name)),
                Some(file) => match save_copy(h, &file, save.place) {
                    Ok(copy) => {
                        let shown = copy.file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_default();
                        let mut m = ChatMessage::note(format!("Vello put {shown} on your {place}."));
                        m.card = Some(card(&copy, bot, Some(&file), Some(save.place)));
                        m
                    }
                    Err(problem) => ChatMessage::note(format!("Vello couldn't copy {} to your {place}: {problem}", save.file)),
                },
            }
        };
        h.post(message.with_exchange(exchange.clone()), room);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn takes_file_and_save_lines_out_and_keeps_the_words() {
        let (text, attached, saves) = extract("Here's the report.\n[FILE: report.md]\n[SAVE FILE: report.pdf -> Desktop]\nAnything else?");
        assert_eq!(attached, vec!["report.md"]);
        assert_eq!(saves, vec![SaveOrder { file: "report.pdf".into(), place: Place::Desktop }]);
        assert_eq!(text, "Here's the report.\n\nAnything else?");
    }

    #[test]
    fn save_lines_take_the_usual_ways_of_naming_the_place() {
        let text = "[SAVE FILE: a.pdf -> Downloads]\n[SAVE FILE: b.pdf to my Desktop]\n[SAVE FILE: c.pdf → desktop]\n[SAVE FILE: d.pdf: the downloads folder]\n[SAVE FILE: e.pdf -> Documents]\n[SAVE FILE: how to sell.pdf -> Desktop]";
        let (_, _, saves) = extract(text);
        let files: Vec<&str> = saves.iter().map(|s| s.file.as_str()).collect();
        assert_eq!(files, vec!["a.pdf", "b.pdf", "c.pdf", "d.pdf", "how to sell.pdf"]);
        assert_eq!(saves[0].place, Place::Downloads);
        assert_eq!(saves[1].place, Place::Desktop);
        assert_eq!(saves[3].place, Place::Downloads);
    }

    #[test]
    fn a_pdf_tag_is_not_a_file_tag_and_five_at_most() {
        let (text, attached, _) = extract("[PDF: x.md]");
        assert!(attached.is_empty());
        assert_eq!(text, "[PDF: x.md]");
        let many: Vec<String> = (1..=8).map(|n| format!("[FILE: f{n}.md]")).collect();
        assert_eq!(extract(&many.join("\n")).1.len(), 5);
    }

    #[test]
    fn a_copy_never_replaces_whats_there() {
        let taken = ["report.pdf", "report 2.pdf", "notes"];
        assert_eq!(free_name("report.pdf", |c| taken.contains(&c)), "report 3.pdf");
        assert_eq!(free_name("new.pdf", |c| taken.contains(&c)), "new.pdf");
        assert_eq!(free_name("notes", |c| taken.contains(&c)), "notes 2");
    }

    // Unix paths: on Windows "/home/sam" isn't a whole path, and Windows reads its folders from the registry instead.
    #[cfg(unix)]
    #[test]
    fn user_dirs_are_read_from_the_owners_own_file() {
        let home = Path::new("/home/sam");
        let text = "# comment\nXDG_DESKTOP_DIR=\"$HOME/Schreibtisch\"\nXDG_DOWNLOAD_DIR=\"$HOME/\"\n";
        assert_eq!(xdg_user_dir(text, "XDG_DESKTOP_DIR", home), Some(PathBuf::from("/home/sam/Schreibtisch")));
        assert_eq!(xdg_user_dir(text, "XDG_DOWNLOAD_DIR", home), None);
        assert_eq!(xdg_user_dir(text, "XDG_MUSIC_DIR", home), None);
    }

    #[test]
    fn the_how_to_names_both_lines_and_the_owner() {
        let text = how_to("Sam");
        assert!(text.contains("[FILE: file name]") && text.contains("[SAVE FILE: file name -> Desktop]") && text.contains("Sam"));
    }
}
