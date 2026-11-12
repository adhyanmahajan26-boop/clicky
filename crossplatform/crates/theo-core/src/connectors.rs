//! Connectors: the MCP servers Claude Code has (claude.ai apps like Notion and Gmail, and local ones). Read from `claude mcp
//! list`, whose lines look like `claude.ai Notion: https://mcp.notion.com/mcp - ✔ Connected` (checked against Claude Code
//! 2.1 on the Studio), `… - ! Needs authentication`, or a failure mark.

use serde::Serialize;

#[derive(Debug, Clone, Serialize, PartialEq)]
pub struct Connector {
    pub name: String,
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
        let Some(dash) = line.rfind(" - ") else { continue };
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
        let name = name.strip_prefix("claude.ai ").unwrap_or(name).to_string();
        out.push(Connector { name, target: target.to_string(), status: kind.into(), reason, last_connected: None });
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
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
}
