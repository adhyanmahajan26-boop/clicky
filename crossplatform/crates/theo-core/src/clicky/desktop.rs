//! Two Windows calls Clicky's overlay needs besides theo-voice's focus-free windows (`theo_voice::overlay`): leaving the
//! spark out of screenshots, so Clicky never sees its own spark, and whether Escape is held, to stop speech from any app.
//! Elsewhere they do nothing.

/// Leaves a window out of every screen capture, Clicky's own included (WDA_EXCLUDEFROMCAPTURE, Windows 10 2004 and later;
/// older Windows refuses it, and the spark then shows in Clicky's screenshots, which is harmless).
pub fn exclude_from_capture(window_handle: isize) {
    #[cfg(windows)]
    unsafe {
        windows_sys::Win32::UI::WindowsAndMessaging::SetWindowDisplayAffinity(window_handle as windows_sys::Win32::Foundation::HWND, 0x0000_0011);
    }
    #[cfg(not(windows))]
    let _ = window_handle;
}

/// Whether Escape is held down right now, whichever app is in front.
pub fn escape_is_down() -> bool {
    #[cfg(windows)]
    unsafe {
        use windows_sys::Win32::UI::Input::KeyboardAndMouse::{GetAsyncKeyState, VK_ESCAPE};
        return (GetAsyncKeyState(VK_ESCAPE as i32) as u16 & 0x8000) != 0;
    }
    #[cfg(not(windows))]
    false
}
