#!/usr/bin/env python3
"""theoui: drive a running `Clicky --profile test` through its control inbox.

  theoui.py cmd '{"cmd":"uiWindows"}'     any control command, JSON reply on stdout
  theoui.py start [--tab bots] [binary]   start the test profile (with no Dock icon, never takes focus)
  theoui.py stop [--hard]                 quit every instance of this test profile (SIGKILL after 20 s, or at once)
  theoui.py instances                     the pids of every running instance of this test profile
  theoui.py shot NAME [window-number]     screenshot of one Theo window only -> <out>/NAME.png
  theoui.py text [window-number]          the text on screen with boxes (window points)
  theoui.py clicktext "words" [index]     finds the words on screen and clicks them, like a person would
"""
import json, os, pathlib, signal, subprocess, sys, time, uuid

REAL_HOME = pathlib.Path(os.path.expanduser("~"))
# THEOUI_PROFILE=clicks drives its own instance (--profile test-clicks), so several testers don't collide.
PROFILE = os.environ.get("THEOUI_PROFILE", "")
PROFILE_ARG = "test-" + PROFILE if PROFILE else "test"
ROOT = REAL_HOME / ("Library/Application Support/Theo-Test" + ("-" + PROFILE if PROFILE else ""))
HOME = ROOT / "home"
INBOX = HOME / ".clicky/control-inbox"
OUTBOX = HOME / ".clicky/control-outbox"
PIDFILE = ROOT / "test-instance.pid"
DEFAULT_BINARY = os.environ.get("THEOUI_BINARY", "/Applications/Theo.app/Contents/MacOS/Clicky")
OUT = pathlib.Path(os.environ.get("THEOUI_OUT", str(ROOT / "shots")))


def send(obj, timeout=60):
    if obj.get("cmd") != "uiState" and PIDFILE.exists() and not running_pid():
        return {"ok": False, "error": "The test instance isn't running."}
    INBOX.mkdir(parents=True, exist_ok=True)
    OUTBOX.mkdir(parents=True, exist_ok=True)
    ident = uuid.uuid4().hex
    tmp = INBOX / f"{ident}.tmp"
    tmp.write_text(json.dumps(obj))
    tmp.rename(INBOX / f"{ident}.json")
    reply = OUTBOX / f"{ident}.json"
    deadline = time.time() + timeout
    while time.time() < deadline:
        if reply.exists():
            text = reply.read_text()
            reply.unlink()
            return json.loads(text)
        time.sleep(0.05)
    return {"ok": False, "error": "timeout"}


def running_pid():
    if not PIDFILE.exists():
        return None
    try:
        pid = int(PIDFILE.read_text())
        os.kill(pid, 0)
        return pid
    except (ValueError, OSError):
        return None


def profile_pids(profile_arg=None):
    """Every running process started with `--profile <this profile>`, found by its arguments, not the pid file.

    The pid file only ever holds the newest launch, so an instance that outlived its stop (or one started some other
    way) was invisible to stop() and a second copy ran beside it. Exact match on the argument after --profile, so
    the owner's Theo (no --profile) and other testers' profiles are never touched.
    """
    target = profile_arg or PROFILE_ARG
    listing = subprocess.run(["ps", "-axww", "-o", "pid=,args="], capture_output=True, text=True).stdout
    found = []
    for line in listing.splitlines():
        parts = line.strip().split(None, 1)
        if len(parts) != 2 or not parts[0].isdigit():
            continue
        pid, words = int(parts[0]), parts[1].split()
        if pid == os.getpid():
            continue
        for index, word in enumerate(words[:-1]):
            if word == "--profile" and words[index + 1] == target:
                found.append(pid)
                break
        else:
            if f"--profile={target}" in words:
                found.append(pid)
    return found


def _alive(pid):
    """Running, not just a zombie waiting for its parent to collect it."""
    try:
        os.kill(pid, 0)
    except OSError:
        return False
    state = subprocess.run(["ps", "-o", "stat=", "-p", str(pid)], capture_output=True, text=True).stdout.strip()
    return bool(state) and not state.startswith("Z")


def stop_pids(pids, hard=False, wait=20.0):
    """SIGTERM (or SIGKILL) each, then SIGKILL whatever is still there after `wait` seconds. Returns any survivors."""
    pids = [p for p in dict.fromkeys(pids) if p]
    for pid in pids:
        try:
            os.kill(pid, signal.SIGKILL if hard else signal.SIGTERM)
        except OSError:
            pass
    deadline = time.time() + (0 if hard else wait)
    while time.time() < deadline and any(_alive(p) for p in pids):
        time.sleep(0.25)
    for pid in pids:
        if _alive(pid):
            try:
                os.kill(pid, signal.SIGKILL)
            except OSError:
                pass
    deadline = time.time() + 5
    while time.time() < deadline and any(_alive(p) for p in pids):
        time.sleep(0.1)
    return [p for p in pids if _alive(p)]


def tracked_instance(found=None):
    """The pid file's id, only while that process still carries this profile (a stale file's id can be reused)."""
    found = profile_pids() if found is None else found
    tracked = running_pid()
    return tracked if tracked in found else None


def start(binary, tab=None):
    found = profile_pids()
    # A stale pid file whose id now belongs to another program isn't a running Theo: launch one.
    current = tracked_instance(found)
    strays = [p for p in found if p != current]
    if strays:
        # Two copies of one profile share a home folder, control inbox and link port: never let a second one run.
        stop_pids(strays)
    if current:
        return current
    ROOT.mkdir(parents=True, exist_ok=True)
    # Theo's monitor comes from the real profile, so a test window can never open on the owner's main display.
    for key in ["v2.screen.claudia", "v2.screen.claudia.side", "v2.screen.claudia.sideFor"]:
        value = subprocess.run(["defaults", "read", "com.personal.clicky", key], capture_output=True, text=True).stdout.strip()
        if not value:
            raise SystemExit(f"Refusing to start: {key} is not set, so the window would open on the main display.")
        subprocess.run(["defaults", "write", f"com.personal.clicky.{PROFILE_ARG}", key, "-string", value], check=True)
    args = [binary, "--profile", PROFILE_ARG] + ([f"--tab={tab}"] if tab else [])
    log = open(ROOT / "test-instance.log", "ab")
    proc = subprocess.Popen(args, stdout=log, stderr=log, stdin=subprocess.DEVNULL, cwd=str(REAL_HOME), start_new_session=True)
    PIDFILE.write_text(str(proc.pid))
    for _ in range(100):
        time.sleep(0.2)
        if send({"cmd": "uiState"}, timeout=1).get("ok"):
            return proc.pid
        if proc.poll() is not None:
            raise SystemExit(f"The test instance exited at launch ({proc.returncode}). See {ROOT}/test-instance.log")
    raise SystemExit("The test instance didn't answer in 100 tries.")


def stop(hard=False):
    """Stops every instance of this profile, the pid file's and any other, and waits until they're gone."""
    found = profile_pids()
    # The pid file's id only counts while that process still carries this profile: a stale file's id can belong to
    # an unrelated program by now.
    tracked = tracked_instance(found)
    left = stop_pids(([tracked] if tracked else []) + found, hard=hard)
    PIDFILE.unlink(missing_ok=True)
    return left


def shot(name, number=None):
    OUT.mkdir(parents=True, exist_ok=True)
    if number is None:
        number = send({"cmd": "uiState"}).get("result", {}).get("frontNumber")
    path = OUT / f"{name}.png"
    subprocess.run(["screencapture", "-x", "-o", "-l", str(number), str(path)], check=True)
    return str(path)


def read_screen(number=None):
    """OCR of one Theo window; boxes in window points."""
    if number is None:
        number = send({"cmd": "uiState"}).get("result", {}).get("frontNumber")
    path = ROOT / "ocr.png"
    subprocess.run(["screencapture", "-x", "-o", "-l", str(number), str(path)], check=True)
    # The capture includes the window shadow only with -o off, so pixels map 1:1 to the window at this scale.
    # Theo's monitor is 2x; pixels map to window points at that scale, whatever the shadow does to the image size.
    scale = 2.0
    ocr = os.environ.get("THEOUI_OCR", str(REAL_HOME / "Library/Application Support/Theo-Test/theoui-ocr"))
    lines = subprocess.run([ocr, str(path)], capture_output=True, text=True).stdout.splitlines()
    pieces = [json.loads(line) for line in lines]
    for piece in pieces:
        for key in "xywh":
            piece[key] = round(piece[key] / scale, 1)
    return number, pieces


def click_text(words, index=0, number=None, within=None):
    """`within`: (x, y, w, h) in window points, to tell a sidebar row from the same words elsewhere."""
    number, pieces = read_screen(number)
    if within:
        x0, y0, w0, h0 = within
        pieces = [p for p in pieces if x0 <= p["x"] <= x0 + w0 and y0 <= p["y"] <= y0 + h0]
    needle = words.lower()
    exact = [p for p in pieces if p["text"].lower() == needle]
    matches = exact or [p for p in pieces if needle in p["text"].lower()]
    if len(matches) <= index:
        return {"ok": False, "error": f"'{words}' is not on screen", "seen": [p["text"] for p in pieces][:60]}
    piece = matches[index]
    # Within a longer line of text, aim at the words themselves rather than the middle of the line.
    start = piece["text"].lower().find(needle)
    share = (start + len(needle) / 2) / max(1, len(piece["text"]))
    x = piece["x"] + piece["w"] * share
    y = piece["y"] + piece["h"] / 2
    reply = send({"cmd": "uiClick", "window": number, "x": x, "y": y})
    reply["clicked"] = {"text": piece["text"], "x": round(x, 1), "y": round(y, 1)}
    return reply


if __name__ == "__main__":
    action = sys.argv[1] if len(sys.argv) > 1 else "help"
    if action == "cmd":
        print(json.dumps(send(json.loads(sys.argv[2]), timeout=int(sys.argv[3]) if len(sys.argv) > 3 else 60), indent=1, ensure_ascii=False))
    elif action == "start":
        rest = sys.argv[2:]
        tab = None
        if "--tab" in rest:
            index = rest.index("--tab")
            tab = rest[index + 1]
            del rest[index:index + 2]
        print(start(rest[0] if rest else DEFAULT_BINARY, tab))
    elif action == "stop":
        left = stop(hard="--hard" in sys.argv[2:])
        if left:
            raise SystemExit(f"Still running after SIGKILL: {left}")
    elif action == "instances":
        print(json.dumps(profile_pids()))
    elif action == "text":
        number, pieces = read_screen(int(sys.argv[2]) if len(sys.argv) > 2 else None)
        for piece in pieces:
            print(f"{piece['x']:7.1f} {piece['y']:7.1f} {piece['w']:6.1f}x{piece['h']:<5.1f} {piece['text']}")
    elif action == "clicktext":
        print(json.dumps(click_text(sys.argv[2], int(sys.argv[3]) if len(sys.argv) > 3 else 0), ensure_ascii=False))
    elif action == "shot":
        print(shot(sys.argv[2], int(sys.argv[3]) if len(sys.argv) > 3 else None))
    else:
        print(__doc__)
