#!/usr/bin/env python3
"""The stranger test (theo-fix-plan package 11) for the Mac: Theo as someone who has never seen it would meet it.

Runs a built Theo in two fresh test profiles (`--profile test-stranger`, `test-stranger-b`), each with its own home folder
and preferences, nothing borrowed from a developer's Mac, and every coding agent counted as missing. A stand-in
OpenAI-compatible server plays the one API key the stranger has. Then:

  1. First run finishes with only an API key: Setup's last step, Theo moves onto the key, and Theo answers on it.
  2. The owner's name typed in setup is in every bot's prompt, and "Addy" is in no prompt and no file Theo wrote.
  3. The echo app is added to Theo's own connector hub, given to Theo, and Theo (on the API key) uses it in a turn.
  4. The projects folder is set to a non-default place, and a coding run starts there with a stand-in harness.
  5. Two profiles that are both laptops are linked, and exactly one of them is the Mac that fires routines.

  python3 Tools/tests/stranger_mac.py --app /path/to/Theo.app [--helper /path/to/theo-connectors] [--out folder]

Never run it against the owner's own profile: it deletes and recreates only the two test-stranger profiles. It moves no
pointer, takes no focus and opens no browser (see docs/TESTING.md).
"""
import argparse, json, os, pathlib, shutil, signal, subprocess, sys, time, uuid

HERE = pathlib.Path(__file__).resolve().parent
REPO = HERE.parent.parent
REAL_HOME = pathlib.Path(os.path.expanduser("~"))
OWNER = "Priya"
PROVIDER_ID = "custom-stand-in"
AGENTS = ["claude", "codex", "cursor", "opencode", "gemini", "grok", "t3"]


def why_it_exited_at_launch(instance_log_file):
    """The end of the instance's own log and the newest crash report macOS wrote for it, as text for the test's output."""
    lines = ["--- last lines of %s ---" % instance_log_file]
    try:
        lines += instance_log_file.read_text(errors="replace").splitlines()[-60:]
    except OSError as error:
        lines.append("(couldn't read it: %s)" % error)
    crash_reports_folder = REAL_HOME / "Library/Logs/DiagnosticReports"
    newest_crash_report = None
    # macOS takes a few seconds to write the report after the process is gone.
    for _ in range(40):
        recent_reports = [report for report in crash_reports_folder.glob("Clicky*.ips") if time.time() - report.stat().st_mtime < 120]
        if recent_reports:
            newest_crash_report = max(recent_reports, key=lambda report: report.stat().st_mtime)
            break
        time.sleep(0.5)
    if newest_crash_report is None:
        lines.append("--- no crash report for Clicky in %s ---" % crash_reports_folder)
        return "\n".join(lines)
    lines.append("--- crash report %s ---" % newest_crash_report.name)
    try:
        # An .ips file is one line of JSON (a header), then the report itself as JSON.
        report = json.loads(newest_crash_report.read_text(errors="replace").split("\n", 1)[1])
        lines.append("exception: %s" % json.dumps(report.get("exception")))
        lines.append("termination: %s" % json.dumps(report.get("termination")))
        for name in ("asi", "lastExceptionBacktrace"):
            if report.get(name):
                lines.append("%s: %s" % (name, json.dumps(report[name])[:3000]))
        images = report.get("usedImages", [])
        crashed_thread = next((thread for thread in report.get("threads", []) if thread.get("triggered")), None)
        for frame in (crashed_thread or {}).get("frames", [])[:30]:
            image_name = images[frame["imageIndex"]].get("name", "?") if frame.get("imageIndex", -1) < len(images) else "?"
            lines.append("  %s  %s + %s" % (image_name, frame.get("symbol", "?"), frame.get("symbolLocation", "?")))
    except (OSError, ValueError, IndexError, KeyError) as error:
        lines.append("(couldn't read the report: %s)" % error)
    return "\n".join(lines)


class Profile:
    """One test profile of Theo: its own home folder, preferences domain and control inbox."""

    def __init__(self, suffix):
        self.argument = "test-" + suffix
        self.root = REAL_HOME / ("Library/Application Support/Theo-Test-" + suffix)
        self.home = self.root / "home"
        self.domain = "com.personal.clicky." + self.argument
        self.process = None

    # ---- life

    def pids(self):
        listing = subprocess.run(["ps", "-axww", "-o", "pid=,args="], capture_output=True, text=True).stdout
        found = []
        for line in listing.splitlines():
            parts = line.strip().split(None, 1)
            if len(parts) == 2 and parts[0].isdigit() and int(parts[0]) != os.getpid():
                words = parts[1].split()
                if any(words[i] == "--profile" and words[i + 1] == self.argument for i in range(len(words) - 1)):
                    found.append(int(parts[0]))
        return found

    def stop(self):
        for pid in self.pids():
            try:
                os.kill(pid, signal.SIGTERM)
            except OSError:
                pass
        deadline = time.time() + 15
        while time.time() < deadline and self.pids():
            time.sleep(0.25)
        for pid in self.pids():
            try:
                os.kill(pid, signal.SIGKILL)
            except OSError:
                pass

    def wipe(self):
        """A stranger's first launch: no folder, no preferences, no keys of this profile's."""
        self.stop()
        shutil.rmtree(self.root, ignore_errors=True)
        subprocess.run(["defaults", "delete", self.domain], capture_output=True)
        subprocess.run(["security", "delete-generic-password", "-s", "com.theo.providers." + self.argument], capture_output=True)

    def write_default(self, key, kind, *values):
        subprocess.run(["defaults", "write", self.domain, key, kind, *values], check=True)

    def read_default(self, key):
        return subprocess.run(["defaults", "read", self.domain, key], capture_output=True, text=True).stdout.strip()

    def start(self, binary):
        self.root.mkdir(parents=True, exist_ok=True)
        log = open(self.root / "test-instance.log", "ab")
        self.process = subprocess.Popen([binary, "--profile", self.argument], stdout=log, stderr=log, stdin=subprocess.DEVNULL,
                                        cwd=str(REAL_HOME), start_new_session=True)
        for _ in range(300):
            time.sleep(0.2)
            if self.send({"cmd": "uiState"}, timeout=1).get("ok"):
                return True
            if self.process.poll() is not None:
                # Say why here: on a build machine the log file is gone with the machine.
                print(why_it_exited_at_launch(self.root / "test-instance.log"), flush=True)
                raise SystemExit("%s exited at launch (%s). See %s" % (self.argument, self.process.returncode, self.root / "test-instance.log"))
        raise SystemExit("%s didn't answer in 60 s." % self.argument)

    # ---- talking to it

    def send(self, obj, timeout=60):
        inbox, outbox = self.home / ".clicky/control-inbox", self.home / ".clicky/control-outbox"
        inbox.mkdir(parents=True, exist_ok=True)
        outbox.mkdir(parents=True, exist_ok=True)
        ident = uuid.uuid4().hex
        tmp = inbox / (ident + ".tmp")
        tmp.write_text(json.dumps(obj))
        tmp.rename(inbox / (ident + ".json"))
        reply = outbox / (ident + ".json")
        deadline = time.time() + timeout
        while time.time() < deadline:
            if reply.exists():
                try:
                    text = reply.read_text()
                    reply.unlink()
                    return json.loads(text)
                except (OSError, ValueError):
                    pass
            time.sleep(0.05)
        return {"ok": False, "error": "timeout"}

    def result(self, obj, timeout=60):
        return self.send(obj, timeout).get("result") or {}

    def bots(self):
        state = self.result({"cmd": "botsState"})
        return state.get("bots", []) if isinstance(state, dict) else []

    def chat(self, bot, limit=30):
        answer = self.result({"cmd": "botChat", "id": bot, "limit": limit})
        return answer if isinstance(answer, list) else answer.get("messages", [])

    def wait_for_reply(self, bot, after_count, seconds=120):
        deadline = time.time() + seconds
        while time.time() < deadline:
            messages = self.chat(bot, 60)
            fresh = messages[after_count:] if len(messages) > after_count else []
            replies = [m for m in fresh if m.get("author") == bot and (m.get("text") or "").strip()]
            busy = self.result({"cmd": "botsState"}).get("replying") if replies else True
            if replies and not busy:
                return replies[-1].get("text", "")
            time.sleep(0.5)
        return ""

    def text_files(self):
        """Every text file Theo wrote in this profile's home, except the folders a test puts there itself."""
        out = []
        for path in self.home.rglob("*"):
            if path.is_symlink() or not path.is_file() or "fake-bin" in path.parts or path.stat().st_size > 2_000_000:
                continue
            if path.suffix in (".json", ".md", ".txt", ".log", ".jsonl", ".plist", ""):
                try:
                    out.append((str(path.relative_to(self.home)), path.read_text(encoding="utf-8", errors="replace")))
                except OSError:
                    pass
        return out


# ---------------------------------------------------------------- the stand-ins

def start_stand_in_provider(record):
    server = subprocess.Popen([sys.executable, str(HERE / "stand_in_openai.py"), str(record)], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
    return server, int(server.stdout.readline().strip())


def stand_in_requests(record):
    return [json.loads(p.read_text())["body"] for p in sorted(record.glob("*.json"))]


def custom_provider_data(port):
    """What Settings › Models & API keys › Custom saves (`CustomProviders.all`): a name and base address, key in the Keychain."""
    provider = {"id": PROVIDER_ID, "label": "Stand-in", "blurb": "http://127.0.0.1:%d/v1" % port, "group": "custom", "kind": "openAICompatible",
                "baseURL": "http://127.0.0.1:%d/v1" % port, "consoleURL": None, "keyHint": "Leave empty if it needs no key", "keyless": False,
                "modelsPath": "/models", "knownModels": ["stand-in-model"], "testPath": None}
    return json.dumps([provider]).encode().hex()


FAKE_CODEX = """#!/bin/sh
# A stand-in Codex for the stranger test: says it's signed in, and a run records where it ran.
case "$1" in
  --version) echo "codex-cli 0.0.0-stand-in"; exit 0 ;;
  login) echo "Logged in using an API key"; exit 0 ;;
esac
printf '{"cwd": "%s", "args": "%s"}' "$PWD" "$*" > "$PWD/stand-in-codex-ran.json"
echo "# Made by the stand-in harness" > "$PWD/README.md"
echo "Done."
exit 0
"""


def system_text(body):
    return "\n".join(m.get("content") if isinstance(m.get("content"), str) else json.dumps(m.get("content"))
                     for m in body.get("messages", []) if m.get("role") == "system")


def all_text(body):
    return json.dumps(body.get("messages", []))


# ---------------------------------------------------------------- the steps

def step_first_run(theo, record):
    keyed = theo.result({"cmd": "uiTestKey", "provider": PROVIDER_ID, "value": "sk-stranger-not-a-real-key"})
    # What typing a name on Setup's Welcome step saves (SetupGuideWindow's name field: ClickySettings.ownerName).
    theo.send({"cmd": "uiSet", "key": "v4.owner.name", "value": OWNER})
    theo.result({"cmd": "uiPixel", "action": "products", "on": {"theo": True, "clicky": False, "dictation": False}})
    opened = theo.result({"cmd": "uiPixel", "action": "setup", "step": "done"})
    pressed = theo.send({"cmd": "uiPress", "label": "Open Theo", "window": opened.get("window")})
    if not pressed.get("ok"):
        # SwiftUI can leave the in-process accessibility tree empty (no accessibility client has asked yet), so the label
        # isn't found. Return presses the same button: "Open Theo" is the step's default action.
        pressed = dict(theo.send({"cmd": "uiKey", "key": "return", "window": opened.get("window")}), by="return")
    deadline = time.time() + 20
    while time.time() < deadline and theo.read_default("v2.setup.completed") != "1":
        time.sleep(0.5)
    theo_bot = next((b for b in theo.bots() if b.get("id") == "theo"), {})
    before = len(theo.chat("theo", 60))
    asked = len(stand_in_requests(record))
    theo.send({"cmd": "botSay", "bot": "theo", "text": "Hello Theo, are you there?"})
    reply = theo.wait_for_reply("theo", before)
    requests = stand_in_requests(record)[asked:]
    checks = {
        "key_saved": keyed.get("hasKey") is True,
        "setup_finished": theo.read_default("v2.setup.completed") == "1",
        "theo_moved_onto_the_key": PROVIDER_ID in json.dumps({k: theo_bot.get(k) for k in ("provider", "model")}),
        "the_key_was_used": bool(requests),
        "theo_answered": "Stand-in here" in reply,
        "no_claude_code_words": "claude" not in reply.lower(),
    }
    return all(checks.values()), dict(checks, pressed=pressed.get("by", "label") if pressed.get("ok") else False, theo={k: theo_bot.get(k) for k in ("provider", "model")}, reply=reply[:300])


def step_owner_name(theo, record):
    prompts = {}
    for bot in theo.bots():
        told = theo.result({"cmd": "uiBotPrompt", "bot": bot["id"]})
        prompts[bot["id"]] = json.dumps(told)
    sent = [system_text(body) + all_text(body) for body in stand_in_requests(record)]
    files_with_addy = [path for path, text in theo.text_files() if "Addy" in text]
    theo_prompt = prompts.get("theo", "")
    checks = {
        "theo_is_told_the_name": OWNER in theo_prompt,
        "addy_in_no_bot_prompt": bool(prompts) and not any("Addy" in p for p in prompts.values()),
        "name_reached_the_model": any(OWNER in s for s in sent),
        "addy_never_sent_to_the_model": bool(sent) and not any("Addy" in s for s in sent),
        "addy_in_no_file": not files_with_addy,
    }
    return all(checks.values()), dict(checks, bots=list(prompts), files_with_addy=files_with_addy[:10])


def step_echo_app(theo, record, helper):
    if not helper:
        return None, {"skipped": "No theo-connectors helper was given or found in the app, so there's no hub to add an app to."}
    data = theo.home / "Library/Application Support/Theo"
    echo = {"id": "echo", "name": "Echo", "kind": "local", "command": str(REPO / "crossplatform/tests/echo_mcp.py")}
    added = subprocess.run([helper, "--data", str(data), "--key-store", "file", "add", "--json", json.dumps(echo)], capture_output=True, text=True)
    listed = subprocess.run([helper, "--data", str(data), "--key-store", "file", "check", "echo"], capture_output=True, text=True)
    given = theo.send({"cmd": "botUpdate", "id": "theo", "apps": ["echo"]})
    before = len(theo.chat("theo", 60))
    asked = len(stand_in_requests(record))
    theo.send({"cmd": "botSay", "bot": "theo", "text": "Say hello through Echo."})
    reply = theo.wait_for_reply("theo", before)
    requests = stand_in_requests(record)[asked:]
    offered = any("echo__echo" in json.dumps(body.get("tools") or []) for body in requests)
    answered = any("echo: hello stranger" in all_text(body) for body in requests)
    checks = {
        "added_to_the_hub": added.returncode == 0,
        "given_to_theo": given.get("ok") is True,
        "tool_offered_to_the_model": offered,
        "tool_ran_through_the_hub": answered,
        "reply_has_it": "echo: hello stranger" in reply,
    }
    theo.send({"cmd": "botUpdate", "id": "theo", "apps": []})
    return all(checks.values()), dict(checks, hub_add=added.stdout[-300:] + added.stderr[-300:], hub_check=listed.stdout[-300:], reply=reply[:300])


def step_coding_run(theo):
    fake_bin = theo.home / "fake-bin"
    fake_bin.mkdir(parents=True, exist_ok=True)
    codex = fake_bin / "codex"
    codex.write_text(FAKE_CODEX)
    codex.chmod(0o755)
    elsewhere = theo.root / "Work Stuff" / "side projects"
    elsewhere.mkdir(parents=True, exist_ok=True)
    theo.send({"cmd": "uiSet", "key": "v2.code.projectsFolder", "value": str(elsewhere)})
    # Codex stops counting as missing for this step: it's the stand-in harness.
    theo.send({"cmd": "uiSetDefaults", "key": "test.engines.missing", "value": [a for a in AGENTS if a != "codex"]})
    harnesses = theo.result({"cmd": "harnessState", "refresh": True}, timeout=120)
    started = theo.result({"cmd": "uiRunStart", "prompt": "Make a README in the current folder.", "title": "Garden planner",
                           "harness": "codex", "await": True}, timeout=120)
    marker = None
    deadline = time.time() + 90
    while time.time() < deadline and not marker:
        marker = next(iter(elsewhere.rglob("stand-in-codex-ran.json")), None)
        time.sleep(0.5)
    ran = json.loads(marker.read_text()) if marker else {}
    default_projects = theo.home / "Projects"
    checks = {
        "run_started": started.get("didStart") is True,
        "harness_ran": bool(marker),
        "ran_inside_the_chosen_folder": bool(ran) and pathlib.Path(ran["cwd"]).resolve().is_relative_to(elsewhere.resolve()),
        "nothing_made_in_the_default_projects_folder": not default_projects.exists() or not any(default_projects.iterdir()),
    }
    return all(checks.values()), dict(checks, started=started, ran=ran, codex=next((h for h in harnesses.get("harnesses") or [] if h.get("id") == "codex"), None))


def step_two_laptops(binary):
    first, second = Profile("stranger-a"), Profile("stranger-b")
    for profile, name in ((first, "Sam’s MacBook Pro"), (second, "Sam’s MacBook Air")):
        profile.wipe()
        profile.write_default("test.link.name", "-string", name)
        profile.write_default("test.devices.isDesktop", "-bool", "false")
        profile.write_default("v2.setup.completed", "-bool", "true")
        profile.write_default("v3.bots.freshStart", "-bool", "true")
        profile.start(binary)
    try:
        code = first.result({"cmd": "uiLink", "action": "start", "port": 47431}).get("code")
        second.result({"cmd": "uiLink", "action": "start", "code": code, "port": 47432, "dialHost": "127.0.0.1", "dialPort": 47431})
        states = {}
        deadline = time.time() + 60
        while time.time() < deadline:
            states = {p.argument: p.result({"cmd": "uiLink", "action": "state"}) for p in (first, second)}
            if all(s.get("otherMac") for s in states.values()):
                break
            time.sleep(1)
        routes = {name: s.get("routinesRoute") for name, s in states.items()}
        firing = [name for name, route in routes.items() if route == "runHere"]
        checks = {"linked": all(s.get("otherMac") for s in states.values()), "both_laptops": all(s.get("thisMac", {}).get("isDesktop") is False for s in states.values()),
                  "exactly_one_fires_routines": len(firing) == 1}
        return all(checks.values()), dict(checks, routes=routes, names={n: s.get("thisMac", {}).get("name") for n, s in states.items()})
    finally:
        first.stop()
        second.stop()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", required=True, help="Theo.app (or its Contents/MacOS/Clicky)")
    parser.add_argument("--helper", default="", help="theo-connectors; default: the one inside the app")
    parser.add_argument("--out", default=str(REPO / "build/stranger-mac"))
    options = parser.parse_args()
    app = pathlib.Path(options.app)
    if app.suffix == ".app":
        executables = [p for p in (app / "Contents/MacOS").iterdir() if p.is_file() and os.access(p, os.X_OK)]
        binary = str(app / "Contents/MacOS/Clicky") if (app / "Contents/MacOS/Clicky").exists() else str(executables[0])
    else:
        binary = str(app)
    bundled = (app if app.suffix == ".app" else app.parent.parent.parent) / "Contents/Helpers/theo-connectors"
    helper = options.helper or (str(bundled) if bundled.exists() else "")
    out = pathlib.Path(options.out)
    out.mkdir(parents=True, exist_ok=True)
    record = out / "stand-in-requests"
    shutil.rmtree(record, ignore_errors=True)
    server, port = start_stand_in_provider(record)

    theo = Profile("stranger")
    theo.wipe()
    theo.write_default("test.engines.missing", "-array", *AGENTS)
    theo.write_default("theo.providers.custom", "-data", custom_provider_data(port))
    if helper:
        theo.write_default("test.connectors.helper", "-string", helper)
    results = {}
    try:
        theo.start(binary)
        steps = [(1, "First run finishes with only an API key", lambda: step_first_run(theo, record)),
                 (2, "The owner's name is in prompts, and \"Addy\" is nowhere", lambda: step_owner_name(theo, record)),
                 (3, "The echo app, given to a bot on the API key, is used", lambda: step_echo_app(theo, record, helper)),
                 (4, "A coding run in a non-default projects folder with a stand-in harness", lambda: step_coding_run(theo))]
        theo_steps_done = False
        for number, title, run in steps + [(5, "Two laptops linked: exactly one fires routines", lambda: step_two_laptops(binary))]:
            if number == 5 and not theo_steps_done:
                theo.stop()
                theo_steps_done = True
            print("\n=== %d. %s ===" % (number, title), flush=True)
            t0 = time.time()
            try:
                ok, evidence = run()
                verdict = "SKIP" if ok is None else ("PASS" if ok else "FAIL")
            except Exception:
                import traceback
                verdict, evidence = "ERROR", {"exception": traceback.format_exc()}
            results[number] = {"step": number, "title": title, "verdict": verdict, "seconds": round(time.time() - t0, 1), "evidence": evidence}
            print("--> %s" % verdict, flush=True)
            print(json.dumps(evidence, default=str, ensure_ascii=False)[:1500], flush=True)
    finally:
        theo.stop()
        server.kill()
    (out / "stranger-mac.json").write_text(json.dumps({"steps": results}, indent=1, default=str, ensure_ascii=False))
    print("\nstep  result  title")
    for number, r in results.items():
        print("%-5d %-7s %s" % (number, r["verdict"], r["title"]))
    failed = [n for n, r in results.items() if r["verdict"] in ("FAIL", "ERROR")]
    print("\n%s" % ("All steps passed" if not failed else "Failed: %s" % failed))
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
