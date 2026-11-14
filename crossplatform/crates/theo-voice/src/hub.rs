//! One keyboard hook for the whole app. Dictation and Clicky each register the chords they want under their own name; the
//! hub runs a single [`hotkey::watch`] over all of them and hands each event to whoever registered that chord.
//!
//! The chords are exact (see `hotkey`), so overlapping ones never both fire: holding Ctrl + Alt is Clicky's and never starts
//! dictation's Ctrl + Win, and adding Win to a held Ctrl + Alt cancels Clicky's rather than starting dictation's.
//!
//!   hub::register("clicky", vec![Chord::CtrlAlt], |chord, event| { … });
//!   hub::unregister("clicky");
//!
//! Registering again under the same name replaces that owner's chords and handler. The hook restarts only when the set of
//! chords changes (a restart forgets keys held at that moment, which only happens while someone changes a setting).

use crate::hotkey::{self, Chord, ChordEvent, HotkeyHandle};
use serde_json::{json, Value};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

type Handler = Arc<dyn Fn(Chord, ChordEvent) + Send + Sync>;

struct Owner {
    name: String,
    chords: Vec<Chord>,
    handler: Handler,
}

#[derive(Default)]
struct Hub {
    owners: Vec<Owner>,
    running: Option<(Vec<Chord>, HotkeyHandle)>,
}

static HUB: once_cell::sync::Lazy<Mutex<Hub>> = once_cell::sync::Lazy::new(|| Mutex::new(Hub::default()));

/// Every chord any owner wants, each once, in the order they were registered.
fn wanted_chords(owners: &[Owner]) -> Vec<Chord> {
    let mut chords = vec![];
    for owner in owners {
        for chord in &owner.chords {
            if !chords.contains(chord) {
                chords.push(*chord);
            }
        }
    }
    chords
}

/// Who gets an event for `chord`.
fn handlers_for(chord: Chord) -> Vec<Handler> {
    HUB.lock().unwrap().owners.iter().filter(|owner| owner.chords.contains(&chord)).map(|owner| owner.handler.clone()).collect()
}

fn restart_if_needed(hub: &mut Hub) {
    let wanted = wanted_chords(&hub.owners);
    let same = hub.running.as_ref().map(|(chords, handle)| *chords == wanted && (handle.is_running() || handle.problem().is_some())).unwrap_or(false);
    if same {
        return;
    }
    hub.running = None;
    if wanted.is_empty() {
        return;
    }
    let handle = hotkey::watch(wanted.clone(), |chord, event| {
        for handler in handlers_for(chord) {
            handler(chord, event);
        }
    });
    // The hook reports itself once its thread is up.
    let started = Instant::now();
    while !handle.is_running() && handle.problem().is_none() && started.elapsed() < Duration::from_millis(500) {
        std::thread::sleep(Duration::from_millis(10));
    }
    hub.running = Some((wanted, handle));
}

/// `name` wants `chords`; `handler` gets their presses, releases and cancels (on the hub's event thread, never the hook's).
/// An empty list is the same as [`unregister`].
pub fn register(name: &str, chords: Vec<Chord>, handler: impl Fn(Chord, ChordEvent) + Send + Sync + 'static) {
    let mut hub = HUB.lock().unwrap();
    hub.owners.retain(|owner| owner.name != name);
    if !chords.is_empty() {
        hub.owners.push(Owner { name: name.to_string(), chords, handler: Arc::new(handler) });
    }
    restart_if_needed(&mut hub);
}

pub fn unregister(name: &str) {
    let mut hub = HUB.lock().unwrap();
    hub.owners.retain(|owner| owner.name != name);
    restart_if_needed(&mut hub);
}

/// Whether the hook is listening, for which chords and owners, and why not.
pub fn status() -> Value {
    let hub = HUB.lock().unwrap();
    let owners: Vec<Value> = hub.owners.iter().map(|owner| json!({"name": owner.name, "chords": owner.chords.iter().map(|chord| chord.id()).collect::<Vec<_>>()})).collect();
    match &hub.running {
        Some((chords, handle)) => json!({"running": handle.is_running(), "problem": handle.problem(), "chords": chords.iter().map(|chord| chord.id()).collect::<Vec<_>>(), "owners": owners}),
        None => json!({"running": false, "chords": [], "owners": owners}),
    }
}

/// Whether `name`'s chords are being listened for right now.
pub fn is_listening_for(name: &str) -> bool {
    let hub = HUB.lock().unwrap();
    hub.owners.iter().any(|owner| owner.name == name) && hub.running.as_ref().map(|(_, handle)| handle.is_running()).unwrap_or(false)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn owners_share_one_set_of_chords() {
        let noop: Handler = Arc::new(|_, _| {});
        let owners = vec![
            Owner { name: "dictation".into(), chords: vec![Chord::CtrlWin], handler: noop.clone() },
            Owner { name: "clicky".into(), chords: vec![Chord::CtrlAlt, Chord::CtrlWin], handler: noop },
        ];
        assert_eq!(wanted_chords(&owners), vec![Chord::CtrlWin, Chord::CtrlAlt]);
    }

    #[test]
    fn registering_and_unregistering_is_reported() {
        register("test-owner", vec![Chord::CtrlShiftSpace], |_, _| {});
        let report = status();
        assert!(report["owners"].as_array().unwrap().iter().any(|owner| owner["name"] == "test-owner"));
        #[cfg(not(windows))]
        assert!(report["problem"].as_str().unwrap().contains("Windows"));
        unregister("test-owner");
        assert!(!status()["owners"].as_array().unwrap().iter().any(|owner| owner["name"] == "test-owner"));
    }

    #[test]
    fn ctrl_alt_and_ctrl_win_never_both_fire() {
        // The hub's one watcher holds both: each chord is exact, so one never starts the other.
        let mut watcher = hotkey::ChordWatcher::new(&[Chord::CtrlWin, Chord::CtrlAlt]);
        let mut events = vec![];
        for (down, key) in [(true, hotkey::VK_LCONTROL), (true, hotkey::VK_LMENU), (false, hotkey::VK_LMENU), (false, hotkey::VK_LCONTROL)] {
            events.extend(watcher.key(down, key).events);
        }
        assert_eq!(events, vec![(Chord::CtrlAlt, ChordEvent::Pressed), (Chord::CtrlAlt, ChordEvent::Released)]);
        let mut events = vec![];
        for (down, key) in [(true, hotkey::VK_LWIN), (true, hotkey::VK_RCONTROL), (false, hotkey::VK_RCONTROL), (false, hotkey::VK_LWIN)] {
            events.extend(watcher.key(down, key).events);
        }
        assert_eq!(events, vec![(Chord::CtrlWin, ChordEvent::Pressed), (Chord::CtrlWin, ChordEvent::Released)]);
    }
}
