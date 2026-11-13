"""Driving theod from outside, the way the Swift suites drive Theo's test profile: start and stop it, send control-inbox
commands, read its files. Works on macOS, Linux and Windows."""
import json, os, pathlib, signal, subprocess, sys, time, uuid

HERE = pathlib.Path(__file__).resolve().parent
WIN = os.name == "nt"
ROOT = pathlib.Path(os.environ.get("THEO_TEST_ROOT") or (HERE / "work"))
DATA = ROOT / "data"
BOTS = DATA / "Bots"
FAKE_DIR = ROOT / "fake"
EXE = ".exe" if WIN else ""
BIN = pathlib.Path(os.environ.get("THEOD_BIN") or (HERE.parent / "target" / "debug" / ("theod" + EXE)))
FAKE = HERE / "fake_engine.py"
FAKE_GH = HERE / "fake_gh.py"
PY = sys.executable

_proc = None


_STARTED = {}


def alive(pid, started=None):
    """Whether this process is running. `started` (seconds since 1970, from the engine's own log): a process with the same id
    that started at another time is a different process (Windows reuses ids quickly)."""
    if not pid:
        return False
    started = started or _STARTED.get(pid)
    if WIN:
        import ctypes
        from ctypes import wintypes
        k = ctypes.windll.kernel32
        k.OpenProcess.restype = wintypes.HANDLE
        h = k.OpenProcess(0x1000, False, int(pid))  # PROCESS_QUERY_LIMITED_INFORMATION
        if not h:
            return False
        code = wintypes.DWORD()
        k.GetExitCodeProcess(h, ctypes.byref(code))
        times = [wintypes.FILETIME() for _ in range(4)]
        k.GetProcessTimes(h, *[ctypes.byref(x) for x in times])
        k.CloseHandle(h)
        if code.value != 259:  # STILL_ACTIVE
            return False
        if started:
            ft = (times[0].dwHighDateTime << 32) | times[0].dwLowDateTime
            created = ft / 1e7 - 11644473600
            if abs(created - started) > 10:
                return False
        return True
    try:
        os.kill(pid, 0)
    except OSError:
        return False
    # A zombie (exited, not yet reaped by its parent) isn't running.
    try:
        st = subprocess.run(["ps", "-o", "stat=", "-p", str(pid)], capture_output=True, text=True).stdout.strip()
        return bool(st) and not st.startswith("Z")
    except Exception:
        return True


def kill_pid(pid):
    try:
        if WIN:
            subprocess.run(["taskkill", "/F", "/T", "/PID", str(pid)], capture_output=True)
        else:
            os.kill(pid, 9)
    except OSError:
        pass


def fresh():
    stop(hard=True)
    import shutil
    shutil.rmtree(ROOT, ignore_errors=True)
    DATA.mkdir(parents=True)
    FAKE_DIR.mkdir(parents=True)


def start(wait=None):
    wait = wait or float(os.environ.get("THEO_START_WAIT", "20"))
    global _proc
    env = dict(os.environ, THEO_FAKE_DIR=str(FAKE_DIR))
    log = open(ROOT / "theod.log", "a")
    kw = {}
    if not WIN:
        kw["start_new_session"] = True
    else:
        kw["creationflags"] = 0x00000200  # CREATE_NEW_PROCESS_GROUP
    t0 = time.time()
    _proc = subprocess.Popen([str(BIN), "--data", str(DATA), "--test"], env=env, stdout=log, stderr=log, stdin=subprocess.DEVNULL, **kw)
    while time.time() - t0 < wait:
        if P({"cmd": "ping"}, timeout=2).get("ok"):
            return round(time.time() - t0, 2)
        if _proc.poll() is not None:
            break
    log.flush()
    tail = (ROOT / "theod.log").read_text(encoding="utf-8", errors="replace")[-4000:]
    raise RuntimeError("theod didn't start (exit %s). Its log ends:\n%s" % (_proc.poll(), tail))


def pid():
    return _proc.pid if _proc and _proc.poll() is None else None


def stop(hard=False):
    global _proc
    if not _proc:
        return
    if _proc.poll() is None:
        if hard:
            _proc.kill()
        else:
            P({"cmd": "quit"}, timeout=5)
        try:
            _proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            _proc.kill()
            _proc.wait()
    _proc = None


def restart(hard=False):
    stop(hard=hard)
    time.sleep(0.5)
    return start()


def P(obj, timeout=30):
    inbox, outbox = DATA / "control-inbox", DATA / "control-outbox"
    inbox.mkdir(parents=True, exist_ok=True)
    outbox.mkdir(parents=True, exist_ok=True)
    ident = uuid.uuid4().hex
    tmp = inbox / (ident + ".tmp")
    tmp.write_text(json.dumps(obj), encoding="utf-8")
    os.replace(tmp, inbox / (ident + ".json"))
    reply = outbox / (ident + ".json")
    deadline = time.time() + timeout
    while time.time() < deadline:
        if reply.exists():
            try:
                t = reply.read_text(encoding="utf-8")
                reply.unlink()
                return json.loads(t)
            except (OSError, ValueError):
                pass
        time.sleep(0.03)
    return {"ok": False, "error": "timeout"}


def setd(key, value):
    return P({"cmd": "uiSetDefaults", "key": key, "value": value})


def state():
    return P({"cmd": "botsState"}).get("result", {}) or {}


def chat(cid, limit=200):
    return P({"cmd": "botChat", "id": cid, "limit": limit}).get("result", []) or []


def disk_chat(cid):
    f = BOTS / "chats" / (cid.replace(":", "-") + ".json")
    try:
        return json.loads(f.read_text(encoding="utf-8")).get("messages", [])
    except (OSError, ValueError):
        return []


def say(bot, text):
    return P({"cmd": "botSay", "bot": bot, "text": text})


def busy(s):
    return bool(s.get("replying")) or bool(s.get("exchanges")) or bool(s.get("rounds")) or bool(s.get("queued"))


def wait_idle(seconds=120, quiet=2.0, poll=0.25, tick=None):
    t0 = time.time()
    calm = 0.0
    while time.time() - t0 < seconds:
        s = state()
        if tick:
            tick(s)
        calm = 0.0 if busy(s) else calm + poll
        if calm >= quiet:
            return True, round(time.time() - t0, 1)
        time.sleep(poll)
    return False, round(time.time() - t0, 1)


def wait_until(fn, seconds=30, poll=0.2):
    t0 = time.time()
    while time.time() - t0 < seconds:
        v = fn()
        if v:
            return v
        time.sleep(poll)
    return None


def bot_id(name):
    for b in json.loads((BOTS / "bots.json").read_text(encoding="utf-8")):
        if b.get("name") == name:
            return b["id"]
    return None


def fake(mode):
    (FAKE_DIR / "fake-mode").write_text(mode, encoding="utf-8")


def fake_reply(text):
    (FAKE_DIR / "fake-reply").write_text(text, encoding="utf-8")


def fake_script(rules):
    (FAKE_DIR / "fake-script.json").write_text(json.dumps(rules), encoding="utf-8")
    fake("script")


def calls(since=0):
    folder = FAKE_DIR / "calls"
    if not folder.exists():
        return []
    out = []
    for f in sorted(folder.glob("*.json"))[since:]:
        try:
            out.append(json.loads(f.read_text(encoding="utf-8")))
        except (OSError, ValueError):
            out.append({"pid": None, "args": [], "system": "", "prompt": "", "resume": False, "coding": False, "opencode": False, "model": "", "t": 0, "cwd": ""})
    return out


def calls_mark():
    folder = FAKE_DIR / "calls"
    return len(list(folder.glob("*.json"))) if folder.exists() else 0


def engine_pids():
    """Everything left from a stand-in engine: the engines, their tool children, and (Mac and Linux) their process groups."""
    out = set()
    groups = set()
    for c in calls():
        for k in ("pid", "child"):
            if c.get(k):
                _STARTED[c[k]] = c.get("t")
                if alive(c[k]):
                    out.add(c[k])
        if c.get("pgid"):
            groups.add(c["pgid"])
    if not WIN:
        me = os.getpgid(0)
        for g in groups - {me}:
            r = subprocess.run(["pgrep", "-g", str(g)], capture_output=True, text=True).stdout.split()
            out |= {int(x) for x in r if alive(int(x))}
    return sorted(out)


def kill_all(pids):
    for p in pids:
        kill_pid(p)


def rss_kb(p):
    if not p:
        return None
    if WIN:
        out = subprocess.run(["tasklist", "/FI", "PID eq %d" % p, "/FO", "CSV", "/NH"], capture_output=True, text=True).stdout
        try:
            return int(out.strip().split('","')[-1].replace('"', "").replace(" K", "").replace(",", "").replace(".", ""))
        except (ValueError, IndexError):
            return None
    out = subprocess.run(["ps", "-o", "rss=", "-p", str(p)], capture_output=True, text=True).stdout.strip()
    return int(out) if out else None


def nonce():
    return uuid.uuid4().hex[:8]
