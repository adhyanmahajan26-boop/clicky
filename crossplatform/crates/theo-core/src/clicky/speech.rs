//! Clicky's voice: the answer spoken aloud with the computer's own voices, as the Mac does with `AVSpeechSynthesizer`.
//!
//! - Windows: the built-in SAPI voices through Windows PowerShell's `System.Speech` (in every Windows 10 and 11), run hidden.
//!   The words go in an environment variable, never on the command line, so nothing needs quoting and nothing is cut.
//! - Linux: `spd-say`, `espeak-ng` or `espeak` when one is installed.
//!
//! Speaking runs as its own process so Escape can stop it at once (the process is ended).

use crate::procs::ProcessTree;
use serde_json::{json, Value};
use std::sync::Arc;
#[cfg(windows)]
use std::time::Duration;

/// The most characters spoken from one answer (an environment variable holds 32,767).
pub const MAXIMUM_SPOKEN_CHARACTERS: usize = 30_000;

#[cfg(windows)]
const SPEAK_SCRIPT: &str = r#"$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Speech
$voice = New-Object System.Speech.Synthesis.SpeechSynthesizer
if ($env:THEO_CLICKY_VOICE) { try { $voice.SelectVoice($env:THEO_CLICKY_VOICE) } catch { } }
if ($env:THEO_CLICKY_RATE) { $voice.Rate = [int]$env:THEO_CLICKY_RATE }
if ($env:THEO_CLICKY_WAV) { $voice.SetOutputToWaveFile($env:THEO_CLICKY_WAV) } else { $voice.SetOutputToDefaultAudioDevice() }
$voice.Speak($env:THEO_CLICKY_WORDS)
$voice.Dispose()
"#;

#[cfg(windows)]
const VOICES_SCRIPT: &str = r#"[Console]::OutputEncoding = [Text.Encoding]::UTF8
Add-Type -AssemblyName System.Speech
$voice = New-Object System.Speech.Synthesis.SpeechSynthesizer
foreach ($installed in $voice.GetInstalledVoices()) {
  if ($installed.Enabled) { $info = $installed.VoiceInfo; Write-Output ($info.Name + "`t" + $info.Culture.Name + "`t" + $info.Gender) }
}
"#;

/// A script for `powershell -EncodedCommand`: base64 of its UTF-16LE text.
pub fn encoded_command(script: &str) -> String {
    use base64::Engine as _;
    let bytes: Vec<u8> = script.encode_utf16().flat_map(|unit| unit.to_le_bytes()).collect();
    base64::engine::general_purpose::STANDARD.encode(bytes)
}

/// The words as they should be spoken: markdown symbols that sound odd read aloud are taken out, and it's cut to size.
pub fn words_for_speaking(text: &str) -> String {
    let mut words: String = text.chars().filter(|c| !matches!(c, '*' | '`' | '#' | '_' | '~')).collect();
    if words.chars().count() > MAXIMUM_SPOKEN_CHARACTERS {
        words = words.chars().take(MAXIMUM_SPOKEN_CHARACTERS).collect();
    }
    words.trim().to_string()
}

#[cfg(windows)]
fn powershell() -> std::path::PathBuf {
    #[cfg(windows)]
    {
        if let Some(root) = std::env::var_os("SystemRoot") {
            let full = std::path::PathBuf::from(root).join("System32").join("WindowsPowerShell").join("v1.0").join("powershell.exe");
            if full.is_file() {
                return full;
            }
        }
    }
    std::path::PathBuf::from("powershell.exe")
}

/// The voices this computer can speak with: `[{name, language, gender}]`.
pub async fn voices() -> Result<Vec<Value>, String> {
    #[cfg(windows)]
    {
        let program = powershell();
        let encoded = encoded_command(VOICES_SCRIPT);
        let (code, out, err) = crate::engine::run_briefly(&program, &["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-EncodedCommand", &encoded], &crate::paths::home(), Duration::from_secs(30))
            .await
            .ok_or("Windows PowerShell didn't answer.")?;
        if code != 0 {
            return Err(format!("Windows couldn't list its voices: {}", err.lines().next().unwrap_or("no reason given")));
        }
        Ok(out
            .lines()
            .filter_map(|line| {
                let mut parts = line.trim().split('\t');
                let name = parts.next()?.trim();
                if name.is_empty() {
                    return None;
                }
                Some(json!({"name": name, "language": parts.next().unwrap_or(""), "gender": parts.next().unwrap_or("")}))
            })
            .collect())
    }
    #[cfg(not(windows))]
    {
        Ok(linux_program().map(|(name, _)| vec![json!({"name": name, "language": "", "gender": ""})]).unwrap_or_default())
    }
}

#[cfg(not(windows))]
fn linux_program() -> Option<(&'static str, std::path::PathBuf)> {
    ["spd-say", "espeak-ng", "espeak"].iter().find_map(|name| crate::engine::locate(name).map(|path| (*name, path)))
}

/// One answer being spoken. Dropping it doesn't stop it; `stop` does.
pub struct Speaking {
    tree: Option<Arc<ProcessTree>>,
    child: tokio::sync::Mutex<Option<tokio::process::Child>>,
}

impl Speaking {
    /// Ends the speech now.
    pub fn stop(&self) {
        if let Some(tree) = &self.tree {
            tree.kill();
        }
    }

    /// Waits until the speech has finished (or was stopped).
    pub async fn finished(&self) {
        let mut child = self.child.lock().await;
        if let Some(child) = child.as_mut() {
            let _ = child.wait().await;
        }
    }
}

/// Starts speaking `text` with `voice` (a name from `voices`, or empty for the computer's default). `rate` is -10 to 10.
pub fn speak(text: &str, voice: &str, rate: i32) -> Result<Speaking, String> {
    start(text, voice, rate, None)
}

/// Speaks into a WAV file instead of the speakers (tests, and a computer with no sound device), and waits for it.
pub async fn speak_to_file(text: &str, voice: &str, rate: i32, file: &std::path::Path) -> Result<(), String> {
    let speaking = start(text, voice, rate, Some(file))?;
    speaking.finished().await;
    match std::fs::metadata(file) {
        Ok(meta) if meta.len() > 44 => Ok(()),
        _ => Err("The computer's voice didn't write any sound.".into()),
    }
}

fn start(text: &str, voice: &str, rate: i32, file: Option<&std::path::Path>) -> Result<Speaking, String> {
    let words = words_for_speaking(text);
    if words.is_empty() {
        return Ok(Speaking { tree: None, child: tokio::sync::Mutex::new(None) });
    }
    #[cfg(windows)]
    let mut command = {
        let mut command = crate::engine::background_command(&powershell());
        command
            .args(["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-EncodedCommand", &encoded_command(SPEAK_SCRIPT)])
            .env("THEO_CLICKY_WORDS", &words)
            .env("THEO_CLICKY_VOICE", voice)
            .env("THEO_CLICKY_RATE", rate.clamp(-10, 10).to_string());
        if let Some(file) = file {
            command.env("THEO_CLICKY_WAV", file);
        }
        command
    };
    #[cfg(not(windows))]
    let mut command = {
        let (name, program) = if file.is_some() {
            ["espeak-ng", "espeak"].iter().find_map(|name| crate::engine::locate(name).map(|path| (*name, path))).ok_or("Saving speech to a file needs espeak-ng here.")?
        } else {
            linux_program().ok_or("No speech program is installed (spd-say or espeak-ng).")?
        };
        let mut command = crate::engine::background_command(&program);
        match name {
            "spd-say" => {
                command.arg("--wait");
                command.args(["-r", &(rate.clamp(-10, 10) * 10).to_string()]);
                command.arg("--").arg(&words);
            }
            _ => {
                if !voice.is_empty() && voice != name {
                    command.args(["-v", voice]);
                }
                command.args(["-s", &(175 + rate.clamp(-10, 10) * 10).to_string()]);
                if let Some(file) = file {
                    command.arg("-w").arg(file);
                }
                command.arg("--").arg(&words);
            }
        }
        command
    };
    command.stdin(std::process::Stdio::null()).stdout(std::process::Stdio::null()).stderr(std::process::Stdio::null()).kill_on_drop(false);
    let child = command.spawn().map_err(|e| format!("Couldn't start the computer's voice: {e}"))?;
    let tree = ProcessTree::attach(&child).ok().map(Arc::new);
    Ok(Speaking { tree, child: tokio::sync::Mutex::new(Some(child)) })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn encoded_command_is_utf16_base64() {
        // "a" is 61 00 in UTF-16LE.
        assert_eq!(encoded_command("a"), "YQA=");
    }

    #[test]
    fn spoken_words_lose_markdown() {
        assert_eq!(words_for_speaking("  **click** the `Save` button  "), "click the Save button");
        assert_eq!(words_for_speaking(&"a".repeat(40_000)).len(), MAXIMUM_SPOKEN_CHARACTERS);
    }
}
