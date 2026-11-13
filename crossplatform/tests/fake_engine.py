#!/usr/bin/env python3
"""Stand-in for `claude -p` (and `opencode run`) in the tests. Cross-platform: Mac, Linux and Windows.

Behaviour comes from files in $THEO_FAKE_DIR: `fake-mode` (the mode), `fake-reply` (a fixed reply), `fake-script.json`
(rules: the first whose `system` and `prompt` regexes match decides the reply), `fake-flaky` (a counter), `fake-down-model`.
Every call is logged to its own file in calls/ with its arguments, process ids and what it was told.
"""
import json, os, re, signal, subprocess, sys, time

D = os.environ.get("THEO_FAKE_DIR") or os.path.dirname(os.path.abspath(__file__))
WIN = os.name == "nt"


def read(name, default=""):
    try:
        with open(os.path.join(D, name), encoding="utf-8") as f:
            return f.read()
    except OSError:
        return default


args = sys.argv[1:]
mode = read("fake-mode", "ok").strip() or "ok"


def arg_after(flag):
    for i, a in enumerate(args[:-1]):
        if a == flag:
            return args[i + 1]
    return None


model = arg_after("--model") or arg_after("-m") or ""
system = arg_after("--append-system-prompt") or ""
system_file = arg_after("--append-system-prompt-file")
if system_file:
    # As Claude Code does: the file is read once, at the start.
    with open(system_file, encoding="utf-8") as f:
        system = f.read()
is_opencode = bool(args) and args[0] == "run"
if not is_opencode and "-p" in args and "--" not in args:
    # `claude -p` with no prompt argument reads the prompt from standard input, as Theo now sends it.
    prompt = sys.stdin.buffer.read().decode("utf-8")
else:
    prompt = args[-1] if args else ""
resume = "--resume" in args or "-s" in args
coding = "bypassPermissions" in args
pgid = os.getpgid(0) if not WIN else None


def log(extra=None):
    entry = {"t": time.time(), "mode": mode, "pid": os.getpid(), "pgid": pgid, "model": model, "resume": resume, "coding": coding,
             "opencode": is_opencode, "cwd": os.getcwd(), "args": args, "system": system, "prompt": prompt}
    if extra:
        entry.update(extra)
    # One file per call: appends from engines running at once can interleave on Windows.
    folder = os.path.join(D, "calls")
    os.makedirs(folder, exist_ok=True)
    name = "%020d-%d-%s.json" % (time.time_ns(), os.getpid(), "x" if extra else "a")
    tmp = os.path.join(folder, name + ".tmp")
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(json.dumps(entry))
    os.replace(tmp, os.path.join(folder, name))


def out(obj):
    sys.stdout.write(json.dumps(obj) + "\n")
    sys.stdout.flush()


def say(text):
    out({"type": "stream_event", "event": {"type": "content_block_delta", "delta": {"type": "text_delta", "text": text}}})


def init():
    out({"type": "system", "subtype": "init", "session_id": "fake-%d" % os.getpid()})


def done(**extra):
    out(dict({"type": "result", "is_error": False}, **extra))


def fail(text, code=1):
    out({"type": "result", "is_error": True, "result": text})
    sys.exit(code)


def ignore_term():
    if not WIN:
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        signal.signal(signal.SIGINT, signal.SIG_IGN)
        signal.signal(signal.SIGHUP, signal.SIG_IGN)


def coding_agent():
    """A coding run: do what the prompt says in the current folder ("create X containing Y"), or run the long command."""
    if "time.sleep(240)" in prompt:
        child = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(240)"])
        log({"child": child.pid})
        init()
        say("running the long command")
        child.wait()
    made = []
    for path, text in re.findall(r"create ([\w./-]+) containing(?: the single line)?:?\s*(.+?)(?:\.\s|$|\. Nothing|\. Change)", prompt):
        path = path.rstrip(".")
        os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
        with open(path, "w", encoding="utf-8") as f:
            f.write(text.strip().rstrip(".") + "\n")
        made.append(path)
    init()
    say("Done: " + (", ".join(made) if made else "nothing to change"))
    done()


def script_reply():
    try:
        rules = json.loads(read("fake-script.json", "[]"))
    except ValueError:
        rules = []
    for rule in rules:
        if re.search(rule.get("system", ""), system, re.S) and re.search(rule.get("prompt", ""), prompt, re.S):
            if rule.get("sleep"):
                time.sleep(rule["sleep"])
            if rule.get("error"):
                fail(rule["error"])
            if rule.get("hold"):
                # Says it, then keeps the turn open: a bot that is still working.
                init(); say(rule.get("reply", "")); time.sleep(rule["hold"]); done(); sys.exit(0)
            return rule.get("reply", "")
    return "fake engine ok"


log()

if args == ["--version"]:
    print("2.1.0 (Claude Code, stand-in)")
    sys.exit(0)
if args[:2] == ["auth", "status"]:
    signed_in = read("fake-auth", "in").strip() != "out"
    print(json.dumps({"loggedIn": signed_in, "authMethod": "claude.ai" if signed_in else "none", "subscriptionType": "max" if signed_in else None}))
    sys.exit(0 if signed_in else 1)
if args[:2] == ["mcp", "list"]:
    # A real check starts every server and can take seconds.
    time.sleep(float(read("fake-mcp-sleep", "0") or 0))
    sys.stdout.write(read("fake-mcp", "Checking MCP server health...\n\nclaude.ai Notion: https://mcp.notion.com/mcp - \u2714 Connected\n"))
    sys.exit(0)

if coding and mode in ("ok", "script", "reply", "slow"):
    coding_agent()
    sys.exit(0)

if mode == "ok":
    init(); say("fake engine ok"); done(result="fake engine ok")
elif mode == "reply":
    init(); say(read("fake-reply")); done()
elif mode == "script":
    init(); say(script_reply()); done()
elif mode == "crash":
    sys.stderr.write("Error: simulated engine crash (segfault in tokenizer)\n"); sys.exit(3)
elif mode == "error-result":
    fail("API Error: 529 Overloaded")
elif mode == "garbage":
    import base64
    print("<<<<not json at all>>>>")
    print(base64.b64encode(os.urandom(200000)).decode())
elif mode == "empty":
    pass
elif mode == "hang":
    init(); say("thinking..."); time.sleep(900)
elif mode == "hang-ignore-term":
    ignore_term(); init(); say("stubborn..."); time.sleep(900)
elif mode == "lost-session":
    if resume:
        fail("No conversation found with session ID: abc")
    init(); say("started over fine"); done()
elif mode == "slow":
    init()
    for i in range(1, 21):
        say("word%d " % i); time.sleep(0.3)
    done()
elif mode == "flood":
    for i in range(20000):
        say("x" * 50)
    done()
elif mode == "flood-big":
    for i in range(200000):
        say("y" * 20)
    done()
elif mode == "flood-oneline":
    say("z" * 8000000); done()
elif mode == "orphan-child":
    # A tool child, detached from the pipes, that ignores SIGTERM. The engine exits when its output pipe breaks.
    code = "import signal,time\ntry:\n signal.signal(signal.SIGTERM, signal.SIG_IGN)\nexcept Exception: pass\ntime.sleep(900)"
    child = subprocess.Popen([sys.executable, "-c", code], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    log({"child": child.pid, "leader": os.getpid()})
    init()
    try:
        for i in range(900):
            say("tick%d " % i); time.sleep(1)
    except (BrokenPipeError, OSError):
        sys.exit(0)
elif mode == "hold-stdout":
    # Answers at once but leaves a child holding the output pipe open, outside the process tree when it can.
    code = "import time\ntime.sleep(900)"
    kw = {"start_new_session": True} if not WIN else {"creationflags": 0x00000008 | 0x01000000}  # DETACHED_PROCESS | CREATE_BREAKAWAY_FROM_JOB
    try:
        child = subprocess.Popen([sys.executable, "-c", code], stdout=sys.stdout, **kw)
    except OSError:
        child = subprocess.Popen([sys.executable, "-c", code], stdout=sys.stdout, start_new_session=not WIN)
    log({"child": child.pid, "holder": True})
    init(); say("answered but a child holds the pipe"); done()
elif mode == "overloaded":
    fail('API Error: 529 {"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}')
elif mode == "ratelimit":
    fail("API Error: 429 rate_limit_error: This request would exceed the rate limit")
elif mode == "model-down":
    if model == read("fake-down-model").strip():
        fail("API Error: 529 Overloaded")
    init(); say("answered on " + model); done()
elif mode == "flaky":
    n = int(read("fake-flaky", "0").strip() or 0)
    if n > 0:
        with open(os.path.join(D, "fake-flaky"), "w") as f:
            f.write(str(n - 1))
        fail("API Error: 529 Overloaded")
    init(); say("answered after retry on " + model); done()
elif mode == "autherr":
    fail("Invalid API key · Please run /login")
elif mode == "usage":
    init(); say("counted")
    done(total_cost_usd=0.0125, usage={"input_tokens": 100, "output_tokens": 40, "cache_read_input_tokens": 1000, "cache_creation_input_tokens": 10})
elif mode == "oc-overloaded":
    if is_opencode:
        out({"type": "error", "error": {"name": "APIError", "data": {"message": "529 Overloaded: the provider is overloaded"}}}); sys.exit(1)
    init(); say("stand-in answered on " + model); done()
elif mode == "tell-par":
    init()
    if "This is a private thread between you and" in prompt:
        time.sleep(5); say("answered after 5 s")
    elif "answered you privately" in prompt:
        say("all done")
    else:
        say(read("fake-reply"))
    done()
else:
    sys.stderr.write("unknown mode %s\n" % mode); sys.exit(64)
