//! The harness's side of teams and of Theo talking to whole group chats. A child module of `harness`, so it uses the harness's own
//! turn machinery (claiming a bot, `reply`, group rounds) without widening it.
//!
//! Ported from the Swift `BotsStore`: the team parts (`reportToCEO`, `reportThroughManager`, `rollUp`, `takeWaitingReports`,
//! `ceoTurnNote`), `sendToGroup(fromCEO:)`, `finishBrief`, `advanceDiscussion` and `BotPrivateMessages`' group asks.

use super::*;
use crate::teams::{self, Layout};
use tokio::sync::oneshot;

/// How long Theo waits for a group chat it asked. A stuck round can't hold his turn for good.
pub const GROUP_ANSWER_LIMIT_SECS: u64 = 20 * 60;

#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Stage { Plan, Critique, Merge }

/// A group chat talking a build through: the head plans, the others critique, the head merges and writes the final prompt.
pub struct Brief {
    pub stage: Stage,
    /// What the owner said that it's about, newest first.
    pub owner_words: Option<String>,
    /// Theo asked: the outcome goes back to him. None: the owner asked in the group chat itself.
    pub reports_to: Option<oneshot::Sender<String>>,
}

#[derive(Default)]
pub struct TeamState {
    pub layout: Layout,
    /// Group chats in a build discussion, by room.
    pub briefs: HashMap<String, Brief>,
    /// Theo waiting on a group chat's last word, by room.
    pub waiters: HashMap<String, oneshot::Sender<String>>,
    /// Which message of the owner's each group chat last heard of through Theo, so one message starts its limits over once.
    owner_marks: HashMap<String, String>,
}

impl Harness {
    // MARK: The categories

    fn layout_file(&self) -> PathBuf { self.paths.bots_dir().join("layout.json") }

    /// Loads the categories; every one that wants a manager and has a bot for the job gets one.
    pub(super) fn load_layout(&self) {
        let mut layout: Layout = self.problems.load(&self.layout_file(), "the categories").unwrap_or_default();
        let before = layout.clone();
        let bots = self.bots();
        layout.settle(&bots);
        let changed = layout != before;
        self.with(|s| s.teams.layout = layout);
        if changed { self.write_layout(); }
    }

    pub fn write_layout(&self) {
        let data = self.with(|s| serde_json::to_vec_pretty(&s.teams.layout).unwrap_or_default());
        ok_or_log(write_atomic(&self.layout_file(), &data), "saving categories");
    }

    pub fn layout(&self) -> Layout { self.with(|s| s.teams.layout.clone()) }

    /// Changes the categories with the bots as they are now, then saves.
    pub fn change_layout<R>(&self, change: impl FnOnce(&mut Layout, &[Bot]) -> R) -> R {
        let result = self.with(|s| {
            let bots = s.bots.clone();
            change(&mut s.teams.layout, &bots)
        });
        self.write_layout();
        result
    }

    pub fn delete_section(&self, id: &str) {
        self.change_layout(|layout, _| layout.sections.retain(|s| s.id != id));
        // Its report schedule goes with it.
        let target = teams::report_target(id);
        self.with(|s| s.routines.retain(|r| r.target != target));
        self.write_routines();
    }

    /// The report routine of a category, if it reports on a schedule.
    pub fn report_routine(&self, section_id: &str) -> Option<Routine> {
        let target = teams::report_target(section_id);
        self.with(|s| s.routines.iter().find(|r| r.target == target).cloned())
    }

    /// `choice`: off, daily, weekdays, weekly or every (two hours), as the team page offers.
    pub fn set_report_schedule(&self, section_id: &str, choice: &str) -> Result<(), String> {
        let Some(section) = self.with(|s| s.teams.layout.section(section_id).cloned()) else { return Err("No such category.".into()) };
        let target = teams::report_target(section_id);
        self.with(|s| s.routines.retain(|r| r.target != target));
        match teams::report_schedule(choice) {
            Some(schedule) => self.save_routine(Routine::new(&format!("{} report", section.name), &target, "Report to the CEO", schedule)),
            None if choice == "off" || choice.is_empty() => self.write_routines(),
            None => return Err("The schedule is off, daily, weekdays, weekly or every.".into()),
        }
        Ok(())
    }

    /// The categories for the window and the tests.
    pub fn teams_report(&self) -> Value {
        let (layout, bots, routines) = self.with(|s| (s.teams.layout.clone(), s.bots.clone(), s.routines.clone()));
        Value::Array(layout.sections.iter().map(|section| {
            let schedule = routines.iter().find(|r| r.target == teams::report_target(&section.id)).map(|r| {
                serde_json::to_value(r.schedule.kind).ok().and_then(|v| v.as_str().map(str::to_string)).unwrap_or_default()
            });
            json!({
                "id": section.id, "name": section.name, "members": section.member_ids(&bots), "leader": section.leader_id,
                "hasManager": section.has_manager(), "wantsManager": section.wants_manager, "purpose": section.purpose,
                "collapsed": section.collapsed.unwrap_or(false), "schedule": schedule,
                "reports": section.reports.clone().unwrap_or_default().iter().map(|r| json!({"author": r.author, "text": r.text, "at": r.at.to_rfc3339()})).collect::<Vec<_>>(),
            })
        }).collect())
    }

    pub(super) fn reporting_lines(&self, bot: &Bot) -> Vec<String> {
        self.with(|s| teams::reporting_lines(bot, &s.teams.layout, &s.bots))
    }

    pub(super) fn role_line(&self, bot: &Bot) -> Option<String> { self.with(|s| teams::role_line(bot, &s.teams.layout)) }

    // MARK: A bot or a group chat that's gone

    /// A deleted bot leaves its categories, and its chat, private threads and routines go with it.
    pub(super) fn forget_bot(&self, id: &str) {
        self.change_layout(|layout, bots| layout.forget_bot(id, bots));
        self.with(|s| {
            s.routines.retain(|r| r.target != id);
            for b in s.bots.iter_mut() {
                if let Some(list) = b.can_message.as_mut() { list.retain(|x| x != id); }
            }
        });
        self.write_routines();
        self.write_bots();
        let chats: Vec<String> = self.with(|s| {
            let chats: Vec<String> = s.conversations.keys().filter(|k| k.as_str() == id || dm::partner(id, k).is_some()).cloned().collect();
            for c in &chats { s.conversations.remove(c); }
            chats
        });
        for c in chats { let _ = std::fs::remove_file(self.paths.chat_file(&c)); }
    }

    /// A deleted group chat: whoever's talking stops, and its chat and routines go too. The bots in it stay.
    pub(super) fn forget_group(&self, id: &str) {
        let room = format!("group-{id}");
        let target = format!("group:{id}");
        self.with(|s| {
            s.routines.retain(|r| r.target != target);
            s.conversations.remove(&room);
        });
        self.write_routines();
        let _ = std::fs::remove_file(self.paths.chat_file(&room));
    }

    /// Makes a bot the CEO: it can message anyone and takes the top of the sidebar. The old CEO becomes a lead.
    pub fn make_primary(&self, id: &str) -> Result<(), String> {
        if self.bot(id).is_none() { return Err("No such bot.".into()); }
        self.with(|s| {
            for b in s.bots.iter_mut() {
                if b.id == id {
                    b.primary = true;
                    b.enabled = Some(true);
                    b.authority = Some("ceo".into());
                } else if b.primary {
                    b.primary = false;
                    if b.authority.is_none() || b.authority.as_deref() == Some("ceo") { b.authority = Some("lead".into()); }
                }
            }
        });
        self.write_bots();
        self.change_layout(|layout, bots| layout.settle(bots));
        Ok(())
    }

    // MARK: Reports

    /// What a bot did lately: its last few exchanges and routine runs, for a report.
    fn recent_work(&self, bot: &Bot) -> String {
        let owner = crate::settings::owner_starting_sentence(&self.owner());
        let messages = self.conversation(&bot.id).messages;
        let shown: Vec<&ChatMessage> = messages.iter().filter(|m| !m.text.is_empty()).collect();
        let mut lines: Vec<String> = shown[shown.len().saturating_sub(8)..].iter().map(|m| {
            let who = if m.author == OWNER_AUTHOR { owner.clone() } else if m.author == ROUTINE_AUTHOR { "Routine".into() } else { self.bot(&m.author).map(|b| b.name).unwrap_or_else(|| bot.name.clone()) };
            format!("- {who}: {}", m.text.replace('\n', " ").chars().take(280).collect::<String>())
        }).collect();
        for r in self.with(|s| s.routines.iter().filter(|r| r.target == bot.id).cloned().collect::<Vec<_>>()) {
            for run in r.runs.iter().rev().take(2).rev() {
                lines.push(format!("- Routine \"{}\" {}: {}", r.name, run.status, run.summary.clone().unwrap_or_default()));
            }
        }
        if lines.is_empty() { "- Nothing yet.".into() } else { lines.join("\n") }
    }

    fn record_report(&self, text: &str, by: &Bot, section_id: &str) {
        self.change_layout(|layout, _| if let Some(s) = layout.section_mut(section_id) { s.add_report(&by.id, text) });
    }

    /// One bot's report: it writes for `reader` in `room` and the report is kept on the team page. None when it didn't answer.
    async fn one_report(self: &Arc<Self>, reporter: Bot, room: String, words: String) -> Option<String> {
        let prompt = self.first_message(&reporter, &words);
        let answer = self.reply(reporter, room, prompt, None, ReplyOpts { hands_on_when_stopped: true, from_owner: false, privately: None, quiet_allowed: false }).await;
        answer.filter(|a| !a.trim().is_empty())
    }

    /// Everyone reports. With a manager: each member sends its report to the manager's chat, then the manager rolls them up and
    /// reports to the CEO. Without one: each member reports to the CEO's chat directly. The CEO reads what came in at the start of
    /// its next turn (`take_waiting_reports`).
    pub fn report_to_ceo(self: &Arc<Self>, section_id: &str) -> Result<(), String> {
        let Some(section) = self.with(|s| s.teams.layout.section(section_id).cloned()) else { return Err("That category is gone.".into()) };
        let Some(ceo) = self.primary() else { return Err("There's no CEO to report to.".into()) };
        let bots = self.bots();
        let team: Vec<Bot> = section.member_ids(&bots).iter().filter_map(|id| bots.iter().find(|b| &b.id == id)).filter(|b| b.is_on()).cloned().collect();
        if team.is_empty() { return Err(format!("{} has no bots that are on.", section.name)); }
        let owner = self.owner();
        if let Some(manager) = section.leader_id.as_deref().and_then(|id| self.bot(id)).filter(|m| m.is_on() && m.id != ceo.id) {
            let me = self.clone();
            tokio::spawn(async move { me.report_through_manager(section, manager, ceo, team).await });
            return Ok(());
        }
        for reporter in team.into_iter().filter(|b| b.id != ceo.id) {
            if !self.claim(&reporter.id, &ceo.id) { continue; }
            let role = format!("You're on the {} team (it has no manager, so you report yourself)", section.name);
            let activity = format!("{} ({}):\n{}", reporter.name, reporter.description, self.recent_work(&reporter));
            let words = teams::report_prompt(&role, section.purpose.as_deref(), &ceo.name, &owner, &activity);
            self.post(ChatMessage::new(ROUTINE_AUTHOR, format!("{} {} is reporting to {} for {}.", teams::REPORT_MARK, reporter.name, ceo.name, section.name)), &ceo.id);
            let me = self.clone();
            let room = ceo.id.clone();
            let section_id = section.id.clone();
            tokio::spawn(async move {
                if let Some(answer) = me.one_report(reporter.clone(), room, words).await { me.record_report(&answer, &reporter, &section_id); }
            });
        }
        Ok(())
    }

    async fn report_through_manager(self: Arc<Self>, section: teams::Section, manager: Bot, ceo: Bot, team: Vec<Bot>) {
        let owner = self.owner();
        let reporters: Vec<Bot> = team.iter().filter(|b| b.id != manager.id && b.id != ceo.id && !self.is_replying(&b.id)).cloned().collect();
        if !reporters.is_empty() {
            let names: Vec<String> = reporters.iter().map(|b| b.name.clone()).collect();
            self.post(ChatMessage::new(ROUTINE_AUTHOR, format!("{} {} is reporting: {} to {}.", teams::REPORT_MARK, section.name, names.join(", "), manager.name)), &manager.id);
        }
        let mut handles = vec![];
        for reporter in reporters {
            if !self.claim(&reporter.id, &manager.id) { continue; }
            let role = format!("You're on the {} team and {} is your manager, so your report goes to {}", section.name, manager.name, manager.name);
            let words = teams::report_prompt(&role, section.purpose.as_deref(), &manager.name, &owner, &self.recent_work(&reporter));
            let me = self.clone();
            let room = manager.id.clone();
            handles.push(tokio::spawn(async move { (reporter.name.clone(), me.one_report(reporter, room, words).await) }));
        }
        let mut received: Vec<(String, String)> = vec![];
        for h in handles {
            if let Ok((name, Some(text))) = h.await { received.push((name, text)); }
        }
        // The manager reads what came in and reports to the CEO, once it isn't busy with something else.
        if !self.wait_and_claim(&manager.id, &ceo.id, 180.0, |_| false).await { return; }
        let Some(section) = self.with(|s| s.teams.layout.section(&section.id).cloned()) else { return self.release(&manager.id) };
        let reports = received.iter().map(|(n, t)| format!("{n} reports:\n{t}")).collect::<Vec<_>>().join("\n\n");
        let silent: Vec<String> = team.iter().filter(|b| b.id != manager.id && b.id != ceo.id && !received.iter().any(|(n, _)| n == &b.name)).map(|b| b.name.clone()).collect();
        let activity = format!("{}{}\n\nYour own recent work:\n{}", if reports.is_empty() { "No reports came in.".to_string() } else { reports },
            if silent.is_empty() { String::new() } else { format!("\n\nNo report from: {}.", silent.join(", ")) }, self.recent_work(&manager));
        let role = format!("You manage the {} team. Roll your team's reports up into one for {}, the CEO", section.name, ceo.name);
        let words = teams::report_prompt(&role, section.purpose.as_deref(), &ceo.name, &owner, &activity);
        self.post(ChatMessage::new(ROUTINE_AUTHOR, format!("{} {} is reporting to {} for {}.", teams::REPORT_MARK, manager.name, ceo.name, section.name)), &ceo.id);
        if let Some(answer) = self.one_report(manager.clone(), ceo.id.clone(), words).await {
            self.record_report(&answer, &manager, &section.id);
        }
    }

    /// A team's scheduled report ("report:<category>").
    pub(super) fn run_report_routine(self: &Arc<Self>, routine_id: &str, section_id: &str) {
        let run = match self.report_to_ceo(section_id) {
            Ok(()) => RoutineRun::finished("done", "Report sent to the CEO."),
            Err(why) if self.with(|s| s.teams.layout.section(section_id).is_none()) => { let _ = why; RoutineRun::finished("failed", "The category is gone.") }
            Err(why) => RoutineRun::finished("skipped", why),
        };
        self.record_run(routine_id, run);
    }

    /// Reports that landed in the CEO's chat since it last spoke, for the top of its next turn; other bots get nothing. Marked as
    /// read here, so each is read once. Also the ids taken, so the catch-up doesn't repeat them.
    pub(super) fn take_waiting_reports(&self, bot: &Bot) -> (String, Vec<String>) {
        if !bot.primary { return (String::new(), vec![]); }
        let (lines, ids) = self.with(|s| {
            let Some(record) = s.conversations.get_mut(&bot.id) else { return (vec![], vec![]) };
            let seen = record.seen.get(&bot.id).copied().unwrap_or(0).min(record.messages.len());
            let waiting: Vec<ChatMessage> = record.messages[seen..].iter().filter(|m| {
                !m.text.is_empty() && m.author != OWNER_AUTHOR && m.author != bot.id && m.author != NOTE_AUTHOR && m.author != ROUTINE_AUTHOR && m.card.is_none()
            }).cloned().collect();
            let waiting: Vec<ChatMessage> = waiting[waiting.len().saturating_sub(6)..].to_vec();
            record.seen.insert(bot.id.clone(), record.messages.len());
            let lines: Vec<String> = waiting.iter().map(|m| format!("{}: {}", s.bots.iter().find(|b| b.id == m.author).map(|b| b.name.clone()).unwrap_or(m.author.clone()), m.text)).collect();
            (lines, waiting.iter().map(|m| m.id.clone()).collect())
        });
        (teams::waiting_reports_note(&lines, &self.owner()), ids)
    }

    /// Goes with every message to the CEO: who it can reach as of now, group chats included.
    pub(super) fn ceo_turn_note(&self, bot: &Bot) -> String {
        if !bot.primary { return String::new(); }
        let (groups, bots, conversations) = self.with(|s| {
            let rooms: HashMap<String, Vec<ChatMessage>> = s.groups.iter().map(|g| g.room_id()).chain(s.bots.iter().map(|b| b.id.clone()))
                .filter_map(|id| s.conversations.get(&id).map(|c| (id, c.messages[c.messages.len().saturating_sub(2)..].to_vec()))).collect();
            (s.groups.clone(), s.bots.clone(), rooms)
        });
        let latest = |room: &str| -> String {
            let said: Vec<String> = conversations.get(room).map(|m| m.iter().filter(|x| !x.text.is_empty()).map(|x| x.text.replace('\n', " ").chars().take(140).collect()).collect()).unwrap_or_default();
            if said.is_empty() { String::new() } else { format!(" Latest: {}", said.join(" / ")) }
        };
        let name_of = |id: &str| bots.iter().find(|b| b.id == id).map(|b| b.name.clone());
        let chats: Vec<String> = groups.iter().filter(|g| g.head_id.is_some()).map(|g| {
            let others: Vec<String> = g.member_ids.iter().filter(|m| Some(*m) != g.head_id.as_ref()).filter_map(|m| name_of(m)).collect();
            format!("- {} (group chat, led by {}, with {}).{}", g.name, g.head_id.as_deref().and_then(name_of).unwrap_or_else(|| "nobody".into()), others.join(", "), latest(&g.room_id()))
        }).collect();
        let people: Vec<String> = bots.iter().filter(|b| b.id != bot.id).map(|b| {
            format!("- {}{}{}.{}", b.name, if b.description.is_empty() { String::new() } else { format!(" ({})", b.description) }, if b.is_on() { "" } else { " [off]" }, latest(&b.id))
        }).collect();
        prompts::ceo_turn_note(&chats, &people, &self.owner())
    }

    // MARK: Theo asking a whole group chat

    /// The group chat Theo's [TELL:] means, when it means one: its exact name, else (when no bot has that name) a group whose
    /// name contains it.
    pub(super) fn group_target(&self, name: &str) -> Option<Group> {
        let wanted = protocol::search_name(name);
        if wanted.is_empty() { return None; }
        self.with(|s| {
            let chats: Vec<&Group> = s.groups.iter().filter(|g| g.head_id.is_some()).collect();
            if let Some(exact) = chats.iter().find(|g| protocol::search_name(&g.name) == wanted) { return Some((*exact).clone()); }
            if s.bots.iter().any(|b| protocol::search_name(&b.name) == wanted) { return None; }
            chats.iter().find(|g| protocol::search_name(&g.name).contains(&wanted)).map(|g| (*g).clone())
        })
    }

    /// Theo's [TELL: group: …]: the group talks it through and its last word comes back as the answer. Err: a line saying why not.
    pub(super) async fn tell_group(self: &Arc<Self>, chat: &Group, sender: &Bot, message: &str, room: &str, ctx: &DmContext) -> Result<String, String> {
        if chat.room_id() == room {
            return Err(format!("You're already talking in {}, so there's nothing to ask them separately.", chat.name));
        }
        // A round in a group counts as a message too, or Theo could keep asking the group forever.
        let verdict = self.with(|s| {
            let verdict = s.budgets.get(&ctx.root_room).cloned().unwrap_or_default().verdict(0);
            if verdict == protocol::Verdict::Send { s.budgets.entry(ctx.root_room.clone()).or_default().note_sent(); }
            verdict
        });
        if let Some(line) = protocol::cap_line(verdict, &sender.name, &chat.name) {
            self.post(ChatMessage::note(line.clone()), room);
            return Err(line);
        }
        self.post(ChatMessage::note(format!("{} asked {} in their group chat.", sender.name, chat.name)), room);
        let answer = self.ask_group(chat, message, sender, ctx.owner_words.clone(), &ctx.root_room).await;
        // The group chat has the whole of it, a final prompt included.
        Ok(answer.split("```prompt").next().unwrap_or("").trim().to_string())
    }

    async fn ask_group(self: &Arc<Self>, chat: &Group, words: &str, ceo: &Bot, owner_words: Option<String>, root_room: &str) -> String {
        let (sender, receiver) = oneshot::channel();
        self.send_to_group_from_ceo(words, ceo, chat, owner_words, root_room, sender);
        match tokio::time::timeout(Duration::from_secs(GROUP_ANSWER_LIMIT_SECS), receiver).await {
            Ok(Ok(answer)) => answer,
            _ => format!("{} didn't finish in time, so there's no answer from them yet.", chat.name),
        }
    }

    /// Theo posts to a group chat. The head's final answer goes to `then`.
    fn send_to_group_from_ceo(self: &Arc<Self>, text: &str, ceo: &Bot, group: &Group, owner_words: Option<String>, root_room: &str, then: oneshot::Sender<String>) {
        let Some(head) = group.head_id.clone() else {
            let _ = then.send(format!("{} has nobody to answer.", group.name));
            return;
        };
        let room = group.room_id();
        self.post(ChatMessage::new(&ceo.id, text), &room);
        // A new message of the owner's starts the group's limits over, once. Theo asking again on the same message doesn't.
        let mark = format!("{root_room}#{}", self.with(|s| s.owner_turns.get(root_room).copied().unwrap_or(0)));
        if self.with(|s| s.teams.owner_marks.insert(room.clone(), mark.clone()).as_deref() != Some(mark.as_str())) {
            self.owner_spoke(&room);
        }
        // They're already talking it through: this joins the discussion rather than starting another.
        if self.with(|s| s.teams.briefs.contains_key(&room)) {
            let _ = then.send("That's added to what they're already discussing.".into());
            return;
        }
        let has_others = self.has_other_members(group);
        let note = if protocol::wants_discussion(text) || owner_words.as_deref().map(protocol::wants_discussion).unwrap_or(false) {
            self.with(|s| s.teams.briefs.insert(room.clone(), Brief { stage: Stage::Plan, owner_words, reports_to: Some(then) }));
            Some(prompts::plan_note(has_others, &self.owner()))
        } else {
            if let Some(old) = self.with(|s| s.teams.waiters.insert(room.clone(), then)) {
                let _ = old.send(format!("{} was asked something else before it answered this.", group.name));
            }
            None
        };
        self.start_round(group, vec![head], vec![], note);
    }

    fn has_other_members(&self, group: &Group) -> bool {
        group.member_ids.iter().any(|m| Some(m) != group.head_id.as_ref() && self.bot(m).map(|b| b.is_on()).unwrap_or(false))
    }

    /// The owner wrote to a group chat: a build discussion starts (or takes in the new words and plans again). The note for the
    /// head's first turn, and whether it's a discussion (then the head goes first and nobody named is brought in).
    pub(super) fn owner_discussion_note(&self, group: &Group, text: &str, tagged: bool) -> (bool, Option<String>) {
        let room = group.room_id();
        let has_others = self.has_other_members(group);
        let note = prompts::plan_note(has_others, &self.owner());
        let discussing = self.with(|s| {
            if let Some(brief) = s.teams.briefs.get_mut(&room) {
                // More from the owner in the middle of a discussion: the head takes it in and plans again.
                brief.stage = Stage::Plan;
                brief.owner_words = Some([text.to_string(), brief.owner_words.clone().unwrap_or_default()].join("\n").trim().to_string());
                return true;
            }
            if !tagged && protocol::wants_discussion(text) {
                s.teams.briefs.insert(room.clone(), Brief { stage: Stage::Plan, owner_words: Some(text.to_string()), reports_to: None });
                return true;
            }
            false
        });
        (discussing, if discussing { Some(note) } else { None })
    }

    /// A group chat is talking a build through, or answering Theo, so a prompt written there (or by Theo meanwhile) doesn't start
    /// a run of its own: the discussion's outcome does.
    pub(super) fn is_discussing(&self, room: &str) -> bool {
        self.with(|s| {
            s.teams.briefs.contains_key(room) || s.teams.waiters.contains_key(room)
                || (s.bots.iter().any(|b| b.primary && b.id == room) && !s.teams.briefs.is_empty())
        })
    }

    /// The turn note in a build discussion; None when the group isn't in one.
    pub(super) fn discussion_turn_note(&self, room: &str, is_head: bool, speaker: &Bot, head_name: &str) -> Option<String> {
        let stage = self.with(|s| s.teams.briefs.get(room).map(|b| b.stage))?;
        let owner = self.owner();
        Some(match (stage, is_head) {
            (Stage::Plan, true) => self.with(|s| s.rounds.get_mut(room).and_then(|r| r.opening_note.take())).unwrap_or_else(|| prompts::plan_note(true, &owner)),
            (_, true) => prompts::merge_note(&owner),
            (_, false) => format!("{} {}", prompts::CRITIQUE_NOTE, prompts::member_turn_note(&speaker.name, head_name)),
        })
    }

    /// A turn is over, spoken or skipped: who's next. In a build discussion the steps decide; otherwise anyone can hand something
    /// on with @Name, except the wrap-up, which ends it.
    pub(super) fn next_group_step(self: &Arc<Self>, room: &str, round_id: u64, group: &Group, bot_id: &str, answer: Option<&str>, can_hand_out: bool) -> Step {
        let others: Vec<String> = group.member_ids.iter().filter(|m| Some(*m) != group.head_id.as_ref()).filter(|m| self.bot(m).map(|b| b.is_on()).unwrap_or(false)).cloned().collect();
        if self.with(|s| s.teams.briefs.contains_key(room)) {
            return self.advance_discussion(room, round_id, group, bot_id, answer, &others);
        }
        let team: Vec<(String, String)> = group.all_ids().iter().filter_map(|id| self.bot(id)).map(|b| (b.id, b.name)).collect();
        let is_head = group.head_id.as_deref() == Some(bot_id);
        // The head handing out turns often names members in words ("Backend first, then Frontend"), so its names count with or
        // without the @. A member's only count with it, so mentioning someone in passing hands nothing on.
        let mentions = match answer {
            Some(a) if is_head => protocol::mentions_named(a, &team),
            Some(a) => protocol::mentions_ordered(a, &team),
            None => vec![],
        };
        self.with(|s| s.rounds.get_mut(room).filter(|r| r.id == round_id).map(|r| r.plan.turn_ended(bot_id, &mentions, can_hand_out, &others))).unwrap_or(Step::Finished)
    }

    /// A build discussion: the head plans, the others critique one at a time, the head merges, and the prompt it writes starts the run.
    fn advance_discussion(self: &Arc<Self>, room: &str, round_id: u64, group: &Group, speaker_id: &str, answer: Option<&str>, others: &[String]) -> Step {
        let Some(head) = group.head_id.as_deref().and_then(|h| self.bot(h)) else {
            // The group lost its head in the middle of it.
            self.end_group_waits(room, &format!("{} has no head any more, so nothing has started.", group.name));
            self.post(ChatMessage::note(format!("{} has no head any more, so the discussion stopped and nothing started.", group.name)), room);
            self.with(|s| if let Some(r) = s.rounds.get_mut(room) { r.plan.finish(); });
            return Step::Finished;
        };
        let is_head = speaker_id == head.id;
        // The owner spoke again: the head plans again in the round that's queued. This one only ends.
        let queued = self.with(|s| s.rounds.get(room).filter(|r| r.id == round_id).map(|r| r.next_first.is_some()).unwrap_or(true));
        if queued {
            self.with(|s| if let Some(r) = s.rounds.get_mut(room) { r.plan.finish(); });
            return Step::Finished;
        }
        let stage = self.with(|s| s.teams.briefs.get(room).map(|b| b.stage)).unwrap_or(Stage::Merge);
        if is_head && (answer.is_none() || stage == Stage::Merge || others.is_empty()) {
            if let Some(brief) = self.with(|s| s.teams.briefs.remove(room)) {
                match answer {
                    Some(a) => self.finish_brief(brief, group, &head, a, false),
                    None => self.finish_brief(brief, group, &head, &format!("{} stopped before answering.", head.name), true),
                }
            }
            self.with(|s| if let Some(r) = s.rounds.get_mut(room) { r.plan.finish(); });
            return Step::Finished;
        }
        // The head's plan brings in everyone; a critique brings in nobody. The last one, spoken or skipped, sends it back to the
        // head to merge.
        let mentions: Vec<String> = if is_head { others.to_vec() } else { vec![] };
        self.with(|s| {
            let Some(r) = s.rounds.get_mut(room).filter(|r| r.id == round_id) else { return Step::Finished };
            let step = r.plan.turn_ended(speaker_id, &mentions, is_head, others);
            let wrapping = r.plan.wrapping_up;
            if let Some(b) = s.teams.briefs.get_mut(room) { b.stage = if wrapping { Stage::Merge } else { Stage::Critique }; }
            step
        })
    }

    /// The discussion is over: its outcome goes to whoever asked, and a final prompt the owner asked for starts its run.
    fn finish_brief(self: &Arc<Self>, brief: Brief, group: &Group, head: &Bot, answer: &str, failed: bool) {
        let Some(ceo) = self.primary() else { return };
        let prompt = if failed { None } else { protocol::fenced_block(answer, "prompt") };
        let owner = brief.owner_words.clone().unwrap_or_default();
        let asked_by_ceo = brief.reports_to.is_some();
        // The owner talking to the group reads its outcome right there; Theo asking gets it back, and the run shows in his chat.
        let room = if asked_by_ceo { ceo.id.clone() } else { group.room_id() };
        let mut may_start = prompt.is_some() && !protocol::is_routine_run(&owner) && protocol::owner_asked_to_build(&owner);
        let pitch = self.with(|s| s.conversations.get(&room).and_then(|c| c.messages.iter().rev().find(|m| m.author == OWNER_AUTHOR).map(|m| m.id.clone())));
        if may_start {
            // This message of the owner's has its run now, so a prompt in Theo's words after hearing back doesn't start a second one.
            let pitch_id = pitch.clone().unwrap_or_default();
            may_start = self.with(|s| pitch_id.is_empty() || s.submitted_pitches.insert(pitch_id.clone()));
        }
        if let Some(then) = brief.reports_to { let _ = then.send(answer.to_string()); }
        let (true, Some(prompt)) = (may_start, prompt) else { return };
        let digest = pitch.unwrap_or_else(|| format!("brief-{}", uuid::Uuid::new_v4()));
        let title = crate::coding::start_from_answer(self, &prompt, answer, &owner, &room, &digest);
        if asked_by_ceo {
            self.post(ChatMessage::new(&head.id, format!("Started **{title}**. You can follow it in {}'s chat.", ceo.name)), &group.room_id());
        }
    }

    /// Whoever's waiting on this group chat hears it won't answer: a waiting turn would otherwise wait for good.
    pub(super) fn end_group_waits(&self, room: &str, line: &str) {
        let (waiter, brief) = self.with(|s| (s.teams.waiters.remove(room), s.teams.briefs.remove(room)));
        if let Some(w) = waiter { let _ = w.send(line.to_string()); }
        if let Some(Brief { reports_to: Some(w), .. }) = brief { let _ = w.send(line.to_string()); }
    }

    /// A round ended with nobody queued after it: a discussion that didn't reach its outcome starts nothing, and Theo waiting on
    /// a plain round gets its last word.
    pub(super) fn round_over(self: &Arc<Self>, group: &Group, last_answer: Option<String>) {
        let room = group.room_id();
        if let Some(brief) = self.with(|s| s.teams.briefs.remove(&room)) {
            if let Some(head) = group.head_id.as_deref().and_then(|h| self.bot(h)) {
                self.finish_brief(brief, group, &head, &format!("{} didn't finish talking it through, so nothing has started.", group.name), true);
            }
        }
        if let Some(w) = self.with(|s| s.teams.waiters.remove(&room)) {
            let _ = w.send(last_answer.unwrap_or_else(|| format!("{} stopped before answering.", group.name)));
        }
    }
}
