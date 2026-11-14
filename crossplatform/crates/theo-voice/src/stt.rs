//! Speech to text, on the owner's own key or, with none, Windows' own recognizer.
//!
//! Services (requests as the Mac's `CloudListening` and `SarvamClient` make them):
//! - Sarvam Saaras (`POST /speech-to-text`, multipart, `api-subscription-key`), first when its key is saved, as on the Mac;
//! - OpenAI (`gpt-4o-transcribe`, then `whisper-1` if the account can't use it) and Groq (`whisper-large-v3-turbo`), both
//!   `POST /audio/transcriptions`;
//! - Deepgram (`nova-3`, the WAV as the body) and AssemblyAI (upload, create, poll);
//! - Windows' built-in `System.Speech` dictation, through a hidden PowerShell reading the WAV: no key, no network, and
//!   plain words when this PC has no recognizer for its language.
//!
//! "Automatic" tries the services with a saved key in that order and then Windows', so a failed call never loses the words
//! (the Mac keeps what Apple heard for the same reason).

use crate::mic::Audio;
use anyhow::{anyhow, bail, Result};
use serde_json::Value;
use std::collections::HashMap;
use std::time::Duration;

/// A recognizer.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum SttEngine {
    /// The first that works: services with a saved key, then Windows'.
    Auto,
    Sarvam,
    OpenAI,
    Groq,
    Deepgram,
    AssemblyAI,
    /// Windows' own recognizer (System.Speech): no key.
    Windows,
}

impl SttEngine {
    pub const ALL: [SttEngine; 7] = [SttEngine::Auto, SttEngine::Sarvam, SttEngine::OpenAI, SttEngine::Groq, SttEngine::Deepgram, SttEngine::AssemblyAI, SttEngine::Windows];

    /// The order "Automatic" tries them in.
    pub const AUTOMATIC_ORDER: [SttEngine; 6] = [SttEngine::Sarvam, SttEngine::OpenAI, SttEngine::Groq, SttEngine::Deepgram, SttEngine::AssemblyAI, SttEngine::Windows];

    pub fn id(self) -> &'static str {
        match self {
            SttEngine::Auto => "auto",
            SttEngine::Sarvam => "sarvam",
            SttEngine::OpenAI => "openai",
            SttEngine::Groq => "groq",
            SttEngine::Deepgram => "deepgram",
            SttEngine::AssemblyAI => "assemblyai",
            SttEngine::Windows => "windows",
        }
    }

    pub fn from_id(id: &str) -> Option<SttEngine> {
        SttEngine::ALL.iter().copied().find(|engine| engine.id() == id.trim().to_lowercase())
    }

    pub fn title(self) -> &'static str {
        match self {
            SttEngine::Auto => "Automatic",
            SttEngine::Sarvam => "Sarvam (Saaras)",
            SttEngine::OpenAI => "OpenAI",
            SttEngine::Groq => "Groq (Whisper)",
            SttEngine::Deepgram => "Deepgram",
            SttEngine::AssemblyAI => "AssemblyAI",
            SttEngine::Windows => "Windows speech (no key)",
        }
    }

    /// The saved key it needs (the provider id in Theo's keys), if any.
    pub fn key_provider(self) -> Option<&'static str> {
        match self {
            SttEngine::Auto | SttEngine::Windows => None,
            other => Some(other.id()),
        }
    }

    fn default_base_url(self) -> &'static str {
        match self {
            SttEngine::Sarvam => "https://api.sarvam.ai",
            SttEngine::OpenAI => "https://api.openai.com/v1",
            SttEngine::Groq => "https://api.groq.com/openai/v1",
            SttEngine::Deepgram => "https://api.deepgram.com",
            SttEngine::AssemblyAI => "https://api.assemblyai.com",
            SttEngine::Auto | SttEngine::Windows => "",
        }
    }
}

/// A language dictation can be told to expect: the Mac's `DictationSettings.languages`, with Windows' culture names.
pub struct DictationLanguage {
    pub id: &'static str,
    pub title: &'static str,
    /// Sarvam's language_code ("unknown" lets it work it out).
    pub sarvam: &'static str,
    /// ISO-639-1 for OpenAI, Groq and Deepgram; empty lets them detect it.
    pub iso: &'static str,
    /// Windows' culture for its own recognizer; empty means this PC's own language.
    pub windows: &'static str,
}

pub const LANGUAGES: [DictationLanguage; 14] = [
    DictationLanguage { id: "auto", title: "Detect it", sarvam: "unknown", iso: "", windows: "" },
    DictationLanguage { id: "hinglish", title: "Hinglish", sarvam: "hi-IN", iso: "", windows: "en-IN" },
    DictationLanguage { id: "en-IN", title: "English (India)", sarvam: "en-IN", iso: "en", windows: "en-IN" },
    DictationLanguage { id: "en-US", title: "English (US)", sarvam: "en-IN", iso: "en", windows: "en-US" },
    DictationLanguage { id: "hi-IN", title: "Hindi", sarvam: "hi-IN", iso: "hi", windows: "hi-IN" },
    DictationLanguage { id: "bn-IN", title: "Bengali", sarvam: "bn-IN", iso: "bn", windows: "" },
    DictationLanguage { id: "gu-IN", title: "Gujarati", sarvam: "gu-IN", iso: "gu", windows: "" },
    DictationLanguage { id: "kn-IN", title: "Kannada", sarvam: "kn-IN", iso: "kn", windows: "" },
    DictationLanguage { id: "ml-IN", title: "Malayalam", sarvam: "ml-IN", iso: "ml", windows: "" },
    DictationLanguage { id: "mr-IN", title: "Marathi", sarvam: "mr-IN", iso: "mr", windows: "" },
    DictationLanguage { id: "od-IN", title: "Odia", sarvam: "od-IN", iso: "or", windows: "" },
    DictationLanguage { id: "pa-IN", title: "Punjabi", sarvam: "pa-IN", iso: "pa", windows: "" },
    DictationLanguage { id: "ta-IN", title: "Tamil", sarvam: "ta-IN", iso: "ta", windows: "" },
    DictationLanguage { id: "te-IN", title: "Telugu", sarvam: "te-IN", iso: "te", windows: "" },
];

pub fn language(id: &str) -> &'static DictationLanguage {
    LANGUAGES.iter().find(|language| language.id == id).unwrap_or(&LANGUAGES[0])
}

/// What one transcription uses. Build it from Theo's settings and keys with `dictation::stt_config`.
#[derive(Clone, Debug, Default)]
pub struct SttConfig {
    pub engine: Option<SttEngine>,
    /// A language id from [`LANGUAGES`] ("auto" when empty).
    pub language: String,
    /// Words to expect (the owner's dictionary).
    pub keyterms: Vec<String>,
    /// Saved keys by provider id (`sarvam`, `openai`, ...). Never logged.
    pub keys: HashMap<String, String>,
    /// A service's address moved (a test's stand-in), by engine id.
    pub base_urls: HashMap<String, String>,
}

impl SttConfig {
    fn engine(&self) -> SttEngine {
        self.engine.unwrap_or(SttEngine::Auto)
    }

    fn key(&self, engine: SttEngine) -> Option<&str> {
        engine.key_provider().and_then(|provider| self.keys.get(provider)).map(String::as_str).filter(|key| !key.trim().is_empty())
    }

    fn base_url(&self, engine: SttEngine) -> String {
        self.base_urls.get(engine.id()).cloned().unwrap_or_else(|| engine.default_base_url().to_string()).trim_end_matches('/').to_string()
    }

    /// Whether `engine` could run now: its key is saved, or it needs none here.
    pub fn is_ready(&self, engine: SttEngine) -> bool {
        match engine {
            SttEngine::Auto => self.engines_to_try().iter().any(|engine| *engine != SttEngine::Auto),
            SttEngine::Windows => windows_recognizer_possible(),
            other => self.key(other).is_some(),
        }
    }

    /// The engines a transcription tries, in order.
    pub fn engines_to_try(&self) -> Vec<SttEngine> {
        match self.engine() {
            SttEngine::Auto => SttEngine::AUTOMATIC_ORDER.iter().copied().filter(|engine| if *engine == SttEngine::Windows { windows_recognizer_possible() } else { self.key(*engine).is_some() }).collect(),
            // A picked service that fails falls back to Windows' own, so the words aren't lost.
            picked if picked != SttEngine::Windows && windows_recognizer_possible() => vec![picked, SttEngine::Windows],
            picked => vec![picked],
        }
    }
}

/// Windows' own recognizer can be asked here (it may still say it has none for this language).
pub fn windows_recognizer_possible() -> bool {
    cfg!(windows) || std::env::var_os("THEO_TEST_WINDOWS_SPEECH").is_some()
}

/// The words, and which engine heard them.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Transcript {
    pub text: String,
    pub engine: String,
    /// What went wrong on the way (an engine that failed before another heard it), plain words, no keys.
    pub problems: Vec<String>,
}

/// The words in `audio`. Err is a sentence for the owner.
pub async fn transcribe(audio: &Audio, cfg: &SttConfig) -> Result<String> {
    Ok(transcribe_detailed(audio, cfg).await?.text)
}

/// The words in `audio`, which engine heard them, and what failed before it.
pub async fn transcribe_detailed(audio: &Audio, cfg: &SttConfig) -> Result<Transcript> {
    if audio.is_empty() {
        bail!("Nothing was recorded.");
    }
    let engines = cfg.engines_to_try();
    if engines.is_empty() {
        bail!("{}", nothing_can_listen_message());
    }
    let mut problems = vec![];
    for engine in engines {
        match transcribe_with(engine, audio, cfg).await {
            Ok(text) if !text.trim().is_empty() => return Ok(Transcript { text: text.trim().to_string(), engine: engine.id().to_string(), problems }),
            Ok(_) => problems.push(format!("{} heard no words.", engine.title())),
            Err(error) => problems.push(error.to_string()),
        }
    }
    if problems.iter().all(|problem| problem.ends_with("heard no words.")) {
        bail!("Didn't catch that.");
    }
    bail!("{}", problems.join(" "))
}

/// No key saved and not on Windows.
pub fn nothing_can_listen_message() -> String {
    "Nothing here can listen yet. Save a Sarvam, OpenAI, Groq, Deepgram or AssemblyAI key in Settings › Dictation.".to_string()
}

/// One engine's words.
pub async fn transcribe_with(engine: SttEngine, audio: &Audio, cfg: &SttConfig) -> Result<String> {
    if engine == SttEngine::Windows {
        return windows_speech(audio, cfg).await;
    }
    if engine == SttEngine::Auto {
        bail!("Pick one recognizer to ask.");
    }
    let key = cfg.key(engine).ok_or_else(|| anyhow!("No {} key is saved.", engine.title()))?.to_string();
    let base = cfg.base_url(engine);
    let language = language(&cfg.language);
    let keyterms = cfg.keyterms.clone();
    let audio = audio.clone();
    tokio::task::spawn_blocking(move || match engine {
        SttEngine::Sarvam => sarvam(&base, &key, &audio, language, &keyterms),
        SttEngine::OpenAI => openai_style(engine, &base, &key, &audio, language, &keyterms, &["gpt-4o-transcribe", "whisper-1"]),
        SttEngine::Groq => openai_style(engine, &base, &key, &audio, language, &keyterms, &["whisper-large-v3-turbo", "whisper-large-v3"]),
        SttEngine::Deepgram => deepgram(&base, &key, &audio, language, &keyterms),
        SttEngine::AssemblyAI => assembly_ai(&base, &key, &audio, language),
        SttEngine::Auto | SttEngine::Windows => unreachable!(),
    })
    .await
    .map_err(|_| anyhow!("The transcription stopped unexpectedly."))?
}

// MARK: Requests

fn agent(address: &str) -> ureq::Agent {
    let local = address.starts_with("http://127.0.0.1") || address.starts_with("http://localhost");
    ureq::AgentBuilder::new().timeout_connect(Duration::from_secs(15)).timeout(Duration::from_secs(90)).try_proxy_from_env(!local).user_agent(concat!("theo/", env!("CARGO_PKG_VERSION"))).build()
}

/// A multipart/form-data body: fields, then one file.
pub fn multipart_body(boundary: &str, fields: &[(&str, String)], file_field: &str, file_name: &str, file_type: &str, file: &[u8]) -> Vec<u8> {
    let mut body = Vec::with_capacity(file.len() + 512);
    for (name, value) in fields {
        body.extend_from_slice(format!("--{boundary}\r\nContent-Disposition: form-data; name=\"{name}\"\r\n\r\n{value}\r\n").as_bytes());
    }
    body.extend_from_slice(format!("--{boundary}\r\nContent-Disposition: form-data; name=\"{file_field}\"; filename=\"{file_name}\"\r\nContent-Type: {file_type}\r\n\r\n").as_bytes());
    body.extend_from_slice(file);
    body.extend_from_slice(format!("\r\n--{boundary}--\r\n").as_bytes());
    body
}

fn boundary() -> String {
    format!("TheoBoundary-{}", uuid::Uuid::new_v4().simple())
}

/// The service's own words for a refusal (`error.message`, `message`, `detail`...), cut short, never the request.
pub fn service_said(body: &str) -> String {
    let parsed: Option<Value> = serde_json::from_str(body).ok();
    let said = parsed.as_ref().and_then(|value| {
        value["error"]["message"].as_str().or_else(|| value["error"].as_str()).or_else(|| value["message"].as_str()).or_else(|| value["detail"].as_str()).or_else(|| value["err_msg"].as_str()).map(str::to_string)
    });
    let said = said.unwrap_or_else(|| body.trim().to_string());
    let said: String = said.chars().take(200).collect();
    if said.is_empty() { "no reason given".to_string() } else { said }
}

/// A failed request in words: a refused key says to check it.
pub fn refusal_sentence(service: &str, status: u16, body: &str) -> String {
    match status {
        401 | 403 => format!("{service} didn't accept the saved key ({status}). Check it in Settings › Dictation."),
        429 => format!("{service} says too many requests or no credit left (429): {}", service_said(body)),
        _ => format!("{service} answered {status}: {}", service_said(body)),
    }
}

enum Sent {
    Answer(String),
    Refused(u16, String),
}

fn send(request: ureq::Request, body: &[u8], service: &str) -> Result<Sent> {
    match request.send_bytes(body) {
        Ok(response) => Ok(Sent::Answer(response.into_string().map_err(|error| anyhow!("{service}'s answer broke off: {error}"))?)),
        Err(ureq::Error::Status(status, response)) => Ok(Sent::Refused(status, response.into_string().unwrap_or_default())),
        Err(ureq::Error::Transport(transport)) => Err(anyhow!("Couldn't reach {service}: {}", transport.message().map(str::to_string).unwrap_or_else(|| format!("{:?}", transport.kind())))),
    }
}

fn openai_style(engine: SttEngine, base: &str, key: &str, audio: &Audio, language: &DictationLanguage, keyterms: &[String], models: &[&str]) -> Result<String> {
    let service = engine.title();
    let wav = audio.to_wav();
    let address = format!("{base}/audio/transcriptions");
    let mut last_problem = String::new();
    for model in models {
        let boundary = boundary();
        let mut fields: Vec<(&str, String)> = vec![("model", model.to_string()), ("response_format", "json".to_string())];
        if !language.iso.is_empty() {
            fields.push(("language", language.iso.to_string()));
        }
        if !keyterms.is_empty() {
            fields.push(("prompt", keyterms.join(", ")));
        }
        let body = multipart_body(&boundary, &fields, "file", "audio.wav", "audio/wav", &wav);
        let request = agent(&address).post(&address).set("Authorization", &format!("Bearer {key}")).set("Content-Type", &format!("multipart/form-data; boundary={boundary}"));
        match send(request, &body, service)? {
            Sent::Answer(text) => return openai_transcript(&text).ok_or_else(|| anyhow!("{service} gave an answer Theo couldn't read.")),
            // An account without this model: the next one.
            Sent::Refused(status @ (400 | 403 | 404), body) if service_said(&body).to_lowercase().contains("model") => last_problem = refusal_sentence(service, status, &body),
            Sent::Refused(status, body) => return Err(anyhow!(refusal_sentence(service, status, &body))),
        }
    }
    Err(anyhow!(last_problem))
}

pub fn openai_transcript(body: &str) -> Option<String> {
    serde_json::from_str::<Value>(body).ok()?["text"].as_str().map(str::to_string)
}

fn sarvam(base: &str, key: &str, audio: &Audio, language: &DictationLanguage, keyterms: &[String]) -> Result<String> {
    // Hinglish (and "detect it") needs its own mode: Hindi and English each stay in their own words.
    let mode = if language.id == "hinglish" || language.id == "auto" { "codemix" } else { "transcribe" };
    let address = format!("{base}/speech-to-text");
    let mut pieces = vec![];
    for chunk in audio.wav_chunks(28) {
        let mut with_mode = true;
        loop {
            let boundary = boundary();
            let fields = sarvam_fields(mode, with_mode, language.sarvam, keyterms);
            let body = multipart_body(&boundary, &fields, "file", "audio.wav", "audio/wav", &chunk);
            let request = agent(&address).post(&address).set("api-subscription-key", key).set("Content-Type", &format!("multipart/form-data; boundary={boundary}"));
            match send(request, &body, "Sarvam")? {
                Sent::Answer(text) => {
                    pieces.push(sarvam_transcript(&text).ok_or_else(|| anyhow!("Sarvam gave an answer Theo couldn't read."))?);
                    break;
                }
                // The docs disagree on whether this model takes `mode`: once more without it (as the Mac does).
                Sent::Refused(400 | 422, body) if with_mode && service_said(&body).to_lowercase().contains("mode") => with_mode = false,
                Sent::Refused(status, body) => return Err(anyhow!(refusal_sentence("Sarvam", status, &body))),
            }
        }
    }
    Ok(pieces.join(" ").trim().to_string())
}

pub fn sarvam_fields(mode: &str, with_mode: bool, language_code: &str, keyterms: &[String]) -> Vec<(&'static str, String)> {
    let mut fields: Vec<(&'static str, String)> = vec![("model", "saaras:v4".to_string())];
    if with_mode {
        fields.push(("mode", mode.to_string()));
    }
    fields.push(("language_code", language_code.to_string()));
    // saaras:v4 only: words to expect, up to 50 of up to 64 characters.
    if !keyterms.is_empty() {
        let terms: Vec<String> = keyterms.iter().take(50).map(|term| term.chars().take(64).collect()).collect();
        fields.push(("keyterms", serde_json::to_string(&terms).unwrap_or_default()));
    }
    fields
}

pub fn sarvam_transcript(body: &str) -> Option<String> {
    serde_json::from_str::<Value>(body).ok()?["transcript"].as_str().map(str::to_string)
}

fn deepgram(base: &str, key: &str, audio: &Audio, language: &DictationLanguage, keyterms: &[String]) -> Result<String> {
    let address = deepgram_address(base, language, keyterms);
    let request = agent(&address).post(&address).set("Authorization", &format!("Token {key}")).set("Content-Type", "audio/wav");
    match send(request, &audio.to_wav(), "Deepgram")? {
        Sent::Answer(text) => deepgram_transcript(&text).ok_or_else(|| anyhow!("Deepgram gave an answer Theo couldn't read.")),
        Sent::Refused(status, body) => Err(anyhow!(refusal_sentence("Deepgram", status, &body))),
    }
}

pub fn deepgram_address(base: &str, language: &DictationLanguage, keyterms: &[String]) -> String {
    let mut address = format!("{base}/v1/listen?model=nova-3&smart_format=true");
    if language.iso.is_empty() {
        address.push_str("&detect_language=true");
    } else {
        address.push_str(&format!("&language={}", language.iso));
    }
    for term in keyterms.iter().take(50) {
        address.push_str(&format!("&keyterm={}", percent_encode(term)));
    }
    address
}

fn percent_encode(text: &str) -> String {
    text.bytes().map(|byte| if byte.is_ascii_alphanumeric() || b"-_.~".contains(&byte) { (byte as char).to_string() } else { format!("%{byte:02X}") }).collect()
}

pub fn deepgram_transcript(body: &str) -> Option<String> {
    serde_json::from_str::<Value>(body).ok()?["results"]["channels"][0]["alternatives"][0]["transcript"].as_str().map(str::to_string)
}

fn assembly_ai(base: &str, key: &str, audio: &Audio, language: &DictationLanguage) -> Result<String> {
    let upload_address = format!("{base}/v2/upload");
    let upload = agent(&upload_address).post(&upload_address).set("Authorization", key).set("Content-Type", "application/octet-stream");
    let audio_url = match send(upload, &audio.to_wav(), "AssemblyAI")? {
        Sent::Answer(text) => serde_json::from_str::<Value>(&text).ok().and_then(|value| value["upload_url"].as_str().map(str::to_string)).ok_or_else(|| anyhow!("AssemblyAI gave no upload address."))?,
        Sent::Refused(status, body) => return Err(anyhow!(refusal_sentence("AssemblyAI", status, &body))),
    };
    let create_address = format!("{base}/v2/transcript");
    let mut create_body = serde_json::json!({"audio_url": audio_url});
    if language.iso.is_empty() {
        create_body["language_detection"] = true.into();
    } else {
        create_body["language_code"] = language.iso.into();
    }
    let create = agent(&create_address).post(&create_address).set("Authorization", key).set("Content-Type", "application/json");
    let id = match send(create, create_body.to_string().as_bytes(), "AssemblyAI")? {
        Sent::Answer(text) => serde_json::from_str::<Value>(&text).ok().and_then(|value| value["id"].as_str().map(str::to_string)).ok_or_else(|| anyhow!("AssemblyAI gave no transcript id."))?,
        Sent::Refused(status, body) => return Err(anyhow!(refusal_sentence("AssemblyAI", status, &body))),
    };
    let read_address = format!("{base}/v2/transcript/{id}");
    for _ in 0..60 {
        std::thread::sleep(Duration::from_millis(500));
        let read = agent(&read_address).get(&read_address).set("Authorization", key);
        let text = match read.call() {
            Ok(response) => response.into_string().unwrap_or_default(),
            Err(ureq::Error::Status(status, response)) => return Err(anyhow!(refusal_sentence("AssemblyAI", status, &response.into_string().unwrap_or_default()))),
            Err(_) => continue,
        };
        let value: Value = serde_json::from_str(&text).unwrap_or_default();
        match value["status"].as_str() {
            Some("completed") => return Ok(value["text"].as_str().unwrap_or("").to_string()),
            Some("error") => return Err(anyhow!("AssemblyAI: {}", value["error"].as_str().unwrap_or("failed"))),
            _ => continue,
        }
    }
    Err(anyhow!("AssemblyAI took too long."))
}

// MARK: Windows' own recognizer

/// What the hidden PowerShell runs: System.Speech's dictation grammar over the WAV file. It prints one line it was asked
/// for (`THEO-WORDS:`, `THEO-NO-RECOGNIZER`, `THEO-NO-LANGUAGE:<culture>|<installed>`, `THEO-FAILED:`), read by
/// [`read_windows_speech_output`].
pub const WINDOWS_SPEECH_SCRIPT: &str = r#"
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
try {
  Add-Type -AssemblyName System.Speech
  $all = @([System.Speech.Recognition.SpeechRecognitionEngine]::InstalledRecognizers())
  if ($all.Count -eq 0) { Write-Output 'THEO-NO-RECOGNIZER'; exit 0 }
  $wanted = $env:THEO_SPEECH_CULTURE
  $mine = [System.Globalization.CultureInfo]::CurrentUICulture
  $info = $null
  if ($wanted) { $info = $all | Where-Object { $_.Culture.Name -eq $wanted } | Select-Object -First 1 }
  if (-not $info) { $info = $all | Where-Object { $_.Culture.Name -eq $mine.Name } | Select-Object -First 1 }
  if (-not $info) { $info = $all | Where-Object { $_.Culture.TwoLetterISOLanguageName -eq $mine.TwoLetterISOLanguageName } | Select-Object -First 1 }
  if (-not $info -and $wanted) { $info = $all | Where-Object { $_.Culture.TwoLetterISOLanguageName -eq $wanted.Substring(0, 2) } | Select-Object -First 1 }
  if (-not $info) {
    $names = ($all | ForEach-Object { $_.Culture.Name }) -join ','
    $asked = if ($wanted) { $wanted } else { $mine.Name }
    Write-Output ("THEO-NO-LANGUAGE:" + $asked + "|" + $names); exit 0
  }
  $engine = New-Object System.Speech.Recognition.SpeechRecognitionEngine($info)
  $engine.LoadGrammar((New-Object System.Speech.Recognition.DictationGrammar))
  $engine.SetInputToWaveFile($env:THEO_SPEECH_WAV)
  $total = [TimeSpan]::FromSeconds([double]::Parse($env:THEO_SPEECH_SECONDS, [System.Globalization.CultureInfo]::InvariantCulture))
  $words = New-Object System.Collections.Generic.List[string]
  for ($i = 0; $i -lt 400; $i++) {
    # At the end of the file System.Speech lets go of its input, and the next Recognize says "No audio input is
    # supplied": that's the end of the words, not a failure.
    try { $result = $engine.Recognize() } catch [System.InvalidOperationException] { if ($i -gt 0) { break } else { throw } }
    if ($result -ne $null -and $result.Text) { $words.Add($result.Text) }
    elseif ($engine.RecognizerAudioPosition -ge ($total - [TimeSpan]::FromMilliseconds(300))) { break }
    if ($engine.RecognizerAudioPosition -ge $total) { break }
  }
  $engine.Dispose()
  Write-Output ("THEO-WORDS:" + (($words -join ' ') -replace "`r|`n", ' '))
} catch {
  Write-Output ("THEO-FAILED:" + ($_.Exception.Message -replace "`r|`n", ' '))
}
"#;

/// The words from the script's output, or a sentence for the owner.
pub fn read_windows_speech_output(output: &str) -> std::result::Result<String, String> {
    for line in output.lines() {
        let line = line.trim().trim_start_matches('\u{feff}');
        if let Some(words) = line.strip_prefix("THEO-WORDS:") {
            return Ok(words.trim().to_string());
        }
        if line == "THEO-NO-RECOGNIZER" {
            return Err("This PC has no Windows speech recognizer installed. Add a speech language in Windows Settings › Time & language › Language & region (pick the language, then Language options › Speech), or save a Sarvam, OpenAI, Groq, Deepgram or AssemblyAI key in Settings › Dictation.".to_string());
        }
        if let Some(rest) = line.strip_prefix("THEO-NO-LANGUAGE:") {
            let (asked, installed) = rest.split_once('|').unwrap_or((rest, ""));
            let installed = if installed.trim().is_empty() { "none".to_string() } else { installed.replace(',', ", ") };
            return Err(format!("Windows has no speech recognizer for {asked} on this PC (it has: {installed}). Add one in Windows Settings › Time & language › Language & region › Language options › Speech, pick another language in Settings › Dictation, or save a Sarvam, OpenAI, Groq, Deepgram or AssemblyAI key there."));
        }
        if let Some(problem) = line.strip_prefix("THEO-FAILED:") {
            return Err(format!("Windows' speech recognizer failed: {}", problem.trim()));
        }
    }
    Err("Windows' speech recognizer gave no answer.".to_string())
}

/// PowerShell's -EncodedCommand: the script as UTF-16LE, base64.
pub fn encoded_command(script: &str) -> String {
    use base64::Engine;
    let bytes: Vec<u8> = script.encode_utf16().flat_map(|unit| unit.to_le_bytes()).collect();
    base64::engine::general_purpose::STANDARD.encode(bytes)
}

async fn windows_speech(audio: &Audio, cfg: &SttConfig) -> Result<String> {
    if !windows_recognizer_possible() {
        bail!("Windows' own recognizer is only on Windows.");
    }
    let folder = std::env::temp_dir().join("theo-dictation");
    let _ = std::fs::create_dir_all(&folder);
    let file = folder.join(format!("{}.wav", uuid::Uuid::new_v4().simple()));
    std::fs::write(&file, audio.to_wav())?;
    let removal = RemoveFile(file.clone());
    // A test can play Windows with a script of its own (`THEO_TEST_WINDOWS_SPEECH` names a program that prints the lines).
    let program = std::env::var_os("THEO_TEST_WINDOWS_SPEECH").map(std::path::PathBuf::from).unwrap_or_else(|| std::path::PathBuf::from("powershell.exe"));
    let mut command = theo_core::engine::background_command(&program);
    command
        .args(["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-EncodedCommand", &encoded_command(WINDOWS_SPEECH_SCRIPT)])
        .env("THEO_SPEECH_WAV", &file)
        .env("THEO_SPEECH_SECONDS", format!("{:.3}", audio.duration_seconds()))
        .env("THEO_SPEECH_CULTURE", language(&cfg.language).windows)
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        .kill_on_drop(true);
    let limit = Duration::from_secs_f64(30.0 + audio.duration_seconds() * 2.0);
    let output = tokio::time::timeout(limit, command.output())
        .await
        .map_err(|_| anyhow!("Windows' speech recognizer took too long."))?
        .map_err(|error| anyhow!("Windows' speech recognizer couldn't start: {error}"))?;
    drop(removal);
    read_windows_speech_output(&String::from_utf8_lossy(&output.stdout)).map_err(|message| anyhow!(message))
}

struct RemoveFile(std::path::PathBuf);
impl Drop for RemoveFile {
    fn drop(&mut self) {
        let _ = std::fs::remove_file(&self.0);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn config(keys: &[(&str, &str)]) -> SttConfig {
        SttConfig { keys: keys.iter().map(|(provider, key)| (provider.to_string(), key.to_string())).collect(), ..Default::default() }
    }

    #[test]
    fn automatic_tries_saved_keys_in_the_macs_order() {
        let cfg = config(&[("openai", "sk-1"), ("sarvam", "sk-2"), ("deepgram", " ")]);
        let engines = cfg.engines_to_try();
        assert_eq!(&engines[..2], &[SttEngine::Sarvam, SttEngine::OpenAI]);
        assert!(!engines.contains(&SttEngine::Deepgram), "a blank key isn't a key");
        assert_eq!(engines.contains(&SttEngine::Windows), windows_recognizer_possible());
        let mut picked = config(&[("groq", "gsk")]);
        picked.engine = Some(SttEngine::Groq);
        assert_eq!(picked.engines_to_try()[0], SttEngine::Groq);
        assert!(picked.is_ready(SttEngine::Groq) && !picked.is_ready(SttEngine::OpenAI));
    }

    #[test]
    fn ids_round_trip() {
        for engine in SttEngine::ALL {
            assert_eq!(SttEngine::from_id(engine.id()), Some(engine));
        }
        assert_eq!(SttEngine::from_id("whisper"), None);
        assert_eq!(language("hinglish").sarvam, "hi-IN");
        assert_eq!(language("nope").id, "auto");
    }

    #[test]
    fn answers_are_read() {
        assert_eq!(openai_transcript(r#"{"text":"hello there"}"#).as_deref(), Some("hello there"));
        assert_eq!(sarvam_transcript(r#"{"transcript":"namaste","language_code":"hi-IN"}"#).as_deref(), Some("namaste"));
        assert_eq!(deepgram_transcript(r#"{"results":{"channels":[{"alternatives":[{"transcript":"hi","confidence":0.9}]}]}}"#).as_deref(), Some("hi"));
        assert_eq!(deepgram_transcript("{}"), None);
    }

    #[test]
    fn requests_are_built_like_the_macs() {
        let fields = sarvam_fields("codemix", true, "hi-IN", &["Theo".into(), "x".repeat(80)]);
        assert_eq!(fields[0], ("model", "saaras:v4".to_string()));
        assert_eq!(fields[1], ("mode", "codemix".to_string()));
        assert_eq!(fields[2], ("language_code", "hi-IN".to_string()));
        assert!(fields[3].1.starts_with("[\"Theo\",\"xxxx") && !fields[3].1.contains(&"x".repeat(65)));
        assert_eq!(sarvam_fields("transcribe", false, "en-IN", &[]).len(), 2);
        let body = multipart_body("B", &[("model", "m".into())], "file", "audio.wav", "audio/wav", b"RIFF");
        let text = String::from_utf8(body).unwrap();
        assert!(text.starts_with("--B\r\nContent-Disposition: form-data; name=\"model\"\r\n\r\nm\r\n--B\r\n"));
        assert!(text.contains("filename=\"audio.wav\"\r\nContent-Type: audio/wav\r\n\r\nRIFF\r\n--B--\r\n"));
        let address = deepgram_address("https://api.deepgram.com", language("en-US"), &["Theo Clicky".into()]);
        assert_eq!(address, "https://api.deepgram.com/v1/listen?model=nova-3&smart_format=true&language=en&keyterm=Theo%20Clicky");
        assert!(deepgram_address("x", language("auto"), &[]).ends_with("&detect_language=true"));
    }

    #[test]
    fn refusals_say_what_to_do_without_the_key() {
        let sentence = refusal_sentence("OpenAI", 401, r#"{"error":{"message":"Incorrect API key provided: sk-abc"}}"#);
        assert!(sentence.contains("Settings › Dictation"));
        assert!(!sentence.contains("sk-abc"));
        assert_eq!(refusal_sentence("Deepgram", 500, "boom"), "Deepgram answered 500: boom");
    }

    #[test]
    fn windows_output_is_read_into_plain_words() {
        assert_eq!(read_windows_speech_output("\u{feff}THEO-WORDS: hello world \r\n"), Ok("hello world".to_string()));
        assert!(read_windows_speech_output("THEO-NO-RECOGNIZER").unwrap_err().contains("Language & region"));
        let missing = read_windows_speech_output("THEO-NO-LANGUAGE:hi-IN|en-US,en-GB").unwrap_err();
        assert!(missing.contains("hi-IN") && missing.contains("en-US, en-GB"), "{missing}");
        assert!(read_windows_speech_output("THEO-FAILED:bad wave").unwrap_err().contains("bad wave"));
        assert!(read_windows_speech_output("").is_err());
    }

    #[test]
    fn the_script_is_encoded_for_powershell() {
        use base64::Engine;
        let encoded = encoded_command("Write-Output 'é'");
        let bytes = base64::engine::general_purpose::STANDARD.decode(encoded).unwrap();
        let units: Vec<u16> = bytes.chunks(2).map(|pair| u16::from_le_bytes([pair[0], pair[1]])).collect();
        assert_eq!(String::from_utf16(&units).unwrap(), "Write-Output 'é'");
        assert!(WINDOWS_SPEECH_SCRIPT.contains("SetInputToWaveFile") && WINDOWS_SPEECH_SCRIPT.contains("DictationGrammar"));
    }

    #[tokio::test]
    async fn nothing_recorded_and_nothing_to_listen_are_plain() {
        let cfg = config(&[]);
        assert!(transcribe(&Audio::default(), &cfg).await.unwrap_err().to_string().contains("Nothing was recorded"));
        if !windows_recognizer_possible() {
            let error = transcribe(&Audio::from_samples(vec![0; 1600]), &cfg).await.unwrap_err().to_string();
            assert!(error.contains("Settings › Dictation"), "{error}");
        }
    }
}
