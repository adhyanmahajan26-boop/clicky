//! Finding the browser a VM screen runs, and how it's started.
//!
//! Google Chrome first, else Microsoft Edge (on every Windows 10 and 11), else Chromium on Linux, each looked for in the
//! usual install folders and on PATH; never a fixed user's path. `vmScreens.browser` in settings.json names another
//! Chromium-based browser by its full path.
//!
//! Each screen is its own browser process with its own profile under Vello's data folder, made fresh each time (no
//! logins, no history kept), started headless: nothing shows on any monitor, in the taskbar or in Alt+Tab, and nothing
//! needs a driver or administrator rights. An off-screen window was the other choice; it shows in the taskbar and Alt+Tab
//! on Windows and needs a display, so headless it is. The page is driven over the DevTools protocol on a port the browser
//! picks itself (`--remote-debugging-port=0`, read back from `DevToolsActivePort`), on 127.0.0.1 only.

use std::path::{Path, PathBuf};

/// The window a screen's pages are laid out in, so a page reads as it would on a laptop.
pub const SCREEN_WIDTH: u32 = 1280;
pub const SCREEN_HEIGHT: u32 = 800;

#[derive(Clone, Debug, PartialEq)]
pub struct Browser {
    pub path: PathBuf,
    /// "Google Chrome", "Microsoft Edge", "Chromium" or the file's own name for one the owner named.
    pub name: String,
}

/// Where each browser usually is on this platform, in the order they're tried.
pub fn candidates() -> Vec<(PathBuf, &'static str)> {
    let mut found: Vec<(PathBuf, &'static str)> = vec![];
    #[cfg(windows)]
    {
        let folders: Vec<PathBuf> = ["ProgramFiles", "ProgramFiles(x86)", "LOCALAPPDATA", "ProgramW6432"].iter().filter_map(|name| std::env::var_os(name)).map(PathBuf::from).collect();
        for folder in &folders {
            found.push((folder.join("Google").join("Chrome").join("Application").join("chrome.exe"), "Google Chrome"));
        }
        for folder in &folders {
            found.push((folder.join("Microsoft").join("Edge").join("Application").join("msedge.exe"), "Microsoft Edge"));
        }
        for folder in &folders {
            found.push((folder.join("Chromium").join("Application").join("chrome.exe"), "Chromium"));
        }
    }
    #[cfg(target_os = "macos")]
    {
        let home = crate::paths::home();
        for root in [PathBuf::from("/Applications"), home.join("Applications")] {
            found.push((root.join("Google Chrome.app/Contents/MacOS/Google Chrome"), "Google Chrome"));
            found.push((root.join("Microsoft Edge.app/Contents/MacOS/Microsoft Edge"), "Microsoft Edge"));
            found.push((root.join("Chromium.app/Contents/MacOS/Chromium"), "Chromium"));
        }
    }
    #[cfg(all(unix, not(target_os = "macos")))]
    {
        for (program, name) in [
            ("google-chrome", "Google Chrome"),
            ("google-chrome-stable", "Google Chrome"),
            ("microsoft-edge", "Microsoft Edge"),
            ("microsoft-edge-stable", "Microsoft Edge"),
            ("chromium", "Chromium"),
            ("chromium-browser", "Chromium"),
        ] {
            if let Some(path) = on_path(program) {
                found.push((path, name));
            }
            for folder in ["/usr/bin", "/usr/local/bin", "/snap/bin", "/opt/google/chrome", "/opt/microsoft/msedge"] {
                found.push((Path::new(folder).join(program), name));
            }
        }
        found.push((PathBuf::from("/opt/google/chrome/chrome"), "Google Chrome"));
        found.push((PathBuf::from("/opt/microsoft/msedge/msedge"), "Microsoft Edge"));
    }
    found
}

#[cfg(all(unix, not(target_os = "macos")))]
fn on_path(program: &str) -> Option<PathBuf> {
    std::env::var_os("PATH").and_then(|path| std::env::split_paths(&path).map(|folder| folder.join(program)).find(|candidate| candidate.is_file()))
}

/// The browser this computer has, or the one the owner named.
pub fn find(named: Option<&str>) -> Option<Browser> {
    if let Some(named) = named.map(str::trim).filter(|named| !named.is_empty()) {
        let path = PathBuf::from(named);
        if path.is_file() {
            let name = path.file_stem().map(|stem| stem.to_string_lossy().to_string()).unwrap_or_else(|| "Browser".into());
            return Some(Browser { path, name });
        }
    }
    candidates().into_iter().find(|(path, _)| path.is_file()).map(|(path, name)| Browser { path, name: name.to_string() })
}

/// The command line for one screen's browser. `as_root`: Chrome won't start as root on Linux without its sandbox off (a
/// server or a container); a person's own account keeps it on.
pub fn launch_arguments(profile_folder: &Path, as_root: bool) -> Vec<String> {
    let mut arguments: Vec<String> = vec![
        "--headless=new".into(),
        "--remote-debugging-port=0".into(),
        "--remote-debugging-address=127.0.0.1".into(),
        format!("--user-data-dir={}", profile_folder.to_string_lossy()),
        format!("--window-size={SCREEN_WIDTH},{SCREEN_HEIGHT}"),
        "--no-first-run".into(),
        "--no-default-browser-check".into(),
        "--disable-extensions".into(),
        "--disable-sync".into(),
        "--disable-background-networking".into(),
        "--disable-component-update".into(),
        "--disable-default-apps".into(),
        "--disable-notifications".into(),
        "--disable-features=Translate,MediaRouter,OptimizationHints".into(),
        "--mute-audio".into(),
        "--no-pings".into(),
        "--password-store=basic".into(),
        "--use-mock-keychain".into(),
    ];
    if as_root {
        arguments.push("--no-sandbox".into());
    }
    arguments.push("about:blank".into());
    arguments
}

/// Whether Vello itself runs as root (Linux and Mac only; never on Windows).
pub fn running_as_root() -> bool {
    #[cfg(unix)]
    {
        // Safe: geteuid only reads this process's own user id.
        unsafe { libc::geteuid() == 0 }
    }
    #[cfg(not(unix))]
    {
        false
    }
}

/// The port and browser address a browser started with `--remote-debugging-port=0` wrote in its profile.
pub fn read_devtools_port(contents: &str) -> Option<(u16, String)> {
    let mut lines = contents.lines();
    let port = lines.next()?.trim().parse::<u16>().ok().filter(|port| *port > 0)?;
    let path = lines.next().map(str::trim).unwrap_or("").to_string();
    Some((port, path))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_screen_starts_headless_on_its_own_profile_and_a_port_it_picks() {
        let arguments = launch_arguments(Path::new("/data/VMScreens/screen-1"), false);
        assert!(arguments.contains(&"--headless=new".to_string()));
        assert!(arguments.contains(&"--remote-debugging-port=0".to_string()));
        assert!(arguments.contains(&"--remote-debugging-address=127.0.0.1".to_string()));
        assert!(arguments.contains(&"--user-data-dir=/data/VMScreens/screen-1".to_string()));
        assert!(arguments.contains(&"--window-size=1280,800".to_string()));
        assert!(!arguments.contains(&"--no-sandbox".to_string()), "a person's own account keeps the sandbox");
        assert!(launch_arguments(Path::new("/x"), true).contains(&"--no-sandbox".to_string()));
        assert_eq!(arguments.last().map(String::as_str), Some("about:blank"));
    }

    #[test]
    fn devtools_port_is_read_back() {
        assert_eq!(read_devtools_port("53211\n/devtools/browser/abc-def\n"), Some((53211, "/devtools/browser/abc-def".into())));
        assert_eq!(read_devtools_port("0\n"), None);
        assert_eq!(read_devtools_port(""), None);
        assert_eq!(read_devtools_port("nope"), None);
    }

    #[test]
    fn a_named_browser_wins_when_it_is_there() {
        let folder = tempfile::tempdir().unwrap();
        let file = folder.path().join("brave.exe");
        std::fs::write(&file, b"").unwrap();
        let found = find(Some(&file.to_string_lossy())).unwrap();
        assert_eq!(found.path, file);
        assert_eq!(found.name, "brave");
        // A name that isn't there falls back to looking.
        assert_eq!(find(Some("/nowhere/at/all")), find(None));
    }
}
