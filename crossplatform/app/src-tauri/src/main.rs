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
#[tauri::command]
fn set_tray(app: tauri::AppHandle, state: String, count: usize, label: String) -> Result<(), String> {
    let bytes: &[u8] = match state.as_str() {
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

/// A system notification: "<Bot> needs you" or "<Bot> failed", with one line of detail.
#[tauri::command]
fn notify(app: tauri::AppHandle, title: String, body: String) -> Result<(), String> {
    use tauri_plugin_notification::NotificationExt;
    app.notification().builder().title(title).body(body).show().map_err(|e| e.to_string())
}

/// Whether Theo opens when you sign in to this computer (Settings). Like the Mac app, it's on unless you turn it off.
#[tauri::command]
fn open_at_login(app: tauri::AppHandle, harness: tauri::State<'_, Arc<Harness>>, enabled: Option<bool>) -> Result<bool, String> {
    use tauri_plugin_autostart::ManagerExt;
    let launcher = app.autolaunch();
    if let Some(on) = enabled {
        if on { launcher.enable() } else { launcher.disable() }.map_err(|e| e.to_string())?;
        harness.settings.set("desktop.openAtLogin", serde_json::json!(on));
    }
    launcher.is_enabled().map_err(|e| e.to_string())
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
    let app = tauri::Builder::default()
        // One Theo at a time: two engines on one data folder would run every routine twice and race on the same files. Opening
        // Theo again (Start menu, desktop icon, a second double-click) brings the running one to the front instead.
        .plugin(tauri_plugin_single_instance::init(|app, _args, _cwd| show_main_window(app)))
        .plugin(tauri_plugin_notification::init())
        // "Theo" is the name of its entry in Windows' sign-in list, which the uninstaller removes (windows/hooks.nsh).
        .plugin(tauri_plugin_autostart::Builder::new().app_name("Theo").args([BACKGROUND_ARG]).build())
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
            if !is_test && harness.settings.get("desktop.openAtLogin").is_none() {
                use tauri_plugin_autostart::ManagerExt;
                let on = app.autolaunch().enable().is_ok();
                harness.settings.set("desktop.openAtLogin", serde_json::json!(on));
            }
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
