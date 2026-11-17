//! A small client for the DevTools protocol a VM screen's browser speaks on 127.0.0.1: a plain WebSocket (RFC 6455, client
//! side: masked frames out, text and continuation frames in, ping answered, close honoured) and JSON commands over it. It
//! blocks, so it runs on a blocking thread; each screen has its own. No TLS and no other host: the browser is always local.

use base64::Engine;
use serde_json::{json, Value};
use std::collections::VecDeque;
use std::io::{Read, Write};
use std::net::TcpStream;
use std::time::{Duration, Instant};

/// The most one message may hold (a screenshot is a few hundred KB; a page's words far less).
const MAXIMUM_MESSAGE_BYTES: usize = 64 * 1024 * 1024;

/// One WebSocket frame, as written by a client: always masked.
pub fn client_frame(opcode: u8, payload: &[u8], mask: [u8; 4]) -> Vec<u8> {
    let mut frame = vec![0x80 | (opcode & 0x0F)];
    let length = payload.len();
    if length < 126 {
        frame.push(0x80 | length as u8);
    } else if length <= u16::MAX as usize {
        frame.push(0x80 | 126);
        frame.extend_from_slice(&(length as u16).to_be_bytes());
    } else {
        frame.push(0x80 | 127);
        frame.extend_from_slice(&(length as u64).to_be_bytes());
    }
    frame.extend_from_slice(&mask);
    frame.extend(payload.iter().enumerate().map(|(index, byte)| byte ^ mask[index % 4]));
    frame
}

/// A frame's header: whether it ends a message, its opcode, whether it's masked and how long its payload is, and how many
/// header bytes that took. None until enough bytes are there.
pub fn frame_header(bytes: &[u8]) -> Option<(bool, u8, bool, usize, usize)> {
    if bytes.len() < 2 {
        return None;
    }
    let finished = bytes[0] & 0x80 != 0;
    let opcode = bytes[0] & 0x0F;
    let masked = bytes[1] & 0x80 != 0;
    let (length, mut used) = match bytes[1] & 0x7F {
        126 => {
            if bytes.len() < 4 {
                return None;
            }
            (u16::from_be_bytes([bytes[2], bytes[3]]) as usize, 4)
        }
        127 => {
            if bytes.len() < 10 {
                return None;
            }
            let mut eight = [0u8; 8];
            eight.copy_from_slice(&bytes[2..10]);
            (u64::from_be_bytes(eight) as usize, 10)
        }
        short => (short as usize, 2),
    };
    if masked {
        used += 4;
    }
    Some((finished, opcode, masked, length, used))
}

/// Decides whether the page may load a document (the page itself or a frame) from an address.
pub type DocumentGate = Box<dyn Fn(&str) -> bool + Send>;

pub struct Cdp {
    stream: TcpStream,
    buffer: Vec<u8>,
    next_id: u64,
    events: VecDeque<Value>,
    gate: Option<DocumentGate>,
    /// Documents the gate turned away, for the log of what happened.
    pub refused: Vec<String>,
}

impl Cdp {
    /// Connects to `ws://127.0.0.1:<port><path>`.
    pub fn connect(port: u16, path: &str, timeout: Duration) -> Result<Cdp, String> {
        let address = std::net::SocketAddr::from(([127, 0, 0, 1], port));
        let mut stream = TcpStream::connect_timeout(&address, timeout).map_err(|e| format!("couldn't reach the browser: {e}"))?;
        stream.set_nodelay(true).ok();
        stream.set_read_timeout(Some(timeout)).ok();
        stream.set_write_timeout(Some(timeout)).ok();
        let key = base64::engine::general_purpose::STANDARD.encode(rand::random::<[u8; 16]>());
        let request = format!("GET {path} HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n");
        stream.write_all(request.as_bytes()).map_err(|e| format!("couldn't talk to the browser: {e}"))?;
        let mut buffer = vec![];
        let mut chunk = [0u8; 4096];
        let deadline = Instant::now() + timeout;
        let header_end = loop {
            if let Some(at) = buffer.windows(4).position(|w| w == b"\r\n\r\n") {
                break at + 4;
            }
            if Instant::now() > deadline || buffer.len() > 64 * 1024 {
                return Err("the browser didn't answer".into());
            }
            let read = stream.read(&mut chunk).map_err(|e| format!("the browser didn't answer: {e}"))?;
            if read == 0 {
                return Err("the browser closed the connection".into());
            }
            buffer.extend_from_slice(&chunk[..read]);
        };
        let header = String::from_utf8_lossy(&buffer[..header_end]).to_string();
        if !header.starts_with("HTTP/1.1 101") {
            return Err(format!("the browser refused: {}", header.lines().next().unwrap_or("")));
        }
        let rest = buffer[header_end..].to_vec();
        Ok(Cdp { stream, buffer: rest, next_id: 1, events: VecDeque::new(), gate: None, refused: vec![] })
    }

    fn send_text(&mut self, text: &str) -> Result<(), String> {
        let frame = client_frame(0x1, text.as_bytes(), rand::random());
        self.stream.write_all(&frame).map_err(|e| format!("the browser stopped listening: {e}"))
    }

    /// The next whole text message, waiting until `deadline`. None when the time ran out.
    fn read_message(&mut self, deadline: Instant) -> Result<Option<String>, String> {
        let mut message: Vec<u8> = vec![];
        let mut chunk = vec![0u8; 64 * 1024];
        loop {
            if let Some((finished, opcode, masked, length, used)) = frame_header(&self.buffer) {
                if length > MAXIMUM_MESSAGE_BYTES {
                    return Err("the browser sent too much at once".into());
                }
                if self.buffer.len() >= used + length {
                    let mut payload = self.buffer[used..used + length].to_vec();
                    if masked {
                        let mask = [self.buffer[used - 4], self.buffer[used - 3], self.buffer[used - 2], self.buffer[used - 1]];
                        for (index, byte) in payload.iter_mut().enumerate() {
                            *byte ^= mask[index % 4];
                        }
                    }
                    self.buffer.drain(..used + length);
                    match opcode {
                        0x0 | 0x1 | 0x2 => {
                            message.extend_from_slice(&payload);
                            if message.len() > MAXIMUM_MESSAGE_BYTES {
                                return Err("the browser sent too much at once".into());
                            }
                            if finished {
                                return Ok(Some(String::from_utf8_lossy(&message).to_string()));
                            }
                        }
                        0x8 => return Err("the browser closed the page".into()),
                        0x9 => {
                            let pong = client_frame(0xA, &payload, rand::random());
                            self.stream.write_all(&pong).map_err(|e| format!("the browser stopped listening: {e}"))?;
                        }
                        _ => {}
                    }
                    continue;
                }
            }
            let now = Instant::now();
            if now >= deadline {
                return Ok(None);
            }
            self.stream.set_read_timeout(Some((deadline - now).max(Duration::from_millis(10)))).ok();
            match self.stream.read(&mut chunk) {
                Ok(0) => return Err("the browser closed the connection".into()),
                Ok(read) => self.buffer.extend_from_slice(&chunk[..read]),
                Err(error) if matches!(error.kind(), std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut) => {
                    // A frame read in part stays in the buffer for the next call.
                    if !message.is_empty() {
                        continue;
                    }
                    return Ok(None);
                }
                Err(error) => return Err(format!("the browser connection broke: {error}")),
            }
        }
    }

    /// Every document the page loads (itself, a redirect, a frame) is asked of `gate` first and refused when it says no, so a
    /// page can't send the screen somewhere it mustn't read. The browser holds each one until it's answered.
    pub fn guard_documents(&mut self, gate: DocumentGate, timeout: Duration) -> Result<(), String> {
        self.gate = Some(gate);
        self.call("Fetch.enable", json!({"patterns": [{"urlPattern": "*", "resourceType": "Document", "requestStage": "Request"}]}), timeout).map(|_| ())
    }

    /// Answers a held document at once (whatever else is being waited for). True when the message was one.
    fn answer_held_document(&mut self, message: &Value) -> Result<bool, String> {
        if message["method"].as_str() != Some("Fetch.requestPaused") {
            return Ok(false);
        }
        let request = message["params"]["requestId"].as_str().unwrap_or("").to_string();
        let address = message["params"]["request"]["url"].as_str().unwrap_or("").to_string();
        let allowed = self.gate.as_ref().map(|gate| gate(&address)).unwrap_or(true);
        let id = self.next_id;
        self.next_id += 1;
        let command = if allowed {
            json!({"id": id, "method": "Fetch.continueRequest", "params": {"requestId": request}})
        } else {
            if self.refused.len() < 50 {
                self.refused.push(address);
            }
            json!({"id": id, "method": "Fetch.failRequest", "params": {"requestId": request, "errorReason": "BlockedByClient"}})
        };
        self.send_text(&command.to_string())?;
        Ok(true)
    }

    /// Sends one command and waits for its answer; events that arrive meanwhile are kept for [`Cdp::wait_event`].
    pub fn call(&mut self, method: &str, params: Value, timeout: Duration) -> Result<Value, String> {
        let id = self.next_id;
        self.next_id += 1;
        self.send_text(&json!({"id": id, "method": method, "params": params}).to_string())?;
        let deadline = Instant::now() + timeout;
        loop {
            let Some(text) = self.read_message(deadline)? else { return Err(format!("the browser didn't answer {method} in time")) };
            let Ok(message) = serde_json::from_str::<Value>(&text) else { continue };
            if self.answer_held_document(&message)? {
                continue;
            }
            if message["id"].as_u64() == Some(id) {
                if let Some(error) = message.get("error") {
                    return Err(error["message"].as_str().unwrap_or("the browser said no").to_string());
                }
                return Ok(message["result"].clone());
            }
            if message.get("method").is_some() && self.events.len() < 500 {
                self.events.push_back(message);
            }
        }
    }

    /// Waits for an event by name until `timeout`, true when it came. Events kept from earlier count.
    pub fn wait_event(&mut self, method: &str, timeout: Duration) -> Result<bool, String> {
        if let Some(at) = self.events.iter().position(|event| event["method"].as_str() == Some(method)) {
            self.events.drain(..=at);
            return Ok(true);
        }
        self.events.clear();
        let deadline = Instant::now() + timeout;
        loop {
            let Some(text) = self.read_message(deadline)? else { return Ok(false) };
            let Ok(message) = serde_json::from_str::<Value>(&text) else { continue };
            if self.answer_held_document(&message)? {
                continue;
            }
            if message["method"].as_str() == Some(method) {
                return Ok(true);
            }
        }
    }

    /// Forgets events seen so far (before a new navigation).
    pub fn forget_events(&mut self) {
        self.events.clear();
    }

    /// Runs an expression in the page and returns its value (it must be JSON-friendly).
    pub fn evaluate(&mut self, expression: &str, timeout: Duration) -> Result<Value, String> {
        let result = self.call("Runtime.evaluate", json!({"expression": expression, "returnByValue": true, "awaitPromise": false, "timeout": timeout.as_millis() as u64}), timeout + Duration::from_secs(2))?;
        if let Some(details) = result.get("exceptionDetails") {
            return Err(details["text"].as_str().unwrap_or("the page's script failed").to_string());
        }
        Ok(result["result"]["value"].clone())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn unmask(frame: &[u8]) -> (u8, Vec<u8>) {
        let (_, opcode, masked, length, used) = frame_header(frame).unwrap();
        assert!(masked, "a client always masks");
        let mask = &frame[used - 4..used];
        (opcode, frame[used..used + length].iter().enumerate().map(|(i, b)| b ^ mask[i % 4]).collect())
    }

    #[test]
    fn frames_of_every_length_round_trip() {
        for size in [0usize, 5, 125, 126, 1000, 65535, 65536, 200_000] {
            let payload: Vec<u8> = (0..size).map(|i| (i % 251) as u8).collect();
            let frame = client_frame(0x1, &payload, [1, 2, 3, 4]);
            let (finished, opcode, _, length, used) = frame_header(&frame).unwrap();
            assert!(finished);
            assert_eq!(opcode, 1);
            assert_eq!(length, size);
            assert_eq!(frame.len(), used + size);
            assert_eq!(unmask(&frame).1, payload);
        }
    }

    #[test]
    fn a_header_waits_for_its_bytes() {
        assert!(frame_header(&[0x81]).is_none());
        assert!(frame_header(&[0x81, 126, 0]).is_none());
        assert_eq!(frame_header(&[0x81, 5]).unwrap(), (true, 1, false, 5, 2));
        assert_eq!(frame_header(&[0x01, 126, 1, 0]).unwrap(), (false, 1, false, 256, 4));
    }

    /// A tiny WebSocket server on 127.0.0.1 that answers one command, sending an event first and the answer in two pieces.
    #[test]
    fn a_command_gets_its_answer_and_events_wait() {
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        let server = std::thread::spawn(move || {
            let (mut socket, _) = listener.accept().unwrap();
            let mut request = vec![0u8; 4096];
            let read = socket.read(&mut request).unwrap();
            assert!(String::from_utf8_lossy(&request[..read]).contains("Upgrade: websocket"));
            socket.write_all(b"HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n").unwrap();
            let mut frame = vec![0u8; 4096];
            let read = socket.read(&mut frame).unwrap();
            let (_, payload) = unmask(&frame[..read]);
            let command: Value = serde_json::from_slice(&payload).unwrap();
            assert_eq!(command["method"], "Page.navigate");
            let send = |socket: &mut TcpStream, first: bool, last: bool, text: &str| {
                let mut out = vec![(if last { 0x80 } else { 0 }) | (if first { 1 } else { 0 })];
                out.push(text.len() as u8);
                out.extend_from_slice(text.as_bytes());
                socket.write_all(&out).unwrap();
            };
            send(&mut socket, true, true, r#"{"method":"Page.loadEventFired","params":{}}"#);
            let answer = json!({"id": command["id"], "result": {"frameId": "F"}}).to_string();
            let (a, b) = answer.split_at(10);
            send(&mut socket, true, false, a);
            send(&mut socket, false, true, b);
            std::thread::sleep(Duration::from_millis(200));
        });
        let mut cdp = Cdp::connect(port, "/devtools/page/X", Duration::from_secs(5)).unwrap();
        let result = cdp.call("Page.navigate", json!({"url": "about:blank"}), Duration::from_secs(5)).unwrap();
        assert_eq!(result["frameId"], "F");
        assert!(cdp.wait_event("Page.loadEventFired", Duration::from_millis(100)).unwrap(), "the event that came first was kept");
        server.join().unwrap();
    }
}
