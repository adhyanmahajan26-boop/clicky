//! Clicky on Windows: hold Ctrl + Alt and talk, let go, and Clicky looks at every monitor, answers in a bubble by the cursor
//! and out loud, and flies its orange spark to what it's talking about. The brain turn, the screenshots, the tags and the
//! voice are theo-core's (`theo_core::clicky`); this file is the desktop side: the spark's overlay windows, following the
//! cursor, the push-to-talk loop (`clicky_voice.rs`), Escape, and the tray item.
//!
//! The overlay is one transparent, click-through, always-on-top window per monitor that never takes the focus and is left
//! out of screenshots (`theo_core::clicky::desktop`). It draws `spark.html`: the spark beside the cursor (breathing when
//! idle, pulsing while listening, spinning while thinking), the answer's bubble, the flight to a [POINT] and up to six
//! [MARK]s. Everything is placed in physical pixels and divided by the monitor's own scale, so 150 % screens line up.
//!
//! Following the cursor costs little: the pointer is read 60 times a second only while it moves (and for a second after),
//! 10 times a second while it's still, and not at all while the spark is hidden.

use serde_json::{json, Value};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use tauri::{AppHandle, Emitter, Manager};
use theo_core::clicky::screens::Monitor;
use theo_core::clicky::speech::Speaking;
use theo_core::engine::Cancel;
use theo_core::Harness;

/// Marks stay this long after the answer has been spoken (the Mac's 20 s).
const MARKS_LINGER: Duration = Duration::from_secs(20);
/// The spark stays on what it pointed at this long after speaking, then goes back to the cursor.
const POINT_LINGER: Duration = Duration::from_millis(1500);
/// An error or "didn't catch that" stays in the bubble this long.
const NOTE_LINGER: Duration = Duration::from_secs(8);
pub const TRAY_ITEM: &str = "clicky";

#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Phase {
    Idle,
    Listening,
    Thinking,
    Speaking,
}

impl Phase {
    fn word(&self) -> &'static str {
        match self {
            Phase::Idle => "idle",
            Phase::Listening => "listening",
            Phase::Thinking => "thinking",
            Phase::Speaking => "speaking",
        }
    }
}

struct Overlay {
    label: String,
    monitor: Monitor,
    handle: isize,
}

struct Inner {
    phase: Phase,
    cancel: Option<Arc<Cancel>>,
    speaking: Option<Arc<Speaking>>,
    overlays: Vec<Overlay>,
    shown: bool,
    /// Something is on screen that keeps the overlay up in "only while talking" mode.
    hold_until: Option<Instant>,
    last_plan: Value,
    last_error: Option<String>,
    last_transcript: String,
}

pub struct ClickyApp {
    pub app: AppHandle,
    pub harness: Arc<Harness>,
    inner: Mutex<Inner>,
    /// Bumped by every new question, Escape and stop: a turn that finds it changed drops its answer.
    turn: AtomicU64,
    /// The overlay is up (read by the cursor thread without the lock).
    visible: AtomicBool,
    /// Where the spark is, as (overlay index, x, y) in that overlay's CSS pixels.
    cursor: Mutex<Option<(usize, f64, f64)>>,
}

static INSTANCE: once_cell::sync::OnceCell<Arc<ClickyApp>> = once_cell::sync::OnceCell::new();

pub fn instance() -> Option<Arc<ClickyApp>> {
    INSTANCE.get().cloned()
}

/// What the control inbox's `clickyAsk`, `clickyStop` and `clickyOverlay` reach in the app.
struct DesktopHook(Arc<ClickyApp>);

impl theo_core::clicky::Desktop for DesktopHook {
    fn ask(&self, transcript: String) -> Value {
        if !theo_core::clicky::is_on(&self.0.harness) {
            return json!({"started": false, "why": "Clicky is off. Turn it on in Settings › Clicky."});
        }
        let clicky = self.0.clone();
        tauri::async_runtime::spawn(async move { clicky.answer(transcript).await });
        json!({"started": true})
    }

    fn stop(&self) -> Value {
        self.0.stop_everything();
        json!({"stopped": true})
    }

    fn status(&self) -> Value {
        self.0.status()
    }
}

pub fn start(app: &AppHandle, harness: Arc<Harness>) {
    let clicky = Arc::new(ClickyApp {
        app: app.clone(),
        harness,
        inner: Mutex::new(Inner { phase: Phase::Idle, cancel: None, speaking: None, overlays: vec![], shown: false, hold_until: None, last_plan: Value::Null, last_error: None, last_transcript: String::new() }),
        turn: AtomicU64::new(0),
        visible: AtomicBool::new(false),
        cursor: Mutex::new(None),
    });
    let _ = INSTANCE.set(clicky.clone());
    theo_core::clicky::set_desktop(Arc::new(DesktopHook(clicky.clone())));
    // Keeps the overlay windows matching the setting and the monitors.
    {
        let clicky = clicky.clone();
        tauri::async_runtime::spawn(async move {
            loop {
                clicky.keep_overlay();
                tokio::time::sleep(Duration::from_millis(400)).await;
            }
        });
    }
    // Follows the cursor and watches for Escape.
    {
        let clicky = clicky.clone();
        std::thread::Builder::new().name("clicky-cursor".into()).spawn(move || clicky.follow_cursor()).ok();
    }
    crate::clicky_voice::start(clicky);
}

impl ClickyApp {
    fn settings_wants_always(&self) -> bool {
        self.harness.settings.string(theo_core::clicky::SPARK_SETTING).as_deref() != Some("talking")
    }

    pub fn phase(&self) -> Phase {
        self.inner.lock().unwrap().phase
    }

    fn set_phase(&self, phase: Phase) {
        self.inner.lock().unwrap().phase = phase;
        self.broadcast(json!({"kind": "state", "state": phase.word()}));
        self.keep_overlay();
    }

    pub fn status(&self) -> Value {
        let inner = self.inner.lock().unwrap();
        json!({
            "phase": inner.phase.word(),
            "overlays": inner.overlays.iter().map(|o| json!({"label": o.label, "monitor": o.monitor.to_json()})).collect::<Vec<_>>(),
            "shown": inner.shown,
            "lastTranscript": inner.last_transcript,
            "lastPlan": inner.last_plan,
            "lastError": inner.last_error,
        })
    }

    /// Sends one message to every overlay.
    fn broadcast(&self, message: Value) {
        let labels: Vec<String> = self.inner.lock().unwrap().overlays.iter().map(|o| o.label.clone()).collect();
        for label in labels {
            let _ = self.app.emit_to(label.as_str(), "spark", message.clone());
        }
    }

    fn send_to(&self, label: &str, message: Value) {
        let _ = self.app.emit_to(label, "spark", message);
    }

    /// The monitors as Tauri sees them (physical pixels), with the primary marked.
    fn monitors(&self) -> Vec<Monitor> {
        let primary = self.app.primary_monitor().ok().flatten().map(|m| (m.position().x, m.position().y));
        self.app
            .available_monitors()
            .unwrap_or_default()
            .iter()
            .enumerate()
            .map(|(index, m)| Monitor {
                x: m.position().x,
                y: m.position().y,
                width: m.size().width,
                height: m.size().height,
                scale: m.scale_factor(),
                primary: primary == Some((m.position().x, m.position().y)),
                name: m.name().cloned().unwrap_or_else(|| format!("Display {}", index + 1)),
            })
            .collect()
    }

    /// Makes the overlay windows match the monitors and the settings, and shows or hides them.
    fn keep_overlay(&self) {
        let on = theo_core::clicky::is_on(&self.harness);
        let monitors = if on { self.monitors() } else { vec![] };
        let (rebuild, close): (bool, Vec<String>) = {
            let inner = self.inner.lock().unwrap();
            let same = inner.overlays.len() == monitors.len() && inner.overlays.iter().zip(&monitors).all(|(o, m)| o.monitor == *m);
            if same {
                (false, vec![])
            } else {
                (on && !monitors.is_empty(), inner.overlays.iter().map(|o| o.label.clone()).collect())
            }
        };
        if !close.is_empty() || rebuild {
            for label in &close {
                if let Some(window) = self.app.get_webview_window(label) {
                    let _ = window.destroy();
                }
            }
            let mut made = vec![];
            if rebuild {
                let generation = uuid::Uuid::new_v4().simple().to_string();
                for (index, monitor) in monitors.iter().enumerate() {
                    let label = format!("spark-{}-{index}", &generation[..8]);
                    match self.make_overlay(&label, monitor) {
                        Ok(handle) => made.push(Overlay { label, monitor: monitor.clone(), handle }),
                        Err(problem) => eprintln!("[clicky] couldn't make the spark's window: {problem}"),
                    }
                }
            }
            let mut inner = self.inner.lock().unwrap();
            inner.overlays = made;
            inner.shown = false;
            *self.cursor.lock().unwrap() = None;
        }
        // Show or hide.
        let (want, overlays): (bool, Vec<(String, isize)>) = {
            let mut inner = self.inner.lock().unwrap();
            let holding = inner.hold_until.map(|until| Instant::now() < until).unwrap_or(false);
            if !holding {
                inner.hold_until = None;
            }
            let want = on && (self.settings_wants_always() || inner.phase != Phase::Idle || holding);
            if want == inner.shown {
                drop(inner);
                self.update_tray_item();
                return;
            }
            inner.shown = want;
            (want, inner.overlays.iter().map(|o| (o.label.clone(), o.handle)).collect())
        };
        for (label, handle) in overlays {
            if want {
                if cfg!(windows) {
                    theo_core::clicky::desktop::show_without_activating(handle);
                } else if let Some(window) = self.app.get_webview_window(&label) {
                    let _ = window.show();
                }
            } else if let Some(window) = self.app.get_webview_window(&label) {
                let _ = window.hide();
            }
        }
        self.visible.store(want, Ordering::SeqCst);
        if !want {
            *self.cursor.lock().unwrap() = None;
        }
        self.update_tray_item();
    }

    fn update_tray_item(&self) {
        let checked = theo_core::clicky::is_on(&self.harness) && self.settings_wants_always();
        if let Some(item) = self.app.try_state::<TrayItem>() {
            let _ = item.0.set_checked(checked);
        }
    }

    fn make_overlay(&self, label: &str, monitor: &Monitor) -> Result<isize, String> {
        let page_label = label.to_string();
        let builder = tauri::WebviewWindowBuilder::new(&self.app, label, tauri::WebviewUrl::App("spark.html".into()))
            .title("Clicky")
            .decorations(false)
            .transparent(true)
            .shadow(false)
            .resizable(false)
            .always_on_top(true)
            .skip_taskbar(true)
            .visible_on_all_workspaces(true)
            .focused(false)
            .focusable(false)
            .visible(false)
            .on_page_load(move |window, payload| {
                if payload.event() == tauri::webview::PageLoadEvent::Finished {
                    if let Some(clicky) = instance() {
                        let phase = clicky.phase();
                        clicky.send_to(&page_label, json!({"kind": "state", "state": phase.word()}));
                        let _ = window.set_ignore_cursor_events(true);
                    }
                }
            });
        let window = builder.build().map_err(|e| e.to_string())?;
        let _ = window.set_position(tauri::PhysicalPosition::new(monitor.x, monitor.y));
        let _ = window.set_size(tauri::PhysicalSize::new(monitor.width, monitor.height));
        let _ = window.set_ignore_cursor_events(true);
        #[cfg(windows)]
        let handle = window.hwnd().map(|h| h.0 as isize).unwrap_or(0);
        #[cfg(not(windows))]
        let handle = 0isize;
        theo_core::clicky::desktop::make_overlay(handle);
        // A window made on one monitor and moved to another of a different scale is resized by Windows: put it back.
        let (x, y, width, height) = (monitor.x, monitor.y, monitor.width, monitor.height);
        let moved = window.clone();
        window.on_window_event(move |event| {
            if let tauri::WindowEvent::ScaleFactorChanged { .. } = event {
                let _ = moved.set_position(tauri::PhysicalPosition::new(x, y));
                let _ = moved.set_size(tauri::PhysicalSize::new(width, height));
            }
        });
        Ok(handle)
    }

    /// The cursor thread: the spark follows the pointer, and Escape stops Clicky.
    fn follow_cursor(self: Arc<Self>) {
        let mut last: Option<(f64, f64)> = None;
        let mut last_moved = Instant::now();
        let mut escape_was_down = false;
        loop {
            let busy = self.phase() != Phase::Idle || self.inner.lock().unwrap().hold_until.is_some();
            // Escape, from any app, while Clicky is listening, thinking, speaking or showing marks.
            let escape = busy && theo_core::clicky::desktop::escape_is_down();
            if escape && !escape_was_down {
                self.stop_everything();
            }
            escape_was_down = escape;
            if !self.visible.load(Ordering::SeqCst) {
                last = None;
                std::thread::sleep(Duration::from_millis(if busy { 50 } else { 250 }));
                continue;
            }
            if let Ok(position) = self.app.cursor_position() {
                let point = (position.x, position.y);
                if last != Some(point) {
                    last = Some(point);
                    last_moved = Instant::now();
                    self.move_spark(point.0.round() as i32, point.1.round() as i32);
                }
            }
            let moving = last_moved.elapsed() < Duration::from_secs(1);
            std::thread::sleep(Duration::from_millis(if moving { 16 } else if busy { 50 } else { 100 }));
        }
    }

    fn move_spark(&self, x: i32, y: i32) {
        let found = {
            let inner = self.inner.lock().unwrap();
            inner.overlays.iter().enumerate().find(|(_, o)| o.monitor.contains(x, y)).map(|(index, o)| (index, o.label.clone(), o.monitor.clone()))
        };
        let Some((index, label, monitor)) = found else { return };
        let (local_x, local_y) = theo_core::clicky::screens::physical_to_overlay(x, y, &monitor);
        let previous = self.cursor.lock().unwrap().replace((index, local_x, local_y));
        if let Some((previous_index, _, _)) = previous {
            if previous_index != index {
                let previous_label = self.inner.lock().unwrap().overlays.get(previous_index).map(|o| o.label.clone());
                if let Some(previous_label) = previous_label {
                    self.send_to(&previous_label, json!({"kind": "away"}));
                }
            }
        }
        self.send_to(&label, json!({"kind": "cursor", "x": local_x, "y": local_y}));
    }

    /// Escape, a new question, or the stop button: speech stops, the answer is dropped, marks go.
    pub fn stop_everything(&self) {
        self.turn.fetch_add(1, Ordering::SeqCst);
        let (cancel, speaking) = {
            let mut inner = self.inner.lock().unwrap();
            inner.hold_until = None;
            (inner.cancel.take(), inner.speaking.take())
        };
        if let Some(cancel) = cancel {
            cancel.cancel();
        }
        if let Some(speaking) = speaking {
            speaking.stop();
        }
        crate::clicky_voice::cancel_listening();
        self.broadcast(json!({"kind": "clear"}));
        self.set_phase(Phase::Idle);
    }

    /// Push-to-talk pressed: anything going on stops, and Clicky listens.
    pub fn begin_listening(&self) {
        self.stop_everything();
        self.set_phase(Phase::Listening);
    }

    /// The mic level while listening (0 to 1), for the spark's pulse.
    pub fn show_level(&self, level: f32) {
        self.broadcast(json!({"kind": "level", "level": level}));
    }

    /// A short note in the bubble that isn't an answer ("didn't catch that", an error).
    pub fn show_note(&self, text: &str, is_error: bool) {
        {
            let mut inner = self.inner.lock().unwrap();
            inner.hold_until = Some(Instant::now() + NOTE_LINGER);
            if is_error {
                inner.last_error = Some(text.to_string());
            }
        }
        self.set_phase(Phase::Idle);
        self.broadcast(json!({"kind": "say", "text": text, "error": is_error, "linger": NOTE_LINGER.as_millis() as u64}));
    }

    /// One question, start to end: look at every monitor, ask the brain, show and speak the answer, fly and draw.
    pub async fn answer(self: Arc<Self>, transcript: String) {
        let turn = self.turn.fetch_add(1, Ordering::SeqCst) + 1;
        let cancel = Cancel::new();
        {
            let mut inner = self.inner.lock().unwrap();
            if let Some(previous) = inner.cancel.replace(cancel.clone()) {
                previous.cancel();
            }
            if let Some(speaking) = inner.speaking.take() {
                speaking.stop();
            }
            inner.last_transcript = transcript.clone();
            inner.last_error = None;
            inner.hold_until = None;
        }
        self.broadcast(json!({"kind": "clear"}));
        self.set_phase(Phase::Thinking);
        let screens = if theo_core::clicky::screens::can_capture() {
            match tauri::async_runtime::spawn_blocking(theo_core::clicky::screens::capture_all).await {
                Ok(Ok(screens)) => screens,
                Ok(Err(problem)) => {
                    eprintln!("[clicky] no screenshot this time: {problem}");
                    vec![]
                }
                Err(_) => vec![],
            }
        } else {
            vec![]
        };
        let shown_text = {
            let clicky = self.clone();
            let last_sent = Mutex::new(Instant::now() - Duration::from_secs(1));
            Arc::new(move |text: &str| {
                if clicky.turn.load(Ordering::SeqCst) != turn {
                    return;
                }
                let mut last = last_sent.lock().unwrap();
                if last.elapsed() < Duration::from_millis(60) {
                    return;
                }
                *last = Instant::now();
                let speech = theo_core::clicky::tags::extract_all(text).speech;
                if !speech.is_empty() {
                    clicky.broadcast(json!({"kind": "text", "text": speech}));
                }
            }) as Arc<dyn Fn(&str) + Send + Sync>
        };
        let result = theo_core::clicky::turn(&self.harness, &transcript, &screens, cancel.clone(), shown_text).await;
        if self.turn.load(Ordering::SeqCst) != turn {
            return;
        }
        let plan = match result {
            Ok(plan) => plan,
            Err(problem) => {
                if problem != "Stopped." {
                    self.show_note(&problem, true);
                }
                return;
            }
        };
        self.inner.lock().unwrap().last_plan = plan.clone();
        let speech = plan["speech"].as_str().unwrap_or("").to_string();
        self.show_plan(&plan);
        // Speak it.
        let voice = self.harness.settings.string(theo_core::clicky::VOICE_SETTING).unwrap_or_default();
        let rate = self.harness.settings.number(theo_core::clicky::RATE_SETTING).unwrap_or(0.0) as i32;
        self.set_phase(Phase::Speaking);
        match theo_core::clicky::speech::speak(&speech, &voice, rate) {
            Ok(speaking) => {
                let speaking = Arc::new(speaking);
                self.inner.lock().unwrap().speaking = Some(speaking.clone());
                speaking.finished().await;
            }
            Err(problem) => {
                eprintln!("[clicky] couldn't speak: {problem}");
                // Nothing to hear: give the bubble time to be read instead.
                tokio::time::sleep(Duration::from_millis((1500 + speech.len() as u64 * 45).min(15_000))).await;
            }
        }
        if self.turn.load(Ordering::SeqCst) != turn {
            return;
        }
        {
            let mut inner = self.inner.lock().unwrap();
            inner.speaking = None;
            inner.cancel = None;
            let has_marks = plan["marks"].as_array().map(|m| !m.is_empty()).unwrap_or(false);
            inner.hold_until = Some(Instant::now() + if has_marks { MARKS_LINGER } else { POINT_LINGER + Duration::from_secs(4) });
        }
        self.set_phase(Phase::Idle);
        // Back to the cursor after a moment; marks stay a while longer.
        let clicky = self.clone();
        tauri::async_runtime::spawn(async move {
            tokio::time::sleep(POINT_LINGER).await;
            if clicky.turn.load(Ordering::SeqCst) == turn {
                clicky.broadcast(json!({"kind": "release"}));
            }
            tokio::time::sleep(MARKS_LINGER.saturating_sub(POINT_LINGER)).await;
            if clicky.turn.load(Ordering::SeqCst) == turn {
                clicky.broadcast(json!({"kind": "clear"}));
            }
        });
    }

    /// Sends each overlay its part of the answer: the bubble, the flight, and the marks on its monitor.
    fn show_plan(&self, plan: &Value) {
        let overlays: Vec<(String, Monitor)> = self.inner.lock().unwrap().overlays.iter().map(|o| (o.label.clone(), o.monitor.clone())).collect();
        let speech = plan["speech"].as_str().unwrap_or("");
        let point = plan["point"].as_object().and_then(|point| {
            let (x, y) = (point.get("x")?.as_i64()? as i32, point.get("y")?.as_i64()? as i32);
            Some((x, y, point.get("label").and_then(Value::as_str).unwrap_or("").to_string()))
        });
        let point_overlay = point.as_ref().and_then(|(x, y, _)| overlays.iter().position(|(_, monitor)| monitor.contains(*x, *y)));
        for (index, (label, monitor)) in overlays.iter().enumerate() {
            let marks: Vec<Value> = plan["marks"]
                .as_array()
                .into_iter()
                .flatten()
                .filter_map(|mark| {
                    let (x, y) = (mark["x"].as_i64()? as i32, mark["y"].as_i64()? as i32);
                    if !monitor.contains(x, y) {
                        return None;
                    }
                    let (local_x, local_y) = theo_core::clicky::screens::physical_to_overlay(x, y, monitor);
                    let mut local = json!({"style": mark["style"], "text": mark["text"], "label": mark["label"], "x": local_x, "y": local_y});
                    if let Some(rect) = mark["box"].as_object() {
                        let (bx, by) = theo_core::clicky::screens::physical_to_overlay(rect["x"].as_i64()? as i32, rect["y"].as_i64()? as i32, monitor);
                        local["box"] = json!({"x": bx, "y": by, "width": rect["width"].as_f64()? / monitor.scale, "height": rect["height"].as_f64()? / monitor.scale});
                    }
                    Some(local)
                })
                .collect();
            let mut message = json!({"kind": "answer", "text": speech, "marks": marks, "clearFirst": plan["clear"]});
            if let (Some((x, y, name)), Some(target)) = (&point, point_overlay) {
                if target == index {
                    let (local_x, local_y) = theo_core::clicky::screens::physical_to_overlay(*x, *y, monitor);
                    message["point"] = json!({"x": local_x, "y": local_y, "label": name});
                } else {
                    // The spark is pointing on another monitor: this one's spark steps aside until it's back.
                    message["pointElsewhere"] = true.into();
                }
            }
            self.send_to(label, message);
        }
    }
}

/// The tray's "Show Clicky" item, kept so its tick can follow the setting.
pub struct TrayItem(pub tauri::menu::CheckMenuItem<tauri::Wry>);

/// The tray's "Show Clicky" item: ticked while the spark is always shown. Picking it turns Clicky on (always shown) the
/// first time, then switches between always shown and only while talking.
pub fn tray_item(app: &AppHandle, harness: &Harness) -> tauri::Result<tauri::menu::CheckMenuItem<tauri::Wry>> {
    let checked = theo_core::clicky::is_on(harness) && harness.settings.string(theo_core::clicky::SPARK_SETTING).as_deref() != Some("talking");
    let item = tauri::menu::CheckMenuItem::with_id(app, TRAY_ITEM, "Show Clicky", true, checked, None::<&str>)?;
    app.manage(TrayItem(item.clone()));
    Ok(item)
}

pub fn tray_item_picked(app: &AppHandle) {
    let Some(harness) = app.try_state::<Arc<Harness>>().map(|h| h.inner().clone()) else { return };
    let settings = &harness.settings;
    if !theo_core::clicky::is_on(&harness) {
        settings.set(theo_core::clicky::PRODUCT_SETTING, json!(true));
        settings.set(theo_core::clicky::SPARK_SETTING, json!("always"));
    } else if settings.string(theo_core::clicky::SPARK_SETTING).as_deref() == Some("talking") {
        settings.set(theo_core::clicky::SPARK_SETTING, json!("always"));
    } else {
        settings.set(theo_core::clicky::SPARK_SETTING, json!("talking"));
    }
    if let Some(clicky) = instance() {
        clicky.keep_overlay();
    }
}
