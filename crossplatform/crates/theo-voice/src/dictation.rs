//! Dictation on Windows: hold the chord in any app, talk, let go, and the tidied words are typed where the cursor is
//! (the Mac's `DictationController`). Also the chat composer's mic button (the Mac's `ComposerDictation`): the same path
//! into the message box, never sent.
//!
//!   chord down   the microphone opens, the pill shows "Listening" and a live level
//!   chord up     the words: the picked recognizer, else the first with a saved key, else Windows' own (`stt`)
//!   clean-up     the instant local pass, then the helper brain if it answers in time (`cleanup`)
//!   insert       paste with the clipboard put back, else typed (`insert`); never into a password field
//!
//! Settings (settings.json): `products.dictation` (the on/off switch, also in Setup and Settings › Products),
//! `dictation.chord`, `dictation.microphone`, `dictation.engine`, `dictation.language`, `dictation.cleanup` (missing = on),
//! `dictation.dictionary`, `dictation.cleanupBrain` / `dictation.cleanupModel`. In a test profile,
//! `test.dictation.baseURL.<engine>` moves a recognizer to a stand-in.
//!
//! Control commands (theod's inbox and the app): `dictationStatus`, `dictationSet`, `dictationKeySet`, `dictationKeyRemove`,
//! `dictationTest {wav, insert?}` (a WAV file through transcribe and clean-up, so CI can check the path with no microphone),
//! and in the app `composerDictation {action: start|level|stop|cancel}`. Reports never carry the words, except
//! `dictationTest`'s and the composer's own answer.

use crate::cleanup::{self, Dictionary};
use crate::hotkey::{self, Chord, ChordEvent};
use crate::mic::{self, Audio, Recorder};
use crate::stt::{self, SttConfig, SttEngine};
use serde_json::{json, Value};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use theo_core::Harness;

pub const PRODUCT_SETTING: &str = "products.dictation";
pub const CHORD_SETTING: &str = "dictation.chord";
pub const MICROPHONE_SETTING: &str = "dictation.microphone";
pub const ENGINE_SETTING: &str = "dictation.engine";
pub const LANGUAGE_SETTING: &str = "dictation.language";
pub const CLEANUP_SETTING: &str = "dictation.cleanup";
pub const DICTIONARY_SETTING: &str = "dictation.dictionary";

/// The keys dictation's recognizers can use (OpenAI's and Groq's are the same keys bots use).
pub const VOICE_KEY_PROVIDERS: [&str; 5] = ["sarvam", "openai", "groq", "deepgram", "assemblyai"];

/// How many levels the pill's waveform shows (the Mac's `DictationController.levelCount`).
pub const LEVEL_COUNT: usize = 18;

pub fn is_on(harness: &Harness) -> bool {
    harness.settings.bool(PRODUCT_SETTING)
}

pub fn chord(harness: &Harness) -> Chord {
    harness.settings.string(CHORD_SETTING).and_then(|id| Chord::from_id(&id)).unwrap_or(Chord::CtrlWin)
}

pub fn uses_cleanup(harness: &Harness) -> bool {
    harness.settings.get(CLEANUP_SETTING).map(|_| harness.settings.bool(CLEANUP_SETTING)).unwrap_or(true)
}

pub fn dictionary(harness: &Harness) -> Dictionary {
    Dictionary::from_lines(&harness.settings.string(DICTIONARY_SETTING).unwrap_or_default())
}

pub fn microphone(harness: &Harness) -> Option<String> {
    harness.settings.string(MICROPHONE_SETTING)
}

/// What a transcription uses now: the picked recognizer and language, the dictionary's words, and the saved keys.
pub fn stt_config(harness: &Harness) -> SttConfig {
    let mut config = SttConfig {
        engine: harness.settings.string(ENGINE_SETTING).and_then(|id| SttEngine::from_id(&id)),
        language: harness.settings.string(LANGUAGE_SETTING).unwrap_or_else(|| "auto".into()),
        keyterms: ["Theo", "Clicky"].iter().map(|word| word.to_string()).chain(dictionary(harness).words()).collect(),
        ..Default::default()
    };
    for provider in VOICE_KEY_PROVIDERS {
        if let Some(key) = theo_core::secrets::read_api_key(&harness.paths.root, harness.settings.is_test, provider) {
            config.keys.insert(provider.to_string(), key);
        }
        if let Some(address) = harness.settings.string(&format!("test.dictation.baseURL.{provider}")) {
            config.base_urls.insert(provider.to_string(), address);
        }
    }
    config
}

/// What the last dictation did, for `dictationStatus` (never the words).
static LAST_REPORT: once_cell::sync::Lazy<Mutex<Value>> = once_cell::sync::Lazy::new(|| Mutex::new(json!({})));

pub fn last_report() -> Value {
    LAST_REPORT.lock().unwrap().clone()
}

/// From audio to the text that goes in.
#[derive(Clone, Debug, Default)]
pub struct Words {
    pub text: String,
    pub heard: String,
    pub engine: String,
    pub problems: Vec<String>,
    pub cleanup: String,
    pub cleanup_brain: Option<String>,
    pub heard_seconds: f64,
    pub cleanup_seconds: f64,
}

impl Words {
    /// The report without the words.
    pub fn report(&self) -> Value {
        json!({"engine": self.engine, "heard": !self.heard.is_empty(), "problems": self.problems, "cleanup": self.cleanup, "cleanupBrain": self.cleanup_brain,
               "heardSeconds": self.heard_seconds, "cleanupSeconds": self.cleanup_seconds, "characters": self.text.chars().count()})
    }
}

/// Transcribe, then tidy. Err is a sentence for the owner ("Didn't catch that" and the like).
pub async fn words_from_audio(harness: &Arc<Harness>, audio: &Audio) -> Result<Words, String> {
    let started = Instant::now();
    if audio.is_empty() || audio.duration_seconds() < 0.15 {
        return Err("Didn't catch that".into());
    }
    if audio.peak_level() < 0.05 {
        return Err("Didn't hear anything. Check the microphone in Settings › Dictation.".into());
    }
    let config = stt_config(harness);
    let transcript = stt::transcribe_detailed(audio, &config).await.map_err(|error| error.to_string())?;
    let heard_seconds = started.elapsed().as_secs_f64();
    let tidied = cleanup::tidy(harness, &transcript.text, &dictionary(harness), uses_cleanup(harness)).await;
    if tidied.text.trim().is_empty() {
        return Err("Didn't catch that".into());
    }
    Ok(Words {
        text: tidied.text,
        heard: transcript.text,
        engine: transcript.engine,
        problems: transcript.problems,
        cleanup: tidied.note,
        cleanup_brain: tidied.brain,
        heard_seconds,
        cleanup_seconds: tidied.seconds,
    })
}

/// Everything Settings › Dictation shows. `slow` also asks which brain would tidy (it may list a provider's models once).
pub async fn status(harness: &Arc<Harness>, slow: bool) -> Value {
    let config = stt_config(harness);
    let engines: Vec<Value> = SttEngine::ALL
        .iter()
        .map(|engine| json!({"id": engine.id(), "title": engine.title(), "ready": config.is_ready(*engine), "key": engine.key_provider(), "hasKey": engine.key_provider().map(|provider| config.keys.contains_key(provider)).unwrap_or(false)}))
        .collect();
    let would_listen: Vec<&str> = config.engines_to_try().iter().map(|engine| engine.id()).collect();
    let chords: Vec<Value> = Chord::ALL.iter().map(|chord| json!({"id": chord.id(), "title": chord.title(), "keys": chord.key_caps()})).collect();
    let languages: Vec<Value> = stt::LANGUAGES.iter().map(|language| json!({"id": language.id, "title": language.title})).collect();
    let mut report = json!({
        "on": is_on(harness),
        "platform": std::env::consts::OS,
        "chord": chord(harness).id(), "chordTitle": chord(harness).title(), "chords": chords,
        "microphone": microphone(harness), "microphones": mic::input_devices(), "defaultMicrophone": mic::default_input_device(),
        "engine": config.engine.unwrap_or(SttEngine::Auto).id(), "engines": engines, "wouldListen": would_listen,
        "nothingCanListen": would_listen.is_empty().then(stt::nothing_can_listen_message),
        "language": if config.language.is_empty() { "auto".to_string() } else { config.language.clone() }, "languages": languages,
        "cleanup": uses_cleanup(harness), "dictionary": harness.settings.string(DICTIONARY_SETTING).unwrap_or_default(),
        "cleanupBrainSetting": harness.settings.string(cleanup::BRAIN_SETTING).unwrap_or_else(|| "auto".into()),
        "last": last_report(),
        "hotkey": hotkey_report(),
    });
    if slow {
        match cleanup::choose_brain(harness).await {
            Some(brain) => report["cleanupBrain"] = brain.label().into(),
            None => report["cleanupNote"] = cleanup::NO_BRAIN_MESSAGE.into(),
        }
    }
    report
}

/// The name dictation registers its chord under in the app's one keyboard hook.
pub const HUB_NAME: &str = "dictation";

fn hotkey_report() -> Value {
    let mut report = crate::hub::status();
    report["dictationListening"] = crate::hub::is_listening_for(HUB_NAME).into();
    report
}

fn s(cmd: &Value, key: &str) -> Option<String> {
    cmd.get(key).and_then(Value::as_str).map(str::to_string)
}

fn ok(result: Value) -> Value {
    theo_core::control::ok(result)
}

fn err(message: &str) -> Value {
    theo_core::control::err(message)
}

/// The commands theod and the app both answer.
pub async fn handle_command(harness: Arc<Harness>, cmd: Value) -> Option<Value> {
    let name = s(&cmd, "cmd")?;
    Some(match name.as_str() {
        "dictationStatus" => ok(status(&harness, cmd.get("slow").and_then(Value::as_bool).unwrap_or(true)).await),
        // One setting of dictation's, checked: {key, value} with key one of chord, microphone, engine, language, cleanup,
        // dictionary, cleanupBrain, on.
        "dictationSet" => {
            let Some(key) = s(&cmd, "key") else { return Some(err("Needs key.")) };
            let value = cmd.get("value").cloned().unwrap_or(Value::Null);
            let text = value.as_str().unwrap_or("").trim().to_string();
            let (setting, stored): (&str, Value) = match key.as_str() {
                "on" => (PRODUCT_SETTING, Value::Bool(value.as_bool().unwrap_or(false))),
                "chord" => match Chord::from_id(&text) {
                    Some(chord) => (CHORD_SETTING, chord.id().into()),
                    None => return Some(err("Theo doesn't know that chord.")),
                },
                "engine" => match SttEngine::from_id(&text) {
                    Some(engine) => (ENGINE_SETTING, engine.id().into()),
                    None => return Some(err("Theo doesn't know that recognizer.")),
                },
                "language" => (LANGUAGE_SETTING, stt::language(&text).id.into()),
                "microphone" => (MICROPHONE_SETTING, if text.is_empty() { Value::Null } else { text.into() }),
                "cleanup" => (CLEANUP_SETTING, Value::Bool(value.as_bool().unwrap_or(true))),
                "dictionary" => (DICTIONARY_SETTING, value.as_str().unwrap_or("").chars().take(4000).collect::<String>().into()),
                "cleanupBrain" => {
                    if !text.is_empty() && text != "auto" && !theo_core::brains::is_known_engine(&text) {
                        return Some(err("Theo doesn't know that brain."));
                    }
                    harness.settings.set(cleanup::MODEL_SETTING, Value::Null);
                    (cleanup::BRAIN_SETTING, if text.is_empty() || text == "auto" { Value::Null } else { text.into() })
                }
                _ => return Some(err("That isn't a dictation setting.")),
            };
            harness.settings.set(setting, stored);
            notify_settings_changed();
            ok(json!({"key": key}))
        }
        "dictationKeySet" => {
            let Some(provider) = s(&cmd, "provider").filter(|provider| VOICE_KEY_PROVIDERS.contains(&provider.as_str())) else { return Some(err("Dictation can't use a key from that provider.")) };
            let Some(key) = s(&cmd, "key").map(|key| key.trim().to_string()).filter(|key| !key.is_empty() && key.len() <= 4096 && !key.chars().any(char::is_control)) else { return Some(err("Paste the key.")) };
            match theo_core::secrets::write_api_key(&harness.paths.root, harness.settings.is_test, &provider, Some(&key)) {
                Ok(()) => ok(json!({"provider": provider, "saved": true})),
                Err(error) => err(&error.to_string()),
            }
        }
        "dictationKeyRemove" => {
            let Some(provider) = s(&cmd, "provider").filter(|provider| VOICE_KEY_PROVIDERS.contains(&provider.as_str())) else { return Some(err("Dictation can't use a key from that provider.")) };
            match theo_core::secrets::write_api_key(&harness.paths.root, harness.settings.is_test, &provider, None) {
                Ok(()) => ok(json!({"provider": provider, "removed": true})),
                Err(error) => err(&error.to_string()),
            }
        }
        // A WAV file through the whole path, as if it were held and let go. Typed where the cursor is only with insert: true.
        "dictationTest" => {
            let Some(path) = s(&cmd, "wav").or_else(|| s(&cmd, "path")) else { return Some(err("Needs wav (a file's path).")) };
            let bytes = match std::fs::read(&path) {
                Ok(bytes) => bytes,
                Err(error) => return Some(err(&format!("Can't read that file: {error}"))),
            };
            let audio = match Audio::from_wav(&bytes) {
                Ok(audio) => audio,
                Err(error) => return Some(err(&error.to_string())),
            };
            let started = Instant::now();
            match words_from_audio(&harness, &audio).await {
                Ok(words) => {
                    let mut report = words.report();
                    let mut inserted = Value::Null;
                    if cmd.get("insert").and_then(Value::as_bool).unwrap_or(false) {
                        let text = words.text.clone();
                        inserted = match tokio::task::spawn_blocking(move || crate::insert::insert(&text)).await {
                            Ok(Ok(outcome)) => json!({"method": outcome.method}),
                            Ok(Err(error)) => json!({"problem": error.to_string()}),
                            Err(_) => json!({"problem": "stopped"}),
                        };
                    }
                    report["totalSeconds"] = started.elapsed().as_secs_f64().into();
                    report["seconds"] = audio.duration_seconds().into();
                    *LAST_REPORT.lock().unwrap() = report.clone();
                    report["text"] = words.text.into();
                    report["raw"] = words.heard.into();
                    report["inserted"] = inserted;
                    ok(report)
                }
                Err(problem) => {
                    *LAST_REPORT.lock().unwrap() = json!({"heard": false, "problem": problem});
                    err(&problem)
                }
            }
        }
        _ => return None,
    })
}

pub fn register_control_commands() {
    theo_core::control_ext::register("dictation", Arc::new(|harness, cmd| Box::pin(handle_command(harness, cmd))));
}

// MARK: The live controller (the app)

static SETTINGS_LISTENERS: once_cell::sync::Lazy<Mutex<Vec<Box<dyn Fn() + Send>>>> = once_cell::sync::Lazy::new(|| Mutex::new(vec![]));

/// Something changed dictation's settings: the controller re-reads them (a new chord, on or off).
pub fn notify_settings_changed() {
    for listener in SETTINGS_LISTENERS.lock().unwrap().iter() {
        listener();
    }
}

/// What the pill shows.
#[derive(Clone, Debug, PartialEq)]
pub enum Phase {
    Idle,
    Listening,
    Transcribing,
    Typed,
    Failed(String),
}

impl Phase {
    pub fn id(&self) -> &'static str {
        match self {
            Phase::Idle => "idle",
            Phase::Listening => "listening",
            Phase::Transcribing => "transcribing",
            Phase::Typed => "typed",
            Phase::Failed(_) => "failed",
        }
    }
}

struct Live {
    phase: Phase,
    recorder: Option<Recorder>,
    pressed_at: Instant,
    session: u64,
    levels: Vec<f32>,
    words: String,
    composer: Option<Recorder>,
}

/// Holds the chord hook, the microphone and the pill's state. The app makes one and shows the pill from `on_pill`.
pub struct Controller {
    harness: Arc<Harness>,
    runtime: tokio::runtime::Handle,
    live: Mutex<Live>,
    on_pill: Box<dyn Fn(Value) + Send + Sync>,
}

impl Controller {
    /// `on_pill` gets the pill's state whenever it changes (and the level while listening): {phase, levels, words,
    /// message, chord}. Phase "idle" means hide it.
    pub fn new(harness: Arc<Harness>, runtime: tokio::runtime::Handle, on_pill: impl Fn(Value) + Send + Sync + 'static) -> Arc<Controller> {
        let controller = Arc::new(Controller {
            harness,
            runtime,
            live: Mutex::new(Live { phase: Phase::Idle, recorder: None, pressed_at: Instant::now(), session: 0, levels: vec![0.0; LEVEL_COUNT], words: String::new(), composer: None }),
            on_pill: Box::new(on_pill),
        });
        let weak = Arc::downgrade(&controller);
        SETTINGS_LISTENERS.lock().unwrap().push(Box::new(move || {
            if let Some(controller) = weak.upgrade() {
                controller.apply_settings();
            }
        }));
        let for_commands = controller.clone();
        theo_core::control_ext::register(
            "dictation-live",
            Arc::new(move |_harness, cmd| {
                let controller = for_commands.clone();
                Box::pin(async move { controller.handle_live_command(cmd).await })
            }),
        );
        controller.apply_settings();
        controller
    }

    /// Registers dictation's chord with the app's one keyboard hook (`hub`), or takes it away, to match the settings.
    pub fn apply_settings(self: &Arc<Self>) {
        if !is_on(&self.harness) {
            crate::hub::unregister(HUB_NAME);
            return;
        }
        let weak = Arc::downgrade(self);
        crate::hub::register(HUB_NAME, vec![chord(&self.harness)], move |chord, event| {
            if let Some(controller) = weak.upgrade() {
                controller.chord_event(chord, event);
            }
        });
    }

    fn show(&self, live: &Live) {
        let message = match &live.phase {
            Phase::Failed(message) => message.clone(),
            _ => String::new(),
        };
        (self.on_pill)(json!({"phase": live.phase.id(), "levels": live.levels, "words": live.words, "message": message, "chord": chord(&self.harness).title()}));
    }

    fn chord_event(self: &Arc<Self>, _chord: Chord, event: ChordEvent) {
        match event {
            ChordEvent::Pressed => self.pressed(),
            ChordEvent::Released => self.released(),
            ChordEvent::Cancelled => self.cancelled(),
        }
    }

    fn pressed(self: &Arc<Self>) {
        let mut live = self.live.lock().unwrap();
        if live.recorder.is_some() || live.composer.is_some() || live.phase == Phase::Transcribing {
            return;
        }
        live.session += 1;
        live.pressed_at = Instant::now();
        live.levels = vec![0.0; LEVEL_COUNT];
        live.words.clear();
        match Recorder::start(microphone(&self.harness)) {
            Ok(recorder) => {
                live.recorder = Some(recorder);
                live.phase = Phase::Listening;
                self.show(&live);
                drop(live);
                self.watch_level();
            }
            Err(error) => {
                live.phase = Phase::Failed(error.to_string());
                self.show(&live);
                let session = live.session;
                drop(live);
                self.hide_later(session, Duration::from_millis(2600));
            }
        }
    }

    /// Feeds the pill the live level while listening.
    fn watch_level(self: &Arc<Self>) {
        let controller = self.clone();
        std::thread::spawn(move || loop {
            std::thread::sleep(Duration::from_millis(60));
            let mut live = controller.live.lock().unwrap();
            let Some(level) = live.recorder.as_ref().map(Recorder::level) else { return };
            if live.phase != Phase::Listening {
                return;
            }
            live.levels.remove(0);
            live.levels.push(level);
            controller.show(&live);
        });
    }

    fn cancelled(self: &Arc<Self>) {
        let mut live = self.live.lock().unwrap();
        if live.recorder.take().is_none() {
            return;
        }
        live.phase = Phase::Idle;
        self.show(&live);
    }

    fn released(self: &Arc<Self>) {
        let mut live = self.live.lock().unwrap();
        // Just brushed the keys.
        if live.pressed_at.elapsed().as_secs_f64() < hotkey::MINIMUM_HOLD_SECONDS {
            drop(live);
            self.cancelled();
            return;
        }
        let Some(recorder) = live.recorder.take() else { return };
        live.phase = Phase::Transcribing;
        self.show(&live);
        let session = live.session;
        drop(live);
        let controller = self.clone();
        self.runtime.spawn(async move {
            let started = Instant::now();
            let audio = match tokio::task::spawn_blocking(move || recorder.stop()).await {
                Ok(Ok(audio)) => audio,
                Ok(Err(error)) => return controller.fail(session, &error.to_string()),
                Err(_) => return controller.fail(session, "The microphone stopped unexpectedly."),
            };
            let words = match words_from_audio(&controller.harness, &audio).await {
                Ok(words) => words,
                Err(problem) => {
                    *LAST_REPORT.lock().unwrap() = json!({"heard": false, "problem": problem, "seconds": audio.duration_seconds()});
                    return controller.fail(session, &problem);
                }
            };
            if controller.live.lock().unwrap().session != session {
                return;
            }
            let text = words.text.clone();
            let outcome = tokio::task::spawn_blocking(move || crate::insert::insert(&text)).await;
            let mut report = words.report();
            report["seconds"] = audio.duration_seconds().into();
            report["totalSeconds"] = started.elapsed().as_secs_f64().into();
            match outcome {
                Ok(Ok(inserted)) => {
                    report["method"] = inserted.method.into();
                    report["inserted"] = true.into();
                    *LAST_REPORT.lock().unwrap() = report;
                    let mut live = controller.live.lock().unwrap();
                    if live.session != session {
                        return;
                    }
                    live.phase = Phase::Typed;
                    live.words = words.text.chars().take(160).collect();
                    controller.show(&live);
                    drop(live);
                    controller.hide_later(session, Duration::from_millis(1400));
                }
                Ok(Err(error)) => {
                    report["inserted"] = false.into();
                    report["problem"] = error.to_string().into();
                    *LAST_REPORT.lock().unwrap() = report;
                    controller.fail(session, &error.to_string());
                }
                Err(_) => controller.fail(session, "Typing stopped unexpectedly."),
            }
        });
    }

    fn fail(self: &Arc<Self>, session: u64, message: &str) {
        let mut live = self.live.lock().unwrap();
        if live.session != session {
            return;
        }
        live.phase = Phase::Failed(message.to_string());
        self.show(&live);
        drop(live);
        // Long messages (what to install, which key to save) stay up longer.
        let seconds = if message.len() > 40 { 6000 } else { 1800 };
        self.hide_later(session, Duration::from_millis(seconds));
    }

    fn hide_later(self: &Arc<Self>, session: u64, after: Duration) {
        let controller = self.clone();
        std::thread::spawn(move || {
            std::thread::sleep(after);
            let mut live = controller.live.lock().unwrap();
            if live.session == session && live.recorder.is_none() && live.phase != Phase::Transcribing {
                live.phase = Phase::Idle;
                controller.show(&live);
            }
        });
    }

    /// The composer's mic button, and the pill shown for a test.
    async fn handle_live_command(self: Arc<Self>, cmd: Value) -> Option<Value> {
        let name = s(&cmd, "cmd")?;
        match name.as_str() {
            "composerDictation" => Some(self.composer(&s(&cmd, "action").unwrap_or_default()).await),
            // `dictationPill {state}`: the pill in a given state, for a screenshot of it (the Mac's uiDictationPill).
            "dictationPill" => {
                let state = s(&cmd, "state").unwrap_or_default();
                let mut live = self.live.lock().unwrap();
                live.session += 1;
                live.phase = match state.as_str() {
                    "listening" => Phase::Listening,
                    "transcribing" => Phase::Transcribing,
                    "typed" => Phase::Typed,
                    "failed" => Phase::Failed("Didn't catch that".into()),
                    _ => Phase::Idle,
                };
                live.levels = (0..LEVEL_COUNT).map(|index| 0.15 + 0.75 * ((index as f32) * 0.7).sin().abs() * (index as f32 + 4.0) / (LEVEL_COUNT as f32 + 4.0)).collect();
                live.words = if live.phase == Phase::Typed { "Typed where your cursor is.".into() } else { String::new() };
                self.show(&live);
                Some(ok(json!({"phase": live.phase.id()})))
            }
            _ => None,
        }
    }

    async fn composer(self: &Arc<Self>, action: &str) -> Value {
        match action {
            "start" => {
                let mut live = self.live.lock().unwrap();
                if live.recorder.is_some() || live.phase == Phase::Transcribing {
                    return err("Dictation is already listening.");
                }
                if live.composer.is_some() {
                    return ok(json!({"listening": true}));
                }
                match Recorder::start(microphone(&self.harness)) {
                    Ok(recorder) => {
                        live.composer = Some(recorder);
                        ok(json!({"listening": true}))
                    }
                    Err(error) => err(&error.to_string()),
                }
            }
            "level" => {
                let live = self.live.lock().unwrap();
                match &live.composer {
                    Some(recorder) => ok(json!({"listening": true, "level": recorder.level(), "seconds": recorder.seconds()})),
                    None => ok(json!({"listening": false})),
                }
            }
            "cancel" => {
                self.live.lock().unwrap().composer = None;
                ok(json!({"listening": false}))
            }
            "stop" => {
                let Some(recorder) = self.live.lock().unwrap().composer.take() else { return err("Dictation isn't listening.") };
                let audio = match tokio::task::spawn_blocking(move || recorder.stop()).await {
                    Ok(Ok(audio)) => audio,
                    Ok(Err(error)) => return err(&error.to_string()),
                    Err(_) => return err("The microphone stopped unexpectedly."),
                };
                match words_from_audio(&self.harness, &audio).await {
                    Ok(words) => {
                        let mut report = words.report();
                        report["seconds"] = audio.duration_seconds().into();
                        report["composer"] = true.into();
                        *LAST_REPORT.lock().unwrap() = report;
                        ok(json!({"text": words.text, "engine": words.engine, "cleanup": words.cleanup}))
                    }
                    Err(problem) => err(&problem),
                }
            }
            _ => err("Needs action: start, level, stop or cancel."),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn harness() -> (tempfile::TempDir, Arc<Harness>) {
        let dir = tempfile::tempdir().unwrap();
        let harness = Harness::new(dir.path().to_path_buf(), true);
        (dir, harness)
    }

    #[tokio::test]
    async fn settings_are_checked_and_kept() {
        let (_dir, harness) = harness();
        assert!(!is_on(&harness));
        assert_eq!(chord(&harness), Chord::CtrlWin);
        assert!(uses_cleanup(&harness));
        let set = |key: &str, value: Value| handle_command(harness.clone(), json!({"cmd": "dictationSet", "key": key, "value": value}));
        assert_eq!(set("chord", "ctrlShiftSpace".into()).await.unwrap()["ok"], true);
        assert_eq!(chord(&harness), Chord::CtrlShiftSpace);
        assert_eq!(set("chord", "fn".into()).await.unwrap()["ok"], false);
        assert_eq!(set("engine", "windows".into()).await.unwrap()["ok"], true);
        assert_eq!(set("engine", "siri".into()).await.unwrap()["ok"], false);
        set("cleanup", false.into()).await;
        assert!(!uses_cleanup(&harness));
        set("on", true.into()).await;
        assert!(is_on(&harness));
        set("dictionary", "Sarvam\ntheo klicky = Theo Clicky".into()).await;
        assert_eq!(dictionary(&harness).words(), vec!["Sarvam", "Theo Clicky"]);
        assert_eq!(set("cleanupBrain", "api:nowhere".into()).await.unwrap()["ok"], false);
        assert_eq!(set("nonsense", "x".into()).await.unwrap()["ok"], false);
        assert!(handle_command(harness.clone(), json!({"cmd": "botsState"})).await.is_none());
    }

    #[tokio::test]
    async fn keys_are_saved_for_voice_providers_only_and_never_reported() {
        let (_dir, harness) = harness();
        let saved = handle_command(harness.clone(), json!({"cmd": "dictationKeySet", "provider": "deepgram", "key": "dg-secret"})).await.unwrap();
        assert_eq!(saved["ok"], true);
        assert_eq!(handle_command(harness.clone(), json!({"cmd": "dictationKeySet", "provider": "anthropic", "key": "x"})).await.unwrap()["ok"], false);
        let config = stt_config(&harness);
        assert_eq!(config.keys.get("deepgram").map(String::as_str), Some("dg-secret"));
        let report = status(&harness, false).await;
        assert!(!report.to_string().contains("dg-secret"));
        assert_eq!(report["wouldListen"][0], "deepgram");
        handle_command(harness.clone(), json!({"cmd": "dictationKeyRemove", "provider": "deepgram"})).await;
        assert!(stt_config(&harness).keys.is_empty());
    }

    #[tokio::test]
    async fn silence_and_bad_files_say_so() {
        let (dir, harness) = harness();
        let silent = dir.path().join("silent.wav");
        std::fs::write(&silent, Audio::from_samples(vec![0; 16_000]).to_wav()).unwrap();
        let answer = handle_command(harness.clone(), json!({"cmd": "dictationTest", "wav": silent})).await.unwrap();
        assert_eq!(answer["ok"], false);
        assert!(answer["error"].as_str().unwrap().contains("Didn't hear anything"));
        let missing = handle_command(harness.clone(), json!({"cmd": "dictationTest", "wav": dir.path().join("nope.wav")})).await.unwrap();
        assert!(missing["error"].as_str().unwrap().contains("Can't read"));
    }
}
