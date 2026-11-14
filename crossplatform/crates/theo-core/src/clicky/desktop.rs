//! The few Windows calls the spark's overlay needs that Tauri doesn't make: a window that never takes the focus and isn't
//! in the taskbar or Alt+Tab, shown without activating, left out of screenshots (so Clicky never sees its own spark), and
//! whether Escape is held (to stop speech from any app). Elsewhere they do nothing.

/// Makes an overlay window non-activating, click-through, a tool window, and invisible to screen capture.
pub fn make_overlay(window_handle: isize) {
    #[cfg(windows)]
    unsafe {
        use windows_sys::Win32::UI::WindowsAndMessaging::*;
        let handle = window_handle as windows_sys::Win32::Foundation::HWND;
        let style = GetWindowLongPtrW(handle, GWL_EXSTYLE);
        let wanted = style | (WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW | WS_EX_TRANSPARENT | WS_EX_LAYERED | WS_EX_TOPMOST) as isize;
        let wanted = wanted & !(WS_EX_APPWINDOW as isize);
        if wanted != style {
            SetWindowLongPtrW(handle, GWL_EXSTYLE, wanted);
        }
        // WDA_EXCLUDEFROMCAPTURE (Windows 10 2004 and later): left out of every capture, ours included. Older Windows
        // refuses it, and the spark then shows in Clicky's own screenshots, which is harmless.
        SetWindowDisplayAffinity(handle, 0x0000_0011);
    }
    #[cfg(not(windows))]
    let _ = window_handle;
}

/// Shows an overlay window on top without taking the focus from the app the owner is in.
pub fn show_without_activating(window_handle: isize) {
    #[cfg(windows)]
    unsafe {
        use windows_sys::Win32::UI::WindowsAndMessaging::*;
        let handle = window_handle as windows_sys::Win32::Foundation::HWND;
        ShowWindow(handle, SW_SHOWNOACTIVATE);
        SetWindowPos(handle, HWND_TOPMOST, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE | SWP_SHOWWINDOW);
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
