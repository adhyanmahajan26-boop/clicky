//! The desktop app's half of in-app updates (the rules, the check and the checked download are theo_core::update). Theo looks
//! for a newer build 20 seconds after it starts and every 6 hours, never installing by itself. The Update button
//! (`install_update`) downloads the build, checks it against the release's SHA256SUMS, and then:
//!
//! - Windows, installed for this user (the setup .exe): writes a small PowerShell script that waits for Theo to quit, runs the
//!   new installer silently over the same folder (`/S /UPDATE /D=…`), notes the build for install.ps1, and opens Theo again.
//! - Linux, an AppImage: swaps the file in place and opens the new one once Theo has quit.
//! - Anything else (the .msi for everyone, the .deb, a build made by hand): opens the releases page and says why.
//!
//! A test profile never replaces the app: the engine records the install in Logs/opened.log instead.

use std::sync::Arc;
use theo_core::update::{self, InstallKind};
use theo_core::Harness;

/// At start: says whether an update Theo quit for went through, then checks quietly now and then.
pub fn start(harness: Arc<Harness>) {
    update::after_launch(&harness);
    if harness.settings.is_test {
        return;
    }
    tauri::async_runtime::spawn(async move {
        tokio::time::sleep(update::FIRST_CHECK_DELAY).await;
        loop {
            update::check(&harness, true).await;
            tokio::time::sleep(update::CHECK_INTERVAL).await;
        }
    });
}

/// What the person is told when this copy can't put the new build in place itself; the releases page opens with it.
fn cannot_install_here(kind: &InstallKind, build: Option<u64>) -> Option<String> {
    let which = build.map(|b| format!("build {b}")).unwrap_or_else(|| "the new build".into());
    match kind {
        InstallKind::WindowsForThisUser { .. } | InstallKind::AppImage { .. } => None,
        InstallKind::WindowsForEveryone => Some(format!(
            "This Vello was installed for everyone on this PC from the .msi, so updating it needs an administrator. The releases page is open: run {which}'s .msi, or its setup .exe to install Vello just for you."
        )),
        InstallKind::Elsewhere => Some(if cfg!(target_os = "linux") {
            format!("This Vello came from the .deb package (or was built by hand), so it doesn't replace itself. The releases page is open: install {which}'s .deb with apt, or use the AppImage.")
        } else {
            format!("This copy of Vello wasn't put here by Vello's installer, so it doesn't replace itself. The releases page is open: {which} is there.")
        }),
    }
}

/// The Update button with a newer build waiting: download, check, hand over to the installer, quit.
#[tauri::command]
pub async fn install_update(app: tauri::AppHandle, harness: tauri::State<'_, Arc<Harness>>) -> Result<serde_json::Value, String> {
    let h = harness.inner().clone();
    if h.settings.is_test {
        return update::control(&h, &serde_json::json!({"action": "install"})).await;
    }
    let kind = update::this_install_kind();
    let waiting = update::report(&h)["available"]["build"].as_u64();
    if let Some(message) = cannot_install_here(&kind, waiting) {
        let _ = update::control(&h, &serde_json::json!({"action": "openPage"})).await;
        update::install_failed(&message);
        return Err(message);
    }
    let (installer, release) = update::download(&h).await?;
    let handed_over = match &kind {
        InstallKind::WindowsForThisUser { folder } => run_windows_installer(&h, &installer, folder, release.build),
        InstallKind::AppImage { file } => update::replace_appimage(&installer, file, release.build).and_then(|()| relaunch_appimage(file)),
        _ => Err("This copy of Vello can't update itself.".into()),
    };
    match handed_over {
        Ok(()) => {
            update::note_pending(&h, release.build);
            // Quitting ends every engine (RunEvent::Exit); the script waits for this process to be gone.
            let app = app.clone();
            tauri::async_runtime::spawn(async move {
                tokio::time::sleep(std::time::Duration::from_millis(300)).await;
                app.exit(0);
            });
            Ok(serde_json::json!({"installing": release.build}))
        }
        Err(problem) => {
            let message = format!("Update failed: {problem}.");
            update::install_failed(&message);
            Err(message)
        }
    }
}

#[cfg(windows)]
fn run_windows_installer(h: &Harness, installer: &std::path::Path, folder: &std::path::Path, build: u64) -> Result<(), String> {
    use std::os::windows::process::CommandExt;
    let exe = std::env::current_exe().map_err(|e| e.to_string())?;
    let script = update::windows_install_script(std::process::id(), installer, folder, &exe, build, &h.paths.root);
    let script_file = installer.with_file_name("install-update.ps1");
    // With a byte-order mark, so Windows PowerShell 5.1 reads a folder name with accents as UTF-8.
    let mut bytes = vec![0xEF, 0xBB, 0xBF];
    bytes.extend_from_slice(script.as_bytes());
    std::fs::write(&script_file, bytes).map_err(|e| e.to_string())?;
    let _ = std::fs::create_dir_all(h.paths.logs_dir());
    // CREATE_NO_WINDOW | CREATE_NEW_PROCESS_GROUP: no console flashes up, and it outlives Theo.
    std::process::Command::new("powershell.exe")
        .args(["-NoProfile", "-ExecutionPolicy", "Bypass", "-WindowStyle", "Hidden", "-File"])
        .arg(&script_file)
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .creation_flags(0x0800_0000 | 0x0000_0200)
        .spawn()
        .map(|_| ())
        .map_err(|e| format!("the installer couldn't be started ({e})"))
}

#[cfg(not(windows))]
fn run_windows_installer(_h: &Harness, _installer: &std::path::Path, _folder: &std::path::Path, _build: u64) -> Result<(), String> {
    Err("the Windows installer only runs on Windows".into())
}

#[cfg(unix)]
fn relaunch_appimage(appimage: &std::path::Path) -> Result<(), String> {
    use std::os::unix::process::CommandExt;
    let mut command = std::process::Command::new("sh");
    // The AppImage runtime pointed these at this copy's own mount, which goes away when it quits; the new copy sets its own.
    for name in ["LD_LIBRARY_PATH", "LD_PRELOAD", "APPDIR", "APPIMAGE", "ARGV0", "OWD", "GDK_PIXBUF_MODULEDIR", "GDK_PIXBUF_MODULE_FILE", "GTK_PATH",
                 "GTK_EXE_PREFIX", "GTK_DATA_PREFIX", "GTK_IM_MODULE_FILE", "GIO_MODULE_DIR", "GSETTINGS_SCHEMA_DIR", "PYTHONHOME", "PYTHONPATH", "PERLLIB", "QT_PLUGIN_PATH"] {
        command.env_remove(name);
    }
    command
        .arg("-c")
        .arg(update::appimage_relaunch_script(std::process::id(), appimage))
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .process_group(0)
        .spawn()
        .map(|_| ())
        .map_err(|e| format!("Vello couldn't be reopened ({e})"))
}

#[cfg(not(unix))]
fn relaunch_appimage(_appimage: &std::path::Path) -> Result<(), String> {
    Err("an AppImage only runs on Linux".into())
}
