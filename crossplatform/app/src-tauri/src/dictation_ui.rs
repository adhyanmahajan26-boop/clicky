//! Dictation in the desktop app: theo-voice's controller (the chord through the app's one keyboard hook, the microphone,
//! transcribe, clean-up, insert) and its pill, a small always-on-top window near the bottom of the screen that shows
//! "Listening" with a live level, then "Writing", then the words it typed. The pill never takes focus, so the words go
//! into the app that was in front.

use std::sync::{Arc, Mutex};
use tauri::{Emitter, Manager};
use theo_core::Harness;

pub const PILL_LABEL: &str = "dictation-pill";
const PILL_WIDTH: f64 = 380.0;
const PILL_HEIGHT: f64 = 96.0;
/// How far above the bottom of the screen the pill sits, in logical pixels (clear of the taskbar).
const PILL_BOTTOM_GAP: f64 = 72.0;

/// The pill's latest state, for a pill page that has just loaded (`dictationPillState`).
static LAST_PILL: Mutex<Option<serde_json::Value>> = Mutex::new(None);

/// Starts dictation: its control commands, the controller, and the hook when `products.dictation` is on.
pub fn start(app: &tauri::AppHandle, harness: Arc<Harness>, runtime: tokio::runtime::Handle) {
    theo_voice::register_control_commands();
    theo_core::control_ext::register(
        "dictation-pill",
        Arc::new(|_harness, cmd| {
            Box::pin(async move {
                (cmd.get("cmd").and_then(|c| c.as_str()) == Some("dictationPillState")).then(|| theo_core::control::ok(LAST_PILL.lock().unwrap().clone().unwrap_or(serde_json::json!({"phase": "idle"}))))
            })
        }),
    );
    let handle = app.clone();
    let controller = theo_voice::dictation::Controller::new(harness, runtime, move |state| show_pill(&handle, state));
    app.manage(controller);
}

fn show_pill(app: &tauri::AppHandle, state: serde_json::Value) {
    let hide = state["phase"] == "idle";
    *LAST_PILL.lock().unwrap() = Some(state.clone());
    let _ = app.emit_to(PILL_LABEL, "dictation-pill", state);
    let app_for_main = app.clone();
    // Windows are made and moved on the main thread.
    let _ = app.run_on_main_thread(move || {
        let window = match app_for_main.get_webview_window(PILL_LABEL) {
            Some(window) => window,
            None if hide => return,
            None => match make_pill(&app_for_main) {
                Some(window) => window,
                None => return,
            },
        };
        if hide {
            let _ = window.hide();
            return;
        }
        place_pill(&window);
        if window.is_visible().unwrap_or(false) {
            return;
        }
        #[cfg(windows)]
        if let Ok(hwnd) = window.hwnd() {
            if theo_voice::overlay::show_without_focus(hwnd.0 as isize) {
                return;
            }
        }
        let _ = window.show();
    });
}

fn make_pill(app: &tauri::AppHandle) -> Option<tauri::WebviewWindow> {
    let window = tauri::WebviewWindowBuilder::new(app, PILL_LABEL, tauri::WebviewUrl::App("pill.html".into()))
        .title("Vello dictation")
        .inner_size(PILL_WIDTH, PILL_HEIGHT)
        .decorations(false)
        .transparent(true)
        .shadow(false)
        .resizable(false)
        .always_on_top(true)
        .skip_taskbar(true)
        .focused(false)
        .focusable(false)
        .visible(false)
        .build();
    match window {
        Ok(window) => {
            #[cfg(windows)]
            if let Ok(hwnd) = window.hwnd() {
                theo_voice::overlay::prepare(hwnd.0 as isize);
            }
            let _ = window.set_ignore_cursor_events(true);
            Some(window)
        }
        Err(error) => {
            eprintln!("[dictation] the pill couldn't open: {error}");
            None
        }
    }
}

/// Bottom centre of the screen the pointer is on (else the main one).
fn place_pill(window: &tauri::WebviewWindow) {
    let monitor = window
        .cursor_position()
        .ok()
        .and_then(|point| window.available_monitors().ok()?.into_iter().find(|monitor| {
            let (position, size) = (monitor.position(), monitor.size());
            point.x >= position.x as f64 && point.x < (position.x + size.width as i32) as f64 && point.y >= position.y as f64 && point.y < (position.y + size.height as i32) as f64
        }))
        .or_else(|| window.primary_monitor().ok().flatten());
    let Some(monitor) = monitor else { return };
    let scale = monitor.scale_factor();
    let (position, size) = (monitor.position(), monitor.size());
    let width = (PILL_WIDTH * scale) as i32;
    let height = (PILL_HEIGHT * scale) as i32;
    let x = position.x + (size.width as i32 - width) / 2;
    let y = position.y + size.height as i32 - height - (PILL_BOTTOM_GAP * scale) as i32;
    let _ = window.set_position(tauri::PhysicalPosition::new(x, y));
}
