#!/usr/bin/env python3
"""The stranger test (theo-fix-plan package 11) for Windows and Linux: Theo as someone who has never seen it would meet it.

A clean profile: its own data folder, its own home folder, and a PATH with no Claude Code or OpenCode on it, so nothing of
the developer's machine (sign-ins, ~/.claude, ~/Projects, the name "Addy") can leak in. Then:

  1. First run finishes with only an API key, and Theo answers on it (a stand-in OpenAI-style server plays the provider).
  2. The owner's name typed in setup is in a bot's prompt, and "Addy" is nowhere: not in a prompt, not in a file Theo wrote.
  3. Add the echo app in Connectors, give it to a bot, and the bot uses it in a turn.
  4. Make a project folder in a non-default place and start a coding run there with a stand-in harness.
  (5. Two linked machines firing a routine once is Mac only: Theo Link isn't in the Windows and Linux app.)

  python3 tests/stranger.py            run it; the verdicts are also written to tests/results-stranger/stranger.json
"""
import json, os, pathlib, shutil, subprocess, sys, time

HERE = pathlib.Path(__file__).resolve().parent
# A root of its own, so it never shares a data folder with suite.py.
os.environ.setdefault("THEO_TEST_ROOT", str(HERE / "work-stranger"))

import lib as T  # noqa: E402
from lib import P  # noqa: E402

OWNER = "Priya"
STEPS = {}


def step(number, title):
    def wrap(fn):
        STEPS[number] = (title, fn)
        return fn
    return wrap


def clean_environment():
    """A home folder of its own and a PATH without any coding agent, the way a stranger's computer starts."""
    home = T.ROOT / "home"
    home.mkdir(parents=True, exist_ok=True)
    os.environ["HOME"] = str(home)
    if T.WIN:
        os.environ["USERPROFILE"] = str(home)
        os.environ["APPDATA"] = str(home / "AppData" / "Roaming")
        os.environ["LOCALAPPDATA"] = str(home / "AppData" / "Local")
    agents = ["claude", "opencode", "codex", "cursor-agent", "gemini", "grok"]
    suffixes = [".exe", ".cmd", ".bat", ".ps1", ""] if T.WIN else [""]
    kept = []
    for folder in os.environ.get("PATH", "").split(os.pathsep):
        if folder and not any(pathlib.Path(folder, agent + suffix).exists() for agent in agents for suffix in suffixes):
            kept.append(folder)
    os.environ["PATH"] = os.pathsep.join(kept)
    still_found = [agent for agent in agents if shutil.which(agent)]
    return {"home": str(home), "agents_on_path": still_found}


def engine_calls_since(mark):
    return T.calls(mark)


def every_text_theo_wrote():
    """Everything in the data folder that's text: settings, bots, chats, memory, the hub's list."""
    out = []
    for path in T.DATA.rglob("*"):
        if path.is_file() and path.suffix in (".json", ".md", ".txt", ".log", ".jsonl", ""):
            try:
                out.append((str(path.relative_to(T.DATA)), path.read_text(encoding="utf-8", errors="replace")))
            except OSError:
                pass
    return out


# ---------------------------------------------------------------- 1. First run on an API key only

@step(1, "First run finishes with only an API key, and Theo answers on it")
def first_run_on_an_api_key():
    before = P({"cmd": "setupState"}, timeout=90).get("result", {})
    api = before.get("apiKeys") or before.get("brains")
    if api is None:
        return None, {"skipped": "This build's setup has no API-key brain yet (theo-fix-plan package 10 adds it).",
                      "setup_said": {k: before.get(k) for k in ("claude", "completed")}}
    return False, {"todo": "package 10's API-key setup is in this build, but this step doesn't drive it yet", "setup_said": before}


# ---------------------------------------------------------------- 2. The owner's own name

@step(2, "The owner's name from setup is in a bot's prompt, and \"Addy\" is nowhere")
def owner_name_everywhere():
    state = P({"cmd": "setupState"}, timeout=90).get("result", {})
    name_before = state.get("ownerName", "")
    T.setd("test.engine.opencode", str(T.FAKE))
    T.fake("ok")
    bot = P({"cmd": "botCreate", "name": "Helper", "instructions": "You are Helper.", "provider": "opencode", "model": "opencode/fake"})["result"]["id"]
    mark = T.calls_mark()
    T.say(bot, "Hello before I gave my name.")
    T.wait_idle()
    unnamed = [c for c in engine_calls_since(mark) if "You are Helper" in (c["system"] + c["prompt"])]
    # What setup's "Your name" field saves (app.js saveOwnerName).
    P({"cmd": "setSetting", "key": "owner.name", "value": OWNER})
    mark = T.calls_mark()
    T.say(bot, "Hello again.")
    T.wait_idle()
    named = [c for c in engine_calls_since(mark) if "You are Helper" in (c["system"] + c["prompt"])]
    theo = next((b for b in T.state().get("bots", []) if b.get("primary")), {})
    mark = T.calls_mark()
    if theo:
        T.say(theo["id"], "Hi Theo.")
        T.wait_idle()
    theo_calls = engine_calls_since(mark)
    prompts = [c["system"] + "\n" + c["prompt"] for c in unnamed + named + theo_calls]
    files_with_addy = [path for path, text in every_text_theo_wrote() if "Addy" in text]
    checks = {
        "no_name_until_given": not name_before,
        "unnamed_prompt_says_the_owner": bool(unnamed) and "the owner" in (unnamed[-1]["system"] + unnamed[-1]["prompt"]).lower(),
        "named_prompt_has_the_name": bool(named) and OWNER in (named[-1]["system"] + named[-1]["prompt"]),
        "saved": P({"cmd": "setupState"}, timeout=90).get("result", {}).get("ownerName") == OWNER,
        "addy_in_no_prompt": bool(prompts) and not any("Addy" in p for p in prompts),
        "addy_in_no_file": not files_with_addy,
    }
    P({"cmd": "botDelete", "id": bot})
    return all(checks.values()), dict(checks, files_with_addy=files_with_addy[:10], theo_turns=len(theo_calls))


# ---------------------------------------------------------------- 3. The echo app, with no Claude Code

ECHO_APP = {"id": "echo", "name": "Echo", "kind": "local", "command": str(HERE / "echo_mcp.py")}


def hub_apps(refresh=False):
    r = P({"cmd": "connectors", "refresh": refresh}, timeout=200)
    return r.get("result", {}) or {}


@step(3, "Add the echo app in Connectors, give it to a bot, and the bot uses it")
def echo_app_in_a_turn():
    page_before = hub_apps(refresh=True)
    added = P({"cmd": "connectorAdd", "app": ECHO_APP}, timeout=120)
    page = hub_apps(refresh=True)
    echo = next((a for a in page.get("connectors", []) if a["id"] == "echo"), {})
    bot = P({"cmd": "botCreate", "name": "Ocho", "instructions": "You are Ocho.", "provider": "opencode", "model": "opencode/fake"})["result"]["id"]
    given = P({"cmd": "botApp", "bot": bot, "app": "echo", "level": "readAndDraft"})
    (T.FAKE_DIR / "fake-mcp-calls.json").write_text(json.dumps([{"tool": "echo__echo", "args": {"text": "hello stranger"}}]), encoding="utf-8")
    T.fake("mcp")
    mark = T.calls_mark()
    T.say(bot, "Say hello through Echo.")
    T.wait_idle()
    used = [c for c in engine_calls_since(mark) if "mcp" in c and "You are Ocho" in (c["system"] + c["prompt"])]
    report = used[-1]["mcp"] if used else {}
    reply = next((m["text"] for m in reversed(T.chat(bot, 10)) if m["author"] == bot), "")
    T.fake("ok")
    checks = {
        "page_works_without_claude_code": page_before.get("claudeCode") is False and "connectors" in page_before,
        "added": added.get("ok") is True,
        "listed_connected": echo.get("status") == "connected",
        "given_to_the_bot": given.get("ok") is True,
        "tool_offered": "echo__echo" in report.get("tools", []),
        "tool_ran": report.get("results", {}).get("echo__echo") == "echo: hello stranger",
        "reply_has_it": "echo: hello stranger" in reply,
    }
    P({"cmd": "botDelete", "id": bot})
    return all(checks.values()), dict(checks, report=report)


# ---------------------------------------------------------------- 4. A coding run in a folder of the owner's choosing

def git(folder, *args):
    return subprocess.run(["git", *args], cwd=folder, capture_output=True, text=True)


@step(4, "A project folder in a non-default place, and a coding run there with a stand-in harness")
def coding_run_elsewhere():
    # Windows and Linux coding runs only run on Claude Code today (coding.rs): the stand-in plays it.
    T.setd("test.engine.claude", str(T.FAKE))
    T.setd("test.engine.gh", str(T.FAKE_GH))
    T.fake("ok")
    elsewhere = T.ROOT / "Work Stuff" / "side projects"
    new_project = elsewhere / "garden-planner"
    elsewhere.mkdir(parents=True, exist_ok=True)
    mark = T.calls_mark()
    started = P({"cmd": "runStart", "prompt": "Make a README in the current folder.", "title": "Garden planner", "folder": str(new_project)})
    run_id = started.get("result", {}).get("id")

    def finished():
        runs = T.state().get("runs", [])
        run = next((r for r in runs if r.get("id") == run_id), None)
        return run if run and run.get("phase") != "running" else None
    run = T.wait_until(finished, 120) or {}
    coding_calls = [c for c in engine_calls_since(mark) if c.get("coding")]
    # The same in an existing repo there: its own branch and worktree, cut from that repo.
    repo = elsewhere / "existing-repo"
    repo.mkdir(exist_ok=True)
    git(repo, "init", "-q")
    git(repo, "-c", "user.email=s@example.com", "-c", "user.name=S", "commit", "-q", "--allow-empty", "-m", "start")
    mark = T.calls_mark()
    started_repo = P({"cmd": "runStart", "prompt": "Add a line to the README in the current folder.", "title": "Repo change", "folder": str(repo)})
    repo_run_id = started_repo.get("result", {}).get("id")
    repo_run = T.wait_until(lambda: next((r for r in T.state().get("runs", []) if r.get("id") == repo_run_id and r.get("phase") != "running"), None), 120) or {}
    worktrees = git(repo, "worktree", "list").stdout
    repo_calls = [c for c in engine_calls_since(mark) if c.get("coding")]
    same = lambda a, b: os.path.normcase(os.path.realpath(a)) == os.path.normcase(os.path.realpath(b))
    checks = {
        "new_folder_made_where_asked": new_project.is_dir(),
        "run_folder_is_it": bool(run.get("folder")) and same(run["folder"], new_project),
        "harness_ran_there": bool(coding_calls) and same(coding_calls[-1]["cwd"], new_project),
        "run_finished": run.get("phase") in ("done", "finished", "ready"),
        "repo_run_has_its_worktree": bool(repo_calls) and any(same(line.split()[0], repo_calls[-1]["cwd"]) for line in worktrees.splitlines() if line.strip()),
        "repo_run_finished": repo_run.get("phase") in ("done", "finished", "ready"),
        "nothing_in_a_projects_folder_in_home": not (T.ROOT / "home" / "Projects").exists(),
    }
    T.setd("test.engine.claude", str(T.ROOT / "no-claude-code-here"))
    return all(checks.values()), dict(checks, run=run, repo_run_phase=repo_run.get("phase"), worktrees=worktrees)


# ---------------------------------------------------------------- 5. Two machines

@step(5, "Two linked machines fire a routine exactly once")
def two_machines():
    return None, {"skipped": "Mac only: Theo Link (two linked computers) isn't part of the Windows and Linux app."}


def main():
    environment = clean_environment()
    T.fresh()
    T.start()
    # No Claude Code anywhere: the engine override points at nothing, as on a computer that never had it.
    T.setd("test.engine.claude", str(T.ROOT / "no-claude-code-here"))
    T.setd("test.engine.opencode", str(T.FAKE))
    results = {}
    try:
        for number, (title, fn) in STEPS.items():
            print("\n=== %d. %s ===" % (number, title), flush=True)
            t0 = time.time()
            try:
                ok, evidence = fn()
                verdict = "SKIP" if ok is None else ("PASS" if ok else "FAIL")
            except Exception:
                import traceback
                verdict, evidence = "ERROR", {"exception": traceback.format_exc()}
            results[number] = {"step": number, "title": title, "verdict": verdict, "seconds": round(time.time() - t0, 1), "evidence": evidence}
            print("--> %s" % verdict, flush=True)
            print(json.dumps(evidence, default=str)[:1500], flush=True)
    finally:
        T.stop()
    out = HERE / "results-stranger"
    out.mkdir(exist_ok=True)
    summary = {"os": sys.platform, "environment": environment, "steps": results}
    (out / "stranger.json").write_text(json.dumps(summary, indent=1, default=str), encoding="utf-8")
    print("\nstep  result  title")
    for number, r in results.items():
        print("%-5d %-7s %s" % (number, r["verdict"], r["title"]))
    failed = [n for n, r in results.items() if r["verdict"] in ("FAIL", "ERROR")]
    print("\n%s on %s" % ("All steps that can run here passed" if not failed else "Failed: %s" % failed, sys.platform))
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
