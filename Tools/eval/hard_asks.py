#!/usr/bin/env python3
"""Hard end-to-end asks against the running Clicky (debug inbox), with
objective pass/fail checks. Each case sets up a real page or app, asks in
the owner's own words, and checks what Clicky actually did:

  research-google   Google results, "search these 3 links on my screen using haiku agents"
                    -> a links job, 3 helpers, the 3 links are organic results on screen
  research-hn       Hacker News, "summarize the top three results with helpers"
                    -> exactly the top 3 stories' links (checked against the live page)
  research-wiki     Wikipedia article, "spawn haiku agents and research the first 2 links in this article"
                    -> 2 helpers, links from the article body (not Wikipedia chrome)
  research-topic    "research the James Webb telescope for me" -> 3 search results, a brief
  workers           "compare ... one helper per phone" -> 3+ Haiku 5.5 workers in the turn
  board             "whiteboard how a TCP handshake works" -> a board with 2+ sections
  point             System Settings in front, "where is Bluetooth? point at it" -> a mark on Bluetooth
  search-action     "search google for weather in delhi" -> the action task finishes
  article           Wikipedia article, "highlight the important parts of this article" -> 3+ highlights
  silent            "silent mode" / "talk again" toggle the setting

Usage: python3 Tools/eval/hard_asks.py [--only research-hn,board]
Prints one line per case and a summary; exits 1 if any case failed.
"""

import argparse
import html
import json
import os
import re
import subprocess
import sys
import time
import urllib.request

REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
CLICKYCTL = os.path.join(REPO_ROOT, "Tools", "clickyctl.sh")
HELPER_MODEL = "claude-haiku-5-5"


def ctl(command, timeout_seconds=240):
    completed = subprocess.run([CLICKYCTL, json.dumps(command), str(timeout_seconds)], capture_output=True, text=True)
    try:
        return json.loads(completed.stdout.strip() or "{}")
    except ValueError:
        return {"ok": False, "error": completed.stdout[:200]}


def open_page(url, settle=6):
    subprocess.run(["open", "-a", "Google Chrome", url])
    time.sleep(settle)


def ask(text, fresh=True):
    # Each case starts a new conversation, so earlier answers don't change this one.
    if fresh:
        ctl({"cmd": "reset"}, 10)
    return ctl({"cmd": "ask", "text": text, "speak": False})


def turn_json(reply):
    turn_dir = reply.get("turnDir")
    if not turn_dir:
        return {}
    try:
        with open(os.path.join(turn_dir, "turn.json")) as turn_file:
            return json.load(turn_file)
    except (OSError, ValueError):
        return {}


def wait_research(timeout_seconds=300):
    """Waits for the research started by the last ask; urls come from "sources" once it's done."""
    time.sleep(3)
    deadline = time.time() + timeout_seconds
    status = {}
    while time.time() < deadline:
        status = ctl({"cmd": "researchStatus"}, 10).get("result") or {}
        if status.get("state") in ("done", "failed", "cancelled") or (status.get("state") == "idle" and not status.get("running")):
            break
        time.sleep(3)
    sources = status.get("sources") or []
    status["urls"] = [s.get("url") for s in sources] if sources else (status.get("urls") or [])
    return status


def host(url):
    match = re.match(r"https?://([^/]+)", url or "")
    return (match.group(1).lower().removeprefix("www.")) if match else ""


def fetch(url):
    request = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0 (Macintosh) ClickyEval"})
    with urllib.request.urlopen(request, timeout=20) as response:
        return response.read().decode("utf-8", "replace")


# ---------------------------------------------------------------- cases

def case_research_google():
    open_page("https://www.google.com/search?q=best+electric+cars+2026")
    reply = ask("search these 3 links on my screen using haiku agents")
    status = wait_research()
    urls = status.get("urls") or []
    hosts = [host(u) for u in urls]
    problems = []
    if len(urls) != 3:
        problems.append(f"{len(urls)} links instead of 3")
    if any("google." in h for h in hosts):
        problems.append("picked a Google link")
    if any(re.search(r"(accounts\.|support\.|policies\.|maps\.)", h) for h in hosts):
        problems.append("picked a utility link")
    if status.get("state") != "done":
        problems.append(f"research ended {status.get('state')}")
    return not problems, f"links={hosts} " + "; ".join(problems)


def case_research_named():
    """Names two of the sites that are on screen right now (Google's results change from day to day)."""
    open_page("https://www.google.com/search?q=best+electric+cars+2026")
    ask("research these 3 links on my screen with haiku agents")
    on_screen = [host(u) for u in wait_research().get("urls") or []]
    if len(on_screen) < 3:
        return False, f"couldn't find 3 results on screen: {on_screen}"
    named = [on_screen[0], on_screen[2]]
    spoken = [h.split(".")[0] for h in named]
    open_page("https://www.google.com/search?q=best+electric+cars+2026")
    ask(f"research the {spoken[0]} and {spoken[1]} links with two haiku agents")
    status = wait_research()
    hosts = sorted(host(u) for u in status.get("urls") or [])
    ok = hosts == sorted(named) and status.get("state") == "done"
    return ok, f"named={spoken} got={hosts} state={status.get('state')}"


def case_research_subagents():
    open_page("https://news.ycombinator.com/")
    ask("deploy sub agents on these links")
    status = wait_research()
    urls = status.get("urls") or []
    ok = len(urls) == 3 and not any("ycombinator.com" in host(u) and "item?id" not in u for u in urls) and status.get("state") == "done"
    return ok, f"got={[host(u) for u in urls]} state={status.get('state')}"


def case_research_hn():
    page = fetch("https://news.ycombinator.com/")
    expected = [html.unescape(m) for m in re.findall(r'<span class="titleline"><a href="([^"]+)"', page)[:3]]
    expected = [u if u.startswith("http") else "https://news.ycombinator.com/" + u for u in expected]
    open_page("https://news.ycombinator.com/")
    ask("summarize the top three results with helpers")
    status = wait_research()
    urls = status.get("urls") or []
    norm = lambda u: u.rstrip("/").lower()
    matched = [u for u in urls if norm(u) in {norm(e) for e in expected}]
    ok = len(urls) == 3 and len(matched) == 3 and status.get("state") == "done"
    return ok, f"expected={[host(e) for e in expected]} got={[host(u) for u in urls]} state={status.get('state')}"


def case_research_wiki():
    open_page("https://en.wikipedia.org/wiki/James_Webb_Space_Telescope")
    ask("spawn haiku agents and research the first 2 links in this article")
    status = wait_research()
    urls = status.get("urls") or []
    chrome = [u for u in urls if re.search(r"(Special:|Main_Page|wikimediafoundation|Help:|Wikipedia:|Portal:|donate|wikidata|commons\.wikimedia|#cite)", u)]
    ok = len(urls) == 2 and not chrome and status.get("state") == "done"
    return ok, f"got={urls} chrome={chrome} state={status.get('state')}"


def case_research_topic():
    ask("research the James Webb telescope for me")
    status = wait_research()
    ok = status.get("state") == "done" and len(status.get("urls") or []) >= 2 and len(status.get("brief") or "") > 200
    return ok, f"state={status.get('state')} links={[host(u) for u in status.get('urls') or []]}"


def case_workers():
    reply = ask("compare the battery life, camera and price of the iPhone 17, Pixel 10 and Galaxy S26, one helper per phone")
    turn = turn_json(reply)
    workers = turn.get("workers") or []
    models = {w.get("model") for w in workers if isinstance(w, dict)}
    ok = len(workers) >= 3
    return ok, f"workers={len(workers)} models={models or '?'}"


def board_state():
    return ctl({"cmd": "boardCtl", "action": "state"}, 20).get("result") or {}


def case_board():
    ask("whiteboard how a TCP handshake works")
    state = board_state()
    ctl({"cmd": "boardCtl", "action": "close"}, 10)
    ok = state.get("hasBoard") and len(state.get("sections") or []) >= 2 and not state.get("side")
    return bool(ok), f"title={state.get('title')} sections={state.get('sections')} side={state.get('side')}"


def case_side_board():
    """Not asked for a board: a complex concept gets the small side board with links; expand, deep research, ×."""
    ctl({"cmd": "boardCtl", "action": "close"}, 10)
    ctl({"cmd": "reset"}, 10)
    import random
    ask(random.choice(["how does a jet engine work?", "how does a nuclear reactor make electricity?",
                       "how does the heart pump blood around the body?", "how does a refrigerator keep things cold?"]))
    time.sleep(8)
    state = board_state()
    problems = []
    if not (state.get("open") and state.get("side")):
        problems.append(f"no side board (open={state.get('open')} side={state.get('side')})")
    panel, screen = state.get("panelFrame"), state.get("screenFrame")
    if panel and screen and not (panel[0] + panel[2] > screen[0] + screen[2] * 0.9 and panel[2] < screen[2] * 0.5):
        problems.append(f"not docked at the side: {panel}")
    if len(state.get("links") or []) < 2:
        problems.append(f"links={len(state.get('links') or [])}")
    ctl({"cmd": "boardCtl", "action": "deepResearch"}, 10)
    expanded = ctl({"cmd": "boardCtl", "action": "expand"}, 10).get("result") or {}
    if expanded.get("side"):
        problems.append("expand didn't grow it")
    research = wait_research()
    if research.get("state") != "done" or len(research.get("urls") or []) < 2:
        problems.append(f"deep research {research.get('state')} with {len(research.get('urls') or [])} links")
    closed = ctl({"cmd": "boardCtl", "action": "close"}, 10).get("result") or {}
    subprocess.run(["defaults", "delete", "com.personal.clicky", "v2.whiteboard.fullScreen"], capture_output=True)
    if closed.get("open"):
        problems.append("× didn't close it")
    return not problems, f"title={state.get('title')} links={len(state.get('links') or [])} " + "; ".join(problems)


def case_no_board_for_simple():
    ctl({"cmd": "boardCtl", "action": "close"}, 10)
    ask("what's 15 times 4?")
    state = board_state()
    return not state.get("open"), f"open={state.get('open')} title={state.get('title')}"


def case_point():
    subprocess.run(["open", "-a", "System Settings"])
    time.sleep(4)
    reply = ask("where is the Bluetooth setting? point at it")
    turn = turn_json(reply)
    tags = [t for t in turn.get("tags") or [] if t.get("kind") in ("mark", "point")]
    labels = " ".join(str(t.get("raw", "")) for t in tags).lower()
    ok = bool(tags) and "bluetooth" in labels
    methods = sorted({t.get("method") for t in tags})
    return ok, f"tags={len(tags)} methods={methods}"


def case_search_action():
    ask("search google for weather in delhi")
    last = {}
    for _ in range(15):
        time.sleep(2)
        last = (ctl({"cmd": "actionsStatus"}, 10).get("result") or {}).get("last") or {}
        if "weather" in (last.get("goal") or "") and last.get("status") in ("done", "failed", "cancelled"):
            break
    ok = last.get("status") == "done" and any("search" in step for step in last.get("steps") or [])
    return ok, f"status={last.get('status')} steps={last.get('steps')}"


def case_article():
    open_page("https://en.wikipedia.org/wiki/Four-stroke_engine")
    ask("highlight the important parts of this article")
    highlights = []
    for _ in range(20):
        time.sleep(3)
        notes = ctl({"cmd": "notesStatus"}, 10).get("result") or {}
        highlights = notes.get("highlights") or []
        if len(highlights) >= 3:
            break
    return len(highlights) >= 3, f"highlights={len(highlights)}"


def case_tabs():
    """Two searches in a row leave one Clicky tab: the first search's tab is closed when the second opens."""
    first, second = "weather in mumbai", "weather in chennai"
    ask(f"search google for {first}")
    time.sleep(10)
    ask(f"search google for {second}")
    time.sleep(10)
    status = ctl({"cmd": "tabsStatus"}, 10).get("result") or {}
    tabs = [t.lower() for t in status.get("chromeTabs") or []]
    first_open = any(first in t for t in tabs)
    second_open = any(second in t for t in tabs)
    ok = second_open and not first_open
    return ok, f"first open={first_open} second open={second_open} tracked={status.get('tracked')}"


def case_t3_mcp():
    """Claudia inside T3 Code: a Claude Code agent (as T3 runs it) uses the claudia MCP tools to see and mark the screen."""
    import glob, tempfile
    app = sorted(glob.glob(os.path.expanduser("~/Library/Developer/Xcode/DerivedData/leanring-buddy-*/Build/Products/Debug/Clicky.app")))[0]
    config = tempfile.NamedTemporaryFile("w", suffix=".json", delete=False)
    json.dump({"mcpServers": {"claudia": {"command": app + "/Contents/MacOS/Clicky", "args": ["--mcp"]}}}, config)
    config.close()
    prompt = ("With the claudia tools: call claudia_see_screen, then claudia_show with speak=false to put "
              "[MARK:1:<id>:Here|test mark] on any button you can see on screen 1. Reply DONE when it worked.")
    completed = subprocess.run([os.path.expanduser("~/.local/bin/claude"), "-p", prompt, "--mcp-config", config.name, "--strict-mcp-config",
                                "--allowedTools", "mcp__claudia__claudia_see_screen,mcp__claudia__claudia_show",
                                "--model", "claude-sonnet-5-5", "--output-format", "text"],
                               capture_output=True, text=True, timeout=300, stdin=subprocess.DEVNULL, cwd="/tmp")
    os.unlink(config.name)
    turns = sorted(glob.glob(os.path.expanduser("~/Library/Logs/Clicky/turns/*")))
    last = {}
    if turns:
        try:
            last = json.load(open(os.path.join(turns[-1], "turn.json")))
        except (OSError, ValueError):
            pass
    marks = [t for t in last.get("tags") or [] if t.get("kind") == "mark"]
    ok = last.get("transcript") == "T3 Code: show" and len(marks) >= 1
    return ok, f"agent said {completed.stdout.strip()[-60:]!r}, marks={len(marks)}"


def case_silent():
    was_on = subprocess.run(["defaults", "read", "com.personal.clicky", "v2.voice.silent"], capture_output=True, text=True).stdout.strip()
    ask("silent mode")
    on = subprocess.run(["defaults", "read", "com.personal.clicky", "v2.voice.silent"], capture_output=True, text=True).stdout.strip()
    ask("talk again", fresh=False)
    off = subprocess.run(["defaults", "read", "com.personal.clicky", "v2.voice.silent"], capture_output=True, text=True).stdout.strip()
    if was_on == "1":
        subprocess.run(["defaults", "write", "com.personal.clicky", "v2.voice.silent", "-bool", "YES"])
    return on == "1" and off == "0", f"on={on} off={off}"


CASES = {
    "research-google": case_research_google,
    "research-hn": case_research_hn,
    "research-named": case_research_named,
    "research-subagents": case_research_subagents,
    "research-wiki": case_research_wiki,
    "research-topic": case_research_topic,
    "workers": case_workers,
    "board": case_board,
    "side-board": case_side_board,
    "no-board-simple": case_no_board_for_simple,
    "point": case_point,
    "search-action": case_search_action,
    "article": case_article,
    "tabs": case_tabs,
    "t3-mcp": case_t3_mcp,
    "silent": case_silent,
}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--only", default="")
    arguments = parser.parse_args()
    names = [n.strip() for n in arguments.only.split(",") if n.strip()] or list(CASES)
    if not ctl({"cmd": "ping"}, 10).get("ok"):
        sys.exit("Clicky isn't answering the debug inbox")
    # The tests never talk: a test-only mute, the owner's voice setting is left alone.
    ctl({"cmd": "testMute", "on": True}, 10)
    results = []
    for name in names:
        started = time.time()
        try:
            passed, detail = CASES[name]()
        except Exception as error:  # a broken case is a failed case
            passed, detail = False, f"error: {error}"
        results.append((name, passed, detail, time.time() - started))
        # Close the pages this run opened (only these titles), so Chrome doesn't fill up with test tabs.
        ctl({"cmd": "closeTabs", "titles": ["best electric cars 2026 - Google", "weather in delhi - Google", "weather in mumbai - Google",
                                            "weather in chennai - Google", "James Webb Space Telescope - Wikipedia",
                                            "Four-stroke engine - Wikipedia"]}, 10)
        ctl({"cmd": "closeTabs"}, 10)
        print(f"{'PASS' if passed else 'FAIL'}  {name:16s} {time.time() - started:5.0f}s  {detail}", flush=True)
    ctl({"cmd": "testMute", "on": False}, 10)
    failed = [r for r in results if not r[1]]
    print(f"\n{len(results) - len(failed)}/{len(results)} passed")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
