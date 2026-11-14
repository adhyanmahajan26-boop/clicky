//! Clicky's push-to-talk on theo-voice: hold the chord (Ctrl + Alt unless Settings › Clicky says otherwise), talk, let go.
//! The microphone and the speech-to-text are Dictation's (the same microphone and recognizer settings), the chord is
//! watched by the keyboard hook, and the words go to `ClickyApp::answer`.

use crate::clicky::{ClickyApp, Phase};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;
use theo_voice::hotkey::{Chord, ChordEvent};
use theo_voice::mic::Recorder;

static RECORDER: Mutex<Option<Recorder>> = Mutex::new(None);
/// Escape or another key while listening: what was recorded is thrown away.
static CANCELLED: AtomicBool = AtomicBool::new(false);
/// Dictation is on with the same chord: both would start on one press, so Clicky stands aside and Settings says so.
static SAME_CHORD_AS_DICTATION: AtomicBool = AtomicBool::new(false);

/// Clicky's chord from the setting (`clicky.shortcut`, a theo-voice chord id), Ctrl + Alt by default.
pub fn chord(clicky: &ClickyApp) -> Chord {
    clicky.harness.settings.string(theo_core::clicky::SHORTCUT_SETTING).and_then(|id| Chord::from_id(&id)).unwrap_or(Chord::CtrlAlt)
}

/// The name Clicky's chord is registered under in theo-voice's one keyboard hook (shared with Dictation).
const HUB_NAME: &str = "clicky";

/// Keeps Clicky's chord in the app's one keyboard hook while Clicky is on, on the chord the settings name.
pub fn start(clicky: Arc<ClickyApp>) {
    std::thread::Builder::new()
        .name("clicky-hotkey".into())
        .spawn(move || {
            let mut registered: Option<Chord> = None;
            loop {
                let dictation_chord = theo_voice::dictation::is_on(&clicky.harness)
                    .then(|| theo_voice::dictation::chord(&clicky.harness));
                let mine = chord(&clicky);
                let clash = theo_core::clicky::is_on(&clicky.harness) && dictation_chord == Some(mine);
                SAME_CHORD_AS_DICTATION.store(clash, Ordering::SeqCst);
                let wanted = if theo_core::clicky::is_on(&clicky.harness) && !clash { Some(mine) } else { None };
                if wanted != registered {
                    match wanted {
                        Some(chord) => {
                            let listener = clicky.clone();
                            theo_voice::hub::register(HUB_NAME, vec![chord], move |_, event| on_event(&listener, event));
                        }
                        None => theo_voice::hub::unregister(HUB_NAME),
                    }
                    registered = wanted;
                }
                std::thread::sleep(Duration::from_secs(1));
            }
        })
        .ok();
}

/// Whether the keyboard hook is listening for Clicky's chord, and why not.
pub fn hook_status() -> serde_json::Value {
    let mut status = serde_json::json!({"listening": theo_voice::hub::is_listening_for(HUB_NAME), "hook": theo_voice::hub::status()});
    if SAME_CHORD_AS_DICTATION.load(Ordering::SeqCst) {
        status["sameChordAsDictation"] = serde_json::json!(true);
    }
    status
}

/// One chord event: pressed starts listening, released sends what was said, cancelled throws it away.
pub fn on_event(clicky: &Arc<ClickyApp>, event: ChordEvent) {
    match event {
        ChordEvent::Pressed => {
            if !theo_core::clicky::is_on(&clicky.harness) {
                return;
            }
            clicky.begin_listening();
            CANCELLED.store(false, Ordering::SeqCst);
            let microphone = theo_voice::dictation::microphone(&clicky.harness);
            match Recorder::start(microphone) {
                Ok(recorder) => {
                    *RECORDER.lock().unwrap() = Some(recorder);
                    // The spark pulses with the voice while it listens.
                    let watcher = clicky.clone();
                    std::thread::spawn(move || loop {
                        let level = match RECORDER.lock().unwrap().as_ref() {
                            Some(recorder) => recorder.level(),
                            None => break,
                        };
                        watcher.show_level(level);
                        std::thread::sleep(Duration::from_millis(50));
                    });
                }
                Err(problem) => clicky.show_note(&problem.to_string(), true),
            }
        }
        ChordEvent::Released => {
            let Some(recorder) = RECORDER.lock().unwrap().take() else { return };
            let audio = recorder.stop();
            if CANCELLED.load(Ordering::SeqCst) || clicky.phase() != Phase::Listening {
                return;
            }
            let audio = match audio {
                Ok(audio) => audio,
                Err(problem) => return clicky.show_note(&problem.to_string(), true),
            };
            // A brush of the keys isn't a question.
            if audio.duration_seconds() < theo_voice::hotkey::MINIMUM_HOLD_SECONDS {
                clicky.stop_everything();
                return;
            }
            let clicky = clicky.clone();
            tauri::async_runtime::spawn(async move {
                clicky.set_phase(Phase::Thinking);
                if audio.peak_level() < 0.02 {
                    return clicky.show_note("i didn't hear anything. check the microphone in settings, dictation.", false);
                }
                let config = theo_voice::dictation::stt_config(&clicky.harness);
                match theo_voice::stt::transcribe(&audio, &config).await {
                    Ok(words) if !words.trim().is_empty() => clicky.answer(words.trim().to_string()).await,
                    Ok(_) => clicky.show_note("i didn't catch that. hold the keys and say it again.", false),
                    Err(problem) => clicky.show_note(&problem.to_string(), true),
                }
            });
        }
        ChordEvent::Cancelled => {
            if RECORDER.lock().unwrap().is_some() {
                cancel_listening();
                clicky.stop_everything();
            }
        }
    }
}

/// Throws away what's being recorded (Escape, a new question).
pub fn cancel_listening() {
    CANCELLED.store(true, Ordering::SeqCst);
    let recorder = RECORDER.lock().unwrap().take();
    drop(recorder);
}
