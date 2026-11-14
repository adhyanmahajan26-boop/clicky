//! The safety rule: what a tool does to the world, decided from the tool's own hints when it gives them and from its name
//! otherwise, and whether a bot's level lets it run.
//!
//! The word lists are the ones the Mac app already uses (`ConnectorBridge.writeTools` and `BotRunner.irreversibleTools`
//! in `leanring-buddy`): sending, replying, forwarding, deleting, sharing, spam and cancelling can't be taken back; drafts,
//! new pages and labels can. A tool whose name says nothing either way counts as a change, so a `read` bot never runs it.

use crate::model::{AccessLevel, ToolEffect};

/// Words in a tool's name that mean it can't be taken back. "clear" is here because the Mac app already counts
/// `batch_clear_values` among the tools a bot never runs on its own.
const IRREVERSIBLE_WORDS: &[&str] = &[
    "send", "reply", "forward", "trash", "delete", "remove", "destroy", "purge", "spam", "share", "unshare", "cancel", "clear",
    "publish", "post", "invite", "pay", "charge", "refund", "transfer", "merge", "revoke", "archive", "wipe", "drop", "kill",
    "terminate", "execute", "run", "deploy", "submit", "approve", "reject", "close",
];

/// Words that mean it writes something that can be looked at and undone.
const CHANGE_WORDS: &[&str] = &[
    "create", "update", "edit", "write", "add", "insert", "append", "set", "put", "patch", "move", "copy", "duplicate", "rename",
    "label", "unlabel", "mark", "unmark", "apply", "upload", "save", "modify", "draft", "comment", "assign", "tag", "untag",
    "star", "unstar", "pin", "unpin", "schedule", "book", "batch", "import", "restore", "untrash", "complete", "upsert", "make",
    "new", "change", "toggle", "enable", "disable", "start", "stop", "convert", "link", "resolve", "reopen",
];

/// Words that mean it looks something up.
const READ_WORDS: &[&str] = &[
    "get", "list", "search", "read", "fetch", "query", "find", "view", "show", "describe", "lookup", "download", "export",
    "count", "check", "status", "info", "whoami", "self", "me", "browse", "inspect", "preview", "retrieve", "peek",
];

/// Splits `notion-calendar-list-events`, `search_threads` or `getFileMetadata` into its lowercase words.
pub fn words_in_tool_name(tool_name: &str) -> Vec<String> {
    let mut words = vec![];
    let mut current_word = String::new();
    let mut previous_character_was_lowercase = false;
    for character in tool_name.chars() {
        if !character.is_ascii_alphanumeric() {
            if !current_word.is_empty() {
                words.push(std::mem::take(&mut current_word));
            }
            previous_character_was_lowercase = false;
            continue;
        }
        if character.is_ascii_uppercase() && previous_character_was_lowercase && !current_word.is_empty() {
            words.push(std::mem::take(&mut current_word));
        }
        previous_character_was_lowercase = character.is_ascii_lowercase() || character.is_ascii_digit();
        current_word.push(character.to_ascii_lowercase());
    }
    if !current_word.is_empty() {
        words.push(current_word);
    }
    words
}

/// What a tool does, from the MCP annotations the server gave (`readOnlyHint`, `destructiveHint`) and its name.
///
/// A server's `readOnlyHint: true` is believed only when the name doesn't say the opposite, since a hint is the server's
/// word and the name is the plainer evidence. MCP says `destructiveHint` defaults to true, but almost no server sets it,
/// so only an explicit `true` counts.
pub fn tool_effect(tool_name: &str, annotations: Option<&serde_json::Value>) -> ToolEffect {
    let words = words_in_tool_name(tool_name);
    let name_says_irreversible = words.iter().any(|word| IRREVERSIBLE_WORDS.contains(&word.as_str()));
    // Otherwise the first verb decides: `get_draft` reads a draft, `create_draft` makes one.
    let first_verb = words.iter().find(|word| CHANGE_WORDS.contains(&word.as_str()) || READ_WORDS.contains(&word.as_str()));
    let name_says_change = first_verb.map(|word| CHANGE_WORDS.contains(&word.as_str())).unwrap_or(false);
    let name_says_read = first_verb.map(|word| READ_WORDS.contains(&word.as_str())).unwrap_or(false);

    let read_only_hint = annotations.and_then(|value| value.get("readOnlyHint")).and_then(|value| value.as_bool());
    let destructive_hint = annotations.and_then(|value| value.get("destructiveHint")).and_then(|value| value.as_bool());

    if name_says_irreversible {
        return ToolEffect::Irreversible;
    }
    if read_only_hint == Some(true) && !name_says_change {
        return ToolEffect::Reads;
    }
    if read_only_hint == Some(false) && destructive_hint == Some(true) {
        return ToolEffect::Irreversible;
    }
    if name_says_change {
        return ToolEffect::Changes;
    }
    if read_only_hint == Some(true) || (name_says_read && read_only_hint != Some(false)) {
        return ToolEffect::Reads;
    }
    ToolEffect::Changes
}

/// The level a bot really gets for one app in one turn: never more than `readAndDraft` when the turn didn't come from
/// the owner's own words (a routine, another bot, the local API). Sending, sharing and deleting take the owner's own
/// words; looking things up and drafting carry on, so a routine can still write its draft or its page.
pub fn effective_level(granted_level: AccessLevel, turn_came_from_owner: bool) -> AccessLevel {
    if turn_came_from_owner {
        granted_level
    } else {
        granted_level.min(AccessLevel::ReadAndDraft)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn names_split_into_words() {
        assert_eq!(words_in_tool_name("notion-calendar-list-events"), ["notion", "calendar", "list", "events"]);
        assert_eq!(words_in_tool_name("getFileMetadata"), ["get", "file", "metadata"]);
        assert_eq!(words_in_tool_name("search_threads"), ["search", "threads"]);
    }

    #[test]
    fn the_mac_apps_gmail_and_notion_lists_classify_the_same_way() {
        // ConnectorBridge.apps (reading tools, plus create_draft).
        for tool in ["search_threads", "get_thread", "get_message", "list_labels", "list_drafts", "get_draft", "notion-search",
                     "notion-fetch", "notion-query-data-sources", "notion-get-comments", "notion-get-self", "notion-list-recent-pages",
                     "notion-calendar-list-events", "search_files", "read_file_content", "get_file_metadata", "read_doc",
                     "get_spreadsheet", "get_values", "list_shared_drives", "get_shared_drive_metadata"] {
            assert_eq!(tool_effect(tool, None), ToolEffect::Reads, "{tool}");
        }
        assert_eq!(tool_effect("create_draft", None), ToolEffect::Changes);
        // ConnectorBridge.writeTools that BotRunner.irreversibleTools lets through: changes.
        for tool in ["create_label", "update_label", "label_message", "unlabel_thread", "update_draft", "notion-create-pages",
                     "notion-update-page", "notion-move-pages", "notion-duplicate-page", "notion-create-comment", "create_file",
                     "update_file", "copy_file", "update_doc", "append_values", "update_values", "insert_dimension",
                     "notion-calendar-create-events", "notion-calendar-update-events", "apply_sensitive_message_label"] {
            assert_eq!(tool_effect(tool, None), ToolEffect::Changes, "{tool}");
        }
        // BotRunner.irreversibleTools: never without `full`.
        for tool in ["send_message", "reply", "forward", "trash_message", "trash_thread", "delete_draft", "delete_label",
                     "mark_message_spam", "mark_thread_spam", "notion-delete-pages", "notion-delete-databases", "notion-delete-comment",
                     "notion-calendar-cancel-events", "trash_file", "share_file", "batch_clear_values"] {
            assert_eq!(tool_effect(tool, None), ToolEffect::Irreversible, "{tool}");
        }
    }

    #[test]
    fn hints_are_used_but_names_win() {
        assert_eq!(tool_effect("lookup_weather", Some(&json!({"readOnlyHint": true}))), ToolEffect::Reads);
        assert_eq!(tool_effect("frobnicate", Some(&json!({"readOnlyHint": true}))), ToolEffect::Reads);
        assert_eq!(tool_effect("frobnicate", None), ToolEffect::Changes);
        assert_eq!(tool_effect("frobnicate", Some(&json!({"readOnlyHint": false, "destructiveHint": true}))), ToolEffect::Irreversible);
        // A server calling its sender read-only is not believed.
        assert_eq!(tool_effect("send_email", Some(&json!({"readOnlyHint": true}))), ToolEffect::Irreversible);
        assert_eq!(tool_effect("create_issue", Some(&json!({"readOnlyHint": true}))), ToolEffect::Changes);
        assert_eq!(tool_effect("get_thing", Some(&json!({"readOnlyHint": false}))), ToolEffect::Changes);
    }

    #[test]
    fn a_turn_not_from_the_owner_reads_and_drafts_at_most() {
        assert_eq!(effective_level(AccessLevel::Full, false), AccessLevel::ReadAndDraft);
        assert_eq!(effective_level(AccessLevel::ReadAndDraft, false), AccessLevel::ReadAndDraft);
        assert_eq!(effective_level(AccessLevel::Read, false), AccessLevel::Read);
        assert_eq!(effective_level(AccessLevel::Full, true), AccessLevel::Full);
    }
}
