#!/usr/bin/env python3
"""Stand-in for `claude -p` (and `opencode run`, `codex exec`, `cursor-agent -p`, `gemini -p` and `grok -p`) in the tests.
Cross-platform: Mac, Linux and Windows. Which agent it plays comes from the arguments Theo passes, and it answers in that
agent's own output format.

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
# The other agents, told apart by what Theo passes each of them (harness.rs run_on_engine).
if args[:1] == ["exec"]:
    agent = "codex"
elif "--stream-partial-output" in args:
    agent = "cursor"
elif arg_after("--output-format") == "json" and "-p" in args:
    agent = "gemini"
elif arg_after("--output-format") == "streaming-messages-json":
    agent = "grok"
else:
    agent = "opencode" if is_opencode else "claude"


def flag_values(flag):
    out = []
    if flag in args:
        for a in args[args.index(flag) + 1:]:
            if a.startswith("--"):
                break
            out.append(a)
    return out


# Permission rules: on the command line, and from a --settings file, as Claude Code merges them.
allowed, denied = flag_values("--allowedTools"), flag_values("--disallowedTools")
settings_file = arg_after("--settings")
if settings_file:
    with open(settings_file, encoding="utf-8") as f:
        perms = json.load(f).get("permissions", {})
    allowed += perms.get("allow", [])
    denied += perms.get("deny", [])
if agent == "codex":
    # `codex exec ... -` reads the prompt from standard input.
    prompt = sys.stdin.buffer.read().decode("utf-8")
elif agent == "gemini":
    # Gemini CLI puts -p's words after what came on standard input.
    prompt = sys.stdin.buffer.read().decode("utf-8") + (arg_after("-p") or "")
elif agent == "grok":
    prompt = arg_after("-p") or ""
elif agent == "cursor":
    prompt = args[-1] if args else ""
elif not is_opencode and "-p" in args and "--" not in args:
    # `claude -p` with no prompt argument reads the prompt from standard input, as Theo now sends it.
    prompt = sys.stdin.buffer.read().decode("utf-8")
else:
    prompt = args[-1] if args else ""
resume = "--resume" in args or "-s" in args or args[:2] == ["exec", "resume"]
coding = "bypassPermissions" in args
pgid = os.getpgid(0) if not WIN else None


def log(extra=None):
    entry = {"t": time.time(), "mode": mode, "pid": os.getpid(), "pgid": pgid, "model": model, "resume": resume, "coding": coding,
             "opencode": is_opencode, "agent": agent, "cwd": os.getcwd(), "args": args, "allowed": allowed, "denied": denied, "system": system, "prompt": prompt}
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


def agent_answer(text):
    """The reply in the agent's own output format (what engine.rs reads for each)."""
    session = "fake-%s-%d" % (agent, os.getpid())
    if agent == "codex":
        out({"type": "thread.started", "thread_id": session})
        out({"type": "item.completed", "item": {"id": "item_0", "type": "agent_message", "text": "Looking."}})
        out({"type": "item.completed", "item": {"id": "item_1", "type": "agent_message", "text": text}})
        out({"type": "turn.completed", "usage": {"input_tokens": 10, "cached_input_tokens": 0, "output_tokens": 5}})
        reply_file = arg_after("-o")
        if reply_file:
            with open(reply_file, "w", encoding="utf-8") as f:
                f.write(text)
    elif agent == "cursor":
        out({"type": "system", "subtype": "init", "session_id": session})
        half = len(text) // 2
        for piece in (text[:half], text[half:]):
            out({"type": "assistant", "message": {"role": "assistant", "content": [{"type": "text", "text": piece}]}, "session_id": session, "timestamp_ms": int(time.time() * 1000)})
        out({"type": "assistant", "message": {"role": "assistant", "content": [{"type": "text", "text": text}]}, "session_id": session})
        out({"type": "result", "subtype": "success", "is_error": False, "result": text, "session_id": session})
    elif agent == "gemini":
        sys.stdout.write(json.dumps({"session_id": session, "response": text, "stats": {"models": {}}}, indent=2) + "\n")
    elif agent == "grok":
        out({"type": "assistant", "text": "a note between tool calls"})
        out({"type": "result", "result": text, "session_id": session, "is_error": False})
    sys.stdout.flush()


def agent_failure(text, code=1):
    if agent == "codex":
        out({"type": "thread.started", "thread_id": "fake-codex-%d" % os.getpid()})
        out({"type": "turn.failed", "error": {"message": text}})
    elif agent == "cursor":
        out({"type": "result", "subtype": "error", "is_error": True, "result": text})
    elif agent == "gemini":
        sys.stdout.write(json.dumps({"error": {"type": "Error", "message": text, "code": code}}, indent=2) + "\n")
    elif agent == "grok":
        out({"type": "result", "result": text, "is_error": True})
    sys.exit(code)


def toml_value(text):
    import tomllib
    return tomllib.loads("value = " + text)["value"]


def shared_hub_server():
    """The connector hub's server as each of the other agents is given it, and whether its tools may run unasked:
    Codex from `-c mcp_servers.theo_apps.*` overrides (approve), Cursor from .cursor/mcp.json with --approve-mcps, Gemini CLI
    from .gemini/settings.json in a trusted folder with `trust`, Grok from its config with each tool in --allow."""
    name = "theo_apps"
    if agent == "codex":
        found = {}
        for i, a in enumerate(args[:-1]):
            if a == "-c" and args[i + 1].startswith("mcp_servers.%s." % name):
                key, value = args[i + 1][len("mcp_servers.%s." % name):].split("=", 1)
                found[key] = toml_value(value)
        if "command" not in found:
            return None, None
        server = {"command": [found["command"]] + found.get("args", []), "env": found.get("env", {})}
        return server, lambda tool: found.get("default_tools_approval_mode") == "approve"
    if agent in ("cursor", "gemini"):
        path = os.path.join(os.getcwd(), ".cursor" if agent == "cursor" else ".gemini", "mcp.json" if agent == "cursor" else "settings.json")
        if not os.path.exists(path):
            return None, None
        if agent == "gemini" and os.environ.get("GEMINI_CLI_TRUST_WORKSPACE") != "true":
            # An untrusted folder gets no MCP servers at all.
            return None, None
        with open(path, encoding="utf-8") as f:
            found = json.load(f).get("mcpServers", {}).get(name)
        if not found:
            return None, None
        server = {"command": [found["command"]] + found.get("args", []), "env": found.get("env", {})}
        if agent == "cursor":
            return server, lambda tool: "--approve-mcps" in args
        return server, lambda tool: found.get("trust") is True
    if agent == "grok":
        path = os.environ.get("THEO_TEST_GROK_CONFIG")
        if not path or not os.path.exists(path):
            return None, None
        import tomllib
        with open(path, "rb") as f:
            found = tomllib.load(f).get("mcp_servers", {}).get(name)
        if not found or not found.get("enabled", True):
            return None, None
        allowed_tools = [args[i + 1] for i, a in enumerate(args[:-1]) if a == "--allow"]
        server = {"command": [found["command"]] + found.get("args", []), "env": found.get("env", {})}
        return server, lambda tool: ("mcp__%s__%s" % (name, tool)) in allowed_tools
    return None, None


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

# The other agents' own sign-in checks (brains.rs signed_in): `codex login status`, `cursor-agent status`, `grok models`.
if args[:2] == ["login", "status"] or args in (["status"], ["models"]):
    signed_in = read("fake-auth", "in").strip() != "out"
    print("Logged in using ChatGPT" if signed_in else "Not logged in")
    sys.exit(0 if signed_in else 1)

if agent in ("codex", "cursor", "gemini", "grok") and mode != "mcp":
    if mode == "signedout-agent":
        said = {"codex": "Error: Not logged in. Run `codex login`.", "cursor": "Error: Authentication required. Run `cursor-agent login`.",
                "gemini": "Please set an Auth method in your settings.json or specify GEMINI_API_KEY.", "grok": "You're not signed in. Run `grok login`."}[agent]
        sys.stderr.write(said + "\n")
        agent_failure(said, 41 if agent == "gemini" else 1)
    if mode in ("overloaded", "error-result"):
        agent_failure("API Error: 529 Overloaded")
    if mode == "usage-limit" and agent in ("codex", "cursor"):
        agent_failure("You've hit your usage limit. Try again in 3 hours." if agent == "codex" else "You're out of usage. Increase your limit at cursor.com.")
    text = {"reply": lambda: read("fake-reply"), "script": script_reply}.get(mode, lambda: "fake %s ok on %s" % (agent, model or "its default"))()
    agent_answer(text)
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
elif mode == "signedout-cli":
    # What Claude Code on Windows printed when signed out (seen on GitHub's Windows runners): its line as an assistant message
    # marked with an error, then a result carrying the same line.
    init()
    out({"type": "assistant", "message": {"role": "assistant", "content": [{"type": "text", "text": "Not logged in · Please run /login"}]}, "error": "authentication_failed"})
    out({"type": "result", "subtype": "success", "is_error": True, "result": "Not logged in · Please run /login"})
    sys.exit(1)
elif mode == "signedout-quiet":
    # The same line with nothing marking it as an error, and a clean exit.
    init()
    out({"type": "assistant", "message": {"role": "assistant", "content": [{"type": "text", "text": "Not logged in · Please run /login"}]}})
    out({"type": "result", "subtype": "success", "is_error": False, "result": "Not logged in · Please run /login"})
elif mode == "usage":
    init(); say("counted")
    done(total_cost_usd=0.0125, usage={"input_tokens": 100, "output_tokens": 40, "cache_read_input_tokens": 1000, "cache_creation_input_tokens": 10})
elif mode == "oc-overloaded":
    if is_opencode:
        out({"type": "error", "error": {"name": "APIError", "data": {"message": "529 Overloaded: the provider is overloaded"}}}); sys.exit(1)
    init(); say("stand-in answered on " + model); done()
elif mode == "mcp":
    # Uses the MCP server Theo gave this turn, the way an engine would: Claude Code's from --mcp-config (only the tools its
    # permission rules allow, as with dontAsk), OpenCode's from OPENCODE_CONFIG_CONTENT, the other agents' as
    # shared_hub_server reads them. `fake-mcp-calls.json` lists the calls to make ([{"tool": "<app>__<tool>", "args": {...}}]);
    # the reply and the call log carry what came back.
    if agent in ("claude", "opencode"):
        init()
    server = None
    config_file = arg_after("--mcp-config")
    if config_file:
        with open(config_file, encoding="utf-8") as f:
            server = json.load(f).get("mcpServers", {}).get("theo")
        if server:
            server = {"command": [server["command"]] + server.get("args", []), "env": server.get("env", {})}
    elif agent in ("codex", "cursor", "gemini", "grok"):
        server, may_run_unasked = shared_hub_server()
    elif os.environ.get("OPENCODE_CONFIG_CONTENT"):
        found = json.loads(os.environ["OPENCODE_CONFIG_CONTENT"]).get("mcp", {}).get("theo")
        if found:
            server = {"command": found["command"], "env": found.get("environment", {})}
    try:
        calls = json.loads(read("fake-mcp-calls.json", "[]"))
    except ValueError:
        calls = []
    report = {"server": bool(server), "tools": [], "results": {}}
    if server:
        env = dict(os.environ); env.update(server["env"])
        proc = subprocess.Popen(server["command"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, env=env, text=True, encoding="utf-8")
        counter = [0]
        def rpc(method, params=None):
            counter[0] += 1
            proc.stdin.write(json.dumps({"jsonrpc": "2.0", "id": counter[0], "method": method, "params": params or {}}) + "\n"); proc.stdin.flush()
            while True:
                line = proc.stdout.readline()
                if not line:
                    return {"error": {"message": "server closed"}}
                message = json.loads(line)
                if message.get("id") == counter[0]:
                    return message
        rpc("initialize", {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "fake-engine", "version": "1"}})
        proc.stdin.write(json.dumps({"jsonrpc": "2.0", "method": "notifications/initialized"}) + "\n"); proc.stdin.flush()
        listed = rpc("tools/list").get("result", {}).get("tools", [])
        report["tools"] = [t["name"] for t in listed]
        def allowed_by_rules(name):
            if agent in ("codex", "cursor", "gemini", "grok"):
                return may_run_unasked(name)
            if is_opencode:
                return True
            rule = "mcp__theo__" + name
            if any(d in (rule, "mcp__theo") for d in denied):
                return False
            return any(a in (rule, "mcp__theo") for a in allowed)
        for call in calls:
            name = call["tool"]
            if not allowed_by_rules(name):
                report["results"][name] = "not allowed by the engine's rules"
                continue
            answer = rpc("tools/call", {"name": name, "arguments": call.get("args", {})})
            if "error" in answer:
                report["results"][name] = "error: " + str(answer["error"].get("message"))
            else:
                result = answer.get("result", {})
                text = " ".join(c.get("text", "") for c in result.get("content", []))
                report["results"][name] = ("refused: " if result.get("isError") else "") + text
        proc.stdin.close(); proc.wait(10)
    log({"mcp": report})
    if agent in ("codex", "cursor", "gemini", "grok"):
        agent_answer("MCP " + json.dumps(report, sort_keys=True))
    elif is_opencode:
        out({"type": "text", "part": {"text": "MCP " + json.dumps(report, sort_keys=True)}})
    else:
        say("MCP " + json.dumps(report, sort_keys=True)); done()
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
