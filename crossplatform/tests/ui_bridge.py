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


if __name__ == "__main__":
    T.fresh(); T.start()
    T.setd("test.engine.claude", str(T.FAKE)); T.setd("test.bots.retryDelays", [0.2])
    T.fake_script([{"system": r"You are Ledger", "reply": "At $8 a month with $1,200 of costs, you break even at **150 subscribers**. Every subscriber after that adds $8 of margin.", "sleep": 1.5},
                   {"system": r"You are Theo", "prompt": "answered you privately", "reply": "Ledger says you break even at 150 subscribers; everything after that is $8 of margin each."},
                   {"system": r"You are Theo", "prompt": "Ledger", "reply": "Asking Ledger for the numbers.\n[TELL: Ledger: break-even subscribers at $8/month with $1,200/month costs?]"},
                   {"reply": "Hi! I'm here. Ask me anything, or hand me something to schedule."}])
    for name, desc in [("Ledger", "Finance analyst"), ("Scout", "Researcher"), ("Forge", "Engineering lead")]:
        T.P({"cmd": "botCreate", "name": name, "description": desc, "instructions": "You are %s, a %s." % (name, desc.lower()), "model": "claude-haiku-5-5"})
    ids = {b["name"]: b["id"] for b in T.state()["bots"]}
    T.P({"cmd": "groupSave", "id": "launch", "name": "Launch room", "head": "theo", "members": [ids["Ledger"], ids["Scout"], ids["Forge"]]})
    T.P({"cmd": "routineAdd", "name": "Morning brief", "target": ids["Scout"], "when": "weekdays 08:00", "do": "Send me the morning brief."})
    print("UI on http://127.0.0.1:8765", flush=True)
    http.server.ThreadingHTTPServer(("127.0.0.1", 8765), H).serve_forever()
