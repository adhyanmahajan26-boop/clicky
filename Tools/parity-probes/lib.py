"""Helpers for the Hermes/OpenClaw parity probes (docs/HARNESS-PARITY.md). Test profile only, never the owner's Theo.

  python3 -c "import lib, crew; lib.setup(crew.CREW); lib.setd('test.bots.retryDelays', [1, 2])"
  python3 probes.py            every probe; or name some. Results go to results/<probe>.json.

skills_*, recall use real Claude Haiku in the test profile; the rest use fake-engine.sh."""
import json, os, pathlib, signal, subprocess, time, uuid, datetime
HERE = pathlib.Path(__file__).resolve().parent
PROFILE = os.environ.get("PARITY_PROFILE", "parity")
BIN = os.environ.get("PARITY_BIN", str(HERE.parents[1] / "dd/Build/Products/Debug/Clicky.app/Contents/MacOS/Clicky"))  # set PARITY_BIN to your build
UI = str(HERE.parent / "theoui.py")
ROOT = pathlib.Path.home() / f"Library/Application Support/Theo-Test-{PROFILE}"
HOME = ROOT / "home"
DATA = HOME / "Library/Application Support/Theo/Bots"
FAKE = HERE / "fake-engine.sh"
CALLS = HERE / "calls.jsonl"
MODEL = "claude-haiku-5-5"
DOMAIN = f"com.personal.clicky.test-{PROFILE}"

def send(obj, timeout=30):
    inbox, outbox = HOME / ".clicky/control-inbox", HOME / ".clicky/control-outbox"
    inbox.mkdir(parents=True, exist_ok=True); outbox.mkdir(parents=True, exist_ok=True)
    ident = uuid.uuid4().hex
    tmp = inbox / f"{ident}.tmp"; tmp.write_text(json.dumps(obj)); tmp.rename(inbox / f"{ident}.json")
    reply = outbox / f"{ident}.json"; deadline = time.time() + timeout
    while time.time() < deadline:
        if reply.exists():
            t = reply.read_text(); reply.unlink(); return json.loads(t)
        time.sleep(0.05)
    return {"ok": False, "error": "timeout"}

def ui(*args):
    env = dict(os.environ, THEOUI_PROFILE=PROFILE, THEOUI_OUT=str(HERE / "shots"))
    return subprocess.run(["python3", UI, *args], env=env, capture_output=True, text=True).stdout.strip()

def pid():
    try:
        p = int((ROOT / "test-instance.pid").read_text()); os.kill(p, 0); return p
    except Exception: return None

def start():
    out = ui("start", "--tab", "bots", BIN); time.sleep(2); return out

def stop(hard=False):
    p = pid()
    if p:
        os.kill(p, signal.SIGKILL if hard else signal.SIGTERM)
        for _ in range(60):
            try: os.kill(p, 0); time.sleep(0.25)
            except OSError: break
    (ROOT / "test-instance.pid").unlink(missing_ok=True)

def restart(): stop(); time.sleep(1); return start()

def defaults(key, value):
    if isinstance(value, bool): args = ["-bool", "true" if value else "false"]
    elif isinstance(value, int): args = ["-int", str(value)]
    elif isinstance(value, list): args = ["-array", *map(str, value)]
    else: args = ["-string", str(value)]
    subprocess.run(["defaults", "write", DOMAIN, key, *args], check=True)

def setd(key, value): return send({"cmd": "uiSetDefaults", "key": key, "value": value})
def state(): return send({"cmd": "botsState"}).get("result", {})
def chat(cid, limit=400): return send({"cmd": "botChat", "id": cid, "limit": limit}).get("result", []) or []
def say(bot, text): return send({"cmd": "botSay", "bot": bot, "text": text})

def wait_idle(seconds=300, quiet=4, poll=1.0):
    t0 = time.time(); calm = 0
    while time.time() - t0 < seconds:
        s = state(); busy = bool(s.get("replying")) or bool(s.get("exchanges"))
        calm = 0 if busy else calm + poll
        if calm >= quiet: return True
        time.sleep(poll)
    return False

def bots(): return json.loads((DATA / "bots.json").read_text())
def bot_id(name): return next((b["id"] for b in bots() if b.get("name") == name), None)
def fake(mode, reply=None):
    (HERE / "fake-mode").write_text(mode)
    if reply is not None: (HERE / "fake-reply").write_text(reply)
def use_fake(on=True): setd("test.engine.claude", str(FAKE) if on else "")
def calls():
    if not CALLS.exists(): return []
    return [json.loads(l) for l in CALLS.read_text().splitlines() if l.strip()]
def clear_calls(): CALLS.write_text("")
def arg(call, name):
    a = call["args"]; return a[a.index(name) + 1] if name in a else None
def routines(): 
    f = DATA / "routines.json"; return json.loads(f.read_text()) if f.exists() else []
def iso(dt): return dt.astimezone(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
def last_text(cid, author=None):
    msgs = [m for m in chat(cid) if author is None or m.get("author") == author]
    return msgs[-1].get("text", "") if msgs else ""

def setup(crew):
    stop(); time.sleep(1)
    subprocess.run(["rm", "-rf", str(ROOT)])
    subprocess.run(["defaults", "delete", DOMAIN], capture_output=True)
    defaults("v2.setup.completed", True)
    start()
    send({"cmd": "botUpdate", "id": "theo", "model": MODEL})
    made = {}
    for name, desc, instr in crew:
        r = send({"cmd": "botCreate", "name": name, "description": desc, "instructions": instr, "provider": "claude", "model": MODEL})
        made[name] = r.get("result", {}).get("id")
    return made
