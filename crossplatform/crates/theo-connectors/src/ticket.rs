//! Tickets: how the hub knows which bot is calling without taking the bot's word for it.
//!
//! Before each bot turn the app writes a small private file into `Connectors/tickets/` (or asks the hub to, with
//! `ticket issue`): the bot, the apps it may use with a level for each, whether the turn came from the owner's own words,
//! and when the ticket stops working. The app starts the brain with `serve --ticket <that file>` and deletes the file
//! when the turn ends. The hub reads the ticket again on every tool call, so a deleted or expired ticket stops a turn
//! that is still running.
//!
//! What a ticket can't do: stop a program that runs as the same user and writes its own ticket. That is the apps' job
//! (bots are not allowed to write into Theo's own folder), and why the hub refuses a ticket anywhere but that folder.

use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use crate::files::{create_private_folder, write_json_file, HubPaths};
use crate::model::AccessLevel;
use crate::safety::effective_level;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Ticket {
    pub bot_id: String,
    /// App id → the most this bot may do with it.
    pub apps: BTreeMap<String, AccessLevel>,
    /// True only when the turn came from the owner's own words. Otherwise every app is `readAndDraft` at most.
    pub owner_asked: bool,
    /// When the ticket stops working (RFC 3339).
    pub expires_at: String,
}

impl Ticket {
    pub fn is_expired(&self) -> bool {
        match chrono::DateTime::parse_from_rfc3339(&self.expires_at) {
            Ok(expires_at) => expires_at.with_timezone(&chrono::Utc) <= chrono::Utc::now(),
            Err(_) => true,
        }
    }

    /// The level this turn really has for an app, or None when the bot wasn't given it.
    pub fn level_for(&self, app_id: &str) -> Option<AccessLevel> {
        self.apps.get(app_id).map(|granted_level| effective_level(*granted_level, self.owner_asked))
    }

    /// True when the bot's own level for the app would have let this tool run, and it's held back only because the turn
    /// didn't come from the owner's own words. The refusal says so, so the bot can tell the owner what to ask for.
    pub fn is_held_back_only_because_owner_did_not_ask(&self, app_id: &str, tool_effect: crate::model::ToolEffect) -> bool {
        match self.apps.get(app_id) {
            Some(granted_level) => !self.owner_asked && granted_level.allows(tool_effect),
            None => false,
        }
    }
}

/// Reads a ticket for use, refusing one that is missing, outside the hub's ticket folder, unreadable or expired.
pub fn load_ticket(paths: &HubPaths, ticket_file: &Path) -> Result<Ticket, String> {
    let ticket_folder = paths.ticket_folder();
    let canonical_folder = std::fs::canonicalize(&ticket_folder).map_err(|_| "No ticket for this turn: the bot's apps are off.".to_string())?;
    let canonical_file = std::fs::canonicalize(ticket_file).map_err(|_| "No ticket for this turn (it ended, or was never written): the bot's apps are off.".to_string())?;
    if canonical_file.parent() != Some(canonical_folder.as_path()) {
        return Err("That ticket isn't one Theo wrote: the bot's apps are off.".into());
    }
    let bytes = std::fs::read(&canonical_file).map_err(|_| "The ticket for this turn can't be read: the bot's apps are off.".to_string())?;
    let ticket: Ticket = serde_json::from_slice(&bytes).map_err(|_| "The ticket for this turn is damaged: the bot's apps are off.".to_string())?;
    if ticket.is_expired() {
        return Err("The ticket for this turn has expired: the bot's apps are off.".into());
    }
    Ok(ticket)
}

/// Writes a ticket into the ticket folder and returns its path. Apps can also write the file themselves, in the same
/// shape, as long as it lands in the same folder.
pub fn issue_ticket(paths: &HubPaths, ticket: &Ticket) -> Result<PathBuf, String> {
    let ticket_folder = paths.ticket_folder();
    create_private_folder(&ticket_folder).map_err(|error| format!("Couldn't make the ticket folder: {error}"))?;
    let safe_bot_id: String = ticket.bot_id.chars().map(|c| if c.is_ascii_alphanumeric() || c == '-' { c } else { '_' }).take(40).collect();
    let ticket_file = ticket_folder.join(format!("{safe_bot_id}-{}.json", uuid::Uuid::new_v4().simple()));
    write_json_file(&ticket_file, ticket).map_err(|error| format!("Couldn't write the ticket: {error}"))?;
    Ok(ticket_file)
}

/// Deletes a ticket. Only files inside the ticket folder are ever deleted.
pub fn revoke_ticket(paths: &HubPaths, ticket_file: &Path) -> Result<(), String> {
    let Ok(canonical_file) = std::fs::canonicalize(ticket_file) else { return Ok(()) };
    let canonical_folder = std::fs::canonicalize(paths.ticket_folder()).map_err(|error| error.to_string())?;
    if canonical_file.parent() != Some(canonical_folder.as_path()) {
        return Err("That file isn't a ticket.".into());
    }
    std::fs::remove_file(&canonical_file).map_err(|error| format!("Couldn't delete the ticket: {error}"))
}

/// Removes tickets that expired more than an hour ago (left behind by an app that crashed mid-turn).
pub fn remove_stale_tickets(paths: &HubPaths) {
    let Ok(entries) = std::fs::read_dir(paths.ticket_folder()) else { return };
    let an_hour_ago = chrono::Utc::now() - chrono::Duration::hours(1);
    for entry in entries.flatten() {
        let file = entry.path();
        if file.extension().and_then(|extension| extension.to_str()) != Some("json") {
            continue;
        }
        let expired_long_ago = std::fs::read(&file)
            .ok()
            .and_then(|bytes| serde_json::from_slice::<Ticket>(&bytes).ok())
            .and_then(|ticket| chrono::DateTime::parse_from_rfc3339(&ticket.expires_at).ok())
            .map(|expires_at| expires_at.with_timezone(&chrono::Utc) < an_hour_ago)
            .unwrap_or(false);
        if expired_long_ago {
            let _ = std::fs::remove_file(&file);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ticket_expiring_in(seconds: i64) -> Ticket {
        Ticket {
            bot_id: "ledger".into(),
            apps: BTreeMap::from([("echo".to_string(), AccessLevel::Full)]),
            owner_asked: true,
            expires_at: (chrono::Utc::now() + chrono::Duration::seconds(seconds)).to_rfc3339(),
        }
    }

    #[test]
    fn tickets_are_refused_when_expired_missing_or_elsewhere() {
        let folder = tempfile::tempdir().unwrap();
        let paths = HubPaths::new(folder.path());
        let good_ticket_file = issue_ticket(&paths, &ticket_expiring_in(60)).unwrap();
        assert_eq!(load_ticket(&paths, &good_ticket_file).unwrap().level_for("echo"), Some(AccessLevel::Full));
        assert_eq!(load_ticket(&paths, &good_ticket_file).unwrap().level_for("gmail"), None);

        let expired_ticket_file = issue_ticket(&paths, &ticket_expiring_in(-5)).unwrap();
        assert!(load_ticket(&paths, &expired_ticket_file).unwrap_err().contains("expired"));

        let elsewhere = folder.path().join("ticket.json");
        std::fs::copy(&good_ticket_file, &elsewhere).unwrap();
        assert!(load_ticket(&paths, &elsewhere).is_err());

        revoke_ticket(&paths, &good_ticket_file).unwrap();
        assert!(load_ticket(&paths, &good_ticket_file).is_err());
    }

    #[test]
    fn a_turn_not_from_the_owner_reads_and_drafts_at_most() {
        let mut ticket = ticket_expiring_in(60);
        ticket.owner_asked = false;
        assert_eq!(ticket.level_for("echo"), Some(AccessLevel::ReadAndDraft));
    }
}
