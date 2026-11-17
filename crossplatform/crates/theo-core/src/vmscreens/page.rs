//! The pure rules for reading the web, ported from ClickyCore `Research/Research.swift` and `Research/BrowserResearch.swift`:
//! which addresses may be read at all, which may open in a VM screen, what a human check looks like, the readable text of a
//! page (its article or main part first), DuckDuckGo's plain results page, and joining the text runs a screen read.
//!
//! A VM screen only ever opens and reads. Nothing here gets past a human check: that becomes a card for the owner.

use regex::Regex;
use url::{Host, Url};

/// The most a page read in a VM screen keeps (the Mac's `BrowserResearchPolicy.maximumCharacters`).
pub const MAXIMUM_BROWSER_CHARACTERS: usize = 40_000;
/// The most a plainly fetched page keeps (the Mac's `ReadableText.maximumCharacters`).
pub const MAXIMUM_READABLE_CHARACTERS: usize = 30_000;
/// A plain fetch reads at most this much of a page (`ResearchURLPolicy.maximumBytes`).
pub const MAXIMUM_BYTES: u64 = 2_000_000;
/// A plain fetch gives up after this long (`ResearchURLPolicy.timeoutSeconds`).
pub const FETCH_TIMEOUT_SECONDS: u64 = 15;

/// Only plain public web pages: http(s), not localhost, private or link-local addresses, no file:. A test profile may read
/// pages served on 127.0.0.1 (`allows_local_host_for_tests`).
pub fn is_allowed(url: &Url, allows_local_host_for_tests: bool) -> bool {
    if url.scheme() != "http" && url.scheme() != "https" {
        return false;
    }
    let Some(host) = url.host() else { return false };
    match host {
        Host::Ipv6(_) => false,
        Host::Ipv4(address) => {
            if allows_local_host_for_tests && address.is_loopback() {
                return true;
            }
            let [first, second, _, _] = address.octets();
            !(first == 10
                || first == 127
                || first == 0
                || (first == 169 && second == 254)
                || (first == 192 && second == 168)
                || (first == 172 && (16..=31).contains(&second))
                || (first == 100 && (64..=127).contains(&second))
                || address.is_broadcast()
                || address.is_multicast())
        }
        Host::Domain(name) => {
            let name = name.to_lowercase();
            if name.is_empty() {
                return false;
            }
            if allows_local_host_for_tests && name == "localhost" {
                return true;
            }
            !(name == "localhost" || name.ends_with(".localhost") || name.ends_with(".local") || name.ends_with(".internal"))
        }
    }
}

/// Search engines' own pages aren't sources.
pub fn is_search_engine(url: &Url) -> bool {
    let host = url.host_str().unwrap_or("").to_lowercase();
    ["google.", "bing.com", "duckduckgo.com", "search.yahoo", "yandex.", "baidu.com", "webcache.googleusercontent"].iter().any(|word| host.contains(word))
}

/// Hosts that are someone's private life, not sources.
const PRIVATE_HOSTS: [&str; 21] = [
    "mail.", "outlook.", "accounts.", "myaccount.", "login.", "signin.", "auth.", "icloud.", "drive.google.", "docs.google.", "calendar.google.",
    "contacts.google.", "photos.google.", "paypal.", "stripe.", "razorpay.", "paytm.", "phonepe.", "wise.com", "web.whatsapp.", "messages.google.",
];
const PRIVATE_HOST_WORDS: [&str; 8] = ["bank", "billing", "wallet", "broker", "zerodha", "groww", "coinbase", "binance"];
/// Addresses that do something when visited, or show an account.
const ACTION_PATH_WORDS: [&str; 24] = [
    "login", "logout", "log-out", "signin", "sign-in", "signout", "sign-out", "account", "settings", "billing", "checkout", "cart", "payment", "invoice",
    "unsubscribe", "delete", "remove", "cancel", "confirm", "approve", "oauth", "authorize", "password", "admin",
];
const SECRET_QUERY_WORDS: [&str; 11] = ["token", "secret", "password", "session", "apikey", "api_key", "auth", "otp", "code", "key", "sig"];

/// Whether this address may open in a VM screen: stricter than a plain fetch (the Mac's `BrowserResearchPolicy.mayOpen`). A VM
/// screen has no logins, but a page must still not be able to send it somewhere that does something.
pub fn may_open(url: &Url, allows_local_host_for_tests: bool) -> bool {
    if !is_allowed(url, allows_local_host_for_tests) || !url.username().is_empty() || url.password().is_some() {
        return false;
    }
    let text = url.as_str();
    if !text.to_lowercase().starts_with("http") || text.contains(' ') {
        return false;
    }
    let host = url.host_str().unwrap_or("").to_lowercase();
    if PRIVATE_HOSTS.iter().any(|private| host.starts_with(private) || host.contains(&format!(".{private}"))) {
        return false;
    }
    if PRIVATE_HOST_WORDS.iter().any(|word| host.contains(word)) {
        return false;
    }
    let path = url.path().to_lowercase();
    if path.split(|c: char| "/._".contains(c)).any(|word| ACTION_PATH_WORDS.contains(&word)) {
        return false;
    }
    !url.query_pairs().any(|(name, _)| SECRET_QUERY_WORDS.contains(&name.to_lowercase().as_str()))
}

const WALL_WORDS: [&str; 12] = [
    "subscribe to continue", "sign in to continue", "log in to continue", "to continue reading", "create a free account", "enable javascript",
    "powered and protected by", "verify you are human", "checking your browser", "just a moment", "access denied", "are you a robot",
];

/// Paywall and sign-in walls: too little text plus wall words.
pub fn looks_walled(text: &str) -> bool {
    let lowered = text.to_lowercase();
    text.chars().count() < 600 && WALL_WORDS.iter().any(|word| lowered.contains(word))
}

/// The plain fetch came back with nothing useful: nothing at all, a wall, or a shell of a page waiting on scripts.
pub fn needs_browser(text: Option<&str>) -> bool {
    match text.map(str::trim) {
        None | Some("") => true,
        Some(text) => looks_walled(text) || text.chars().count() < 200,
    }
}

const HUMAN_CHECK_WORDS: [&str; 16] = [
    "verify you are human", "verify you're human", "verifying you are human", "confirm you are human", "confirm you're human", "are you a robot",
    "are you human", "i'm not a robot", "not a robot", "checking your browser", "checking if the site connection is secure", "unusual traffic",
    "press and hold", "press & hold", "complete the security check", "captcha",
];

/// A page asking for a person (a captcha, "are you human", a browser check). Long pages only mention these words, so only
/// short ones count.
pub fn is_human_check(title: Option<&str>, text: &str) -> bool {
    let body = text.to_lowercase();
    if title.unwrap_or("").to_lowercase().contains("just a moment") {
        return true;
    }
    body.chars().count() < 1_500 && (HUMAN_CHECK_WORDS.iter().any(|word| body.contains(word)) || body.contains("just a moment"))
}

/// Text runs from a page, in order: one block joins with spaces, a new block starts a line (the Mac's
/// `BrowserResearchPolicy.joined`).
pub fn joined(runs: &[(String, i64)]) -> String {
    let mut output = String::new();
    let mut last_block: Option<i64> = None;
    for (text, block) in runs {
        let piece = text.trim();
        if piece.is_empty() {
            continue;
        }
        if let Some(last) = last_block {
            output.push(if last == *block { ' ' } else { '\n' });
        }
        output.push_str(piece);
        last_block = Some(*block);
        if output.chars().count() >= MAXIMUM_BROWSER_CHARACTERS {
            return output.chars().take(MAXIMUM_BROWSER_CHARACTERS).collect();
        }
    }
    output
}

/// The script a VM screen runs to read its page: the longest `<article>`, else `<main>`, when it holds the page's words, else
/// the body, without scripts, styles, navigation, headers, footers, forms and asides, and only what's drawn. Text runs come
/// back with their block, so the words join the way the Mac's Accessibility reader joins them. It reads; it changes nothing.
pub const READER_SCRIPT: &str = r#"(() => {
  const SKIP = "script,style,noscript,template,svg,iframe,nav,header,footer,aside,form,button,select,textarea,[aria-hidden=true]";
  const words = (element) => ((element && element.innerText) || "").split(/\s+/).filter(Boolean).length;
  const body = document.body;
  if (!body) return JSON.stringify({ title: document.title, url: location.href, runs: [] });
  const bodyWords = words(body);
  let best = null, bestWords = 0;
  for (const article of document.querySelectorAll("article")) { const count = words(article); if (count > bestWords) { best = article; bestWords = count; } }
  let root = best || document.querySelector("main, [role=main]");
  if (!root || !(words(root) >= 150 || words(root) * 3 >= bodyWords)) root = body;
  const BLOCK = /^(P|DIV|LI|H[1-6]|TD|TH|TR|SECTION|ARTICLE|BLOCKQUOTE|PRE|DD|DT|FIGCAPTION|UL|OL|TABLE|MAIN|BODY)$/;
  const blocks = new Map();
  const runs = [];
  let total = 0;
  const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
  while (walker.nextNode() && total < 40000) {
    const node = walker.currentNode, parent = node.parentElement;
    if (!parent) continue;
    const skipped = parent.closest(SKIP);
    if (skipped && root.contains(skipped)) continue;
    if (parent.getClientRects().length === 0) continue;
    const text = (node.nodeValue || "").replace(/\s+/g, " ").trim();
    if (!text) continue;
    let block = parent;
    while (block && block !== root && !BLOCK.test(block.tagName)) block = block.parentElement;
    if (!blocks.has(block)) blocks.set(block, blocks.size);
    runs.push([text, blocks.get(block)]);
    total += text.length + 1;
  }
  return JSON.stringify({ title: document.title, url: location.href, runs });
})()"#;

fn regex(pattern: &str) -> Regex {
    Regex::new(pattern).expect("a fixed pattern")
}

/// HTML entities to characters: the named ones pages use most, and numeric ones.
pub fn decode_entities(text: &str) -> String {
    let mut result = text.to_string();
    for (entity, character) in [
        ("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"), ("&rsquo;", "\u{2019}"), ("&lsquo;", "\u{2018}"),
        ("&ldquo;", "\u{201C}"), ("&rdquo;", "\u{201D}"), ("&mdash;", "\u{2014}"), ("&ndash;", "\u{2013}"), ("&hellip;", "\u{2026}"),
    ] {
        result = result.replace(entity, character);
    }
    let numeric = regex(r"&#(x?[0-9a-fA-F]+);");
    result = numeric
        .replace_all(&result, |captures: &regex::Captures| {
            let code = &captures[1];
            let value = match code.strip_prefix('x') {
                Some(hex) => u32::from_str_radix(hex, 16).ok(),
                None => code.parse::<u32>().ok(),
            };
            value.and_then(char::from_u32).map(String::from).unwrap_or_default()
        })
        .to_string();
    // Last, so "&amp;lt;" stays "&lt;" as written.
    result.replace("&amp;", "&")
}

fn strip_tags(html: &str) -> String {
    regex(r"<[^>]+>").replace_all(html, " ").to_string()
}

fn word_count(html: &str) -> usize {
    strip_tags(html).split_whitespace().count()
}

/// The readable text of a page fetched plainly (the Mac's `ReadableText.extract`): its title, and the longest `<article>`'s
/// words (else `<main>`'s) when they hold the page, else the body's, without scripts, styles, navigation and the like.
pub fn readable_text(html: &str) -> (Option<String>, String) {
    let title = regex(r"(?is)<title[^>]*>(.*?)</title>").captures(html).map(|c| decode_entities(&strip_tags(&c[1])).trim().to_string()).filter(|t| !t.is_empty());
    let mut body = html.to_string();
    for tag in ["script", "style", "noscript", "svg", "nav", "header", "footer", "form", "aside", "iframe", "template"] {
        body = regex(&format!(r"(?is)<{tag}\b[^>]*>.*?</{tag}>")).replace_all(&body, " ").to_string();
    }
    let articles: Vec<String> = regex(r"(?is)<article\b[^>]*>(.*?)</article>").captures_iter(&body).map(|c| c[1].to_string()).collect();
    let article = articles.into_iter().max_by_key(|a| word_count(a)).or_else(|| regex(r"(?is)<main\b[^>]*>(.*?)</main>").captures(&body).map(|c| c[1].to_string()));
    let body_words = word_count(&body);
    if let Some(article) = article.filter(|a| word_count(a) >= 150 || word_count(a) * 3 >= body_words) {
        body = article;
    } else if let Some(inside) = regex(r"(?is)<body\b[^>]*>(.*?)</body>").captures(&body) {
        body = inside[1].to_string();
    }
    body = regex(r"(?i)<(?:/p|br\s*/?|/h[1-6]|/li|/div|/tr)>").replace_all(&body, "\n").to_string();
    let mut text = decode_entities(&strip_tags(&body));
    text = regex(r"[ \t\u{00A0}]+").replace_all(&text, " ").to_string();
    text = regex(r"\s*\n\s*").replace_all(&text, "\n").to_string();
    text = regex(r"\n{3,}").replace_all(&text, "\n\n").trim().to_string();
    if text.chars().count() > MAXIMUM_READABLE_CHARACTERS {
        text = text.chars().take(MAXIMUM_READABLE_CHARACTERS).collect();
    }
    (title, text)
}

/// DuckDuckGo's plain HTML results page for a question (no key, no JavaScript). A test profile may name its own page with a
/// `{q}` where the question goes.
pub fn search_url(question: &str, template: Option<&str>) -> String {
    let encoded: String = url::form_urlencoded::byte_serialize(question.as_bytes()).collect();
    match template {
        Some(template) if template.contains("{q}") => template.replace("{q}", &encoded),
        _ => format!("https://html.duckduckgo.com/html/?q={encoded}"),
    }
}

/// The results on DuckDuckGo's plain results page: each result's address and title, one per site, at most `maximum`
/// (the Mac's `ResearchSearchResults.results`). `allows_local_host_for_tests` lets a test's own results page point at
/// pages on 127.0.0.1.
pub fn search_results(html: &str, maximum: usize, allows_local_host_for_tests: bool) -> Vec<(Url, String)> {
    let link = regex(r#"(?is)<a[^>]+class="result__a"[^>]+href="([^"]+)"[^>]*>(.*?)</a>"#);
    let link_href_first = regex(r#"(?is)<a[^>]+href="([^"]+)"[^>]+class="result__a"[^>]*>(.*?)</a>"#);
    let mut seen_hosts: Vec<String> = vec![];
    let mut found = vec![];
    let matches: Vec<(String, String)> = link
        .captures_iter(html)
        .map(|c| (c[1].to_string(), c[2].to_string()))
        .chain(link_href_first.captures_iter(html).map(|c| (c[1].to_string(), c[2].to_string())))
        .collect();
    // In page order, whichever way round the attributes were written.
    let mut ordered: Vec<(usize, String, String)> = matches.into_iter().filter_map(|(href, title)| html.find(&format!("href=\"{href}\"")).map(|at| (at, href, title))).collect();
    ordered.sort_by_key(|(at, _, _)| *at);
    ordered.dedup_by(|a, b| a.0 == b.0);
    for (_, href, title) in ordered {
        let mut address = decode_entities(&href);
        if address.starts_with("//") {
            address = format!("https:{address}");
        }
        // DuckDuckGo wraps results: /l/?uddg=<the real address>.
        if let Ok(wrapped) = Url::parse(&address).or_else(|_| Url::parse("https://duckduckgo.com").and_then(|base| base.join(&address))) {
            if let Some((_, target)) = wrapped.query_pairs().find(|(name, _)| name == "uddg") {
                address = target.to_string();
            }
        }
        let Ok(url) = Url::parse(&address) else { continue };
        if !is_allowed(&url, allows_local_host_for_tests) || is_search_engine(&url) {
            continue;
        }
        let host = url.host_str().unwrap_or("").to_lowercase();
        // One result a site; a test's pages all live on one host, so they're told apart by their path there.
        let site = if allows_local_host_for_tests && (host == "127.0.0.1" || host == "localhost") { format!("{host}{}", url.path()) } else { host };
        if seen_hosts.contains(&site) {
            continue;
        }
        seen_hosts.push(site);
        let words = decode_entities(&regex(r"<[^>]+>").replace_all(&title, "")).trim().to_string();
        let shown = if words.is_empty() { url.host_str().unwrap_or("").to_string() } else { words };
        found.push((url, shown));
        if found.len() >= maximum {
            break;
        }
    }
    found
}

/// A short topic from a question: its first six words.
pub fn short_topic(question: &str) -> String {
    let words: Vec<&str> = question.split_whitespace().take(6).collect();
    if words.is_empty() { "research".into() } else { words.join(" ") }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn u(text: &str) -> Url {
        Url::parse(text).unwrap()
    }

    #[test]
    fn only_public_web_pages_are_read() {
        assert!(is_allowed(&u("https://example.com/a"), false));
        assert!(!is_allowed(&u("file:///etc/passwd"), false));
        assert!(!is_allowed(&u("http://localhost:8080/"), false));
        assert!(!is_allowed(&u("http://127.0.0.1/"), false));
        assert!(!is_allowed(&u("http://2130706433/"), false), "a decimal address is still 127.0.0.1");
        assert!(!is_allowed(&u("http://192.168.1.4/router"), false));
        assert!(!is_allowed(&u("http://10.0.0.1/"), false));
        assert!(!is_allowed(&u("http://172.20.0.1/"), false));
        assert!(!is_allowed(&u("http://169.254.169.254/latest/meta-data"), false));
        assert!(!is_allowed(&u("http://[::1]/"), false));
        assert!(!is_allowed(&u("http://printer.local/"), false));
        assert!(is_allowed(&u("http://127.0.0.1:9000/page"), true), "a test profile reads its own pages");
        assert!(!is_allowed(&u("http://192.168.1.4/"), true), "but never the network around it");
    }

    #[test]
    fn a_screen_opens_less_than_a_plain_fetch_reads() {
        assert!(may_open(&u("https://en.wikipedia.org/wiki/Rust"), false));
        assert!(may_open(&u("https://html.duckduckgo.com/html/?q=rust"), false));
        assert!(!may_open(&u("https://mail.google.com/mail/u/0"), false));
        assert!(!may_open(&u("https://www.mybank.com/"), false));
        assert!(!may_open(&u("https://shop.example.com/checkout"), false));
        assert!(!may_open(&u("https://example.com/account/delete"), false));
        assert!(!may_open(&u("https://example.com/page?token=abc"), false));
        assert!(!may_open(&u("https://user:pass@example.com/"), false));
        assert!(!may_open(&u("http://127.0.0.1/x"), false));
    }

    #[test]
    fn human_checks_are_short_pages_asking_for_a_person() {
        assert!(is_human_check(Some("Just a moment..."), "Checking your browser"));
        assert!(is_human_check(None, "Please verify you are human by completing the captcha below."));
        assert!(is_human_check(None, "Our systems have detected unusual traffic from your computer network."));
        let long = format!("{} This article explains what a captcha is.", "Words about the web. ".repeat(100));
        assert!(!is_human_check(Some("CAPTCHA - Wikipedia"), &long), "a long page that only mentions one isn't one");
        assert!(!is_human_check(Some("Rust"), "Rust is a language."));
    }

    #[test]
    fn walls_and_shells_need_more_than_a_plain_fetch() {
        assert!(needs_browser(None));
        assert!(needs_browser(Some("  ")));
        assert!(needs_browser(Some("Please enable JavaScript to continue.")));
        assert!(needs_browser(Some("short")));
        assert!(!needs_browser(Some(&"A real paragraph of words. ".repeat(20))));
    }

    #[test]
    fn runs_join_by_block() {
        let runs = vec![("Hello".to_string(), 0), ("world.".to_string(), 0), ("  ".to_string(), 1), ("Next".to_string(), 2), ("line".to_string(), 2)];
        assert_eq!(joined(&runs), "Hello world.\nNext line");
        let long: Vec<(String, i64)> = (0..10_000).map(|n| ("word".to_string(), n)).collect();
        assert_eq!(joined(&long).chars().count(), MAXIMUM_BROWSER_CHARACTERS);
    }

    #[test]
    fn readable_text_takes_the_article_and_drops_the_chrome() {
        let html = r#"<html><head><title>Ferns &amp; moss</title><style>p{}</style></head><body><nav>Home About</nav><header>Site</header>
<article><h1>Ferns</h1><p>Ferns like shade&#8217;s damp.</p><p>They need water.</p></article><footer>Copyright</footer><script>var x=1</script></body></html>"#;
        let (title, text) = readable_text(html);
        assert_eq!(title.as_deref(), Some("Ferns & moss"));
        assert!(text.contains("Ferns like shade\u{2019}s damp."), "{text}");
        assert!(text.contains("They need water."));
        for gone in ["Home About", "Copyright", "var x", "Site"] {
            assert!(!text.contains(gone), "{gone} in {text}");
        }
    }

    #[test]
    fn duckduckgo_results_are_unwrapped_one_per_site() {
        let html = r#"
<a rel="nofollow" class="result__a" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fen.wikipedia.org%2Fwiki%2FFern&amp;rut=1">The <b>Fern</b> - Wikipedia</a>
<a rel="nofollow" class="result__a" href="https://en.wikipedia.org/wiki/Moss">Moss</a>
<a rel="nofollow" class="result__a" href="https://www.rhs.org.uk/ferns">Growing ferns | RHS</a>
<a rel="nofollow" class="result__a" href="https://duckduckgo.com/y.js?ad=1">Ad</a>
<a rel="nofollow" class="result__a" href="http://127.0.0.1/secret">Local</a>"#;
        let found = search_results(html, 8, false);
        let addresses: Vec<String> = found.iter().map(|(url, _)| url.to_string()).collect();
        assert_eq!(addresses, vec!["https://en.wikipedia.org/wiki/Fern", "https://www.rhs.org.uk/ferns"]);
        assert_eq!(found[0].1, "The Fern - Wikipedia");
        assert_eq!(search_results(html, 1, false).len(), 1);
    }

    #[test]
    fn a_test_profile_names_its_own_search_page() {
        assert_eq!(search_url("ferns & moss", None), "https://html.duckduckgo.com/html/?q=ferns+%26+moss");
        assert_eq!(search_url("ferns", Some("http://127.0.0.1:9/search?q={q}")), "http://127.0.0.1:9/search?q=ferns");
        let html = r#"<a class="result__a" href="http://127.0.0.1:9/a.html">A</a><a class="result__a" href="http://127.0.0.1:9/b.html">B</a>"#;
        assert_eq!(search_results(html, 8, true).len(), 2, "a test's pages share one host");
    }
}
