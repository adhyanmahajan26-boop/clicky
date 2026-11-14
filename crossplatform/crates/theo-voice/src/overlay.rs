//! Floating windows that must never take the keyboard: dictation's pill (and Clicky's overlays). Showing a window the
//! usual way on Windows activates it, which would move the cursor out of the app the words are meant for. These calls
//! take the window's handle (`HWND` as an integer) and make it a click-through, never-activated, always-on-top tool window.
//! Elsewhere they do nothing and return false, so the caller shows the window its own way.

/// Makes the window never take focus, stay out of Alt+Tab and the taskbar, and let clicks through. True when done.
pub fn prepare(window_handle: isize) -> bool {
    #[cfg(windows)]
    {
        use windows::Win32::Foundation::HWND;
        use windows::Win32::UI::WindowsAndMessaging::{GetWindowLongPtrW, SetWindowLongPtrW, GWL_EXSTYLE, WS_EX_LAYERED, WS_EX_NOACTIVATE, WS_EX_TOOLWINDOW, WS_EX_TOPMOST, WS_EX_TRANSPARENT};
        let window = HWND(window_handle as *mut core::ffi::c_void);
        unsafe {
            let style = GetWindowLongPtrW(window, GWL_EXSTYLE);
            let wanted = style | (WS_EX_NOACTIVATE.0 | WS_EX_TOOLWINDOW.0 | WS_EX_TOPMOST.0 | WS_EX_TRANSPARENT.0 | WS_EX_LAYERED.0) as isize;
            SetWindowLongPtrW(window, GWL_EXSTYLE, wanted);
        }
        true
    }
    #[cfg(not(windows))]
    {
        let _ = window_handle;
        false
    }
}

/// Shows it on top without activating it. True when done.
pub fn show_without_focus(window_handle: isize) -> bool {
    #[cfg(windows)]
    {
        use windows::Win32::Foundation::HWND;
        use windows::Win32::UI::WindowsAndMessaging::{SetWindowPos, ShowWindow, HWND_TOPMOST, SWP_NOACTIVATE, SWP_NOMOVE, SWP_NOSIZE, SWP_SHOWWINDOW, SW_SHOWNOACTIVATE};
        let window = HWND(window_handle as *mut core::ffi::c_void);
        unsafe {
            let _ = ShowWindow(window, SW_SHOWNOACTIVATE);
            let _ = SetWindowPos(window, HWND_TOPMOST, 0, 0, 0, 0, SWP_NOACTIVATE | SWP_NOMOVE | SWP_NOSIZE | SWP_SHOWWINDOW);
        }
        true
    }
    #[cfg(not(windows))]
    {
        let _ = window_handle;
        false
    }
}
