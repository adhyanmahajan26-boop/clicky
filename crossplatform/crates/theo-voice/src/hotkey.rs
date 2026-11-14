//! Hold-to-talk chords, watched system-wide by one low-level keyboard hook (`SetWindowsHookExW(WH_KEYBOARD_LL)`) on its own
//! thread. Several chords at once: Dictation's (Ctrl + Win by default) and Clicky's (Ctrl + Alt) share the one hook.
//!
//! The rules are the Mac's `DictationChordDetector` (ClickyCore `Voice/Dictation.swift`), which watches modifier flags:
//! - the chord's keys exactly → `Pressed`;
//! - one of them comes up → `Released`;
//! - another modifier or an ordinary key joins in, or Esc → `Cancelled` (it was a keyboard shortcut, not talking).
//!
//! Fn never reaches Windows (the keyboard's firmware keeps it), so Windows chords are made of Ctrl, Alt, Shift and Win, plus
//! chords with a key (Ctrl + Shift + Space), whose key is kept from the app in front while it is held.
//!
//! Nothing else is swallowed, so the keys still do what they did, with one exception: letting go of Win (or Alt) after a
//! chord would open the Start menu (or the app's menu bar), so a harmless unassigned key (0xE8, what AutoHotkey uses) is sent
//! first, which Windows takes as "Win was used with something".
//!
//! On Linux and the Mac `watch` starts nothing and says so ([`HotkeyHandle::problem`]); the rules are tested everywhere.

use std::collections::HashSet;

/// A chord to hold. Modifier chords are exact: Ctrl + Win doesn't fire while Shift is also down.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Chord {
    /// Dictation's default on Windows (the Mac's Control + Fn has no Fn here).
    CtrlWin,
    /// Clicky's push-to-talk, as Control + Option on the Mac.
    CtrlAlt,
    CtrlShift,
    AltShift,
    WinAlt,
    CtrlShiftSpace,
    CtrlAltSpace,
}

/// What the chord just did.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ChordEvent {
    Pressed,
    /// A key of the chord came up: the words go in.
    Released,
    /// Another key joined in, or Esc: it was a shortcut, or the owner changed their mind.
    Cancelled,
}

/// How long a hold has to be to count (the Mac's `DictationHoldPolicy`): a brush of the keys isn't dictation.
pub const MINIMUM_HOLD_SECONDS: f64 = 0.3;

pub const MODIFIER_CTRL: u8 = 1;
pub const MODIFIER_ALT: u8 = 2;
pub const MODIFIER_SHIFT: u8 = 4;
pub const MODIFIER_WIN: u8 = 8;

// Windows virtual-key codes (the low-level hook reports left and right separately).
pub const VK_SHIFT: u32 = 0x10;
pub const VK_CONTROL: u32 = 0x11;
pub const VK_MENU: u32 = 0x12;
pub const VK_ESCAPE: u32 = 0x1B;
pub const VK_SPACE: u32 = 0x20;
pub const VK_LWIN: u32 = 0x5B;
pub const VK_RWIN: u32 = 0x5C;
pub const VK_LSHIFT: u32 = 0xA0;
pub const VK_RSHIFT: u32 = 0xA1;
pub const VK_LCONTROL: u32 = 0xA2;
pub const VK_RCONTROL: u32 = 0xA3;
pub const VK_LMENU: u32 = 0xA4;
pub const VK_RMENU: u32 = 0xA5;
/// An unassigned key: sent before Win or Alt comes up after a chord, so Windows doesn't open Start or a menu bar.
pub const VK_MASK_KEY: u32 = 0xE8;

impl Chord {
    pub const ALL: [Chord; 7] = [Chord::CtrlWin, Chord::CtrlAlt, Chord::CtrlShift, Chord::AltShift, Chord::WinAlt, Chord::CtrlShiftSpace, Chord::CtrlAltSpace];

    /// The id kept in settings.
    pub fn id(self) -> &'static str {
        match self {
            Chord::CtrlWin => "ctrlWin",
            Chord::CtrlAlt => "ctrlAlt",
            Chord::CtrlShift => "ctrlShift",
            Chord::AltShift => "altShift",
            Chord::WinAlt => "winAlt",
            Chord::CtrlShiftSpace => "ctrlShiftSpace",
            Chord::CtrlAltSpace => "ctrlAltSpace",
        }
    }

    pub fn from_id(id: &str) -> Option<Chord> {
        Chord::ALL.iter().copied().find(|chord| chord.id().eq_ignore_ascii_case(id.trim()))
    }

    /// What Settings and the pill call it.
    pub fn title(self) -> &'static str {
        match self {
            Chord::CtrlWin => "Ctrl + Win",
            Chord::CtrlAlt => "Ctrl + Alt",
            Chord::CtrlShift => "Ctrl + Shift",
            Chord::AltShift => "Alt + Shift",
            Chord::WinAlt => "Win + Alt",
            Chord::CtrlShiftSpace => "Ctrl + Shift + Space",
            Chord::CtrlAltSpace => "Ctrl + Alt + Space",
        }
    }

    /// The key caps, for drawing.
    pub fn key_caps(self) -> &'static [&'static str] {
        match self {
            Chord::CtrlWin => &["Ctrl", "Win"],
            Chord::CtrlAlt => &["Ctrl", "Alt"],
            Chord::CtrlShift => &["Ctrl", "Shift"],
            Chord::AltShift => &["Alt", "Shift"],
            Chord::WinAlt => &["Win", "Alt"],
            Chord::CtrlShiftSpace => &["Ctrl", "Shift", "Space"],
            Chord::CtrlAltSpace => &["Ctrl", "Alt", "Space"],
        }
    }

    /// The modifiers held for it.
    pub fn modifiers(self) -> u8 {
        match self {
            Chord::CtrlWin => MODIFIER_CTRL | MODIFIER_WIN,
            Chord::CtrlAlt => MODIFIER_CTRL | MODIFIER_ALT,
            Chord::CtrlShift => MODIFIER_CTRL | MODIFIER_SHIFT,
            Chord::AltShift => MODIFIER_ALT | MODIFIER_SHIFT,
            Chord::WinAlt => MODIFIER_WIN | MODIFIER_ALT,
            Chord::CtrlShiftSpace => MODIFIER_CTRL | MODIFIER_SHIFT,
            Chord::CtrlAltSpace => MODIFIER_CTRL | MODIFIER_ALT,
        }
    }

    /// The ordinary key a chord also needs, if any.
    pub fn key(self) -> Option<u32> {
        match self {
            Chord::CtrlShiftSpace | Chord::CtrlAltSpace => Some(VK_SPACE),
            _ => None,
        }
    }
}

/// Which modifier a virtual key is, if it is one.
pub fn modifier_of(virtual_key: u32) -> Option<u8> {
    match virtual_key {
        VK_CONTROL | VK_LCONTROL | VK_RCONTROL => Some(MODIFIER_CTRL),
        VK_MENU | VK_LMENU | VK_RMENU => Some(MODIFIER_ALT),
        VK_SHIFT | VK_LSHIFT | VK_RSHIFT => Some(MODIFIER_SHIFT),
        VK_LWIN | VK_RWIN => Some(MODIFIER_WIN),
        _ => None,
    }
}

/// What the hook does with one key event.
#[derive(Debug, Default, PartialEq, Eq)]
pub struct Reaction {
    pub events: Vec<(Chord, ChordEvent)>,
    /// Keep this key from the app in front (a chord's own key, such as Space in Ctrl + Shift + Space).
    pub swallow: bool,
    /// Send the harmless mask key before letting this key up (Win or Alt after a chord).
    pub mask_first: bool,
}

/// The rules for every watched chord, fed one physical key event at a time. Pure: the hook feeds it, and so do the tests.
#[derive(Debug)]
pub struct ChordWatcher {
    chords: Vec<(Chord, bool)>,
    held_modifier_keys: HashSet<u32>,
    held_other_keys: HashSet<u32>,
    swallowed_keys: HashSet<u32>,
    /// Win and Alt bits of chords that fired, waiting for their key to come up (to mask it).
    armed_mask: u8,
}

impl ChordWatcher {
    pub fn new(chords: &[Chord]) -> Self {
        let mut unique: Vec<(Chord, bool)> = vec![];
        for chord in chords {
            if !unique.iter().any(|(known, _)| known == chord) {
                unique.push((*chord, false));
            }
        }
        Self { chords: unique, held_modifier_keys: HashSet::new(), held_other_keys: HashSet::new(), swallowed_keys: HashSet::new(), armed_mask: 0 }
    }

    pub fn modifiers(&self) -> u8 {
        self.held_modifier_keys.iter().filter_map(|key| modifier_of(*key)).fold(0, |all, one| all | one)
    }

    pub fn is_held(&self, chord: Chord) -> bool {
        self.chords.iter().any(|(known, held)| *known == chord && *held)
    }

    /// One key went down (`down`) or up.
    pub fn key(&mut self, down: bool, virtual_key: u32) -> Reaction {
        let mut reaction = Reaction::default();
        if let Some(modifier) = modifier_of(virtual_key) {
            if down && self.held_modifier_keys.contains(&virtual_key) {
                // Windows repeats a held key: nothing changed.
                return reaction;
            }
            if down {
                self.held_modifier_keys.insert(virtual_key);
            } else {
                self.held_modifier_keys.remove(&virtual_key);
            }
            let flags = self.modifiers();
            for (chord, held) in self.chords.iter_mut() {
                let required = chord.modifiers();
                let exact = flags == required;
                if chord.key().is_none() {
                    // The Mac's flagsChanged rule.
                    if exact && !*held {
                        *held = true;
                        reaction.events.push((*chord, ChordEvent::Pressed));
                        self.armed_mask |= required & (MODIFIER_WIN | MODIFIER_ALT);
                        continue;
                    }
                    if *held && !exact {
                        *held = false;
                        let event = if flags & required == required { ChordEvent::Cancelled } else { ChordEvent::Released };
                        reaction.events.push((*chord, event));
                    }
                } else if *held && !exact {
                    *held = false;
                    let event = if flags & required == required { ChordEvent::Cancelled } else { ChordEvent::Released };
                    reaction.events.push((*chord, event));
                }
            }
            if !down && self.armed_mask & modifier & (MODIFIER_WIN | MODIFIER_ALT) != 0 {
                // Only when no other key of the same kind is still down (the other Win or Alt).
                if self.modifiers() & modifier == 0 {
                    reaction.mask_first = true;
                    self.armed_mask &= !modifier;
                }
            }
            return reaction;
        }

        if !down {
            self.held_other_keys.remove(&virtual_key);
            for (chord, held) in self.chords.iter_mut() {
                if *held && chord.key() == Some(virtual_key) {
                    *held = false;
                    reaction.events.push((*chord, ChordEvent::Released));
                }
            }
            if self.swallowed_keys.remove(&virtual_key) {
                reaction.swallow = true;
            }
            return reaction;
        }

        if self.held_other_keys.contains(&virtual_key) {
            // A repeat: keep swallowing what was swallowed, and nothing else changes.
            reaction.swallow = self.swallowed_keys.contains(&virtual_key);
            return reaction;
        }
        self.held_other_keys.insert(virtual_key);
        let flags = self.modifiers();
        for (chord, held) in self.chords.iter_mut() {
            if *held {
                // Esc, or any other key, while held: a shortcut, not talking.
                *held = false;
                reaction.events.push((*chord, ChordEvent::Cancelled));
                continue;
            }
            if virtual_key != VK_ESCAPE && chord.key() == Some(virtual_key) && flags == chord.modifiers() {
                *held = true;
                reaction.events.push((*chord, ChordEvent::Pressed));
                reaction.swallow = true;
                self.armed_mask |= chord.modifiers() & (MODIFIER_WIN | MODIFIER_ALT);
            }
        }
        if reaction.swallow {
            self.swallowed_keys.insert(virtual_key);
        }
        reaction
    }

    /// Forgets every key (the hook was restarted, or the computer woke): nothing counts as held.
    pub fn reset(&mut self) -> Vec<(Chord, ChordEvent)> {
        let mut events = vec![];
        for (chord, held) in self.chords.iter_mut() {
            if *held {
                *held = false;
                events.push((*chord, ChordEvent::Cancelled));
            }
        }
        self.held_modifier_keys.clear();
        self.held_other_keys.clear();
        self.swallowed_keys.clear();
        self.armed_mask = 0;
        events
    }
}

/// The running hook. Dropping it (or `stop`) removes the hook and ends its thread.
pub struct HotkeyHandle {
    #[cfg(windows)]
    thread_id: std::sync::Arc<std::sync::atomic::AtomicU32>,
    running: std::sync::Arc<std::sync::atomic::AtomicBool>,
    problem: std::sync::Arc<std::sync::Mutex<Option<String>>>,
}

impl HotkeyHandle {
    /// Whether the hook is installed and listening.
    pub fn is_running(&self) -> bool {
        self.running.load(std::sync::atomic::Ordering::SeqCst)
    }

    /// Why it isn't, in plain words.
    pub fn problem(&self) -> Option<String> {
        self.problem.lock().unwrap().clone()
    }

    pub fn stop(&self) {
        #[cfg(windows)]
        windows_hook::stop(self.thread_id.load(std::sync::atomic::Ordering::SeqCst));
        self.running.store(false, std::sync::atomic::Ordering::SeqCst);
    }
}

impl Drop for HotkeyHandle {
    fn drop(&mut self) {
        self.stop();
    }
}

/// Starts watching `chords`; `on_event` is called on a thread of its own (never on the hook's, which must answer Windows
/// at once) for each press, release and cancel.
pub fn watch(chords: Vec<Chord>, on_event: impl Fn(Chord, ChordEvent) + Send + 'static) -> HotkeyHandle {
    let running = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
    let problem = std::sync::Arc::new(std::sync::Mutex::new(None));
    #[cfg(windows)]
    {
        let thread_id = std::sync::Arc::new(std::sync::atomic::AtomicU32::new(0));
        windows_hook::start(chords, Box::new(on_event), thread_id.clone(), running.clone(), problem.clone());
        HotkeyHandle { thread_id, running, problem }
    }
    #[cfg(not(windows))]
    {
        let _ = (chords, on_event);
        *problem.lock().unwrap() = Some("Holding a chord to talk works on Windows only in this build.".to_string());
        HotkeyHandle { running, problem }
    }
}

#[cfg(windows)]
mod windows_hook {
    use super::*;
    use std::cell::RefCell;
    use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};
    use std::sync::{mpsc, Arc, Mutex};
    use windows::Win32::Foundation::{LPARAM, LRESULT, WPARAM};
    use windows::Win32::System::LibraryLoader::GetModuleHandleW;
    use windows::Win32::System::Threading::GetCurrentThreadId;
    use windows::Win32::UI::Input::KeyboardAndMouse::{SendInput, INPUT, INPUT_0, INPUT_KEYBOARD, KEYBDINPUT, KEYBD_EVENT_FLAGS, KEYEVENTF_KEYUP, VIRTUAL_KEY};
    use windows::Win32::UI::WindowsAndMessaging::{
        CallNextHookEx, DispatchMessageW, GetMessageW, PostThreadMessageW, SetWindowsHookExW, TranslateMessage, UnhookWindowsHookEx, HC_ACTION, HHOOK, KBDLLHOOKSTRUCT,
        LLKHF_INJECTED, MSG, WH_KEYBOARD_LL, WM_KEYDOWN, WM_KEYUP, WM_QUIT, WM_SYSKEYDOWN, WM_SYSKEYUP,
    };

    struct HookState {
        watcher: ChordWatcher,
        events: mpsc::Sender<(Chord, ChordEvent)>,
    }

    thread_local! {
        static STATE: RefCell<Option<HookState>> = const { RefCell::new(None) };
    }

    pub fn stop(thread_id: u32) {
        if thread_id != 0 {
            unsafe {
                let _ = PostThreadMessageW(thread_id, WM_QUIT, WPARAM(0), LPARAM(0));
            }
        }
    }

    fn send_mask_key() {
        let key = |flags: KEYBD_EVENT_FLAGS| INPUT {
            r#type: INPUT_KEYBOARD,
            Anonymous: INPUT_0 { ki: KEYBDINPUT { wVk: VIRTUAL_KEY(VK_MASK_KEY as u16), wScan: 0, dwFlags: flags, time: 0, dwExtraInfo: 0 } },
        };
        let inputs = [key(KEYBD_EVENT_FLAGS(0)), key(KEYEVENTF_KEYUP)];
        unsafe {
            SendInput(&inputs, std::mem::size_of::<INPUT>() as i32);
        }
    }

    unsafe extern "system" fn hook_procedure(code: i32, wparam: WPARAM, lparam: LPARAM) -> LRESULT {
        if code == HC_ACTION as i32 {
            let info = &*(lparam.0 as *const KBDLLHOOKSTRUCT);
            let message = wparam.0 as u32;
            let down = message == WM_KEYDOWN || message == WM_SYSKEYDOWN;
            let up = message == WM_KEYUP || message == WM_SYSKEYUP;
            // Keys Theo (or anything else) typed itself aren't the owner's hands.
            if (down || up) && info.flags.0 & LLKHF_INJECTED.0 == 0 {
                let reaction = STATE.with(|state| {
                    let mut state = state.borrow_mut();
                    let state = state.as_mut()?;
                    let reaction = state.watcher.key(down, info.vkCode);
                    for event in &reaction.events {
                        let _ = state.events.send(*event);
                    }
                    Some(reaction)
                });
                if let Some(reaction) = reaction {
                    if reaction.mask_first {
                        send_mask_key();
                    }
                    if reaction.swallow {
                        return LRESULT(1);
                    }
                }
            }
        }
        CallNextHookEx(HHOOK::default(), code, wparam, lparam)
    }

    pub fn start(chords: Vec<Chord>, on_event: Box<dyn Fn(Chord, ChordEvent) + Send>, thread_id: Arc<AtomicU32>, running: Arc<AtomicBool>, problem: Arc<Mutex<Option<String>>>) {
        let (sender, receiver) = mpsc::channel::<(Chord, ChordEvent)>();
        // Events are handed on from a thread of their own, so a slow handler never holds up the keyboard.
        std::thread::Builder::new()
            .name("theo-hotkey-events".into())
            .spawn(move || {
                for (chord, event) in receiver {
                    on_event(chord, event);
                }
            })
            .ok();
        std::thread::Builder::new()
            .name("theo-hotkey".into())
            .spawn(move || unsafe {
                thread_id.store(GetCurrentThreadId(), Ordering::SeqCst);
                STATE.with(|state| *state.borrow_mut() = Some(HookState { watcher: ChordWatcher::new(&chords), events: sender }));
                let module = GetModuleHandleW(None).unwrap_or_default();
                let hook = match SetWindowsHookExW(WH_KEYBOARD_LL, Some(hook_procedure), module, 0) {
                    Ok(hook) => hook,
                    Err(error) => {
                        *problem.lock().unwrap() = Some(format!("Windows didn't let Theo watch the keyboard ({error})."));
                        return;
                    }
                };
                running.store(true, Ordering::SeqCst);
                let mut message = MSG::default();
                while GetMessageW(&mut message, None, 0, 0).as_bool() {
                    let _ = TranslateMessage(&message);
                    DispatchMessageW(&message);
                }
                let _ = UnhookWindowsHookEx(hook);
                running.store(false, Ordering::SeqCst);
                STATE.with(|state| *state.borrow_mut() = None);
            })
            .ok();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn press(watcher: &mut ChordWatcher, keys: &[(bool, u32)]) -> Vec<(Chord, ChordEvent)> {
        keys.iter().flat_map(|(down, key)| watcher.key(*down, *key).events).collect()
    }

    #[test]
    fn ctrl_win_pressed_then_released() {
        let mut watcher = ChordWatcher::new(&[Chord::CtrlWin]);
        assert!(watcher.key(true, VK_LCONTROL).events.is_empty());
        assert_eq!(watcher.key(true, VK_LWIN).events, vec![(Chord::CtrlWin, ChordEvent::Pressed)]);
        // Windows repeats held keys: nothing new.
        assert!(watcher.key(true, VK_LWIN).events.is_empty());
        assert!(watcher.key(true, VK_LCONTROL).events.is_empty());
        let up = watcher.key(false, VK_LWIN);
        assert_eq!(up.events, vec![(Chord::CtrlWin, ChordEvent::Released)]);
        // Letting go of Win after the chord would open Start: masked.
        assert!(up.mask_first);
        assert!(!up.swallow);
        let ctrl_up = watcher.key(false, VK_LCONTROL);
        assert!(ctrl_up.events.is_empty() && !ctrl_up.mask_first);
    }

    #[test]
    fn either_order_works_and_ctrl_up_releases() {
        let mut watcher = ChordWatcher::new(&[Chord::CtrlWin]);
        assert_eq!(press(&mut watcher, &[(true, VK_RWIN), (true, VK_RCONTROL)]), vec![(Chord::CtrlWin, ChordEvent::Pressed)]);
        assert_eq!(press(&mut watcher, &[(false, VK_RCONTROL)]), vec![(Chord::CtrlWin, ChordEvent::Released)]);
        // Win comes up after: still masked, since the chord fired.
        assert!(watcher.key(false, VK_RWIN).mask_first);
    }

    #[test]
    fn another_key_or_modifier_cancels() {
        let mut watcher = ChordWatcher::new(&[Chord::CtrlWin]);
        press(&mut watcher, &[(true, VK_LCONTROL), (true, VK_LWIN)]);
        // Ctrl + Win + D is Windows' new desktop: a shortcut, not talking.
        assert_eq!(press(&mut watcher, &[(true, 0x44)]), vec![(Chord::CtrlWin, ChordEvent::Cancelled)]);
        // And it doesn't come back while the same keys stay down.
        assert!(press(&mut watcher, &[(false, 0x44)]).is_empty());
        assert!(press(&mut watcher, &[(false, VK_LWIN), (false, VK_LCONTROL)]).is_empty());

        press(&mut watcher, &[(true, VK_LCONTROL), (true, VK_LWIN)]);
        assert_eq!(press(&mut watcher, &[(true, VK_LSHIFT)]), vec![(Chord::CtrlWin, ChordEvent::Cancelled)]);
    }

    #[test]
    fn escape_cancels() {
        let mut watcher = ChordWatcher::new(&[Chord::CtrlWin]);
        press(&mut watcher, &[(true, VK_LCONTROL), (true, VK_LWIN)]);
        let escape = watcher.key(true, VK_ESCAPE);
        assert_eq!(escape.events, vec![(Chord::CtrlWin, ChordEvent::Cancelled)]);
        assert!(!escape.swallow);
    }

    #[test]
    fn exact_means_exact() {
        let mut watcher = ChordWatcher::new(&[Chord::CtrlWin]);
        // Shift first, then Ctrl + Win: not the chord.
        assert!(press(&mut watcher, &[(true, VK_LSHIFT), (true, VK_LCONTROL), (true, VK_LWIN)]).is_empty());
        // Shift up leaves exactly Ctrl + Win: now it is.
        assert_eq!(press(&mut watcher, &[(false, VK_LSHIFT)]), vec![(Chord::CtrlWin, ChordEvent::Pressed)]);
    }

    #[test]
    fn several_chords_share_one_watcher() {
        let mut watcher = ChordWatcher::new(&[Chord::CtrlWin, Chord::CtrlAlt]);
        assert_eq!(press(&mut watcher, &[(true, VK_LCONTROL), (true, VK_LMENU)]), vec![(Chord::CtrlAlt, ChordEvent::Pressed)]);
        assert!(watcher.is_held(Chord::CtrlAlt) && !watcher.is_held(Chord::CtrlWin));
        // Adding Win: Ctrl + Alt is cancelled, and Ctrl + Win isn't exact.
        assert_eq!(press(&mut watcher, &[(true, VK_LWIN)]), vec![(Chord::CtrlAlt, ChordEvent::Cancelled)]);
        // Alt up leaves Ctrl + Win exactly.
        let alt_up = watcher.key(false, VK_LMENU);
        assert_eq!(alt_up.events, vec![(Chord::CtrlWin, ChordEvent::Pressed)]);
        // Alt had fired a chord, so its release is masked (no menu bar).
        assert!(alt_up.mask_first);
        assert_eq!(press(&mut watcher, &[(false, VK_LCONTROL)]), vec![(Chord::CtrlWin, ChordEvent::Released)]);
    }

    #[test]
    fn a_key_chord_keeps_its_key_from_the_app() {
        let mut watcher = ChordWatcher::new(&[Chord::CtrlShiftSpace]);
        assert!(press(&mut watcher, &[(true, VK_LCONTROL), (true, VK_LSHIFT)]).is_empty());
        let space = watcher.key(true, VK_SPACE);
        assert_eq!(space.events, vec![(Chord::CtrlShiftSpace, ChordEvent::Pressed)]);
        assert!(space.swallow);
        // Repeats of Space are kept too.
        let repeat = watcher.key(true, VK_SPACE);
        assert!(repeat.events.is_empty() && repeat.swallow);
        let up = watcher.key(false, VK_SPACE);
        assert_eq!(up.events, vec![(Chord::CtrlShiftSpace, ChordEvent::Released)]);
        assert!(up.swallow);
        // A plain Space isn't touched.
        press(&mut watcher, &[(false, VK_LSHIFT), (false, VK_LCONTROL)]);
        let plain = watcher.key(true, VK_SPACE);
        assert!(plain.events.is_empty() && !plain.swallow);
        assert!(!watcher.key(false, VK_SPACE).swallow);
    }

    #[test]
    fn a_key_chord_ends_when_a_modifier_comes_up_and_cancels_on_more() {
        let mut watcher = ChordWatcher::new(&[Chord::CtrlShiftSpace]);
        press(&mut watcher, &[(true, VK_LCONTROL), (true, VK_LSHIFT), (true, VK_SPACE)]);
        assert_eq!(press(&mut watcher, &[(false, VK_LSHIFT)]), vec![(Chord::CtrlShiftSpace, ChordEvent::Released)]);
        // Its Space still comes up swallowed, since its down was.
        assert!(watcher.key(false, VK_SPACE).swallow);
        press(&mut watcher, &[(true, VK_LSHIFT), (true, VK_SPACE)]);
        assert_eq!(press(&mut watcher, &[(true, VK_LMENU)]), vec![(Chord::CtrlShiftSpace, ChordEvent::Cancelled)]);
    }

    #[test]
    fn plain_alt_and_win_are_never_masked() {
        let mut watcher = ChordWatcher::new(&[Chord::CtrlWin]);
        press(&mut watcher, &[(true, VK_LWIN)]);
        assert!(!watcher.key(false, VK_LWIN).mask_first);
        press(&mut watcher, &[(true, VK_LMENU)]);
        assert!(!watcher.key(false, VK_LMENU).mask_first);
    }

    #[test]
    fn ids_round_trip_and_reset_cancels() {
        for chord in Chord::ALL {
            assert_eq!(Chord::from_id(chord.id()), Some(chord));
            assert!(!chord.title().is_empty());
        }
        assert_eq!(Chord::from_id("nope"), None);
        let mut watcher = ChordWatcher::new(&[Chord::CtrlWin, Chord::CtrlWin]);
        press(&mut watcher, &[(true, VK_LCONTROL), (true, VK_LWIN)]);
        assert_eq!(watcher.reset(), vec![(Chord::CtrlWin, ChordEvent::Cancelled)]);
        assert_eq!(watcher.modifiers(), 0);
    }
}
