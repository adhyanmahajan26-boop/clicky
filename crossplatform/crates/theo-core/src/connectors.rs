//! Connectors: the MCP servers Claude Code has (claude.ai apps like Notion and Gmail, and local ones). Read from `claude mcp
//! list`, whose lines look like `claude.ai Notion: https://mcp.notion.com/mcp - ✔ Connected` (checked against Claude Code
//! 2.1 on the Studio), `… - ! Needs authentication`, or a failure mark.

use serde::Serialize;

#[derive(Debug, Clone, Serialize, PartialEq)]
pub struct Connector {
    pub name: String,
    /// The server's own name in `claude mcp list` ("claude.ai Gmail"), which its tools are named after.
    pub server: String,
    pub target: String,
    /// connected, needsSignIn, failed or unknown.
    pub status: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub reason: Option<String>,
    #[serde(rename = "lastConnected", skip_serializing_if = "Option::is_none")]
    pub last_connected: Option<String>,
}

pub fn parse(output: &str) -> Vec<Connector> {
    let mut out = vec![];
    for line in output.lines() {
        let line = line.trim();
        // The status starts at the first " - " followed by a status mark or word: a failure's reason can hold " - " too
        // ("✘ Failed to connect — spawn C:\\x - y ENOENT"), and Windows prints √ and × for ✔ and ✘.
        let status_at = line.match_indices(" - ").map(|(i, _)| i).find(|&i| {
            let rest = line[i + 3..].trim_start();
            rest.starts_with(['✔', '✓', '√', '✘', '✗', '×', '✖', '!', '⚠', '‼']) || ["connected", "failed", "needs", "error"].iter().any(|w| rest.to_lowercase().starts_with(w))
        });
        let Some(dash) = status_at.or_else(|| line.rfind(" - ")) else { continue };
        let (head, status) = (&line[..dash], line[dash + 3..].trim());
        let Some(colon) = head.find(": ") else { continue };
        let (name, target) = (head[..colon].trim(), head[colon + 2..].trim());
        if name.is_empty() {
            continue;
        }
        let lower = status.to_lowercase();
        let (kind, reason) = if lower.contains("needs auth") || lower.contains("sign in") || lower.contains("login") {
            ("needsSignIn", None)
        } else if lower.contains("connected") && !lower.contains("not connected") && !lower.contains("failed") {
            ("connected", None)
        } else if lower.contains("fail") || lower.contains("error") || status.starts_with('✘') || status.starts_with('✗') || status.starts_with('×') {
            let reason = status.trim_start_matches(|c: char| !c.is_alphanumeric()).trim().to_string();
            ("failed", Some(reason))
        } else {
            ("unknown", None)
        };
        let server = name.to_string();
        let name = name.strip_prefix("claude.ai ").unwrap_or(name).to_string();
        out.push(Connector { name, server, target: target.to_string(), status: kind.into(), reason, last_connected: None });
    }
    out
}

/// The permission rule that lets a bot use every tool of one connector: Claude Code names a server's tools
/// `mcp__<server>__<tool>`, with anything but letters, digits, `_` and `-` in the server's name turned into `_`
/// ("claude.ai Gmail" → `mcp__claude_ai_Gmail`, as the Swift app's `BotConnectors.known` has it).
pub fn tool_rule(server: &str) -> Option<String> {
    let cleaned: String = server.trim().chars().map(|c| if c.is_ascii_alphanumeric() || c == '_' || c == '-' { c } else { '_' }).collect();
    if cleaned.is_empty() || cleaned.chars().all(|c| c == '_') {
        return None;
    }
    Some(format!("mcp__{cleaned}"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tool_rules_follow_claude_codes_names() {
        assert_eq!(tool_rule("claude.ai Gmail").as_deref(), Some("mcp__claude_ai_Gmail"));
        assert_eq!(tool_rule("claude.ai Hostinger Connector").as_deref(), Some("mcp__claude_ai_Hostinger_Connector"));
        assert_eq!(tool_rule("theo-echo").as_deref(), Some("mcp__theo-echo"));
        assert_eq!(tool_rule("*"), None);
        assert_eq!(tool_rule(""), None);
    }

    #[test]
    fn reads_claude_mcp_list() {
        let text = "Checking MCP server health…\n\nclaude.ai Notion: https://mcp.notion.com/mcp - ✔ Connected\nclaude.ai Runway (runway.team): https://mcp.runway.team - ! Needs authentication\nplugin:theo:theo: /x/theo-mcp  - ✔ Connected\nbroken: npx broken-mcp - ✘ Failed to connect\n";
        let c = parse(text);
        assert_eq!(c.len(), 4);
        assert_eq!((c[0].name.as_str(), c[0].status.as_str()), ("Notion", "connected"));
        assert_eq!((c[1].name.as_str(), c[1].status.as_str()), ("Runway (runway.team)", "needsSignIn"));
        assert_eq!((c[2].name.as_str(), c[2].status.as_str()), ("plugin:theo:theo", "connected"));
        assert_eq!(c[3].status, "failed");
        assert_eq!(c[3].reason.as_deref(), Some("Failed to connect"));
    }

    #[test]
    fn reads_failures_with_reasons() {
        // Claude Code 2.1.323's own output (Linux), and the same with Windows' marks and a reason holding " - ".
        let text = "Checking MCP server health…\n\ntheo-echo: python3 /x/tests/echo_mcp.py - ✔ Connected\ntheo-broken: /nonexistent/server  - ✘ Failed to connect — ENOENT: no such file or directory, posix_spawn '/nonexistent/server'\ntheo-echo: C:\\Python312\\python.exe C:\\a\\echo_mcp.py - √ Connected\ntheo-broken: C:\\nope.exe  - × Failed to connect — spawn C:\\nope.exe - x ENOENT\n";
        let c = parse(text);
        assert_eq!(c.len(), 4);
        assert_eq!((c[0].name.as_str(), c[0].status.as_str(), c[0].target.as_str()), ("theo-echo", "connected", "python3 /x/tests/echo_mcp.py"));
        assert_eq!((c[1].name.as_str(), c[1].status.as_str()), ("theo-broken", "failed"));
        assert!(c[1].reason.as_deref().unwrap().contains("ENOENT"));
        assert_eq!((c[2].status.as_str(), c[2].target.as_str()), ("connected", "C:\\Python312\\python.exe C:\\a\\echo_mcp.py"));
        assert_eq!((c[3].name.as_str(), c[3].status.as_str(), c[3].target.as_str()), ("theo-broken", "failed", "C:\\nope.exe"));
        assert!(c[3].reason.as_deref().unwrap().ends_with("x ENOENT"));
    }
}
