// Theo's desktop app: the same harness engine as theod, with a window. No console window on Windows.
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

use std::sync::Arc;
use tauri::Manager;
use theo_core::Harness;

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
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![control])
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
