//! Theo's local API: programs on this computer can message a bot or fire a routine over HTTP on 127.0.0.1. Off by default; every
//! request needs the token; what comes in this way is never the owner's own words. Port of the Swift `TheoGateway`.

use crate::harness::Harness;
use serde_json::{json, Value};
use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use tokio::io::{AsyncReadExt, AsyncWriteExt};

pub const MAX_BODY: usize = 64 * 1024;
pub const MAX_HEADER: usize = 16 * 1024;
pub const MAX_TEXT: usize = 16_000;

#[derive(Default)]
pub struct GatewayHandle {
    inner: Mutex<GatewayInner>,
}

#[derive(Default)]
struct GatewayInner {
    port: Option<u16>,
    task: Option<tokio::task::JoinHandle<()>>,
    problem: Option<String>,
    stamps: Vec<f64>,
}

impl GatewayHandle {
    pub fn report(&self, h: &Harness) -> Value {
        let g = self.inner.lock().unwrap();
        json!({"enabled": h.settings.gateway_enabled(), "listening": g.port, "port": h.settings.gateway_port(),
               "hasToken": crate::secrets::read(&h.paths.token_file(), h.settings.is_test).is_some(), "problem": g.problem,
               "received": h.with(|s| s.gateway_recent.len())})
    }
    /// At most 30 work requests in any 60 seconds.
    fn allow(&self) -> bool {
        let now = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_secs_f64();
        let mut g = self.inner.lock().unwrap();
        g.stamps.retain(|t| now - t < 60.0);
        if g.stamps.len() >= 30 { return false; }
        g.stamps.push(now);
        true
    }
}

/// Starts or stops the API to match the setting.
pub fn apply(h: &Arc<Harness>) {
    let enabled = h.settings.gateway_enabled();
    let port = h.settings.gateway_port();
    let mut g = h.gateway.inner.lock().unwrap();
    if !enabled {
        if let Some(t) = g.task.take() { t.abort(); }
        g.port = None;
        return;
    }
    if g.task.is_some() && g.port == Some(port) { return; }
    if let Some(t) = g.task.take() { t.abort(); }
    if crate::secrets::read(&h.paths.token_file(), h.settings.is_test).is_none() {
        let _ = crate::secrets::write(&h.paths.token_file(), h.settings.is_test, &crate::secrets::new_token());
    }
    // Loopback only: nothing on the network can reach it, whatever the firewall says.
    let listener = match std::net::TcpListener::bind(("127.0.0.1", port)) {
        Ok(l) => l,
        Err(e) => {
            g.problem = Some(format!("Couldn't listen on 127.0.0.1:{port}: {e}"));
            g.port = None;
            return;
        }
    };
    let _ = listener.set_nonblocking(true);
    let listener = match tokio::net::TcpListener::from_std(listener) {
        Ok(l) => l,
        Err(e) => {
            g.problem = Some(e.to_string());
            return;
        }
    };
    g.problem = None;
    g.port = Some(port);
    let me = h.clone();
    g.task = Some(tokio::spawn(async move {
        loop {
            let Ok((stream, _)) = listener.accept().await else { continue };
            let me = me.clone();
            tokio::spawn(async move { serve(me, stream, port).await });
        }
    }));
}

pub struct Request {
    pub method: String,
    pub path: String,
    pub query: HashMap<String, String>,
    pub headers: HashMap<String, String>,
    pub body: Vec<u8>,
}

pub enum Parse { Incomplete, Request(Request), Bad(u16, String) }

pub fn parse(data: &[u8]) -> Parse {
    let Some(end) = data.windows(4).position(|w| w == b"\r\n\r\n") else {
        return if data.len() > MAX_HEADER { Parse::Bad(431, "Headers too large".into()) } else { Parse::Incomplete };
    };
    if end > MAX_HEADER { return Parse::Bad(431, "Headers too large".into()); }
    let Ok(head) = std::str::from_utf8(&data[..end]) else { return Parse::Bad(400, "Bad request".into()) };
    let mut lines = head.split("\r\n");
    let request_line: Vec<&str> = lines.next().unwrap_or("").split(' ').filter(|s| !s.is_empty()).collect();
    if request_line.len() != 3 || !request_line[2].starts_with("HTTP/1.") { return Parse::Bad(400, "Bad request line".into()); }
    let mut headers = HashMap::new();
    for line in lines.filter(|l| !l.is_empty()) {
        let Some(colon) = line.find(':') else { return Parse::Bad(400, "Bad header".into()) };
        headers.insert(line[..colon].trim().to_lowercase(), line[colon + 1..].trim().to_string());
    }
    if headers.contains_key("transfer-encoding") { return Parse::Bad(411, "Send a Content-Length".into()); }
    let Ok(length) = headers.get("content-length").map(|s| s.as_str()).unwrap_or("0").parse::<usize>() else { return Parse::Bad(400, "Bad Content-Length".into()) };
    if length > MAX_BODY { return Parse::Bad(413, "Body too large".into()); }
    let body_start = end + 4;
    if data.len() - body_start < length { return Parse::Incomplete; }
    let target = request_line[1];
    let (path, query_text) = target.split_once('?').unwrap_or((target, ""));
    let query = query_text.split('&').filter(|p| !p.is_empty()).map(|p| {
        let (k, v) = p.split_once('=').unwrap_or((p, ""));
        (k.to_string(), v.to_string())
    }).collect();
    Parse::Request(Request { method: request_line[0].to_uppercase(), path: path.to_string(), query, headers, body: data[body_start..body_start + length].to_vec() })
}

pub fn constant_time_eq(a: &str, b: &str) -> bool {
    let (x, y) = (a.as_bytes(), b.as_bytes());
    let mut diff: u8 = if x.len() == y.len() { 0 } else { 1 };
    for i in 0..x.len().max(y.len()) {
        diff |= x.get(i).copied().unwrap_or(0) ^ y.get(i).copied().unwrap_or(0);
    }
    diff == 0
}

/// Loopback Host (no DNS rebinding), no browser page calling across sites, and the token.
pub fn check(req: &Request, port: u16, token: &str) -> Option<(u16, &'static str)> {
    let allowed = [format!("127.0.0.1:{port}"), format!("localhost:{port}"), format!("[::1]:{port}")];
    let host = req.headers.get("host").map(|h| h.to_lowercase()).unwrap_or_default();
    if !allowed.contains(&host) { return Some((403, "Host must be 127.0.0.1")); }
    if req.headers.contains_key("origin") || req.headers.get("sec-fetch-site").map(|v| v != "none").unwrap_or(false) {
        return Some((403, "Browser requests aren't accepted"));
    }
    let given = req.headers.get("authorization").and_then(|a| a.strip_prefix("Bearer ")).unwrap_or("");
    if token.is_empty() || !constant_time_eq(given, token) { return Some((401, "Needs Authorization: Bearer <token from Theo's Settings>")); }
    None
}

fn is_id(t: &str) -> bool {
    !t.is_empty() && !t.starts_with('.') && t.len() <= 128 && t.chars().all(|c| c.is_alphanumeric() || "-_.:".contains(c))
}

fn response(status: u16, body: &Value) -> Vec<u8> {
    let body = serde_json::to_vec(body).unwrap_or_default();
    let reason = match status { 200 => "OK", 202 => "Accepted", 400 => "Bad Request", 401 => "Unauthorized", 403 => "Forbidden", 404 => "Not Found", 405 => "Method Not Allowed", 409 => "Conflict", 411 => "Length Required", 413 => "Payload Too Large", 429 => "Too Many Requests", 431 => "Request Header Fields Too Large", 503 => "Service Unavailable", 504 => "Gateway Timeout", _ => "Status" };
    let mut head = format!("HTTP/1.1 {status} {reason}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\nCache-Control: no-store\r\n", body.len());
    if status == 401 { head.push_str("WWW-Authenticate: Bearer\r\n"); }
    head.push_str("\r\n");
    let mut out = head.into_bytes();
    out.extend(body);
    out
}

async fn serve(h: Arc<Harness>, mut stream: tokio::net::TcpStream, port: u16) {
    let started = std::time::Instant::now();
    let mut buffer = vec![];
    let mut chunk = vec![0u8; 16 * 1024];
    let req = loop {
        match parse(&buffer) {
            Parse::Request(r) => break r,
            Parse::Bad(status, why) => {
                let _ = stream.write_all(&response(status, &json!({"error": why}))).await;
                return;
            }
            Parse::Incomplete => {}
        }
        let left = std::time::Duration::from_secs(10).saturating_sub(started.elapsed());
        match tokio::time::timeout(left, stream.read(&mut chunk)).await {
            Ok(Ok(n)) if n > 0 => buffer.extend_from_slice(&chunk[..n]),
            _ => return,
        }
    };
    let (status, body) = respond(&h, req, port).await;
    let _ = stream.write_all(&response(status, &body)).await;
    let _ = stream.shutdown().await;
}

async fn respond(h: &Arc<Harness>, req: Request, port: u16) -> (u16, Value) {
    let token = match (h.settings.gateway_enabled(), crate::secrets::read(&h.paths.token_file(), h.settings.is_test)) {
        (true, Some(t)) => t,
        _ => return (503, json!({"error": "Theo's local API is off"})),
    };
    if let Some((status, why)) = check(&req, port, &token) {
        return (status, json!({"error": why}));
    }
    let parts: Vec<&str> = req.path.split('/').filter(|p| !p.is_empty()).collect();
    if parts.first() != Some(&"v1") { return (404, json!({"error": "Not found"})); }
    let rest = &parts[1..];
    let only = |m: &str| req.method == m;
    match rest {
        ["health"] if only("GET") => (200, json!({"ok": true, "bots": h.gateway_bots().len()})),
        ["bots"] if only("GET") => (200, json!({"bots": h.gateway_bots().iter().map(|b| json!({"id": b.id, "name": b.name, "description": b.description})).collect::<Vec<_>>()})),
        ["routines"] if only("GET") => (200, json!({"routines": h.with(|s| s.routines.iter().map(|r| json!({"id": r.id, "name": r.name, "target": r.target, "paused": r.paused, "schedule": crate::schedule::label(&r.schedule)})).collect::<Vec<_>>())})),
        ["usage"] if only("GET") => {
            let days = req.query.get("days").and_then(|d| d.parse().ok()).unwrap_or(7i64).clamp(1, 400);
            (200, json!({"days": days, "bots": h.usage_report(days)}))
        }
        ["doctor"] if only("GET") => (200, json!({"findings": h.doctor_findings().iter().map(|f| json!({"level": f.0, "check": f.1, "detail": f.2})).collect::<Vec<_>>()})),
        ["routines", id, "run"] if is_id(id) && only("POST") => {
            if !h.gateway.allow() { return (429, json!({"error": "Too many requests: 30 a minute"})); }
            let Some(r) = h.with(|s| s.routines.iter().find(|r| r.id == *id).cloned()) else { return (404, json!({"error": "No such routine"})) };
            h.run_routine_now(&r.id);
            (202, json!({"ok": true, "routine": r.name}))
        }
        ["bots", id, "messages"] if is_id(id) && only("POST") => {
            if !h.gateway.allow() { return (429, json!({"error": "Too many requests: 30 a minute"})); }
            let Ok(object) = serde_json::from_slice::<Value>(&req.body) else { return (400, json!({"error": "Body must be a JSON object"})) };
            let Some(text) = object.get("text").and_then(|t| t.as_str()).map(str::trim).filter(|t| !t.is_empty()) else { return (400, json!({"error": "Needs text"})) };
            if text.chars().count() > MAX_TEXT { return (400, json!({"error": format!("Text is over {MAX_TEXT} characters")})); }
            let raw = object.get("source").and_then(|s| s.as_str()).unwrap_or("a script");
            let source: String = raw.chars().filter(|c| c.is_alphanumeric() || " -_.".contains(*c)).take(40).collect();
            let source = if source.is_empty() { "a script".to_string() } else { source };
            let wait = object.get("wait").and_then(|w| w.as_bool()).unwrap_or(false);
            let timeout = object.get("timeout").and_then(|t| t.as_f64()).unwrap_or(300.0).clamp(5.0, 600.0);
            if !h.gateway_bots().iter().any(|b| b.id == *id) { return (404, json!({"error": "No bot with that id can be messaged"})); }
            let Some(message_id) = h.receive_from_gateway(text, &source, id) else { return (409, json!({"error": "That bot is turned off"})) };
            if !wait { return (202, json!({"id": message_id, "status": "queued"})); }
            match h.gateway_reply(&message_id, id, timeout).await {
                Some(reply) => (200, json!({"id": message_id, "status": "answered", "reply": reply})),
                None => (504, json!({"id": message_id, "status": "still working", "error": format!("No answer within {} s; it will appear in the chat", timeout as i64)})),
            }
        }
        ["health"] | ["bots"] | ["routines"] | ["usage"] | ["doctor"] | ["routines", _, "run"] | ["bots", _, "messages"] => (405, json!({"error": "Method not allowed"})),
        _ => (404, json!({"error": "Not found"})),
    }
}
