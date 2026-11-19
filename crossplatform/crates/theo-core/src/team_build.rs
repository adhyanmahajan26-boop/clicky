//! The CEO makes new bots and categories when the owner asks for them in chat (the Mac's ClickyCore `TeamBuildOrder` and
//! `BotsStore.buildTeamFromChat`). The CEO writes one ```team block with JSON; Theo takes it out of the shown answer, checks
//! the owner's own words asked for new bots or categories, and makes them as the New bot dialog and New category row do.

use crate::harness::Harness;
use crate::model::{Bot, ChatMessage};
use crate::protocol;
use once_cell::sync::Lazy;
use regex::Regex;
use serde_json::Value;
use std::collections::HashMap;
use std::sync::Arc;

/// One owner message can't flood the sidebar: at most this many new bots and categories from one answer.
pub const MOST_BOTS: usize = 5;
pub const MOST_CATEGORIES: usize = 3;
const LONGEST_BOT_NAME: usize = 40;
const LONGEST_CATEGORY_NAME: usize = 80;
const LONGEST_DOES: usize = 200;
const LONGEST_INSTRUCTIONS: usize = 4000;

#[derive(Debug, Clone, PartialEq, Default)]
pub struct NewCategory {
    pub name: String,
    pub purpose: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Default)]
pub struct NewBot {
    pub name: String,
    /// One line on what it does: its description in the sidebar.
    pub does: String,
    /// Its own instructions. Empty: Theo writes "You are <name>. <does>".
    pub instructions: String,
    /// The category it joins, by name. None: it sits under "Other bots".
    pub category: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Default)]
pub struct TeamBuildOrder {
    pub categories: Vec<NewCategory>,
    pub bots: Vec<NewBot>,
}

impl TeamBuildOrder {
    pub fn is_empty(&self) -> bool { self.categories.is_empty() && self.bots.is_empty() }
}

/// What the CEO is told (ClickyCore `BotProtocol.teamBuildHowTo`).
pub fn how_to(owner: &str) -> String {
    format!(
        "New bots and categories: you can make them yourself. When {owner} asks for a new bot, agent, team or category, don't tell them to use a button and don't write files for it: say in a line what you'll make, then add one ```team block with JSON {{\"categories\": [{{\"name\": \"Marketing\", \"purpose\": \"one line\"}}], \"bots\": [{{\"name\": \"Ada\", \"does\": \"one line on its job\", \"instructions\": \"its full instructions, written to it as 'You are …'\", \"category\": \"Marketing\"}}]}}. Either list can be left out. A bot's category is made if it doesn't exist yet, and a bot that already exists is filed into it instead of made twice. At most {MOST_BOTS} bots and {MOST_CATEGORIES} categories at a time. Vello makes them and says so in the chat; never say they're made before that line shows. Only when {owner} asked for it in their own words."
    )
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

/// The JSON inside the block: {"categories": [{"name", "purpose"?}], "bots": [{"name", "does", "instructions"?, "category"?}]}.
pub fn parse(body: &str) -> Option<TeamBuildOrder> {
    let object: Value = serde_json::from_str(body.trim()).ok()?;
    let mut order = TeamBuildOrder::default();
    for entry in object.get("categories").and_then(|c| c.as_array()).into_iter().flatten() {
        let Some(name) = cleaned(entry.get("name"), LONGEST_CATEGORY_NAME) else { continue };
        if order.categories.iter().any(|c| same_name(&c.name, &name)) { continue; }
        order.categories.push(NewCategory { name, purpose: cleaned(entry.get("purpose"), LONGEST_DOES) });
    }
    for entry in object.get("bots").and_then(|b| b.as_array()).into_iter().flatten() {
        let Some(name) = cleaned(entry.get("name"), LONGEST_BOT_NAME) else { continue };
        if order.bots.iter().any(|b| same_name(&b.name, &name)) { continue; }
        let does = cleaned(entry.get("does").or(entry.get("description")), LONGEST_DOES).unwrap_or_default();
        let instructions = cleaned(entry.get("instructions"), LONGEST_INSTRUCTIONS).unwrap_or_default();
        let category = cleaned(entry.get("category"), LONGEST_CATEGORY_NAME);
        order.bots.push(NewBot { name, does, instructions, category });
    }
    // A bot's category that the block didn't list is made too, so "a bot in a new Sales category" works in one go.
    let wanted: Vec<String> = order.bots.iter().filter_map(|b| b.category.clone()).collect();
    for category in wanted {
        if !order.categories.iter().any(|c| same_name(&c.name, &category)) {
            order.categories.push(NewCategory { name: category, purpose: None });
        }
    }
    order.categories.truncate(MOST_CATEGORIES);
    order.bots.truncate(MOST_BOTS);
    if order.is_empty() { None } else { Some(order) }
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
        let things = r"(bots?|agents?|assistants?|categor(y|ies)|teams?|departments?|helpers?|employees?|members?)";
        [
            format!(r"\b(make|makes|making|made|create|creates|creating|add|adding|set\s+up|setup|build|start|spin\s+up|hire|need|want|get|give\s+me)\b[^.?!\n]{{0,60}}\b{things}\b"),
            format!(r"\b(new|another|more|extra)\s+([a-z-]+\s+){{0,3}}{things}\b"),
            r"\b(a|an)\s+([a-z-]+\s+){0,3}(bot|agent|assistant)\s+(that|which|who|for|to)\b".to_string(),
        ]
        .iter()
        .map(|p| Regex::new(p).unwrap())
        .collect()
    });
    let lower = text.to_lowercase();
    PATTERNS.iter().any(|re| re.is_match(&lower))
}

/// "A", "A and B", "A, B and C".
fn listed_in_words(items: &[String]) -> String {
    match items.len() {
        0 => String::new(),
        1 => items[0].clone(),
        n => format!("{} and {}", items[..n - 1].join(", "), items[n - 1]),
    }
}

/// Who may make bots and categories from chat: the CEO.
pub fn may_build(bot: &Bot) -> bool { bot.primary }

/// Carries out a ```team block from `maker`'s answer in `room`. Only the owner's own words asking for new bots or categories
/// let it through; anything else is said in the chat and dropped, as a routine block is.
pub async fn build_for_turn(h: &Arc<Harness>, maker: &Bot, order: TeamBuildOrder, room: &str, from_owner: bool) {
    let asked = from_owner && may_build(maker) && h.recent_owner_words(room).as_deref().map(owner_asked).unwrap_or(false);
    if !asked {
        h.post(ChatMessage::note(format!("{} wrote new bots or categories, but they weren't asked for in your own words here, so Vello didn't make them. Ask for them yourself if you want them.", maker.name)), room);
        return;
    }
    let mut made_categories: Vec<String> = vec![];
    let mut made_bots: Vec<String> = vec![];
    let mut filed: Vec<String> = vec![];

    // Categories first, so the bots can join them. One with the same name is used rather than made twice.
    let mut category_ids: HashMap<String, String> = HashMap::new();
    for wanted in &order.categories {
        if let Some(existing) = h.layout().sections.iter().find(|s| same_name(&s.name, &wanted.name)) {
            category_ids.insert(wanted.name.to_lowercase(), existing.id.clone());
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
    let provider = maker.provider.clone();
    let model = match crate::brains::api_provider_id(&provider) {
        Some(provider_id) => crate::brains::model_for_new_bot(h, provider_id).await.unwrap_or_else(|| maker.model.clone()),
        None => crate::brains::command_line_brain(&provider).map(|brain| brain.default_model.to_string()).unwrap_or_default(),
    };
    for wanted in &order.bots {
        let category_id = wanted.category.as_ref().and_then(|c| category_ids.get(&c.to_lowercase()).cloned());
        let in_words = wanted.category.as_ref().map(|c| format!(" in {c}")).unwrap_or_default();
        if let Some(existing) = h.bots().into_iter().find(|b| same_name(&b.name, &wanted.name)) {
            // Already there: filed into its category rather than made a second time. The CEO stays on top.
            if let Some(id) = category_id.as_deref().filter(|_| !existing.primary) {
                h.change_layout(|layout, bots| { if let Some(s) = layout.section_mut(id) { s.add_member(&existing.id, bots) } });
                filed.push(format!("{} was already here, so it's now{in_words}", existing.name));
            }
            continue;
        }
        let description = if wanted.does.is_empty() { format!("Your {} bot.", wanted.name) } else { wanted.does.clone() };
        let bot = h.add_bot(Bot::new(&wanted.name, &description, &instructions_for(wanted), &provider, &model));
        if let Some(id) = category_id.as_deref() {
            h.change_layout(|layout, bots| { if let Some(s) = layout.section_mut(id) { s.add_member(&bot.id, bots) } });
        }
        made_bots.push(format!("{}{in_words}", bot.name));
    }

    let mut sentences: Vec<String> = vec![];
    if !made_bots.is_empty() {
        sentences.push(format!("Vello made {} {}.", if made_bots.len() == 1 { "the bot" } else { "the bots" }, listed_in_words(&made_bots)));
    }
    if !made_categories.is_empty() {
        sentences.push(format!("New {} {}.", if made_categories.len() == 1 { "category:" } else { "categories:" }, listed_in_words(&made_categories)));
    }
    sentences.extend(filed.into_iter().map(|f| format!("{f}.")));
    if sentences.is_empty() {
        sentences.push(format!("Everything {} asked for was already here, so Vello didn't make anything new.", maker.name));
    } else if !made_bots.is_empty() {
        sentences.push("They're in the sidebar, and each one's settings can change its brain, model and apps.".into());
    }
    h.post(ChatMessage::note(sentences.join(" ")), room);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn takes_the_block_out_and_reads_it() {
        let answer = "I'll set up a Marketing team with a writer.\n```team\n{\"categories\": [{\"name\": \"Marketing\", \"purpose\": \"Launch posts\"}],\n \"bots\": [{\"name\": \"Ada\", \"does\": \"Writes launch posts\", \"category\": \"Marketing\"}]}\n```";
        let (shown, order) = extract(answer);
        assert_eq!(shown, "I'll set up a Marketing team with a writer.");
        let order = order.unwrap();
        assert_eq!(order.categories, vec![NewCategory { name: "Marketing".into(), purpose: Some("Launch posts".into()) }]);
        assert_eq!(order.bots, vec![NewBot { name: "Ada".into(), does: "Writes launch posts".into(), instructions: String::new(), category: Some("Marketing".into()) }]);
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
        let bots: Vec<String> = (1..=9).map(|n| format!(r#"{{"name": "Bot {n}"}}"#)).collect();
        let categories: Vec<String> = (1..=6).map(|n| format!(r#"{{"name": "Team {n}"}}"#)).collect();
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
    fn the_ceo_is_told_how() {
        let text = how_to("the owner");
        assert!(text.contains("```team"));
        assert!(text.contains("\"bots\": [{\"name\": \"Ada\""));
    }
}
