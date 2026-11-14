//! Control commands for the routines editor, the chat's cards and the coding-run card. One hook in `control::handle` sends
//! these here, so the shared file stays small.

use crate::control::{err, ok};
use crate::harness::Harness;
use serde_json::{json, Value};
use std::sync::Arc;

pub const COMMANDS: [&str; 10] = ["routineSave", "routinesList", "runChoices", "runChats", "projectMake", "projectsFolderSet", "runChoiceStart", "openFile", "pdfMake", "openLink"];

pub fn handles(name: &str) -> bool { COMMANDS.contains(&name) }

/// The line under a signed-out bot's name: the fix for the brain it's on, never Claude Code's for another brain.
pub fn sign_in_detail(provider: &str, reason: &str) -> String {
    let label = crate::brains::label(provider);
    if provider.starts_with("api:") { return format!("Check your {} key", label.trim_end_matches(" (API key)")); }
    if reason.contains("isn't installed") || reason.contains("not installed") { format!("Install {label}") } else { format!("Sign in to {label}") }
}

#[cfg(test)]
mod tests {
    #[test]
    fn the_sign_in_line_names_the_bots_own_brain() {
        assert_eq!(super::sign_in_detail("claude", "Not logged in · Please run /login"), "Sign in to Claude Code");
        assert_eq!(super::sign_in_detail("codex", "Codex isn't installed"), "Install Codex");
        assert!(super::sign_in_detail("api:openai", "invalid api key").starts_with("Check your OpenAI"));
    }
}

pub async fn handle(h: &Arc<Harness>, name: &str, cmd: &Value) -> Value {
    match name {
        "routineSave" => crate::routine_edit::save(h, cmd),
        "routinesList" => ok(crate::routine_edit::list(h)),
        "runChoices" => crate::run_choices::choices(h).await,
        "runChats" => crate::run_choices::chats(h, cmd).await,
        "projectMake" => crate::run_choices::make_project(h, cmd).await,
        "projectsFolderSet" => crate::run_choices::set_projects_folder(h, cmd),
        "runChoiceStart" => crate::run_choices::start(h, cmd).await,
        "openFile" => {
            let Some(path) = cmd.get("path").and_then(|p| p.as_str()) else { return err("Needs path.") };
            match crate::pdf::open_file(h, path) {
                Ok(()) => ok(json!({"opened": path})),
                Err(e) => err(&e),
            }
        }
        // A web page in the owner's browser (claude.ai's connectors page, a pull request). Only https: never a file or a program.
        "openLink" => {
            let Some(url) = cmd.get("url").and_then(|u| u.as_str()).map(str::trim) else { return err("Needs url.") };
            if !url.starts_with("https://") || url.chars().any(|c| c.is_whitespace() || c.is_control() || c == '"') { return err("Only a web address (https://) opens here."); }
            crate::hub::open_in_browser(h, url);
            ok(json!({"opened": url}))
        }
        // A bot's [PDF:] by hand, for tests and for trying again: the file in that bot's memory folder.
        "pdfMake" => {
            let (Some(bot), Some(file)) = (cmd.get("bot").and_then(|b| b.as_str()).and_then(|id| h.bot(id)), cmd.get("file").and_then(|f| f.as_str())) else { return err("Needs bot and file.") };
            match crate::pdf::make(file, &h.paths.memory_dir(&bot.id)) {
                Ok(pdf) => ok(json!({"pdf": pdf.to_string_lossy()})),
                Err(e) => err(&e),
            }
        }
        _ => err(&format!("Unknown command {name}")),
    }
}
