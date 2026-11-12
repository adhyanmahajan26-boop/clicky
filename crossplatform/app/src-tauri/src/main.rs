// Theo's desktop app: the same harness engine as theod, with a window. No console window on Windows.
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

use std::sync::Arc;
use tauri::Manager;
use theo_core::Harness;

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

#[tauri::command]
async fn control(harness: tauri::State<'_, Arc<Harness>>, cmd: serde_json::Value) -> Result<serde_json::Value, String> {
    Ok(theo_core::control::handle(&harness, &cmd).await)
}

fn main() {
    let app = tauri::Builder::default()
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
            app.manage(harness);
            let icon = tauri::image::Image::from_bytes(include_bytes!("../icons/tray/awake.png"))?;
            tauri::tray::TrayIconBuilder::with_id("theo")
                .icon(icon)
                .tooltip("Theo")
                .on_tray_icon_event(|tray, event| {
                    if let tauri::tray::TrayIconEvent::Click { .. } = event {
                        if let Some(w) = tray.app_handle().get_webview_window("main") {
                            let _ = w.show();
                            let _ = w.unminimize();
                            let _ = w.set_focus();
                        }
                    }
                })
                .build(app)?;
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![control, set_tray])
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
