//! The harness: bots, chats, turns, private messages, group rounds, routines, recovery. One per data folder.
//!
//! Ported from the Swift app's `BotsStore`, `BotPrivateMessages`, `BotRoutines`, `BotFailover` and `BotsResume`. State lives
//! behind one lock that's never held across an await; each turn runs as its own task.

use crate::engine::{self, Cancel, EndReason, Format, Spec};
use crate::failover::{self, Failure, Plan};
use crate::model::*;
use crate::paths::Paths;
use crate::procs::Registry;
use crate::prompts;
use crate::protocol::{self, Order, Step};
use crate::schedule;
use crate::settings::Settings;
use crate::store::{write_atomic, LoadProblems};
use crate::usage::Ledger;
use chrono::{DateTime, Utc};
use serde_json::{json, Value};
use std::collections::{HashMap, HashSet, VecDeque};
use std::future::Future;
use std::path::PathBuf;
use std::pin::Pin;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

pub type Fut<T> = Pin<Box<dyn Future<Output = T> + Send + 'static>>;

pub const TEAM_ID: &str = "team";
pub const RESUME_PREFIX: &str = "Theo stopped before ";
pub const RESUME_RETRY_SUFFIX: &str = "so it's asking again now.";
pub const RESUME_WINDOW_SECS: i64 = 6 * 3600;
pub const RESUME_RETRIES: usize = 2;
pub const LONGEST_SHOWN_REPLY: usize = 60_000;
pub const MEMBER_WAIT_SECS: f64 = 90.0;

#[derive(Clone, Debug)]
pub struct DmContext {
    /// The chat the owner (or a routine) spoke in. Budgets and coding runs belong to it however deep the messages go.
    pub root_room: String,
    pub owner_words: Option<String>,
    pub from_owner: bool,
}

#[derive(Clone, Debug)]
pub struct DmTurn {
    pub exchange_id: Option<String>,
    pub asker_id: Option<String>,
    pub ctx: DmContext,
    pub may_message: bool,
}

#[derive(Clone, Debug, Default)]
pub struct ReplyOpts {
    pub hands_on_when_stopped: bool,
    pub from_owner: bool,
    pub privately: Option<DmTurn>,
    pub quiet_allowed: bool,
}

#[derive(Clone, Debug)]
struct Exchange {
    id: String,
    thread_id: String,
    owner_turn: u64,
    round_trips: u32,
}

#[derive(Clone, Debug)]
pub struct DmLive {
    pub sender: String,
    pub target: String,
    pub room: String,
    pub root_room: String,
    pub replying: bool,
}

struct Round {
    id: u64,
    group_id: String,
    plan: protocol::GroupTurnPlan,
    opening_note: Option<String>,
    next_first: Option<Vec<String>>,
    next_note: Option<String>,
}

#[derive(Default)]
pub struct State {
    pub bots: Vec<Bot>,
    pub groups: Vec<Group>,
    pub routines: Vec<Routine>,
    pub runs: Vec<CodingRun>,
    pub conversations: HashMap<String, Conversation>,
    pub replying: HashMap<String, String>,
    pub replying_in: HashMap<String, String>,
    pub live_exchanges: HashMap<String, DmLive>,
    budgets: HashMap<String, protocol::DmBudget>,
    owner_turns: HashMap<String, u64>,
    open_exchanges: HashMap<String, Exchange>,
    stopped_exchange_rooms: HashSet<String>,
    stop_counts: HashMap<String, u64>,
    stopped: HashSet<String>,
    rounds: HashMap<String, Round>,
    next_round: u64,
    running_routines: HashSet<String>,
    quiet_group_routines: HashMap<String, (String, RoutineRun, String)>,
    queues: HashMap<String, VecDeque<u64>>,
    next_ticket: u64,
    pub submitted_pitches: HashSet<String>,
    /// When the owner last looked at each chat.
    pub seen: HashMap<String, DateTime<Utc>>,
    pub replying_since: HashMap<String, DateTime<Utc>>,
    pub connectors: Vec<crate::connectors::Connector>,
    pub connectors_checked: Option<DateTime<Utc>>,
    /// A `claude mcp list` is running. It starts every MCP server to check it, so only one runs at a time.
    pub connectors_refreshing: bool,
    pub gateway_recent: Vec<(DateTime<Utc>, String, String)>,
}

#[derive(Debug)]
pub enum RunError {
    NotInstalled(String),
    Failed(String),
    LostSession,
    EngineDown(String),
}

impl std::fmt::Display for RunError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            RunError::NotInstalled(e) => write!(f, "{e} isn't installed on this computer."),
            RunError::Failed(m) | RunError::EngineDown(m) => write!(f, "{m}"),
            RunError::LostSession => write!(f, "The engine has lost this chat's session."),
        }
    }
}

pub struct Harness {
    pub paths: Paths,
    pub settings: Settings,
    pub problems: LoadProblems,
    pub state: Mutex<State>,
    procs: Mutex<HashMap<String, Arc<Cancel>>>,
    stopped_at: Mutex<HashMap<String, Instant>>,
    pub registry: Arc<Registry>,
    usage: Mutex<Ledger>,
    pub coding_procs: Mutex<HashMap<String, Arc<Cancel>>>,
    pub gateway: crate::gateway::GatewayHandle,
}

fn ok_or_log<T, E: std::fmt::Display>(r: Result<T, E>, what: &str) {
    if let Err(e) = r {
        eprintln!("[theo] {what}: {e}");
    }
}

impl Harness {
    pub fn new(root: PathBuf, is_test: bool) -> Arc<Self> {
        let paths = Paths::new(root);
        let _ = paths.ensure();
        let settings = Settings::load(paths.settings_file(), is_test);
        let registry = Arc::new(Registry::new(paths.engines_running_file()));
        Arc::new(Self {
            settings,
            problems: LoadProblems::default(),
            state: Mutex::new(State::default()),
            procs: Mutex::new(HashMap::new()),
            stopped_at: Mutex::new(HashMap::new()),
            registry,
            usage: Mutex::new(Ledger::default()),
            coding_procs: Mutex::new(HashMap::new()),
            gateway: crate::gateway::GatewayHandle::default(),
            paths,
        })
    }

    pub fn owner(&self) -> String { self.settings.owner_name() }

    /// Theo is quitting: every engine still running ends with it, so a turn nobody will read doesn't keep using the owner's
    /// subscription. (On Windows the Job Objects do this by themselves when the process ends.)
    pub fn shutdown(&self) {
        for c in self.procs.lock().unwrap().values() { c.cancel(); }
        for c in self.coding_procs.lock().unwrap().values() { c.cancel(); }
        self.registry.kill_all();
        let _ = std::fs::remove_file(self.paths.pid_file());
    }

    // MARK: Loading and saving

    /// Loads everything, ends engines a crash left behind, and picks up where the last run stopped.
    pub fn start(self: &Arc<Self>) {
        let ended = self.registry.end_leftovers();
        if ended > 0 {
            eprintln!("[theo] ended {ended} engine(s) left running by the last session");
        }
        // Turn folders a crash left behind.
        let _ = std::fs::remove_dir_all(self.paths.turns_dir());
        self.load();
        self.settle_stale_routine_runs();
        let me = self.clone();
        tokio::spawn(async move {
            loop {
                tokio::time::sleep(Duration::from_secs(2)).await;
                me.run_due_routines();
            }
        });
        self.resume_interrupted_turns();
        self.fire_hook("app-started", json!({"bots": self.with(|s| s.bots.len())}));
        crate::gateway::apply(self);
    }

    pub fn load(&self) {
        let p = &self.paths;
        let mut bots: Vec<Bot> = self.problems.load(&p.bots_file(), "the list of bots").unwrap_or_default();
        if !bots.iter().any(|b| b.primary) {
            bots.insert(0, Bot::theo());
        }
        let groups: Vec<Group> = self.problems.load(&p.groups_file(), "the group chats").unwrap_or_default();
        let routines: Vec<Routine> = self.problems.load(&p.routines_file(), "the routines").unwrap_or_default();
        let runs: Vec<CodingRun> = self.problems.load(&p.runs_file(), "the coding runs").unwrap_or_default();
        let ledger: Ledger = self.problems.load(&p.usage_file(), "the usage ledger").unwrap_or_default();
        *self.usage.lock().unwrap() = ledger;
        let mut conversations = HashMap::new();
        if let Ok(dir) = std::fs::read_dir(p.chats_dir()) {
            for entry in dir.flatten() {
                let name = entry.file_name().to_string_lossy().to_string();
                let Some(stem) = name.strip_suffix(".json") else { continue };
                let id = protocol_thread_id(stem);
                if let Some(c) = self.problems.load::<Conversation>(&entry.path(), &format!("the chat {id}")) {
                    conversations.insert(id, c);
                }
            }
        }
        let groups: Vec<Group> = groups.into_iter().filter(|g| g.head_id.as_ref().map(|h| bots.iter().any(|b| &b.id == h)).unwrap_or(true)).collect();
        {
            let mut s = self.state.lock().unwrap();
            s.bots = bots;
            s.groups = groups;
            s.routines = routines;
            s.runs = runs;
            s.conversations = conversations;
        }
        self.write_bots();
        // Runs that were going when Theo stopped can't be going now.
        let mut changed = false;
        self.with(|s| {
            for run in s.runs.iter_mut().filter(|r| r.phase == "running") {
                run.phase = "stopped".into();
                run.summary = Some("Theo stopped while this run was going.".into());
                changed = true;
            }
        });
        if changed {
            self.write_runs();
        }
        for line in self.problems.problems.lock().unwrap().iter() {
            let first = self.with(|s| s.bots.iter().find(|b| b.primary).map(|b| b.id.clone())).unwrap_or_else(|| "theo".into());
            self.post(ChatMessage::note(line.clone()), &first);
        }
    }

    pub fn with<R>(&self, f: impl FnOnce(&mut State) -> R) -> R {
        let mut s = self.state.lock().unwrap();
        f(&mut s)
    }

    pub fn write_bots(&self) {
        let data = self.with(|s| serde_json::to_vec_pretty(&s.bots).unwrap_or_default());
        ok_or_log(write_atomic(&self.paths.bots_file(), &data), "saving bots");
    }
    pub fn write_groups(&self) {
        let data = self.with(|s| serde_json::to_vec_pretty(&s.groups).unwrap_or_default());
        ok_or_log(write_atomic(&self.paths.groups_file(), &data), "saving groups");
    }
    pub fn write_routines(&self) {
        let data = self.with(|s| serde_json::to_vec_pretty(&s.routines).unwrap_or_default());
        ok_or_log(write_atomic(&self.paths.routines_file(), &data), "saving routines");
    }
    pub fn write_runs(&self) {
        let data = self.with(|s| serde_json::to_vec_pretty(&s.runs).unwrap_or_default());
        ok_or_log(write_atomic(&self.paths.runs_file(), &data), "saving runs");
    }
    fn write_conversation_locked(&self, s: &State, id: &str) {
        if let Some(c) = s.conversations.get(id) {
            if let Ok(data) = serde_json::to_vec(c) {
                ok_or_log(write_atomic(&self.paths.chat_file(id), &data), "saving a chat");
            }
        }
    }
    pub fn write_conversation(&self, id: &str) {
        let s = self.state.lock().unwrap();
        self.write_conversation_locked(&s, id);
    }

    pub fn conversation(&self, id: &str) -> Conversation { self.with(|s| s.conversations.get(id).cloned().unwrap_or_default()) }

    /// Adds a message to a chat and saves it.
    pub fn post(&self, message: ChatMessage, conversation_id: &str) {
        let s = &mut *self.state.lock().unwrap();
        s.conversations.entry(conversation_id.to_string()).or_default().messages.push(message);
        self.write_conversation_locked(s, conversation_id);
    }

    pub fn bot(&self, id: &str) -> Option<Bot> { self.with(|s| s.bots.iter().find(|b| b.id == id).cloned()) }
    pub fn bots(&self) -> Vec<Bot> { self.with(|s| s.bots.clone()) }
    pub fn primary(&self) -> Option<Bot> { self.with(|s| s.bots.iter().find(|b| b.primary).or(s.bots.first()).cloned()) }
    pub fn group(&self, id: &str) -> Option<Group> { self.with(|s| s.groups.iter().find(|g| g.id == id).cloned()) }
    pub fn group_for_room(&self, room: &str) -> Option<Group> {
        self.with(|s| s.groups.iter().find(|g| g.head_id.is_some() && g.room_id() == room).cloned())
    }

    pub fn add_bot(&self, mut bot: Bot) -> Bot {
        self.with(|s| {
            while s.bots.iter().any(|b| b.id == bot.id) {
                bot.id = format!("{}-{}", bot.id, &uuid::Uuid::new_v4().simple().to_string()[..4]);
            }
            s.bots.push(bot.clone());
        });
        let _ = std::fs::create_dir_all(self.paths.memory_dir(&bot.id));
        self.write_bots();
        bot
    }

    pub fn save_bot(&self, bot: Bot) {
        self.with(|s| {
            if let Some(i) = s.bots.iter().position(|b| b.id == bot.id) {
                s.bots[i] = bot;
            }
        });
        self.write_bots();
    }

    pub fn delete_bot(&self, id: &str) {
        self.stop(id);
        self.with(|s| {
            s.bots.retain(|b| b.id != id || b.primary);
            for g in s.groups.iter_mut() {
                g.member_ids.retain(|m| m != id);
            }
            s.groups.retain(|g| g.head_id.as_deref() != Some(id));
        });
        self.write_bots();
        self.write_groups();
    }

    pub fn save_group(&self, group: Group) {
        self.with(|s| {
            if let Some(i) = s.groups.iter().position(|g| g.id == group.id) { s.groups[i] = group; } else { s.groups.push(group); }
        });
        self.write_groups();
    }

    pub fn delete_group(&self, id: &str) {
        self.with(|s| s.groups.retain(|g| g.id != id));
        self.write_groups();
    }

    pub fn chat_file_path(&self, id: &str) -> PathBuf { self.paths.chat_file(id) }

    /// The group chats a bot is in and its private threads, saved, for it to search.
    pub fn recall_files(&self, bot_id: &str) -> Vec<(String, PathBuf)> {
        let (rooms, threads) = self.with(|s| {
            let rooms: Vec<(String, String)> = s.groups.iter().filter(|g| g.head_id.is_some() && g.all_ids().iter().any(|i| i == bot_id)).map(|g| (format!("the \"{}\" group chat", g.name), g.room_id())).collect();
            let threads: Vec<(String, String)> = s.conversations.keys().filter_map(|id| {
                let partner = dm::partner(bot_id, id)?;
                let name = s.bots.iter().find(|b| b.id == partner)?.name.clone();
                Some((format!("your private thread with {name}"), id.clone()))
            }).collect();
            (rooms, threads)
        });
        rooms.into_iter().chain(threads).map(|(l, id)| (l, self.paths.chat_file(&id))).filter(|(_, p)| p.exists()).collect()
    }

    // MARK: Who can reach whom

    pub fn reachable(&self, bot: &Bot) -> Vec<Bot> {
        self.with(|s| {
            let others: Vec<Bot> = s.bots.iter().filter(|b| b.id != bot.id && b.is_on()).cloned().collect();
            let Some(allowed) = &bot.can_message else { return others };
            let mut allowed: HashSet<String> = allowed.iter().cloned().collect();
            match bot.authority_level() {
                "ceo" => return others,
                "lead" => {
                    for g in s.groups.iter().filter(|g| g.head_id.as_deref() == Some(&bot.id)) {
                        allowed.extend(g.member_ids.iter().cloned());
                    }
                }
                _ => {}
            }
            others.into_iter().filter(|b| allowed.contains(&b.id)).collect()
        })
    }

    fn direct_message_target(&self, name: &str, sender: &Bot) -> Option<Bot> {
        let wanted = protocol::search_name(name);
        if wanted.is_empty() {
            return None;
        }
        let candidates = if sender.primary { self.with(|s| s.bots.iter().filter(|b| b.id != sender.id && b.is_on()).cloned().collect()) } else { self.reachable(sender) };
        candidates.iter().find(|b| protocol::search_name(&b.name) == wanted).cloned()
            .or_else(|| candidates.iter().find(|b| protocol::search_name(&b.name).contains(&wanted)).cloned())
    }

    fn reach_note(&self, bot: &Bot) -> String {
        let reachable: Vec<(String, String)> = self.reachable(bot).iter().map(|b| (b.name.clone(), b.description.clone())).collect();
        prompts::reach_how_to(&reachable, &self.owner())
    }

    fn room_label(&self, room: &str) -> String {
        if let Some(g) = self.group_for_room(room) {
            return format!("the \"{}\" group chat", g.name);
        }
        if let Some((a, b)) = dm::members(room) {
            let names: Vec<String> = [a, b].iter().map(|id| self.bot(id).map(|x| x.name).unwrap_or_else(|| id.clone())).collect();
            return format!("the private thread between {} and {}", names[0], names[1]);
        }
        format!("your own chat with {}", self.owner())
    }

    fn awareness(&self, bot: &Bot, room: &str) -> String { prompts::awareness_note(bot, room, &self.room_label(room), prompts::os_name()) }

    /// The persona: Claude Code takes it as its system prompt.
    pub fn persona(&self, bot: &Bot) -> String {
        let owner = self.owner();
        let mut parts = vec![bot.instructions.clone(), prompts::house_style(&owner), prompts::ASKING_STYLE.to_string()];
        let team = self.bots();
        if bot.primary {
            let others: Vec<String> = team.iter().filter(|b| b.id != bot.id).map(|b| format!("{} ({})", b.name, b.description)).collect();
            if !others.is_empty() {
                parts.push(format!("Your teammates: {}.", others.join("; ")));
            }
        }
        parts.push(prompts::routine_how_to(&owner));
        parts.push(prompts::coding_how_to("Claude Code"));
        parts.push(self.reach_note(bot));
        if !bot.apps.is_empty() {
            let names: Vec<String> = bot.apps.iter().map(|a| a.strip_prefix("claude.ai ").unwrap_or(a).to_string()).collect();
            parts.push(format!("Apps you can use: {}. Their tools are yours to call when the owner's request needs them; any other app's tools are off for you.", names.join(", ")));
        }
        let memory_file = self.paths.memory_file(&bot.id);
        let memory = std::fs::read_to_string(&memory_file).unwrap_or_default();
        parts.push(prompts::memory_section(&memory, &memory_file.to_string_lossy()));
        let recall: Vec<(String, String)> = self.recall_files(&bot.id).into_iter().map(|(l, p)| (l, p.to_string_lossy().to_string())).collect();
        parts.push(prompts::recall_section(&self.chat_file_path(&bot.id).to_string_lossy(), &owner, &recall));
        let names: HashMap<String, String> = team.iter().map(|b| (b.id.clone(), b.name.clone())).collect();
        let skills = prompts::all_skills(&self.paths, &names, Some(&bot.id));
        parts.push(prompts::skills_section(&skills, &self.paths.skills_dir(&bot.id).to_string_lossy(), &self.paths.shared_skills_dir().to_string_lossy(), &bot.name, &owner));
        parts.join("\n\n")
    }

    /// The first message on engines without a system prompt option.
    fn first_message(&self, bot: &Bot, text: &str) -> String {
        if bot.provider == "claude" { text.to_string() } else { format!("{}\n\n---\n\n{}", self.persona(bot), text) }
    }

    // MARK: Claiming a bot

    /// Takes the bot for a turn when it's free.
    fn claim(&self, bot: &str, room: &str) -> bool {
        self.with(|s| {
            if s.replying.contains_key(bot) {
                return false;
            }
            s.replying.insert(bot.into(), String::new());
            s.replying_in.insert(bot.into(), room.into());
            s.replying_since.insert(bot.into(), Utc::now());
            true
        })
    }

    fn release(&self, bot: &str) {
        self.with(|s| {
            s.replying.remove(bot);
            s.replying_in.remove(bot);
        });
    }

    pub fn is_replying(&self, bot: &str) -> bool { self.with(|s| s.replying.contains_key(bot)) }

    /// Waits for the bot to be free and takes it, up to `limit` seconds. False when the time ran out or `give_up` said so.
    async fn wait_and_claim(&self, bot: &str, room: &str, limit: f64, give_up: impl Fn(&State) -> bool) -> bool {
        let deadline = Instant::now() + Duration::from_secs_f64(limit);
        loop {
            if self.with(|s| give_up(s)) {
                return false;
            }
            if self.claim(bot, room) {
                return true;
            }
            if Instant::now() > deadline {
                return false;
            }
            tokio::time::sleep(Duration::from_millis(200)).await;
        }
    }

    /// Owner messages to one bot answer in the order they were sent.
    async fn wait_in_line(&self, bot: &str, room: &str) {
        let ticket = self.with(|s| {
            s.next_ticket += 1;
            let t = s.next_ticket;
            s.queues.entry(bot.into()).or_default().push_back(t);
            t
        });
        loop {
            let taken = self.with(|s| {
                let front = s.queues.get(bot).and_then(|q| q.front().copied());
                if front == Some(ticket) && !s.replying.contains_key(bot) {
                    s.replying_since.insert(bot.into(), Utc::now());
                    s.queues.get_mut(bot).unwrap().pop_front();
                    s.replying.insert(bot.into(), String::new());
                    s.replying_in.insert(bot.into(), room.into());
                    true
                } else {
                    false
                }
            });
            if taken {
                return;
            }
            tokio::time::sleep(Duration::from_millis(200)).await;
        }
    }

    fn owner_spoke(&self, room: &str) {
        self.with(|s| {
            *s.owner_turns.entry(room.into()).or_default() += 1;
            s.budgets.entry(room.into()).or_default().owner_spoke();
            s.stopped_exchange_rooms.remove(room);
        });
    }

    /// The owner's latest words in a chat, unless that was a routine's run.
    pub fn recent_owner_words(&self, room: &str) -> Option<String> {
        self.with(|s| {
            s.conversations.get(room)?.messages.iter().rev().find(|m| m.author == OWNER_AUTHOR).map(|m| m.text.clone())
        }).filter(|t| !protocol::is_routine_run(t))
    }

    // MARK: The owner's messages

    /// A message from the owner to a bot's own chat.
    pub fn send(self: &Arc<Self>, text: &str, bot_id: &str) { self.send_with_id(text, bot_id, None, None) }

    pub fn send_with_id(self: &Arc<Self>, text: &str, bot_id: &str, message_id: Option<String>, written_at: Option<DateTime<Utc>>) {
        let Some(bot) = self.bot(bot_id) else { return };
        let message = {
            let mut m = ChatMessage::new(OWNER_AUTHOR, text);
            if let Some(id) = message_id.clone() { m.id = id; }
            if let Some(at) = written_at { m.at = at; }
            m
        };
        let owner_message_id = message.id.clone();
        let already = self.with(|s| s.conversations.get(bot_id).map(|c| c.messages.iter().any(|m| m.id == owner_message_id)).unwrap_or(false));
        if protocol::asks_for_doctor(text) {
            self.post(message, bot_id);
            let findings = self.doctor_findings();
            self.post(ChatMessage::note(doctor_markdown(&findings)), bot_id);
            return;
        }
        if protocol::asks_for_fresh_session(text) {
            self.post(message, bot_id);
            self.start_fresh_session(bot_id);
            return;
        }
        if !bot.is_on() {
            self.post(message, bot_id);
            self.post(ChatMessage::new(&bot.id, format!("_({} is turned off. Turn it on in its settings to chat.)_", bot.name)), bot_id);
            return;
        }
        if !already {
            self.post(message, bot_id);
        }
        // New work: the owner has seen the chat, and an old failure no longer stands.
        self.with(|s| s.seen.insert(bot_id.into(), Utc::now()));
        if bot.last_failure.as_ref().map(|f| f.kind == "failed").unwrap_or(false) {
            self.set_failure(bot_id, None);
        }
        let me = self.clone();
        let text = text.to_string();
        tokio::spawn(async move {
            me.wait_in_line(&bot.id, &bot.id).await;
            // It may have been changed or turned off while the message waited.
            let Some(bot) = me.bot(&bot.id) else { return me.release(&bot.id) };
            me.start_own_turn(bot, &text, &owner_message_id).await;
        });
    }

    async fn start_own_turn(self: &Arc<Self>, bot: Bot, text: &str, owner_message_id: &str) {
        let record = self.conversation(&bot.id);
        let session = record.sessions.get(&bot.id).cloned();
        let first_turn = session.is_none();
        let mut prompt = if first_turn { self.first_message(&bot, text) } else { text.to_string() };
        if !first_turn && protocol::asks_for_schedule(text) {
            prompt.push_str(&format!("\n\n({})", prompts::routine_how_to(&self.owner())));
        }
        let tagged = protocol::mentions_ordered(text, &self.reachable(&bot).iter().map(|b| (b.id.clone(), b.name.clone())).collect::<Vec<_>>());
        if !tagged.is_empty() {
            let names: Vec<String> = tagged.iter().filter_map(|id| self.bot(id).map(|b| b.name)).collect();
            prompt.push_str(&format!("\n\n({} tagged {}: message them with a [TELL:] line.)", self.owner(), names.join(" and ")));
        }
        prompt = self.catch_up(&record, &bot, owner_message_id) + &prompt;
        if !bot.primary {
            prompt = format!("({})\n\n{}", self.reach_note(&bot), prompt);
        }
        prompt = self.awareness(&bot, &bot.id) + &prompt;
        self.owner_spoke(&bot.id);
        self.reply(bot.clone(), bot.id.clone(), prompt, session, ReplyOpts { from_owner: true, ..Default::default() }).await;
    }

    /// What this bot's engine session hasn't heard of its own chat (messages that came while it had no session, or a routine).
    fn catch_up(&self, record: &Conversation, bot: &Bot, before: &str) -> String {
        let heard = record.heard.get(&bot.id);
        let has_session = record.sessions.contains_key(&bot.id);
        let upto = record.messages.iter().position(|m| m.id == before).unwrap_or(record.messages.len());
        let earlier = &record.messages[..upto];
        let start = match heard {
            Some(h) => earlier.iter().position(|m| &m.id == h).map(|i| i + 1).unwrap_or(0),
            None if has_session => earlier.len(),
            None => 0,
        };
        let unheard: Vec<&ChatMessage> = earlier[start..].iter().filter(|m| m.author != NOTE_AUTHOR && !m.text.is_empty()).collect();
        let unheard: Vec<&ChatMessage> = unheard.into_iter().rev().take(20).collect::<Vec<_>>().into_iter().rev().collect();
        if unheard.is_empty() {
            return String::new();
        }
        let mut total = 0;
        let mut lines = vec![];
        for m in unheard {
            let who = if m.author == OWNER_AUTHOR { self.owner() } else if m.author == ROUTINE_AUTHOR { "Routine".into() } else { self.bot(&m.author).map(|b| b.name).unwrap_or(m.author.clone()) };
            let text: String = m.text.chars().take(1500).collect();
            total += text.len();
            if total > 12_000 { break; }
            lines.push(format!("{who}: {text}"));
        }
        format!("(Said in this chat that your session hasn't seen:\n{}\n)\n\n", lines.join("\n"))
    }

    pub fn start_fresh_session(&self, bot_id: &str) {
        let Some(bot) = self.bot(bot_id) else { return };
        if self.is_replying(bot_id) {
            self.stop(bot_id);
        }
        self.with(|s| {
            let c = s.conversations.entry(bot_id.into()).or_default();
            c.sessions.remove(bot_id);
            if let Some(last) = c.messages.last().map(|m| m.id.clone()) {
                c.heard.insert(bot_id.into(), last);
            }
        });
        self.post(ChatMessage::note(format!("{} starts a fresh session from its next reply. Its memory, skills and this chat are kept.", bot.name)), bot_id);
    }

    // MARK: Stop

    pub fn stop(&self, bot_id: &str) {
        let room = self.with(|s| {
            s.stopped.insert(bot_id.into());
            s.replying_in.get(bot_id).cloned()
        });
        self.stopped_at.lock().unwrap().insert(bot_id.into(), Instant::now());
        if let Some(c) = self.procs.lock().unwrap().get(bot_id) {
            c.cancel();
        }
        self.stop_private_messages(bot_id);
        if let Some(room) = room {
            if room != bot_id {
                self.stop_private_messages(&room);
            }
        }
    }

    pub fn stop_group(&self, group_id: &str) {
        let Some(group) = self.group(group_id) else { return };
        let room = group.room_id();
        self.with(|s| {
            if let Some(r) = s.rounds.get_mut(&room) {
                r.plan.finish();
                r.next_first = None;
            }
        });
        let speaking: Vec<String> = self.with(|s| s.replying_in.iter().filter(|(_, r)| **r == room).map(|(b, _)| b.clone()).collect());
        for b in speaking {
            self.stop(&b);
        }
        self.stop_private_messages(&room);
    }

    fn was_stopped_since(&self, bot: &str, since: Instant) -> bool {
        self.stopped_at.lock().unwrap().get(bot).map(|t| *t >= since).unwrap_or(false)
    }

    fn stop_private_messages(&self, room: &str) {
        let live: Vec<(String, DmLive)> = self.with(|s| {
            s.stopped_exchange_rooms.insert(room.into());
            *s.stop_counts.entry(room.into()).or_default() += 1;
            let live: Vec<(String, DmLive)> = s.live_exchanges.iter().filter(|(_, e)| e.root_room == room || e.room == room).map(|(k, v)| (k.clone(), v.clone())).collect();
            for (id, e) in &live {
                s.stopped_exchange_rooms.insert(e.root_room.clone());
                if e.root_room != room {
                    *s.stop_counts.entry(e.root_room.clone()).or_default() += 1;
                }
                s.live_exchanges.remove(id);
            }
            live
        });
        for (id, e) in live {
            let thread = dm::id(&e.sender, &e.target);
            self.post(ChatMessage::note("Stopped.").with_exchange(Some(id)), &thread);
            if self.with(|s| s.replying_in.get(&e.target) == Some(&thread)) {
                self.stop(&e.target);
            }
        }
    }

    // MARK: One turn

    /// Runs a bot's turn and handles what its reply asks for. The bot must already be claimed. Returns its words (including
    /// what it said after hearing back from bots it messaged), or None when it failed or was stopped.
    pub fn reply(self: &Arc<Self>, bot: Bot, conversation_id: String, prompt: String, session: Option<String>, opts: ReplyOpts) -> Fut<Option<String>> {
        let me = self.clone();
        Box::pin(async move {
            me.with(|s| {
                s.stopped.remove(&bot.id);
                if opts.privately.is_none() {
                    s.stopped_exchange_rooms.remove(&conversation_id);
                }
                s.replying.insert(bot.id.clone(), String::new());
                s.replying_in.insert(bot.id.clone(), conversation_id.clone());
            });
            let owner_text = if opts.from_owner { me.recent_owner_words(&conversation_id) } else { opts.privately.as_ref().and_then(|p| p.ctx.owner_words.clone()) };
            let readable = owner_text.as_deref().map(crate::policy::paths_in_words).unwrap_or_default();
            let mut recall = vec![me.chat_file_path(&bot.id)];
            recall.extend(me.recall_files(&bot.id).into_iter().map(|(_, p)| p));
            let live_bot = bot.id.clone();
            let live_me = me.clone();
            let on_text = move |t: &str| {
                let shown = protocol::extract_orders(t).0;
                live_me.with(|s| {
                    if let Some(slot) = s.replying.get_mut(&live_bot) {
                        *slot = shown;
                    }
                });
            };
            let result = match me.run_turn(&bot, &prompt, session.clone(), &readable, &recall, on_text.clone()).await {
                Err(RunError::LostSession) if session.is_some() => {
                    let fresh = me.start_over_prompt(&bot, &conversation_id, &prompt);
                    me.run_turn(&bot, &fresh, None, &readable, &recall, on_text).await
                }
                other => other,
            };
            let mut answer: Option<String> = None;
            let mut new_session = session.clone();
            let mut failure: Option<(String, &'static str)> = None;
            match result {
                Ok((text, s)) => {
                    answer = Some(me.keeping_long_reply_aside(text.trim(), &bot));
                    new_session = s;
                }
                Err(e) => {
                    // Signed out or not installed is something the owner fixes: yellow. Anything else is a failure: red.
                    let kind = match &e {
                        RunError::NotInstalled(_) => "signin",
                        RunError::Failed(m) | RunError::EngineDown(m) if failover::classify(m) == Failure::Auth => "signin",
                        _ => "failed",
                    };
                    failure = Some((e.to_string(), kind));
                }
            }
            let exchange = opts.privately.as_ref().and_then(|p| p.exchange_id.clone());
            let was_stopped = me.with(|s| s.stopped.remove(&bot.id));
            match (&failure, was_stopped) {
                (Some((f, kind)), false) => {
                    me.post(ChatMessage::new(&bot.id, format!("Couldn't reply: {f}")).with_exchange(exchange.clone()), &conversation_id);
                    me.set_failure(&bot.id, Some(LastFailure { kind: kind.to_string(), reason: f.clone(), at: Utc::now() }));
                }
                (None, false) => me.set_failure(&bot.id, None),
                _ => {}
            }
            // Orders don't show in the chat; [TELL:] lines become private messages.
            let mut tells: Vec<(String, String)> = vec![];
            let mut clicky_orders = 0;
            if let Some(said) = answer.clone() {
                let (text, orders) = protocol::extract_orders(&said);
                answer = Some(text);
                for o in orders {
                    match o {
                        Order::Tell { name, message } => tells.push((name, message)),
                        Order::Clicky(_) => clicky_orders += 1,
                    }
                }
                // An answer goes back by itself, so a line back to whoever asked is just more of the answer.
                if let Some(partner) = opts.privately.as_ref().and_then(|p| p.asker_id.clone()).and_then(|id| me.bot(&id)) {
                    let pn = protocol::search_name(&partner.name);
                    let (to_partner, rest): (Vec<_>, Vec<_>) = tells.into_iter().partition(|(n, _)| protocol::search_name(n) == pn);
                    tells = rest;
                    let mut words: Vec<String> = vec![answer.clone().unwrap_or_default()];
                    words.extend(to_partner.into_iter().map(|(_, m)| m));
                    answer = Some(words.into_iter().filter(|w| !w.is_empty()).collect::<Vec<_>>().join("\n\n"));
                }
                if opts.privately.as_ref().map(|p| !p.may_message).unwrap_or(false) {
                    tells.clear();
                }
            }
            let streamed = me.with(|s| s.replying.get(&bot.id).cloned());
            me.release(&bot.id);
            if was_stopped {
                let partial = answer.clone().or(streamed).unwrap_or_default().trim().to_string();
                let text = if partial.is_empty() { "_(Stopped.)_".to_string() } else { format!("{partial}\n\n_(Stopped.)_") };
                me.post(ChatMessage::new(&bot.id, text).with_exchange(exchange), &conversation_id);
                return None;
            }
            let quiet = opts.quiet_allowed && protocol::is_quiet(answer.as_deref());
            {
                let s = &mut *me.state.lock().unwrap();
                let is_room = s.groups.iter().any(|g| g.head_id.is_some() && g.room_id() == conversation_id);
                let record = s.conversations.entry(conversation_id.clone()).or_default();
                if let Some(ns) = new_session.clone() {
                    record.sessions.insert(bot.id.clone(), ns);
                }
                if !quiet {
                    match answer.as_deref() {
                        Some(a) if !a.is_empty() => {
                            let message = ChatMessage::new(&bot.id, protocol::without_name_heading(a, &bot.name)).with_exchange(exchange.clone());
                            if is_room {
                                record.own_answers.entry(bot.id.clone()).or_default().push(message.id.clone());
                            }
                            record.messages.push(message);
                        }
                        Some(_) if tells.is_empty() && clicky_orders == 0 => {
                            record.messages.push(ChatMessage::new(&bot.id, "(No answer this time. Send it again, or try another model.)").with_exchange(exchange.clone()));
                        }
                        _ => {}
                    }
                    if let Some(last) = record.messages.last().map(|m| m.id.clone()) {
                        record.heard.insert(bot.id.clone(), last);
                    }
                }
                self_write(&me, s, &conversation_id);
            }
            if quiet {
                return Some(protocol::QUIET_MARKER.to_string());
            }
            me.fire_hook("turn-finished", json!({"bot": bot.id, "botName": bot.name, "chat": conversation_id, "fromOwner": opts.from_owner, "privately": opts.privately.is_some(), "ok": answer.is_some(), "reply": answer.clone().unwrap_or_default()}));
            if clicky_orders > 0 && bot.primary {
                me.post(ChatMessage::note("Clicky isn't part of this build of Theo yet, so that order to Clicky wasn't carried out."), &conversation_id);
            }
            if opts.from_owner {
                if let Some(a) = answer.clone() {
                    let head_of_room = me.group_for_room(&conversation_id).and_then(|g| g.head_id) == Some(bot.id.clone());
                    if head_of_room || conversation_id == bot.id {
                        me.submit_if_final(&a, &conversation_id, &bot);
                    }
                    if let Some(request) = protocol::routine_request(&a) {
                        let words = me.recent_owner_words(&conversation_id);
                        if words.as_deref().map(protocol::owner_asked_for_routine).unwrap_or(false) {
                            let target = me.group_for_room(&conversation_id).map(|g| format!("group:{}", g.id)).unwrap_or(bot.id.clone());
                            me.add_routine_from_chat(&request, &target);
                        } else {
                            let target = me.group_for_room(&conversation_id).map(|g| format!("group:{}", g.id)).unwrap_or(bot.id.clone());
                            me.ask_routine(&bot, &request, &target, &conversation_id);
                        }
                    }
                }
            } else if let Some(a) = answer.as_deref() {
                if let Some(request) = protocol::routine_request(a) {
                    let target = if dm::is_thread(&conversation_id) { bot.id.clone() } else { me.group_for_room(&conversation_id).map(|g| format!("group:{}", g.id)).unwrap_or(bot.id.clone()) };
                    // In a private thread nobody's there to answer: the card goes to the bot's own chat.
                    let room = if dm::is_thread(&conversation_id) { bot.id.clone() } else { conversation_id.clone() };
                    me.ask_routine(&bot, &request, &target, &room);
                }
            }
            if !tells.is_empty() {
                let ctx = opts.privately.as_ref().map(|p| p.ctx.clone()).unwrap_or_else(|| DmContext {
                    root_room: conversation_id.clone(),
                    owner_words: if opts.from_owner { me.recent_owner_words(&conversation_id) } else { None },
                    from_owner: opts.from_owner,
                });
                let asker = opts.privately.as_ref().and_then(|p| p.asker_id.clone());
                let final_words = me.run_private_messages(tells, bot.clone(), conversation_id.clone(), ctx, asker, exchange).await;
                let words: Vec<String> = [answer, final_words].into_iter().flatten().filter(|w| !w.is_empty()).collect();
                return if words.is_empty() { None } else { Some(words.join("\n\n")) };
            }
            answer
        })
    }

    fn start_over_prompt(&self, bot: &Bot, room: &str, prompt: &str) -> String {
        let record = self.conversation(room);
        let lines: Vec<String> = record.messages.iter().filter(|m| !m.text.is_empty() && m.author != NOTE_AUTHOR).rev().take(8).collect::<Vec<_>>().into_iter().rev().map(|m| {
            let who = if m.author == OWNER_AUTHOR { self.owner() } else { self.bot(&m.author).map(|b| b.name).unwrap_or(m.author.clone()) };
            format!("{}: {}", who, m.text.chars().take(1500).collect::<String>())
        }).collect();
        let history = if lines.is_empty() { String::new() } else { format!("(Your earlier session of this chat is gone, so here's the chat so far:\n\n{}\n\nUse it as context.)\n\n", lines.join("\n")) };
        self.first_message(bot, &(history + prompt))
    }

    fn keeping_long_reply_aside(&self, text: &str, bot: &Bot) -> String {
        if text.chars().count() <= LONGEST_SHOWN_REPLY {
            return text.to_string();
        }
        let folder = self.paths.memory_dir(&bot.id).join("long-replies");
        let _ = std::fs::create_dir_all(&folder);
        let file = folder.join(format!("reply-{}.md", Utc::now().format("%Y%m%dT%H%M%S%3f")));
        let saved = std::fs::write(&file, text).is_ok();
        let kept: String = text.chars().take(LONGEST_SHOWN_REPLY).collect();
        let count = text.chars().count();
        if saved {
            format!("{kept}\n\n_(This reply was {count} characters long, so the chat shows the start. The whole of it is in {}.)_", file.display())
        } else {
            format!("{kept}\n\n_(This reply was {count} characters long, so the chat shows the start only.)_")
        }
    }

    // MARK: Engines

    /// The program behind a provider: a test profile's stand-in, or the installed one.
    pub fn executable(&self, provider: &str) -> Option<PathBuf> {
        if let Some(path) = self.settings.string(&format!("test.engine.{provider}")) {
            let p = PathBuf::from(path);
            return if p.is_file() { Some(p) } else { None };
        }
        engine::locate(provider)
    }

    /// One turn with retries, the fallback chain, and Claude Code standing in for another engine that keeps failing.
    async fn run_turn(&self, bot: &Bot, prompt: &str, session: Option<String>, readable: &[PathBuf], recall: &[PathBuf], on_text: impl Fn(&str) + Clone + Send + Sync + 'static) -> Result<(String, Option<String>), RunError> {
        match self.run_with_failover(bot, prompt, session.clone(), readable, recall, on_text.clone()).await {
            Err(RunError::EngineDown(why)) => {
                let mut stand_in = bot.clone();
                stand_in.provider = "claude".into();
                stand_in.model = self.settings.strings("v3.bots.fallbackModels").and_then(|v| v.first().cloned()).filter(|m| m != "off").unwrap_or_else(|| "claude-haiku-5-5".into());
                stand_in.effort = None;
                let label = if bot.provider == "opencode" { "OpenCode" } else { &bot.provider };
                let (text, _) = self.run_on_engine(&stand_in, &stand_in.model.clone(), prompt, None, readable, recall, on_text).await?;
                Ok((format!("{text}\n\n_({label} kept failing ({}), so this reply came from {}.)_", why.chars().take(80).collect::<String>(), failover::model_label(&stand_in.model)), session))
            }
            other => other,
        }
    }

    async fn run_with_failover(&self, bot: &Bot, prompt: &str, session: Option<String>, readable: &[PathBuf], recall: &[PathBuf], on_text: impl Fn(&str) + Clone + Send + Sync + 'static) -> Result<(String, Option<String>), RunError> {
        let configured = self.settings.strings("v3.bots.fallbackModels");
        let off = configured.as_deref() == Some(&["off".to_string()][..]);
        let fallbacks = if bot.provider == "claude" && !off { Plan::chain(&bot.model, configured.as_deref()) } else { vec![] };
        let plan = Plan { retry_delays: self.settings.retry_delays(), fallbacks };
        let began = Instant::now();
        let mut model = bot.model.clone();
        let mut attempt = 0;
        let mut fallback_index: Option<usize> = None;
        let mut first_failure: Option<Failure> = None;
        loop {
            match self.run_on_engine(bot, &model, prompt, session.clone(), readable, recall, on_text.clone()).await {
                Ok((text, s)) => {
                    if model != bot.model {
                        if let Some(reason) = first_failure {
                            return Ok((format!("{text}\n\n{}", failover::fallback_note(&bot.model, &model, reason)), s));
                        }
                    }
                    return Ok((text, s));
                }
                Err(RunError::Failed(message)) => {
                    let failure = failover::classify(&message);
                    let stopped = self.was_stopped_since(&bot.id, began);
                    let next = if stopped { None } else { plan.next(failure, &model, attempt, fallback_index) };
                    let Some(next) = next else {
                        if bot.provider != "claude" && matches!(failure, Failure::Transient | Failure::ModelUnavailable) && !off && !stopped && self.executable("claude").is_some() {
                            return Err(RunError::EngineDown(message.chars().take(300).collect()));
                        }
                        return Err(RunError::Failed(message));
                    };
                    eprintln!("[failover] bot {}: {} failed ({:?}): {}; next {} in {}s", bot.id, model, failure, message.chars().take(160).collect::<String>(), next.model, next.delay);
                    first_failure.get_or_insert(failure);
                    if next.is_fallback {
                        fallback_index = Some(fallback_index.map(|i| i + 1).unwrap_or(0));
                    }
                    attempt += 1;
                    if next.delay > 0.0 {
                        tokio::time::sleep(Duration::from_secs_f64(next.delay)).await;
                    }
                    if self.was_stopped_since(&bot.id, began) {
                        return Err(RunError::Failed(message));
                    }
                    model = next.model;
                }
                Err(e) => return Err(e),
            }
        }
    }

    #[allow(clippy::too_many_arguments)]
    async fn run_on_engine(&self, bot: &Bot, model: &str, prompt: &str, session: Option<String>, readable: &[PathBuf], recall: &[PathBuf], on_text: impl Fn(&str) + Send + Sync + 'static) -> Result<(String, Option<String>), RunError> {
        let is_claude = bot.provider == "claude";
        let provider = if is_claude { "claude" } else { "opencode" };
        let label = if is_claude { "Claude Code" } else { "OpenCode" };
        let Some(program) = self.executable(provider) else { return Err(RunError::NotInstalled(label.into())) };
        let workspace = self.paths.memory_root();
        let _ = std::fs::create_dir_all(&workspace);
        let _ = std::fs::create_dir_all(self.paths.memory_dir(&bot.id));
        let mut new_session = None;
        // This turn's own folder for the system prompt the engine reads; removed when the turn ends, however it ends.
        let turn_folder = TurnFolder(self.paths.turns_dir().join(uuid::Uuid::new_v4().to_string()));
        let mut stdin = None;
        let args = if is_claude {
            if session.is_none() {
                new_session = Some(uuid::Uuid::new_v4().to_string());
            }
            let persona = self.persona(bot);
            let persona_file = turn_folder.0.join("system-prompt.md");
            let settings_file = turn_folder.0.join("settings.json");
            let (args, settings) = crate::policy::claude_turn(&self.paths, bot, model, &persona_file, &settings_file, session.as_deref(), new_session.as_deref(), readable, recall);
            std::fs::create_dir_all(&turn_folder.0)
                .and_then(|_| std::fs::write(&persona_file, persona.as_bytes()))
                .and_then(|_| std::fs::write(&settings_file, serde_json::to_vec_pretty(&settings).unwrap_or_default()))
                .map_err(|e| RunError::Failed(format!("Couldn't write the bot's instructions for its engine: {e}")))?;
            stdin = Some(prompt.to_string());
            args
        } else {
            let mut a: Vec<String> = vec!["run".into(), "-m".into(), model.into(), "--format".into(), "json".into(), "--dir".into(), workspace.to_string_lossy().to_string()];
            if let Some(s) = &session {
                a.push("-s".into());
                a.push(s.clone());
            }
            a.push(prompt.into());
            a
        };
        let spec = Spec {
            program,
            args,
            env: vec![("NO_COLOR".into(), "1".into()), ("PWD".into(), workspace.to_string_lossy().to_string())],
            // Theo might itself be running inside Claude Code; the bot's engine mustn't think it's nested.
            remove_env: ["CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_CODE_SSE_PORT", "ANTHROPIC_API_KEY_HELPER"].iter().map(|s| s.to_string()).collect(),
            cwd: workspace,
            limit: Duration::from_secs_f64(self.settings.turn_limit_seconds()),
            format: if is_claude { Format::Claude } else { Format::OpenCode },
            stdin,
        };
        let cancel = Cancel::new();
        if self.with(|s| s.stopped.contains(&bot.id)) {
            return Err(RunError::Failed("Stopped.".into()));
        }
        self.procs.lock().unwrap().insert(bot.id.clone(), cancel.clone());
        let outcome = engine::run(spec, cancel.clone(), Some(self.registry.clone()), on_text).await;
        {
            let mut procs = self.procs.lock().unwrap();
            if procs.get(&bot.id).map(|c| Arc::ptr_eq(c, &cancel)).unwrap_or(false) {
                procs.remove(&bot.id);
            }
        }
        let outcome = outcome.map_err(|e| RunError::Failed(format!("{label} couldn't start: {e}")))?;
        if let Some(u) = &outcome.usage {
            let data = {
                let mut ledger = self.usage.lock().unwrap();
                ledger.record(&bot.id, u, Utc::now());
                serde_json::to_vec(&*ledger).unwrap_or_default()
            };
            let _ = write_atomic(&self.paths.usage_file(), &data);
        }
        if !outcome.stderr_tail.is_empty() {
            let log = self.paths.logs_dir().join(format!("bots-{provider}.log"));
            use std::io::Write;
            if let Ok(mut f) = std::fs::OpenOptions::new().create(true).append(true).open(&log) {
                let _ = f.write_all(outcome.stderr_tail.as_bytes());
            }
        }
        let text = outcome.text.clone();
        let resolved = outcome.session_id.clone().or(new_session).or(session.clone());
        match outcome.end {
            EndReason::Timeout => {
                let secs = self.settings.turn_limit_seconds();
                let minutes = (secs / 60.0).round() as i64;
                let limit = if minutes >= 1 { format!("{minutes} minute{}", if minutes == 1 { "" } else { "s" }) } else { format!("{} seconds", secs as i64) };
                if text.trim().is_empty() {
                    return Err(RunError::Failed(format!("{label} didn't finish within {limit}, so Theo stopped it.")));
                }
                return Ok((format!("{text}\n\n_(Cut off: this reply didn't finish within {limit}, so Theo stopped it.)_"), resolved));
            }
            EndReason::Cancelled => return Ok((text, resolved)),
            EndReason::Exited => {}
        }
        // Claude Code signed out answers with its own one line ("Not logged in · Please run /login") as if it were the reply,
        // so a reply that is only that line, or only the error it reported, is the turn failing, never the bot speaking.
        let error = outcome.error.clone().or_else(|| protocol::is_sign_in_line(&text).then(|| text.trim().to_string()));
        if let Some(error) = &error {
            if text.trim().is_empty() || text.trim() == error.trim() || protocol::is_sign_in_line(&text) {
                let last = outcome.stderr_tail.lines().last().unwrap_or("").trim().to_string();
                if session.is_some() && (protocol::says_session_is_lost(error) || protocol::says_session_is_lost(&outcome.stderr_tail)) {
                    return Err(RunError::LostSession);
                }
                return Err(RunError::Failed(if error == "Claude reported an error." && !last.is_empty() { format!("Claude reported an error: {}", last.chars().take(300).collect::<String>()) } else { error.clone() }));
            }
        }
        let status = outcome.exit_code.unwrap_or(-1);
        if text.is_empty() && status != 0 {
            if session.is_some() && protocol::says_session_is_lost(&outcome.stderr_tail) {
                return Err(RunError::LostSession);
            }
            return Err(RunError::Failed(format!("{label} stopped (exit {status}). Details are in {}.", self.paths.logs_dir().join(format!("bots-{provider}.log")).display())));
        }
        Ok((text, resolved))
    }

    // MARK: Private messages

    /// Sends a bot's [TELL:] lines, then lets it carry on with all the answers at once. Different bots answer at the same time
    /// (up to `v3.bots.parallelMessages`); lines to the same bot go one after another. Every line is checked against the caps first.
    fn run_private_messages(self: &Arc<Self>, tells: Vec<(String, String)>, sender: Bot, room: String, ctx: DmContext, asker: Option<String>, exchange_id: Option<String>) -> Fut<Option<String>> {
        let me = self.clone();
        Box::pin(async move {
            let stops_before = me.with(|s| s.stop_counts.get(&ctx.root_room).copied().unwrap_or(0));
            let root = ctx.root_room.clone();
            let was_stopped = {
                let me = me.clone();
                let root = root.clone();
                move || me.with(|s| s.stopped_exchange_rooms.contains(&root) || s.stop_counts.get(&root).copied().unwrap_or(0) != stops_before)
            };
            let mut reply_at: HashMap<usize, (String, String)> = HashMap::new();
            let mut note_at: HashMap<usize, String> = HashMap::new();
            let mut last_round: Vec<String> = vec![];
            struct Job { index: usize, target: Bot, exchange: Exchange, words: String }
            let mut jobs: Vec<Job> = vec![];
            for (index, (name, message)) in tells.into_iter().enumerate() {
                if was_stopped() { break; }
                let Some(target) = me.direct_message_target(&name, &sender) else {
                    let names: Vec<String> = if sender.primary { me.bots().into_iter().filter(|b| b.id != sender.id && b.is_on()).map(|b| b.name).collect() } else { me.reachable(&sender).into_iter().map(|b| b.name).collect() };
                    note_at.insert(index, format!("There's nobody called {name} you can message. Who you can reach: {}.", names.join(", ")));
                    continue;
                };
                let key = format!("{}|{}|{}", room, sender.id, target.id);
                // Checked and counted in one step: relays answering at the same time could otherwise each see 11 sent and
                // both send, going past the cap (seen on Windows).
                let (verdict, exchange) = me.with(|s| {
                    let turn = s.owner_turns.get(&ctx.root_room).copied().unwrap_or(0);
                    let mut exchange = s.open_exchanges.get(&key).filter(|e| e.owner_turn == turn).cloned().unwrap_or_else(|| Exchange {
                        id: uuid::Uuid::new_v4().to_string().to_uppercase(),
                        thread_id: dm::id(&sender.id, &target.id),
                        owner_turn: turn,
                        round_trips: 0,
                    });
                    let verdict = s.budgets.get(&ctx.root_room).cloned().unwrap_or_default().verdict(exchange.round_trips);
                    if protocol::cap_line(verdict, "", "").is_none() {
                        exchange.round_trips += 1;
                        s.budgets.entry(ctx.root_room.clone()).or_default().note_sent();
                        s.open_exchanges.insert(key.clone(), exchange.clone());
                    }
                    (verdict, exchange)
                });
                if let Some(line) = protocol::cap_line(verdict, &sender.name, &target.name) {
                    me.post(ChatMessage::note(line.clone()).with_exchange(exchange_id.clone()), &room);
                    note_at.insert(index, line);
                    continue;
                }
                let first = exchange.round_trips == 1;
                if first {
                    let mut card = ChatMessage::new(&sender.id, "");
                    card.card = Some(dm::card(&exchange.id, &target.id));
                    card.exchange_id = exchange_id.clone();
                    me.post(card, &room);
                }
                me.post(ChatMessage::new(&sender.id, message.clone()).with_exchange(Some(exchange.id.clone())), &exchange.thread_id);
                jobs.push(Job { index, target, exchange, words: message });
            }
            // Each bot's lines in order; different bots at once, a few at a time.
            let mut queues: Vec<Vec<Job>> = vec![];
            for job in jobs {
                if let Some(q) = queues.iter_mut().find(|q| q[0].target.id == job.target.id) { q.push(job); } else { queues.push(vec![job]); }
            }
            let lanes = me.settings.parallel_messages();
            let semaphore = Arc::new(tokio::sync::Semaphore::new(lanes));
            let mut handles = vec![];
            for queue in queues {
                let me = me.clone();
                let sender = sender.clone();
                let ctx = ctx.clone();
                let sem = semaphore.clone();
                let was_stopped = was_stopped.clone();
                handles.push(tokio::spawn(async move {
                    let _permit = sem.acquire_owned().await;
                    let mut results = vec![];
                    for job in queue {
                        if was_stopped() { break; }
                        let answer = me.private_turn(job.target.clone(), sender.clone(), job.words.clone(), job.exchange.clone(), ctx.clone()).await;
                        me.with(|s| s.live_exchanges.remove(&job.exchange.id));
                        if was_stopped() { break; }
                        let text = answer.filter(|a| !a.is_empty()).map(|a| me.start_run_if_asked(&a, &job.target, &ctx));
                        results.push((job.index, job.target.name.clone(), text, job.exchange.round_trips >= protocol::MAX_ROUND_TRIPS));
                    }
                    results
                }));
            }
            for h in handles {
                if let Ok(results) = h.await {
                    for (index, name, text, last) in results {
                        match text {
                            Some(t) => {
                                reply_at.insert(index, (name.clone(), t));
                                if last && !last_round.contains(&name) { last_round.push(name); }
                            }
                            None => { note_at.insert(index, format!("{name} didn't answer.")); }
                        }
                    }
                }
            }
            if was_stopped() { return None; }
            let mut keys: Vec<usize> = reply_at.keys().copied().collect();
            keys.sort();
            let replies: Vec<(String, String)> = keys.iter().map(|k| reply_at[k].clone()).collect();
            let mut nkeys: Vec<usize> = note_at.keys().copied().collect();
            nkeys.sort();
            let notes: Vec<String> = nkeys.iter().map(|k| note_at[k].clone()).collect();
            if replies.is_empty() && notes.is_empty() { return None; }
            me.carry_on(sender, room, replies, notes, last_round, ctx, asker, exchange_id).await
        })
    }

    /// The other bot's turn, in the private thread. None when it couldn't answer.
    async fn private_turn(self: &Arc<Self>, target: Bot, sender: Bot, message: String, exchange: Exchange, ctx: DmContext) -> Option<String> {
        let busy = self.is_replying(&target.id);
        self.with(|s| s.live_exchanges.insert(exchange.id.clone(), DmLive { sender: sender.id.clone(), target: target.id.clone(), room: ctx.root_room.clone(), root_room: ctx.root_room.clone(), replying: !busy }));
        let root = ctx.root_room.clone();
        let limit = self.settings.turn_limit_seconds() + 60.0;
        if !self.wait_and_claim(&target.id, &exchange.thread_id, limit, move |s| s.stopped_exchange_rooms.contains(&root)).await {
            return None;
        }
        self.with(|s| if let Some(l) = s.live_exchanges.get_mut(&exchange.id) { l.replying = true; });
        let thread = exchange.thread_id.clone();
        let record = self.conversation(&thread);
        let session = record.sessions.get(&target.id).cloned();
        let earlier_msgs: Vec<&ChatMessage> = record.messages[..record.messages.len().saturating_sub(1)].iter().filter(|m| !m.text.is_empty() && m.author != NOTE_AUTHOR).collect();
        let unseen: Vec<&ChatMessage> = if session.is_some() { vec![] } else { earlier_msgs.into_iter().rev().take(6).collect::<Vec<_>>().into_iter().rev().collect() };
        let earlier: Vec<String> = unseen.iter().map(|m| format!("{}: {}", self.bot(&m.author).map(|b| b.name).unwrap_or(m.author.clone()), m.text.chars().take(1500).collect::<String>())).collect();
        let role = if sender.description.is_empty() { None } else { Some(sender.description.clone()) };
        let words = prompts::private_message_prompt(&sender.name, role.as_deref(), &message, ctx.owner_words.as_deref(), &earlier, &self.owner());
        let prompt = format!("{}({})\n\n{}", self.awareness(&target, &thread), prompts::private_thread_how_to(&sender.name), words);
        let prompt = if session.is_none() { self.first_message(&target, &prompt) } else { prompt };
        let turn = DmTurn { exchange_id: Some(exchange.id.clone()), asker_id: Some(sender.id.clone()), ctx, may_message: true };
        self.reply(target, thread, prompt, session, ReplyOpts { hands_on_when_stopped: true, from_owner: false, privately: Some(turn), quiet_allowed: false }).await
    }

    /// The sender reads the answers and carries on where it was.
    #[allow(clippy::too_many_arguments)]
    fn carry_on(self: &Arc<Self>, sender: Bot, room: String, replies: Vec<(String, String)>, notes: Vec<String>, last_round: Vec<String>, ctx: DmContext, asker: Option<String>, exchange_id: Option<String>) -> Fut<Option<String>> {
        let me = self.clone();
        Box::pin(async move {
            // Nothing got through: it says where things stand, rather than trying again (how a stubborn model loops forever).
            let may_message = !replies.is_empty();
            let stops_before = me.with(|s| s.stop_counts.get(&ctx.root_room).copied().unwrap_or(0));
            let root = ctx.root_room.clone();
            if !me.wait_and_claim(&sender.id, &room, 24.0 * 3600.0, move |s| s.stopped_exchange_rooms.contains(&root) || s.stop_counts.get(&root).copied().unwrap_or(0) != stops_before).await {
                return None;
            }
            let session = me.conversation(&room).sessions.get(&sender.id).cloned();
            let reader = asker.as_deref().and_then(|a| me.bot(a)).map(|b| b.name).unwrap_or_else(|| me.owner());
            let words = prompts::replies_prompt(&replies, &notes, &last_round, &reader, may_message);
            let prompt = if session.is_none() { me.first_message(&sender, &words) } else { words };
            let turn = DmTurn { exchange_id, asker_id: asker, ctx: ctx.clone(), may_message };
            me.reply(sender, room, prompt, session, ReplyOpts { hands_on_when_stopped: true, from_owner: ctx.from_owner, privately: Some(turn), quiet_allowed: false }).await
        })
    }

    // MARK: Group chats

    pub fn send_to_group(self: &Arc<Self>, text: &str, group_id: &str) { self.send_to_group_with_id(text, group_id, None, None) }

    pub fn send_to_group_with_id(self: &Arc<Self>, text: &str, group_id: &str, message_id: Option<String>, written_at: Option<DateTime<Utc>>) {
        let Some(group) = self.group(group_id) else { return };
        let Some(head) = group.head_id.clone() else { return };
        let room = group.room_id();
        let mut message = ChatMessage::new(OWNER_AUTHOR, text);
        if let Some(id) = message_id { message.id = id; }
        if let Some(at) = written_at { message.at = at; }
        let exists = self.with(|s| s.conversations.get(&room).map(|c| c.messages.iter().any(|m| m.id == message.id)).unwrap_or(false));
        if !exists {
            self.post(message, &room);
        }
        self.owner_spoke(&room);
        let members: Vec<(String, String)> = group.all_ids().iter().filter_map(|id| self.bot(id)).map(|b| (b.id, b.name)).collect();
        let tagged = protocol::mentions_ordered(text, &members);
        let first = if tagged.is_empty() { vec![head] } else { tagged };
        self.start_round(&group, first, None);
    }

    fn start_round(self: &Arc<Self>, group: &Group, first: Vec<String>, note: Option<String>) {
        let room = group.room_id();
        let Some(head) = group.head_id.clone() else { return };
        let started = self.with(|s| {
            if let Some(r) = s.rounds.get_mut(&room) {
                // The owner spoke again: nobody else speaks in this round, and the head reads the new message first.
                r.plan.finish();
                r.next_first = Some(first.clone());
                r.next_note = note.clone();
                return None;
            }
            s.stopped_exchange_rooms.remove(&room);
            s.next_round += 1;
            let id = s.next_round;
            let mut plan = protocol::GroupTurnPlan::new(&head, &first);
            let step = plan.start();
            s.rounds.insert(room.clone(), Round { id, group_id: group.id.clone(), plan, opening_note: note, next_first: None, next_note: None });
            Some((id, step))
        });
        if let Some((id, step)) = started {
            let me = self.clone();
            tokio::spawn(async move { me.run_round(room, id, step).await });
        }
    }

    async fn run_round(self: Arc<Self>, room: String, round_id: u64, mut step: Step) {
        loop {
            let current = self.with(|s| s.rounds.get(&room).filter(|r| r.id == round_id).map(|r| (r.group_id.clone(), r.plan.finished)));
            let Some((group_id, finished)) = current else { return };
            let Some(group) = self.group(&group_id) else {
                self.with(|s| s.rounds.remove(&room));
                return;
            };
            let (bot_id, wrap_up) = match (&step, finished) {
                (Step::Speak { bot, wrap_up }, false) => (bot.clone(), *wrap_up),
                _ => {
                    let next = self.with(|s| s.rounds.remove(&room).and_then(|r| r.next_first.map(|f| (f, r.next_note))));
                    if let Some((first, note)) = next {
                        self.start_round(&group, first, note);
                    } else {
                        self.finish_quiet_group_routine(&room, None);
                    }
                    return;
                }
            };
            let others: Vec<String> = group.member_ids.iter().filter(|m| Some(*m) != group.head_id.as_ref()).filter(|m| self.bot(m).map(|b| b.is_on()).unwrap_or(false)).cloned().collect();
            let Some(speaker) = self.bot(&bot_id).filter(|b| b.is_on()) else {
                let name = self.bot(&bot_id).map(|b| b.name).unwrap_or_else(|| "That bot".into());
                self.post(ChatMessage::note(format!("{name} is turned off, so it didn't answer.")), &room);
                step = self.with(|s| s.rounds.get_mut(&room).map(|r| r.plan.turn_ended(&bot_id, &[], false, &others))).unwrap_or(Step::Finished);
                continue;
            };
            let is_head = group.head_id.as_deref() == Some(&bot_id);
            let wait = if is_head { self.settings.turn_limit_seconds() + 60.0 } else { MEMBER_WAIT_SECS };
            let r2 = room.clone();
            let claimed = self.wait_and_claim(&bot_id, &room, wait, move |s| s.rounds.get(&r2).map(|r| r.id != round_id || r.plan.finished).unwrap_or(true)).await;
            let superseded = self.with(|s| s.rounds.get(&room).map(|r| r.id != round_id || r.plan.finished).unwrap_or(true));
            if superseded {
                if claimed { self.release(&bot_id); }
                step = Step::Finished;
                continue;
            }
            if !claimed {
                self.post(ChatMessage::note(prompts::busy_member_line(&speaker.name)), &room);
                step = self.with(|s| s.rounds.get_mut(&room).map(|r| r.plan.turn_ended(&bot_id, &[], false, &others))).unwrap_or(Step::Finished);
                continue;
            }
            let answer = self.group_turn(&speaker, &group, wrap_up, is_head).await;
            let team: Vec<(String, String)> = group.all_ids().iter().filter_map(|id| self.bot(id)).map(|b| (b.id, b.name)).collect();
            let mentions = match &answer {
                Some(a) if is_head => protocol::mentions_named(a, &team),
                Some(a) => protocol::mentions_ordered(a, &team),
                None => vec![],
            };
            step = self.with(|s| s.rounds.get_mut(&room).filter(|r| r.id == round_id).map(|r| r.plan.turn_ended(&bot_id, &mentions, !wrap_up, &others))).unwrap_or(Step::Finished);
            if matches!(step, Step::Speak { .. }) {
                tokio::time::sleep(Duration::from_millis(300)).await;
            }
        }
    }

    async fn group_turn(self: &Arc<Self>, speaker: &Bot, group: &Group, wrap_up: bool, is_head: bool) -> Option<String> {
        let room = group.room_id();
        let owner = self.owner();
        let head_name = group.head_id.as_deref().and_then(|h| self.bot(h)).map(|b| b.name).unwrap_or_else(|| "the head".into());
        let record = self.conversation(&room);
        let session = record.sessions.get(&speaker.id).cloned();
        let mut turn_note = if wrap_up { prompts::wrap_up_note(&owner) } else if is_head { prompts::head_opens_note(&owner) } else { prompts::member_turn_note(&speaker.name, &head_name) };
        if let Some(extra) = self.with(|s| s.rounds.get_mut(&room).and_then(|r| r.opening_note.take())) {
            turn_note.push(' ');
            turn_note.push_str(&extra);
        }
        let quiet_run = is_head && !wrap_up && self.with(|s| s.quiet_group_routines.contains_key(&room));
        if quiet_run {
            turn_note.push(' ');
            turn_note.push_str(&protocol::quiet_how_to(&owner));
        }
        // What it hasn't read yet: everything since it last spoke, trimmed to what fits.
        let own: HashSet<String> = if session.is_none() { HashSet::new() } else { record.own_answers.get(&speaker.id).cloned().unwrap_or_default().into_iter().collect() };
        let seen = record.seen.get(&speaker.id).copied().unwrap_or(0).min(record.messages.len());
        let spoken: Vec<&ChatMessage> = record.messages[seen..].iter().filter(|m| !m.text.is_empty() && m.author != NOTE_AUTHOR && !own.contains(&m.id)).collect();
        let last_owner = spoken.iter().rposition(|m| m.author == OWNER_AUTHOR).unwrap_or(0);
        let mut kept: Vec<&ChatMessage> = spoken[last_owner..].to_vec();
        let mut used: usize = kept.iter().map(|m| m.text.len()).sum();
        for m in spoken[..last_owner].iter().rev() {
            used += m.text.len();
            if used > 24_000 { break; }
            kept.insert(0, m);
        }
        let team: Vec<Bot> = group.all_ids().iter().filter_map(|id| self.bot(id)).collect();
        let transcript: Vec<(String, String)> = kept.iter().map(|m| {
            let who = if m.author == OWNER_AUTHOR { owner.clone() } else { team.iter().find(|b| b.id == m.author).map(|b| b.name.clone()).unwrap_or(m.author.clone()) };
            (who, m.text.clone())
        }).collect();
        let mut intro = vec![];
        if session.is_none() {
            intro.push(format!("You are {} in {}'s \"{}\" group chat. {}", speaker.name, owner, group.name, if speaker.provider == "claude" { speaker.instructions.clone() } else { self.persona(speaker) }));
            if is_head && !speaker.primary {
                intro.push(format!("You lead this group. When {owner} asks to build something, end your final answer with a line \"Project: <short name>\" and the prompt for the coding agent in a ```prompt fenced block."));
            }
        }
        let others: Vec<(String, String)> = team.iter().filter(|b| b.id != speaker.id).map(|b| (b.name.clone(), b.description.clone())).collect();
        let mut prompt = prompts::group_turn_prompt(&speaker.name, &group.name, &others, &intro, &transcript, &turn_note);
        if !speaker.primary {
            prompt = format!("({})\n\n{}", self.reach_note(speaker), prompt);
        }
        prompt = self.awareness(speaker, &room) + &prompt;
        self.with(|s| {
            let c = s.conversations.entry(room.clone()).or_default();
            c.seen.insert(speaker.id.clone(), c.messages.len());
            c.own_answers.remove(&speaker.id);
        });
        let answer = self.reply(speaker.clone(), room.clone(), prompt, session, ReplyOpts { hands_on_when_stopped: true, from_owner: true, privately: None, quiet_allowed: quiet_run }).await;
        if quiet_run {
            self.finish_quiet_group_routine(&room, Some(answer.clone()));
        }
        answer
    }

    fn finish_quiet_group_routine(&self, room: &str, answer: Option<Option<String>>) {
        let Some((routine_id, run, message_id)) = self.with(|s| s.quiet_group_routines.remove(room)) else { return };
        let mut finished = run;
        finished.finished_at = Some(Utc::now());
        match answer {
            Some(a) if protocol::is_quiet(a.as_deref()) => {
                finished.status = "quiet".into();
                finished.summary = Some("Nothing to report.".into());
                let s = &mut *self.state.lock().unwrap();
                if let Some(c) = s.conversations.get_mut(room) {
                    c.messages.retain(|m| m.id != message_id);
                }
                self_write(self, s, room);
            }
            Some(a) => {
                finished.status = if a.is_some() { "done".into() } else { "failed".into() };
                finished.summary = Some(a.map(|t| t.chars().take(140).collect()).unwrap_or_else(|| "The head didn't answer.".into()));
            }
            None => {
                finished.status = "failed".into();
                finished.summary = Some("The group didn't answer.".into());
            }
        }
        self.record_run(&routine_id, finished);
    }

    // MARK: Routines

    pub fn save_routine(&self, mut routine: Routine) {
        self.with(|s| {
            let same = s.routines.iter().any(|r| r.id == routine.id && r.schedule == routine.schedule);
            if routine.next_run_at.is_none() || !same {
                routine.next_run_at = Some(schedule::next_after(&routine.schedule, Utc::now()));
            }
            if let Some(i) = s.routines.iter().position(|r| r.id == routine.id) { s.routines[i] = routine; } else { s.routines.push(routine); }
        });
        self.write_routines();
    }

    fn add_routine_from_chat(&self, request: &protocol::RoutineRequest, target: &str) {
        let exists = self.with(|s| s.routines.iter().any(|r| r.target == target && r.instruction == request.instruction && r.schedule == request.schedule));
        if !exists {
            self.save_routine(Routine::new(&request.name, target, &request.instruction, request.schedule.clone()));
        }
    }

    pub fn set_paused(&self, paused: bool, id: &str) {
        self.with(|s| {
            if let Some(r) = s.routines.iter_mut().find(|r| r.id == id) {
                r.paused = paused;
                if !paused {
                    r.next_run_at = Some(schedule::next_after(&r.schedule, Utc::now()));
                }
            }
        });
        self.write_routines();
    }

    pub fn delete_routine(&self, id: &str) {
        self.with(|s| s.routines.retain(|r| r.id != id));
        self.write_routines();
    }

    pub fn run_routine_now(self: &Arc<Self>, id: &str) {
        if let Some(r) = self.with(|s| s.routines.iter().find(|r| r.id == id).cloned()) {
            self.start_routine(r, false);
        }
    }

    fn longest_routine_run(&self) -> f64 { self.settings.turn_limit_seconds() * 2.0 + 120.0 }

    pub fn settle_stale_routine_runs(&self) {
        let now = Utc::now();
        let longest = self.longest_routine_run();
        let changed = self.with(|s| {
            let mut changed = false;
            let running = s.running_routines.clone();
            for r in s.routines.iter_mut() {
                if running.contains(&r.id) { continue; }
                for run in r.runs.iter_mut().filter(|x| x.status == "running") {
                    if (now - run.started_at).num_seconds() as f64 > longest {
                        run.status = "failed".into();
                        run.finished_at = Some(now);
                        run.summary = Some("Theo stopped before this run finished, so it didn't get done. It runs again at its next time; Run now runs it sooner.".into());
                        changed = true;
                    }
                }
            }
            changed
        });
        if changed { self.write_routines(); }
    }

    pub fn run_due_routines(self: &Arc<Self>) {
        self.settle_stale_routine_runs();
        if self.settings.is_test && !self.settings.bool("test.routines.run") {
            return;
        }
        let now = Utc::now();
        let due: Vec<(Routine, DateTime<Utc>)> = self.with(|s| {
            let mut out = vec![];
            for r in s.routines.iter_mut() {
                if r.paused { continue; }
                let Some(next) = r.next_run_at else { continue };
                if next > now { continue; }
                r.next_run_at = Some(schedule::next_after(&r.schedule, now));
                out.push((r.clone(), next));
            }
            out
        });
        if due.is_empty() { return; }
        self.write_routines();
        for (routine, at) in due {
            if protocol::catch_up(at, now, schedule::period_seconds(&routine.schedule)) == protocol::CatchUp::Missed {
                let late = lateness((now - at).num_seconds());
                let when = at.with_timezone(&chrono::Local).format("%-d %b %H:%M");
                self.record_run(&routine.id, RoutineRun::finished("missed", format!("Missed the {when} run: Theo wasn't running then, and {late} late is too late to catch up.")));
                continue;
            }
            self.start_routine(routine, true);
        }
    }

    pub fn start_routine(self: &Arc<Self>, routine: Routine, scheduled: bool) {
        if self.with(|s| s.running_routines.contains(&routine.id)) { return; }
        let text = format!("{} \"{}\": {}", protocol::ROUTINE_RUN_PREFIX, routine.name, routine.instruction);
        if let Some(group_id) = routine.target.strip_prefix("group:") {
            let Some(group) = self.group(group_id) else { return self.record_run(&routine.id, RoutineRun::finished("failed", "The group is gone.")) };
            let message_id = uuid::Uuid::new_v4().to_string().to_uppercase();
            let run = RoutineRun::running();
            self.with(|s| s.quiet_group_routines.insert(group.room_id(), (routine.id.clone(), run.clone(), message_id.clone())));
            self.record_run(&routine.id, run);
            let mut m = ChatMessage::new(OWNER_AUTHOR, text);
            m.id = message_id;
            self.post(m, &group.room_id());
            self.owner_spoke(&group.room_id());
            let head = group.head_id.clone().unwrap_or_default();
            self.start_round(&group, vec![head], None);
            return;
        }
        let Some(bot) = self.bot(&routine.target) else { return self.record_run(&routine.id, RoutineRun::finished("failed", "The bot is gone.")) };
        if !bot.is_on() {
            return self.record_run(&routine.id, RoutineRun::finished("skipped", format!("{} is turned off.", bot.name)));
        }
        if !self.claim(&bot.id, &bot.id) {
            // Busy right now: a scheduled run waits a minute instead of being lost.
            if scheduled {
                self.with(|s| if let Some(r) = s.routines.iter_mut().find(|r| r.id == routine.id) { r.next_run_at = Some(Utc::now() + chrono::Duration::seconds(60)); });
                self.write_routines();
            } else {
                // Run now while it's busy: it runs as soon as the bot is free.
                let me = self.clone();
                tokio::spawn(async move {
                    while me.is_replying(&bot.id) { tokio::time::sleep(Duration::from_millis(300)).await; }
                    me.start_routine(routine, false);
                });
            }
            return;
        }
        self.with(|s| s.running_routines.insert(routine.id.clone()));
        let run = RoutineRun::running();
        self.record_run(&routine.id, run.clone());
        let message = ChatMessage::new(ROUTINE_AUTHOR, text.clone());
        let routine_message_id = message.id.clone();
        self.post(message, &bot.id);
        let record = self.conversation(&bot.id);
        let session = record.sessions.get(&bot.id).cloned();
        let owner = self.owner();
        let mut prompt = self.awareness(&bot, &bot.id) + &(if session.is_none() { self.first_message(&bot, &text) } else { text });
        prompt.push_str(&format!("\n\n(This is a scheduled run of a routine {owner} set up; do the job now and report briefly. {})", protocol::quiet_how_to(&owner)));
        if !bot.primary {
            prompt.push_str(&format!("\n\n({})", self.reach_note(&bot)));
        }
        self.owner_spoke(&bot.id);
        let me = self.clone();
        tokio::spawn(async move {
            let answer = me.reply(bot.clone(), bot.id.clone(), prompt, session, ReplyOpts { hands_on_when_stopped: true, from_owner: false, privately: None, quiet_allowed: true }).await;
            me.with(|s| s.running_routines.remove(&routine.id));
            let mut finished = run;
            finished.finished_at = Some(Utc::now());
            if protocol::is_quiet(answer.as_deref()) {
                finished.status = "quiet".into();
                finished.summary = Some("Nothing to report.".into());
                let s = &mut *me.state.lock().unwrap();
                if let Some(c) = s.conversations.get_mut(&bot.id) {
                    c.messages.retain(|m| m.id != routine_message_id);
                }
                self_write(&me, s, &bot.id);
            } else {
                finished.status = if answer.is_some() { "done".into() } else { "failed".into() };
                finished.summary = answer.map(|a| a.chars().take(140).collect());
            }
            me.record_run(&routine.id, finished);
        });
    }

    fn record_run(&self, routine_id: &str, run: RoutineRun) {
        let info = self.with(|s| {
            let r = s.routines.iter_mut().find(|r| r.id == routine_id)?;
            if let Some(i) = r.runs.iter().position(|x| x.id == run.id) { r.runs[i] = run.clone(); } else {
                r.runs.push(run.clone());
                if r.runs.len() > 20 { let extra = r.runs.len() - 20; r.runs.drain(..extra); }
            }
            Some((r.id.clone(), r.name.clone(), r.target.clone()))
        });
        self.write_routines();
        if let (Some((id, name, target)), true) = (info, run.finished_at.is_some()) {
            self.fire_hook("routine-finished", json!({"routine": id, "name": name, "target": target, "status": run.status, "summary": run.summary.unwrap_or_default()}));
        }
    }

    // MARK: Recovery after a crash or restart

    /// The owner's messages at the end of a chat with nothing after them, and how many times they've been asked again.
    pub fn interrupted(messages: &[ChatMessage], heard: &HashMap<String, String>) -> (Vec<ChatMessage>, usize) {
        let heard_ids: HashSet<&String> = heard.values().collect();
        let mut trailing = vec![];
        let mut retries = 0;
        for m in messages.iter().rev() {
            if m.author == NOTE_AUTHOR && m.text.starts_with(RESUME_PREFIX) {
                if !m.text.ends_with(RESUME_RETRY_SUFFIX) { break; }
                if trailing.is_empty() { retries += 1; }
                continue;
            }
            if m.author != OWNER_AUTHOR || heard_ids.contains(&m.id) { break; }
            trailing.insert(0, m.clone());
        }
        (trailing, retries)
    }

    pub fn resume_interrupted_turns(self: &Arc<Self>) {
        let now = Utc::now();
        for bot in self.bots() {
            if !bot.is_on() || self.is_replying(&bot.id) { continue; }
            let record = self.conversation(&bot.id);
            let (waiting, retries) = Self::interrupted(&record.messages, &record.heard);
            if waiting.is_empty() { continue; }
            let recent: Vec<ChatMessage> = waiting.into_iter().filter(|m| (now - m.at).num_seconds() < RESUME_WINDOW_SECS).collect();
            if recent.is_empty() || retries >= RESUME_RETRIES {
                let why = if recent.is_empty() { String::new() } else { format!(" (it was cut off {} times, so it isn't asking again by itself)", retries + 1) };
                self.post(ChatMessage::note(format!("{RESUME_PREFIX}{} answered this{why}. Send it again if you still need it.", bot.name)), &bot.id);
                continue;
            }
            let what = if recent.len() == 1 { "your last message".to_string() } else { format!("your last {} messages", recent.len()) };
            self.post(ChatMessage::note(format!("{RESUME_PREFIX}{} answered {what}, {RESUME_RETRY_SUFFIX}", bot.name)), &bot.id);
            for m in recent {
                self.send_with_id(&m.text, &bot.id, Some(m.id.clone()), Some(m.at));
            }
        }
        for group in self.with(|s| s.groups.clone()) {
            if group.head_id.is_none() { continue; }
            let room = group.room_id();
            let record = self.conversation(&room);
            let (waiting, retries) = Self::interrupted(&record.messages, &record.heard);
            let Some(last) = waiting.last().cloned() else { continue };
            if (now - last.at).num_seconds() >= RESUME_WINDOW_SECS || retries >= RESUME_RETRIES {
                self.post(ChatMessage::note(format!("{RESUME_PREFIX}{} answered this. Send it again if you still need it.", group.name)), &room);
                continue;
            }
            self.post(ChatMessage::note(format!("{RESUME_PREFIX}{} answered your last message, {RESUME_RETRY_SUFFIX}", group.name)), &room);
            self.send_to_group_with_id(&last.text, &group.id, Some(last.id.clone()), Some(last.at));
        }
    }

    // MARK: Coding runs

    fn submit_if_final(self: &Arc<Self>, answer: &str, room: &str, bot: &Bot) {
        let Some(pitch) = self.with(|s| s.conversations.get(room).and_then(|c| c.messages.iter().rev().find(|m| m.author == OWNER_AUTHOR).cloned())) else { return };
        if protocol::is_routine_run(&pitch.text) || self.with(|s| s.submitted_pitches.contains(&pitch.id)) { return; }
        let Some(prompt) = protocol::fenced_block(answer, "prompt") else {
            if let Some(follow) = protocol::fenced_block(answer, "followup") {
                if let Some(run) = self.with(|s| s.runs.iter().rev().find(|r| r.room == room).cloned()) {
                    self.with(|s| s.submitted_pitches.insert(pitch.id.clone()));
                    crate::coding::follow_up(self, &run.id, &follow);
                }
            }
            return;
        };
        // The agent has full access: only the owner's own words asking to build start one.
        if !protocol::owner_asked_to_build(&pitch.text) {
            // Nothing starts by itself; the owner can start it from the card.
            self.with(|s| s.submitted_pitches.insert(pitch.id.clone()));
            let title = protocol::labeled("Project", answer).unwrap_or_else(|| prompt.split_whitespace().take(6).collect::<Vec<_>>().join(" "));
            self.post_ask(bot, room, &format!("{} wrote a coding prompt, but you didn't ask to build or change code, so nothing started. Start \"{title}\"?", bot.name),
                json!({"kind": "run", "bot": bot.id, "prompt": prompt, "answer": answer, "words": pitch.text, "pitch": pitch.id, "title": title}));
            return;
        }
        self.with(|s| s.submitted_pitches.insert(pitch.id.clone()));
        crate::coding::start_from_answer(self, &prompt, answer, &pitch.text, room, &pitch.id);
    }

    /// A coder's final prompt in a private answer, for work the owner just asked for, starts the run in the owner's chat.
    fn start_run_if_asked(self: &Arc<Self>, answer: &str, target: &Bot, ctx: &DmContext) -> String {
        let Some(owner_words) = ctx.owner_words.as_deref() else { return answer.to_string() };
        let Some(prompt) = protocol::fenced_block(answer, "prompt") else { return answer.to_string() };
        let Some(pitch) = self.with(|s| s.conversations.get(&ctx.root_room).and_then(|c| c.messages.iter().rev().find(|m| m.author == OWNER_AUTHOR).cloned())) else { return answer.to_string() };
        if self.with(|s| s.submitted_pitches.contains(&pitch.id)) || !protocol::owner_asked_to_build(owner_words) { return answer.to_string(); }
        self.with(|s| s.submitted_pitches.insert(pitch.id.clone()));
        let title = crate::coding::start_from_answer(self, &prompt, answer, owner_words, &ctx.root_room, &pitch.id);
        let words = answer.split("```prompt").next().unwrap_or("").trim().to_string();
        format!("{}({}'s prompt has started the run \"{}\", so don't start it again. It shows on its card in this chat.)", if words.is_empty() { String::new() } else { words + "\n\n" }, target.name, title)
    }

    // MARK: Faces, cards and failures

    pub fn set_failure(&self, bot_id: &str, failure: Option<LastFailure>) {
        let changed = self.with(|s| match s.bots.iter_mut().find(|b| b.id == bot_id) {
            Some(b) if b.last_failure != failure => {
                b.last_failure = failure;
                true
            }
            _ => false,
        });
        if changed {
            self.write_bots();
        }
    }

    /// A card that waits for the owner. Its question is the text; what to do on yes is in the card.
    fn post_ask(&self, bot: &Bot, room: &str, question: &str, payload: Value) {
        let mut m = ChatMessage::note(question);
        let mut payload = payload;
        payload["bot"] = bot.id.clone().into();
        m.card = Some(format!("ask:{}", payload));
        self.post(m, room);
    }

    fn ask_routine(&self, bot: &Bot, request: &protocol::RoutineRequest, target: &str, room: &str) {
        let label = schedule::label(&request.schedule);
        self.post_ask(bot, room, &format!("{} wrote a routine (\"{}\", {}), but you didn't ask for one, so Theo didn't set it up. Set it up?", bot.name, request.name, label),
            json!({"kind": "routine", "name": request.name, "when": request.when, "do": request.instruction, "target": target}));
    }

    /// The owner answered a card: "yes" does what it asked, anything else declines. The card folds to one line.
    pub fn answer_card(self: &Arc<Self>, room: &str, message_id: &str, choice: &str) -> Result<String, String> {
        let card = self.with(|s| s.conversations.get(room).and_then(|c| c.messages.iter().find(|m| m.id == message_id)).and_then(|m| m.card.clone()));
        let Some(card) = card else { return Err("No such card.".into()) };
        let Some(raw) = card.strip_prefix("ask:") else { return Err("That card was already answered.".into()) };
        let payload: Value = serde_json::from_str(raw).map_err(|e| e.to_string())?;
        let yes = choice == "yes";
        let mut done = if yes { "Set up" } else { "Declined" }.to_string();
        if yes {
            match payload["kind"].as_str() {
                Some("routine") => {
                    let when = payload["when"].as_str().unwrap_or_default();
                    let schedule = schedule::parse(when).ok_or("Can't read when.")?;
                    let name = payload["name"].as_str().unwrap_or("Routine");
                    let instruction = payload["do"].as_str().unwrap_or_default();
                    let target = payload["target"].as_str().unwrap_or_default();
                    if !self.with(|s| s.routines.iter().any(|r| r.target == target && r.instruction == instruction && r.schedule == schedule)) {
                        self.save_routine(Routine::new(name, target, instruction, schedule));
                    }
                }
                Some("run") => {
                    let title = crate::coding::start_from_answer(self, payload["prompt"].as_str().unwrap_or_default(), payload["answer"].as_str().unwrap_or_default(),
                        payload["words"].as_str().unwrap_or_default(), room, &format!("card-{message_id}"));
                    done = format!("Started \"{title}\"");
                }
                _ => return Err("Unknown card.".into()),
            }
        }
        let folded = format!("answered:{}", json!({"choice": choice, "what": done, "kind": payload["kind"], "bot": payload["bot"], "at": Utc::now().to_rfc3339()}));
        let s = &mut *self.state.lock().unwrap();
        if let Some(m) = s.conversations.get_mut(room).and_then(|c| c.messages.iter_mut().find(|m| m.id == message_id)) {
            m.card = Some(folded);
        }
        self.write_conversation_locked(s, room);
        Ok(done)
    }

    /// The owner opened a chat: what's new there is seen, and a failure shown there is cleared (a sign-in problem stays until
    /// it's fixed).
    pub fn chat_seen(&self, room: &str) {
        self.with(|s| s.seen.insert(room.into(), Utc::now()));
        if self.bot(room).and_then(|b| b.last_failure).map(|f| f.kind == "failed").unwrap_or(false) {
            self.set_failure(room, None);
        }
    }

    /// Retry: the owner's last message to this bot is asked again.
    pub fn retry(self: &Arc<Self>, bot_id: &str) -> bool {
        self.set_failure(bot_id, None);
        let last = self.with(|s| s.conversations.get(bot_id).and_then(|c| c.messages.iter().rev().find(|m| m.author == OWNER_AUTHOR).cloned()));
        match last {
            Some(m) => {
                self.send_with_id(&m.text, bot_id, Some(m.id), Some(m.at));
                true
            }
            None => false,
        }
    }

    /// Each bot's face: its state, the word for it, one line of detail and since when.
    pub fn faces(&self) -> Vec<Value> {
        let now = Utc::now();
        self.with(|s| {
            s.bots.iter().map(|b| {
                let chat = s.conversations.get(&b.id);
                let messages: &[ChatMessage] = chat.map(|c| c.messages.as_slice()).unwrap_or(&[]);
                // A failure line isn't an answer: it's the failure record's to show.
                let last_bot = messages.iter().rev().find(|m| m.author == b.id && !m.text.is_empty() && !m.text.starts_with("Couldn't reply:"));
                let last_owner = messages.iter().rev().find(|m| m.author == OWNER_AUTHOR);
                let seen = s.seen.get(&b.id).copied().or(last_owner.map(|m| m.at));
                let unread = match (last_bot, seen) {
                    (Some(m), Some(seen)) => m.at > seen,
                    (Some(_), None) => true,
                    _ => false,
                };
                let ask = messages.iter().rev().find(|m| m.card.as_deref().map(|c| c.starts_with("ask:")).unwrap_or(false))
                    .or_else(|| s.conversations.iter().filter(|(k, _)| k.starts_with("group-")).flat_map(|(_, c)| c.messages.iter())
                        .find(|m| m.card.as_deref().map(|c| c.starts_with("ask:") && c.contains(&format!("\"bot\":\"{}\"", b.id))).unwrap_or(false)));
                let choose = messages.last().filter(|m| m.author == b.id && m.text.contains("[CHOOSE:"));
                let run_live = s.runs.iter().find(|r| r.room == b.id && r.phase == "running");
                let live = s.replying.get(&b.id);
                let facts = crate::faces::Facts {
                    enabled: b.is_on(),
                    primary: b.primary,
                    failure: b.last_failure.as_ref().map(|f| f.kind.clone()),
                    asks: ask.is_some() || choose.is_some(),
                    replying: live.is_some(),
                    streamed: live.map(|t| !t.trim().is_empty()).unwrap_or(false),
                    queued: s.queues.get(&b.id).map(|q| !q.is_empty()).unwrap_or(false),
                    run_live: run_live.is_some(),
                    unread,
                    answered_ago: last_bot.map(|m| (now - m.at).num_seconds()),
                    active_ago: messages.last().map(|m| (now - m.at).num_seconds()),
                };
                let state = crate::faces::state(&facts);
                let first_sentence = |t: &str| -> String {
                    let t = t.split("```").next().unwrap_or("");
                    let t = t.split_whitespace().collect::<Vec<_>>().join(" ");
                    let t = t.trim();
                    let end = t.find(". ").map(|i| i + 1).unwrap_or(t.len());
                    t[..end].chars().take(140).collect()
                };
                let (detail, since): (String, Option<DateTime<Utc>>) = match state {
                    "needs" if b.last_failure.as_ref().map(|f| f.kind == "signin").unwrap_or(false) => {
                        let f = b.last_failure.as_ref().unwrap();
                        (if f.reason.contains("isn't installed") { "Install Claude Code".into() } else { "Sign in to Claude Code".into() }, Some(f.at))
                    }
                    "needs" => match (ask, choose) {
                        (Some(m), _) => (if m.card.as_deref().unwrap_or("").contains("\"kind\":\"run\"") { "Start a coding run?".into() } else { "Set up a routine?".into() }, Some(m.at)),
                        (_, Some(m)) => ("Wants you to choose".into(), Some(m.at)),
                        _ => (String::new(), None),
                    },
                    "failed" => {
                        let f = b.last_failure.as_ref().unwrap();
                        (first_sentence(&f.reason), Some(f.at))
                    }
                    "working" => (run_live.map(|r| format!("Coding run \"{}\"", r.title)).unwrap_or_else(|| "Writing a reply".into()), s.replying_since.get(&b.id).copied().or(run_live.map(|r| r.started_at))),
                    "thinking" => ("Reading".into(), s.replying_since.get(&b.id).copied()),
                    "done" => (last_bot.map(|m| first_sentence(&m.text)).unwrap_or_default(), last_bot.map(|m| m.at)),
                    "off" => ("Turned off".into(), None),
                    _ => (String::new(), messages.last().map(|m| m.at)),
                };
                json!({"id": b.id, "state": state, "word": crate::faces::word(state), "detail": detail, "since": since.map(|d| d.to_rfc3339()),
                       "unread": unread, "look": b.look.clone().unwrap_or_else(|| Look::for_bot(&b.id))})
            }).collect()
        })
    }

    /// Claude Code's connectors, from `claude mcp list` (it checks each server, so it can take a while).
    pub async fn refresh_connectors(&self) -> Result<(), String> {
        let started_here = self.with(|s| {
            if s.connectors_refreshing {
                false
            } else {
                s.connectors_refreshing = true;
                true
            }
        });
        if !started_here {
            // Another caller's check is running: wait for its result instead of starting every server again.
            let deadline = Instant::now() + Duration::from_secs(95);
            while self.with(|s| s.connectors_refreshing) && Instant::now() < deadline {
                tokio::time::sleep(Duration::from_millis(250)).await;
            }
            return Ok(());
        }
        // Cleared however this ends, even if the caller stops waiting.
        struct ClearWhenDone<'a>(&'a Harness);
        impl Drop for ClearWhenDone<'_> {
            fn drop(&mut self) {
                self.0.with(|s| s.connectors_refreshing = false);
            }
        }
        let _clear = ClearWhenDone(self);
        self.list_connectors_now().await
    }

    async fn list_connectors_now(&self) -> Result<(), String> {
        let program = self.executable("claude").ok_or("Claude Code isn't installed.")?;
        // Its own process tree, like every engine Theo starts: the servers it checks end with it, even after a timeout.
        let (_, stdout, _) = engine::run_briefly(&program, &["mcp", "list"], &crate::paths::home(), Duration::from_secs(90)).await.ok_or_else(|| "Claude Code took too long to list connectors, or couldn't start.".to_string())?;
        let mut list = crate::connectors::parse(&stdout);
        let now = Utc::now();
        let mut seen: HashMap<String, String> = std::fs::read(self.paths.root.join("connectors-seen.json")).ok().and_then(|d| serde_json::from_slice(&d).ok()).unwrap_or_default();
        for c in list.iter_mut() {
            if c.status == "connected" {
                seen.insert(c.name.clone(), now.to_rfc3339());
            }
            c.last_connected = seen.get(&c.name).cloned();
        }
        let _ = write_atomic(&self.paths.root.join("connectors-seen.json"), &serde_json::to_vec(&seen).unwrap_or_default());
        self.with(|s| {
            s.connectors = list;
            s.connectors_checked = Some(now);
        });
        Ok(())
    }

    // MARK: Hooks, usage, doctor

    pub fn fire_hook(&self, event: &'static str, fields: Value) {
        crate::hooks::fire(self.paths.hooks_dir(), self.paths.root.join("tmp"), event, fields);
    }

    pub fn usage_report(&self, days: i64) -> Value {
        let ledger = self.usage.lock().unwrap().clone();
        let now = Utc::now();
        let bots = self.bots();
        let mut out = vec![];
        for (id, _) in ledger.days.iter() {
            let total = ledger.total(id, days, now);
            out.push(json!({"id": id, "name": bots.iter().find(|b| &b.id == id).map(|b| b.name.clone()).unwrap_or(id.clone()), "turns": total.turns, "inputTokens": total.usage.input_tokens, "outputTokens": total.usage.output_tokens, "cacheReadTokens": total.usage.cache_read_tokens, "cacheWriteTokens": total.usage.cache_write_tokens, "totalTokens": total.usage.total_tokens(), "costUSD": total.usage.cost_usd, "turnsWithoutCost": total.turns_without_cost}));
        }
        Value::Array(out)
    }

    pub fn doctor_findings(&self) -> Vec<(String, String, String)> {
        let mut f: Vec<(String, String, String)> = vec![];
        match self.executable("claude") {
            Some(p) => f.push(("ok".into(), "Claude Code".into(), format!("Found at {}.", p.display()))),
            None => f.push(("fail".into(), "Claude Code".into(), "Not found. Install it (https://claude.com/claude-code) and sign in with `claude auth login`.".into())),
        }
        let problems = self.problems.problems.lock().unwrap().clone();
        if problems.is_empty() {
            f.push(("ok".into(), "Saved files".into(), "Bots, chats, groups and routines all read fine.".into()));
        } else {
            for p in problems { f.push(("warn".into(), "Saved files".into(), p)); }
        }
        let probe = self.paths.root.join(".write-check");
        if std::fs::write(&probe, b"ok").is_ok() {
            let _ = std::fs::remove_file(&probe);
            f.push(("ok".into(), "Data folder".into(), format!("{} is writable.", self.paths.root.display())));
        } else {
            f.push(("fail".into(), "Data folder".into(), format!("{} can't be written to.", self.paths.root.display())));
        }
        let (routines, bots) = self.with(|s| (s.routines.clone(), s.bots.clone()));
        for r in &routines {
            if r.paused { continue; }
            if let Some(gid) = r.target.strip_prefix("group:") {
                if self.group(gid).is_none() { f.push(("warn".into(), "Routines".into(), format!("\"{}\" is for a group chat that's gone: delete it.", r.name))); }
            } else {
                match bots.iter().find(|b| b.id == r.target) {
                    None => f.push(("warn".into(), "Routines".into(), format!("\"{}\" is for a bot that's gone: delete it.", r.name))),
                    Some(b) if !b.is_on() => f.push(("warn".into(), "Routines".into(), format!("\"{}\" runs {}, which is turned off, so every run is skipped. Turn {} on or pause the routine.", r.name, b.name, b.name))),
                    _ => {}
                }
            }
        }
        if !f.iter().any(|x| x.1 == "Routines") {
            f.push(("ok".into(), "Routines".into(), format!("{} routine(s), each with a bot that's on.", routines.len())));
        }
        // Skills a bot can't find: a SKILL.md without a description isn't listed.
        let mut hidden = vec![];
        let mut dirs = vec![self.paths.shared_skills_dir()];
        dirs.extend(bots.iter().map(|b| self.paths.skills_dir(&b.id)));
        for dir in dirs {
            if let Ok(entries) = std::fs::read_dir(&dir) {
                for e in entries.flatten() {
                    let file = e.path().join("SKILL.md");
                    if let Ok(text) = std::fs::read_to_string(&file) {
                        if prompts::parse_skill(&text, "", None, "").is_none() { hidden.push(file.display().to_string()); }
                    }
                }
            }
        }
        if hidden.is_empty() {
            f.push(("ok".into(), "Skills".into(), "Every skill has a description, so every bot can see it.".into()));
        } else {
            for h in hidden { f.push(("warn".into(), "Skills".into(), format!("{h} has no description in its front matter, so no bot sees it in its list."))); }
        }
        let mut bad_hooks = vec![];
        for event in crate::hooks::EVENTS {
            for (path, ok) in crate::hooks::files(&self.paths.hooks_dir(), event) {
                if let Err(why) = ok { bad_hooks.push(format!("{} won't run: {why}", path.display())); }
            }
        }
        if bad_hooks.is_empty() {
            f.push(("ok".into(), "Hooks".into(), "Every hook file can run.".into()));
        } else {
            for h in bad_hooks { f.push(("warn".into(), "Hooks".into(), h)); }
        }
        let g = self.gateway.report(self);
        f.push(("ok".into(), "Local API".into(), if g["listening"].is_null() { "Off.".into() } else { format!("On, at 127.0.0.1:{}.", g["listening"]) }));
        f
    }

    // MARK: The local API

    pub fn gateway_bots(&self) -> Vec<Bot> { self.with(|s| s.bots.iter().filter(|b| b.is_on()).cloned().collect()) }

    /// A message from a program on this computer: shown as from that program, answered on a turn that isn't the owner's.
    pub fn receive_from_gateway(self: &Arc<Self>, text: &str, source: &str, bot_id: &str) -> Option<String> {
        let bot = self.bot(bot_id).filter(|b| b.is_on())?;
        let message = ChatMessage::new(ROUTINE_AUTHOR, format!("\u{1F4E8} From {source}, through Theo's local API: {text}"));
        let id = message.id.clone();
        self.post(message, bot_id);
        self.fire_hook("gateway-message", json!({"bot": bot_id, "source": source, "text": text}));
        self.with(|s| s.gateway_recent.push((Utc::now(), source.into(), bot_id.into())));
        let me = self.clone();
        let text = text.to_string();
        let source = source.to_string();
        tokio::spawn(async move {
            me.wait_in_line(&bot.id, &bot.id).await;
            let record = me.conversation(&bot.id);
            let session = record.sessions.get(&bot.id).cloned();
            let body = format!("{}\n\n{}", prompts::outside_note(&source, &me.owner()), text);
            let mut prompt = if session.is_none() { me.first_message(&bot, &body) } else { body };
            if !bot.primary { prompt = format!("({})\n\n{}", me.reach_note(&bot), prompt); }
            prompt = me.awareness(&bot, &bot.id) + &prompt;
            me.owner_spoke(&bot.id);
            me.reply(bot.clone(), bot.id.clone(), prompt, session, ReplyOpts { from_owner: false, ..Default::default() }).await;
        });
        Some(id)
    }

    pub async fn gateway_reply(&self, message_id: &str, bot_id: &str, timeout: f64) -> Option<String> {
        let deadline = Instant::now() + Duration::from_secs_f64(timeout);
        tokio::time::sleep(Duration::from_millis(700)).await;
        while Instant::now() < deadline {
            let found = self.with(|s| {
                let busy = s.replying.contains_key(bot_id) || s.live_exchanges.values().any(|e| e.room == bot_id) || s.queues.get(bot_id).map(|q| !q.is_empty()).unwrap_or(false);
                if busy { return None; }
                let messages = &s.conversations.get(bot_id)?.messages;
                let index = messages.iter().position(|m| m.id == message_id)?;
                messages[index + 1..].iter().rev().find(|m| m.author == bot_id && !m.text.is_empty()).map(|m| m.text.clone())
            });
            if found.is_some() { return found; }
            tokio::time::sleep(Duration::from_millis(400)).await;
        }
        None
    }

    // MARK: State for the UI and tests

    pub fn state_report(&self) -> Value {
        let report = self.with(|s| {
            let threads: Vec<&String> = s.conversations.keys().filter(|k| dm::is_thread(k)).collect();
            json!({
                "replying": s.replying.keys().collect::<Vec<_>>(),
                "replyingIn": s.replying_in,
                "live": s.replying,
                "runs": s.runs.iter().map(|r| json!({"id": r.id, "title": r.title, "phase": r.phase, "folder": r.folder, "startedAt": r.started_at.to_rfc3339(), "harness": r.harness, "session": r.session_id, "branch": r.branch, "pullRequest": r.pull_request, "room": r.room, "summary": r.summary})).collect::<Vec<_>>(),
                "exchanges": s.live_exchanges.iter().map(|(id, e)| json!({"id": id, "from": e.sender, "to": e.target, "room": e.room, "replying": e.replying})).collect::<Vec<_>>(),
                "threads": threads,
                "bots": s.bots.iter().map(|b| json!({"id": b.id, "name": b.name, "provider": b.provider, "model": b.model, "enabled": b.is_on(), "primary": b.primary, "description": b.description, "apps": b.apps})).collect::<Vec<_>>(),
                "groups": s.groups.iter().map(|g| json!({"id": g.id, "name": g.name, "head": g.head_id, "members": g.member_ids})).collect::<Vec<_>>(),
                "rounds": s.rounds.keys().collect::<Vec<_>>(),
                "queued": s.queues.iter().filter(|(_, q)| !q.is_empty()).map(|(k, q)| (k.clone(), q.len())).collect::<HashMap<_, _>>(),
            })
        });
        let faces = self.faces();
        let count = |st: &str| faces.iter().filter(|f| f["state"] == st).count();
        let mut report = report;
        report["counts"] = json!({"needs": count("needs"), "failed": count("failed"), "working": count("working") + count("thinking"), "done": count("done")});
        report["faces"] = Value::Array(faces);
        report
    }

    pub fn is_busy(&self) -> bool {
        self.with(|s| !s.replying.is_empty() || !s.live_exchanges.is_empty() || !s.rounds.is_empty() || s.queues.values().any(|q| !q.is_empty()))
    }
}

fn self_write(h: &Harness, s: &State, id: &str) { h.write_conversation_locked(s, id) }

fn protocol_thread_id(stem: &str) -> String { dm::thread_from_file_name(stem).unwrap_or_else(|| stem.to_string()) }

fn lateness(seconds: i64) -> String {
    let minutes = seconds / 60;
    if minutes < 120 { return format!("{minutes} minutes"); }
    let hours = minutes / 60;
    if hours < 48 { format!("{hours} hours") } else { format!("{} days", hours / 24) }
}

pub fn doctor_markdown(findings: &[(String, String, String)]) -> String {
    let rank = |l: &str| match l { "fail" => 0, "warn" => 1, _ => 2 };
    let mut sorted: Vec<&(String, String, String)> = findings.iter().collect();
    sorted.sort_by_key(|f| rank(&f.0));
    let fails = findings.iter().filter(|f| f.0 == "fail").count();
    let warns = findings.iter().filter(|f| f.0 == "warn").count();
    let head = if fails + warns == 0 { format!("Theo's health check: all {} checks pass.", findings.len()) } else {
        format!("Theo's health check: {fails} problem{} and {warns} warning{} out of {} checks.", if fails == 1 { "" } else { "s" }, if warns == 1 { "" } else { "s" }, findings.len())
    };
    let lines: Vec<String> = sorted.iter().map(|f| format!("{} **{}**: {}", match f.0.as_str() { "fail" => "✗", "warn" => "!", _ => "✓" }, f.1, f.2)).collect();
    format!("{head}\n\n{}", lines.join("\n"))
}

/// A bot turn's folder under Turns/, removed when the turn is over.
struct TurnFolder(PathBuf);

impl Drop for TurnFolder {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}
