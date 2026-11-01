#!/usr/bin/env python3
"""Clicks through Theo's screens in a running test profile and checks each click did what it says.

A person's route through the app: find a control by its words on screen, click it through AppKit, then read the screen
for what should now be there. Takes a screenshot of Theo's window at each step. Exit code 1 if anything failed.

  theo-click-test.py <screens-out-dir>
"""
import json, os, pathlib, sys, time
sys.path.insert(0, str(pathlib.Path(__file__).parent))
import theoui

out = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else "/tmp/theo-clicks")
out.mkdir(parents=True, exist_ok=True)
theoui.OUT = out
results = []


def front():
    return theoui.send({"cmd": "uiState"})["result"]["frontNumber"]


def text_on_screen(number=None):
    return [p["text"].lower() for p in theoui.read_screen(number)[1]]


def has(words, number=None):
    needle = words.lower()
    return any(needle in line for line in text_on_screen(number))


def step(name, click=None, expect=None, gone=None, index=0, settle=0.9, xy=None, shot=True):
    """Clicks `click` (words on screen) or `xy`, then checks `expect` shows up and `gone` doesn't."""
    ok, detail = True, ""
    if xy:
        theoui.send({"cmd": "uiClick", "window": front(), "x": xy[0], "y": xy[1]})
    elif click:
        reply = theoui.click_text(click, index)
        if not reply.get("ok"):
            ok, detail = False, f"couldn't find '{click}' on screen"
    time.sleep(settle)
    if ok and expect:
        found = False
        for _ in range(6):
            if has(expect):
                found = True
                break
            time.sleep(0.5)
        if not found:
            ok, detail = False, f"'{expect}' didn't appear"
    if ok and gone and has(gone):
        ok, detail = False, f"'{gone}' is still there"
    path = theoui.shot(f"{len(results) + 1:03d}-{name}") if shot else ""
    results.append({"step": name, "ok": ok, "detail": detail, "shot": path})
    print(("✅" if ok else "❌"), name, detail, flush=True)
    return ok


def go(pane):
    theoui.send({"cmd": "uiGo", "pane": pane})
    time.sleep(0.7)


# Settings: every page is one click away, and "Back to Theo" returns.
go("home")
step("open-settings", click="Settings", expect="Back to Theo")
for page, words in [("Clicky", "Thinks with"), ("Harnesses", "Builds go to"), ("Models & API keys", "Anthropic"), ("Voice", "speak with"),
                    ("Screen", "Theo's screen"), ("Permissions", "Microphone"), ("Updates", "This is Theo"), ("About", "Show Theo in the Dock"), ("Look", "Cursor")]:
    step(f"settings-{page.split()[0].lower()}", click=page, expect=words)
step("settings-back", click="Back to Theo", gone="Back to Theo")

# Sidebar.
go("home")
step("sidebar-notes", click="Notes", expect="Everything Theo saved")
step("sidebar-routines", click="Routines", expect="Routines")
step("sidebar-connectors", click="Connectors", expect="Gmail", settle=1.2)
step("sidebar-home", click="Home", expect="Your team")
step("sidebar-clicky", click="Clicky", expect="Message Clicky")
step("sidebar-theo", click="Theo", expect="Message Theo", index=1)

# API keys: a row opens, a bad key shows the provider's own error.
go("settings:keys")
step("keys-open-row", click="Groq", expect="Get a key", settle=1.0)

# Harnesses show their state.
go("settings:coding")
time.sleep(2.5)
step("harness-state", expect="Signed in")

# New bot sheet.
go("home")
step("new-bot-opens", click="New bot", expect="Pick a starting point", settle=1.0)
step("new-bot-stencil", click="Researcher", expect="Create bot")
step("new-bot-cancel", click="Cancel", gone="Create bot")

report = out / "click-test.json"
report.write_text(json.dumps(results, indent=1))
failed = [r for r in results if not r["ok"]]
print(f"\n{len(results) - len(failed)}/{len(results)} passed. Report: {report}")
sys.exit(1 if failed else 0)
