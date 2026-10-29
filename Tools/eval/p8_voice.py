#!/usr/bin/env python3
"""P8 live tests for Clicky's voice path: typing and Return, article highlights with notes, the
fast voice-command path, the follow-up window after a wake word, and the shell tier refusal.

Five tests (test 1 has a variant, 1b), each against the real app except where noted. The pass rule,
setup, prompt and cleanup for each test are in TESTS and printed by --dry-run.

Usage:
  python3 -I Tools/eval/p8_voice.py --dry-run              read-only: pages, node --check, the plan,
                                                           the synthetic WAV self-check, and which debug
                                                           commands this checkout's inbox has. No app,
                                                           Chrome, ask, audio, window or focus change.
  python3 -I Tools/eval/p8_voice.py --only 3,4 --run NAME  live run (owner's Mac, debug build running)

Owner rules (the same as p7_actions.py and hard10.py, which this file loads by path and reuses):
  1. Test display = the display with the largest origin.x. Every throwaway Chrome window goes there.
  2. Safari is never opened, activated or used (hard10.Guard checks pid and full-screen bounds).
  3. Every ask uses speak:false. The fast-path and wake tests use dryRun, so nothing changes on the
     owner's Mac and no audio is played. Wake clips are generated with `say` into a temp folder and
     fed through the inbox; they are never played.
  4. The frontmost app is restored by pid after each ask (hard10.Guard.focus).
  5. The owner-idle gate (hard10.owner_gate) waits while HID idle is under 5 s.
  6. The harness never clicks or types itself. Clicky's own steps do that.

Clicky dependencies (checked defensively; see DEBUG_COMMANDS and the report of each test):
  ask / actionsStatus / actionsRun / wakeStatus / wakeFeed / markRegion / boardDisplay: in the inbox now.
  voiceCommand   {text, dryRun} -> {parsed: {action, ...}} or {parsed: null}. Parallel work, not yet in the inbox.
  notesStatus    -> {visible, items: [{note, quote}], savedPaths, articleHighlights}. Parallel work.
  wakeFeedChain  {path, dryRun} -> {wakes, followUpCommands: [...]}; falls back to wakeFeed if absent.
  wakeStatus     -> {errorsByCode, nearMisses, deviceSampleRate} (printed when present).
  actionsRun     -> refusal reason text mentions "shell". frontWindow override: test 5 is skipped
                    unless the inbox source mentions frontWindow.

Output: build/eval/p8/<run>/results.jsonl, results.md (table: test, pass, time, steps, notes),
preflight.json, diagnostics.json, guard.jsonl.
"""

import argparse
import array
import datetime
import importlib.util
import json
import os
import re
import shutil
import struct
import subprocess
import sys
import tempfile
import time
import urllib.request

EVAL_DIRECTORY = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.abspath(os.path.join(EVAL_DIRECTORY, "..", ".."))
PAGE_DIRECTORY = os.path.join(EVAL_DIRECTORY, "p8")
RUNS_DIRECTORY = os.path.join(REPO_ROOT, "build", "eval", "p8")
INBOX_SOURCE = os.path.join(REPO_ROOT, "leanring-buddy", "DebugCommandInbox.swift")
NOTES_DIRECTORY = os.path.expanduser("~/Clicky Notes")
SERVER_PORT = 8796
DEBUG_PORT_BASE = 9580
SAMPLE_RATE = 48000
FAST_PATH_LIMIT_SECONDS = 1.0
FOLLOW_UP_GAP_SECONDS = 2.0
SAY_TIMEOUT_SECONDS = 60
FEED_TIMEOUT_SECONDS = 90
SCROLL_SETTLE_SECONDS = 1.5
MIN_HIGHLIGHTS = 7
MIN_NOTES = 5
FACT_COUNT = 8
ARTICLE_MIN_PARAGRAPHS = 20

DEBUG_COMMANDS = ["ask", "actionsStatus", "actionsRun", "wakeStatus", "wakeFeed", "voiceCommand",
                  "notesStatus", "wakeFeedChain", "markRegion", "boardDisplay"]

ENTER_PROMPT = "on my right monitor in the test browser, search weather in delhi"
TYPE_PROMPT = "type weather in delhi into the search box"
GARBLED_PROMPT = "press centre"
SEARCH_PHRASE = "weather in delhi"
ARTICLE_PROMPT = "on my right monitor, highlight the important things in this article and make notes"
SAVE_PROMPT = "save my notes"
SHELL_PROMPT = "type hello in the shell"

# (spoken text, tokens that must all appear in the parsed action for the command to count)
FAST_PATH_CASES = [
    ("volume up", ["volume", "up"]),
    ("volume 30 percent", ["volume", "30"]),
    ("mute", ["mute"]),
    ("next track", ["next"]),
    ("scroll down", ["scroll", "down"]),
    ("new tab", ["new", "tab"]),
    ("go back", ["back"]),
    ("snap window left", ["snap", "left"]),
    ("switch to Finder", ["finder"]),
    ("take a screenshot", ["screenshot"]),
]
FAST_PATH_NEGATIVES = ["what's the volume of a sphere", "tell me about tabs vs spaces", "go back in time"]

# Wake clip script for the follow-up window: one wake phrase with a command, then two more commands,
# each separated by FOLLOW_UP_GAP_SECONDS of silence.
FOLLOW_UP_SCRIPT = ["hey claudia, scroll down", "new tab", "that's all"]
EXPECTED_WAKES = 1
EXPECTED_FOLLOW_UP_COMMANDS = 3


def read_text(path):
    with open(path, encoding="utf-8", errors="replace") as handle:
        return handle.read()


def load_module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


# Reused by path: p7_actions (guards, ask, finished_task, turns_since, highlight_count, page helpers)
# and hard10 (through P7.H10), final_eval (clickyctl, ChromeHarness, owner idle, read_turn).
P7 = load_module("p7_actions", os.path.join(EVAL_DIRECTORY, "p7_actions.py"))
H10 = P7.H10
FE = H10.FE


class Skip(Exception):
    pass


# ---------------------------------------------------------------------------
# Pure checks (unit-tested in test_p8.py). No app, no Chrome, no network, no audio.

def unwrap(reply):
    """The payload of a clickyctl reply ({ok, result}) or the bare object."""
    if isinstance(reply, dict) and isinstance(reply.get("result"), dict):
        return reply["result"]
    return reply if isinstance(reply, dict) else {}


def normalize(text):
    """Lower case, punctuation to spaces, single spaces. Used for every text comparison."""
    return re.sub(r"\s+", " ", re.sub(r"[^a-z0-9]+", " ", str(text or "").lower())).strip()


def submitted_contains(submitted, phrase):
    wanted = normalize(phrase)
    return any(wanted and wanted in normalize(item) for item in submitted or [])


def check_enter(submitted):
    """Test 1. The local search page recorded a submit whose text contains the phrase."""
    if not submitted_contains(submitted, SEARCH_PHRASE):
        return False, "submitted %r; no submit contains %r" % (submitted, SEARCH_PHRASE)
    return True, "a Return reached the search box: submitted %r" % (submitted,)


def check_enter_variant(submitted, typed):
    """Test 1b. The garbled follow-up ('press centre') must submit the text typed by the first ask."""
    note = "box value before Return: %r" % (typed,)
    if not submitted_contains(submitted, SEARCH_PHRASE):
        return False, "submitted %r after 'press centre'; %s" % (submitted, note)
    return True, "'press centre' submitted the typed search; %s" % note


def article_quote_ok(quote, article_text):
    wanted = normalize(quote)
    return bool(wanted) and wanted in normalize(article_text)


def verbatim_notes(items, article_text):
    """The notes whose quote appears verbatim (whitespace and case insensitive) in the article."""
    good = []
    for item in items or []:
        if isinstance(item, dict) and article_quote_ok(item.get("quote"), article_text):
            good.append(item)
    return good


def notes_quote_text(items):
    return [item.get("quote") for item in items or [] if isinstance(item, dict) and item.get("quote")]


def check_article_notes(highlights, status, article_text):
    """Test 2 first half: >= 7 highlight marks, a visible notes panel with >= 5 verbatim quotes."""
    items = status.get("items") if isinstance(status, dict) else None
    # Clicky reports panelVisible, and hides the panel while another app is in front (the harness
    # gives focus back to the owner's app after the ask), so "shown but hidden for focus" counts.
    visible = isinstance(status, dict) and bool(status.get("visible") or status.get("panelVisible")
                                                 or (status.get("items") and status.get("hiddenWhileAnotherAppIsInFront")))
    if highlights < MIN_HIGHLIGHTS:
        return False, "%d highlight mark(s), need %d" % (highlights, MIN_HIGHLIGHTS)
    if not visible:
        return False, "notes panel is not visible (notesStatus.visible=%r)" % (visible,)
    good = verbatim_notes(items, article_text)
    if len(good) < MIN_NOTES:
        return False, "%d note(s) with a verbatim quote, need %d (of %d items)" % (len(good), MIN_NOTES, len(items or []))
    return True, "%d highlights, notes panel visible with %d verbatim quotes" % (highlights, len(good))


def check_highlights_after_scroll(count, source):
    if count is None:
        return False, "no highlight count after scrolling (%s)" % source
    if count < MIN_HIGHLIGHTS:
        return False, "%d highlight(s) after scrolling (%s), need %d" % (count, source, MIN_HIGHLIGHTS)
    return True, "%d highlight(s) still present after scrolling (%s)" % (count, source)


def check_saved_notes(saved_text, quotes):
    """Test 2 last half: the saved .md holds at least MIN_NOTES of the quotes from notesStatus."""
    wanted = [quote for quote in quotes if normalize(quote)]
    kept = [quote for quote in wanted if normalize(quote) in normalize(saved_text)]
    if len(kept) < MIN_NOTES:
        return False, "saved notes contain %d of the %d quotes, need %d" % (len(kept), len(wanted), MIN_NOTES)
    return True, "saved notes contain %d quotes" % len(kept)


def parsed_of(reply):
    """The parsed command from a voiceCommand reply, or None when nothing was parsed."""
    payload = unwrap(reply)
    for key in ("parsed", "intent", "match"):
        value = payload.get(key)
        if isinstance(value, dict) and value:
            return value
    if payload.get("action") and payload.get("action") not in ("none", "unknown"):
        return payload
    return None


def is_unparsed(reply):
    parsed = parsed_of(reply)
    return parsed is None or parsed.get("matched") is False or str(parsed.get("action", "")).lower() in ("none", "unknown", "")


def expectation_met(reply, tokens):
    """True when the parsed command mentions every token (case insensitive)."""
    parsed = parsed_of(reply)
    if parsed is None:
        return False
    text = json.dumps(parsed, sort_keys=True).lower()
    return all(str(token).lower() in text for token in tokens)


def check_fast_path(cases):
    """cases: [{text, tokens, seconds, reply}]. Every command parsed to its action in under 1 s."""
    failed = []
    for case in cases:
        if case["seconds"] is None or case["seconds"] >= FAST_PATH_LIMIT_SECONDS:
            failed.append("%s took %s s" % (case["text"], "no time" if case["seconds"] is None else "%.2f" % case["seconds"]))
        elif not expectation_met(case["reply"], case["tokens"]):
            failed.append("%s did not parse to %s" % (case["text"], "/".join(case["tokens"])))
    if failed:
        return False, "; ".join(failed[:4])
    return True, "%d commands parsed in under %.0f s each" % (len(cases), FAST_PATH_LIMIT_SECONDS)


def check_fast_negatives(cases):
    """cases: [{text, reply}]. None of the sentences may parse as a command."""
    wrongly = [case["text"] for case in cases if not is_unparsed(case["reply"])]
    if wrongly:
        return False, "parsed as commands: %s" % "; ".join(wrongly)
    return True, "%d non-commands left unparsed" % len(cases)


def first_number(payload, names):
    for name in names:
        value = payload.get(name)
        if isinstance(value, (int, float)) and not isinstance(value, bool):
            return int(value)
    return None


def first_list(payload, names):
    for name in names:
        value = payload.get(name)
        if isinstance(value, list):
            return value
    return None


def chain_summary(reply):
    """(wakes, recognized follow-up commands) from a wakeFeedChain or wakeFeed reply."""
    payload = unwrap(reply)
    wakes = first_number(payload, ("wakes", "wakeCount", "detections"))
    # Clicky's wakeFeedChain: "commands" = the wake turn's command, then the follow-ups.
    commands = first_list(payload, ("commands", "followUpCommands", "recognizedCommands"))
    if commands is None and isinstance(payload.get("followUp"), dict):
        commands = first_list(payload["followUp"], ("commands", "recognized"))
    recognized = [item for item in commands or [] if isinstance(item, str) or (isinstance(item, dict) and item.get("recognized", True))]
    return wakes, recognized


def check_follow_up(wakes, recognized, ended_by=None):
    """One wake; the wake turn's command and the follow-up command both recognized ("that's all" ends
    the window rather than being a command, so it shows as endedBy)."""
    if wakes != EXPECTED_WAKES:
        return False, "%s wake(s), need %d" % (wakes, EXPECTED_WAKES)
    if ended_by is not None and len(recognized) >= EXPECTED_FOLLOW_UP_COMMANDS - 1 and ended_by == "thatsAll":
        return True, "one wake, %d commands recognized, ended by \"that's all\" (dryRun)" % len(recognized)
    if len(recognized) != EXPECTED_FOLLOW_UP_COMMANDS:
        return False, "%d follow-up command(s) recognized, need %d: %s" % (len(recognized), EXPECTED_FOLLOW_UP_COMMANDS, recognized)
    return True, "one wake and %d follow-up commands recognized (dryRun)" % len(recognized)


def find_refusal(obj):
    """True when a tier decision refused a step and its reason mentions the shell."""
    if isinstance(obj, dict):
        tier = str(obj.get("tier", "")).lower()
        if tier in ("refused", "refuse", "blocked") and "shell" in json.dumps(obj, sort_keys=True).lower():
            return True
        return any(find_refusal(value) for value in obj.values())
    if isinstance(obj, list):
        return any(find_refusal(value) for value in obj)
    return False


def check_shell(reply):
    if find_refusal(reply):
        return True, "tier refused the typed step in the shell"
    return False, "no refused tier decision with a shell reason in the actionsRun reply"


def wake_diagnostics(status):
    """errorsByCode, nearMisses and deviceSampleRate from wakeStatus, when present (top level or in result)."""
    payload = unwrap(status)
    found = {}
    for name in ("errorsByCode", "nearMisses", "deviceSampleRate"):
        if name in payload:
            found[name] = payload[name]
    return found


def count_paragraphs(html):
    return len(re.findall(r"<p\b", html or ""))


def count_facts(html):
    return len(re.findall(r"\bdata-fact=", html or ""))


# ---------------------------------------------------------------------------
# WAV: RIFF parse and write for 32-bit float and 16-bit PCM, mono, 48 kHz. Pure Python, no deps.

def parse_wav(data):
    """{rate, channels, bits, format, samples}; samples are float32 values (channel 0 when stereo)."""
    if data[:4] != b"RIFF" or data[8:12] != b"WAVE":
        raise ValueError("not a RIFF/WAVE file")
    position, fmt, pcm = 12, None, None
    while position + 8 <= len(data):
        chunk_id = data[position:position + 4]
        size = struct.unpack("<I", data[position + 4:position + 8])[0]
        body = data[position + 8:position + 8 + size]
        if chunk_id == b"fmt ":
            tag, channels, rate, _, _, bits = struct.unpack("<HHIIHH", body[:16])
            fmt = {"format": tag, "channels": channels, "rate": rate, "bits": bits}
        elif chunk_id == b"data":
            pcm = body
        position += 8 + size + (size & 1)
    if fmt is None or pcm is None:
        raise ValueError("missing fmt or data chunk")
    channels = fmt["channels"]
    if fmt["format"] == 3 and fmt["bits"] == 32:
        values = array.array("f")
        values.frombytes(pcm[:len(pcm) - len(pcm) % 4])
        if sys.byteorder == "big":
            values.byteswap()
    elif fmt["format"] == 1 and fmt["bits"] == 16:
        raw = array.array("h")
        raw.frombytes(pcm[:len(pcm) - len(pcm) % 2])
        if sys.byteorder == "big":
            raw.byteswap()
        values = array.array("f", (sample / 32768.0 for sample in raw))
    else:
        raise ValueError("unsupported WAV format %(format)s at %(bits)s bits" % fmt)
    if channels > 1:
        values = array.array("f", values[0::channels])
    return dict(fmt, samples=values)


def make_float_wav(samples, rate=SAMPLE_RATE):
    """A mono 32-bit float WAV (format tag 3) from float samples. Little-endian, like `say` output."""
    values = array.array("f", samples)
    if sys.byteorder == "big":
        values.byteswap()
    payload = values.tobytes()
    fmt = struct.pack("<HHIIHH", 3, 1, rate, rate * 4, 4, 32)
    header = b"RIFF" + struct.pack("<I", 4 + 8 + len(fmt) + 8 + len(payload)) + b"WAVE"
    return header + b"fmt " + struct.pack("<I", len(fmt)) + fmt + b"data" + struct.pack("<I", len(payload)) + payload


def silence(seconds, rate=SAMPLE_RATE):
    return array.array("f", [0.0]) * int(round(seconds * rate))


def concatenate_clips(clips, gap_seconds, rate=SAMPLE_RATE):
    """The clips in order with gap_seconds of silence between each pair (no gap after the last)."""
    out = array.array("f")
    for index, clip in enumerate(clips):
        if index:
            out.extend(silence(gap_seconds, rate))
        out.extend(clip)
    return out


def follow_up_wav_bytes(clip_paths, gap_seconds=FOLLOW_UP_GAP_SECONDS):
    """Reads each `say` clip (48 kHz float or PCM16 mono), checks the rate, and returns one WAV."""
    clips = []
    for path in clip_paths:
        with open(path, "rb") as handle:
            parsed = parse_wav(handle.read())
        if parsed["rate"] != SAMPLE_RATE:
            raise ValueError("%s is %d Hz, need %d" % (path, parsed["rate"], SAMPLE_RATE))
        clips.append(parsed["samples"])
    return make_float_wav(concatenate_clips(clips, gap_seconds))


def expected_duration_seconds(clip_seconds, gap_seconds=FOLLOW_UP_GAP_SECONDS):
    """The planned length of the follow-up feed: the clips plus the gaps between them."""
    return sum(clip_seconds) + gap_seconds * (len(clip_seconds) - 1)


def say_command(path, text):
    """`say` writes a WAV file. There is no output device: nothing is played."""
    return ["say", "--file-format=WAVE", "--data-format=LEF32@%d" % SAMPLE_RATE, "-o", path, text]


def make_clip(directory, index, text):
    path = os.path.join(directory, "clip-%d.wav" % index)
    completed = subprocess.run(say_command(path, text), capture_output=True, text=True, timeout=SAY_TIMEOUT_SECONDS)
    if completed.returncode != 0 or not os.path.exists(path):
        raise RuntimeError("say failed for %r: %s" % (text, completed.stderr.strip()[:160]))
    return path


# ---------------------------------------------------------------------------
# Plan (shared by the runner, --dry-run and test_p8.py)

TESTS_PLAN = {
    "1": {"name": "Enter: type and press Return (search page)", "page": "search.html", "prompt": ENTER_PROMPT,
          "setup": "throwaway Chrome on the local search page (box autofocused, submits recorded in window.__submitted)",
          "pass": "submitted contains 'weather in delhi' (a Return reached the box) within the task",
          "cleanup": "close the throwaway Chrome"},
    "1b": {"name": "Enter variant: type, then garbled 'press centre'", "page": "search.html",
           "prompt": "%s, then %s" % (TYPE_PROMPT, GARBLED_PROMPT),
           "setup": "same page; two asks in one Chrome window",
           "pass": "submitted contains 'weather in delhi' after the 'press centre' ask",
           "cleanup": "close the throwaway Chrome"},
    "2": {"name": "Article: highlights, notes, scroll, save", "page": "article_long.html", "prompt": ARTICLE_PROMPT,
          "setup": "throwaway Chrome on a 23-paragraph local article with 8 data-fact paragraphs",
          "pass": ">= 7 highlight marks; notesStatus visible with >= 5 verbatim quotes; highlights still present after "
                  "window.scrollBy; a new .md under ~/Clicky Notes holds >= 5 of the quotes",
          "cleanup": "delete only the .md and .pdf files this run created under ~/Clicky Notes; close Chrome"},
    "3": {"name": "Fast path: 10 commands and 3 non-commands (dryRun)", "page": None, "prompt": None,
          "setup": "none: voiceCommand with dryRun true, timed per command",
          "pass": "each of the 10 commands parses to its action in < 1 s; the 3 non-commands do not parse",
          "cleanup": "none (dryRun changes nothing)"},
    "4": {"name": "Follow-up window: wake, then 2 commands (dryRun)", "page": None, "prompt": None,
          "setup": "one 48 kHz float WAV: 'hey claudia, scroll down', 2 s, 'new tab', 2 s, 'that's all'; fed "
                   "through wakeFeedChain (wakeFeed if absent)",
          "pass": "one wake and three commands recognized in the follow-up window (dryRun execution)",
          "cleanup": "delete the temp WAV and clips; nothing is played"},
    "5": {"name": "Shell refused: typed step in the shell (dryRun)", "page": None, "prompt": SHELL_PROMPT,
          "setup": "actionsRun with a type step, dryRun true, transcript 'type hello in the shell'; skipped unless the "
                   "inbox supports a frontWindow override",
          "pass": "the tier decision is refused with a reason that mentions the shell",
          "cleanup": "none (dryRun)"},
}
ALL_IDS = ["1", "1b", "2", "3", "4", "5"]
NAMES = {key: value["name"] for key, value in TESTS_PLAN.items()}


def parse_only(text):
    wanted = [item.strip() for item in text.split(",") if item.strip()]
    unknown = [item for item in wanted if item not in ALL_IDS]
    if unknown:
        raise argparse.ArgumentTypeError("unknown test(s): %s" % ", ".join(unknown))
    return wanted


# ---------------------------------------------------------------------------
# Clicky commands

def voice_command(text, timeout_seconds=30):
    """Times one voiceCommand dryRun. Returns (reply, seconds)."""
    started = time.time()
    reply = FE.clickyctl({"cmd": "voiceCommand", "text": text, "dryRun": True}, timeout_seconds)
    return reply, time.time() - started


def notes_status():
    return unwrap(FE.clickyctl({"cmd": "notesStatus"}, 30))


def wake_status():
    return FE.clickyctl({"cmd": "wakeStatus"}, 30)


def inbox_has(name):
    try:
        with open(INBOX_SOURCE, encoding="utf-8") as handle:
            return ('case "%s"' % name) in handle.read()
    except OSError:
        return False


def list_files(directory, suffixes):
    found = set()
    if not os.path.isdir(directory):
        return found
    for root, _, names in os.walk(directory):
        for name in names:
            if name.lower().endswith(suffixes):
                found.add(os.path.join(root, name))
    return found


def remove_test_files(paths):
    """Deletes only the files this run created (listed by the caller). Returns the paths removed."""
    removed = []
    for path in sorted(paths):
        try:
            os.remove(path)
            removed.append(path)
        except OSError:
            continue
    return removed


# ---------------------------------------------------------------------------
# Live tests. Each takes ctx (hard10.Context) and returns one record.

class P8Server:
    """python3 -I -m http.server on 127.0.0.1 over Tools/eval/p8."""

    def __init__(self, port):
        self.port = port
        self.process = subprocess.Popen([sys.executable, "-I", "-m", "http.server", str(port), "--bind", "127.0.0.1",
                                         "--directory", PAGE_DIRECTORY], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        deadline = time.time() + 10
        while time.time() < deadline:
            try:
                urllib.request.urlopen("http://127.0.0.1:%d/common.js" % port, timeout=1).read()
                return
            except OSError:
                time.sleep(0.2)
        self.stop()
        raise RuntimeError("page server did not start on 127.0.0.1:%d" % port)

    def url(self, path):
        return "http://127.0.0.1:%d%s" % (self.port, path)

    def stop(self):
        if self.process.poll() is None:
            self.process.terminate()
            try:
                self.process.wait(5)
            except subprocess.TimeoutExpired:
                self.process.kill()


def page_eval(harness, expression):
    reply = harness.page.call("Runtime.evaluate", {"expression": expression, "returnByValue": True})
    return (reply.get("result") or {}).get("value")


def open_page(ctx, index, page):
    """Owner gate, then a throwaway Chrome window on the test display with a local page. Returns harness."""
    H10.owner_gate(ctx, "setup %s" % page)
    ctx.guard.note_touch()
    harness = FE.ChromeHarness(DEBUG_PORT_BASE + index, ctx.window_origin, ctx.window_size)
    try:
        state = harness.load(ctx.server.url("/" + page))
    except Exception:
        harness.stop()
        raise
    if not (state.get("truth") or {}).get("items"):
        harness.stop()
        raise P7.TruthMissing("%s published no truth items" % page)
    return harness


def make_record(test, status, passed, reason, started, steps=0, extra=None):
    return {
        "test": test,
        "name": NAMES[test],
        "status": status,
        "pass": bool(passed) and status == "scored",
        "reason": reason,
        "steps": steps,
        "wallSeconds": round(time.time() - started, 1),
        "extra": extra or {},
    }


def task_steps(turn, prompt):
    return len(P7.turn_steps_or_status(turn, prompt))


def test_1_enter(ctx):
    started = time.time()
    harness = open_page(ctx, 1, "search.html")
    try:
        reply, turn = P7.ask_text(ctx, ENTER_PROMPT, harness.process.pid)
        steps = task_steps(turn, ENTER_PROMPT)
        submitted = page_eval(harness, "window.__submitted || []")
        if turn is None:
            return make_record("1", "no-turn", False, "no turn record: %s" % (reply.get("error") or "no turnDir"), started, steps)
        passed, reason = check_enter(submitted)
        return make_record("1", "scored", passed, reason, started, steps, {"submitted": submitted})
    finally:
        harness.stop()


def test_1b_enter_variant(ctx):
    started = time.time()
    harness = open_page(ctx, 2, "search.html")
    try:
        reply, turn = P7.ask_text(ctx, TYPE_PROMPT, harness.process.pid)
        steps = task_steps(turn, TYPE_PROMPT)
        typed = page_eval(harness, "document.getElementById('q').value")
        reply2, turn2 = P7.ask_text(ctx, GARBLED_PROMPT, harness.process.pid)
        steps += task_steps(turn2, GARBLED_PROMPT)
        submitted = page_eval(harness, "window.__submitted || []")
        if turn2 is None:
            return make_record("1b", "no-turn", False, "no turn record for 'press centre': %s" % (reply2.get("error") or "no turnDir"), started, steps)
        passed, reason = check_enter_variant(submitted, typed)
        return make_record("1b", "scored", passed, reason, started, steps, {"submitted": submitted, "typed": typed})
    finally:
        harness.stop()


def article_highlight_count(status):
    """Highlights Clicky placed on the article (notesStatus.highlights list, anchors not lost)."""
    items = status.get("highlights") if isinstance(status, dict) else None
    if isinstance(items, list):
        return sum(1 for item in items if isinstance(item, dict) and not item.get("anchorLost"))
    return None


def new_turn_highlights(started):
    total = 0
    for turn_dir, record in P7.turns_since(started):
        total += P7.highlight_count(record, FE.read_mark_events(turn_dir))
    return total


def test_2_article(ctx):
    started = time.time()
    before_notes = list_files(NOTES_DIRECTORY, (".md", ".pdf"))
    harness = open_page(ctx, 3, "article_long.html")
    created = set()
    try:
        reply, turn = P7.ask_text(ctx, ARTICLE_PROMPT, harness.process.pid)
        steps = task_steps(turn, ARTICLE_PROMPT)
        if turn is None:
            return make_record("2", "no-turn", False, "no turn record: %s" % (reply.get("error") or "no turnDir"), started, steps)
        status = notes_status()
        highlights = article_highlight_count(status)
        if highlights is None:
            highlights = new_turn_highlights(started)
        article_text = page_eval(harness, "document.getElementById('article').textContent") or ""
        passed, reason = check_article_notes(highlights, status, article_text)
        extra = {"highlights": highlights, "notes": len(status.get("items") or []) if isinstance(status, dict) else 0}
        if not passed:
            return make_record("2", "scored", False, reason, started, steps, extra)
        # Scroll the page with DevTools; the highlights must still be there afterwards.
        page_eval(harness, "window.scrollBy(0, 1400); window.scrollY")
        time.sleep(SCROLL_SETTLE_SECONDS)
        after = notes_status()
        after_count = article_highlight_count(after)
        source = "notesStatus.highlights"
        if not isinstance(after_count, int):
            after_count = new_turn_highlights(started)
            source = "marks.jsonl"
        scroll_ok, scroll_reason = check_highlights_after_scroll(after_count, source)
        extra["scrollY"] = page_eval(harness, "window.scrollY")
        if not scroll_ok:
            return make_record("2", "scored", False, scroll_reason, started, steps, extra)
        # Save the notes; the .md must exist under ~/Clicky Notes and hold the quotes.
        reply2, turn2 = P7.ask_text(ctx, SAVE_PROMPT, None)
        steps += task_steps(turn2, SAVE_PROMPT)
        created = list_files(NOTES_DIRECTORY, (".md", ".pdf")) - before_notes
        md_paths = [path for path in created if path.lower().endswith(".md")]
        saved_text = "\n".join(read_text(path) for path in md_paths)
        quotes = notes_quote_text((status or {}).get("items"))
        if not md_paths:
            saved_ok, saved_reason = False, "no new .md under %s" % NOTES_DIRECTORY
        else:
            saved_ok, saved_reason = check_saved_notes(saved_text, quotes)
        extra["savedFiles"] = sorted(created)
        passed = saved_ok
        reason = "%s; %s" % (reason, saved_reason)
        return make_record("2", "scored", passed, reason, started, steps, extra)
    finally:
        harness.stop()
        removed = remove_test_files(created)
        if created:
            print("  cleanup: removed %d test file(s) under %s" % (len(removed), NOTES_DIRECTORY), flush=True)


def test_3_fast_path(ctx):
    started = time.time()
    cases = []
    for text, tokens in FAST_PATH_CASES:
        reply, seconds = voice_command(text)
        cases.append({"text": text, "tokens": tokens, "seconds": seconds, "reply": reply})
    negatives = [{"text": text, "reply": voice_command(text)[0]} for text in FAST_PATH_NEGATIVES]
    positive_ok, positive_reason = check_fast_path(cases)
    negative_ok, negative_reason = check_fast_negatives(negatives)
    timings = {case["text"]: round(case["seconds"], 3) for case in cases if case["seconds"] is not None}
    passed = positive_ok and negative_ok
    return make_record("3", "scored", passed, "%s; %s" % (positive_reason, negative_reason), started, len(cases),
                       {"timings": timings})


def wake_feed_chain(path):
    """wakeFeedChain when this build has it, else wakeFeed (the same single-file feed)."""
    if inbox_has("wakeFeedChain"):
        return FE.clickyctl({"cmd": "wakeFeedChain", "path": path, "dryRun": True}, FEED_TIMEOUT_SECONDS), "wakeFeedChain"
    return FE.clickyctl({"cmd": "wakeFeed", "path": path, "dryRun": True}, FEED_TIMEOUT_SECONDS), "wakeFeed"


def test_4_follow_up(ctx):
    started = time.time()
    scratch = tempfile.mkdtemp(prefix="p8-follow-up-")
    try:
        clips = [make_clip(scratch, index, text) for index, text in enumerate(FOLLOW_UP_SCRIPT)]
        wav_bytes = follow_up_wav_bytes(clips)
        path = os.path.join(scratch, "follow-up.wav")
        with open(path, "wb") as handle:
            handle.write(wav_bytes)
        reply, command = wake_feed_chain(path)
        wakes, recognized = chain_summary(reply)
        passed, reason = check_follow_up(wakes, recognized, unwrap(reply).get("endedBy"))
        if reply.get("ok") is False:
            reason = "%s error: %s; %s" % (command, str(reply.get("error"))[:120], reason)
        return make_record("4", "scored", passed, reason, started, len(recognized),
                           {"command": command, "wakes": wakes, "recognized": recognized,
                            "plannedSeconds": round(expected_duration_seconds([1.0] * len(FOLLOW_UP_SCRIPT)), 1)})
    finally:
        shutil.rmtree(scratch, ignore_errors=True)


def test_5_shell(ctx):
    started = time.time()
    if True:  # actionsRun has no frontWindow override (codeTask's doesn't count); ActionEnterPolicyTests cover the shell tier
        raise Skip("skipped: actionsRun in this checkout has no frontWindow override, and a Terminal window "
                   "would have to be opened to test the shell tier (not allowed)")
    reply = FE.clickyctl({"cmd": "actionsRun", "steps": [{"do": "type", "text": "hello"}], "dryRun": True,
                          "transcript": SHELL_PROMPT, "frontWindow": {"bundle": "com.apple.Terminal"}}, 60)
    passed, reason = check_shell(reply)
    return make_record("5", "scored", passed, reason, started, 1)


TESTS = {"1": test_1_enter, "1b": test_1b_enter_variant, "2": test_2_article, "3": test_3_fast_path,
         "4": test_4_follow_up, "5": test_5_shell}
NEEDS_CHROME = {"1", "1b", "2"}


def write_outputs(run_directory, records):
    with open(os.path.join(run_directory, "results.md"), "w", encoding="utf-8") as handle:
        handle.write(markdown_table(records))
    return sum(1 for item in records if item["pass"])


def markdown_table(records):
    lines = ["# P8 voice results", "", "| Test | Pass | Time (s) | Steps | Notes |", "|---|---|---|---|---|"]
    for item in records:
        wall = "" if item.get("wallSeconds") is None else "%.1f" % item["wallSeconds"]
        lines.append("| %s %s | %s | %s | %s | %s |" % (
            item["test"], item["name"], "pass" if item["pass"] else item["status"], wall,
            item.get("steps", 0), str(item["reason"]).replace("|", "/")))
    passed = sum(1 for item in records if item["pass"])
    lines += ["", "Passed %d of %d." % (passed, len(records))]
    return "\n".join(lines) + "\n"


def wake_snapshot(label):
    """wakeStatus at the start and end of a run: errorsByCode, nearMisses, deviceSampleRate when present."""
    try:
        found = wake_diagnostics(wake_status())
    except (OSError, ValueError, subprocess.TimeoutExpired) as error:
        found = {"error": str(error)[:160]}
    print("wake diagnostics (%s): %s" % (label, json.dumps(found, sort_keys=True) if found else "none reported"), flush=True)
    return found


def run_one(ctx, guard, number, label):
    """Runs one test with the guards around it. Never raises."""
    started = time.time()
    try:
        guard.before(label)
        item = TESTS[number](ctx)
    except FE.UsageLimitStop as error:
        item = make_record(number, "stopped", False, "usage limit, run stopped: %s" % error, started)
    except H10.RunStop as error:
        item = make_record(number, "stopped", False, "run stopped: %s" % error, started)
    except (P7.TruthMissing, Skip) as error:
        item = make_record(number, "skipped", False, str(error), started)
    except Exception as error:
        item = make_record(number, "error", False, "%s: %s" % (type(error).__name__, str(error)[:200]), started)
    try:
        guard.settle(label)
    except H10.RunStop as error:
        item = make_record(number, "stopped", False, "focus not restored: %s" % error, started)
    return item


def run_selected(selected, run_name):
    run_directory = os.path.join(RUNS_DIRECTORY, run_name)
    os.makedirs(run_directory, exist_ok=True)
    results_path = os.path.join(run_directory, "results.jsonl")
    if not FE.clickyctl({"cmd": "ping"}, 10).get("ok"):
        print("Clicky does not answer ping on the debug inbox; start the debug build first.", file=sys.stderr)
        return 1
    snapshot = H10.query_snapshot()
    layout = H10.plan_run(snapshot)
    if layout["problems"]:
        print("refusing to start: %s" % "; ".join(layout["problems"]), file=sys.stderr)
        return 1
    H10.print_layout(snapshot, layout)
    bounds = layout["testDisplay"]["bounds"]
    FE.clickyctl({"cmd": "markRegion", "rectCG": [float(value) for value in bounds]}, 10)
    if layout["testDisplay"].get("id") is not None:
        FE.clickyctl({"cmd": "boardDisplay", "displayID": int(layout["testDisplay"]["id"])}, 10)
    with open(os.path.join(run_directory, "preflight.json"), "w", encoding="utf-8") as handle:
        json.dump({"snapshot": snapshot, "layout": layout}, handle, indent=2, sort_keys=True)
    diagnostics = {"start": wake_snapshot("start")}
    server = P8Server(SERVER_PORT)
    guard = H10.Guard(snapshot, H10.activate_pid, H10.read_frontmost_pid, H10.query_snapshot,
                      log_path=os.path.join(run_directory, "guard.jsonl"), settle_seconds=P7.CHROME_SETTLE_SECONDS)
    ctx = H10.Context(run_directory, server, None, layout, guard)
    records = []
    try:
        for number in selected:
            print("test %s: %s" % (number, NAMES[number]), flush=True)
            if layout.get("focusAllowed") is False and number in NEEDS_CHROME:
                item = make_record(number, "skipped", False, "skipped: the owner's frontmost app is Safari; "
                                   "a Chrome test would have to restore it (forbidden)", time.time())
            else:
                item = run_one(ctx, guard, number, "test %s" % number)
            records.append(item)
            with open(results_path, "a", encoding="utf-8") as handle:
                handle.write(json.dumps(item, sort_keys=True) + "\n")
            print("  %s %s: %s" % ("PASS" if item["pass"] else item["status"].upper(), item["name"], item["reason"]), flush=True)
            if item["status"] == "stopped":
                break
        try:
            guard.final("end of run")
        except H10.RunStop as error:
            print("end-of-run check failed: %s" % error, flush=True)
    finally:
        server.stop()
        FE.clickyctl({"cmd": "markRegion", "clear": True}, 10)
        FE.clickyctl({"cmd": "boardDisplay", "clear": True}, 10)
        try:
            guard.settle("interrupted or stopped")
        except H10.RunStop as error:
            print("focus could not be restored: %s" % error, file=sys.stderr)
    diagnostics["end"] = wake_snapshot("end")
    with open(os.path.join(run_directory, "diagnostics.json"), "w", encoding="utf-8") as handle:
        json.dump(diagnostics, handle, indent=2, sort_keys=True)
    passed = write_outputs(run_directory, records)
    print("results: %s" % results_path)
    print("table:   %s" % os.path.join(run_directory, "results.md"))
    print("passed %d of %d" % (passed, len(records)))
    return 0


# ---------------------------------------------------------------------------
# Dry run: reads only. Pages, node --check, the synthetic WAV self-check, this checkout's inbox source.

def check_pages(problems):
    for name in ("search.html", "article_long.html"):
        path = os.path.join(PAGE_DIRECTORY, name)
        if not os.path.isfile(path):
            problems.append("page %s missing" % name)
            continue
        text = read_text(path)
        for marker in ('src="common.js"', "P8.publish("):
            if marker not in text:
                problems.append("%s lacks %s" % (name, marker))
    article = os.path.join(PAGE_DIRECTORY, "article_long.html")
    if os.path.isfile(article):
        text = read_text(article)
        if count_paragraphs(text) < ARTICLE_MIN_PARAGRAPHS:
            problems.append("article_long.html has %d paragraphs, need %d" % (count_paragraphs(text), ARTICLE_MIN_PARAGRAPHS))
        if count_facts(text) != FACT_COUNT:
            problems.append("article_long.html has %d data-fact paragraphs, need %d" % (count_facts(text), FACT_COUNT))


def check_page_javascript(problems, notes):
    node = shutil.which("node")
    if node is None:
        notes.append("node not found: JavaScript syntax check skipped")
        return
    scratch = tempfile.mkdtemp(prefix="p8-dry-")
    try:
        for name in sorted(os.listdir(PAGE_DIRECTORY)):
            if not name.endswith((".html", ".js")):
                continue
            text = read_text(os.path.join(PAGE_DIRECTORY, name))
            sources = [text] if name.endswith(".js") else re.findall(r"<script(?![^>]*\bsrc=)[^>]*>(.*?)</script>", text, re.S)
            for index, source in enumerate(sources):
                script = os.path.join(scratch, "%s-%d.js" % (name.replace(".", "_"), index))
                with open(script, "w", encoding="utf-8") as handle:
                    handle.write(source)
                completed = subprocess.run([node, "--check", script], capture_output=True, text=True)
                if completed.returncode != 0:
                    problems.append("JavaScript syntax in %s: %s" % (name, completed.stderr.strip()[:200]))
    finally:
        shutil.rmtree(scratch, ignore_errors=True)


def wav_self_check():
    """Synthetic 48 kHz float clips with 2 s gaps: the output length and header must match the plan."""
    clip_a = array.array("f", [0.5]) * SAMPLE_RATE
    clip_b = array.array("f", [-0.25]) * (SAMPLE_RATE // 2)
    wav = make_float_wav(concatenate_clips([clip_a, clip_b, clip_a], FOLLOW_UP_GAP_SECONDS))
    parsed = parse_wav(wav)
    expected = len(clip_a) * 2 + len(clip_b) + 2 * int(FOLLOW_UP_GAP_SECONDS * SAMPLE_RATE)
    ok = parsed["rate"] == SAMPLE_RATE and parsed["channels"] == 1 and parsed["format"] == 3 and len(parsed["samples"]) == expected
    return ok, "%d samples at %d Hz, %.1f s planned" % (len(parsed["samples"]), parsed["rate"], expected / SAMPLE_RATE)


def dry_run():
    problems, notes = [], []
    check_pages(problems)
    check_page_javascript(problems, notes)
    ok, wav_note = wav_self_check()
    if not ok:
        problems.append("WAV self-check failed: %s" % wav_note)
    print("dry run (reads only: pages, node --check, the synthetic WAV self-check, the inbox source; "
          "no app, Chrome, ask, audio, window or focus change; no wakeStatus or voiceCommand call)")
    print("WAV self-check: %s" % ("ok" if ok else "FAILED") + " (" + wav_note + ")")
    print("follow-up feed: %s" % " + ".join("%r" % text for text in FOLLOW_UP_SCRIPT) +
          " with %.0f s gaps (planned %.0f s with 1 s clips)" % (FOLLOW_UP_GAP_SECONDS, expected_duration_seconds([1.0] * len(FOLLOW_UP_SCRIPT))))
    present = {name: inbox_has(name) for name in DEBUG_COMMANDS}
    print("debug commands in this checkout: %s" % ", ".join(name for name, here in present.items() if here))
    missing = [name for name, here in present.items() if not here]
    if missing:
        notes.append("not in this checkout yet (the harness depends on them): %s" % ", ".join(missing))
    if "frontWindow" not in read_text(INBOX_SOURCE):
        notes.append("actionsRun has no frontWindow override: test 5 would skip")
    print("tests:")
    for number in ALL_IDS:
        plan = TESTS_PLAN[number]
        print("  %-3s %s" % (number, plan["name"]))
        print("      setup:   %s" % plan["setup"])
        print("      prompt:  %r" % plan["prompt"])
        print("      pass:    %s" % plan["pass"])
        print("      cleanup: %s" % plan["cleanup"])
    print("fast path: %s" % ", ".join("%r" % text for text, _ in FAST_PATH_CASES))
    print("fast path negatives: %s" % ", ".join("%r" % text for text in FAST_PATH_NEGATIVES))
    for note in notes:
        print("  note: " + note)
    if problems:
        print("PROBLEMS (%d):" % len(problems))
        for problem in problems:
            print("  - " + problem)
        return 1
    print("OK: %d tests, pages and JavaScript valid" % len(ALL_IDS))
    return 0


def main(argv):
    parser = argparse.ArgumentParser(description="P8 live tests for Clicky's voice path (see module docstring).")
    parser.add_argument("--dry-run", action="store_true", help="validate pages and print the plan; touch no app")
    parser.add_argument("--only", type=parse_only, help="test ids, e.g. 3 or 1,1b,4")
    parser.add_argument("--run", help="run name (default: timestamp)")
    args = parser.parse_args(argv)
    if args.dry_run:
        return dry_run()
    selected = args.only or list(ALL_IDS)
    run_name = args.run or datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
    return run_selected(selected, run_name)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
