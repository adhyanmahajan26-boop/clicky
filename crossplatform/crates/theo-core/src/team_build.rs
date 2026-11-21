//! The CEO makes new bots, categories and group chats, picks managers, moves bots, and renames a bot or changes its
//! instructions, description, model or memory, when the owner asks in chat (the Mac's ClickyCore `TeamBuildOrder` and
//! `BotsStore.buildTeamFromChat`). The CEO writes one ```team block with JSON; Theo takes it out of the shown answer, checks
//! the owner's own words asked for new bots or categories, and makes them as the New bot dialog and New category row do.

use crate::harness::Harness;
use crate::model::{Bot, ChatMessage, Group};
use crate::protocol;
use once_cell::sync::Lazy;
use regex::Regex;
use serde_json::Value;
use std::collections::HashMap;
use std::sync::Arc;

/// One owner message can't flood the sidebar: at most this many new bots and categories from one answer. Enough for a
/// manager and a squad of workers in one go.
pub const MOST_BOTS: usize = 20;
pub const MOST_CATEGORIES: usize = 6;
pub const MOST_GROUPS: usize = 6;
/// A group chat's bots, its head included: two to six, as the New group dialog allows.
pub const MOST_GROUP_MEMBERS: usize = 6;
pub const FEWEST_GROUP_MEMBERS: usize = 2;
const LONGEST_BOT_NAME: usize = 80;
const LONGEST_CATEGORY_NAME: usize = 80;
const LONGEST_DOES: usize = 200;
/// Long enough for a whole playbook: a bot's instructions go into its prompt as they are.
pub const LONGEST_INSTRUCTIONS: usize = 30000;
pub const LONGEST_MEMORY: usize = 20000;
const LONGEST_MODEL_WORDS: usize = 80;

#[derive(Debug, Clone, PartialEq, Default)]
pub struct NewCategory {
    pub name: String,
    pub purpose: Option<String>,
    /// The bot who manages it, by name, or "none" for everyone reporting to the CEO. None: left as it is.
    pub manager: Option<String>,
}

impl NewCategory {
    pub fn wants_no_manager(&self) -> bool { self.manager.as_deref().map(|m| same_name(m, "none")).unwrap_or(false) }
}

#[derive(Debug, Clone, PartialEq, Default)]
pub struct NewBot {
    pub name: String,
    /// One line on what it does: its description in the sidebar.
    pub does: String,
    /// Its own instructions. Empty: Theo writes "You are <name>. <does>". For a bot that exists, given ones replace its own.
    pub instructions: String,
    /// The category it joins, by name (a bot that already exists is moved there). None: it sits under "Other bots".
    pub category: Option<String>,
    /// The model it runs on, as said ("haiku", "Claude Opus 5.5", an exact id). None: the brain's usual starting model, or,
    /// for a bot that already exists, the one it has. Matched by `pick_brain`.
    pub model: Option<String>,
    /// The brain it runs on ("Claude Code", "Codex", "OpenAI"). None: the maker's own brain, or one that has `model`.
    pub brain: Option<String>,
    /// A bot that exists gets this name instead ("rename"). Ignored for a new bot.
    pub new_name: Option<String>,
    /// What it should remember: a new bot's memory file starts with it, a bot that exists has it added to its own (unless its
    /// memory already holds it).
    pub memory: Option<String>,
}

/// A group chat: bots talking in one room, the head reading the owner's message first and wrapping up. One that exists (by
/// name) gets the head named and the members listed added.
#[derive(Debug, Clone, PartialEq, Default)]
pub struct NewGroup {
    pub name: String,
    /// The bot at its head, by name. None: the first member. Two to six bots in all.
    pub head: Option<String>,
    pub members: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Default)]
pub struct TeamBuildOrder {
    pub categories: Vec<NewCategory>,
    pub bots: Vec<NewBot>,
    pub groups: Vec<NewGroup>,
}

impl TeamBuildOrder {
    pub fn is_empty(&self) -> bool { self.categories.is_empty() && self.bots.is_empty() && self.groups.is_empty() }
}

/// What the CEO is told (ClickyCore `BotProtocol.teamBuildHowTo`).
pub fn how_to(owner: &str) -> String {
    [
        format!("Bots, categories, group chats and managers: you can set them up yourself. When {owner} asks for a new bot, agent, team, category or group chat, a category's manager, a bot moved to another team, or a bot renamed or given new instructions, a new description, model, brain or memory, don't tell them to use a button and don't write files for it: "),
        "say in a line what you'll do, then add one ```team block with JSON {\"categories\": [{\"name\": \"Marketing\", \"purpose\": \"one line\", \"manager\": \"Ada\"}], \"bots\": [{\"name\": \"Ada\", \"does\": \"one line on its job\", \"instructions\": \"its full instructions, written to it as 'You are …'\", \"category\": \"Marketing\", \"model\": \"haiku\", \"memory\": \"what it should remember\"}], \"groups\": [{\"name\": \"Launch room\", \"head\": \"Ada\", \"members\": [\"Rex\", \"Bo\"]}]}. Any list can be left out. ".to_string(),
        "\"model\" picks a bot's model (\"opus\", \"sonnet\", \"haiku\", or an exact model id) and \"brain\" its brain (\"Claude Code\", \"Codex\", or an API key's provider such as \"OpenAI\"), only when asked; without them it runs on your brain and its usual model. List an existing bot with a model or brain to switch it. ".to_string(),
        format!("Instructions can be long (up to {LONGEST_INSTRUCTIONS} characters): write everything the bot should be told, with its sources and how to work, not a summary. "),
        "A category or bot that already exists is used, not made twice: list an existing category to give it a manager (\"manager\": \"none\" for everyone reporting to you), and an existing bot with a category to move it there, with \"rename\": \"its new name\" to rename it, with \"instructions\" or \"does\" to replace its own (only when asked), and with \"memory\" to add to what it remembers (a new bot's memory starts with it). ".to_string(),
        "A manager is a bot in that team (it joins if it isn't), never you. A category with no manager named gets its first bot as manager by itself, unless it's set to \"none\". ".to_string(),
        format!("A group chat is bots talking in one room: its head reads {owner}'s message first and wraps up, its members answer in turn; the bots must exist or be made in the same block, and listing a group chat that exists sets its head and adds the members named; two to six bots in one, the head included. "),
        format!("At most {MOST_BOTS} bots, {MOST_CATEGORIES} categories and {MOST_GROUPS} group chats at a time: make all of what was asked in one block, a whole squad included. Vello does it and says so in the chat; never say it's done before that line shows. Only when {owner} asked for it in their own words."),
    ]
    .concat()
}

/// Names match without regard to case or spaces at the ends.
pub fn same_name(a: &str, b: &str) -> bool { a.trim().to_lowercase() == b.trim().to_lowercase() }

fn cleaned(value: Option<&Value>, longest: usize) -> Option<String> {
    let text = value?.as_str()?;
    let one_line = if longest > LONGEST_DOES { text.to_string() } else { text.replace('\n', " ") };
    let trimmed = one_line.trim();
    if trimmed.is_empty() { return None; }
    Some(trimmed.chars().take(longest).collect())
}

/// The answer without its ```team block, and the order the block holds (None when there's none, or nothing usable in it).
pub fn extract(text: &str) -> (String, Option<TeamBuildOrder>) {
    let Some(start) = text.find("```team") else { return (text.to_string(), None) };
    let after = &text[start + "```team".len()..];
    // The fence's language must be exactly "team", not "teammates" or the like.
    if after.chars().next().map(|c| !c.is_whitespace()).unwrap_or(false) { return (text.to_string(), None); }
    let Some(end) = after.find("```") else { return (text.to_string(), None) };
    let body = &after[..end];
    let shown = format!("{}{}", &text[..start], &after[end + 3..]).trim().to_string();
    (shown, parse(body))
}

/// The JSON inside the block: {"categories": [{"name", "purpose"?, "manager"?}], "bots": [{"name", "does", "instructions"?,
/// "category"?, "model"?, "brain"?, "rename"?, "memory"?}], "groups": [{"name", "head"?, "members"}]}.
pub fn parse(body: &str) -> Option<TeamBuildOrder> {
    let object: Value = serde_json::from_str(body.trim()).ok()?;
    let mut order = TeamBuildOrder::default();
    for entry in object.get("categories").and_then(|c| c.as_array()).into_iter().flatten() {
        let Some(name) = cleaned(entry.get("name"), LONGEST_CATEGORY_NAME) else { continue };
        if order.categories.iter().any(|c| same_name(&c.name, &name)) { continue; }
        order.categories.push(NewCategory { name, purpose: cleaned(entry.get("purpose"), LONGEST_DOES), manager: cleaned(entry.get("manager"), LONGEST_BOT_NAME) });
    }
    for entry in object.get("bots").and_then(|b| b.as_array()).into_iter().flatten() {
        let Some(name) = cleaned(entry.get("name"), LONGEST_BOT_NAME) else { continue };
        if order.bots.iter().any(|b| same_name(&b.name, &name)) { continue; }
        let does = cleaned(entry.get("does").or(entry.get("description")), LONGEST_DOES).unwrap_or_default();
        let instructions = cleaned(entry.get("instructions"), LONGEST_INSTRUCTIONS).unwrap_or_default();
        let category = cleaned(entry.get("category"), LONGEST_CATEGORY_NAME);
        let model = cleaned(entry.get("model"), LONGEST_MODEL_WORDS);
        let brain = cleaned(entry.get("brain").or(entry.get("engine")), LONGEST_MODEL_WORDS);
        let new_name = cleaned(entry.get("rename").or(entry.get("newName")).or(entry.get("new_name")), LONGEST_BOT_NAME).filter(|n| !same_name(n, &name));
        let memory = cleaned(entry.get("memory"), LONGEST_MEMORY);
        order.bots.push(NewBot { name, does, instructions, category, model, brain, new_name, memory });
    }
    for entry in object.get("groups").and_then(|g| g.as_array()).into_iter().flatten() {
        let Some(name) = cleaned(entry.get("name"), LONGEST_CATEGORY_NAME) else { continue };
        if order.groups.iter().any(|g| same_name(&g.name, &name)) { continue; }
        let head = cleaned(entry.get("head").or(entry.get("lead")), LONGEST_BOT_NAME);
        let mut members: Vec<String> = vec![];
        for member in entry.get("members").and_then(|m| m.as_array()).into_iter().flatten().filter_map(|m| cleaned(Some(m), LONGEST_BOT_NAME)) {
            if members.iter().any(|m| same_name(m, &member)) || head.as_deref().map(|h| same_name(h, &member)).unwrap_or(false) { continue; }
            members.push(member);
        }
        members.truncate(if head.is_none() { MOST_GROUP_MEMBERS } else { MOST_GROUP_MEMBERS - 1 });
        if members.len() + usize::from(head.is_some()) < FEWEST_GROUP_MEMBERS { continue; }
        order.groups.push(NewGroup { name, head, members });
    }
    // A bot's category that the block didn't list is made too, so "a bot in a new Sales category" works in one go.
    let wanted: Vec<String> = order.bots.iter().filter_map(|b| b.category.clone()).collect();
    for category in wanted {
        if !order.categories.iter().any(|c| same_name(&c.name, &category)) {
            order.categories.push(NewCategory { name: category, purpose: None, manager: None });
        }
    }
    order.categories.truncate(MOST_CATEGORIES);
    order.bots.truncate(MOST_BOTS);
    order.groups.truncate(MOST_GROUPS);
    if order.is_empty() { None } else { Some(order) }
}

/// `memory` with `added` at its end, or None when it already holds it (so saying it twice doesn't write it twice).
pub fn memory_adding(memory: &str, added: &str) -> Option<String> {
    let wanted = added.trim();
    if wanted.is_empty() || memory.contains(wanted) { return None; }
    let kept = memory.trim();
    Some(if kept.is_empty() { format!("{wanted}\n") } else { format!("{kept}\n\n{wanted}\n") })
}

/// The instructions a new bot starts with.
pub fn instructions_for(bot: &NewBot) -> String {
    if !bot.instructions.is_empty() { return bot.instructions.clone(); }
    if bot.does.is_empty() { format!("You are {}.", bot.name) } else { format!("You are {}. {}", bot.name, bot.does) }
}

/// Whether the owner's own words asked for new bots or categories (ClickyCore `TeamBuildIntent`).
pub fn owner_asked(text: &str) -> bool {
    if protocol::is_routine_run(text) { return false; }
    static PATTERNS: Lazy<Vec<Regex>> = Lazy::new(|| {
        let things = r"(bots?|agents?|assistants?|categor(y|ies)|teams?|departments?|helpers?|employees?|members?|group\s*chats?|groups?)";
        [
            format!(r"\b(make|makes|making|made|create|creates|creating|add|adding|set\s+up|setup|build|start|spin\s+up|hire|need|want|get|give\s+me)\b[^.?!\n]{{0,60}}\b{things}\b"),
            format!(r"\b(new|another|more|extra)\s+([a-z-]+\s+){{0,3}}{things}\b"),
            r"\b(a|an)\s+([a-z-]+\s+){0,3}(bot|agent|assistant)\s+(that|which|who|for|to)\b".to_string(),
            // "make Penny the manager of Growth", "put Ada in charge of Sales", "Rex should lead the team"
            r"\b(make|set|put|assign|appoint|promote|let|turn|have|change|switch)\b[^.?!\n]{0,60}\b(manager|lead|head|boss|in\s+charge)\b".to_string(),
            r"\b(should|to|will|can)\s+(manage|lead|head|run)\b".to_string(),
            r"\bno\s+(manager|lead|boss)\b".to_string(),
            // "move Penny to Sales", "put Rex into Growth"
            r"\b(move|put|file|shift|transfer)\b[^.?!\n]{0,60}\b(to|into|under|in)\b".to_string(),
            // "switch Rex to Haiku", "Penny should use Opus", "run the workers on Codex"
            r"\b(set|switch|change|move|put|use|uses|using|run|runs|make|give)\b[^.?!\n]{0,60}\b(models?|brains?|opus|sonnet|haiku|fable|gpt[-\w.]*|gemini|grok|codex|cursor|opencode|claude)\b".to_string(),
            // "rename Rex to Max", "call Penny Ledger from now on"
            r"\b(rename|renames|renaming|re-name)\b".to_string(),
            r"\b(call|name)\s+\w+[^.?!\n]{0,40}\b(instead|from\s+now\s+on)\b".to_string(),
            // "change Rex's instructions", "give Ada a better prompt", "update the digger's description"
            r"\b(set|change|changes|update|updates|replace|rewrite|rewrites|edit|edits|give|fix|improve|improves|write|tweak|tune)\b[^.?!\n]{0,60}\b(instructions?|prompts?|system\s+prompts?|descriptions?|persona)\b".to_string(),
            // "save this to Rex's memory", "Ada should remember that", "add the sources to their memory"
            r"\b(save|saves|add|adds|write|writes|put|store|stores|set|give|seed|update)\b[^.?!\n]{0,60}\b(memory|memories)\b".to_string(),
            r"\b(should|to|must|always)\s+remember\b".to_string(),
        ]
        .iter()
        .map(|p| Regex::new(p).unwrap())
        .collect()
    });
    let lower = text.to_lowercase();
    PATTERNS.iter().any(|re| re.is_match(&lower))
}

// MARK: Which brain and model (ClickyCore `TeamBuildBrains`)

/// A brain a bot can run on here: an engine id ("claude", "codex", "api:openai"), its name, and its models as (id, name)
/// (empty when Vello can't list them, as with most agents).
#[derive(Debug, Clone, PartialEq, Default)]
pub struct BrainHere {
    pub engine: String,
    pub label: String,
    pub models: Vec<(String, String)>,
}

/// The choice for one bot. `model` None: the brain's usual starting model (or, for a bot that exists, the one it has).
/// `trouble` says in a few words why something asked for couldn't be used, for Vello's note.
#[derive(Debug, Clone, PartialEq, Default)]
pub struct BrainPick {
    pub engine: String,
    pub model: Option<String>,
    pub trouble: Option<String>,
}

/// The Claude models a bot on Claude Code can pick (the New bot dialog's list).
pub const CLAUDE_MODELS: [(&str, &str); 3] = [("claude-opus-5-5", "Claude Opus 5.5"), ("claude-sonnet-5-5", "Claude Sonnet 5.5"), ("claude-haiku-5-5", "Claude Haiku 5.5")];

/// "Claude Opus 5.5" → ["claude", "opus", "5", "5"]; letters and digits apart, so "gpt5" is ["gpt", "5"].
fn model_words(text: &str) -> Vec<String> {
    let mut found = vec![];
    let mut current = String::new();
    let mut current_is_digits = false;
    for c in text.to_lowercase().chars() {
        let (letter, digit) = (c.is_ascii_alphabetic(), c.is_ascii_digit());
        if !letter && !digit {
            if !current.is_empty() { found.push(std::mem::take(&mut current)); }
            continue;
        }
        if !current.is_empty() && current_is_digits != digit { found.push(std::mem::take(&mut current)); }
        current.push(c);
        current_is_digits = digit;
    }
    if !current.is_empty() { found.push(current); }
    found
}

/// Whether every word of `wanted` is in `words`, in that order (others may come between).
fn holds_in_order(words: &[String], wanted: &[String]) -> bool {
    let mut next = 0;
    for word in words {
        if next < wanted.len() && *word == wanted[next] { next += 1; }
    }
    next == wanted.len()
}

/// The model `asked` names: its exact id, else the first whose id or name holds the asked words in order.
pub fn match_model<'a>(asked: &str, models: &'a [(String, String)]) -> Option<&'a (String, String)> {
    let exact = asked.trim().to_lowercase();
    if let Some(found) = models.iter().find(|(id, _)| id.to_lowercase() == exact) { return Some(found); }
    let wanted = model_words(asked);
    if wanted.is_empty() { return None; }
    models.iter().find(|(id, label)| holds_in_order(&model_words(id), &wanted) || holds_in_order(&model_words(label), &wanted))
}

/// The brain `asked` names, by its engine id or the words of its name ("Claude Code", "codex", "OpenAI").
pub fn match_brain<'a>(asked: &str, brains: &'a [BrainHere]) -> Option<&'a BrainHere> {
    let exact = asked.trim().to_lowercase();
    if let Some(found) = brains.iter().find(|b| b.engine.to_lowercase() == exact) { return Some(found); }
    const FILLER: [&str; 7] = ["code", "cli", "agent", "api", "key", "the", "app"];
    let wanted: Vec<String> = model_words(asked).into_iter().filter(|w| !FILLER.contains(&w.as_str())).collect();
    if wanted.is_empty() { return None; }
    brains.iter().find(|b| {
        let named: Vec<String> = model_words(&b.engine).into_iter().chain(model_words(&b.label)).collect();
        wanted.iter().all(|w| named.contains(w))
    })
}

/// An exact model id rather than words: no spaces, only the characters ids use.
pub fn looks_like_model_id(text: &str) -> bool {
    let trimmed = text.trim();
    !trimmed.is_empty() && trimmed.chars().count() <= 80 && trimmed.chars().all(|c| c.is_alphanumeric() || "-._/:".contains(c))
}

/// `brains` in the order to try them (the maker's own first). A brain that's asked for and isn't set up here is said and
/// the maker's is used; a model is looked for on the asked brain, else on the maker's, else on any brain here.
pub fn pick_brain(asked_brain: Option<&str>, asked_model: Option<&str>, maker_engine: &str, brains: &[BrainHere]) -> BrainPick {
    let mut trouble = None;
    let mut engine = maker_engine.to_string();
    if let Some(asked) = asked_brain {
        match match_brain(asked, brains) {
            Some(found) => engine = found.engine.clone(),
            None => trouble = Some(format!("there's no brain called {asked} set up here")),
        }
    }
    let Some(asked_model) = asked_model else { return BrainPick { engine, model: None, trouble } };
    let chosen = brains.iter().find(|b| b.engine == engine);
    if let Some(found) = chosen.and_then(|b| match_model(asked_model, &b.models)) {
        return BrainPick { engine, model: Some(found.0.clone()), trouble };
    }
    // A brain whose models Vello can't list (most agents) takes an exact model id as it is.
    let chosen_takes_ids = chosen.map(|b| b.models.is_empty()).unwrap_or(true) && looks_like_model_id(asked_model);
    // No brain was named: another brain here with that model will do, in order. An exact id that the maker's own brain takes
    // as it is stays there ("gpt-6" for a bot made by a Codex CEO), but words ("opus") move.
    if asked_brain.is_none() {
        for other in brains.iter().filter(|b| b.engine != engine) {
            let Some(found) = match_model(asked_model, &other.models) else { continue };
            if chosen_takes_ids && found.0.to_lowercase() == asked_model.trim().to_lowercase() { continue; }
            return BrainPick { engine: other.engine.clone(), model: Some(found.0.clone()), trouble: None };
        }
    }
    if chosen_takes_ids {
        return BrainPick { engine, model: Some(asked_model.to_string()), trouble };
    }
    let brain_name = chosen.map(|b| b.label.clone()).unwrap_or_else(|| engine.clone());
    let model_trouble = format!("{brain_name} has no model called {asked_model}");
    BrainPick { engine, model: None, trouble: Some(match trouble { Some(t) => format!("{t}, and {model_trouble}"), None => model_trouble }) }
}

/// The brains a bot made or switched from chat can run on here, the maker's own first: agents that are installed, then API
/// providers with a key. API models are only asked for when a model was named.
async fn brains_here(h: &Arc<Harness>, maker: &Bot, list_api_models: bool) -> Vec<BrainHere> {
    let mut engines: Vec<String> = crate::brains::COMMAND_LINE_BRAINS.iter().map(|b| b.id.to_string())
        .chain(crate::brains::api_provider_ids().into_iter().map(|id| format!("api:{id}")))
        .filter(|engine| *engine == maker.provider || crate::brains::usable_without_asking(h, engine))
        .collect();
    if !engines.contains(&maker.provider) { engines.insert(0, maker.provider.clone()); }
    engines.sort_by_key(|engine| *engine != maker.provider);
    let mut brains = vec![];
    for engine in engines {
        let models: Vec<(String, String)> = if engine == "claude" {
            CLAUDE_MODELS.iter().map(|(id, label)| (id.to_string(), label.to_string())).collect()
        } else if let Some(provider_id) = crate::brains::api_provider_id(&engine).filter(|_| list_api_models) {
            crate::brains::list_models(h, provider_id).await.unwrap_or_default().into_iter().map(|id| (id.clone(), id)).collect()
        } else {
            vec![]
        };
        let label = crate::brains::label(&engine);
        brains.push(BrainHere { engine, label, models });
    }
    brains
}

/// "Claude Haiku 5.5", or "gpt-6 (Codex)" when it's not the maker's brain.
fn brain_words(model: &str, engine: &str, maker_engine: &str) -> String {
    let model_name = if model.is_empty() { "its usual model".to_string() } else {
        CLAUDE_MODELS.iter().find(|(id, _)| *id == model).map(|(_, label)| label.to_string()).unwrap_or_else(|| model.to_string())
    };
    if engine == maker_engine { model_name } else { format!("{model_name} ({})", crate::brains::label(engine)) }
}

/// One bot made from a block, for Vello's note: its name, its category's name and the words for its model (empty when no
/// model was asked for).
#[derive(Debug, Clone, PartialEq, Default)]
pub struct MadeBot {
    pub name: String,
    pub category: Option<String>,
    pub model_words: String,
}

/// "Vello made the bot Rex in Sales." or, for many, grouped so a squad reads in one line (ClickyCore
/// `TeamBuildOrder.madeBotsSentence`).
pub fn made_bots_sentence(made: &[MadeBot]) -> String {
    if made.len() <= 1 {
        let Some(only) = made.first() else { return String::new() };
        let category = only.category.as_ref().map(|c| format!(" in {c}")).unwrap_or_default();
        let model = if only.model_words.is_empty() { String::new() } else { format!(" on {}", only.model_words) };
        return format!("Vello made the bot {}{category}{model}.", only.name);
    }
    let mut category_order: Vec<Option<String>> = vec![];
    for bot in made { if !category_order.contains(&bot.category) { category_order.push(bot.category.clone()); } }
    let names_in = |category: &Option<String>| -> String {
        let members: Vec<&MadeBot> = made.iter().filter(|b| &b.category == category).collect();
        let mut model_order: Vec<&str> = vec![];
        for bot in &members { if !model_order.contains(&bot.model_words.as_str()) { model_order.push(&bot.model_words); } }
        model_order.iter().map(|model| {
            let names: Vec<String> = members.iter().filter(|b| b.model_words == *model).map(|b| b.name.clone()).collect();
            format!("{}{}", listed_in_words(&names), if model.is_empty() { String::new() } else { format!(" on {model}") })
        }).collect::<Vec<_>>().join("; ")
    };
    if category_order.len() == 1 {
        return match &category_order[0] {
            Some(category) => format!("Vello made {} bots in {category}: {}.", made.len(), names_in(&category_order[0])),
            None => format!("Vello made {} bots: {}.", made.len(), names_in(&None)),
        };
    }
    let parts: Vec<String> = category_order.iter().map(|category| match category {
        Some(name) => format!("in {name}, {}", names_in(category)),
        None => format!("outside any category, {}", names_in(category)),
    }).collect();
    format!("Vello made {} bots: {}.", made.len(), parts.join("; "))
}

/// "A", "A and B", "A, B and C".
fn listed_in_words(items: &[String]) -> String {
    match items.len() {
        0 => String::new(),
        1 => items[0].clone(),
        n => format!("{} and {}", items[..n - 1].join(", "), items[n - 1]),
    }
}

/// The model a new bot on `engine` starts with: an API provider's preferred model, an agent's own default.
async fn starting_model(h: &Arc<Harness>, engine: &str, maker: &Bot) -> String {
    match crate::brains::api_provider_id(engine) {
        Some(provider_id) => crate::brains::model_for_new_bot(h, provider_id).await
            .unwrap_or_else(|| if maker.provider == engine { maker.model.clone() } else { String::new() }),
        None => crate::brains::command_line_brain(engine).map(|brain| brain.default_model.to_string()).unwrap_or_default(),
    }
}

/// Who may make bots and categories from chat: the CEO.
pub fn may_build(bot: &Bot) -> bool { bot.primary }

/// Carries out a ```team block from `maker`'s answer in `room`. Only the owner's own words asking for new bots or categories
/// let it through; anything else is said in the chat and dropped, as a routine block is.
pub async fn build_for_turn(h: &Arc<Harness>, maker: &Bot, order: TeamBuildOrder, room: &str, from_owner: bool) {
    let asked = from_owner && may_build(maker) && h.recent_owner_words(room).as_deref().map(owner_asked).unwrap_or(false);
    if !asked {
        h.post(ChatMessage::note(format!("{} wrote changes to the bots or categories, but they weren't asked for in your own words here, so Vello didn't make them. Ask for them yourself if you want them.", maker.name)), room);
        return;
    }
    let mut made_categories: Vec<String> = vec![];
    let mut made_bots: Vec<MadeBot> = vec![];
    let mut filed: Vec<String> = vec![];
    let mut manager_lines: Vec<String> = vec![];
    let mut brain_lines: Vec<String> = vec![];
    let mut edit_lines: Vec<String> = vec![];
    // A bot renamed in this answer can still be named by its old name further down the block (a group chat, a manager).
    let mut renamed: HashMap<String, String> = HashMap::new();

    // Each category's manager before any change, so a manager filled in by itself (the first bot in a category takes the job)
    // is said in the note too, and the CEO doesn't think the category has none.
    let managers_before: HashMap<String, Option<String>> = h.layout().sections.iter().map(|s| (s.id.clone(), s.leader_id.clone())).collect();
    let mut managed_by_order: Vec<String> = vec![];

    // Categories first, so the bots can join them. One with the same name is used rather than made twice.
    let mut category_ids: HashMap<String, String> = HashMap::new();
    for wanted in &order.categories {
        if let Some(existing) = h.layout().sections.iter().find(|s| same_name(&s.name, &wanted.name)) {
            category_ids.insert(wanted.name.to_lowercase(), existing.id.clone());
            if let Some(purpose) = wanted.purpose.clone().filter(|p| Some(p) != existing.purpose.as_ref()) {
                let id = existing.id.clone();
                h.change_layout(|layout, _| { if let Some(s) = layout.section_mut(&id) { s.purpose = Some(purpose) } });
            }
            continue;
        }
        let purpose = wanted.purpose.clone();
        let id = h.change_layout(|layout, _| {
            let id = layout.add(&wanted.name)?;
            if let Some(section) = layout.section_mut(&id) { section.purpose = purpose; }
            Some(id)
        });
        if let Some(id) = id {
            category_ids.insert(wanted.name.to_lowercase(), id);
            made_categories.push(wanted.name.clone());
        }
    }

    // New bots run on the same brain as the bot that made it, on that brain's usual starting model: it works on this
    // computer, which the owner's default may not.
    // A model or brain the block names is used when this computer has it.
    let brains = brains_here(h, maker, order.bots.iter().any(|b| b.model.is_some())).await;
    for wanted in &order.bots {
        let category_id = wanted.category.as_ref().and_then(|c| category_ids.get(&c.to_lowercase()).cloned());
        if let Some(existing) = h.bots().into_iter().find(|b| same_name(&b.name, &wanted.name)) {
            // Already there: moved into its category rather than made a second time. The CEO stays on top.
            let already_in = category_id.as_deref().and_then(|id| h.layout().section(id).map(|s| s.contains(&existing.id))).unwrap_or(true);
            if let Some(id) = category_id.as_deref().filter(|_| !existing.primary && !already_in) {
                h.change_layout(|layout, bots| layout.move_bot(&existing.id, Some(id), bots));
                let saved = h.layout().section(id).map(|s| s.name.clone()).unwrap_or_default();
                filed.push(format!("{} moved to {saved}", existing.name));
            }
            // A model or brain named for a bot that exists switches it, as its settings do.
            if !existing.primary && (wanted.model.is_some() || wanted.brain.is_some()) {
                let pick = pick_brain(wanted.brain.as_deref(), wanted.model.as_deref(), &existing.provider, &brains);
                if let Some(trouble) = &pick.trouble { brain_lines.push(format!("Vello couldn't switch {} as asked: {trouble}", existing.name)); }
                let new_model = match &pick.model {
                    Some(model) => model.clone(),
                    None if pick.engine == existing.provider => existing.model.clone(),
                    None => starting_model(h, &pick.engine, maker).await,
                };
                if pick.engine != existing.provider || new_model != existing.model {
                    let mut switched = existing.clone();
                    switched.provider = pick.engine.clone();
                    switched.model = new_model.clone();
                    switched.effort = None;
                    h.save_bot(switched);
                    brain_lines.push(format!("{} runs on {} now", existing.name, brain_words(&new_model, &pick.engine, &maker.provider)));
                }
            }
            edit_lines.extend(edit_from_chat(h, &existing.id, wanted, &mut renamed));
            continue;
        }
        let pick = pick_brain(wanted.brain.as_deref(), wanted.model.as_deref(), &maker.provider, &brains);
        let model = match &pick.model { Some(model) => model.clone(), None => starting_model(h, &pick.engine, maker).await };
        let description = if wanted.does.is_empty() { format!("Your {} bot.", wanted.name) } else { wanted.does.clone() };
        let bot = h.add_bot(Bot::new(&wanted.name, &description, &instructions_for(wanted), &pick.engine, &model));
        if let Some(memory) = &wanted.memory { write_memory_from_chat(h, &bot.id, memory, false); }
        if let Some(id) = category_id.as_deref() {
            h.change_layout(|layout, bots| { if let Some(s) = layout.section_mut(id) { s.add_member(&bot.id, bots) } });
        }
        let model_words = if wanted.model.is_some() || wanted.brain.is_some() { brain_words(&model, &pick.engine, &maker.provider) } else { String::new() };
        let category = category_id.as_deref().and_then(|id| h.layout().section(id).map(|s| s.name.clone()));
        made_bots.push(MadeBot { name: bot.name.clone(), category, model_words });
        if let Some(trouble) = &pick.trouble {
            brain_lines.push(format!("{} runs on {} because {trouble}", bot.name, brain_words(&model, &pick.engine, &maker.provider)));
        }
    }

    // Managers last, so a bot made in this same answer can be one.
    for wanted in order.categories.iter().filter(|c| c.manager.is_some()) {
        let Some(id) = category_ids.get(&wanted.name.to_lowercase()).cloned() else { continue };
        let Some(team) = h.layout().section(&id).cloned() else { continue };
        managed_by_order.push(id.clone());
        if wanted.wants_no_manager() {
            if team.leader_id.is_some() || team.wants_manager != Some(false) {
                h.change_layout(|layout, bots| { if let Some(s) = layout.section_mut(&id) { s.set_has_manager(false, bots) } });
                manager_lines.push(format!("{} has no manager now, so its bots report to {}", team.name, maker.name));
            }
            continue;
        }
        let name = wanted.manager.clone().unwrap_or_default();
        let Some(manager) = h.bots().into_iter().find(|b| same_name(&b.name, &name) && !b.primary) else {
            manager_lines.push(format!("Vello couldn't make {name} the manager of {}: there's no bot by that name that can manage a team", team.name));
            continue;
        };
        // Already the manager: said anyway when it only became one in this answer (a new category's first bot takes the job as it
        // joins, before this loop), so the note always names the manager it was asked for.
        if team.leader_id.as_deref() == Some(manager.id.as_str()) {
            if managers_before.get(&id).and_then(|m| m.as_deref()) != Some(manager.id.as_str()) {
                manager_lines.push(format!("{} manages {} now", manager.name, team.name));
            }
            continue;
        }
        h.change_layout(|layout, bots| {
            if let Some(s) = layout.section_mut(&id) {
                s.add_member(&manager.id, bots);
                s.set_leader(Some(manager.id.clone()), bots);
            }
        });
        manager_lines.push(format!("{} manages {} now", manager.name, team.name));
    }

    let group_lines = build_groups_from_chat(h, &order.groups, &renamed);

    // A manager the block didn't name but the category got anyway: a new category's first bot, or the next bot in one whose
    // manager moved out.
    let bots_now = h.bots();
    for section in h.layout().sections.iter().filter(|s| !managed_by_order.contains(&s.id)) {
        let Some(leader) = section.leader_id.as_deref() else { continue };
        if managers_before.get(&section.id).and_then(|m| m.as_deref()) == Some(leader) { continue; }
        let Some(manager) = bots_now.iter().find(|b| b.id == leader) else { continue };
        manager_lines.push(format!("{} manages {} now, as its first bot (ask for another manager, or none, if you'd like)", manager.name, section.name));
    }

    let mut sentences: Vec<String> = vec![];
    if !made_bots.is_empty() {
        sentences.push(made_bots_sentence(&made_bots));
    }
    if !made_categories.is_empty() {
        sentences.push(format!("New {} {}.", if made_categories.len() == 1 { "category:" } else { "categories:" }, listed_in_words(&made_categories)));
    }
    sentences.extend(filed.into_iter().map(|f| format!("{f}.")));
    sentences.extend(manager_lines.into_iter().map(|f| format!("{f}.")));
    sentences.extend(brain_lines.into_iter().map(|f| format!("{f}.")));
    sentences.extend(edit_lines.into_iter().map(|f| format!("{f}.")));
    sentences.extend(group_lines.into_iter().map(|f| format!("{f}.")));
    if sentences.is_empty() {
        sentences.push(format!("Everything {} asked for was already set up that way, so nothing changed.", maker.name));
    } else if !made_bots.is_empty() {
        sentences.push("They're in the sidebar, and each one's settings can change its brain, model and apps.".into());
    }
    // Marked as a team note so the CEO reads it at the start of its next turn (`take_waiting_reports`) and knows what was made.
    let mut note = ChatMessage::note(sentences.join(" "));
    note.card = Some(TEAM_NOTE_CARD.into());
    h.post(note, room);
}

/// A bot that exists, listed with a new name, instructions, description or memory: changed as its settings would, and said
/// in the note. The CEO stays as it is.
fn edit_from_chat(h: &Arc<Harness>, bot_id: &str, wanted: &NewBot, renamed: &mut HashMap<String, String>) -> Vec<String> {
    let Some(mut edited) = h.bot(bot_id) else { return vec![] };
    if wanted.new_name.is_none() && wanted.instructions.is_empty() && wanted.does.is_empty() && wanted.memory.is_none() { return vec![]; }
    if edited.primary {
        // Only said when something it can't take was asked for: a description alone is often just the CEO restating it.
        if wanted.new_name.is_none() && wanted.instructions.is_empty() && wanted.memory.is_none() { return vec![]; }
        return vec![format!("Vello doesn't change {}'s name, instructions or memory from chat: its own settings can", edited.name)];
    }
    let before = edited.clone();
    let mut lines = vec![];
    let mut changes: Vec<String> = vec![];
    if let Some(new_name) = &wanted.new_name {
        if h.bots().iter().any(|b| b.id != bot_id && same_name(&b.name, new_name)) {
            lines.push(format!("Vello couldn't rename {} to {new_name}: another bot is called that", edited.name));
        } else if edited.name != *new_name {
            renamed.insert(edited.name.to_lowercase(), bot_id.to_string());
            lines.push(format!("{} is called {new_name} now", edited.name));
            edited.name = new_name.clone();
        }
    }
    if !wanted.instructions.is_empty() && wanted.instructions != edited.instructions {
        edited.instructions = wanted.instructions.clone();
        changes.push("new instructions".into());
    }
    if !wanted.does.is_empty() && wanted.does != edited.description {
        edited.description = wanted.does.clone();
        changes.push("a new description".into());
    }
    if edited != before { h.save_bot(edited.clone()); }
    if !changes.is_empty() { lines.push(format!("{} has {}", edited.name, listed_in_words(&changes))); }
    if let Some(memory) = &wanted.memory {
        lines.push(if write_memory_from_chat(h, bot_id, memory, true) { format!("Vello added that to {}'s memory", edited.name) } else { format!("{}'s memory already had that", edited.name) });
    }
    lines
}

/// Writes what a bot should remember into its memory file: a new bot's file starts with it, a bot that exists has it added at
/// the end. False when its memory already held it.
fn write_memory_from_chat(h: &Arc<Harness>, bot_id: &str, memory: &str, adding: bool) -> bool {
    let file = h.paths.memory_file(bot_id);
    let before = if adding { std::fs::read_to_string(&file).unwrap_or_default() } else { String::new() };
    let Some(after) = memory_adding(&before, memory) else { return false };
    let _ = std::fs::create_dir_all(h.paths.memory_dir(bot_id));
    std::fs::write(&file, after).is_ok()
}

/// A group chat's id from its name, as the New group dialog makes it.
fn group_slug(name: &str) -> String {
    let lowered: String = name.to_lowercase().chars().map(|c| if c.is_ascii_alphanumeric() { c } else { '-' }).collect();
    let joined = lowered.split('-').filter(|p| !p.is_empty()).collect::<Vec<_>>().join("-");
    let short: String = joined.chars().take(40).collect();
    let short = short.trim_end_matches('-').to_string();
    if short.is_empty() { "group".into() } else { short }
}

/// Makes the group chats a block lists, or sets the head of one that exists and adds the members named, as the New group
/// dialog does. Each one's line for the note.
fn build_groups_from_chat(h: &Arc<Harness>, wanted_groups: &[NewGroup], renamed: &HashMap<String, String>) -> Vec<String> {
    let mut lines = vec![];
    // A bot by its name now, or by the name it had before this answer renamed it.
    let bot_named = |name: &str| -> Option<Bot> {
        let bots = h.bots();
        bots.iter().find(|b| same_name(&b.name, name)).cloned().or_else(|| renamed.get(&name.trim().to_lowercase()).and_then(|id| h.bot(id)))
    };
    let name_of = |id: &str| h.bot(id).map(|b| b.name).unwrap_or_default();
    for wanted in wanted_groups {
        let head = wanted.head.as_deref().and_then(bot_named);
        let mut member_ids: Vec<String> = vec![];
        let mut missing: Vec<String> = vec![];
        for name in wanted.head.iter().chain(wanted.members.iter()) {
            match bot_named(name) {
                Some(found) => { if !member_ids.contains(&found.id) { member_ids.push(found.id); } }
                None => missing.push(name.clone()),
            }
        }
        let missing_line = if missing.is_empty() { String::new() } else { format!(" (Vello couldn't find {} to add)", listed_in_words(&missing)) };
        let existing = h.with(|s| s.groups.iter().find(|g| same_name(&g.name, &wanted.name)).cloned());
        if let Some(mut group) = existing {
            let before = group.clone();
            if let Some(head) = &head {
                if group.head_id.as_deref() != Some(head.id.as_str()) {
                    if let Some(old) = group.head_id.take() { group.member_ids.push(old); }
                    group.head_id = Some(head.id.clone());
                }
            }
            let joining: Vec<String> = member_ids.iter().filter(|id| group.head_id.as_deref() != Some(id.as_str()) && !group.member_ids.contains(id)).cloned().collect();
            group.member_ids.retain(|id| group.head_id.as_deref() != Some(id.as_str()));
            let room = MOST_GROUP_MEMBERS.saturating_sub(group.all_ids().len());
            let joined: Vec<String> = joining.iter().take(room).cloned().collect();
            group.member_ids.extend(joined.iter().cloned());
            if group == before {
                if !missing.is_empty() { lines.push(format!("The {} group chat stays as it was{missing_line}", group.name)); }
                continue;
            }
            h.save_group(group.clone());
            let mut parts: Vec<String> = vec![];
            if group.head_id != before.head_id { if let Some(id) = &group.head_id { parts.push(format!("{} leads it now", name_of(id))); } }
            let joined_names: Vec<String> = joined.iter().map(|id| name_of(id)).collect();
            if !joined_names.is_empty() { parts.push(format!("{} joined", listed_in_words(&joined_names))); }
            if joining.len() > room { parts.push("it was full, so not everyone joined (six bots at most)".into()); }
            lines.push(format!("In the {} group chat, {}{missing_line}", group.name, parts.join("; ")));
            continue;
        }
        let head_id = head.map(|b| b.id).or_else(|| member_ids.first().cloned());
        let Some(head_id) = head_id.filter(|_| member_ids.len() >= FEWEST_GROUP_MEMBERS) else {
            lines.push(format!("Vello couldn't make the {} group chat: it needs two bots that are here{missing_line}", wanted.name));
            continue;
        };
        let base = group_slug(&wanted.name);
        let mut id = base.clone();
        let mut n = 2;
        while h.group(&id).is_some() { id = format!("{base}-{n}"); n += 1; }
        let others: Vec<String> = member_ids.iter().filter(|m| **m != head_id).take(MOST_GROUP_MEMBERS - 1).cloned().collect();
        h.save_group(Group { id, name: wanted.name.clone(), head_id: Some(head_id.clone()), member_ids: others.clone() });
        let other_names: Vec<String> = others.iter().map(|id| name_of(id)).collect();
        lines.push(format!("New group chat: {}, with {} at its head and {}{missing_line}", wanted.name, name_of(&head_id), listed_in_words(&other_names)));
    }
    lines
}

/// The `card` of Vello's note on what a ```team block changed. It draws as a plain note.
pub const TEAM_NOTE_CARD: &str = "team-note";

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn takes_the_block_out_and_reads_it() {
        let answer = "I'll set up a Marketing team with a writer.\n```team\n{\"categories\": [{\"name\": \"Marketing\", \"purpose\": \"Launch posts\"}],\n \"bots\": [{\"name\": \"Ada\", \"does\": \"Writes launch posts\", \"category\": \"Marketing\"}]}\n```";
        let (shown, order) = extract(answer);
        assert_eq!(shown, "I'll set up a Marketing team with a writer.");
        let order = order.unwrap();
        assert_eq!(order.categories, vec![NewCategory { name: "Marketing".into(), purpose: Some("Launch posts".into()), manager: None }]);
        assert_eq!(order.bots, vec![NewBot { name: "Ada".into(), does: "Writes launch posts".into(), instructions: String::new(), category: Some("Marketing".into()), ..Default::default() }]);
    }

    #[test]
    fn a_bots_category_is_made_too() {
        let order = parse(r#"{"bots": [{"name": "Rex", "category": "Sales"}]}"#).unwrap();
        assert_eq!(order.categories.iter().map(|c| c.name.as_str()).collect::<Vec<_>>(), vec!["Sales"]);
    }

    #[test]
    fn nothing_usable_is_no_order() {
        assert!(parse(r#"{"bots": [{"name": "  "}]}"#).is_none());
        assert!(parse("not json").is_none());
        assert!(extract("No block here.").1.is_none());
        let other = "```teammates\n{\"bots\": [{\"name\": \"Ada\"}]}\n```";
        assert_eq!(extract(other), (other.to_string(), None));
    }

    #[test]
    fn one_answer_cant_flood_the_sidebar() {
        let bots: Vec<String> = (1..=30).map(|n| format!(r#"{{"name": "Bot {n}"}}"#)).collect();
        let categories: Vec<String> = (1..=10).map(|n| format!(r#"{{"name": "Team {n}"}}"#)).collect();
        let order = parse(&format!(r#"{{"bots": [{}], "categories": [{}]}}"#, bots.join(","), categories.join(","))).unwrap();
        assert_eq!(order.bots.len(), MOST_BOTS);
        assert_eq!(order.categories.len(), MOST_CATEGORIES);
        assert_eq!(parse(r#"{"bots": [{"name": "Ada"}, {"name": "ada "}]}"#).unwrap().bots.len(), 1);
    }

    #[test]
    fn instructions_fall_back_to_the_job() {
        assert_eq!(instructions_for(&NewBot { name: "Ada".into(), does: "Writes posts.".into(), ..Default::default() }), "You are Ada. Writes posts.");
        assert_eq!(instructions_for(&NewBot { name: "Ada".into(), ..Default::default() }), "You are Ada.");
    }

    #[test]
    fn the_owner_asking_for_bots_or_categories() {
        for words in ["make a new bot that writes my posts", "Can you create a Sales category?", "add two agents to research competitors",
                      "set up a marketing team with a writer and a designer", "I need a bot for my inbox", "new category: Finance",
                      "hire an assistant to sort my mail", "spin up 3 bots for the launch"] {
            assert!(owner_asked(words), "{words}");
        }
        for words in ["what did the team do today?", "summarise my inbox", "write me a launch post"] {
            assert!(!owner_asked(words), "{words}");
        }
    }

    #[test]
    fn a_category_can_name_its_manager() {
        let order = parse(r#"{"categories": [{"name": "Growth", "manager": "Penny"}, {"name": "Sales", "manager": "None"}]}"#).unwrap();
        assert_eq!(order.categories[0].manager.as_deref(), Some("Penny"));
        assert!(!order.categories[0].wants_no_manager());
        assert!(order.categories[1].wants_no_manager());
        for words in ["make Penny the manager of Growth", "put Ada in charge of Sales", "Rex should lead the marketing team",
                      "Growth needs no manager", "move Penny to Sales", "assign a manager to every team"] {
            assert!(owner_asked(words), "{words}");
        }
    }

    #[test]
    fn the_ceo_is_told_how() {
        let text = how_to("the owner");
        assert!(text.contains("```team"));
        assert!(text.contains("\"bots\": [{\"name\": \"Ada\""));
    }

    fn brains_for_tests() -> Vec<BrainHere> {
        let claude = BrainHere { engine: "claude".into(), label: "Claude Code".into(), models: CLAUDE_MODELS.iter().map(|(i, l)| (i.to_string(), l.to_string())).chain([("claude-haiku-4-5".to_string(), "Claude Haiku 4.5".to_string())]).collect() };
        let codex = BrainHere { engine: "codex".into(), label: "Codex".into(), models: vec![] };
        let openai = BrainHere { engine: "api:openai".into(), label: "OpenAI (API key)".into(), models: vec![("gpt-6".into(), "gpt-6".into()), ("gpt-6-mini".into(), "gpt-6-mini".into())] };
        vec![claude, codex, openai]
    }

    #[test]
    fn a_manager_and_ten_workers_fit_in_one_answer() {
        let workers: Vec<String> = (1..=10).map(|n| format!(r#"{{"name": "Digger {n}", "category": "Super Digger Squad", "model": "haiku"}}"#)).collect();
        let body = format!(r#"{{"categories": [{{"name": "Super Digger Squad", "manager": "Digger Boss"}}], "bots": [{{"name": "Digger Boss", "category": "Super Digger Squad", "model": "Claude Opus 5.5"}}, {}]}}"#, workers.join(","));
        let order = parse(&body).unwrap();
        assert_eq!(order.bots.len(), 11);
        assert_eq!(order.bots[0].model.as_deref(), Some("Claude Opus 5.5"));
        let brains = brains_for_tests();
        assert_eq!(pick_brain(None, order.bots[0].model.as_deref(), "claude", &brains).model.as_deref(), Some("claude-opus-5-5"));
        assert_eq!(pick_brain(None, order.bots[10].model.as_deref(), "claude", &brains).model.as_deref(), Some("claude-haiku-5-5"));
    }

    #[test]
    fn models_and_brains_by_their_words() {
        let brains = brains_for_tests();
        assert_eq!(match_model("haiku 4.5", &brains[0].models).map(|m| m.0.as_str()), Some("claude-haiku-4-5"));
        assert_eq!(match_model("opus 4.1", &brains[0].models), None);
        assert_eq!(match_brain("Claude Code", &brains).map(|b| b.engine.as_str()), Some("claude"));
        assert_eq!(match_brain("OpenAI API key", &brains).map(|b| b.engine.as_str()), Some("api:openai"));
        assert_eq!(match_brain("Gemini", &brains), None);
        let parsed = parse(r#"{"bots": [{"name": "Rex", "engine": "Codex", "model": "gpt-6"}]}"#).unwrap();
        assert_eq!(parsed.bots[0].brain.as_deref(), Some("Codex"));
    }

    #[test]
    fn brain_picks() {
        let brains = brains_for_tests();
        let pick = |brain: Option<&str>, model: Option<&str>, maker: &str| { let p = pick_brain(brain, model, maker, &brains); (p.engine, p.model, p.trouble) };
        assert_eq!(pick(None, Some("gpt-6-mini"), "claude"), ("api:openai".into(), Some("gpt-6-mini".into()), None));
        assert_eq!(pick(None, Some("gpt-6"), "codex"), ("codex".into(), Some("gpt-6".into()), None));
        assert_eq!(pick(None, Some("opus"), "codex"), ("claude".into(), Some("claude-opus-5-5".into()), None));
        assert_eq!(pick(Some("Codex"), Some("gpt-6-codex"), "claude"), ("codex".into(), Some("gpt-6-codex".into()), None));
        assert_eq!(pick(Some("Gemini"), None, "claude"), ("claude".into(), None, Some("there's no brain called Gemini set up here".into())));
        assert_eq!(pick(Some("Claude Code"), Some("Opus 4.1"), "claude"), ("claude".into(), None, Some("Claude Code has no model called Opus 4.1".into())));
    }

    #[test]
    fn the_owner_asking_for_models() {
        for words in ["switch Rex to Haiku", "Penny should use Opus 5.5", "run the workers on Codex"] {
            assert!(owner_asked(words), "{words}");
        }
    }

    #[test]
    fn a_squad_reads_in_one_line() {
        let mut squad = vec![MadeBot { name: "Boss".into(), category: Some("Squad".into()), model_words: "Claude Opus 5.5".into() }];
        squad.extend((1..=3).map(|n| MadeBot { name: format!("Digger {n}"), category: Some("Squad".into()), model_words: "Claude Haiku 5.5".into() }));
        assert_eq!(made_bots_sentence(&squad), "Vello made 4 bots in Squad: Boss on Claude Opus 5.5; Digger 1, Digger 2 and Digger 3 on Claude Haiku 5.5.");
        assert_eq!(made_bots_sentence(&[MadeBot { name: "Rex".into(), category: Some("Sales".into()), ..Default::default() }]), "Vello made the bot Rex in Sales.");
        let mixed = [MadeBot { name: "Ada".into(), category: Some("Growth".into()), ..Default::default() }, MadeBot { name: "Rex".into(), category: Some("Sales".into()), ..Default::default() }, MadeBot { name: "Bo".into(), ..Default::default() }];
        assert_eq!(made_bots_sentence(&mixed), "Vello made 3 bots: in Growth, Ada; in Sales, Rex; outside any category, Bo.");
        let loose = [MadeBot { name: "Ada".into(), ..Default::default() }, MadeBot { name: "Bo".into(), ..Default::default() }];
        assert_eq!(made_bots_sentence(&loose), "Vello made 2 bots: Ada and Bo.");
    }

    #[test]
    fn a_group_chat_with_a_head_and_members() {
        let order = parse(r#"{"groups": [{"name": "Launch room", "head": "Ada", "members": ["Rex", "Bo", "ada", "rex"]}]}"#).unwrap();
        assert_eq!(order.groups, vec![NewGroup { name: "Launch room".into(), head: Some("Ada".into()), members: vec!["Rex".into(), "Bo".into()] }]);
        assert!(order.bots.is_empty());
        assert!(parse(r#"{"groups": [{"name": "Alone", "head": "Ada"}]}"#).is_none());
        let crowd: Vec<String> = (1..=10).map(|n| format!("\"Bot {n}\"")).collect();
        let with_head = parse(&format!(r#"{{"groups": [{{"name": "Crowd", "head": "Boss", "members": [{}]}}]}}"#, crowd.join(","))).unwrap();
        assert_eq!(with_head.groups[0].members.len(), 5);
        let without_head = parse(&format!(r#"{{"groups": [{{"name": "Crowd", "members": [{}]}}]}}"#, crowd.join(","))).unwrap();
        assert_eq!(without_head.groups[0].members.len(), 6);
        let many: Vec<String> = (1..=10).map(|n| format!(r#"{{"name": "Room {n}", "members": ["Ada", "Rex"]}}"#)).collect();
        assert_eq!(parse(&format!(r#"{{"groups": [{}]}}"#, many.join(","))).unwrap().groups.len(), MOST_GROUPS);
    }

    #[test]
    fn a_bot_can_be_renamed_and_remember() {
        let order = parse(r#"{"bots": [{"name": "Rex", "rename": "Max", "memory": "The owner trades on NSE.\nUse NSE bhavcopy first."}, {"name": "Bo", "newName": "bo"}]}"#).unwrap();
        assert_eq!(order.bots[0].new_name.as_deref(), Some("Max"));
        assert_eq!(order.bots[0].memory.as_deref(), Some("The owner trades on NSE.\nUse NSE bhavcopy first."));
        assert_eq!(order.bots[1].new_name, None);
    }

    #[test]
    fn long_instructions_and_names_stay_whole() {
        let playbook = "Check the exchange's own data first, then two other sources.\n".repeat(400);
        assert!(playbook.len() > 20000);
        let name = "Global Super Digger Squad Lead for Commodities and Trade Data";
        let body = serde_json::json!({"bots": [{"name": name, "instructions": playbook}]}).to_string();
        let order = parse(&body).unwrap();
        assert_eq!(order.bots[0].name, name);
        assert_eq!(order.bots[0].instructions, playbook.trim());
        let capped = serde_json::json!({"bots": [{"name": "Ada", "instructions": "a".repeat(40000)}]}).to_string();
        assert_eq!(parse(&capped).unwrap().bots[0].instructions.chars().count(), LONGEST_INSTRUCTIONS);
    }

    #[test]
    fn memory_is_added_once() {
        assert_eq!(memory_adding("", "  Use NSE first. ").as_deref(), Some("Use NSE first.\n"));
        assert_eq!(memory_adding("Old line.\n", "Use NSE first.").as_deref(), Some("Old line.\n\nUse NSE first.\n"));
        assert_eq!(memory_adding("Old line.\n\nUse NSE first.\n", "Use NSE first."), None);
        assert_eq!(memory_adding("Old line.", "   "), None);
    }

    #[test]
    fn the_owner_asking_for_groups_renames_and_memory() {
        for words in ["make a group chat with Ada and Rex", "set up a group with the diggers", "rename Rex to Max",
                      "call Penny Ledger from now on", "change Rex's instructions", "give Ada a better prompt",
                      "update the digger's description", "fix the prompt of the squad", "save this to Rex's memory",
                      "Ada should remember that I trade on NSE", "add the sources to their memory"] {
            assert!(owner_asked(words), "{words}");
        }
        for words in ["what's in my memory?", "do you remember yesterday?", "summarise the group's day"] {
            assert!(!owner_asked(words), "{words}");
        }
        let text = how_to("the owner");
        for part in ["\"groups\": [{\"name\"", "\"rename\"", "\"memory\"", "30000 characters"] { assert!(text.contains(part), "{part}"); }
    }

    #[test]
    fn group_ids_from_names() {
        assert_eq!(group_slug("Launch Room!"), "launch-room");
        assert_eq!(group_slug("***"), "group");
    }
}
