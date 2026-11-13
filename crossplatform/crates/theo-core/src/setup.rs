//! First run: is Claude Code here and signed in, are git and the GitHub CLI here for coding runs. Read from the programs
//! themselves (`claude --version`, `claude auth status`, which prints JSON, `git --version`, `gh auth status`).

use crate::harness::Harness;
use serde_json::{json, Value};
use std::path::Path;
use std::time::Duration;

async fn run(program: &Path, args: &[&str], secs: u64) -> Option<(i32, String)> {
    // Its own process tree with no console window, like every engine Theo starts: a probe in Theo's own group would make
    // anything that ends an engine's group end Theo with it.
    let (code, stdout, stderr) = crate::engine::run_briefly(program, args, &crate::paths::home(), Duration::from_secs(secs)).await?;
    Some((code, stdout + &stderr))
}

/// Whether Windows has an entry called `name` in this user's programs to start at sign-in (HKCU\\...\\Run). Elsewhere: true.
/// An uninstall removes Theo's entry, so a reinstall puts it back when the setting is still on.
pub fn sign_in_entry_exists(name: &str) -> bool {
    #[cfg(windows)]
    unsafe {
        use windows_sys::Win32::System::Registry::*;
        let key: Vec<u16> = "Software\\Microsoft\\Windows\\CurrentVersion\\Run".encode_utf16().chain(Some(0)).collect();
        let value: Vec<u16> = name.encode_utf16().chain(Some(0)).collect();
        let mut bytes: u32 = 0;
        return RegGetValueW(HKEY_CURRENT_USER, key.as_ptr(), value.as_ptr(), RRF_RT_ANY, std::ptr::null_mut(), std::ptr::null_mut(), &mut bytes) == 0;
    }
    #[cfg(not(windows))]
    {
        let _ = name;
        true
    }
}

/// The official one-line installs for Claude Code, by platform.
pub fn claude_install_command() -> &'static str {
    if cfg!(windows) { "irm https://claude.ai/install.ps1 | iex" } else { "curl -fsSL https://claude.ai/install.sh | bash" }
}

pub async fn state(h: &Harness) -> Value {
    let claude = match h.executable("claude") {
        None => json!({"installed": false, "signedIn": false, "install": claude_install_command()}),
        Some(path) => {
            let version = run(&path, &["--version"], 20).await.map(|(_, t)| t.lines().next().unwrap_or("").trim().to_string()).unwrap_or_default();
            // `claude auth status` prints JSON; never pass on the account's email or ids.
            let status = run(&path, &["auth", "status"], 30).await;
            let parsed: Option<Value> = status.as_ref().and_then(|(_, t)| t.find('{').and_then(|i| serde_json::from_str(&t[i..t.rfind('}').map(|e| e + 1).unwrap_or(t.len())]).ok()));
            let signed_in = parsed.as_ref().and_then(|v| v["loggedIn"].as_bool()).unwrap_or(false);
            json!({"installed": true, "path": path, "version": version, "signedIn": signed_in,
                   "method": parsed.as_ref().and_then(|v| v["authMethod"].as_str().map(str::to_string)),
                   "plan": parsed.as_ref().and_then(|v| v["subscriptionType"].as_str().map(str::to_string)),
                   "install": claude_install_command(), "signIn": "claude auth login"})
        }
    };
    let git = match crate::engine::locate("git") {
        Some(p) => json!({"installed": true, "version": run(&p, &["--version"], 10).await.map(|(_, t)| t.trim().to_string()).unwrap_or_default()}),
        None => json!({"installed": false}),
    };
    let gh_path = h.settings.string("test.engine.gh").map(std::path::PathBuf::from).or_else(|| crate::engine::locate("gh"));
    let gh = match gh_path {
        Some(p) => json!({"installed": true, "signedIn": run(&p, &["auth", "status"], 15).await.map(|(code, _)| code == 0).unwrap_or(false)}),
        None => json!({"installed": false, "signedIn": false}),
    };
    let bots = h.with(|s| s.bots.iter().filter(|b| !b.primary).count());
    json!({"claude": claude, "git": git, "gh": gh, "bots": bots, "completed": h.settings.bool("setup.completed"), "os": std::env::consts::OS})
}

/// The command a setup button runs in a terminal. Claude Code and the GitHub CLI are named by the full path Theo found them at:
/// a terminal opened from Theo has Theo's own PATH, which doesn't yet have the folder an installer added since Theo started
/// (Claude Code's Windows installer adds `%USERPROFILE%\.local\bin`; npm's folder often isn't on PATH at all).
pub fn terminal_command(which: &str, claude: Option<&Path>, gh: Option<&Path>) -> Result<String, String> {
    let quoted = |path: &Path, rest: &str| {
        let text = path.to_string_lossy();
        if cfg!(windows) { format!("& '{}' {rest}", text.replace('\'', "''")) } else { format!("'{}' {rest}", text.replace('\'', "'\\''")) }
    };
    Ok(match which {
        "signin" => claude.map(|p| quoted(p, "auth login")).unwrap_or_else(|| "claude auth login".into()),
        "install" => claude_install_command().to_string(),
        "gh" => gh.map(|p| quoted(p, "auth login")).unwrap_or_else(|| "gh auth login".into()),
        _ => return Err("Unknown command.".into()),
    })
}

/// Opens the platform's terminal running one of the setup commands, for signing in or installing. Only these commands:
/// the window can't ask for anything else.
pub fn open_terminal(h: &Harness, which: &str) -> Result<(), String> {
    let claude = h.executable("claude").filter(|p| p.extension().map(|e| e != "py").unwrap_or(true));
    let gh = crate::engine::locate("gh");
    let command = terminal_command(which, claude.as_deref(), gh.as_deref())?;
    let command = command.as_str();
    let spawn = |program: &str, args: &[&str]| std::process::Command::new(program).args(args).spawn().map(|_| ()).map_err(|e| e.to_string());
    if cfg!(target_os = "macos") {
        let script = format!("tell application \"Terminal\" to do script \"{}\"\ntell application \"Terminal\" to activate", command.replace('"', "\\\""));
        spawn("osascript", &["-e", &script])
    } else if cfg!(windows) {
        spawn("cmd", &["/C", "start", "", "powershell", "-NoExit", "-Command", command])
    } else {
        let wrapped = format!("{command}; echo; read -p 'Done. Press Enter to close.' _");
        for term in ["x-terminal-emulator", "gnome-terminal", "konsole", "xfce4-terminal", "xterm"] {
            if crate::engine::locate(term).is_some() {
                return match term {
                    "gnome-terminal" => spawn(term, &["--", "bash", "-lc", &wrapped]),
                    _ => spawn(term, &["-e", "bash", "-lc", &wrapped]),
                };
            }
        }
        Err(format!("No terminal found. Run this in one: {command}"))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sign_in_names_the_program_theo_found() {
        let found = Path::new(if cfg!(windows) { r"C:\Users\O'Neil\.local\bin\claude.exe" } else { "/home/o'neil/.local/bin/claude" });
        let command = terminal_command("signin", Some(found), None).unwrap();
        if cfg!(windows) {
            assert_eq!(command, r"& 'C:\Users\O''Neil\.local\bin\claude.exe' auth login");
        } else {
            assert_eq!(command, "'/home/o'\\''neil/.local/bin/claude' auth login");
        }
        assert_eq!(terminal_command("signin", None, None).unwrap(), "claude auth login");
        assert_eq!(terminal_command("gh", None, None).unwrap(), "gh auth login");
        assert!(terminal_command("rm -rf", None, None).is_err());
    }
}
