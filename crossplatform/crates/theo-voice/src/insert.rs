//! Putting words where the cursor is, in whatever app is in front.
//!
//! As the Mac's `DictationInserter` falls back to Paste: here Paste comes first, since Windows has no Accessibility insert
//! that works in every app. The clipboard is saved, the words put on it (marked so Windows' clipboard history doesn't keep
//! them), Ctrl+V is sent, and after a moment the clipboard is put back, unless something else changed it meanwhile. When
//! the clipboard can't be opened, the words are typed instead (`SendInput` with `KEYEVENTF_UNICODE`).
//!
//! Never into a password field when Windows can tell: UI Automation's IsPassword on the focused element, and the classic
//! password style on a plain edit box.

use anyhow::{bail, Result};

/// How the words went in.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct InsertOutcome {
    /// "paste" or "typed".
    pub method: &'static str,
}

/// How long the words stay on the clipboard before the owner's own clipboard is put back.
pub const CLIPBOARD_RESTORE_MILLISECONDS: u64 = 450;

pub const PASSWORD_REFUSAL: &str = "That's a password field, so Theo didn't type there.";

/// The text as it is typed: Windows line ends, no stray carriage returns or control characters.
pub fn text_for_typing(text: &str) -> String {
    let normalized = text.replace("\r\n", "\n").replace('\r', "\n");
    normalized.chars().filter(|character| *character == '\n' || *character == '\t' || !character.is_control()).collect::<String>().replace('\n', "\r\n")
}

/// The words typed where the cursor is. Blocking (it waits a moment for the paste): call it off the async runtime.
pub fn insert(text: &str) -> Result<InsertOutcome> {
    let text = text_for_typing(text);
    if text.trim().is_empty() {
        bail!("There were no words to type.");
    }
    #[cfg(windows)]
    {
        windows_insert::insert(&text)
    }
    #[cfg(not(windows))]
    {
        bail!("Typing into other apps works on Windows only in this build.")
    }
}

/// Whether the focused field looks like a password (false when Windows can't say).
pub fn focused_field_is_password() -> bool {
    #[cfg(windows)]
    {
        windows_insert::focused_field_is_password()
    }
    #[cfg(not(windows))]
    {
        false
    }
}

#[cfg(windows)]
mod windows_insert {
    use super::*;
    use std::time::Duration;
    use windows::core::w;
    use windows::Win32::Foundation::{HANDLE, HGLOBAL, HWND};
    use windows::Win32::System::Com::{CoCreateInstance, CoInitializeEx, CoUninitialize, CLSCTX_INPROC_SERVER, COINIT_MULTITHREADED};
    use windows::Win32::System::DataExchange::{
        CloseClipboard, EmptyClipboard, EnumClipboardFormats, GetClipboardData, GetClipboardSequenceNumber, OpenClipboard, RegisterClipboardFormatW, SetClipboardData,
    };
    use windows::Win32::System::Memory::{GlobalAlloc, GlobalLock, GlobalSize, GlobalUnlock, GMEM_MOVEABLE};
    use windows::Win32::UI::Accessibility::{CUIAutomation, IUIAutomation};
    use windows::Win32::UI::Input::KeyboardAndMouse::{SendInput, INPUT, INPUT_0, INPUT_KEYBOARD, KEYBDINPUT, KEYBD_EVENT_FLAGS, KEYEVENTF_KEYUP, KEYEVENTF_UNICODE, VIRTUAL_KEY, VK_CONTROL, VK_RETURN, VK_V};
    use windows::Win32::UI::WindowsAndMessaging::{GetClassNameW, GetForegroundWindow, GetGUIThreadInfo, GetWindowLongW, GetWindowThreadProcessId, GUITHREADINFO, GWL_STYLE};

    const CF_UNICODETEXT: u32 = 13;
    const ES_PASSWORD: i32 = 0x20;
    /// Clipboard formats whose data is a GDI handle, not memory: they can't be copied as bytes (Windows makes the bitmap
    /// and metafile forms again from the DIB and enhanced forms).
    const HANDLE_FORMATS: [u32; 8] = [2, 3, 9, 14, 0x80, 0x82, 0x83, 0x8E];

    pub fn focused_field_is_password() -> bool {
        classic_password_box() || automation_says_password()
    }

    fn classic_password_box() -> bool {
        unsafe {
            let foreground = GetForegroundWindow();
            if foreground.0.is_null() {
                return false;
            }
            let thread = GetWindowThreadProcessId(foreground, None);
            let mut info = GUITHREADINFO { cbSize: std::mem::size_of::<GUITHREADINFO>() as u32, ..Default::default() };
            if GetGUIThreadInfo(thread, &mut info).is_err() || info.hwndFocus.0.is_null() {
                return false;
            }
            let mut class = [0u16; 64];
            let length = GetClassNameW(info.hwndFocus, &mut class);
            let class = String::from_utf16_lossy(&class[..length.max(0) as usize]).to_lowercase();
            class.contains("edit") && GetWindowLongW(info.hwndFocus, GWL_STYLE) & ES_PASSWORD != 0
        }
    }

    /// UI Automation, on a thread of its own with a short limit: an app that isn't answering mustn't hold the words up.
    fn automation_says_password() -> bool {
        let (sender, receiver) = std::sync::mpsc::channel();
        let spawned = std::thread::Builder::new().name("theo-uia".into()).spawn(move || {
            let answer = unsafe {
                let initialized = CoInitializeEx(None, COINIT_MULTITHREADED).is_ok();
                let answer = CoCreateInstance::<_, IUIAutomation>(&CUIAutomation, None, CLSCTX_INPROC_SERVER)
                    .and_then(|automation| automation.GetFocusedElement())
                    .and_then(|element| element.CurrentIsPassword())
                    .map(|is_password| is_password.as_bool())
                    .unwrap_or(false);
                if initialized {
                    CoUninitialize();
                }
                answer
            };
            let _ = sender.send(answer);
        });
        if spawned.is_err() {
            return false;
        }
        receiver.recv_timeout(Duration::from_millis(600)).unwrap_or(false)
    }

    fn key(virtual_key: VIRTUAL_KEY, scan: u16, flags: KEYBD_EVENT_FLAGS) -> INPUT {
        INPUT { r#type: INPUT_KEYBOARD, Anonymous: INPUT_0 { ki: KEYBDINPUT { wVk: virtual_key, wScan: scan, dwFlags: flags, time: 0, dwExtraInfo: 0 } } }
    }

    fn send(inputs: &[INPUT]) -> bool {
        unsafe { SendInput(inputs, std::mem::size_of::<INPUT>() as i32) as usize == inputs.len() }
    }

    /// The clipboard, opened for as long as this lives (a few tries: another app may have it open for a moment).
    struct OpenedClipboard;
    impl OpenedClipboard {
        fn open() -> Option<OpenedClipboard> {
            for _ in 0..10 {
                if unsafe { OpenClipboard(HWND::default()) }.is_ok() {
                    return Some(OpenedClipboard);
                }
                std::thread::sleep(Duration::from_millis(20));
            }
            None
        }
    }
    impl Drop for OpenedClipboard {
        fn drop(&mut self) {
            unsafe {
                let _ = CloseClipboard();
            }
        }
    }

    /// Every memory-backed format on the clipboard, as bytes.
    fn save_clipboard() -> Vec<(u32, Vec<u8>)> {
        let mut saved = vec![];
        let Some(_open) = OpenedClipboard::open() else { return saved };
        unsafe {
            let mut format = EnumClipboardFormats(0);
            while format != 0 {
                if !HANDLE_FORMATS.contains(&format) {
                    if let Ok(handle) = GetClipboardData(format) {
                        let global = HGLOBAL(handle.0);
                        let size = GlobalSize(global);
                        let pointer = GlobalLock(global);
                        if !pointer.is_null() && size > 0 && size < 64 * 1024 * 1024 {
                            saved.push((format, std::slice::from_raw_parts(pointer as *const u8, size).to_vec()));
                        }
                        if !pointer.is_null() {
                            let _ = GlobalUnlock(global);
                        }
                    }
                }
                format = EnumClipboardFormats(format);
            }
        }
        saved
    }

    fn put_bytes(format: u32, bytes: &[u8]) -> bool {
        unsafe {
            let Ok(global) = GlobalAlloc(GMEM_MOVEABLE, bytes.len().max(1)) else { return false };
            let pointer = GlobalLock(global);
            if pointer.is_null() {
                return false;
            }
            std::ptr::copy_nonoverlapping(bytes.as_ptr(), pointer as *mut u8, bytes.len());
            let _ = GlobalUnlock(global);
            // The clipboard owns the memory once this works.
            SetClipboardData(format, HANDLE(global.0)).is_ok()
        }
    }

    /// The words on the clipboard, marked so clipboard history and cloud clipboard skip them. Returns the clipboard's
    /// sequence number after, to tell later whether anything else changed it.
    fn set_clipboard_text(text: &str) -> Option<u32> {
        let _open = OpenedClipboard::open()?;
        unsafe {
            EmptyClipboard().ok()?;
            let mut wide: Vec<u8> = text.encode_utf16().chain(std::iter::once(0)).flat_map(|unit| unit.to_le_bytes()).collect();
            if !put_bytes(CF_UNICODETEXT, &wide) {
                return None;
            }
            wide.clear();
            for name in [w!("ExcludeClipboardContentFromMonitorProcessing"), w!("CanIncludeInClipboardHistory"), w!("CanUploadToCloudClipboard")] {
                let format = RegisterClipboardFormatW(name);
                if format != 0 {
                    // A DWORD 0 says "no" for the two Can… formats; the first only needs to be there.
                    put_bytes(format, &0u32.to_le_bytes());
                }
            }
        }
        drop(_open);
        Some(unsafe { GetClipboardSequenceNumber() })
    }

    fn restore_clipboard(saved: Vec<(u32, Vec<u8>)>) {
        let Some(_open) = OpenedClipboard::open() else { return };
        unsafe {
            if EmptyClipboard().is_err() {
                return;
            }
            for (format, bytes) in saved {
                put_bytes(format, &bytes);
            }
        }
    }

    fn paste(text: &str) -> bool {
        let saved = save_clipboard();
        let Some(sequence) = set_clipboard_text(text) else { return false };
        let control = VIRTUAL_KEY(VK_CONTROL.0);
        let sent = send(&[key(control, 0, KEYBD_EVENT_FLAGS(0)), key(VK_V, 0, KEYBD_EVENT_FLAGS(0)), key(VK_V, 0, KEYEVENTF_KEYUP), key(control, 0, KEYEVENTF_KEYUP)]);
        // The app reads the clipboard when it handles the paste, so the owner's clipboard comes back a moment later, and
        // only if nothing else has put something there since.
        std::thread::spawn(move || {
            std::thread::sleep(Duration::from_millis(CLIPBOARD_RESTORE_MILLISECONDS));
            if unsafe { GetClipboardSequenceNumber() } == sequence {
                restore_clipboard(saved);
            }
        });
        sent
    }

    fn type_text(text: &str) -> bool {
        let mut inputs = vec![];
        for line_piece in text.split("\r\n").enumerate() {
            let (index, piece) = line_piece;
            if index > 0 {
                inputs.push(key(VK_RETURN, 0, KEYBD_EVENT_FLAGS(0)));
                inputs.push(key(VK_RETURN, 0, KEYEVENTF_KEYUP));
            }
            for unit in piece.encode_utf16() {
                inputs.push(key(VIRTUAL_KEY(0), unit, KEYEVENTF_UNICODE));
                inputs.push(key(VIRTUAL_KEY(0), unit, KEYEVENTF_UNICODE | KEYEVENTF_KEYUP));
            }
        }
        // In batches, so a long dictation doesn't flood the app's input queue.
        inputs.chunks(200).all(|batch| {
            let sent = send(batch);
            std::thread::sleep(Duration::from_millis(5));
            sent
        })
    }

    pub fn insert(text: &str) -> Result<InsertOutcome> {
        if focused_field_is_password() {
            bail!(PASSWORD_REFUSAL);
        }
        if paste(text) {
            return Ok(InsertOutcome { method: "paste" });
        }
        if type_text(text) {
            return Ok(InsertOutcome { method: "typed" });
        }
        bail!("Windows didn't take the typing (an app running as administrator ignores apps that aren't).")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn text_is_tidied_for_typing() {
        assert_eq!(text_for_typing("one\ntwo\r\nthree\rfour"), "one\r\ntwo\r\nthree\r\nfour");
        assert_eq!(text_for_typing("a\u{0007}b\tc"), "ab\tc");
        assert_eq!(text_for_typing("नमस्ते"), "नमस्ते");
    }

    #[test]
    fn empty_words_are_refused_and_other_systems_say_so() {
        assert!(insert("   ").is_err());
        #[cfg(not(windows))]
        assert!(insert("hello").unwrap_err().to_string().contains("Windows"));
        #[cfg(not(windows))]
        assert!(!focused_field_is_password());
    }
}
