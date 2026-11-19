//! The hub as the apps use it: the real `theo-connectors` program against the stand-in servers in `crossplatform/tests`
//! (`echo_mcp.py`, a local app; `oauth_mcp.py`, a remote app with its own OAuth sign-in; `fake_engine.py`, standing in for
//! Claude Code). Every hub run uses `--key-store file`, so the tests never touch the Keychain or the Credential Manager.

use serde_json::{json, Value};
use std::io::{BufRead, BufReader, Write};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};

fn stand_in_folder() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../../tests").canonicalize().unwrap()
}

fn python() -> String {
    std::env::var("PYTHON").unwrap_or_else(|_| if cfg!(windows) { "python".into() } else { "python3".into() })
}

fn hub_command(data_folder: &Path) -> Command {
    let mut command = Command::new(env!("CARGO_BIN_EXE_theo-connectors"));
    command.arg("--data").arg(data_folder).arg("--key-store").arg("file");
    command.env_remove("THEO_DATA").env_remove("THEO_CONNECTORS_CLAUDE");
    command
}

/// Runs one hub command and returns (the JSON it printed last, everything it printed).
fn hub_with_input(data_folder: &Path, arguments: &[&str], standard_input: &str) -> (Value, String) {
    let mut child = hub_command(data_folder).args(arguments).stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(Stdio::piped()).spawn().unwrap();
    child.stdin.take().unwrap().write_all(standard_input.as_bytes()).unwrap();
    let output = child.wait_with_output().unwrap();
    let printed = String::from_utf8_lossy(&output.stdout).to_string();
    let last_line = printed.lines().last().unwrap_or("").to_string();
    let answer: Value = serde_json::from_str(&last_line).unwrap_or_else(|_| panic!("{arguments:?} printed {printed:?} (stderr {:?})", String::from_utf8_lossy(&output.stderr)));
    (answer, printed)
}

fn hub(data_folder: &Path, arguments: &[&str]) -> (Value, String) {
    hub_with_input(data_folder, arguments, "")
}

fn app_in_listing<'a>(listing: &'a Value, app_id: &str) -> &'a Value {
    listing["apps"].as_array().unwrap().iter().find(|app| app["id"] == app_id).unwrap_or_else(|| panic!("{app_id} not in {listing}"))
}

fn issue_ticket(data_folder: &Path, apps: Value, owner_asked: bool, seconds_left: i64) -> String {
    let ticket = json!({
        "botId": "ledger",
        "apps": apps,
        "ownerAsked": owner_asked,
        "expiresAt": (chrono::Utc::now() + chrono::Duration::seconds(seconds_left)).to_rfc3339(),
    });
    let (answer, _) = hub(data_folder, &["ticket", "issue", "--json", &ticket.to_string()]);
    assert_eq!(answer["ok"], true, "{answer}");
    answer["ticket"].as_str().unwrap().to_string()
}

fn add_echo_app(data_folder: &Path) -> Value {
    let echo_app = json!({
        "id": "echo",
        "name": "Echo",
        "kind": "local",
        "command": python(),
        "args": [stand_in_folder().join("echo_mcp.py")],
    });
    hub(data_folder, &["add", "--json", &echo_app.to_string()]).0
}

/// A running `serve`, spoken to as a brain would.
struct McpServerUnderTest {
    child: Child,
    output_lines: std::io::Lines<BufReader<std::process::ChildStdout>>,
    next_request_id: u64,
}

impl McpServerUnderTest {
    fn start(data_folder: &Path, ticket_file: &str) -> McpServerUnderTest {
        let mut child = hub_command(data_folder).args(["serve", "--ticket", ticket_file]).stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(Stdio::null()).spawn().unwrap();
        let output_lines = BufReader::new(child.stdout.take().unwrap()).lines();
        let mut server = McpServerUnderTest { child, output_lines, next_request_id: 1 };
        let initialized = server.request("initialize", json!({"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "test", "version": "1"}}));
        assert_eq!(initialized["result"]["protocolVersion"], "2025-06-18", "{initialized}");
        server.notify("notifications/initialized");
        server
    }

    fn notify(&mut self, method: &str) {
        let stdin = self.child.stdin.as_mut().unwrap();
        writeln!(stdin, "{}", json!({"jsonrpc": "2.0", "method": method})).unwrap();
        stdin.flush().unwrap();
    }

    fn request(&mut self, method: &str, parameters: Value) -> Value {
        let request_id = self.next_request_id;
        self.next_request_id += 1;
        let stdin = self.child.stdin.as_mut().unwrap();
        writeln!(stdin, "{}", json!({"jsonrpc": "2.0", "id": request_id, "method": method, "params": parameters})).unwrap();
        stdin.flush().unwrap();
        loop {
            let line = self.output_lines.next().expect("serve stopped").unwrap();
            let message: Value = serde_json::from_str(&line).unwrap();
            if message["id"] == request_id {
                return message;
            }
        }
    }

    fn tool_names(&mut self) -> Vec<String> {
        let listed = self.request("tools/list", json!({}));
        listed["result"]["tools"].as_array().unwrap().iter().map(|tool| tool["name"].as_str().unwrap().to_string()).collect()
    }

    fn call(&mut self, tool_name: &str, arguments: Value) -> Value {
        self.request("tools/call", json!({"name": tool_name, "arguments": arguments}))["result"].clone()
    }
}

impl Drop for McpServerUnderTest {
    fn drop(&mut self) {
        drop(self.child.stdin.take());
        let _ = self.child.wait();
    }
}

fn result_text(result: &Value) -> String {
    result["content"][0]["text"].as_str().unwrap_or("").to_string()
}

#[test]
fn a_local_app_is_added_listed_and_used_through_call_and_serve() {
    let data = tempfile::tempdir().unwrap();
    let added = add_echo_app(data.path());
    assert_eq!(added["status"], "connected", "{added}");
    assert_eq!(added["toolCount"], 4);

    let (listing, _) = hub(data.path(), &["list"]);
    let echo = app_in_listing(&listing, "echo");
    assert_eq!(echo["status"], "connected");
    assert!(echo["lastWorked"].is_string());

    let (tools, _) = hub(data.path(), &["tools", "echo"]);
    let effect_of = |name: &str| tools["tools"].as_array().unwrap().iter().find(|tool| tool["name"] == name).unwrap()["effect"].clone();
    assert_eq!(effect_of("echo"), "read");
    assert_eq!(effect_of("save_note"), "change");
    assert_eq!(effect_of("send_note"), "irreversible");

    // A secret setting reaches the command and isn't in the list file.
    let (saved, _) = hub_with_input(data.path(), &["set-secret", "echo", "--env", "ECHO_SETTING"], "setting-value-4821\n");
    assert_eq!(saved["ok"], true, "{saved}");
    let list_file = std::fs::read_to_string(data.path().join("Connectors/connectors.json")).unwrap();
    assert!(!list_file.contains("setting-value-4821"));

    let full_ticket = issue_ticket(data.path(), json!({"echo": "full"}), true, 600);
    let (called, _) = hub(data.path(), &["call", "echo", "echo", "--args", r#"{"text":"hi"}"#, "--ticket", &full_ticket]);
    assert_eq!(result_text(&called["result"]), "echo: hi", "{called}");
    let (setting, _) = hub(data.path(), &["call", "echo", "read_setting", "--ticket", &full_ticket]);
    assert_eq!(result_text(&setting["result"]), "setting: setting-value-4821");

    let mut server = McpServerUnderTest::start(data.path(), &full_ticket);
    let mut names = server.tool_names();
    names.sort();
    assert_eq!(names, ["echo__echo", "echo__read_setting", "echo__save_note", "echo__send_note"]);
    assert_eq!(result_text(&server.call("echo__echo", json!({"text": "through serve"}))), "echo: through serve");
    assert_eq!(result_text(&server.call("echo__send_note", json!({"text": "x"}))), "send_note: x");
    assert_eq!(server.request("ping", json!({}))["result"], json!({}));
}

#[test]
fn levels_tickets_and_turns_not_from_the_owner_limit_what_runs() {
    let data = tempfile::tempdir().unwrap();
    assert_eq!(add_echo_app(data.path())["status"], "connected");

    // read: changing tools are neither offered nor run, even when asked for by name.
    let read_ticket = issue_ticket(data.path(), json!({"echo": "read"}), true, 600);
    let (refused, _) = hub(data.path(), &["call", "echo", "save_note", "--args", r#"{"text":"x"}"#, "--ticket", &read_ticket]);
    assert_eq!(refused["ok"], false);
    assert!(refused["error"].as_str().unwrap().starts_with("Not allowed"), "{refused}");
    let mut server = McpServerUnderTest::start(data.path(), &read_ticket);
    let mut names = server.tool_names();
    names.sort();
    assert_eq!(names, ["echo__echo", "echo__read_setting"]);
    let refused_in_serve = server.call("echo__save_note", json!({"text": "x"}));
    assert_eq!(refused_in_serve["isError"], true);
    assert_eq!(result_text(&server.call("echo__echo", json!({"text": "ok"}))), "echo: ok");
    drop(server);

    // readAndDraft (the default): changes yes, sending no.
    let draft_ticket = issue_ticket(data.path(), json!({"echo": "readAndDraft"}), true, 600);
    let (saved, _) = hub(data.path(), &["call", "echo", "save_note", "--args", r#"{"text":"x"}"#, "--ticket", &draft_ticket]);
    assert_eq!(saved["ok"], true, "{saved}");
    let (sent, _) = hub(data.path(), &["call", "echo", "send_note", "--args", r#"{"text":"x"}"#, "--ticket", &draft_ticket]);
    assert_eq!(sent["ok"], false);

    // A turn that didn't come from the owner (a routine, another bot) never gets more than read and draft: it can
    // still save its draft, and it can't send even when the bot has the app in full.
    let routine_ticket = issue_ticket(data.path(), json!({"echo": "full"}), false, 600);
    let (routine_change, _) = hub(data.path(), &["call", "echo", "save_note", "--args", r#"{"text":"x"}"#, "--ticket", &routine_ticket]);
    assert_eq!(routine_change["ok"], true, "{routine_change}");
    let (routine_send, _) = hub(data.path(), &["call", "echo", "send_note", "--args", r#"{"text":"x"}"#, "--ticket", &routine_ticket]);
    assert_eq!(routine_send["ok"], false);
    assert!(routine_send["error"].as_str().unwrap().contains("owner's own words"), "{routine_send}");
    let routine_read_ticket = issue_ticket(data.path(), json!({"echo": "read"}), false, 600);
    let (routine_read_change, _) = hub(data.path(), &["call", "echo", "save_note", "--args", r#"{"text":"x"}"#, "--ticket", &routine_read_ticket]);
    assert_eq!(routine_read_change["ok"], false);

    // An app the bot wasn't given can't be called.
    let other_app_ticket = issue_ticket(data.path(), json!({"gmail": "full"}), true, 600);
    let (not_given, _) = hub(data.path(), &["call", "echo", "echo", "--args", r#"{"text":"x"}"#, "--ticket", &other_app_ticket]);
    assert_eq!(not_given["ok"], false);
    let mut server = McpServerUnderTest::start(data.path(), &other_app_ticket);
    assert!(server.tool_names().is_empty());
    assert_eq!(server.call("echo__echo", json!({"text": "x"}))["isError"], true);
    drop(server);

    // An expired ticket runs nothing, and serve refuses to start with it.
    let expired_ticket = issue_ticket(data.path(), json!({"echo": "full"}), true, -1);
    let (expired, _) = hub(data.path(), &["call", "echo", "echo", "--args", r#"{"text":"x"}"#, "--ticket", &expired_ticket]);
    assert_eq!(expired["ok"], false);
    assert!(expired["error"].as_str().unwrap().contains("expired"), "{expired}");
    let (serve_refused, _) = hub(data.path(), &["serve", "--ticket", &expired_ticket]);
    assert_eq!(serve_refused["ok"], false);

    // A ticket deleted mid-turn stops the turn's apps at once.
    let live_ticket = issue_ticket(data.path(), json!({"echo": "full"}), true, 600);
    let mut server = McpServerUnderTest::start(data.path(), &live_ticket);
    assert_eq!(result_text(&server.call("echo__echo", json!({"text": "before"}))), "echo: before");
    let (revoked, _) = hub(data.path(), &["ticket", "revoke", &live_ticket]);
    assert_eq!(revoked["ok"], true);
    assert_eq!(server.call("echo__echo", json!({"text": "after"}))["isError"], true);
    drop(server);

    // A ticket outside the hub's own folder isn't accepted.
    let outside = data.path().join("my-ticket.json");
    std::fs::write(&outside, json!({"botId": "x", "apps": {"echo": "full"}, "ownerAsked": true, "expiresAt": "2999-01-01T00:00:00Z"}).to_string()).unwrap();
    let (outside_refused, _) = hub(data.path(), &["call", "echo", "echo", "--args", "{}", "--ticket", outside.to_str().unwrap()]);
    assert_eq!(outside_refused["ok"], false);
}

#[test]
fn the_list_changes_and_secrets_stay_out_of_it() {
    let data = tempfile::tempdir().unwrap();
    assert_eq!(add_echo_app(data.path())["ok"], true);
    let (duplicate, _) = hub(data.path(), &["add", "--json", r#"{"id":"echo","name":"Echo","kind":"local","command":"x"}"#, "--no-check"]);
    assert_eq!(duplicate["ok"], false);
    let (with_token, _) = hub(data.path(), &["add", "--json", r#"{"id":"n","name":"N","kind":"remote","url":"https://x.example/mcp","auth":"token","token":"abc"}"#]);
    assert_eq!(with_token["ok"], false);
    assert!(with_token["error"].as_str().unwrap().contains("set-secret"));
    let (bad_id, _) = hub(data.path(), &["add", "--json", r#"{"id":"Bad Id","name":"N","kind":"local","command":"x"}"#]);
    assert_eq!(bad_id["ok"], false);

    hub(data.path(), &["disable", "echo"]);
    assert_eq!(app_in_listing(&hub(data.path(), &["list"]).0, "echo")["status"], "off");
    hub(data.path(), &["enable", "echo"]);
    let (checked, _) = hub(data.path(), &["check", "echo"]);
    assert_eq!(checked["apps"][0]["status"], "connected", "{checked}");

    // A command that isn't there fails with a reason, and the list says so.
    let (broken, _) = hub(data.path(), &["add", "--json", r#"{"id":"broken","name":"Broken","kind":"local","command":"/nonexistent/server-program"}"#]);
    assert_eq!(broken["status"], "failed", "{broken}");
    let broken_listed = app_in_listing(&hub(data.path(), &["list"]).0, "broken").clone();
    assert_eq!(broken_listed["status"], "failed");
    assert!(broken_listed["reason"].as_str().unwrap().contains("couldn't start"), "{broken_listed}");

    let (removed, _) = hub(data.path(), &["remove", "echo"]);
    assert_eq!(removed["ok"], true);
    assert!(hub(data.path(), &["list"]).0["apps"].as_array().unwrap().iter().all(|app| app["id"] != "echo"));
    let (catalog, _) = hub(data.path(), &["catalog"]);
    assert!(catalog["catalog"]["apps"].as_array().unwrap().iter().any(|app| app["id"] == "gmail"));
}

struct StandInRemoteApp {
    child: Child,
    port: u16,
}

impl StandInRemoteApp {
    fn start(token_lifetime_seconds: u32) -> StandInRemoteApp {
        let mut child = Command::new(python())
            .arg(stand_in_folder().join("oauth_mcp.py"))
            .env("TOKEN_LIFETIME", token_lifetime_seconds.to_string())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()
            .unwrap();
        let mut first_line = String::new();
        BufReader::new(child.stdout.take().unwrap()).read_line(&mut first_line).unwrap();
        StandInRemoteApp { child, port: first_line.trim().parse().unwrap() }
    }

    fn address(&self, path: &str) -> String {
        format!("http://127.0.0.1:{}{path}", self.port)
    }

    fn stats(&self) -> Value {
        serde_json::from_str(&ureq::get(&self.address("/debug/stats")).call().unwrap().into_string().unwrap()).unwrap()
    }
}

impl Drop for StandInRemoteApp {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

/// Runs `signin`, plays the browser (opens the address it printed and follows the redirect back to the hub), and
/// returns everything the hub printed.
fn sign_in_with_stand_in_browser(data_folder: &Path, app_id: &str) -> (Value, String) {
    let mut child = hub_command(data_folder).args(["signin", app_id, "--timeout", "60"]).stdout(Stdio::piped()).stderr(Stdio::null()).spawn().unwrap();
    let mut output_lines = BufReader::new(child.stdout.take().unwrap()).lines();
    let first_line = output_lines.next().unwrap().unwrap();
    let opened: Value = serde_json::from_str(&first_line).unwrap();
    assert_eq!(opened["event"], "open", "{opened}");
    let address_to_open = opened["url"].as_str().unwrap().to_string();
    let browser_landed_on = ureq::get(&address_to_open).call().unwrap();
    assert!(browser_landed_on.into_string().unwrap().contains("Signed in"));
    let last_line = output_lines.next().unwrap().unwrap();
    child.wait().unwrap();
    (serde_json::from_str(&last_line).unwrap(), format!("{first_line}\n{last_line}"))
}

fn everything_under(folder: &Path) -> String {
    let mut contents = String::new();
    for entry in std::fs::read_dir(folder).unwrap().flatten() {
        let path = entry.path();
        if path.is_dir() {
            contents.push_str(&everything_under(&path));
        } else {
            contents.push_str(&String::from_utf8_lossy(&std::fs::read(&path).unwrap_or_default()));
        }
    }
    contents
}

#[test]
fn a_remote_app_signs_in_refreshes_and_signs_out_without_leaking_a_token() {
    let data = tempfile::tempdir().unwrap();
    // 30-second tokens: the hub refreshes any token with less than a minute left, so every use refreshes first.
    let remote_app = StandInRemoteApp::start(30);
    let mut everything_printed = String::new();

    let app = json!({"id": "notes", "name": "Notes", "kind": "remote", "url": remote_app.address("/mcp"), "auth": "oauth"});
    let (added, printed) = hub(data.path(), &["add", "--json", &app.to_string()]);
    everything_printed.push_str(&printed);
    assert_eq!(added["status"], "needsSignIn", "{added}");

    let (signed_in, printed) = sign_in_with_stand_in_browser(data.path(), "notes");
    everything_printed.push_str(&printed);
    assert_eq!(signed_in["ok"], true, "{signed_in}");
    assert_eq!(signed_in["status"], "connected", "{signed_in}");
    let stats = remote_app.stats();
    assert_eq!(stats["registrations"], 1);
    assert_eq!(stats["resources"][0], remote_app.address("/mcp"));

    // The token is stored outside the list file, and refreshed when it runs out.
    let refreshes_before = stats["refreshes"].as_u64().unwrap();
    let (checked, printed) = hub(data.path(), &["check", "notes"]);
    everything_printed.push_str(&printed);
    assert_eq!(checked["apps"][0]["status"], "connected", "{checked}");
    assert!(remote_app.stats()["refreshes"].as_u64().unwrap() > refreshes_before);

    let ticket = issue_ticket(data.path(), json!({"notes": "read"}), true, 600);
    let (whoami, printed) = hub(data.path(), &["call", "notes", "whoami", "--ticket", &ticket]);
    everything_printed.push_str(&printed);
    assert_eq!(result_text(&whoami["result"]), "signed in as stand-in user", "{whoami}");
    let (send_refused, _) = hub(data.path(), &["call", "notes", "send_note", "--args", r#"{"text":"x"}"#, "--ticket", &ticket]);
    assert_eq!(send_refused["ok"], false);

    let mut server = McpServerUnderTest::start(data.path(), &ticket);
    assert_eq!(server.tool_names(), ["notes__whoami"]);
    assert_eq!(result_text(&server.call("notes__whoami", json!({}))), "signed in as stand-in user");
    drop(server);

    // No token the server issued is in anything the hub printed or wrote.
    let issued_tokens: Vec<String> = remote_app.stats()["issued"].as_array().unwrap().iter().map(|token| token.as_str().unwrap().to_string()).collect();
    assert!(issued_tokens.len() >= 4);
    let everything_written = everything_under(data.path());
    for token in &issued_tokens {
        assert!(!everything_printed.contains(token.as_str()), "a token was printed");
        assert!(!everything_written.contains(token.as_str()), "a token was written in the clear");
    }

    let (signed_out, _) = hub(data.path(), &["signout", "notes"]);
    assert_eq!(signed_out["status"], "needsSignIn");
    assert_eq!(app_in_listing(&hub(data.path(), &["list"]).0, "notes")["status"], "needsSignIn");
    assert_eq!(hub(data.path(), &["check", "notes"]).0["apps"][0]["status"], "needsSignIn");

    // Signing in again reuses the client the hub registered.
    let (signed_in_again, _) = sign_in_with_stand_in_browser(data.path(), "notes");
    assert_eq!(signed_in_again["status"], "connected", "{signed_in_again}");
    assert_eq!(remote_app.stats()["registrations"], 1);
}

#[test]
fn a_token_the_server_stopped_taking_is_refreshed_once() {
    let data = tempfile::tempdir().unwrap();
    let remote_app = StandInRemoteApp::start(3600);
    let app = json!({"id": "notes", "name": "Notes", "kind": "remote", "url": remote_app.address("/mcp"), "auth": "oauth"});
    hub(data.path(), &["add", "--json", &app.to_string(), "--no-check"]);
    assert_eq!(sign_in_with_stand_in_browser(data.path(), "notes").0["status"], "connected");
    assert_eq!(remote_app.stats()["refreshes"], 0);
    ureq::post(&remote_app.address("/debug/revoke-access-tokens")).call().unwrap();
    let (checked, _) = hub(data.path(), &["check", "notes"]);
    assert_eq!(checked["apps"][0]["status"], "connected", "{checked}");
    assert_eq!(remote_app.stats()["refreshes"], 1);
}

#[test]
fn claude_account_apps_take_their_status_from_claude_code() {
    let data = tempfile::tempdir().unwrap();
    let fake_claude_folder = tempfile::tempdir().unwrap();
    std::fs::write(
        fake_claude_folder.path().join("fake-mcp"),
        "Checking MCP server health...\n\nclaude.ai Notion: https://mcp.notion.com/mcp - \u{2714} Connected\nclaude.ai Gmail: https://gmail.mcp.claude.com/mcp - ! Needs authentication\n",
    )
    .unwrap();
    let run_with_fake_claude = |arguments: &[&str]| -> Value {
        let output = hub_command(data.path())
            .args(arguments)
            .env("THEO_CONNECTORS_CLAUDE", stand_in_folder().join("fake_engine.py"))
            .env("THEO_FAKE_DIR", fake_claude_folder.path())
            .output()
            .unwrap();
        serde_json::from_str(String::from_utf8_lossy(&output.stdout).lines().last().unwrap()).unwrap()
    };
    assert_eq!(run_with_fake_claude(&["add", "--catalog", "notion"])["status"], "connected");
    assert_eq!(run_with_fake_claude(&["add", "--catalog", "gmail"])["status"], "needsSignIn");
    assert_eq!(run_with_fake_claude(&["add", "--catalog", "drive"])["status"], "failed");
    let discovered = run_with_fake_claude(&["discover-claude"]);
    let notion = discovered["servers"].as_array().unwrap().iter().find(|server| server["server"] == "claude.ai Notion").unwrap().clone();
    assert_eq!(notion["catalogIds"], json!(["notion", "calendar"]));
    assert_eq!(notion["suggestedId"], "notion");

    // With no Claude Code at all, the app says why instead of hanging or crashing.
    let output = hub_command(data.path()).args(["check", "notion"]).env("THEO_CONNECTORS_CLAUDE", data.path().join("no-claude-here")).output().unwrap();
    let checked: Value = serde_json::from_str(String::from_utf8_lossy(&output.stdout).lines().last().unwrap()).unwrap();
    assert_eq!(checked["apps"][0]["status"], "failed", "{checked}");
}

struct StandInComposio {
    child: Child,
    port: u16,
}

impl StandInComposio {
    fn start() -> StandInComposio {
        let mut child = Command::new(python())
            .arg(stand_in_folder().join("composio_stub.py"))
            .env("COMPOSIO_TEST_KEY", "ck-test-key")
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()
            .unwrap();
        let mut first_line = String::new();
        BufReader::new(child.stdout.take().unwrap()).read_line(&mut first_line).unwrap();
        StandInComposio { child, port: first_line.trim().parse().unwrap() }
    }

    fn address(&self, path: &str) -> String {
        format!("http://127.0.0.1:{}{path}", self.port)
    }

    fn stats(&self) -> Value {
        serde_json::from_str(&ureq::get(&self.address("/debug/stats")).call().unwrap().into_string().unwrap()).unwrap()
    }
}

impl Drop for StandInComposio {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

#[test]
fn composio_takes_one_key_connects_apps_by_link_and_judges_each_run_by_what_it_runs() {
    let data = tempfile::tempdir().unwrap();
    let composio = StandInComposio::start();

    // The catalog offers it, as a token app on Composio's API.
    let (catalog, _) = hub(data.path(), &["catalog"]);
    let offered = catalog["catalog"]["apps"].as_array().unwrap().iter().find(|app| app["id"] == "composio").cloned().expect("composio in the catalog");
    assert_eq!(offered["auth"], "token");
    assert_eq!(offered["url"], "https://backend.composio.dev");

    // Added (pointed at the stand-in), it needs its key before anything else.
    let app = json!({"id": "composio", "name": "Composio", "kind": "remote", "url": composio.address(""), "auth": "token", "composio": {"userId": "vello"}});
    let (added, _) = hub(data.path(), &["add", "--json", &app.to_string()]);
    assert_eq!(added["status"], "needsSignIn", "{added}");

    // A wrong key says so plainly.
    hub_with_input(data.path(), &["set-secret", "composio"], "not-the-key\n");
    let (checked, _) = hub(data.path(), &["check", "composio"]);
    assert_eq!(checked["apps"][0]["status"], "failed", "{checked}");
    assert!(checked["apps"][0]["reason"].as_str().unwrap().contains("API key"), "{checked}");

    // The right key: one session, its tools, and which apps are connected on Composio.
    // Nothing pasted removes, and says so rather than "saved".
    let (removed, _) = hub_with_input(data.path(), &["set-secret", "composio"], "\n");
    assert_eq!(removed["removed"], "token", "{removed}");
    assert!(removed.get("saved").is_none(), "{removed}");
    let (saved, _) = hub_with_input(data.path(), &["set-secret", "composio"], "ck-test-key\n");
    assert_eq!(saved["saved"], "token");
    let (checked, _) = hub(data.path(), &["check", "composio"]);
    assert_eq!(checked["apps"][0]["status"], "connected", "{checked}");
    assert_eq!(checked["apps"][0]["toolCount"], 4);
    let (listing, _) = hub(data.path(), &["list"]);
    let listed = app_in_listing(&listing, "composio");
    assert_eq!(listed["signedIn"], true);
    assert_eq!(listed["composioConnectedApps"], json!(["gmail", "slack"]), "only active connections count");
    let (tools, _) = hub(data.path(), &["tools", "composio"]);
    let executor = tools["tools"].as_array().unwrap().iter().find(|tool| tool["name"] == "COMPOSIO_MULTI_EXECUTE_TOOL").unwrap();
    assert_eq!(executor["effect"], "read");
    assert_eq!(executor["judgedPerCall"], true);
    assert_eq!(executor["readOnly"], false);
    let stats = composio.stats();
    assert_eq!(stats["userIds"], json!(["vello"]));
    assert_eq!(stats["sessionRequests"][0]["manage_connections"]["enable_connection_removal"], false, "bots never disconnect an app");

    // A link to connect an app, from its plain name.
    let (link, _) = hub(data.path(), &["composio-link", "composio", "Google Calendar"]);
    assert_eq!(link["ok"], true, "{link}");
    assert_eq!(link["toolkit"], "googlecalendar");
    assert_eq!(link["url"], "https://app.composio.dev/link/lt_googlecalendar");
    let (no_such_app, _) = hub(data.path(), &["composio-link", "composio", "no such app"]);
    assert_eq!(no_such_app["ok"], false);
    assert!(no_such_app["error"].as_str().unwrap().contains("nosuchapp"), "{no_such_app}");
    let (connected, _) = hub(data.path(), &["composio-apps", "composio"]);
    assert_eq!(connected["connected"], json!(["gmail", "slack"]));

    // A bot that reads and drafts: Composio's runner is offered, its code sandbox isn't; drafts run, sends don't.
    let ticket = issue_ticket(data.path(), json!({"composio": "readAndDraft"}), true, 600);
    let mut server = McpServerUnderTest::start(data.path(), &ticket);
    let names = server.tool_names();
    assert!(names.contains(&"composio__COMPOSIO_MULTI_EXECUTE_TOOL".to_string()), "{names:?}");
    assert!(names.contains(&"composio__COMPOSIO_MANAGE_CONNECTIONS".to_string()), "{names:?}");
    assert!(!names.contains(&"composio__COMPOSIO_REMOTE_WORKBENCH".to_string()), "{names:?}");
    let drafted = server.call("composio__COMPOSIO_MULTI_EXECUTE_TOOL", json!({"tools": [{"tool_slug": "GMAIL_FETCH_EMAILS", "arguments": {}}, {"tool_slug": "GMAIL_CREATE_EMAIL_DRAFT", "arguments": {}}]}));
    assert_eq!(drafted["isError"], false, "{drafted}");
    let refused = server.call("composio__COMPOSIO_MULTI_EXECUTE_TOOL", json!({"tools": [{"tool_slug": "GMAIL_FETCH_EMAILS"}, {"tool_slug": "GMAIL_SEND_EMAIL", "arguments": {"recipient_email": "a@example.com"}}]}));
    assert_eq!(refused["isError"], true);
    assert!(result_text(&refused).contains("GMAIL_SEND_EMAIL"), "{refused}");
    let hidden_under_another_key = server.call("composio__COMPOSIO_MULTI_EXECUTE_TOOL", json!({"tools": [{"name": "GMAIL_SEND_EMAIL", "tool_slug": "GMAIL_FETCH_EMAILS"}]}));
    assert_eq!(hidden_under_another_key["isError"], true, "a slug under any key counts");
    let link_in_chat = server.call("composio__COMPOSIO_MANAGE_CONNECTIONS", json!({"toolkits": ["notion"]}));
    assert!(result_text(&link_in_chat).contains("app.composio.dev/link"), "{link_in_chat}");
    drop(server);

    // Everything, but not from the owner's own words: still no send. From the owner: it sends.
    let routine_ticket = issue_ticket(data.path(), json!({"composio": "full"}), false, 600);
    let (routine_send, _) = hub(data.path(), &["call", "composio", "COMPOSIO_MULTI_EXECUTE_TOOL", "--args", &json!({"tools": [{"tool_slug": "SLACK_CHAT_POST_MESSAGE"}]}).to_string(), "--ticket", &routine_ticket]);
    assert_eq!(routine_send["ok"], false);
    assert!(routine_send["error"].as_str().unwrap().contains("owner's own words"), "{routine_send}");
    let owner_ticket = issue_ticket(data.path(), json!({"composio": "full"}), true, 600);
    let (owner_send, _) = hub(data.path(), &["call", "composio", "COMPOSIO_MULTI_EXECUTE_TOOL", "--args", &json!({"tools": [{"tool_slug": "GMAIL_SEND_EMAIL"}]}).to_string(), "--ticket", &owner_ticket]);
    assert_eq!(owner_send["ok"], true, "{owner_send}");
    let read_ticket = issue_ticket(data.path(), json!({"composio": "read"}), true, 600);
    let (read_draft, _) = hub(data.path(), &["call", "composio", "COMPOSIO_MULTI_EXECUTE_TOOL", "--args", &json!({"tools": [{"tool_slug": "NOTION_CREATE_NOTION_PAGE"}]}).to_string(), "--ticket", &read_ticket]);
    assert_eq!(read_draft["ok"], false, "{read_draft}");

    let stats = composio.stats();
    let ran: Vec<Value> = stats["ran"].as_array().unwrap().clone();
    assert_eq!(ran, vec![json!(["GMAIL_FETCH_EMAILS", "GMAIL_CREATE_EMAIL_DRAFT"]), json!(["GMAIL_SEND_EMAIL"])], "only allowed runs reached Composio");
    let sessions_before = stats["sessionsMade"].as_u64().unwrap();
    assert_eq!(sessions_before, 1, "the wrong key made none; the right one made one, kept and reused by every command");

    // A session Composio forgot is replaced once, without the owner doing anything.
    ureq::post(&composio.address("/debug/forget-sessions")).call().unwrap();
    let (checked, _) = hub(data.path(), &["check", "composio"]);
    assert_eq!(checked["apps"][0]["status"], "connected", "{checked}");
    assert_eq!(composio.stats()["sessionsMade"].as_u64().unwrap(), sessions_before + 1);

    // The key went only in x-api-key, and is nowhere in Vello's files in the clear.
    assert_eq!(composio.stats()["keyOutsideItsHeader"], false);
    assert!(!everything_under(data.path()).contains("ck-test-key"));
}
