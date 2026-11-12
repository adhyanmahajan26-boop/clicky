#!/usr/bin/env python3
"""Runs the desktop app's UI in an ordinary browser against a live theod, for looking at and clicking through the UI without
building the app: http://127.0.0.1:8765. `window.__TAURI__.core.invoke` is stood in by a fetch to /invoke, which goes through
theod's control inbox, the same commands the app's `control` call takes. Uses the stand-in engine, in tests/work-ui."""
import http.server, json, os, pathlib, sys

HERE = pathlib.Path(__file__).resolve().parent
os.environ.setdefault("THEO_TEST_ROOT", str(HERE / "work-ui"))
import lib as T  # noqa: E402

UI = HERE.parent / "app" / "ui"
SHIM = """<script>window.__TAURI__ = { core: { invoke: async (name, args) => {
  if (name !== 'control') return null;
  const r = await fetch('/invoke', { method: 'POST', body: JSON.stringify(args.cmd) }); return r.json(); } } };</script>"""


class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def send(self, body, ctype):
        self.send_response(200); self.send_header("Content-Type", ctype); self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)

    def do_GET(self):
        name = self.path.split("?")[0].lstrip("/") or "index.html"
        f = (UI / name).resolve()
        if UI not in f.parents or not f.is_file():
            self.send_response(404); self.end_headers(); return
        body = f.read_bytes()
        if name == "index.html":
            body = body.replace(b'<script src="app.js">', SHIM.encode() + b'<script src="app.js">')
        self.send(body, {"html": "text/html", "js": "text/javascript", "css": "text/css"}.get(name.rsplit(".", 1)[-1], "application/octet-stream") + "; charset=utf-8")

    def do_POST(self):
        cmd = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        self.send(json.dumps(T.P(cmd)).encode(), "application/json")


CREW = {
    "Builder": ("Engineering", {"fin": "bone", "trim": "#5B8DEF", "eye": "wide", "top": "handle", "extra": "none"}),
    "Researcher": ("Growth", {"fin": "sky", "trim": "#F4F4F5", "eye": "round", "top": "twin", "extra": "none"}),
    "Designer": ("Engineering", {"fin": "lilac", "trim": "#F06FB0", "eye": "tall", "top": "beret", "extra": "none"}),
    "Code Reviewer": ("Engineering", {"fin": "graphite", "trim": "#9B7BF0", "eye": "block", "top": "twin", "extra": "star"}),
    "Inbox Triage": ("Growth", {"fin": "sand", "trim": "#45C8E6", "eye": "round", "top": "headset", "extra": "none"}),
    "Manager": ("Planning", {"fin": "graphite", "trim": "#F4D7C4", "eye": "tall", "top": "tophat", "extra": "bowtie"}),
    "Copy Editor": ("Growth", {"fin": "slate", "trim": "#F4F4F5", "eye": "tall", "top": "handle", "extra": "pencil"}),
    "Release Mgr": ("Engineering", {"fin": "cocoa", "trim": "#F4D7C4", "eye": "wide", "top": "flag", "extra": "none"}),
}


def seed():
    T.setd("test.engine.claude", str(T.FAKE)); T.setd("test.bots.retryDelays", [0.2]); T.setd("v3.bots.fallbackModels", ["off"])
    (T.FAKE_DIR / "fake-mcp").write_text("Checking MCP server health...\n\nclaude.ai Notion: https://mcp.notion.com/mcp - \u2714 Connected\nclaude.ai Gmail: https://gmailmcp.googleapis.com/mcp/v1 - \u2714 Connected\nclaude.ai Linear: https://mcp.linear.app/mcp - ! Needs authentication\nsentry: npx @sentry/mcp-server - \u2718 Failed to connect\nclaude.ai Google Drive: https://drivemcp.googleapis.com/mcp/v1 - \u2714 Connected\n", encoding="utf-8")
    T.fake_script([
        {"system": r"You are Researcher", "error": "Invalid API key \u00b7 Please run /login"},
        {"system": r"You are Designer", "error": "Tool crashed: the image renderer exited with code 139. Nothing was written."},
        {"system": r"You are Builder", "reply": "Writing the migration for the orders table now, then the tests…", "hold": 3600},
        {"system": r"You are Inbox Triage", "reply": "Sorted today's mail: 3 replies drafted, 12 archived.\n```routine\n{\"name\": \"Inbox sweep\", \"when\": \"every 2 hours\", \"do\": \"Sort new mail and draft replies\"}\n```"},
        {"system": r"You are Code Reviewer", "reply": "Reviewed the checkout PR: two small issues (an unchecked null in `cart.ts` and a missing test for refunds). Otherwise good to merge."},
        {"system": r"You are Manager", "reply": "We can ship Friday if we cut one thing. [CHOOSE: What should we cut for Friday? | Dark mode: two days saved, nobody asked for it yet | Export to CSV: one day saved, two customers want it]"},
        {"system": r"You are Ledger", "reply": "At $8 a month with $1,200 of costs, you break even at **150 subscribers**.", "sleep": 1.5},
        {"system": r"You are Theo", "prompt": "answered you privately", "reply": "Ledger says you break even at 150 subscribers; everything after that is $8 of margin each."},
        {"system": r"You are Theo", "prompt": "Ledger", "reply": "Asking Ledger for the numbers.\n[TELL: Ledger: break-even subscribers at $8/month with $1,200/month costs?]"},
        {"system": r"You are Theo", "prompt": "hello-demo", "reply": "One small script.\nProject: Hello demo\nNew folder: hello-demo\n```prompt\nIn the current folder create hello.txt containing hello from Theo. Nothing else.\n```"},
        {"reply": "Hi! I'm here. Ask me anything, or hand me something to schedule."}])
    ids = {}
    for name, (desc, look) in CREW.items():
        r = T.P({"cmd": "botCreate", "name": name, "description": desc, "instructions": "You are %s, %s." % (name, desc.lower()), "model": "claude-haiku-5-5"})
        ids[name] = r["result"]["id"]
        T.P({"cmd": "botLook", "id": ids[name], "look": look})
    r = T.P({"cmd": "botCreate", "name": "Ledger", "description": "Finance", "instructions": "You are Ledger, finance.", "model": "claude-haiku-5-5"})
    ids["Ledger"] = r["result"]["id"]
    T.P({"cmd": "botLook", "id": ids["Ledger"], "look": {"fin": "bone", "trim": "#45C8E6", "eye": "round", "top": "none", "extra": "bezel"}})
    T.P({"cmd": "botUpdate", "id": ids["Release Mgr"], "enabled": False})
    T.P({"cmd": "groupSave", "id": "launch", "name": "Launch room", "head": "theo", "members": [ids["Builder"], ids["Designer"], ids["Ledger"]]})
    T.P({"cmd": "routineAdd", "name": "Morning brief", "target": ids["Researcher"], "when": "weekdays 08:00", "do": "Send me the morning brief."})
    T.say(ids["Code Reviewer"], "Review the checkout PR, please.")
    T.say(ids["Inbox Triage"], "Sort today's mail.")
    T.say(ids["Manager"], "Can we ship on Friday?")
    T.say(ids["Researcher"], "What did competitors launch this week?")
    T.say(ids["Designer"], "Make the launch banner.")
    T.say("theo", "Ask Ledger: what's our break-even at $8 a month with $1,200 of costs?")
    T.wait_idle(seconds=30)
    T.say("theo", "Build a tiny script in a new folder called hello-demo that says hello.")
    T.wait_idle(seconds=30)
    T.say(ids["Builder"], "Add the orders table migration.")
    return ids


if __name__ == "__main__":
    T.fresh(); T.start()
    seed()
    if os.environ.get("THEOD_BIN"):
        print("seeded the app", flush=True)
        import time
        while True:
            time.sleep(3600)
    print("UI on http://127.0.0.1:8765", flush=True)
    http.server.ThreadingHTTPServer(("127.0.0.1", 8765), H).serve_forever()
