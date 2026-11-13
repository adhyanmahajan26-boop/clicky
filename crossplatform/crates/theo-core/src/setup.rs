//! First run: which brains this computer can think with (an API key, or any of the agents: none is required), is Claude Code
//! here and signed in for coding runs, are git and the GitHub CLI here. Read from the programs themselves (`claude --version`,
//! `claude auth status`, which prints JSON, `git --version`, `gh auth status`, and each agent's own check in `brains`).

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
    {
        windows_sign_in::read_string(windows_sign_in::RUN_KEY, name).is_some()
    }
    #[cfg(not(windows))]
    {
        let _ = name;
        true
    }
}

/// Theo's start-at-sign-in entry on Windows, written by Theo itself for this user only. (The autostart plugin writes to
/// HKLM whenever the process can, which on an admin account with UAC off means every user of the PC gets Theo, and the
/// uninstaller, which only cleans this user's entry, leaves it behind. It also leaves the program path unquoted.)
#[cfg(windows)]
pub mod windows_sign_in {
    use windows_sys::Win32::System::Registry::*;

    pub const RUN_KEY: &str = "Software\\Microsoft\\Windows\\CurrentVersion\\Run";
    /// Task Manager's Startup apps switch: the first byte is even when the entry is allowed to run, odd when switched off.
    pub const APPROVED_KEY: &str = "Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\StartupApproved\\Run";

    fn wide(text: &str) -> Vec<u16> {
        text.encode_utf16().chain(Some(0)).collect()
    }

    pub fn read_string(key: &str, name: &str) -> Option<String> {
        let (key, name) = (wide(key), wide(name));
        let mut bytes: u32 = 0;
        unsafe {
            if RegGetValueW(HKEY_CURRENT_USER, key.as_ptr(), name.as_ptr(), RRF_RT_REG_SZ, std::ptr::null_mut(), std::ptr::null_mut(), &mut bytes) != 0 {
                return None;
            }
            let mut buffer = vec![0u16; (bytes as usize).div_ceil(2) + 1];
            let mut size = (buffer.len() * 2) as u32;
            if RegGetValueW(HKEY_CURRENT_USER, key.as_ptr(), name.as_ptr(), RRF_RT_REG_SZ, std::ptr::null_mut(), buffer.as_mut_ptr().cast(), &mut size) != 0 {
                return None;
            }
            let length = buffer.iter().position(|c| *c == 0).unwrap_or(buffer.len());
            Some(String::from_utf16_lossy(&buffer[..length]))
        }
    }

    fn switched_off_in_task_manager(name: &str) -> bool {
        let (key, name) = (wide(APPROVED_KEY), wide(name));
        let mut value = [0u8; 12];
        let mut size = value.len() as u32;
        let read = unsafe { RegGetValueW(HKEY_CURRENT_USER, key.as_ptr(), name.as_ptr(), RRF_RT_REG_BINARY, std::ptr::null_mut(), value.as_mut_ptr().cast(), &mut size) };
        read == 0 && size > 0 && value[0] % 2 == 1
    }

    /// On: the entry exists and Task Manager hasn't switched it off.
    pub fn is_on(name: &str) -> bool {
        read_string(RUN_KEY, name).is_some() && !switched_off_in_task_manager(name)
    }

    /// The command Windows runs: the program's full path in quotes (a user name can have spaces), then the arguments.
    pub fn command_for(program: &std::path::Path, args: &[&str]) -> String {
        let mut command = format!("\"{}\"", program.display());
        for arg in args {
            command.push(' ');
            command.push_str(arg);
        }
        command
    }

    pub fn set(name: &str, command: Option<&str>) -> Result<(), String> {
        let name_wide = wide(name);
        unsafe {
            let mut run: HKEY = std::ptr::null_mut();
            let status = RegCreateKeyExW(HKEY_CURRENT_USER, wide(RUN_KEY).as_ptr(), 0, std::ptr::null(), REG_OPTION_NON_VOLATILE, KEY_SET_VALUE, std::ptr::null(), &mut run, std::ptr::null_mut());
            if status != 0 {
                return Err(format!("Windows wouldn't open the sign-in list (error {status})"));
            }
            let status = match command {
                Some(command) => {
                    let value = wide(command);
                    RegSetValueExW(run, name_wide.as_ptr(), 0, REG_SZ, value.as_ptr().cast(), (value.len() * 2) as u32)
                }
                None => match RegDeleteValueW(run, name_wide.as_ptr()) {
                    2 => 0, // ERROR_FILE_NOT_FOUND: already gone
                    other => other,
                },
            };
            RegCloseKey(run);
            if status != 0 {
                return Err(format!("Windows wouldn't change the sign-in list (error {status})"));
            }
            // Turning it on in Theo also turns it back on in Task Manager's Startup apps; turning it off leaves no trace there.
            let mut approved: HKEY = std::ptr::null_mut();
            if RegOpenKeyExW(HKEY_CURRENT_USER, wide(APPROVED_KEY).as_ptr(), 0, KEY_SET_VALUE, &mut approved) == 0 {
                if command.is_some() {
                    let enabled = [2u8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0];
                    RegSetValueExW(approved, name_wide.as_ptr(), 0, REG_BINARY, enabled.as_ptr(), enabled.len() as u32);
                } else {
                    RegDeleteValueW(approved, name_wide.as_ptr());
                }
                RegCloseKey(approved);
            }
        }
        Ok(())
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
    let brains = crate::brains::inventory(h).await;
    let suggested = crate::brains::starting_brain(h, &brains).await.map(|(engine, model)| json!({"engine": engine, "model": model, "label": crate::brains::label(&engine)}));
    let any_ready = brains["anyReady"].clone();
    json!({"claude": claude, "git": git, "gh": gh, "bots": bots, "completed": h.settings.bool("setup.completed"), "os": std::env::consts::OS,
           "brains": brains, "suggested": suggested, "anyReady": any_ready})
}

/// At the end of setup: Theo was made on Claude Code before anything was checked. When Claude Code can't answer here and the
/// owner hasn't changed Theo's brain, Theo moves to the brain setup found (an agent that is signed in, or a key). Someone who
/// picked a brain for Theo keeps it.
pub async fn move_untouched_theo(h: &Harness) -> Option<(String, String)> {
    let theo = h.primary()?;
    let untouched = theo.provider == "claude" && theo.model == "claude-sonnet-5-5";
    if !untouched {
        return None;
    }
    let brains = crate::brains::inventory(h).await;
    let claude_ready = brains["agents"].as_array().into_iter().flatten().any(|agent| agent["id"] == "claude" && agent["ready"].as_bool() == Some(true));
    if claude_ready {
        return None;
    }
    let (engine, model) = crate::brains::starting_brain(h, &brains).await?;
    let mut moved = theo;
    moved.provider = engine.clone();
    moved.model = model.clone();
    moved.effort = None;
    h.save_bot(moved);
    Some((engine, model))
}

/// The command for one brain's Install or Sign in button (`install:<brain>` or `signin:<brain>`), with the program named by
/// the full path Theo found it at, for the same reason as `terminal_command`.
pub fn brain_terminal_command(which: &str, found_program: Option<&Path>) -> Result<String, String> {
    let (action, brain_id) = which.split_once(':').ok_or("Unknown command.")?;
    let brain = crate::brains::command_line_brain(brain_id).ok_or("Unknown command.")?;
    match action {
        "install" => Ok(if cfg!(windows) { brain.install_on_windows } else { brain.install_elsewhere }.to_string()),
        "signin" => {
            let arguments = brain.sign_in_arguments.join(" ");
            Ok(match found_program {
                Some(path) => {
                    let text = path.to_string_lossy();
                    let program = if cfg!(windows) { format!("& '{}'", text.replace('\'', "''")) } else { format!("'{}'", text.replace('\'', "'\\''")) };
                    format!("{program} {arguments}").trim_end().to_string()
                }
                None => format!("{} {arguments}", brain.programs[0]).trim_end().to_string(),
            })
        }
        _ => Err("Unknown command.".into()),
    }
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
    let command = if which.contains(':') {
        let brain_id = which.split_once(':').map(|(_, id)| id).unwrap_or_default();
        let found = crate::brains::command_line_brain(brain_id).and_then(|_| h.executable(brain_id)).filter(|p| p.extension().map(|e| e != "py").unwrap_or(true));
        brain_terminal_command(which, found.as_deref())?
    } else {
        terminal_command(which, claude.as_deref(), gh.as_deref())?
    };
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

    #[test]
    fn every_brain_has_an_install_and_a_sign_in_button() {
        for brain in crate::brains::COMMAND_LINE_BRAINS.iter() {
            assert!(!brain_terminal_command(&format!("install:{}", brain.id), None).unwrap().is_empty());
            assert!(brain_terminal_command(&format!("signin:{}", brain.id), None).unwrap().starts_with(brain.programs[0]));
        }
        assert_eq!(brain_terminal_command("signin:codex", None).unwrap(), "codex login");
        assert_eq!(brain_terminal_command("signin:gemini", None).unwrap(), "gemini");
        assert!(brain_terminal_command("install:rm -rf", None).is_err());
        assert!(brain_terminal_command("format:codex", None).is_err());
    }
}
