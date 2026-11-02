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


SIDEBAR = (0, 0, 264, 820)


def step(name, click=None, expect=None, gone=None, index=0, settle=0.9, xy=None, shot=True, within=None):
    """Clicks `click` (words on screen) or `xy`, then checks `expect` shows up and `gone` doesn't."""
    ok, detail = True, ""
    if xy:
        theoui.send({"cmd": "uiClick", "window": front(), "x": xy[0], "y": xy[1]})
    elif click:
        reply = theoui.click_text(click, index, within=within)
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
step("open-settings", click="Settings", expect="Back to Theo", within=SIDEBAR)
for page, words in [("Clicky", "Thinks with"), ("Harnesses", "Builds go to"), ("Models & API keys", "Anthropic"), ("Voice", "Hears you with"),
                    ("Screen", "Theo's screen"), ("Permissions", "Microphone"), ("Updates", "This is Theo"), ("About", "Show Theo in the Dock"), ("Look", "Cursor")]:
    step(f"settings-{page.split()[0].lower()}", click=page, expect=words, within=SIDEBAR)
step("settings-back", click="Back to Theo", gone="Back to Theo", within=SIDEBAR)

# Sidebar.
go("home")
step("sidebar-notes", click="Notes", expect="Everything Theo saved", within=SIDEBAR)
step("sidebar-routines", click="Routines", expect="Bots doing a job", within=SIDEBAR)
step("sidebar-connectors", click="Connectors", expect="Gmail", settle=1.2, within=SIDEBAR)
step("sidebar-home", click="Home", expect="Your team", within=SIDEBAR)
# The pill at the bottom. A team called Clicky also has a label higher up, so its second line tells them apart.
step("sidebar-clicky", click="Listening for", expect="Message Clicky", within=SIDEBAR)
step("sidebar-theo", click="Theo", expect="Message Theo", within=SIDEBAR)

# API keys: a row opens, a bad key shows the provider's own error.
go("settings:keys")
step("keys-open-row", click="Groq", expect="Get a key", settle=1.0)

# Real typing and ⌘V in the key field, with a bad key: the provider's own error comes back and nothing is saved.
theoui.send({"cmd": "uiPasteboard", "text": "gsk_this-is-not-a-real-key"})
theoui.click_text("gsk_", within=(248, 60, 1032, 760))
time.sleep(0.5)
# The field takes a paste: ⌘V's action, sent to it. (The menu bar can't reach it while the test profile stays inactive,
# and it mustn't activate; the Edit menu itself is checked below.)
state = theoui.send({"cmd": "uiResponderAction", "action": "paste:"})["result"]
ok = state.get("editing") and state.get("fieldLength", 0) == len("gsk_this-is-not-a-real-key")
results.append({"step": "keys-field-takes-paste", "ok": bool(ok), "detail": str(state.get("fieldLength")), "shot": theoui.shot("keys-pasted")})
print("✅" if ok else "❌", "keys-field-takes-paste", state.get("fieldLength"), flush=True)
menus = theoui.send({"cmd": "uiMenus"})["result"]["menus"]
edit = next((m for m in menus if m["title"] == "Edit"), {"items": []})
ok = any(i["title"] == "Paste" and i["key"] == "v" for i in edit["items"])
results.append({"step": "edit-menu-has-cmd-v", "ok": ok, "detail": "", "shot": ""})
print("✅" if ok else "❌", "edit-menu-has-cmd-v", flush=True)
step("keys-test-bad-key", click="Test", expect="rejected", settle=2.5, within=(248, 60, 1032, 760))

# Harnesses show their state.
go("settings:coding")
time.sleep(2.5)
step("harness-state", expect="Signed in")

# New bot sheet.
go("home")
# The new-bot button is an icon on Theo's row at the top of the sidebar.
step("new-bot-opens", xy=(233, 64), expect="Pick a starting point", settle=1.0)
step("new-bot-stencil", click="Researcher", expect="Create bot", within=(270, 60, 1010, 760))
step("new-bot-cancel", click="Cancel", gone="Create bot")

report = out / "click-test.json"
report.write_text(json.dumps(results, indent=1))
failed = [r for r in results if not r["ok"]]
print(f"\n{len(results) - len(failed)}/{len(results)} passed. Report: {report}")
sys.exit(1 if failed else 0)
