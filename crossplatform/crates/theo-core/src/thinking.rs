//! A thinking model's reasoning is never a bot's answer (the Mac's ClickyCore `ThinkingText`). A server that separates it
//! sends it as `reasoning_content` (or `reasoning`), which is never read as text. One that doesn't sends it in the answer
//! between <think> and </think>, and a template that put the opening tag in the prompt makes the reply start mid-think with
//! only the closing tag. `visible` is what's left. It works on the whole text so far, and only ever grows while a reply
//! streams: anything that might still turn out to be thinking is held until it's sure.

use serde_json::Value;

const OPENING_TAG: &str = "<think>";
const CLOSING_TAG: &str = "</think>";

/// Model ids that think in their answer, where a server may leave the opening tag in the prompt: held until the thinking is
/// known to be over, unless the server is seen separating its reasoning.
pub fn may_think_without_opening_tag(model: &str) -> bool {
    let lowered = model.to_lowercase();
    ["qwen3", "qwq", "deepseek-r1", "r1-distill", "thinking", "reasoning", "reasoner", "magistral", "gpt-oss", "glm-4.5", "glm-z1", "ornith",
     "exaone-deep", "hermes-4"]
        .iter()
        .any(|family| lowered.contains(family))
}

/// Whether one server-sent line carries reasoning the server separated from the answer.
pub fn line_carries_reasoning(line: &str) -> bool {
    let Some(payload) = line.strip_prefix("data:").map(str::trim) else { return false };
    let Ok(event) = serde_json::from_str::<Value>(payload) else { return false };
    let delta = &event["choices"][0]["delta"];
    ["reasoning_content", "reasoning"].iter().any(|key| delta[*key].as_str().map_or(false, |text| !text.is_empty()))
}

fn find(haystack: &str, tag: &str) -> Option<usize> {
    haystack.to_lowercase().find(tag)
}

fn is_start_of(text: &str, tag: &str) -> bool {
    text.len() <= tag.len() && tag.starts_with(&text.to_lowercase())
}

/// The answer in `text` without any thinking (see the module comment).
pub fn visible(text: &str, is_complete: bool, holds_until_sure: bool) -> String {
    let mut answer: &str = text;
    let leading = text.trim_start();
    if leading.to_lowercase().starts_with(OPENING_TAG) {
        let after_opening = &leading[OPENING_TAG.len()..];
        let Some(closing) = find(after_opening, CLOSING_TAG) else { return String::new() };
        answer = &after_opening[closing + CLOSING_TAG.len()..];
    } else if !is_complete && !leading.is_empty() && is_start_of(leading, OPENING_TAG) {
        return String::new();
    } else if let Some(closing) = find(answer, CLOSING_TAG).filter(|closing| find(answer, OPENING_TAG).map_or(true, |opening| opening > *closing)) {
        answer = &answer[closing + CLOSING_TAG.len()..];
    } else if holds_until_sure && !is_complete {
        return String::new();
    }
    let mut shown = String::new();
    let mut remaining = answer;
    while let Some(opening) = find(remaining, OPENING_TAG) {
        shown.push_str(&remaining[..opening]);
        let after_opening = &remaining[opening + OPENING_TAG.len()..];
        match find(after_opening, CLOSING_TAG) {
            Some(closing) => remaining = &after_opening[closing + CLOSING_TAG.len()..],
            None => {
                remaining = "";
                break;
            }
        }
    }
    shown.push_str(remaining);
    let mut shown = shown.replace(CLOSING_TAG, "").replace("</THINK>", "");
    if !is_complete {
        if let Some(last) = shown.rfind('<') {
            let ending = &shown[last..];
            if is_start_of(ending, OPENING_TAG) || is_start_of(ending, CLOSING_TAG) {
                shown.truncate(last);
            }
        }
    }
    let started = shown.trim_start().to_string();
    if is_complete { started.trim_end().to_string() } else { started }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn streamed(reply: &str, size: usize, holds: bool) -> (Vec<String>, String) {
        let characters: Vec<char> = reply.chars().collect();
        let mut pieces = Vec::new();
        let mut end = 0;
        while end < characters.len() {
            end = (end + size).min(characters.len());
            let so_far: String = characters[..end].iter().collect();
            pieces.push(visible(&so_far, false, holds));
        }
        (pieces, visible(reply, true, holds))
    }

    fn only_grows(pieces: &[String]) -> bool {
        pieces.windows(2).all(|pair| pair[1].starts_with(&pair[0]))
    }

    #[test]
    fn a_reply_that_opens_with_thinking_shows_only_the_answer() {
        let reply = "<think>\nSay Paris.\n</think>\n\nIt's Paris.";
        for size in [1, 3, 50] {
            let (pieces, last) = streamed(reply, size, false);
            assert!(only_grows(&pieces));
            assert!(pieces.iter().all(|piece| !piece.contains("Say Paris") && !piece.contains('<')));
            assert_eq!(last, "It's Paris.");
        }
    }

    #[test]
    fn a_reply_that_starts_mid_think_is_held_and_cut_at_the_closing_tag() {
        let reply = "Rayleigh scattering, I think.\n</think>\n\nBlue light scatters more.";
        let (pieces, last) = streamed(reply, 4, true);
        assert!(only_grows(&pieces));
        assert!(pieces.iter().all(|piece| !piece.contains("Rayleigh")));
        assert_eq!(last, "Blue light scatters more.");
        assert_eq!(visible(reply, true, false), "Blue light scatters more.");
    }

    #[test]
    fn unclosed_and_later_blocks() {
        assert_eq!(visible("<think>never closes", true, false), "");
        assert_eq!(visible("Sure. <think>hidden", true, false), "Sure.");
        assert_eq!(visible("One. <think>aside</think>Two.", true, false), "One. Two.");
        assert_eq!(visible("So <thi", false, false), "So ");
        assert_eq!(visible("a < b", false, false), "a < b");
        assert_eq!(visible("Hello there.", true, true), "Hello there.");
        assert_eq!(visible("Hello there.", false, true), "");
    }

    #[test]
    fn models_and_reasoning_lines() {
        assert!(may_think_without_opening_tag("qwen3.8-27b-uncensored-mlx"));
        assert!(!may_think_without_opening_tag("gpt-6-mini"));
        assert!(line_carries_reasoning(r#"data: {"choices":[{"delta":{"reasoning_content":"hmm"}}]}"#));
        assert!(!line_carries_reasoning(r#"data: {"choices":[{"delta":{"content":"hi"}}]}"#));
    }
}
