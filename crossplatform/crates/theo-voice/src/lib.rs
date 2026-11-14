//! Theo's voice foundation, shared by Dictation and Clicky on Windows (the Mac has its own in Swift).
//!
//! - [`hotkey`]: one low-level keyboard hook that watches several chords at once (hold Ctrl + Win to dictate, Ctrl + Alt for
//!   Clicky), with the chord rules pure and tested anywhere.
//! - [`mic`]: the microphone through WASAPI, and the recorded audio as 16 kHz mono PCM16 with a WAV writer and reader.
//! - [`stt`]: speech to text on the owner's own key (Sarvam, OpenAI, Groq, Deepgram, AssemblyAI) or, with no key, Windows'
//!   own recognizer.
//! - [`insert`]: the words typed where the cursor is (paste, with the clipboard put back, else typed), never into a password.
//! - [`cleanup`]: the Mac's dictation clean-up rules (ClickyCore `Voice/Dictation.swift`) and the helper brain that tidies.
//! - [`dictation`]: the whole path from audio to text, its settings and its control commands (`dictationTest` and friends).
//!
//! Every Windows-only part has a stand-in with the same API elsewhere, so the workspace builds on Linux and the Mac.

pub mod hotkey;
pub mod mic;
pub mod stt;
pub mod insert;
pub mod cleanup;
pub mod dictation;

/// Adds dictation's control commands to theo-core's control inbox (and the desktop app's `control`). Call once at start.
pub fn register_control_commands() {
    dictation::register_control_commands();
}
