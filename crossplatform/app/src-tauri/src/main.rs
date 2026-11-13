// Theo's desktop app: the same harness engine as theod, with a window. No console window on Windows.
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use tauri::Manager;
use theo_core::Harness;

/// Started by the system at sign-in: Theo comes up in the tray without opening its window.
const BACKGROUND_ARG: &str = "--background";

/// The tray icon is the micro face of the most urgent state (failed, then needs you, then working), with how many bots are
/// in it; calm is the awake face and no count.
fn show_tray_state(app: &tauri::AppHandle, state: &str, count: usize, label: &str) -> Result<(), String> {
    let bytes: &[u8] = match state {
        "failed" => include_bytes!("../icons/tray/failed.png"),
        "needs" => include_bytes!("../icons/tray/needs.png"),
        "working" => include_bytes!("../icons/tray/working.png"),
        "done" => include_bytes!("../icons/tray/done.png"),
        _ => include_bytes!("../icons/tray/awake.png"),
    };
    if let Some(tray) = app.tray_by_id("theo") {
        let image = tauri::image::Image::from_bytes(bytes).map_err(|e| e.to_string())?;
        tray.set_icon(Some(image)).map_err(|e| e.to_string())?;
        let _ = tray.set_tooltip(Some(if label.is_empty() { "Theo".to_string() } else { format!("Theo: {label}") }));
        // A count beside the icon where the platform shows one (the Mac menu bar); elsewhere the tooltip says it.
        let _ = tray.set_title(if count > 0 { Some(count.to_string()) } else { None });
    }
    Ok(())
}

#[tauri::command]
fn set_tray(app: tauri::AppHandle, state: String, count: usize, label: String) -> Result<(), String> {
    show_tray_state(&app, &state, count, &label)
}

/// Keeps the tray face and notifications current from the engine itself, every second, whether or not the window is open.
/// (The window's own timers slow down or stop while it's hidden, which is when "Writer needs you" matters most.) A bot that
/// starts needing you, or fails, gets one notification, unless Theo's window is in front. Each one is written to
/// Logs/notifications.log (title and whether Windows took it), so a test can see it was sent.
fn watch_faces(app: tauri::AppHandle, harness: Arc<Harness>) {
    tauri::async_runtime::spawn(async move {
        let mut known: Option<std::collections::HashMap<String, (String, String)>> = None;
        let mut tray_shown = String::new();
        loop {
            tokio::time::sleep(std::time::Duration::from_secs(1)).await;
            let report = harness.state_report();
            let counts = &report["counts"];
            let number = |key: &str| counts[key].as_u64().unwrap_or(0) as usize;
            let (state, count, label) = if number("failed") > 0 {
                ("failed", number("failed"), format!("{} failed", number("failed")))
            } else if number("needs") > 0 {
                ("needs", number("needs"), format!("{} need{} you", number("needs"), if number("needs") == 1 { "s" } else { "" }))
            } else if number("working") > 0 {
                ("working", number("working"), format!("{} working", number("working")))
            } else {
                ("awake", 0, String::new())
            };
            let shown = format!("{state}{count}");
            if shown != tray_shown && show_tray_state(&app, state, count, &label).is_ok() {
                tray_shown = shown;
            }
            let names: std::collections::HashMap<String, String> = report["bots"].as_array().into_iter().flatten()
                .filter_map(|b| Some((b["id"].as_str()?.to_string(), b["name"].as_str()?.to_string()))).collect();
            let mut now = std::collections::HashMap::new();
            for face in report["faces"].as_array().into_iter().flatten() {
                let (Some(id), Some(face_state)) = (face["id"].as_str(), face["state"].as_str()) else { continue };
                let since = face["since"].as_str().unwrap_or("").to_string();
                now.insert(id.to_string(), (face_state.to_string(), since.clone()));
                let Some(before) = &known else { continue };
                if face_state != "needs" && face_state != "failed" {
                    continue;
                }
                if before.get(id) == Some(&(face_state.to_string(), since)) {
                    continue;
                }
                let in_front = app.get_webview_window("main").map(|w| w.is_visible().unwrap_or(false) && w.is_focused().unwrap_or(false)).unwrap_or(false);
                if in_front {
                    continue;
                }
                let name = names.get(id).cloned().unwrap_or_else(|| id.to_string());
                let title = format!("{name} {}", if face_state == "needs" { "needs you" } else { "failed" });
                let detail = face["detail"].as_str().filter(|d| !d.is_empty()).or(face["word"].as_str()).unwrap_or("").to_string();
                use tauri_plugin_notification::NotificationExt;
                let sent = app.notification().builder().title(&title).body(&detail).show();
                let line = format!("{}\t{}\t{}\n", chrono_now(), match &sent { Ok(()) => "sent".to_string(), Err(e) => format!("error: {e}") }, title);
                let log = harness.paths.logs_dir();
                let _ = std::fs::create_dir_all(&log);
                use std::io::Write;
                if let Ok(mut f) = std::fs::OpenOptions::new().create(true).append(true).open(log.join("notifications.log")) {
                    let _ = f.write_all(line.as_bytes());
                }
            }
            known = Some(now);
        }
    });
}

fn chrono_now() -> String {
    let seconds = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0);
    seconds.to_string()
}

/// A system notification: "<Bot> needs you" or "<Bot> failed", with one line of detail.
#[tauri::command]
fn notify(app: tauri::AppHandle, title: String, body: String) -> Result<(), String> {
    use tauri_plugin_notification::NotificationExt;
    app.notification().builder().title(title).body(body).show().map_err(|e| e.to_string())
}

/// Whether Theo opens when you sign in to this computer (Settings). Like the Mac app, it's on unless you turn it off.
#[tauri::command]
fn open_at_login(app: tauri::AppHandle, harness: tauri::State<'_, Arc<Harness>>, enabled: Option<bool>) -> Result<bool, String> {
    if let Some(on) = enabled {
        set_open_at_login(&app, on)?;
        harness.settings.set("desktop.openAtLogin", serde_json::json!(on));
    }
    open_at_login_is_on(&app)
}

/// Windows: this user's Run entry, written by Theo (see theo_core::setup::windows_sign_in for why not the plugin).
#[cfg(windows)]
fn set_open_at_login(_app: &tauri::AppHandle, on: bool) -> Result<(), String> {
    use theo_core::setup::windows_sign_in;
    let command = match on {
        true => Some(windows_sign_in::command_for(&std::env::current_exe().map_err(|e| e.to_string())?, &[BACKGROUND_ARG])),
        false => None,
    };
    windows_sign_in::set("Theo", command.as_deref())
}

#[cfg(windows)]
fn open_at_login_is_on(_app: &tauri::AppHandle) -> Result<bool, String> {
    Ok(theo_core::setup::windows_sign_in::is_on("Theo"))
}

/// Mac and Linux: the autostart plugin (a LaunchAgent, or an XDG autostart file).
#[cfg(not(windows))]
fn set_open_at_login(app: &tauri::AppHandle, on: bool) -> Result<(), String> {
    use tauri_plugin_autostart::ManagerExt;
    let launcher = app.autolaunch();
    if on { launcher.enable() } else { launcher.disable() }.map_err(|e| e.to_string())
}

#[cfg(not(windows))]
fn open_at_login_is_on(app: &tauri::AppHandle) -> Result<bool, String> {
    use tauri_plugin_autostart::ManagerExt;
    app.autolaunch().is_enabled().map_err(|e| e.to_string())
}

#[tauri::command]
async fn control(harness: tauri::State<'_, Arc<Harness>>, cmd: serde_json::Value) -> Result<serde_json::Value, String> {
    Ok(theo_core::control::handle(&harness, &cmd).await)
}

fn show_main_window(app: &tauri::AppHandle) {
    if let Some(w) = app.get_webview_window("main") {
        let _ = w.show();
        let _ = w.unminimize();
        let _ = w.set_focus();
    }
}

fn main() {
    let told_still_running = Arc::new(AtomicBool::new(false));
    let is_test_run = std::env::args().any(|a| a == "--test");
    let mut builder = tauri::Builder::default();
    if !is_test_run {
        // One Theo at a time: two engines on one data folder would run every routine twice and race on the same files. Opening
        // Theo again (Start menu, desktop icon, a second double-click) brings the running one to the front instead. A test run
        // (its own --data folder) stays out of it, so it never collides with the Theo someone is using.
        builder = builder.plugin(tauri_plugin_single_instance::init(|app, _args, _cwd| show_main_window(app)));
    }
    #[cfg(not(windows))]
    {
        builder = builder.plugin(tauri_plugin_autostart::Builder::new().app_name("Theo").args([BACKGROUND_ARG]).build());
    }
    let app = builder
        .plugin(tauri_plugin_notification::init())
        .setup(|app| {
            // The same flags as theod, so the test suite can drive the app itself: --data DIR, --test.
            let args: Vec<String> = std::env::args().collect();
            let root = args.iter().position(|a| a == "--data").and_then(|i| args.get(i + 1)).map(std::path::PathBuf::from).unwrap_or_else(theo_core::paths::default_root);
            let is_test = args.iter().any(|a| a == "--test") || std::env::var("THEO_TEST").map(|v| v == "1").unwrap_or(false);
            std::fs::create_dir_all(&root)?;
            let harness = Harness::new(root, is_test);
            let h = harness.clone();
            tauri::async_runtime::block_on(async move {
                h.start();
                // Scripts and tests can drive the app the way they drive theod.
                tokio::spawn(theo_core::control::serve_inbox(h.clone()));
            });
            std::fs::write(harness.paths.pid_file(), std::process::id().to_string())?;
            // Open at sign-in, as the Mac app does, from the first time Theo runs; after that, whatever Settings says (and Windows'
            // own Startup apps switch, which Theo leaves alone). Never for a test.
            // "Theo" is the name of its entry in Windows' sign-in list, which the uninstaller removes (windows/hooks.nsh).
            if !is_test {
                match harness.settings.get("desktop.openAtLogin").and_then(|v| v.as_bool()) {
                    None => {
                        let on = set_open_at_login(app.handle(), true).is_ok();
                        harness.settings.set("desktop.openAtLogin", serde_json::json!(on));
                    }
                    // Uninstalled and installed again: the entry went with the uninstall, the setting stayed on.
                    Some(true) if !theo_core::setup::sign_in_entry_exists("Theo") => {
                        let _ = set_open_at_login(app.handle(), true);
                    }
                    _ => {}
                }
            }
            watch_faces(app.handle().clone(), harness.clone());
            app.manage(harness);

            let open_item = tauri::menu::MenuItem::with_id(app, "open", "Open Theo", true, None::<&str>)?;
            let quit_item = tauri::menu::MenuItem::with_id(app, "quit", "Quit Theo", true, None::<&str>)?;
            let menu = tauri::menu::Menu::with_items(app, &[&open_item, &quit_item])?;
            let icon = tauri::image::Image::from_bytes(include_bytes!("../icons/tray/awake.png"))?;
            tauri::tray::TrayIconBuilder::with_id("theo")
                .icon(icon)
                .tooltip("Theo")
                .menu(&menu)
                .show_menu_on_left_click(false)
                .on_menu_event(|app, event| match event.id().as_ref() {
                    "open" => show_main_window(app),
                    "quit" => app.exit(0),
                    _ => {}
                })
                .on_tray_icon_event(|tray, event| {
                    if let tauri::tray::TrayIconEvent::Click { button: tauri::tray::MouseButton::Left, button_state: tauri::tray::MouseButtonState::Up, .. } = event {
                        show_main_window(tray.app_handle());
                    }
                })
                .build(app)?;
            if !args.iter().any(|a| a == BACKGROUND_ARG) {
                show_main_window(app.handle());
            }
            Ok(())
        })
        .on_window_event({
            let told_still_running = told_still_running.clone();
            move |window, event| {
                // Closing the window keeps Theo running in the tray, like the Mac app in the menu bar: routines keep firing and
                // bots keep working. Quit Theo is in the tray icon's menu.
                if let tauri::WindowEvent::CloseRequested { api, .. } = event {
                    api.prevent_close();
                    let _ = window.hide();
                    if !told_still_running.swap(true, Ordering::SeqCst) {
                        use tauri_plugin_notification::NotificationExt;
                        let _ = window.app_handle().notification().builder().title("Theo is still running").body("Routines and bots keep going. Open or quit Theo from its icon in the tray.").show();
                    }
                }
            }
        })
        .invoke_handler(tauri::generate_handler![control, set_tray, notify, open_at_login])
        .build(tauri::generate_context!())
        .expect("Theo couldn't start");
    app.run(|handle, event| {
        if let tauri::RunEvent::Exit = event {
            if let Some(h) = handle.try_state::<Arc<Harness>>() {
                h.shutdown();
            }
        }
    });
}
