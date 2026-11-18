//! VM screens on Windows and Linux: hidden browser windows where Pointer Assistant's research agents read the web.
//!
//! The Mac makes virtual displays and reads pages in the owner's own Chrome on them (`leanring-buddy/Studio/`,
//! `Research/BrowserResearcher.swift`). Windows can only make a display with a signed driver, so here each VM screen is a
//! headless Chrome or Edge of its own (`browser.rs`), driven over the DevTools protocol (`cdp.rs`): it opens a page, waits
//! for it, reads its words (the article or main part first, `page.rs`) and keeps a small JPEG of it for its tile in the
//! VM screens panel. Up to four, each with a fresh profile under Vello's data folder (no logins, nothing kept), closed a
//! minute after its last page and when Vello quits; a crash takes them along (a Job Object on Windows, the process group
//! recorded for the next launch elsewhere).
//!
//! A screen only ever opens and reads: no typing, no clicks, no forms, no sign-ins. A page asking for a person becomes a
//! card in the chat (`research.rs`), never a workaround.
//!
//! Settings (`settings.json`): `vmScreens.on` (default off), `vmScreens.count` (1 to 4, default 2), `vmScreens.browser` (a
//! Chromium-based browser's full path, when it isn't found by itself).

pub mod browser;
pub mod cdp;
pub mod page;
pub mod research;

use crate::harness::Harness;
use crate::procs::ProcessTree;
use base64::Engine;
use cdp::Cdp;
use chrono::{DateTime, Utc};
use once_cell::sync::{Lazy, OnceCell};
use serde_json::{json, Value};
use std::path::PathBuf;
use std::sync::{Arc, Mutex, Weak};
use std::time::{Duration, Instant};

pub const ON_SETTING: &str = "vmScreens.on";
pub const COUNT_SETTING: &str = "vmScreens.count";
pub const BROWSER_SETTING: &str = "vmScreens.browser";
pub const MAXIMUM_SCREENS: usize = 4;
pub const DEFAULT_SCREENS: usize = 2;
/// A screen with nothing to do closes after this long.
const IDLE_SECONDS: u64 = 60;
/// The longest a page may take to load before what's there is read anyway.
const PAGE_LOAD_SECONDS: u64 = 25;
/// How often a working screen's tile is refreshed.
const TILE_EVERY: Duration = Duration::from_secs(2);
/// The longest an agent waits for a screen to come free (the Mac's `secondsToWaitForATile`).
pub const WAIT_FOR_A_SCREEN: Duration = Duration::from_secs(120);
/// Said wherever a VM screen is wanted and no browser was found.
pub const NEEDS_BROWSER: &str = "Vello needs Chrome or Edge for VM screens. Install Google Chrome (or use Microsoft Edge, which Windows has), then try again.";
pub const TURNED_OFF: &str = "VM screens are off. Turn them on in Settings › VM screens.";

/// What one screen's tile shows.
#[derive(Clone, Debug, Default)]
pub struct Tile {
    /// asleep (no browser), starting, working or idle.
    pub state: String,
    pub url: String,
    pub title: String,
    /// What the agent on it is doing, in a few words ("Info · Reading example.com").
    pub doing: String,
    /// Who holds it (an agent, "Try it").
    pub holder: String,
    pub pages: u32,
    pub jpeg: Option<String>,
    pub at: Option<DateTime<Utc>>,
}

/// A browser running for one screen.
struct Session {
    _child: tokio::process::Child,
    tree: ProcessTree,
    cdp: Cdp,
    profile: PathBuf,
}

struct Slot {
    tile: Mutex<Tile>,
    session: Arc<Mutex<Option<Session>>>,
    holder: Mutex<Option<String>>,
    /// The browser's name while one runs. Kept apart from the session, which is locked for as long as a page loads.
    running: Mutex<Option<String>>,
    last_used: Mutex<Instant>,
    /// One start at a time per screen.
    starting: tokio::sync::Mutex<()>,
}

static SLOTS: Lazy<Vec<Slot>> = Lazy::new(|| {
    (0..MAXIMUM_SCREENS)
        .map(|_| Slot {
            tile: Mutex::new(Tile { state: "asleep".into(), ..Tile::default() }),
            session: Arc::new(Mutex::new(None)),
            holder: Mutex::new(None),
            running: Mutex::new(None),
            last_used: Mutex::new(Instant::now()),
            starting: tokio::sync::Mutex::new(()),
        })
        .collect()
});
static FREED: Lazy<tokio::sync::Notify> = Lazy::new(tokio::sync::Notify::new);
static HARNESS: OnceCell<Weak<Harness>> = OnceCell::new();

/// What a screen read.
#[derive(Clone, Debug, Default)]
pub struct PageRead {
    pub url: String,
    pub title: Option<String>,
    pub text: String,
    pub human_check: bool,
    pub html: Option<String>,
    pub jpeg_bytes: usize,
}

/// Called once the engine has started: remembers it for work started from places that only borrow it (Pointer Assistant's
/// turn, an API bot's tool), and closes screens that have nothing to do.
pub fn attach(h: &Arc<Harness>) {
    if HARNESS.set(Arc::downgrade(h)).is_err() {
        return;
    }
    // Profiles a crash left behind.
    let _ = std::fs::remove_dir_all(profiles_folder(h));
    let weak = Arc::downgrade(h);
    if tokio::runtime::Handle::try_current().is_err() {
        return;
    }
    tokio::spawn(async move {
        loop {
            tokio::time::sleep(Duration::from_secs(5)).await;
            let Some(h) = weak.upgrade() else { return };
            let on = is_on(&h);
            let idle = Duration::from_secs(h.settings.number("test.vmScreens.idleSeconds").map(|s| s.max(1.0) as u64).unwrap_or(IDLE_SECONDS));
            for number in 1..=MAXIMUM_SCREENS {
                let slot = &SLOTS[number - 1];
                let held = slot.holder.lock().unwrap().is_some();
                if held || slot.running.lock().unwrap().is_none() {
                    continue;
                }
                let quiet = slot.last_used.lock().unwrap().elapsed() >= idle;
                if !on || quiet || number > count(&h) {
                    close(number);
                }
            }
        }
    });
}

/// The engine, when it's running in this process.
pub fn harness() -> Option<Arc<Harness>> {
    HARNESS.get().and_then(Weak::upgrade)
}

pub fn is_on(h: &Harness) -> bool {
    h.settings.bool(ON_SETTING)
}

/// How many screens the owner wants (1 to 4).
pub fn count(h: &Harness) -> usize {
    h.settings.number(COUNT_SETTING).map(|n| n.round() as i64).unwrap_or(DEFAULT_SCREENS as i64).clamp(1, MAXIMUM_SCREENS as i64) as usize
}

pub fn browser(h: &Harness) -> Option<browser::Browser> {
    browser::find(h.settings.string(BROWSER_SETTING).as_deref())
}

/// A test profile may read pages served on 127.0.0.1; nothing else may.
pub fn allows_local_host(h: &Harness) -> bool {
    h.settings.is_test
}

fn profiles_folder(h: &Harness) -> PathBuf {
    h.paths.root.join("VMScreens")
}

fn set_tile(number: usize, change: impl FnOnce(&mut Tile)) {
    if let Some(slot) = SLOTS.get(number.wrapping_sub(1)) {
        let mut tile = slot.tile.lock().unwrap();
        change(&mut tile);
        tile.at = Some(Utc::now());
    }
}

/// What the agent on a screen is doing now, in a few words.
pub fn set_tile_doing(number: usize, doing: &str) {
    set_tile(number, |tile| tile.doing = doing.to_string());
}

/// A free screen for `holder`, waiting up to `wait` for one. None when VM screens are off or none came free.
pub async fn acquire(h: &Harness, holder: &str, wait: Duration) -> Option<usize> {
    let deadline = tokio::time::Instant::now() + wait;
    loop {
        if !is_on(h) {
            return None;
        }
        let wanted = count(h);
        let freed = FREED.notified();
        for number in 1..=wanted {
            let mut taken = SLOTS[number - 1].holder.lock().unwrap();
            if taken.is_none() {
                *taken = Some(holder.to_string());
                set_tile(number, |tile| tile.holder = holder.to_string());
                return Some(number);
            }
        }
        if tokio::time::timeout_at(deadline, freed).await.is_err() {
            return None;
        }
    }
}

/// The screen goes back; whoever waited longest may have it.
pub fn release(number: usize) {
    if let Some(slot) = SLOTS.get(number.wrapping_sub(1)) {
        *slot.holder.lock().unwrap() = None;
        *slot.last_used.lock().unwrap() = Instant::now();
        set_tile(number, |tile| {
            tile.holder.clear();
            if tile.state != "asleep" {
                tile.state = "idle".into();
                tile.doing.clear();
            }
        });
        FREED.notify_waiters();
    }
}

/// Ends a screen's browser and removes its profile.
pub fn close(number: usize) {
    let Some(slot) = SLOTS.get(number.wrapping_sub(1)) else { return };
    let session = slot.session.lock().map(|mut s| s.take()).unwrap_or(None);
    *slot.running.lock().unwrap() = None;
    if let Some(session) = session {
        end_session(session);
    }
    set_tile(number, |tile| *tile = Tile { state: "asleep".into(), holder: tile.holder.clone(), ..Tile::default() });
}

fn end_session(session: Session) {
    session.tree.kill();
    if let Some(h) = harness() {
        h.registry.remove(&session.tree);
    }
    let profile = session.profile.clone();
    drop(session);
    // The browser lets go of its files once it has ended; on Windows that can take a moment.
    std::thread::spawn(move || {
        for _ in 0..20 {
            if std::fs::remove_dir_all(&profile).is_ok() || !profile.exists() {
                return;
            }
            std::thread::sleep(Duration::from_millis(250));
        }
    });
}

/// Every screen closes (Vello is quitting, or VM screens were turned off).
pub fn close_all() {
    for number in 1..=MAXIMUM_SCREENS {
        close(number);
    }
}

/// How many screens have a browser running now.
pub fn running() -> usize {
    SLOTS.iter().filter(|slot| slot.running.lock().unwrap().is_some()).count()
}

/// Starts a screen's browser when it isn't running.
async fn ensure_session(h: &Harness, number: usize) -> Result<(), String> {
    let slot = &SLOTS[number - 1];
    let _one_start = slot.starting.lock().await;
    {
        let mut guard = slot.session.lock().unwrap();
        if let Some(session) = guard.as_ref() {
            if session.tree.alive() {
                return Ok(());
            }
        }
        if let Some(dead) = guard.take() {
            end_session(dead);
        }
    }
    let found = browser(h).ok_or_else(|| NEEDS_BROWSER.to_string())?;
    set_tile(number, |tile| {
        tile.state = "starting".into();
        tile.doing = format!("Starting {}", found.name);
    });
    let profile = profiles_folder(h).join(format!("screen-{number}"));
    let _ = std::fs::remove_dir_all(&profile);
    std::fs::create_dir_all(&profile).map_err(|e| format!("Couldn't make VM screen {number}'s profile: {e}"))?;
    crate::paths::make_private(&profile);
    let mut command = tokio::process::Command::new(&found.path);
    command
        .args(browser::launch_arguments(&profile, browser::running_as_root()))
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .kill_on_drop(true);
    crate::procs::configure(&mut command);
    let mut child = command.spawn().map_err(|e| format!("Couldn't start {}: {e}", found.name))?;
    let tree = ProcessTree::attach(&child).map_err(|e| format!("Couldn't keep track of {}: {e}", found.name))?;
    h.registry.add(&tree);
    let port_file = profile.join("DevToolsActivePort");
    let deadline = Instant::now() + Duration::from_secs(30);
    let port = loop {
        if let Some((port, _)) = std::fs::read_to_string(&port_file).ok().as_deref().and_then(browser::read_devtools_port) {
            break port;
        }
        if let Ok(Some(status)) = child.try_wait() {
            tree.kill();
            h.registry.remove(&tree);
            set_tile(number, |tile| tile.state = "asleep".into());
            return Err(format!("{} stopped as it started ({status}).", found.name));
        }
        if Instant::now() > deadline {
            tree.kill();
            h.registry.remove(&tree);
            set_tile(number, |tile| tile.state = "asleep".into());
            return Err(format!("{} didn't start in time.", found.name));
        }
        tokio::time::sleep(Duration::from_millis(100)).await;
    };
    let allow_local = allows_local_host(h);
    let connected = tokio::task::spawn_blocking(move || connect_to_page(port, allow_local)).await.map_err(|_| "The browser's start stopped.".to_string())?;
    let cdp = match connected {
        Ok(cdp) => cdp,
        Err(problem) => {
            tree.kill();
            h.registry.remove(&tree);
            set_tile(number, |tile| tile.state = "asleep".into());
            return Err(format!("{} started but couldn't be driven: {problem}", found.name));
        }
    };
    *slot.session.lock().unwrap() = Some(Session { _child: child, tree, cdp, profile });
    *slot.running.lock().unwrap() = Some(found.name.clone());
    *slot.last_used.lock().unwrap() = Instant::now();
    set_tile(number, |tile| {
        tile.state = "idle".into();
        tile.doing.clear();
    });
    Ok(())
}

/// The browser's one page, ready: its address from `/json/list` (a new one if it has none), connected, page events on, and
/// downloads refused.
fn connect_to_page(port: u16, allows_local_host_for_tests: bool) -> Result<Cdp, String> {
    let agent = ureq::AgentBuilder::new().timeout(Duration::from_secs(10)).build();
    let base = format!("http://127.0.0.1:{port}");
    let mut target = None;
    for _ in 0..30 {
        if let Ok(response) = agent.get(&format!("{base}/json/list")).call() {
            if let Ok(list) = response.into_string().map_err(|_| ()).and_then(|t| serde_json::from_str::<Value>(&t).map_err(|_| ())) {
                target = list.as_array().and_then(|items| items.iter().find(|item| item["type"] == "page").and_then(|item| item["webSocketDebuggerUrl"].as_str().map(str::to_string)));
                if target.is_some() {
                    break;
                }
            }
            if let Ok(made) = agent.put(&format!("{base}/json/new?about:blank")).call() {
                if let Ok(item) = made.into_string().map_err(|_| ()).and_then(|t| serde_json::from_str::<Value>(&t).map_err(|_| ())) {
                    target = item["webSocketDebuggerUrl"].as_str().map(str::to_string);
                    if target.is_some() {
                        break;
                    }
                }
            }
        }
        std::thread::sleep(Duration::from_millis(200));
    }
    let target = target.ok_or("it showed no page")?;
    let path = target.split_once(&format!("127.0.0.1:{port}")).map(|(_, path)| path.to_string()).ok_or("its page is somewhere unexpected")?;
    let mut cdp = Cdp::connect(port, &path, Duration::from_secs(10))?;
    cdp.call("Page.enable", json!({}), Duration::from_secs(10))?;
    let _ = cdp.call("Page.setDownloadBehavior", json!({"behavior": "deny"}), Duration::from_secs(5));
    // Only public web pages load as documents: never a file, this computer or the network around it.
    cdp.guard_documents(
        Box::new(move |address: &str| address.starts_with("about:") || url::Url::parse(address).map(|u| page::is_allowed(&u, allows_local_host_for_tests)).unwrap_or(false)),
        Duration::from_secs(10),
    )?;
    Ok(cdp)
}

fn snapshot(cdp: &mut Cdp) -> Option<String> {
    let clip = json!({"x": 0, "y": 0, "width": browser::SCREEN_WIDTH, "height": browser::SCREEN_HEIGHT, "scale": 0.5});
    cdp.call("Page.captureScreenshot", json!({"format": "jpeg", "quality": 55, "clip": clip}), Duration::from_secs(10)).ok().and_then(|r| r["data"].as_str().map(str::to_string))
}

fn host_of(address: &str) -> String {
    url::Url::parse(address).ok().and_then(|u| u.host_str().map(str::to_string)).unwrap_or_else(|| address.chars().take(60).collect())
}

/// Opens `address` in screen `number` and reads it: waits for it to load (its tile refreshed every two seconds meanwhile),
/// for its words to stop growing, then reads them. `want_html` also returns the page's markup (a search results page).
pub async fn open(h: &Harness, number: usize, address: &str, doing: &str, want_html: bool) -> Result<PageRead, String> {
    let url = url::Url::parse(address).map_err(|_| "That isn't a web address.".to_string())?;
    let allow_local = allows_local_host(h);
    if !page::may_open(&url, allow_local) {
        return Err(format!("{} wasn't opened: it looks private or isn't a public web page.", host_of(address)));
    }
    ensure_session(h, number).await?;
    let slot = &SLOTS[number - 1];
    *slot.last_used.lock().unwrap() = Instant::now();
    set_tile(number, |tile| {
        tile.state = "working".into();
        tile.doing = if doing.is_empty() { format!("Opening {}", host_of(address)) } else { doing.to_string() };
        tile.url = url.to_string();
        tile.title.clear();
    });
    let session = slot.session.clone();
    let address = url.to_string();
    let result = tokio::task::spawn_blocking(move || {
        let mut guard = session.lock().unwrap();
        let Some(session) = guard.as_mut() else { return Err("The screen closed.".to_string()) };
        open_blocking(&mut session.cdp, number, &address, want_html)
    })
    .await
    .map_err(|_| "The screen stopped.".to_string())?;
    *slot.last_used.lock().unwrap() = Instant::now();
    match result {
        Ok(read) => {
            let final_url = url::Url::parse(&read.url).ok();
            // A page that moved somewhere private (the network around this computer, a file) is never read.
            if !final_url.map(|u| page::is_allowed(&u, allow_local) || u.as_str() == "about:blank").unwrap_or(false) {
                let session = slot.session.clone();
                let _ = tokio::task::spawn_blocking(move || session.lock().ok().and_then(|mut g| g.as_mut().map(|s| s.cdp.call("Page.navigate", json!({"url": "about:blank"}), Duration::from_secs(5)).ok()))).await;
                set_tile(number, |tile| {
                    tile.state = "idle".into();
                    tile.url.clear();
                    tile.title.clear();
                });
                return Err("The page moved somewhere Vello won't read.".into());
            }
            set_tile(number, |tile| {
                tile.pages += 1;
                tile.title = read.title.clone().unwrap_or_default();
                tile.url = read.url.clone();
            });
            Ok(read)
        }
        Err(problem) => {
            // A browser that broke is started afresh next time.
            if !slot.session.lock().map(|s| s.as_ref().map(|s| s.tree.alive()).unwrap_or(false)).unwrap_or(false) {
                close(number);
            }
            set_tile(number, |tile| tile.doing = format!("Couldn't open {}", host_of(&tile.url)));
            Err(problem)
        }
    }
}

fn open_blocking(cdp: &mut Cdp, number: usize, address: &str, want_html: bool) -> Result<PageRead, String> {
    cdp.forget_events();
    let navigated = cdp.call("Page.navigate", json!({"url": address}), Duration::from_secs(20))?;
    if let Some(problem) = navigated["errorText"].as_str().filter(|e| !e.is_empty()) {
        if problem.contains("BLOCKED_BY_CLIENT") {
            return Err(format!("{} tried to go somewhere Vello won't read (this computer or the network around it), so it wasn't opened.", host_of(address)));
        }
        return Err(format!("{} didn't load ({problem}).", host_of(address)));
    }
    let deadline = Instant::now() + Duration::from_secs(PAGE_LOAD_SECONDS);
    let mut loaded = false;
    while Instant::now() < deadline {
        if cdp.wait_event("Page.loadEventFired", TILE_EVERY)? {
            loaded = true;
            break;
        }
        if let Some(jpeg) = snapshot(cdp) {
            set_tile(number, |tile| tile.jpeg = Some(jpeg));
        }
    }
    if !loaded {
        let _ = cdp.call("Page.stopLoading", json!({}), Duration::from_secs(5));
    }
    if let Some(jpeg) = snapshot(cdp) {
        set_tile(number, |tile| tile.jpeg = Some(jpeg));
    }
    // A page that fills itself in with scripts: wait until its words stop growing (three seconds at most).
    let mut last_length = -1i64;
    for _ in 0..5 {
        let length = cdp.evaluate("(document.body && document.body.innerText || '').length", Duration::from_secs(5)).ok().and_then(|v| v.as_i64()).unwrap_or(0);
        if length == last_length && length > 0 {
            break;
        }
        last_length = length;
        std::thread::sleep(Duration::from_millis(600));
    }
    let raw = cdp.evaluate(page::READER_SCRIPT, Duration::from_secs(15))?;
    let read: Value = raw.as_str().and_then(|text| serde_json::from_str(text).ok()).unwrap_or(Value::Null);
    let runs: Vec<(String, i64)> = read["runs"].as_array().map(|runs| runs.iter().filter_map(|run| Some((run[0].as_str()?.to_string(), run[1].as_i64()?))).collect()).unwrap_or_default();
    let text = page::joined(&runs);
    let title = read["title"].as_str().map(str::trim).filter(|t| !t.is_empty()).map(str::to_string);
    let html = if want_html { cdp.evaluate("document.documentElement ? document.documentElement.outerHTML : ''", Duration::from_secs(10)).ok().and_then(|v| v.as_str().map(str::to_string)) } else { None };
    let jpeg = snapshot(cdp);
    let jpeg_bytes = jpeg.as_ref().map(|data| base64::engine::general_purpose::STANDARD.decode(data).map(|b| b.len()).unwrap_or(0)).unwrap_or(0);
    if let Some(jpeg) = jpeg {
        set_tile(number, |tile| tile.jpeg = Some(jpeg));
    }
    Ok(PageRead {
        url: read["url"].as_str().unwrap_or(address).to_string(),
        human_check: page::is_human_check(title.as_deref(), &text),
        title,
        text,
        html,
        jpeg_bytes,
    })
}

/// What screen `number` shows now, read again (Settings' "Try it" and the control inbox's `read`).
pub async fn read_again(number: usize) -> Result<PageRead, String> {
    let session = SLOTS.get(number.wrapping_sub(1)).ok_or("There's no such screen.")?.session.clone();
    tokio::task::spawn_blocking(move || {
        let mut guard = session.lock().unwrap();
        let Some(session) = guard.as_mut() else { return Err(format!("VM screen {number} isn't open.")) };
        let raw = session.cdp.evaluate(page::READER_SCRIPT, Duration::from_secs(15))?;
        let read: Value = raw.as_str().and_then(|text| serde_json::from_str(text).ok()).unwrap_or(Value::Null);
        let runs: Vec<(String, i64)> = read["runs"].as_array().map(|runs| runs.iter().filter_map(|run| Some((run[0].as_str()?.to_string(), run[1].as_i64()?))).collect()).unwrap_or_default();
        let text = page::joined(&runs);
        let title = read["title"].as_str().map(str::to_string);
        Ok(PageRead { url: read["url"].as_str().unwrap_or("").to_string(), human_check: page::is_human_check(title.as_deref(), &text), title, text, html: None, jpeg_bytes: 0 })
    })
    .await
    .map_err(|_| "The screen stopped.".to_string())?
}

/// Each screen as the panel and Settings show it. `tiles`: with each one's latest picture as a data address.
pub fn screens_report(h: &Harness, tiles: bool) -> Vec<Value> {
    (1..=count(h).max(running()))
        .map(|number| {
            let slot = &SLOTS[number - 1];
            let tile = slot.tile.lock().unwrap().clone();
            let browser = slot.running.lock().unwrap().clone();
            let mut entry = json!({
                "number": number,
                "name": format!("VM screen {number}"),
                "state": tile.state,
                "url": tile.url,
                "title": tile.title,
                "doing": tile.doing,
                "holder": tile.holder,
                "pages": tile.pages,
                "hasPicture": tile.jpeg.is_some(),
                "browser": browser,
                "at": tile.at.map(|at| at.to_rfc3339()),
            });
            if tiles {
                entry["picture"] = tile.jpeg.map(|data| Value::from(format!("data:image/jpeg;base64,{data}"))).unwrap_or(Value::Null);
            }
            entry
        })
        .collect()
}

/// Settings' and the panel's view: on or off, how many, the browser found, every screen and the research running.
pub fn state(h: &Harness, tiles: bool) -> Value {
    let found = browser(h);
    json!({
        "on": is_on(h),
        "count": count(h),
        "maximum": MAXIMUM_SCREENS,
        "browser": found.as_ref().map(|b| json!({"name": b.name, "path": b.path.to_string_lossy()})),
        "needsBrowser": found.is_none().then_some(NEEDS_BROWSER),
        "running": running(),
        "screens": screens_report(h, tiles),
        "research": research::status(),
        "agents": research::agent_count(h),
        "pages": research::pages_per_agent(h),
        "roles": research::roles_report(h),
        "os": std::env::consts::OS,
    })
}

fn s(v: &Value, k: &str) -> Option<String> {
    v.get(k).and_then(|x| x.as_str()).map(str::to_string)
}

/// The control commands (Settings, the panel, theod's inbox and the suite):
/// - `vmScreens {action: state, tiles?}`: on or off, the count, the browser found, each screen (`tiles`: with its picture).
/// - `vmScreens {action: on | off, count?}`: turn them on (and how many) or off (every screen closes).
/// - `vmScreens {action: open, url, screen?}`: opens a page in a screen and reads it ("Try it").
/// - `vmScreens {action: read, screen?}`: what a screen shows now, read again.
/// - `vmScreens {action: close, screen?}`: closes one screen, or all.
/// - `research {question, agents?, bot?, wait?}`: research agents answer a question (research.rs); `research {action:
///   state | cancel}`.
pub async fn control(h: &Arc<Harness>, name: &str, cmd: &Value) -> Value {
    use crate::control::{err, ok};
    if name == "research" {
        return research::control(h, cmd).await;
    }
    let action = s(cmd, "action").unwrap_or_else(|| "state".into());
    match action.as_str() {
        "state" => ok(state(h, cmd["tiles"].as_bool() == Some(true))),
        "on" | "off" => {
            if let Some(wanted) = cmd["count"].as_f64() {
                h.settings.set(COUNT_SETTING, json!((wanted.round() as i64).clamp(1, MAXIMUM_SCREENS as i64)));
            }
            h.settings.set(ON_SETTING, json!(action == "on"));
            if action == "off" {
                tokio::task::spawn_blocking(close_all).await.ok();
            }
            ok(state(h, false))
        }
        "open" => {
            if !is_on(h) {
                return err(TURNED_OFF);
            }
            if browser(h).is_none() {
                return err(NEEDS_BROWSER);
            }
            let Some(address) = s(cmd, "url").map(|u| u.trim().to_string()).filter(|u| !u.is_empty()) else { return err("Needs url.") };
            let address = if address.contains("://") { address } else { format!("https://{address}") };
            let wanted = cmd["screen"].as_u64().map(|n| n as usize);
            let number = match wanted {
                Some(number) if (1..=count(h)).contains(&number) => {
                    let mut holder = SLOTS[number - 1].holder.lock().unwrap();
                    if holder.is_some() {
                        return err(&format!("VM screen {number} is busy."));
                    }
                    *holder = Some("Try it".into());
                    number
                }
                Some(_) => return err("There's no such screen."),
                None => match acquire(h, "Try it", Duration::from_secs(5)).await {
                    Some(number) => number,
                    None => return err("Every VM screen is busy. Try again in a moment."),
                },
            };
            let started = Instant::now();
            let result = open(h, number, &address, &format!("Try it · Opening {}", host_of(&address)), false).await;
            release(number);
            match result {
                Ok(read) => ok(json!({
                    "screen": number,
                    "url": read.url,
                    "title": read.title,
                    "words": read.text.split_whitespace().count(),
                    "text": read.text.chars().take(4000).collect::<String>(),
                    "humanCheck": read.human_check,
                    "jpegBytes": read.jpeg_bytes,
                    "seconds": (started.elapsed().as_secs_f64() * 10.0).round() / 10.0,
                })),
                Err(problem) => err(&problem),
            }
        }
        "read" => {
            let number = cmd["screen"].as_u64().unwrap_or(1) as usize;
            match read_again(number).await {
                Ok(read) => ok(json!({"screen": number, "url": read.url, "title": read.title, "text": read.text, "humanCheck": read.human_check})),
                Err(problem) => err(&problem),
            }
        }
        "close" => {
            match cmd["screen"].as_u64() {
                Some(number) => {
                    let number = number as usize;
                    tokio::task::spawn_blocking(move || close(number)).await.ok();
                }
                None => {
                    tokio::task::spawn_blocking(close_all).await.ok();
                }
            }
            ok(state(h, false))
        }
        other => err(&format!("Unknown vmScreens action {other}")),
    }
}
