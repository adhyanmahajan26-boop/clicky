//! The tags in Clicky's answers: `[POINT:…]` (where the spark flies), `[MARK:…]` (circles, boxes, arrows and numbered steps
//! drawn on the screen) and `[CLEAR]`. A port of ClickyCore's `MarkTagParser` for the raw-pixel targets Windows has (there
//! are no element lists here, so `#id` and `"text"` targets aren't offered and don't parse):
//!
//! ```text
//! [POINT:x,y[:label][:screenN]]      [POINT:none]
//! [MARK:style:target[:label][:screenN]]
//! [CLEAR]
//!   style   circle | box | arrow | underline | spot | highlight | 1..9   (unknown: circle; a target in the style slot: circle)
//!   target  x,y | x,y,r (a box around the point) | x,y,w,h
//!   label   name[|note], up to the closing ] (a trailing :screenN is cut first)
//! ```
//!
//! Keywords are case-insensitive, a space is allowed after "[" and around ":", "," and "|". A "]" inside quotes doesn't close
//! a tag. Coordinates are pixels of SCREEN N's image (1 when not given); decimals are rounded. Every tag, valid or not, is
//! taken out of what's spoken, and an unclosed one runs to the end of the text. At most six marks are kept, in order.

/// The most marks drawn for one answer (the Mac's `LiveScreenMarkTagParser` cap).
pub const MAXIMUM_MARKS: usize = 6;
pub const MAXIMUM_LABEL_LENGTH: usize = 80;

#[derive(Clone, Copy, Debug, PartialEq)]
pub enum MarkStyle {
    Circle,
    Box,
    Arrow,
    Underline,
    Spot,
    Highlight,
    /// A numbered step badge, 1 to 9.
    Step(u8),
}

impl MarkStyle {
    pub fn name(&self) -> String {
        match self {
            MarkStyle::Circle => "circle".into(),
            MarkStyle::Box => "box".into(),
            MarkStyle::Arrow => "arrow".into(),
            MarkStyle::Underline => "underline".into(),
            MarkStyle::Spot => "spot".into(),
            MarkStyle::Highlight => "highlight".into(),
            MarkStyle::Step(number) => number.to_string(),
        }
    }

    fn from_keyword(word: &str) -> Option<MarkStyle> {
        let lower = word.trim().to_lowercase();
        Some(match lower.as_str() {
            "circle" | "ring" => MarkStyle::Circle,
            "box" | "rect" | "rectangle" => MarkStyle::Box,
            "arrow" => MarkStyle::Arrow,
            "underline" => MarkStyle::Underline,
            "spot" => MarkStyle::Spot,
            "highlight" => MarkStyle::Highlight,
            _ => match lower.parse::<u8>() {
                Ok(number) if (1..=9).contains(&number) => MarkStyle::Step(number),
                _ => return None,
            },
        })
    }
}

/// Where a tag points, in pixels of its screen's image.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Target {
    Point { x: i64, y: i64 },
    Box { x: i64, y: i64, width: i64, height: i64 },
    None,
}

impl Target {
    /// The centre of the target (where the spark flies).
    pub fn centre(&self) -> Option<(i64, i64)> {
        match *self {
            Target::Point { x, y } => Some((x, y)),
            Target::Box { x, y, width, height } => Some((x + width / 2, y + height / 2)),
            Target::None => None,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub enum TagKind {
    Point,
    Mark,
    Clear,
}

#[derive(Clone, Debug, PartialEq)]
pub struct Tag {
    pub kind: TagKind,
    pub style: Option<MarkStyle>,
    pub target: Target,
    pub name: Option<String>,
    pub note: Option<String>,
    pub screen: Option<usize>,
}

impl Tag {
    /// SCREEN n the coordinates belong to (1 when not given).
    pub fn screen_number(&self) -> usize {
        self.screen.unwrap_or(1)
    }

    /// What's written beside a mark: the note, else the name for arrows and numbered steps, else nothing.
    pub fn display_text(&self) -> Option<String> {
        if let Some(note) = self.note.as_ref().filter(|note| !note.is_empty()) {
            return Some(note.clone());
        }
        match self.style {
            Some(MarkStyle::Arrow) | Some(MarkStyle::Step(_)) => self.name.clone(),
            _ => None,
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct Extraction {
    /// Valid tags in the order they appear.
    pub tags: Vec<Tag>,
    /// The answer with every tag removed: what gets spoken.
    pub speech: String,
    /// Tag-looking spans that didn't parse (taken out of the speech anyway).
    pub malformed: usize,
}

/// What an answer asks the overlay to do.
#[derive(Clone, Debug, PartialEq)]
pub struct Reply {
    pub speech: String,
    /// The last [POINT] with a target, if any ([POINT:none] means no flight).
    pub point: Option<Tag>,
    /// At most `MAXIMUM_MARKS`, in the order written.
    pub marks: Vec<Tag>,
    /// The answer said [CLEAR]: marks from earlier answers go.
    pub clear: bool,
}

#[derive(Clone, Copy, PartialEq)]
enum Keyword {
    Point,
    Mark,
    Clear,
}

/// The keyword right after a "[" at `index` (a space allowed after the bracket), with the index just past it. Only
/// POINT and MARK followed by ":" and CLEAR followed by "]" count; anything else in brackets ("items[0]") is left alone.
fn keyword_after_bracket(characters: &[char], index: usize) -> Option<(Keyword, usize)> {
    let mut position = index + 1;
    while position < characters.len() && characters[position] == ' ' {
        position += 1;
    }
    for (word, keyword) in [("point", Keyword::Point), ("mark", Keyword::Mark), ("clear", Keyword::Clear)] {
        let end = position + word.len();
        if end > characters.len() {
            continue;
        }
        let candidate: String = characters[position..end].iter().collect();
        if !candidate.eq_ignore_ascii_case(word) {
            continue;
        }
        let mut after = end;
        while after < characters.len() && characters[after] == ' ' {
            after += 1;
        }
        let next = characters.get(after).copied();
        let fits = match keyword {
            Keyword::Clear => next == Some(']'),
            _ => next == Some(':'),
        };
        if fits {
            return Some((keyword, after));
        }
        // An unclosed "[POINT" at the very end of a streamed answer still counts as a tag being written.
        if next.is_none() && keyword != Keyword::Clear {
            return Some((keyword, after));
        }
    }
    None
}

/// The "]" that closes the tag opened at `opening`, skipping any inside quotes (\" escapes a quote).
fn closing_bracket(characters: &[char], opening: usize) -> Option<usize> {
    let mut in_quotes = false;
    let mut index = opening + 1;
    while index < characters.len() {
        match characters[index] {
            '\\' if in_quotes => index += 1,
            '"' => in_quotes = !in_quotes,
            ']' if !in_quotes => return Some(index),
            // A new tag starting before this one closed: this one was never closed.
            '[' if !in_quotes && keyword_after_bracket(characters, index).is_some() => return None,
            _ => {}
        }
        index += 1;
    }
    None
}

/// Every POINT, MARK and CLEAR tag in `answer`, and the answer without them.
pub fn extract_all(answer: &str) -> Extraction {
    let characters: Vec<char> = answer.chars().collect();
    let mut tags = vec![];
    let mut malformed = 0;
    let mut speech = String::new();
    let mut index = 0;
    while index < characters.len() {
        if characters[index] == '[' {
            if let Some((keyword, body_start)) = keyword_after_bracket(&characters, index) {
                match closing_bracket(&characters, index) {
                    Some(closing) => {
                        let body: String = characters[(body_start + 1).min(closing)..closing].iter().collect();
                        match parse_body(keyword, &body) {
                            Some(tag) => tags.push(tag),
                            None => malformed += 1,
                        }
                        index = closing + 1;
                        continue;
                    }
                    None => {
                        // Unclosed: never speak it. Skip to the next tag that starts, or the end.
                        malformed += 1;
                        let mut next = index + 1;
                        while next < characters.len() && !(characters[next] == '[' && keyword_after_bracket(&characters, next).is_some()) {
                            next += 1;
                        }
                        index = next;
                        continue;
                    }
                }
            }
        }
        speech.push(characters[index]);
        index += 1;
    }
    Extraction { tags, speech: tidy_speech(&speech), malformed }
}

/// The overlay's view of an answer: its speech, its last real POINT and its first six marks.
pub fn read_reply(answer: &str) -> Reply {
    let extraction = extract_all(answer);
    let mut point = None;
    let mut marks = vec![];
    let mut clear = false;
    for tag in extraction.tags {
        match tag.kind {
            TagKind::Point => {
                if tag.target != Target::None {
                    point = Some(tag);
                }
            }
            TagKind::Mark => {
                if marks.len() < MAXIMUM_MARKS && tag.target != Target::None {
                    marks.push(tag);
                }
            }
            TagKind::Clear => clear = true,
        }
    }
    Reply { speech: extraction.speech, point, marks, clear }
}

/// Parses one whole tag such as "[MARK:circle:120,40:Share]".
pub fn parse(raw: &str) -> Option<Tag> {
    let characters: Vec<char> = raw.trim().chars().collect();
    if characters.first() != Some(&'[') {
        return None;
    }
    let (keyword, body_start) = keyword_after_bracket(&characters, 0)?;
    let closing = closing_bracket(&characters, 0)?;
    if closing != characters.len() - 1 {
        return None;
    }
    let body: String = characters[(body_start + 1).min(closing)..closing].iter().collect();
    parse_body(keyword, &body)
}

fn parse_body(keyword: Keyword, body: &str) -> Option<Tag> {
    if keyword == Keyword::Clear {
        return Some(Tag { kind: TagKind::Clear, style: None, target: Target::None, name: None, note: None, screen: None });
    }
    let (rest, screen) = cut_screen(body.trim());
    let (first, after_first) = split_once_colon(&rest);
    match keyword {
        Keyword::Point => {
            let target = parse_target(&first)?;
            let (name, note) = parse_label(after_first.as_deref());
            Some(Tag { kind: TagKind::Point, style: None, target, name, note, screen })
        }
        Keyword::Mark => {
            let (style, target, label) = match MarkStyle::from_keyword(&first) {
                Some(style) => {
                    let after = after_first?;
                    let (target_text, label) = split_once_colon(&after);
                    (style, parse_target(&target_text)?, label)
                }
                // [MARK:120,40:Share]: a target in the style slot means a circle. An unknown style word also means a circle.
                None => match parse_target(&first) {
                    Some(target) => (MarkStyle::Circle, target, after_first),
                    None => {
                        let after = after_first?;
                        let (target_text, label) = split_once_colon(&after);
                        (MarkStyle::Circle, parse_target(&target_text)?, label)
                    }
                },
            };
            let (name, note) = parse_label(label.as_deref());
            Some(Tag { kind: TagKind::Mark, style: Some(style), target, name, note, screen })
        }
        Keyword::Clear => None,
    }
}

/// Cuts a trailing ":screenN" (any case, spaces allowed). N must be 1 or more.
fn cut_screen(body: &str) -> (String, Option<usize>) {
    let lower = body.to_lowercase();
    if let Some(position) = lower.rfind("screen") {
        let digits = lower[position + "screen".len()..].trim();
        let before = body[..position].trim_end();
        if !digits.is_empty() && digits.chars().all(|c| c.is_ascii_digit()) && before.ends_with(':') {
            if let Ok(number) = digits.parse::<usize>() {
                if number >= 1 {
                    return (before[..before.len() - 1].trim_end().to_string(), Some(number));
                }
            }
        }
    }
    (body.to_string(), None)
}

fn split_once_colon(text: &str) -> (String, Option<String>) {
    match text.split_once(':') {
        Some((first, rest)) => (first.trim().to_string(), Some(rest.trim().to_string())),
        None => (text.trim().to_string(), None),
    }
}

fn parse_target(text: &str) -> Option<Target> {
    let text = text.trim();
    if text.eq_ignore_ascii_case("none") {
        return Some(Target::None);
    }
    let numbers: Vec<f64> = text.split(',').map(|part| part.trim().parse::<f64>()).collect::<Result<_, _>>().ok()?;
    if numbers.iter().any(|number| !number.is_finite() || *number < 0.0 || *number > 100_000.0) {
        return None;
    }
    let rounded: Vec<i64> = numbers.iter().map(|number| number.round() as i64).collect();
    match rounded.as_slice() {
        [x, y] => Some(Target::Point { x: *x, y: *y }),
        // The legacy x,y,r: a box around the point.
        [x, y, radius] => Some(Target::Box { x: (x - radius).max(0), y: (y - radius).max(0), width: radius * 2, height: radius * 2 }),
        [x, y, width, height] if *width > 0 && *height > 0 => Some(Target::Box { x: *x, y: *y, width: *width, height: *height }),
        _ => None,
    }
}

fn parse_label(label: Option<&str>) -> (Option<String>, Option<String>) {
    let Some(label) = label.map(str::trim).filter(|label| !label.is_empty()) else { return (None, None) };
    let (name, note) = match label.split_once('|') {
        Some((name, note)) => (name.trim(), Some(note.trim())),
        None => (label, None),
    };
    let clean = |text: &str| -> Option<String> {
        let text = text.trim().trim_matches('"').trim();
        if text.is_empty() {
            None
        } else {
            Some(text.chars().take(MAXIMUM_LABEL_LENGTH).collect())
        }
    };
    (clean(name), note.and_then(clean))
}

/// The speech once tags are gone: no doubled spaces, no space before punctuation, no blank lines left by a tag.
pub fn tidy_speech(text: &str) -> String {
    let mut lines = vec![];
    for line in text.lines() {
        let mut tidy = String::new();
        let mut last_space = false;
        for character in line.chars() {
            if character == ' ' || character == '\t' {
                if !last_space && !tidy.is_empty() {
                    tidy.push(' ');
                }
                last_space = true;
                continue;
            }
            if matches!(character, '.' | ',' | '!' | '?' | ';' | ':') && tidy.ends_with(' ') {
                tidy.pop();
            }
            tidy.push(character);
            last_space = false;
        }
        lines.push(tidy.trim_end().to_string());
    }
    let mut joined = lines.join("\n");
    while joined.contains("\n\n\n") {
        joined = joined.replace("\n\n\n", "\n\n");
    }
    joined.trim().to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn point_with_label_and_screen() {
        let tag = parse("[POINT:400,300:terminal:screen2]").unwrap();
        assert_eq!(tag.kind, TagKind::Point);
        assert_eq!(tag.target, Target::Point { x: 400, y: 300 });
        assert_eq!(tag.name.as_deref(), Some("terminal"));
        assert_eq!(tag.screen, Some(2));
        assert_eq!(tag.screen_number(), 2);
    }

    #[test]
    fn point_none_and_without_label() {
        assert_eq!(parse("[POINT:none]").unwrap().target, Target::None);
        let tag = parse("[ point : 1100.6 , 42.2 ]").unwrap();
        assert_eq!(tag.target, Target::Point { x: 1101, y: 42 });
        assert_eq!(tag.name, None);
        assert_eq!(tag.screen_number(), 1);
    }

    #[test]
    fn marks_of_every_style() {
        let step = parse("[MARK:2:540,140:dark]").unwrap();
        assert_eq!(step.style, Some(MarkStyle::Step(2)));
        assert_eq!(step.display_text().as_deref(), Some("dark"));
        let circle = parse("[MARK:circle:10,20:Save]").unwrap();
        assert_eq!(circle.style, Some(MarkStyle::Circle));
        assert_eq!(circle.display_text(), None);
        let boxed = parse("[MARK:box:10,20,300,40:Results|click this first:screen3]").unwrap();
        assert_eq!(boxed.target, Target::Box { x: 10, y: 20, width: 300, height: 40 });
        assert_eq!(boxed.note.as_deref(), Some("click this first"));
        assert_eq!(boxed.display_text().as_deref(), Some("click this first"));
        assert_eq!(boxed.screen, Some(3));
        let legacy = parse("[MARK:arrow:100,100,20]").unwrap();
        assert_eq!(legacy.target, Target::Box { x: 80, y: 80, width: 40, height: 40 });
        // A target in the style slot, and an unknown style, both mean a circle.
        assert_eq!(parse("[MARK:120,40:Share]").unwrap().style, Some(MarkStyle::Circle));
        assert_eq!(parse("[MARK:sparkle:120,40:Share]").unwrap().style, Some(MarkStyle::Circle));
        assert_eq!(parse("[MARK:10:120,40:Share]").unwrap().style, Some(MarkStyle::Circle));
    }

    #[test]
    fn bad_tags_are_refused() {
        assert!(parse("[POINT:#57:Share]").is_none());
        assert!(parse("[MARK:circle:\"Save\":Save]").is_none());
        assert!(parse("[POINT:-5,10]").is_none());
        assert!(parse("[POINT:1,2,3,4,5]").is_none());
        assert!(parse("[MARK:box:1,2,0,0]").is_none());
    }

    #[test]
    fn speech_loses_every_tag_and_keeps_other_brackets() {
        let answer = "click appearance in the sidebar, then pick dark at the top. [MARK:1:160,320:appearance] [MARK:2:540,140:dark] [MARK:oops] [POINT:160,320:appearance]";
        let extraction = extract_all(answer);
        assert_eq!(extraction.speech, "click appearance in the sidebar, then pick dark at the top.");
        assert_eq!(extraction.tags.len(), 3);
        assert_eq!(extraction.malformed, 1);
        assert_eq!(extract_all("items[0] is the first one").speech, "items[0] is the first one");
        // Unclosed at the end (a streamed answer, or a model that stopped): not spoken.
        assert_eq!(extract_all("look up here [POINT:12,3").speech, "look up here");
        assert_eq!(extract_all("look up here [POI").speech, "look up here [POI");
        // A quoted "]" doesn't close the tag.
        assert_eq!(extract_all("ok [MARK:circle:5,5:\"a ] b\"] done").speech, "ok done");
    }

    #[test]
    fn reply_keeps_last_point_and_six_marks() {
        let mut answer = String::from("here.");
        for number in 1..=8 {
            answer.push_str(&format!(" [MARK:{number}:{},{}]", number * 10, number * 10));
        }
        answer.push_str(" [POINT:5,5:first] [POINT:none] [POINT:50,60:second:screen2] [CLEAR]");
        let reply = read_reply(&answer);
        assert_eq!(reply.marks.len(), MAXIMUM_MARKS);
        assert_eq!(reply.marks[0].style, Some(MarkStyle::Step(1)));
        let point = reply.point.unwrap();
        assert_eq!(point.name.as_deref(), Some("second"));
        assert_eq!(point.screen, Some(2));
        assert!(reply.clear);
        assert_eq!(reply.speech, "here.");
    }

    #[test]
    fn label_may_hold_a_colon_and_screen_needs_its_colon() {
        let tag = parse("[POINT:10,10:time: 3pm:screen2]").unwrap();
        assert_eq!(tag.name.as_deref(), Some("time: 3pm"));
        assert_eq!(tag.screen, Some(2));
        let tag = parse("[POINT:10,10:big screen2]").unwrap();
        assert_eq!(tag.name.as_deref(), Some("big screen2"));
        assert_eq!(tag.screen, None);
    }
}
