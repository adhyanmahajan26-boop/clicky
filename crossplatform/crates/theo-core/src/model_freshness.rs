//! Keeping model choices current without a new build: a port of the Mac's ClickyCore `Settings/ModelFreshness.swift` and
//! the app's `ModelFreshnessController`.
//!
//! - `VersionShape` / `newer_model`: which id is the same model family at a newer version ("claude-sonnet-5" →
//!   "claude-sonnet-5-5", "claude-opus-4-8" → "claude-opus-5-5", "grok-4.6" → "grok-4.7"). Never across families (Sonnet
//!   never becomes Opus, a mini never becomes the full model), never onto a dated snapshot or a preview, and a model pinned
//!   to a snapshot is left alone.
//! - `chat_models`: a provider's list without embeddings, voices or images, each family's newest first.
//! - `claude_fast_mode`: which Claude models fast mode runs on (Windows and Linux have no fast mode switch yet).
//! - `keep_models_current`: at start and every 12 hours, each bot on Claude Code or an API key moves onto the newest model
//!   of its family that's offered, when "Keep models up to date" (`v4.models.autoUpgrade`, default on) is on.

use crate::harness::Harness;
use serde_json::{json, Value};
use std::collections::{HashMap, HashSet};
use std::sync::Arc;
use std::time::Duration;

pub const AUTO_UPGRADE_SETTING: &str = "v4.models.autoUpgrade";
pub const HISTORY_SETTING: &str = "v4.models.upgradeHistory";
pub const LAST_CHECK_SETTING: &str = "v4.models.lastFreshnessCheck";
const CHECK_EVERY_SECS: i64 = 12 * 3600;

/// A model id read as a family plus version numbers.
#[derive(Clone, Debug, PartialEq)]
pub struct VersionShape {
    /// The id with each version written as "#": "claude-sonnet-#", "gpt-#-mini", "grok-#-build-fast".
    pub family: String,
    /// Each version in order: "grok-4.7-build-fast" → [[4, 7]], "qwen3-235b" → [[3], [235]].
    pub versions: Vec<Vec<u64>>,
    /// Ends in a dated snapshot ("-20250929", "-2024-08-06", "-1017").
    pub is_snapshot: bool,
    /// A preview, experimental, alpha or beta build.
    pub is_preview: bool,
}

impl VersionShape {
    pub fn read(model_id: &str) -> Option<VersionShape> {
        let lowered = model_id.trim().to_lowercase();
        if lowered.is_empty() {
            return None;
        }
        // The part before the last slash is kept as it is, so providers never mix.
        let (mut family, name) = match lowered.rfind('/') {
            Some(slash) => (lowered[..=slash].to_string(), lowered[slash + 1..].to_string()),
            None => (String::new(), lowered.clone()),
        };
        // Tokens are runs of letters and digits; everything else separates them.
        let mut tokens: Vec<(String, String)> = Vec::new();
        let mut current_token = String::new();
        let mut current_separator = String::new();
        for character in name.chars() {
            if character.is_alphanumeric() {
                current_token.push(character);
            } else {
                if !current_token.is_empty() {
                    tokens.push((std::mem::take(&mut current_token), std::mem::take(&mut current_separator)));
                }
                current_separator.push(character);
            }
        }
        let trailing_separator = if current_token.is_empty() { current_separator.clone() } else { String::new() };
        if !current_token.is_empty() {
            tokens.push((current_token, current_separator));
        }

        let mut versions: Vec<Vec<u64>> = Vec::new();
        let mut version_is_open = false;
        let mut is_snapshot = false;
        let mut is_preview = false;
        for (token, separator_before) in &tokens {
            if ["preview", "exp", "experimental", "alpha", "beta"].contains(&token.as_str()) {
                is_preview = true;
            }
            // A long number is a date or build stamp: a snapshot, and nothing after it counts.
            if token.chars().all(|c| c.is_ascii_digit()) && token.len() >= 4 {
                is_snapshot = true;
                break;
            }
            // Letter and digit chunks: "qwen3" → qwen, 3; "4o" → 4, o; "235b" → 235, b.
            let mut chunks: Vec<String> = Vec::new();
            for character in token.chars() {
                let is_digit = character.is_ascii_digit();
                match chunks.last_mut() {
                    Some(last) if last.chars().last().map(|c| c.is_ascii_digit()) == Some(is_digit) => last.push(character),
                    _ => chunks.push(character.to_string()),
                }
            }
            let mut pending_separator = separator_before.clone();
            let chunk_count = chunks.len();
            for (chunk_index, chunk) in chunks.iter().enumerate() {
                let is_first_chunk = chunk_index == 0;
                if let Ok(number) = chunk.parse::<u64>() {
                    // Only a token that is all digits carries a version on ("5-5", "4.1").
                    let continues = is_first_chunk && chunk_count == 1 && version_is_open && (pending_separator == "-" || pending_separator == ".");
                    if continues {
                        if let Some(last) = versions.last_mut() {
                            last.push(number);
                        }
                    } else {
                        if is_first_chunk {
                            family.push_str(&pending_separator);
                        }
                        family.push('#');
                        versions.push(vec![number]);
                    }
                    version_is_open = true;
                } else {
                    if is_first_chunk {
                        family.push_str(&pending_separator);
                    }
                    family.push_str(chunk);
                    version_is_open = false;
                }
                pending_separator.clear();
            }
        }
        if !is_snapshot {
            family.push_str(&trailing_separator);
        }
        Some(VersionShape { family, versions, is_snapshot, is_preview })
    }
}

/// Compares two versions part by part; a missing part counts as 0.
pub fn compare_versions(left: &[u64], right: &[u64]) -> std::cmp::Ordering {
    for index in 0..left.len().max(right.len()) {
        let l = left.get(index).copied().unwrap_or(0);
        let r = right.get(index).copied().unwrap_or(0);
        if l != r {
            return l.cmp(&r);
        }
    }
    std::cmp::Ordering::Equal
}

/// The newest id in `available` of the same family as `current` at a higher version, or None. Only the first version may change.
pub fn newer_model(current: &str, available: &[String]) -> Option<String> {
    let current_shape = VersionShape::read(current)?;
    if current_shape.is_snapshot {
        return None;
    }
    let current_first = current_shape.versions.first()?.clone();
    let mut best: Option<(String, Vec<u64>)> = None;
    for candidate in available {
        if candidate.eq_ignore_ascii_case(current) {
            continue;
        }
        let Some(shape) = VersionShape::read(candidate) else { continue };
        if shape.family != current_shape.family || shape.is_snapshot || (shape.is_preview && !current_shape.is_preview)
            || shape.versions.len() != current_shape.versions.len() || shape.versions[1..] != current_shape.versions[1..] {
            continue;
        }
        let first = shape.versions[0].clone();
        if compare_versions(&first, &current_first) != std::cmp::Ordering::Greater {
            continue;
        }
        if let Some((_, chosen)) = &best {
            if compare_versions(&first, chosen) != std::cmp::Ordering::Greater {
                continue;
            }
        }
        best = Some((candidate.clone(), first));
    }
    best.map(|(id, _)| id)
}

/// The same ids, each family's newest first, families in the order they first appear; snapshots and previews last in their family.
pub fn newest_first(ids: &[String]) -> Vec<String> {
    let mut family_order: Vec<String> = Vec::new();
    let mut members: HashMap<String, Vec<(String, Option<VersionShape>, usize)>> = HashMap::new();
    for (position, id) in ids.iter().enumerate() {
        let shape = VersionShape::read(id);
        let key = shape.as_ref().map(|s| s.family.clone()).unwrap_or_else(|| format!("\u{0}{id}"));
        if !members.contains_key(&key) {
            family_order.push(key.clone());
        }
        members.entry(key).or_default().push((id.clone(), shape, position));
    }
    let mut ordered = Vec::new();
    for key in family_order {
        let mut group = members.remove(&key).unwrap_or_default();
        group.sort_by(|left, right| {
            let pinned = |shape: &Option<VersionShape>| shape.as_ref().map(|s| s.is_snapshot || s.is_preview).unwrap_or(false);
            let (left_pinned, right_pinned) = (pinned(&left.1), pinned(&right.1));
            if left_pinned != right_pinned {
                return left_pinned.cmp(&right_pinned);
            }
            let version = |shape: &Option<VersionShape>| shape.as_ref().and_then(|s| s.versions.first().cloned()).unwrap_or_default();
            compare_versions(&version(&right.1), &version(&left.1)).then(left.2.cmp(&right.2))
        });
        ordered.extend(group.into_iter().map(|(id, _, _)| id));
    }
    ordered
}

/// Words in ids that are never for chatting (the same list as `brains::is_chat_model`, and the Mac's `ModelListFilter`).
pub fn is_chat_model(model: &str) -> bool {
    let lower = model.to_lowercase();
    !["embed", "whisper", "tts", "dall-e", "image", "moderation", "audio", "transcribe", "rerank", "search", "realtime", "speech",
      "guard", "sora", "davinci", "babbage", "computer-use"]
        .iter()
        .any(|word| lower.contains(word))
}

/// A provider's chat models without repeats, each family's newest first.
pub fn chat_models(ids: &[String]) -> Vec<String> {
    let mut seen = HashSet::new();
    let unique: Vec<String> = ids.iter().filter(|id| is_chat_model(id) && seen.insert((*id).clone())).cloned().collect();
    newest_first(&unique)
}

/// Whether fast mode runs on this Claude model: Opus 5 and newer, Fable and Mythos 5.2 and newer.
pub fn claude_fast_mode(model: &str) -> bool {
    let Some(shape) = VersionShape::read(model) else { return false };
    let Some(version) = shape.versions.first() else { return false };
    if shape.is_snapshot {
        return false;
    }
    let bare = shape.family.rsplit('/').next().unwrap_or(&shape.family);
    match bare {
        "claude-opus-#" => compare_versions(version, &[5]) != std::cmp::Ordering::Less,
        "claude-fable-#" | "claude-mythos-#" => compare_versions(version, &[5, 2]) != std::cmp::Ordering::Less,
        _ => false,
    }
}

pub fn is_on(h: &Harness) -> bool {
    h.settings.get(AUTO_UPGRADE_SETTING).map(|_| h.settings.bool(AUTO_UPGRADE_SETTING)).unwrap_or(true)
}

/// What was moved, newest first.
pub fn history(h: &Harness) -> Vec<Value> {
    h.settings.get(HISTORY_SETTING).and_then(|v| v.as_array().cloned()).unwrap_or_default()
}

fn record(h: &Harness, lines: &[String]) {
    if lines.is_empty() {
        return;
    }
    let at = chrono::Utc::now().to_rfc3339();
    let mut entries: Vec<Value> = lines.iter().map(|line| json!({"at": at, "line": line})).collect();
    entries.extend(history(h));
    entries.truncate(30);
    h.settings.set(HISTORY_SETTING, Value::Array(entries));
}

/// The models offered for an engine here: Claude Code's list, or an API key's live chat models. None when there's no list.
async fn offered(h: &Harness, engine: &str, lists: &mut HashMap<String, Vec<String>>) -> Option<Vec<String>> {
    if let Some(known) = lists.get(engine) {
        return Some(known.clone());
    }
    let models = if engine == "claude" {
        crate::team_build::CLAUDE_MODELS.iter().map(|(id, _)| id.to_string()).collect()
    } else if let Some(provider) = engine.strip_prefix("api:") {
        chat_models(&crate::brains::list_models(h, provider).await.ok()?)
    } else {
        return None;
    };
    lists.insert(engine.to_string(), models.clone());
    Some(models)
}

/// Moves each bot onto the newest model of its family that's offered here. Returns the lines it recorded.
pub async fn upgrade_bots(h: &Arc<Harness>) -> Vec<String> {
    if !is_on(h) {
        return Vec::new();
    }
    let mut lists: HashMap<String, Vec<String>> = HashMap::new();
    let mut moved = Vec::new();
    for bot in h.bots() {
        if bot.model.is_empty() {
            continue;
        }
        let Some(models) = offered(h, &bot.provider, &mut lists).await else { continue };
        let Some(newer) = newer_model(&bot.model, &models) else { continue };
        moved.push(format!("{}: {} → {}", bot.name, bot.model, newer));
        let mut edited = bot.clone();
        edited.model = newer;
        h.save_bot(edited);
    }
    record(h, &moved);
    moved
}

/// One check: the lists are asked for again (each call to `list_models` is live) and the bots moved; the time is kept.
pub async fn check_now(h: &Arc<Harness>) -> Vec<String> {
    let moved = upgrade_bots(h).await;
    h.settings.set(LAST_CHECK_SETTING, json!(chrono::Utc::now().to_rfc3339()));
    moved
}

fn check_is_due(h: &Harness) -> bool {
    let Some(last) = h.settings.string(LAST_CHECK_SETTING).and_then(|text| chrono::DateTime::parse_from_rfc3339(&text).ok()) else { return true };
    let age = chrono::Utc::now().signed_duration_since(last.with_timezone(&chrono::Utc)).num_seconds();
    !(0..CHECK_EVERY_SECS).contains(&age)
}

/// From start: a check shortly after, then every hour whether 12 hours have passed. Not in a test profile (its tests ask).
pub fn start(h: &Arc<Harness>) {
    if h.settings.is_test {
        return;
    }
    let me = h.clone();
    tokio::spawn(async move {
        tokio::time::sleep(Duration::from_secs(8)).await;
        loop {
            if check_is_due(&me) {
                let moved = check_now(&me).await;
                if !moved.is_empty() {
                    eprintln!("[theo] moved {} bot(s) onto newer models", moved.len());
                }
            }
            tokio::time::sleep(Duration::from_secs(3600)).await;
        }
    });
}

/// For the `models` control command and Settings.
pub fn report(h: &Harness) -> Value {
    json!({
        "keepsModelsCurrent": is_on(h),
        "claudeModels": crate::team_build::CLAUDE_MODELS.iter().map(|(id, _)| *id).collect::<Vec<_>>(),
        "lastCheck": h.settings.string(LAST_CHECK_SETTING),
        "moved": history(h),
        "bots": h.bots().iter().map(|b| json!({"id": b.id, "provider": b.provider, "model": b.model})).collect::<Vec<_>>(),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ids(list: &[&str]) -> Vec<String> { list.iter().map(|s| s.to_string()).collect() }

    #[test]
    fn ids_read_as_a_family_and_versions() {
        let sonnet = VersionShape::read("claude-sonnet-5-5").unwrap();
        assert_eq!(sonnet.family, "claude-sonnet-#");
        assert_eq!(sonnet.versions, vec![vec![5, 5]]);
        assert_eq!(VersionShape::read("grok-4.7-build-fast").unwrap().family, "grok-#-build-fast");
        assert_eq!(VersionShape::read("gpt-4o-mini").unwrap().family, "gpt-#o-mini");
        assert_eq!(VersionShape::read("qwen3-235b").unwrap().versions, vec![vec![3], vec![235]]);
        assert!(VersionShape::read("claude-sonnet-4-5-20250929").unwrap().is_snapshot);
        assert_eq!(VersionShape::read("gpt-4o-2024-08-06").unwrap().family, "gpt-#o");
        assert!(VersionShape::read("gemini-3-flash-preview").unwrap().is_preview);
    }

    #[test]
    fn a_model_moves_only_to_a_newer_one_of_its_own_family() {
        let claude = ids(&["claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5", "claude-fable-5-2", "claude-opus-4-8"]);
        assert_eq!(newer_model("claude-sonnet-5", &claude).as_deref(), Some("claude-sonnet-5-5"));
        assert_eq!(newer_model("claude-opus-4-8", &claude).as_deref(), Some("claude-opus-5-5"));
        assert_eq!(newer_model("claude-fable-5-1", &claude).as_deref(), Some("claude-fable-5-2"));
        assert_eq!(newer_model("claude-sonnet-5-5", &claude), None);
        assert_eq!(newer_model("gpt-6-mini", &ids(&["gpt-6.1", "gpt-7"])), None);
        assert_eq!(newer_model("gpt-6", &ids(&["gpt-6.1-mini", "gpt-6.1"])).as_deref(), Some("gpt-6.1"));
        assert_eq!(newer_model("grok-4.6", &ids(&["grok-4.7-build-fast", "grok-4.7"])).as_deref(), Some("grok-4.7"));
        assert_eq!(newer_model("qwen3-235b", &ids(&["qwen4-30b"])), None);
        assert_eq!(newer_model("gemini-2.5-flash", &ids(&["gemini-3-flash-preview"])), None);
        assert_eq!(newer_model("gpt-6", &ids(&["gpt-6.1-2026-10-01"])), None);
        assert_eq!(newer_model("claude-sonnet-4-5-20250929", &claude), None);
    }

    #[test]
    fn lists_put_chat_models_newest_first() {
        let listed = ids(&["gpt-6", "text-embedding-3-large", "gpt-4o-mini-tts", "whisper-1", "gpt-image-1", "gpt-6.1"]);
        assert_eq!(chat_models(&listed), ids(&["gpt-6.1", "gpt-6"]));
        assert_eq!(newest_first(&ids(&["grok-4.5", "grok-4.7", "grok-4.6"])), ids(&["grok-4.7", "grok-4.6", "grok-4.5"]));
    }

    #[test]
    fn fast_mode_is_for_opus_and_fable() {
        assert!(claude_fast_mode("claude-opus-5-5"));
        assert!(claude_fast_mode("claude-fable-5-2"));
        assert!(!claude_fast_mode("claude-fable-5-1"));
        assert!(!claude_fast_mode("claude-opus-4-8"));
        assert!(!claude_fast_mode("claude-sonnet-5-5"));
    }
}
