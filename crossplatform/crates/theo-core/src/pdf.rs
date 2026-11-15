//! `[PDF: file name]` in a bot's reply (the Mac's `BotPDF` and ClickyCore `BotPDFOrder`). Bots can't run commands, so a bot
//! writes the document (Markdown, HTML or plain text) in its memory folder and adds the line; Theo renders it into a paged A4
//! PDF next to that file and puts it in the chat.
//!
//! The PDF is written here, with no library: the standard Helvetica and Courier fonts every PDF reader has (so nothing is
//! embedded), text in the Windows-1252 set they use, wrapped and paged. Nothing in a bot's HTML is ever loaded or run: its
//! tags are only read for structure (headings, paragraphs, lists, table rows) and everything else is dropped.

use crate::harness::Harness;
use crate::model::{Bot, ChatMessage};
use regex::Regex;
use serde_json::json;
use std::path::{Path, PathBuf};

pub const MAXIMUM_PER_REPLY: usize = 3;

/// What a bot is told about PDFs (ClickyCore `BotProtocol.pdfHowTo`).
pub const HOW_TO: &str = "For a PDF, write the document as Markdown or HTML in your memory folder, then put a line [PDF: file name] in your reply: Vello makes the PDF next to that file and puts it in the chat. Say the PDF is made only once Vello's line says so.";

/// The reply without its `[PDF: …]` tags, and the files they name (at most three).
pub fn extract(text: &str) -> (String, Vec<String>) {
    let tag = Regex::new(r"(?i)\[\s*PDF\s*:\s*([^\]\n]{1,200}?)\s*\]").unwrap();
    let files: Vec<String> = tag.captures_iter(text).map(|c| c[1].trim().to_string()).filter(|f| !f.is_empty()).take(MAXIMUM_PER_REPLY).collect();
    if files.is_empty() && !tag.is_match(text) { return (text.to_string(), vec![]); }
    let without = tag.replace_all(text, "");
    // A line that held only the tag goes with it.
    let mut lines: Vec<&str> = vec![];
    for line in without.lines() {
        if line.trim().is_empty() && lines.last().map(|l: &&str| l.trim().is_empty()).unwrap_or(true) { continue; }
        lines.push(line);
    }
    while lines.last().map(|l| l.trim().is_empty()).unwrap_or(false) { lines.pop(); }
    (lines.join("\n"), files)
}

/// The file a tag names, only if it's inside `folder`: no way out with `..`, an absolute path elsewhere or a link.
pub fn file_named(name: &str, folder: &Path) -> Option<PathBuf> {
    let cleaned: String = name.trim().trim_matches(|c| c == '`' || c == '\'' || c == '"' || c == ' ').replace('~', "");
    if cleaned.is_empty() { return None; }
    let candidate = if Path::new(&cleaned).is_absolute() { PathBuf::from(&cleaned) } else { folder.join(&cleaned) };
    let resolved = std::fs::canonicalize(&candidate).ok()?;
    let root = std::fs::canonicalize(folder).ok()?;
    (resolved.starts_with(&root) && resolved != root && resolved.is_file()).then_some(resolved)
}

/// Renders `name` (inside `folder`) to `<name>.pdf` beside it and returns where it went.
pub fn make(name: &str, folder: &Path) -> Result<PathBuf, String> {
    let source = file_named(name, folder).ok_or_else(|| format!("There's no file called {name} in the bot's memory folder."))?;
    let shown = source.file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_default();
    let bytes = std::fs::read(&source).map_err(|_| format!("{shown} couldn't be read."))?;
    let text = String::from_utf8(bytes).map_err(|_| format!("{shown} couldn't be read as text."))?;
    let kind = source.extension().map(|e| e.to_string_lossy().to_lowercase()).unwrap_or_default();
    let blocks = match kind.as_str() {
        "html" | "htm" => markdown_blocks(&html_to_markdown(&text)),
        "md" | "markdown" | "txt" | "" => markdown_blocks(&text),
        _ => vec![Block::Code(text.lines().map(str::to_string).collect())],
    };
    let title = source.file_stem().map(|s| s.to_string_lossy().to_string()).unwrap_or_else(|| "Document".into());
    let pdf = render(&blocks, &title);
    let output = source.with_extension("pdf");
    crate::store::write_atomic(&output, &pdf).map_err(|_| format!("The PDF of {shown} couldn't be made."))?;
    Ok(output)
}

/// After a turn: each PDF the reply asked for, made and said in the chat (with an Open button), or why it couldn't be.
pub fn make_for_turn(h: &Harness, bot: &Bot, files: &[String], room: &str, exchange: Option<String>) {
    let folder = h.paths.memory_dir(&bot.id);
    for name in files {
        let message = match make(name, &folder) {
            Ok(pdf) => {
                let file = pdf.file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_default();
                let mut m = ChatMessage::note(format!("Vello made the PDF {file} for {}.\n{}", bot.name, pdf.to_string_lossy()));
                m.card = Some(format!("pdf:{}", json!({"path": pdf.to_string_lossy(), "name": file, "bot": bot.id})));
                m
            }
            Err(problem) => ChatMessage::note(format!("Vello couldn't make a PDF for {}: {problem}", bot.name)),
        };
        h.post(message.with_exchange(exchange.clone()), room);
    }
}

/// Opens a file Theo made (a PDF in a bot's folder) with the computer's own app. Only files inside Theo's data folder; a test
/// profile records it in `Logs/opened.log` instead.
pub fn open_file(h: &Harness, path: &str) -> Result<(), String> {
    let wanted = std::fs::canonicalize(path).map_err(|_| "That file isn't there any more.".to_string())?;
    let root = std::fs::canonicalize(&h.paths.root).map_err(|e| e.to_string())?;
    if !wanted.starts_with(&root) || !wanted.is_file() { return Err("Vello only opens files it made.".into()); }
    if h.settings.is_test {
        let folder = h.paths.logs_dir();
        let _ = std::fs::create_dir_all(&folder);
        use std::io::Write;
        if let Ok(mut file) = std::fs::OpenOptions::new().create(true).append(true).open(folder.join("opened.log")) {
            let _ = writeln!(file, "{}", wanted.to_string_lossy());
        }
        return Ok(());
    }
    let shown = wanted.to_string_lossy().to_string();
    // Windows: the path canonicalize gives starts with \\?\, which the file handler doesn't take.
    #[cfg(windows)]
    let shown = shown.trim_start_matches(r"\\?\").to_string();
    #[cfg(windows)]
    let opener = ("rundll32", vec!["url.dll,FileProtocolHandler".to_string(), shown]);
    #[cfg(target_os = "macos")]
    let opener = ("open", vec![shown]);
    #[cfg(all(unix, not(target_os = "macos")))]
    let opener = ("xdg-open", vec![shown]);
    let mut command = std::process::Command::new(opener.0);
    command.args(&opener.1).stdin(std::process::Stdio::null()).stdout(std::process::Stdio::null()).stderr(std::process::Stdio::null());
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        command.creation_flags(0x0800_0000);
    }
    command.spawn().map(|_| ()).map_err(|e| e.to_string())
}

// MARK: Reading the document

#[derive(Clone, Debug, PartialEq)]
pub enum Block {
    Heading(usize, String),
    Paragraph(Vec<String>),
    Item(Option<usize>, String),
    Table(Vec<Vec<String>>),
    Rule,
    Code(Vec<String>),
}

/// Bold, italics, code and links as plain words: a link keeps its address in brackets, only for web and mail addresses.
pub fn inline(text: &str) -> String {
    let link = Regex::new(r"\[([^\]]+)\]\(((?:https?://|mailto:)[^)\s]+)\)").unwrap();
    let mut out = link.replace_all(text, "$1 ($2)").to_string();
    for (pattern, with) in [(r"\*\*([^*]+)\*\*", "$1"), (r"__([^_]+)__", "$1"), (r"`([^`]+)`", "$1"), (r"(^|[^*\w])\*([^*\n]+)\*", "$1$2"), (r"(^|[^\w])_([^_\n]+)_($|[^\w])", "$1$2$3")] {
        out = Regex::new(pattern).unwrap().replace_all(&out, with).to_string();
    }
    out
}

fn cells(line: &str) -> Vec<String> {
    let trimmed = line.trim().trim_start_matches('|').trim_end_matches('|');
    trimmed.split('|').map(|c| inline(c.trim())).collect()
}

fn is_divider(line: &str) -> bool {
    Regex::new(r"^\s*\|?\s*:?-{2,}:?\s*(\|\s*:?-{2,}:?\s*)*\|?\s*$").unwrap().is_match(line)
}

/// Just enough Markdown for a document a bot writes: headings, paragraphs, lists, tables, rules and code.
pub fn markdown_blocks(markdown: &str) -> Vec<Block> {
    let lines: Vec<&str> = markdown.lines().collect();
    let heading = Regex::new(r"^(#{1,6})\s+(.*)$").unwrap();
    let rule = Regex::new(r"^(-{3,}|\*{3,}|_{3,})$").unwrap();
    let item = Regex::new(r"^([-*+]|(\d+)[.)])\s+(.*)$").unwrap();
    let mut blocks = vec![];
    let mut paragraph: Vec<String> = vec![];
    let flush = |paragraph: &mut Vec<String>, blocks: &mut Vec<Block>| {
        if !paragraph.is_empty() { blocks.push(Block::Paragraph(std::mem::take(paragraph))); }
    };
    let mut index = 0;
    while index < lines.len() {
        let line = lines[index];
        let trimmed = line.trim();
        if trimmed.starts_with("```") {
            flush(&mut paragraph, &mut blocks);
            let mut code = vec![];
            index += 1;
            while index < lines.len() && !lines[index].trim().starts_with("```") {
                code.push(lines[index].to_string());
                index += 1;
            }
            blocks.push(Block::Code(code));
            index += 1;
            continue;
        }
        if trimmed.starts_with('|') && index + 1 < lines.len() && is_divider(lines[index + 1]) {
            flush(&mut paragraph, &mut blocks);
            let mut rows = vec![cells(line)];
            index += 2;
            while index < lines.len() && lines[index].trim().starts_with('|') {
                rows.push(cells(lines[index]));
                index += 1;
            }
            blocks.push(Block::Table(rows));
            continue;
        }
        if trimmed.is_empty() {
            flush(&mut paragraph, &mut blocks);
        } else if let Some(c) = heading.captures(trimmed) {
            flush(&mut paragraph, &mut blocks);
            blocks.push(Block::Heading(c[1].len(), inline(c[2].trim())));
        } else if rule.is_match(trimmed) {
            flush(&mut paragraph, &mut blocks);
            blocks.push(Block::Rule);
        } else if let Some(c) = item.captures(trimmed) {
            flush(&mut paragraph, &mut blocks);
            blocks.push(Block::Item(c.get(2).and_then(|n| n.as_str().parse().ok()), inline(&c[3])));
        } else {
            paragraph.push(inline(trimmed));
        }
        index += 1;
    }
    flush(&mut paragraph, &mut blocks);
    blocks
}

/// A bot's HTML as the Markdown above, by its tags alone. Scripts, styles and everything inside them go; no tag is ever acted on.
pub fn html_to_markdown(html: &str) -> String {
    let mut text = html.to_string();
    for tag in ["script", "style", "head", "iframe", "object", "embed", "svg", "template", "noscript"] {
        text = Regex::new(&format!(r"(?is)<\s*{tag}\b.*?(<\s*/\s*{tag}\s*>|$)")).unwrap().replace_all(&text, "").to_string();
    }
    text = Regex::new(r"(?s)<!--.*?-->").unwrap().replace_all(&text, "").to_string();
    for (pattern, with) in [
        (r"(?i)<\s*h([1-6])\b[^>]*>", "\n\n${1}H "),
        (r"(?i)<\s*/\s*h[1-6]\s*>", "\n\n"),
        (r"(?i)<\s*li\b[^>]*>", "\n- "),
        (r"(?i)<\s*br\s*/?\s*>", "\n"),
        (r"(?i)<\s*hr\b[^>]*>", "\n\n---\n\n"),
        (r"(?i)<\s*tr\b[^>]*>", "\n|"),
        (r"(?i)<\s*/\s*t[dh]\s*>", " |"),
        (r"(?i)<\s*/?\s*(p|div|section|article|ul|ol|table|thead|tbody|blockquote|pre|header|footer|main)\b[^>]*>", "\n\n"),
        (r"<[^>]*>", ""),
    ] {
        text = Regex::new(pattern).unwrap().replace_all(&text, with).to_string();
    }
    // "2H Title" back to "## Title".
    text = Regex::new(r"(?m)^([1-6])H ").unwrap().replace_all(&text, |c: &regex::Captures| format!("{} ", "#".repeat(c[1].parse().unwrap_or(1)))).to_string();
    // A table's first row is its header.
    let mut out: Vec<String> = vec![];
    let mut in_table = false;
    for line in decode_entities(&text).lines() {
        let line = line.trim_end().to_string();
        let row = line.trim_start().starts_with('|');
        if row && !in_table {
            let columns = line.matches('|').count().saturating_sub(1).max(1);
            out.push(line);
            out.push(format!("|{}", " --- |".repeat(columns)));
        } else {
            out.push(line);
        }
        in_table = row;
    }
    out.join("\n")
}

fn decode_entities(text: &str) -> String {
    let numeric = Regex::new(r"&#(x[0-9a-fA-F]+|\d+);").unwrap();
    let text = numeric.replace_all(text, |c: &regex::Captures| {
        let raw = &c[1];
        let code = if let Some(hex) = raw.strip_prefix('x') { u32::from_str_radix(hex, 16).ok() } else { raw.parse().ok() };
        code.and_then(char::from_u32).map(|ch| ch.to_string()).unwrap_or_default()
    });
    text.replace("&nbsp;", " ").replace("&lt;", "<").replace("&gt;", ">").replace("&quot;", "\"").replace("&#39;", "'").replace("&apos;", "'").replace("&mdash;", "\u{2014}").replace("&ndash;", "\u{2013}").replace("&hellip;", "\u{2026}").replace("&amp;", "&")
}

// MARK: Writing the PDF

const PAGE_WIDTH: f32 = 595.0;
const PAGE_HEIGHT: f32 = 842.0;
const MARGIN: f32 = 56.0;

#[derive(Clone, Copy, PartialEq)]
enum Font { Regular, Bold, Mono }

impl Font {
    fn name(self) -> &'static str { match self { Font::Regular => "F1", Font::Bold => "F2", Font::Mono => "F3" } }
}

/// Helvetica's and Helvetica-Bold's widths for the printable ASCII characters (Adobe's metrics, per 1000 units).
const HELVETICA: [u16; 95] = [278, 278, 355, 556, 556, 889, 667, 191, 333, 333, 389, 584, 278, 333, 278, 278, 556, 556, 556, 556, 556, 556, 556, 556, 556, 556, 278, 278, 584, 584, 584, 556, 1015, 667, 667, 722, 722, 667, 611, 778, 722, 278, 500, 667, 556, 833, 722, 778, 667, 778, 722, 667, 611, 722, 667, 944, 667, 667, 611, 278, 278, 278, 469, 556, 333, 556, 556, 500, 556, 556, 278, 556, 556, 222, 222, 500, 222, 833, 556, 556, 556, 556, 333, 500, 278, 556, 500, 722, 500, 500, 500, 334, 260, 334, 584];
const HELVETICA_BOLD: [u16; 95] = [278, 333, 474, 556, 556, 889, 722, 238, 333, 333, 389, 584, 278, 333, 278, 278, 556, 556, 556, 556, 556, 556, 556, 556, 556, 556, 333, 333, 584, 584, 584, 611, 975, 722, 722, 722, 722, 667, 611, 778, 722, 278, 556, 722, 611, 833, 722, 778, 667, 778, 722, 667, 611, 722, 667, 944, 667, 667, 611, 333, 278, 333, 584, 556, 333, 556, 611, 556, 611, 556, 333, 611, 611, 278, 278, 556, 278, 889, 611, 611, 611, 611, 389, 556, 333, 611, 556, 778, 556, 556, 500, 389, 280, 389, 584];

/// The byte a character is in Windows-1252, the set the standard fonts draw; anything else is a question mark.
fn win_ansi(ch: char) -> u8 {
    match ch {
        ' '..='~' => ch as u8,
        '\u{a0}'..='\u{ff}' => ch as u32 as u8,
        '\u{20ac}' => 0x80, '\u{201a}' => 0x82, '\u{0192}' => 0x83, '\u{201e}' => 0x84, '\u{2026}' => 0x85, '\u{2020}' => 0x86, '\u{2021}' => 0x87,
        '\u{02c6}' => 0x88, '\u{2030}' => 0x89, '\u{0160}' => 0x8a, '\u{2039}' => 0x8b, '\u{0152}' => 0x8c, '\u{017d}' => 0x8e,
        '\u{2018}' => 0x91, '\u{2019}' => 0x92, '\u{201c}' => 0x93, '\u{201d}' => 0x94, '\u{2022}' => 0x95, '\u{2013}' => 0x96, '\u{2014}' => 0x97,
        '\u{02dc}' => 0x98, '\u{2122}' => 0x99, '\u{0161}' => 0x9a, '\u{203a}' => 0x9b, '\u{0153}' => 0x9c, '\u{017e}' => 0x9e, '\u{0178}' => 0x9f,
        '\t' => b' ',
        '\u{2212}' => b'-', '\u{2192}' => b'>', '\u{2190}' => b'<', '\u{2713}' | '\u{2714}' => b'v', '\u{2715}' | '\u{2717}' | '\u{2718}' => b'x',
        _ => b'?',
    }
}

fn width_of(text: &str, font: Font, size: f32) -> f32 {
    let units: u32 = text.chars().map(|ch| {
        let b = win_ansi(ch);
        match font {
            Font::Mono => 600,
            Font::Regular => if (32..=126).contains(&b) { HELVETICA[(b - 32) as usize] as u32 } else { 556 },
            Font::Bold => if (32..=126).contains(&b) { HELVETICA_BOLD[(b - 32) as usize] as u32 } else { 556 },
        }
    }).sum();
    units as f32 * size / 1000.0
}

/// Lines of at most `width` points, broken at spaces, and inside a word only when the word alone is too long.
fn wrap(text: &str, font: Font, size: f32, width: f32) -> Vec<String> {
    let mut lines = vec![];
    let mut line = String::new();
    for word in text.split(' ') {
        let candidate = if line.is_empty() { word.to_string() } else { format!("{line} {word}") };
        if width_of(&candidate, font, size) <= width || line.is_empty() && width_of(word, font, size) <= width {
            line = candidate;
            continue;
        }
        if !line.is_empty() { lines.push(std::mem::take(&mut line)); }
        let mut piece = String::new();
        for ch in word.chars() {
            piece.push(ch);
            if width_of(&piece, font, size) > width && piece.chars().count() > 1 {
                let last = piece.pop().unwrap();
                lines.push(std::mem::take(&mut piece));
                piece.push(last);
            }
        }
        line = piece;
    }
    lines.push(line);
    lines
}

fn literal(text: &str) -> String {
    let mut out = String::from("(");
    for ch in text.chars() {
        match win_ansi(ch) {
            b'(' => out.push_str("\\("),
            b')' => out.push_str("\\)"),
            b'\\' => out.push_str("\\\\"),
            b if b < 128 => out.push(b as char),
            b => out.push_str(&format!("\\{:03o}", b)),
        }
    }
    out.push(')');
    out
}

struct Pages {
    done: Vec<String>,
    current: String,
    y: f32,
}

impl Pages {
    fn new() -> Self { Self { done: vec![], current: String::new(), y: PAGE_HEIGHT - MARGIN } }
    fn room_for(&mut self, height: f32) {
        if self.y - height < MARGIN && self.y < PAGE_HEIGHT - MARGIN - 1.0 {
            self.done.push(std::mem::take(&mut self.current));
            self.y = PAGE_HEIGHT - MARGIN;
        }
    }
    fn text(&mut self, x: f32, baseline: f32, font: Font, size: f32, text: &str) {
        self.current.push_str(&format!("BT /{} {:.1} Tf {:.2} {:.2} Td {} Tj ET\n", font.name(), size, x, baseline, literal(text)));
    }
    /// Lines of one style, each moving down by `leading`, onto a new page when the next one doesn't fit.
    fn lines(&mut self, x: f32, lines: &[String], font: Font, size: f32, leading: f32) {
        for line in lines {
            self.room_for(leading);
            self.y -= leading;
            let baseline = self.y + (leading - size) / 2.0 + size * 0.22;
            self.text(x, baseline, font, size, line);
        }
    }
    fn finish(mut self) -> Vec<String> {
        if !self.current.is_empty() || self.done.is_empty() { self.done.push(self.current); }
        self.done
    }
}

/// The blocks laid out on A4 pages with 56-point margins, as the Mac's.
pub fn render(blocks: &[Block], title: &str) -> Vec<u8> {
    let width = PAGE_WIDTH - 2.0 * MARGIN;
    let mut pages = Pages::new();
    for (index, block) in blocks.iter().enumerate() {
        let first = index == 0;
        match block {
            Block::Heading(level, text) => {
                let size = match level { 1 => 20.0, 2 => 15.0, 3 => 12.5, _ => 11.5 };
                if !first { pages.room_for(size * 3.0); pages.y -= if *level <= 2 { 10.0 } else { 6.0 }; }
                pages.lines(MARGIN, &wrap(text, Font::Bold, size, width), Font::Bold, size, size * 1.25);
                pages.y -= 4.0;
            }
            Block::Paragraph(lines) => {
                for line in lines { pages.lines(MARGIN, &wrap(line, Font::Regular, 11.0, width), Font::Regular, 11.0, 15.0); }
                pages.y -= 6.0;
            }
            Block::Item(number, text) => {
                let mark = number.map(|n| format!("{n}.")).unwrap_or_else(|| "\u{2022}".to_string());
                let wrapped = wrap(text, Font::Regular, 11.0, width - 16.0);
                pages.room_for(15.0);
                let top = pages.y;
                pages.text(MARGIN + 2.0, top - 15.0 + 2.0 + 11.0 * 0.22, Font::Regular, 11.0, &mark);
                pages.lines(MARGIN + 16.0, &wrapped, Font::Regular, 11.0, 15.0);
                let next_is_item = matches!(blocks.get(index + 1), Some(Block::Item(..)));
                pages.y -= if next_is_item { 1.0 } else { 6.0 };
            }
            Block::Rule => {
                pages.room_for(14.0);
                pages.y -= 7.0;
                pages.current.push_str(&format!("0.6 G 0.5 w {MARGIN:.2} {y:.2} m {right:.2} {y:.2} l S 0 G\n", y = pages.y, right = PAGE_WIDTH - MARGIN));
                pages.y -= 7.0;
            }
            Block::Code(lines) => {
                for line in lines {
                    let wrapped = wrap(&line.replace('\t', "    "), Font::Mono, 9.5, width - 8.0);
                    pages.lines(MARGIN + 4.0, &wrapped, Font::Mono, 9.5, 12.0);
                }
                pages.y -= 8.0;
            }
            Block::Table(rows) => {
                let columns = rows.iter().map(|r| r.len()).max().unwrap_or(1).max(1);
                let cell_width = width / columns as f32;
                for (row_index, row) in rows.iter().enumerate() {
                    let font = if row_index == 0 { Font::Bold } else { Font::Regular };
                    let wrapped: Vec<Vec<String>> = (0..columns).map(|c| wrap(row.get(c).map(String::as_str).unwrap_or(""), font, 10.0, cell_width - 12.0)).collect();
                    let height = wrapped.iter().map(|w| w.len()).max().unwrap_or(1) as f32 * 13.0 + 6.0;
                    pages.room_for(height);
                    let top = pages.y;
                    if row_index == 0 {
                        pages.current.push_str(&format!("0.93 g {MARGIN:.2} {:.2} {width:.2} {height:.2} re f 0 g\n", top - height));
                    }
                    for (c, lines) in wrapped.iter().enumerate() {
                        let x = MARGIN + c as f32 * cell_width;
                        pages.current.push_str(&format!("0.6 G 0.5 w {x:.2} {:.2} {cell_width:.2} {height:.2} re S 0 G\n", top - height));
                        for (n, line) in lines.iter().enumerate() {
                            let baseline = top - 3.0 - 13.0 * (n as f32 + 1.0) + 3.0;
                            pages.text(x + 6.0, baseline, font, 10.0, line);
                        }
                    }
                    pages.y = top - height;
                }
                pages.y -= 8.0;
            }
        }
    }
    document(&pages.finish(), title)
}

fn document(pages: &[String], title: &str) -> Vec<u8> {
    let mut objects: Vec<String> = vec![];
    // 1 catalog, 2 pages, 3-5 fonts, 6 info, then a page and its contents for each page.
    let first_page = 7;
    let kids: Vec<String> = (0..pages.len()).map(|i| format!("{} 0 R", first_page + i * 2)).collect();
    objects.push("<< /Type /Catalog /Pages 2 0 R >>".into());
    objects.push(format!("<< /Type /Pages /Kids [{}] /Count {} >>", kids.join(" "), pages.len()));
    objects.push("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>".into());
    objects.push("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica-Bold /Encoding /WinAnsiEncoding >>".into());
    objects.push("<< /Type /Font /Subtype /Type1 /BaseFont /Courier /Encoding /WinAnsiEncoding >>".into());
    objects.push(format!("<< /Title {} /Producer (Vello) >>", literal(title)));
    for (i, content) in pages.iter().enumerate() {
        objects.push(format!("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 {PAGE_WIDTH} {PAGE_HEIGHT}] /Resources << /Font << /F1 3 0 R /F2 4 0 R /F3 5 0 R >> >> /Contents {} 0 R >>", first_page + i * 2 + 1));
        objects.push(format!("<< /Length {} >>\nstream\n{}endstream", content.len(), content));
    }
    let mut out: Vec<u8> = b"%PDF-1.4\n%\xe2\xe3\xcf\xd3\n".to_vec();
    let mut offsets = vec![];
    for (i, object) in objects.iter().enumerate() {
        offsets.push(out.len());
        out.extend_from_slice(format!("{} 0 obj\n{}\nendobj\n", i + 1, object).as_bytes());
    }
    let xref = out.len();
    out.extend_from_slice(format!("xref\n0 {}\n0000000000 65535 f \n", objects.len() + 1).as_bytes());
    for offset in offsets { out.extend_from_slice(format!("{offset:010} 00000 n \n").as_bytes()); }
    out.extend_from_slice(format!("trailer\n<< /Size {} /Root 1 0 R /Info 6 0 R >>\nstartxref\n{xref}\n%%EOF\n", objects.len() + 1).as_bytes());
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn page_count(pdf: &[u8]) -> usize {
        let text = String::from_utf8_lossy(pdf);
        text.matches("/Type /Page /Parent").count()
    }

    /// Every entry of the cross-reference table points at its own object, so readers open it without repairing it.
    fn xref_is_right(pdf: &[u8]) -> bool {
        // One character a byte, so offsets stay byte offsets.
        let text: String = pdf.iter().map(|&b| if b < 128 { b as char } else { '?' }).collect();
        let start: usize = text.rsplit("startxref\n").next().unwrap().lines().next().unwrap().parse().unwrap();
        let table = &text[start..];
        let mut lines = table.lines().skip(2);
        lines.next();
        let mut number = 1;
        for line in lines.take_while(|l| l.ends_with(" n ")) {
            let offset: usize = line[..10].parse().unwrap();
            if !text[offset..].starts_with(&format!("{number} 0 obj")) { return false; }
            number += 1;
        }
        number > 6
    }

    #[test]
    fn tags_come_out_of_the_reply_and_at_most_three_count() {
        let (text, files) = extract("Here it is.\n[PDF: report.md]\nThanks [pdf : notes.html] and [PDF: a] [PDF: b]");
        assert_eq!(files, vec!["report.md", "notes.html", "a"]);
        assert!(!text.contains("[PDF") && !text.contains("[pdf") && text.starts_with("Here it is."));
        assert_eq!(extract("no tags").1.len(), 0);
    }

    #[test]
    fn only_files_inside_the_folder() {
        let dir = tempfile::tempdir().unwrap();
        let folder = dir.path().join("memory");
        std::fs::create_dir_all(&folder).unwrap();
        std::fs::write(folder.join("doc.md"), "# Hi").unwrap();
        std::fs::write(dir.path().join("secret.md"), "no").unwrap();
        assert!(file_named("doc.md", &folder).is_some());
        assert!(file_named("`doc.md`", &folder).is_some());
        assert!(file_named("../secret.md", &folder).is_none());
        assert!(file_named(&dir.path().join("secret.md").to_string_lossy(), &folder).is_none());
        assert!(file_named("missing.md", &folder).is_none());
        assert!(file_named("", &folder).is_none());
    }

    #[test]
    fn markdown_becomes_blocks() {
        let blocks = markdown_blocks("# Title\n\nSome **bold** words and a [link](https://x.y).\n\n- one\n- two\n\n| A | B |\n|---|---|\n| 1 | 2 |\n\n---\n\n```\ncode here\n```");
        assert_eq!(blocks[0], Block::Heading(1, "Title".into()));
        assert_eq!(blocks[1], Block::Paragraph(vec!["Some bold words and a link (https://x.y).".into()]));
        assert_eq!(blocks[2], Block::Item(None, "one".into()));
        assert_eq!(blocks[4], Block::Table(vec![vec!["A".into(), "B".into()], vec!["1".into(), "2".into()]]));
        assert_eq!(blocks[5], Block::Rule);
        assert_eq!(blocks[6], Block::Code(vec!["code here".into()]));
    }

    #[test]
    fn html_is_read_for_structure_only() {
        let md = html_to_markdown("<html><head><style>body{background:url(x)}</style></head><body><h2>Plan</h2><p>Fish &amp; chips</p><script>alert(1)</script><img src=\"file:///etc/passwd\"><ul><li>a</li></ul><table><tr><th>K</th><th>V</th></tr><tr><td>1</td><td>2</td></tr></table></body></html>");
        let blocks = markdown_blocks(&md);
        assert!(blocks.contains(&Block::Heading(2, "Plan".into())));
        assert!(blocks.contains(&Block::Paragraph(vec!["Fish & chips".into()])));
        assert!(blocks.contains(&Block::Item(None, "a".into())));
        assert!(blocks.iter().any(|b| matches!(b, Block::Table(rows) if rows.len() == 2 && rows[1] == vec!["1".to_string(), "2".to_string()])));
        assert!(!md.contains("alert") && !md.contains("passwd") && !md.contains("url("));
    }

    #[test]
    fn a_long_document_is_a_real_paged_pdf() {
        let mut text = String::from("# A long report\n\n");
        for i in 0..120 { text.push_str(&format!("Paragraph {i} says something about the plan (with brackets) and a back\\slash, café and “quotes”.\n\n")); }
        let pdf = render(&markdown_blocks(&text), "Report");
        assert!(pdf.starts_with(b"%PDF-1.4"));
        assert!(pdf.ends_with(b"%%EOF\n"));
        assert!(page_count(&pdf) > 2, "{}", page_count(&pdf));
        assert!(xref_is_right(&pdf));
        let body = String::from_utf8_lossy(&pdf);
        assert!(body.contains("\\(with brackets\\)") && body.contains("back\\\\slash") && body.contains("caf\\351") && body.contains("\\223quotes\\224"));
    }

    #[test]
    fn an_empty_document_is_one_page() {
        let pdf = render(&[], "Empty");
        assert_eq!(page_count(&pdf), 1);
        assert!(xref_is_right(&pdf));
    }

    #[test]
    fn long_words_and_lines_wrap_inside_the_margins() {
        let width = PAGE_WIDTH - 2.0 * MARGIN;
        for line in wrap(&"word ".repeat(80), Font::Regular, 11.0, width).iter().chain(wrap(&"x".repeat(400), Font::Mono, 9.5, width).iter()) {
            assert!(width_of(line, Font::Regular, 11.0).min(width_of(line, Font::Mono, 9.5)) <= width + 0.01, "{line}");
        }
        assert!(wrap(&"x".repeat(400), Font::Mono, 9.5, width).len() > 4);
    }

    #[test]
    fn make_writes_the_pdf_beside_the_file() {
        let dir = tempfile::tempdir().unwrap();
        std::fs::write(dir.path().join("brief.md"), "# Brief\n\nHello.").unwrap();
        let out = make("brief.md", dir.path()).unwrap();
        assert_eq!(out.file_name().unwrap(), "brief.pdf");
        assert!(std::fs::read(&out).unwrap().starts_with(b"%PDF"));
        assert!(make("nope.md", dir.path()).unwrap_err().contains("no file called nope.md"));
    }
}
