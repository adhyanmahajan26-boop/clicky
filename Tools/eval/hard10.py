#!/usr/bin/env python3
"""Hard10: ten hard live tests for Clicky, run against the real app by hand.

Each test sets up a fixture (a local page in a Chrome window, System Settings,
a scratch git repo, or the owner's own screen), asks Clicky one prompt through
the debug inbox, and checks the turn record (turn.json, marks.jsonl) against
ground truth. The pass rule for each test is in its docstring and in TESTS.

Usage:
  python3 -I Tools/eval/hard10.py --dry-run          validate pages and fixtures; no app touched
  python3 -I Tools/eval/hard10.py --only 2,5 --run NAME
  python3 -I Tools/eval/hard10.py --side-origin X,Y  Chrome origin for test 6 (default: next to the side display)

Pause guard: before each setup and each ask, if the owner's HID idle time is
under 5 s the run waits until it reaches 120 s. Every pause is logged to
build/eval/hard10/<run>/pauses.jsonl.

Output: build/eval/hard10/<run>/results.jsonl and results.md.

Reused from final_eval.py: clickyctl, owner_idle_seconds, ChromeHarness (temp
profile, DevTools on 127.0.0.1), css_to_cg, axfind/resolve_truth, open_app,
read_turn, read_mark_events, the usage-limit backoff, and the hit rules.
"""

import argparse
import datetime
import importlib.util
import json
import math
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
PAGE_DIRECTORY = os.path.join(EVAL_DIRECTORY, "hard10")
RUNS_DIRECTORY = os.path.join(REPO_ROOT, "build", "eval", "hard10")
TURNS_DIRECTORY = os.path.expanduser("~/Library/Logs/Clicky/turns")
SCRATCH_REPO = os.path.expanduser("~/Projects/clicky-scratch")
SHOTS_DIRECTORY = os.path.expanduser("~/Desktop/Clicky Screenshots")
SETTINGS_BUNDLE = "com.apple.systempreferences"
SERVER_PORT = 8793
DEBUG_PORT_BASE = 9440
MAIN_ORIGIN = (200, 200)
MAIN_SIZE = (1100, 1000)
SIDE_SIZE = (1100, 800)
OWNER_ACTIVE_SECONDS = 5.0
OWNER_RESUME_SECONDS = 120.0
POINT_TOLERANCE_PT = 4.0
BOX_EDGE_TOLERANCE_PT = 8.0
LABEL_GAP_PT = 40.0
SCREENSHOT_TOLERANCE = 0.10
ASK_TIMEOUT_SECONDS = 420
BOX_KINDS = ("box", "rbox")
FINISHED_STATES = {"finished", "done", "complete", "completed", "succeeded"}
PAGE_FILES = ["common.js", "dense_table.html", "product_grid.html", "toolbar.html",
              "canvas_quarterly.html", "submit_form.html"]
LONG_QUESTION = ("explain in detail, step by step and in several paragraphs, how a transistor "
                 "amplifies a small signal into a larger one")
FOLLOW_UP = "quick one, what is the capital of France?"
CODE_PROMPT = "turn on code mode and in the clicky-scratch repo add a function multiply with a test"
SETTINGS_TRUTH_SECONDS = 20
# Sidebar rows on recent macOS are AXRow > AXCell > AXStaticText, and the sidebar is an
# AXOutline (or AXList). Search any role whose title/description/value contains "Wallpaper",
# first inside the sidebar container, then anywhere; report the nearest row/cell frame.
WALLPAPER_FINDERS = [
    dict({"role": "*", "title": "Wallpaper", "match": "contains", "within": {"role": container, "nth": 1}},
         **({"ancestor": ancestor} if ancestor else {}))
    for container in ("AXOutline", "AXList")
    for ancestor in ("AXRow", "AXCell", None)
] + [
    {"role": "*", "title": "Wallpaper", "match": "contains", "ancestor": "AXRow"},
    {"role": "*", "title": "Wallpaper", "match": "contains"},
]
BARGE_VOICE = "clicky-voice.wav"
CODE_START_SECONDS = 120
CODE_RUN_SECONDS = 600
CHROME_SETTLE_SECONDS = 1.5
NON_NODE_ELEMENTS = {"edge", "arrow", "list", "text", "section"}
PREFLIGHT_FAILURE_WORDS = ("off", "fail", "reject", "blocked", "missing", "not found", "unavailable", "error")
SCRATCH_FILES = {
    "utils.py": "def add(a, b):\n    return a + b\n",
    "tests/__init__.py": "",
    "tests/test_utils.py": (
        "import unittest\n\nfrom utils import add\n\n\nclass AddTests(unittest.TestCase):\n"
        "    def test_add(self):\n        self.assertEqual(add(2, 3), 5)\n\n\n"
        "if __name__ == '__main__':\n    unittest.main()\n"),
}


def load_module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


# final_eval.py is loaded by path because python3 -I leaves the script directory off sys.path.
FE = load_module("final_eval", os.path.join(EVAL_DIRECTORY, "final_eval.py"))


class TruthMissing(Exception):
    pass


class Skip(Exception):
    pass


# ---------------------------------------------------------------------------
# Pure checks (unit-tested in test_hard10.py).

def rect_edges_within(rect, frame, tolerance):
    """Each edge of rect (x, y, w, h) is within tolerance of the matching edge of frame."""
    x, y, width, height = rect
    fx, fy, fw, fh = frame
    pairs = [(x, fx), (y, fy), (x + width, fx + fw), (y + height, fy + fh)]
    return all(abs(first - second) <= tolerance for first, second in pairs)


def rect_gap(first, second):
    """Distance between two rects (0 when they touch or overlap)."""
    dx = max(second[0] - (first[0] + first[2]), first[0] - (second[0] + second[2]), 0.0)
    dy = max(second[1] - (first[1] + first[3]), first[1] - (second[1] + second[3]), 0.0)
    return math.hypot(dx, dy)


def point_hits_frame(point, frame, tolerance=POINT_TOLERANCE_PT):
    if not point:
        return False
    x, y, width, height = frame
    return (x - tolerance <= point[0] <= x + width + tolerance
            and y - tolerance <= point[1] <= y + height + tolerance)


def drawn_kind(tag):
    return (tag.get("drawn") or {}).get("kind")


def drawn_rect(tag):
    return (tag.get("drawn") or {}).get("rectCG")


def tag_anchor(tag):
    """CG point a tag points at: its cgPoint, else the centre of its drawn outline."""
    if tag.get("cgPoint"):
        return tag["cgPoint"]
    rect = drawn_rect(tag)
    if rect:
        return [rect[0] + rect[2] / 2.0, rect[1] + rect[3] / 2.0]
    return None


def box_tight(tag, frame, tolerance=BOX_EDGE_TOLERANCE_PT):
    """A box or rbox mark whose outline sits within 8 pt of every edge of the frame."""
    if drawn_kind(tag) not in BOX_KINDS or not drawn_rect(tag):
        return False
    return rect_edges_within(drawn_rect(tag), frame, tolerance)


def match_frames(frames, tags, rule):
    """Maximum bipartite match: frame index -> tag index, each tag used at most once."""
    candidates = [[index for index, tag in enumerate(tags) if rule(tag, frame)] for frame in frames]
    owner = {}

    def assign(frame_index, seen):
        for tag_index in candidates[frame_index]:
            if tag_index in seen:
                continue
            seen.add(tag_index)
            if tag_index not in owner or assign(owner[tag_index], seen):
                owner[tag_index] = frame_index
                return True
        return False

    for frame_index in range(len(frames)):
        assign(frame_index, set())
    return {frame_index: tag_index for tag_index, frame_index in owner.items()}


def note_of(raw):
    """The note after the bar in a legend-style mark, e.g. "[MARK:box:#76:id|wrong photo]"."""
    match = re.search(r"\|([^\]|]*)\]\s*$", raw or "")
    return match.group(1).strip() if match else ""


def dedupe_bubbles(events):
    """marks.jsonl bubble events grow while the label streams in; keep the last rect per left edge."""
    latest = {}
    for event in events or []:
        if event.get("event") == "bubble" and event.get("rectCG"):
            latest[round(event["rectCG"][0], 1)] = event["rectCG"]
    return list(latest.values())


def attached_label(tag):
    label = (tag.get("drawn") or {}).get("label") or tag.get("label")
    if isinstance(label, dict) and label.get("rectCG"):
        return label["rectCG"]
    return None


def assign_labels(anchor_rects, tags, bubbles):
    """Index-aligned label rect per tag. An attached label wins; otherwise the nearest
    unused bubble within LABEL_GAP_PT is taken (one bubble per tag)."""
    labels = [attached_label(tag) for tag in tags]
    free = list(bubbles)
    for index, anchor in enumerate(anchor_rects):
        if labels[index] is not None or anchor is None:
            continue
        best, best_gap = None, None
        for bubble_index, bubble in enumerate(free):
            gap = rect_gap(anchor, bubble)
            if gap <= LABEL_GAP_PT and (best_gap is None or gap < best_gap):
                best, best_gap = bubble_index, gap
        if best is not None:
            labels[index] = free.pop(best)
    return labels


def label_is_adjacent(anchor, label):
    return anchor is not None and label is not None and rect_gap(anchor, label) <= LABEL_GAP_PT


def check_dense(tags, targets, others, bubbles):
    """Test 1. targets/others: row name -> CG frame. Pass: exactly one underline on each
    target row (drawn underline rule), no underline on any other row, and each target
    has a note (legend text after the bar, or a label within 40 pt of its underline)."""
    underlines = [tag for tag in tags if drawn_kind(tag) == "underline"]
    names = list(targets)
    frames = [targets[name] for name in names]
    mapping = match_frames(frames, underlines, FE.drawn_rule)
    missing = [names[index] for index in range(len(names)) if index not in mapping]
    if missing:
        return False, "no underline on %s" % ", ".join(missing)
    for name, frame in others.items():
        if any(FE.drawn_rule(tag, frame) for tag in underlines):
            return False, "underline on %s, which is not a target" % name
    chosen = [underlines[mapping[index]] for index in range(len(names))]
    labels = assign_labels([drawn_rect(tag) for tag in chosen], chosen, bubbles)
    for index, tag in enumerate(chosen):
        if note_of(tag.get("raw")):
            continue
        if not label_is_adjacent(drawn_rect(tag), labels[index]):
            return False, "no note on %s" % names[index]
    return True, "%d underlines on the right rows, all noted" % len(names)


def check_boxes(tags, red_frames, bubbles):
    """Test 2. Pass: exactly one box/rbox mark per red card, each within 8 pt of every edge
    of its card (DevTools truth), no extra box marks, each with a label within 40 pt of its
    box, and each note contains the price (a digit)."""
    boxes = [tag for tag in tags if drawn_kind(tag) in BOX_KINDS]
    if len(boxes) != len(red_frames):
        return False, "%d box marks, want %d" % (len(boxes), len(red_frames))
    mapping = match_frames(red_frames, boxes, box_tight)
    if len(mapping) != len(red_frames):
        return False, "%d of %d red cards boxed within 8 pt" % (len(mapping), len(red_frames))
    chosen = [boxes[mapping[index]] for index in range(len(red_frames))]
    labels = assign_labels([drawn_rect(tag) for tag in chosen], chosen, bubbles)
    for index, tag in enumerate(chosen):
        if not label_is_adjacent(drawn_rect(tag), labels[index]):
            return False, "box %d has no label within 40 pt" % (index + 1)
        if not re.search(r"\d", note_of(tag.get("raw"))):
            return False, "box %d note has no price" % (index + 1)
    return True, "3 boxes tight to the red cards, labelled with prices"


def check_point(tags, frame):
    """Tests 3, 5 and 6. Pass: some tag's anchor point lies inside the frame grown by 4 pt."""
    if not tags:
        return False, "no tags"
    for tag in tags:
        if point_hits_frame(tag_anchor(tag), frame):
            return True, "point within 4 pt of the target"
    return False, "no point within 4 pt of the target"


def check_settings(tags, wallpaper_frame):
    """Test 4. Pass: at least two step marks, and the first lands on the sidebar Wallpaper item."""
    if len(tags) < 2:
        return False, "%d step marks, want at least 2" % len(tags)
    if not point_hits_frame(tag_anchor(tags[0]), wallpaper_frame):
        return False, "first step is not on the Wallpaper sidebar item"
    return True, "%d steps, first on Wallpaper" % len(tags)


def point_in_bounds(point, bounds):
    return bounds[0] <= point[0] < bounds[0] + bounds[2] and bounds[1] <= point[1] < bounds[1] + bounds[3]


def is_main_screen(screen):
    """The main display is the one at origin 0,0 (or the one the turn's header marks as main)."""
    bounds = screen.get("boundsCG") or [None, None]
    return (list(bounds[:2]) == [0, 0]) or "(main" in str(screen.get("header", ""))


def screen_under_frame(frame, screens):
    """The screen from this turn whose boundsCG holds the frame's centre, or None."""
    centre = [frame[0] + frame[2] / 2.0, frame[1] + frame[3] / 2.0]
    for screen in screens or []:
        if screen.get("boundsCG") and point_in_bounds(centre, screen["boundsCG"]):
            return screen
    return None


def check_side(tags, frame, screens):
    """Test 6. Pass: the frame's centre lies on a non-main screen of the same turn (screens =
    that turn's boundsCG list), and a tag points at the frame within 4 pt."""
    screen = screen_under_frame(frame, screens)
    if screen is None or is_main_screen(screen):
        return False, "Submit frame %s is not on the side display (centre off every non-main screen)" % (frame,)
    passed, reason = check_point(tags, frame)
    return passed, "%s; frame on %s" % (reason, (screen.get("header") or "side display")[:40])


def png_size(path):
    """(width, height) from a PNG's IHDR chunk, or None."""
    with open(path, "rb") as handle:
        head = handle.read(24)
    if len(head) < 24 or head[:8] != b"\x89PNG\r\n\x1a\n" or head[12:16] != b"IHDR":
        return None
    return struct.unpack(">II", head[16:24])


def size_matches(actual, expected, tolerance=SCREENSHOT_TOLERANCE):
    return all(abs(a - e) <= tolerance * e for a, e in zip(actual, expected))


def screenshot_matches_window(png, window_points, dpr):
    """Test 7. The PNG's pixel size must match the window's size in points, times 1 or the
    display scale, within 10 %."""
    for scale in sorted({1.0, float(dpr or 1.0)}):
        if size_matches(png, (window_points[0] * scale, window_points[1] * scale)):
            return True
    return False


def snapshot_paths(turn, started_at):
    """Paths the turn reports (a "snaps" array with "path"), else PNGs in the shots folder written since start."""
    paths = []
    for snap in ((turn or {}).get("snaps") or []) + ((turn or {}).get("snapshots") or []):
        if isinstance(snap, dict) and snap.get("path"):
            paths.append(snap["path"])
    if not paths and os.path.isdir(SHOTS_DIRECTORY):
        for name in sorted(os.listdir(SHOTS_DIRECTORY)):
            full = os.path.join(SHOTS_DIRECTORY, name)
            if name.lower().endswith(".png") and os.path.getmtime(full) >= started_at - 1:
                paths.append(full)
    return paths


def whiteboard_node_ids(raw_response):
    """Distinct ids of the node elements in the <whiteboard> JSONL of an answer. Node elements
    are every "el" except edge, arrow, list, text and section; a line with no id counts once."""
    match = re.search(r"<whiteboard>(.*?)</whiteboard>", raw_response or "", re.S)
    if not match:
        return set()
    ids = set()
    for line_index, line in enumerate(match.group(1).splitlines()):
        line = line.strip()
        if not line.startswith("{"):
            continue
        try:
            element = json.loads(line)
        except ValueError:
            continue
        if not isinstance(element, dict) or "el" not in element or element["el"] in NON_NODE_ELEMENTS:
            continue
        ids.add(str(element.get("id", "#line%d" % line_index)))
    return ids


def check_board(turn):
    """Test 8. Pass: the board was played (boardEvents non-empty) and the board itself holds at
    least four distinct node elements (counted from the <whiteboard> JSONL in rawResponse)."""
    if not (turn or {}).get("boardEvents"):
        return False, "boardEvents is empty: the board was not played"
    nodes = whiteboard_node_ids((turn or {}).get("rawResponse"))
    if len(nodes) < 4:
        return False, "%d board nodes, want at least 4" % len(nodes)
    return True, "%d board nodes (%s)" % (len(nodes), ", ".join(sorted(nodes)))


def reports_finished(value):
    """True when a codeStatus reply (any nesting) reports a finished task."""
    if isinstance(value, dict):
        for key, item in value.items():
            if key in ("finished", "done", "complete") and item is True:
                return True
            if key in ("state", "status", "phase") and isinstance(item, str) and item.lower() in FINISHED_STATES:
                return True
            if reports_finished(item):
                return True
    elif isinstance(value, list):
        return any(reports_finished(item) for item in value)
    return False


def check_code(finished, diff_text, test_diff_text, unittest_returncode):
    """Test 9. Pass: codeStatus reports finished, the scratch diff has def multiply and a test
    that names multiply, and python3 -m unittest passes in that worktree."""
    if not finished:
        return False, "codeStatus never reported a finished task"
    if "def multiply" not in diff_text:
        return False, "no def multiply in the scratch diff"
    if "multiply" not in test_diff_text:
        return False, "no multiply test in the scratch diff"
    if unittest_returncode != 0:
        return False, "python3 -m unittest failed (rc %s)" % unittest_returncode
    return True, "multiply and its test are in the diff; unittest passes"


def status_snapshot(reply):
    """The codeStatus snapshot from a clickyctl reply ({ok, result, ...}) or a bare snapshot."""
    if isinstance(reply, dict) and isinstance(reply.get("result"), dict):
        return reply["result"]
    return reply if isinstance(reply, dict) else {}


def preflight_failed(line):
    """True when the code preflight line reads as a failure (e.g. "Off: plugins load in headless runs")."""
    text = str(line or "").strip().lower()
    if text.startswith("off"):
        return True
    return any(word in text for word in PREFLIGHT_FAILURE_WORDS if word != "off")


def code_progress(reply):
    """(verdict, reason) for one codeStatus poll. verdict is "finished" (not busy, the review panel
    shows a task whose worktree is ready), "running" (busy or a task is live), or "waiting".
    A finished review needs a worktree path, so an idle panel with no task is still "waiting"."""
    snap = status_snapshot(reply)
    review = snap.get("review") if isinstance(snap.get("review"), dict) else None
    busy = bool(snap.get("busy"))
    if busy or (snap.get("task") and not review):
        return "running", "busy: phase %s" % snap.get("phase")
    if reports_finished(snap) or (not busy and snap.get("panelMode") == "review" and review and review.get("worktree")):
        return "finished", "review ready in %s" % (review or {}).get("worktree")
    return "waiting", "phase %s, panel %s, task %s" % (snap.get("phase"), snap.get("panelMode"), "set" if snap.get("task") else "none")


SPEECH_VOICE_KEYS = ("voice", "referenceVoice", "reference", "voiceId", "referenceId")


def speech_identity(turn):
    speech = (turn or {}).get("speech") or {}
    voice = None
    for key in SPEECH_VOICE_KEYS:
        if speech.get(key) is not None:
            voice = speech[key]
            break
    return {"engine": speech.get("engine"), "fallback": bool(speech.get("fallback")), "voice": voice}


def find_key(value, name):
    """First value stored under name anywhere in a reply (any nesting), or None."""
    if isinstance(value, dict):
        if name in value and value[name] is not None:
            return value[name]
        for item in value.values():
            found = find_key(item, name)
            if found is not None:
                return found
    elif isinstance(value, list):
        for item in value:
            found = find_key(item, name)
            if found is not None:
                return found
    return None


def speaking_info(state):
    """From a speechState reply sampled while speaking: whether speech was seen playing, and the
    engine and fallback flag when the app reports them (the first turn of a barge-in is cancelled,
    so its turn.json may carry no engine)."""
    return {"seen": probe_flag(state, ("speaking", "isSpeaking", "playing", "audioPlaying", "isPlaying")),
            "engine": find_key(state, "engine"),
            "fallback": bool(find_key(state, "fallback"))}


def check_barge(first_turn, second_turn, speaking):
    """Test 10. The follow-up must be qwen with no fallback on the clicky-voice.wav reference. The
    first (cancelled) turn must be qwen when its speech shows it, or else speech must have been seen
    playing before the barge-in (speaking, from speaking_info) with no fallback flag."""
    speaking = speaking or {}
    first, second = speech_identity(first_turn), speech_identity(second_turn)
    if second["engine"] != "qwen":
        return False, "follow-up engine %s, want qwen" % second["engine"]
    if second["fallback"]:
        return False, "follow-up used fallback speech"
    if second["voice"] != BARGE_VOICE:
        return False, "follow-up reference voice %r, want %s" % (second["voice"], BARGE_VOICE)
    if first["fallback"] or speaking.get("fallback"):
        return False, "first turn used fallback speech"
    first_engine = first["engine"] or speaking.get("engine")
    if first_engine is None:
        if not speaking.get("seen"):
            return False, "first turn engine not recorded and no speech seen playing before the barge-in"
        note = "first turn engine not in turn.json; speech was playing before the barge-in, no fallback"
    elif first_engine != "qwen":
        return False, "first turn engine %s, want qwen" % first_engine
    else:
        note = "first turn qwen"
    if first["voice"] not in (None, BARGE_VOICE):
        return False, "first turn reference voice %r, want %s" % (first["voice"], BARGE_VOICE)
    return True, "follow-up qwen on %s; %s" % (BARGE_VOICE, note)


def key_up_to_first_audio_ms(turn):
    timings = (turn or {}).get("timings") or {}
    if "keyUp" in timings and "firstAudio" in timings:
        return round((timings["firstAudio"] - timings["keyUp"]) * 1000.0, 1)
    return None


def probe_flag(value, names):
    """True when a reply (any nesting) sets one of names to true, e.g. speaking."""
    if isinstance(value, dict):
        for key, item in value.items():
            if key in names and item is True:
                return True
            if probe_flag(item, names):
                return True
    elif isinstance(value, list):
        return any(probe_flag(item, names) for item in value)
    return False


# ---------------------------------------------------------------------------
# Owner pause guard, asks, and records.

class Context:
    def __init__(self, run_directory, server, side_origin=None):
        self.run_directory = run_directory
        self.pauses_path = os.path.join(run_directory, "pauses.jsonl")
        self.server = server
        self.side_origin = side_origin
        self.paused_total = 0.0


def append_jsonl(path, record):
    with open(path, "a", encoding="utf-8") as handle:
        handle.write(json.dumps(record, sort_keys=True) + "\n")


def wait_owner_idle(ctx):
    """Before a setup or an ask: if the owner used the Mac in the last 5 s, wait until 120 s idle."""
    idle = FE.owner_idle_seconds()
    if idle is None or idle >= OWNER_ACTIVE_SECONDS:
        return 0.0
    started = time.time()
    print("  owner is active (idle %.1f s); pausing until idle %d s" % (idle, OWNER_RESUME_SECONDS), flush=True)
    while True:
        time.sleep(5)
        idle = FE.owner_idle_seconds()
        if idle is None or idle >= OWNER_RESUME_SECONDS:
            break
    paused = time.time() - started
    ctx.paused_total += paused
    append_jsonl(ctx.pauses_path, {"start": round(started, 1), "seconds": round(paused, 1)})
    print("  resumed after %.0f s" % paused, flush=True)
    return paused


def ask(ctx, prompt):
    """ask{speak:true} through the debug inbox, with the owner guard before each try and
    final_eval's usage-limit backoff. Returns (reply, turn)."""
    waits = FE.backoff_schedule()
    while True:
        wait_owner_idle(ctx)
        reply = FE.clickyctl({"cmd": "ask", "text": prompt, "speak": True}, ASK_TIMEOUT_SECONDS)
        turn = FE.read_turn(reply.get("turnDir"))
        error_text = str(reply.get("error") or "")
        if turn and turn.get("error"):
            error_text += " " + str(turn["error"])
        if not FE.is_usage_limit_error(error_text):
            return reply, turn
        if not waits:
            raise FE.UsageLimitStop(error_text[:200])
        wait_seconds = waits.pop(0)
        print("  usage limit (%s); waiting %d s" % (error_text[:80], wait_seconds), flush=True)
        time.sleep(wait_seconds)


def record(number, status, passed, reason, turn_dir=None, turn=None, extra=None):
    return {
        "test": number,
        "name": TEST_NAMES[number],
        "status": status,
        "pass": bool(passed) and status == "scored",
        "reason": reason,
        "keyUpToFirstAudioMs": key_up_to_first_audio_ms(turn),
        "turnDir": turn_dir,
        "extra": extra or {},
    }


def score(ctx, number, reply, turn, check):
    """check(turn, bubbles) -> (passed, reason). Missing turn records are a failed run, not a pass."""
    turn_dir = reply.get("turnDir")
    if turn is None:
        return record(number, "no-turn", False, "no turn record: %s" % (reply.get("error") or "no turnDir"))
    if turn.get("error"):
        return record(number, "error", False, "turn error: %s" % str(turn["error"])[:200], turn_dir, turn)
    bubbles = dedupe_bubbles(FE.read_mark_events(turn_dir))
    passed, reason = check(turn, bubbles)
    return record(number, "scored", passed, reason, turn_dir, turn, {"tags": len(turn.get("tags") or [])})


def cg_frames(window, truth, keys):
    return {key: FE.css_to_cg(truth["items"][key], window) for key in keys}


def frontmost_script(pid, activate=True):
    """AppleScript for the one Chrome process with this pid. Only sets or reads its frontmost
    flag; no clicks, keystrokes or window moves."""
    if activate:
        return 'tell application "System Events" to set frontmost of (first process whose unix id is %d) to true' % pid
    return 'tell application "System Events" to return frontmost of (first process whose unix id is %d)' % pid


def bring_chrome_front(harness):
    """Activates this harness's Chrome window (by pid) and reads back that it is frontmost."""
    pid = harness.process.pid
    try:
        subprocess.run(["osascript", "-e", frontmost_script(pid)], capture_output=True, text=True, timeout=10)
        read = subprocess.run(["osascript", "-e", frontmost_script(pid, activate=False)], capture_output=True, text=True, timeout=10)
        return read.returncode == 0 and read.stdout.strip() == "true"
    except (OSError, subprocess.TimeoutExpired):
        return False


def open_chrome_page(ctx, number, page, origin, size):
    """Owner guard, then a Chrome app window on origin, loaded with the page. The window is made
    frontmost and given CHROME_SETTLE_SECONDS after the page reports its truth, before any ask.
    Returns (harness, state, window, truth)."""
    wait_owner_idle(ctx)
    harness = FE.ChromeHarness(DEBUG_PORT_BASE + number, origin, size)
    try:
        state = harness.load(ctx.server.url("/" + page))
    except Exception:
        harness.stop()
        raise
    truth = state.get("truth") or {}
    if not truth.get("items"):
        harness.stop()
        raise TruthMissing("%s published no truth items" % page)
    harness.frontmost = bring_chrome_front(harness)
    time.sleep(CHROME_SETTLE_SECONDS)
    window = {"bounds": state["bounds"], "innerWidth": state["innerWidth"], "innerHeight": state["innerHeight"]}
    return harness, state, window, truth


# ---------------------------------------------------------------------------
# The ten tests. Each returns one record.

PROMPTS = {
    1: "mark rows Alpha, Delta, Kilo and Papa and note what's wrong with each",
    2: "box the three red products and note their prices",
    3: "point at the share button",
    4: "how do I change my wallpaper",
    5: "point at the word 'Quarterly'",
    6: "point at the Submit button",
    7: "take a screenshot of this window",
    8: "explain how DNS resolution works with a diagram",
    9: CODE_PROMPT,
    10: LONG_QUESTION,
}


def test_1_dense_table(ctx):
    """Dense Notion-style table, 18 rows. Pass: underline on each of Alpha, Delta, Kilo, Papa
    (and no other row), each with a note."""
    harness, _, window, truth = open_chrome_page(ctx, 1, "dense_table.html", MAIN_ORIGIN, MAIN_SIZE)
    try:
        frames = {key.split("_", 1)[1].capitalize(): frame
                  for key, frame in cg_frames(window, truth, truth["items"].keys()).items()}
        wanted = ["Alpha", "Delta", "Kilo", "Papa"]
        targets = {name: frames[name] for name in wanted}
        others = {name: frame for name, frame in frames.items() if name not in wanted}
        reply, turn = ask(ctx, PROMPTS[1])
        result = score(ctx, 1, reply, turn, lambda t, b: check_dense(t.get("tags") or [], targets, others, b))
        result["extra"]["chromeFrontmost"] = harness.frontmost
        return result
    finally:
        harness.stop()


def test_2_product_boxes(ctx):
    """Product grid, 9 cards, 3 red. Pass: one box/rbox per red card, within 8 pt of the card
    edges (DevTools truth), each labelled within 40 pt, each note with a price."""
    harness, _, window, truth = open_chrome_page(ctx, 2, "product_grid.html", MAIN_ORIGIN, MAIN_SIZE)
    try:
        red_keys = truth.get("red") or []
        red_frames = [FE.css_to_cg(truth["items"][key], window) for key in red_keys]
        reply, turn = ask(ctx, PROMPTS[2])
        result = score(ctx, 2, reply, turn, lambda t, b: check_boxes(t.get("tags") or [], red_frames, b))
        result["extra"]["chromeFrontmost"] = harness.frontmost
        return result
    finally:
        harness.stop()


def test_3_icon_button(ctx):
    """16 px icon toolbar. Pass: a point lands inside the Share button frame plus 4 pt."""
    harness, _, window, truth = open_chrome_page(ctx, 3, "toolbar.html", MAIN_ORIGIN, MAIN_SIZE)
    try:
        frame = FE.css_to_cg(truth["items"]["share"], window)
        reply, turn = ask(ctx, PROMPTS[3])
        return score(ctx, 3, reply, turn, lambda t, b: check_point(t.get("tags") or [], frame))
    finally:
        harness.stop()


def resolve_wallpaper_truth(timeout_seconds=SETTINGS_TRUTH_SECONDS):
    """First WALLPAPER_FINDERS entry that resolves, polling until the sidebar is up.
    Returns (frame, finder, error)."""
    deadline = time.time() + timeout_seconds
    error = "no finder tried"
    while True:
        for finder in WALLPAPER_FINDERS:
            frames, _, found_error = FE.resolve_truth([finder], SETTINGS_BUNDLE)
            if frames:
                return frames[0], finder, None
            error = found_error
        if time.time() >= deadline:
            return None, None, error
        time.sleep(2)


def test_4_settings_steps(ctx):
    """System Settings, read-only (opened, never clicked by the harness). Pass: at least two
    step marks, the first on the sidebar Wallpaper item (axfind truth, any of WALLPAPER_FINDERS)."""
    if not FE.app_installed("System Settings"):
        raise Skip("System Settings is not installed")
    wait_owner_idle(ctx)
    if not FE.open_app("System Settings"):
        raise Skip("could not open System Settings")
    time.sleep(3)
    frame, finder, error = resolve_wallpaper_truth()
    if frame is None:
        raise TruthMissing("truth: no Wallpaper sidebar item after %d s (%s)" % (SETTINGS_TRUTH_SECONDS, error))
    reply, turn = ask(ctx, PROMPTS[4])
    result = score(ctx, 4, reply, turn, lambda t, b: check_settings(t.get("tags") or [], frame))
    result["extra"]["truthFinder"] = finder
    result["extra"]["truthFrameCG"] = frame
    return result


def test_5_canvas_text(ctx):
    """Canvas-only text. Pass: a point lands inside the ink box of 'Quarterly' plus 4 pt."""
    harness, _, window, truth = open_chrome_page(ctx, 5, "canvas_quarterly.html", MAIN_ORIGIN, MAIN_SIZE)
    try:
        frame = FE.css_to_cg(truth["items"]["quarterly"], window)
        reply, turn = ask(ctx, PROMPTS[5])
        return score(ctx, 5, reply, turn, lambda t, b: check_point(t.get("tags") or [], frame))
    finally:
        harness.stop()


def find_side_display():
    """bounds [x, y, w, h] of a display that is not the main one (main has origin 0,0), from the
    screens recorded in recent turns. None when no turn has shown a side display yet."""
    if not os.path.isdir(TURNS_DIRECTORY):
        return None
    for name in sorted(os.listdir(TURNS_DIRECTORY), reverse=True)[:30]:
        turn = FE.read_turn(os.path.join(TURNS_DIRECTORY, name))
        for screen in (turn or {}).get("screens") or []:
            bounds = screen.get("boundsCG")
            if bounds and list(bounds[:2]) != [0, 0]:
                return bounds
    return None


def test_6_side_display(ctx):
    """Chrome window on a non-main display. Pass: a point lands on the Submit button, which
    is on that display."""
    side = find_side_display()
    if side is None:
        raise Skip("no side display seen in turn records (ask Clicky once with the side display attached)")
    origin = ctx.side_origin or (side[0] + 100, side[1] + 100)
    harness, _, window, truth = open_chrome_page(ctx, 6, "submit_form.html", origin, SIDE_SIZE)
    try:
        frame = FE.css_to_cg(truth["items"]["submit"], window)
        reply, turn = ask(ctx, PROMPTS[6])
        # The screens come from the scored turn itself, not from an earlier one.
        return score(ctx, 6, reply, turn, lambda t, b: check_side(t.get("tags") or [], frame, t.get("screens") or []))
    finally:
        harness.stop()


def test_7_screenshot(ctx):
    """Window screenshot. Pass: a snap with a path (or a new PNG in the shots folder), PNG
    size matches the window size within 10 %."""
    harness, state, _, _ = open_chrome_page(ctx, 7, "product_grid.html", MAIN_ORIGIN, MAIN_SIZE)
    try:
        started = time.time()
        reply, turn = ask(ctx, PROMPTS[7])
        if turn is None:
            return record(7, "no-turn", False, "no turn record: %s" % (reply.get("error") or "no turnDir"))
        window_points = (state["bounds"]["width"], state["bounds"]["height"])
        dpr = state.get("dpr") or 1.0
        for path in snapshot_paths(turn, started):
            size = png_size(path) if os.path.exists(path) else None
            if size and screenshot_matches_window(size, window_points, dpr):
                return record(7, "scored", True, "PNG %dx%d matches the window %sx%s pt" % (size[0], size[1], window_points[0], window_points[1]), reply.get("turnDir"), turn, {"png": path})
        return record(7, "scored", False, "no matching PNG (candidates %d)" % len(snapshot_paths(turn, started)), reply.get("turnDir"), turn)
    finally:
        harness.stop()


def test_8_whiteboard(ctx):
    """Whiteboard. Pass: turn.json boardEvents is non-empty and holds at least four nodes."""
    wait_owner_idle(ctx)
    reply, turn = ask(ctx, PROMPTS[8])
    return score(ctx, 8, reply, turn, lambda t, b: check_board(t))


def ensure_scratch_repo(path=SCRATCH_REPO):
    """Creates the clicky-scratch repo (git init, utils.py, tests/test_utils.py, one commit) when
    missing. Returns the HEAD sha."""
    if os.path.isdir(os.path.join(path, ".git")):
        return git_output(path, ["rev-parse", "HEAD"]).strip()
    if os.path.exists(path):
        raise RuntimeError("%s exists but is not a git repo" % path)
    os.makedirs(path)
    for relative, text in SCRATCH_FILES.items():
        full = os.path.join(path, relative)
        os.makedirs(os.path.dirname(full), exist_ok=True)
        with open(full, "w", encoding="utf-8") as handle:
            handle.write(text)
    git_output(path, ["init", "-q"])
    git_output(path, ["add", "-A"])
    git_output(path, ["-c", "user.name=Clicky hard10", "-c", "user.email=hard10@localhost",
                      "commit", "-q", "-m", "scratch base\n\nCo-Authored-By: Claude Haiku 5.5 <noreply@anthropic.com>"])
    return git_output(path, ["rev-parse", "HEAD"]).strip()


def git_output(path, arguments):
    completed = subprocess.run(["git", "-C", path] + arguments, capture_output=True, text=True, timeout=60)
    if completed.returncode != 0:
        raise RuntimeError("git %s: %s" % (" ".join(arguments), completed.stderr.strip()[:200]))
    return completed.stdout


def worktree_changes(base_sha, paths=None):
    """(path, combined diff text, test-file diff text) for the given worktree paths, or for every
    worktree of the scratch repo when none are given."""
    if paths is None:
        listing = git_output(SCRATCH_REPO, ["worktree", "list", "--porcelain"])
        paths = [line[len("worktree "):] for line in listing.splitlines() if line.startswith("worktree ")]
    changes = []
    for path in paths:
        diff = git_output(path, ["diff", base_sha])
        test_diff = git_output(path, ["diff", base_sha, "--", "tests"])
        for relative in git_output(path, ["ls-files", "--others", "--exclude-standard"]).split():
            try:
                with open(os.path.join(path, relative), encoding="utf-8", errors="replace") as handle:
                    text = handle.read()
            except OSError:
                continue
            diff += "\n+++ %s\n%s" % (relative, text)
            if relative.startswith("tests"):
                test_diff += "\n+++ %s\n%s" % (relative, text)
        changes.append((path, diff, test_diff))
    return changes


def test_9_code_mode(ctx):
    """Code mode in clicky-scratch. The ask may carry [CODEMODE:on]; the app then re-asks the
    original request itself and a code task starts after a 2 s "Opening" countdown. Poll codeStatus
    for up to CODE_RUN_SECONDS after the ask. Pass: codeStatus reports a finished task (review panel
    with a worktree, not busy); the worktree diff has def multiply and a test naming multiply; and
    python3 -m unittest passes in that worktree. Nothing is approved or pushed by the harness."""
    base_sha = ensure_scratch_repo()
    reply, turn = ask(ctx, PROMPTS[9])
    asked_at = time.time()
    finished, preflight_reason, last_snap, last_reason = False, None, {}, "no poll"
    started = False
    while time.time() < asked_at + CODE_RUN_SECONDS:
        status = FE.clickyctl({"cmd": "codeStatus"}, 30)
        if status.get("ok") is False and "unknown" in str(status.get("error", "")).lower():
            raise TruthMissing("codeStatus is not in this build: %s" % str(status.get("error"))[:120])
        last_snap = status_snapshot(status)
        verdict, last_reason = code_progress(status)
        if verdict == "running":
            started = True
        if verdict == "finished":
            finished = True
            break
        if not started and time.time() - asked_at > CODE_START_SECONDS:
            if preflight_failed(last_snap.get("preflight")):
                preflight_reason = "preflight: %s" % last_snap.get("preflight")
            break
        time.sleep(5)
    review = last_snap.get("review") if isinstance(last_snap.get("review"), dict) else {}
    worktree = review.get("worktree") if finished else None
    branch = None
    if worktree and os.path.isdir(worktree):
        branch = git_output(worktree, ["rev-parse", "--abbrev-ref", "HEAD"]).strip()
    diff_text, test_text, returncode = "", "", None
    for path, diff, test_diff in worktree_changes(base_sha, [worktree] if worktree else None):
        if "def multiply" in diff or worktree:
            diff_text, test_text = diff, test_diff
            run = subprocess.run([sys.executable, "-m", "unittest"], cwd=path, capture_output=True, text=True, timeout=120)
            returncode = run.returncode
            break
    if returncode is None:
        returncode = 1
    if not finished:
        reason = preflight_reason or "codeStatus never reported a finished task (last: %s)" % last_reason
        passed = False
    else:
        passed, reason = check_code(finished, diff_text, test_text, returncode)
    extra = {"codeStatus": last_snap, "worktree": worktree, "branch": branch, "codeToggled": "[CODEMODE:on" in str((turn or {}).get("rawResponse") or "")}
    if turn is None:
        return record(9, "no-turn", False, "no turn record: %s" % (reply.get("error") or "no turnDir"), extra=extra)
    return record(9, "scored", passed, reason, reply.get("turnDir"), turn, extra)


def wait_for_speaking(timeout_seconds):
    """Polls speechState until speech is seen playing. Returns speaking_info(state) for that poll
    (seen, engine, fallback) or {"seen": False} on timeout."""
    deadline = time.time() + timeout_seconds
    while time.time() < deadline:
        state = FE.clickyctl({"cmd": "speechState"}, 15)
        info = speaking_info(state)
        if info["seen"]:
            return info
        time.sleep(0.3)
    return {"seen": False, "engine": None, "fallback": False}


def test_10_barge_in(ctx):
    """Barge-in during speech. Pass: the follow-up answers (Paris) on qwen with clicky-voice.wav and
    no fallback, and the first (cancelled) turn is qwen or was seen speaking with no fallback (see
    check_barge). Records the follow-up's keyUp to firstAudio."""
    wait_owner_idle(ctx)
    long_ask = subprocess.Popen([FE.CLICKYCTL, json.dumps({"cmd": "ask", "text": LONG_QUESTION, "speak": True}),
                                 str(ASK_TIMEOUT_SECONDS)], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
    try:
        speaking = wait_for_speaking(180)
        if not speaking["seen"]:
            long_ask.kill()
            return record(10, "error", False, "no speech started within 180 s")
        barge = FE.clickyctl({"cmd": "bargeIn"}, 30)
        long_out, _ = long_ask.communicate(timeout=ASK_TIMEOUT_SECONDS + 30)
    except Exception:
        long_ask.kill()
        raise
    first_reply = json.loads(long_out.strip() or "{}")
    first_turn = FE.read_turn(first_reply.get("turnDir"))
    if first_turn is None:
        return record(10, "no-turn", False, "first turn missing after bargeIn (%s)" % str(barge)[:120])
    reply, second_turn = ask(ctx, FOLLOW_UP)
    if second_turn is None:
        return record(10, "no-turn", False, "follow-up turn missing: %s" % (reply.get("error") or "no turnDir"), reply.get("turnDir"), first_turn)
    speech_state = FE.clickyctl({"cmd": "speechState"}, 15)
    answered = "paris" in str(second_turn.get("rawResponse") or "").lower()
    same, reason = check_barge(first_turn, second_turn, speaking)
    passed = answered and same
    if not answered:
        reason = "follow-up did not answer (no Paris)"
    return record(10, "scored", passed, reason, reply.get("turnDir"), second_turn,
                  {"firstTurnDir": first_reply.get("turnDir"), "speaking": speaking, "speechState": speech_state,
                   "speech": [speech_identity(first_turn), speech_identity(second_turn)],
                   "followUpKeyUpToFirstAudioMs": key_up_to_first_audio_ms(second_turn)})


TEST_NAMES = {
    1: "Dense table: four row underlines with notes",
    2: "Product grid: three red boxes with price notes",
    3: "Icon-only toolbar: point at share",
    4: "System Settings: multi-step wallpaper",
    5: "Canvas text: point at 'Quarterly'",
    6: "Side display: point at Submit",
    7: "Screenshot of this window",
    8: "Whiteboard: DNS diagram with 4+ nodes",
    9: "Code mode: multiply and test in clicky-scratch",
    10: "Barge-in: follow-up on the same qwen voice",
}

TESTS = {
    1: test_1_dense_table, 2: test_2_product_boxes, 3: test_3_icon_button, 4: test_4_settings_steps,
    5: test_5_canvas_text, 6: test_6_side_display, 7: test_7_screenshot, 8: test_8_whiteboard,
    9: test_9_code_mode, 10: test_10_barge_in,
}

PAGE_OF = {1: "dense_table.html", 2: "product_grid.html", 3: "toolbar.html", 4: None, 5: "canvas_quarterly.html",
           6: "submit_form.html", 7: "product_grid.html", 8: None, 9: None, 10: None}


# ---------------------------------------------------------------------------
# Server, runs, and reports.

class PageServer:
    """python3 -I -m http.server on 127.0.0.1 over Tools/eval/hard10."""

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


def write_report(run_directory, records):
    lines = ["# Hard10 results", "", "| # | Test | Result | Pass | keyUp to firstAudio (ms) | Paused (s) | Detail |",
             "|---|---|---|---|---|---|---|"]
    for item in sorted(records, key=lambda r: r["test"]):
        latency = "" if item.get("keyUpToFirstAudioMs") is None else "%.0f" % item["keyUpToFirstAudioMs"]
        lines.append("| %d | %s | %s | %s | %s | %.0f | %s |" % (
            item["test"], item["name"], item["status"], "yes" if item["pass"] else "no", latency,
            item.get("pausedSeconds", 0.0), str(item["reason"]).replace("|", "/")))
    passed = sum(1 for item in records if item["pass"])
    lines += ["", "Passed %d of %d." % (passed, len(records))]
    with open(os.path.join(run_directory, "results.md"), "w", encoding="utf-8") as handle:
        handle.write("\n".join(lines) + "\n")
    return passed


def leftover_harness_state():
    """Chrome processes still running from this harness (temp profiles) and profile dirs not yet deleted."""
    processes = subprocess.run(["pgrep", "-fl", "clicky-eval-chrome-"], capture_output=True, text=True).stdout.strip()
    profiles = [name for name in os.listdir(tempfile.gettempdir()) if name.startswith("clicky-eval-chrome-")]
    return processes, profiles


def run_selected(selected, run_name, side_origin):
    run_directory = os.path.join(RUNS_DIRECTORY, run_name)
    os.makedirs(run_directory, exist_ok=True)
    results_path = os.path.join(run_directory, "results.jsonl")
    if not FE.clickyctl({"cmd": "ping"}, 10).get("ok"):
        print("Clicky does not answer ping on the debug inbox; start the debug build first.", file=sys.stderr)
        return 1
    server = PageServer(SERVER_PORT)
    ctx = Context(run_directory, server, side_origin)
    records = []
    try:
        for number in selected:
            print("test %d: %s" % (number, TEST_NAMES[number]), flush=True)
            paused_before = ctx.paused_total
            stop_run = False
            try:
                item = TESTS[number](ctx)
            except FE.UsageLimitStop as error:
                item = record(number, "error", False, "usage limit, run stopped: %s" % error)
                stop_run = True
            except (TruthMissing, Skip) as error:
                item = record(number, "truth-missing" if isinstance(error, TruthMissing) else "skipped", False, str(error))
            except Exception as error:
                item = record(number, "error", False, "%s: %s" % (type(error).__name__, str(error)[:200]))
            item["pausedSeconds"] = round(ctx.paused_total - paused_before, 1)
            records.append(item)
            with open(results_path, "a", encoding="utf-8") as handle:
                handle.write(json.dumps(item, sort_keys=True) + "\n")
            print("  %s %s: %s" % ("PASS" if item["pass"] else item["status"].upper(), item["name"], item["reason"]), flush=True)
            if stop_run:
                break
    finally:
        server.stop()
    passed = write_report(run_directory, records)
    processes, profiles = leftover_harness_state()
    print("results: %s" % results_path)
    print("table:   %s" % os.path.join(run_directory, "results.md"))
    print("passed %d of %d" % (passed, len(records)))
    print("leftover Chrome processes from this harness: %s" % (processes or "none"))
    print("leftover temp profiles: %s" % (", ".join(profiles) or "none"))
    return 0


# ---------------------------------------------------------------------------
# Dry run: validates the pages, the scratch-repo fixture and the PNG reader. No app is touched.

def check_page_files(problems):
    for name in PAGE_FILES:
        path = os.path.join(PAGE_DIRECTORY, name)
        if not os.path.isfile(path):
            problems.append("missing page %s" % name)
            continue
        if name.endswith(".html"):
            with open(path, encoding="utf-8") as handle:
                text = handle.read()
            for marker in ('src="common.js"', "Hard10.publish(", "Hard10.fail(", "data-page="):
                if marker not in text:
                    problems.append("%s lacks %s" % (name, marker))


def inline_scripts(path):
    with open(path, encoding="utf-8") as handle:
        text = handle.read()
    if path.endswith(".js"):
        return [text]
    return [match.group(1) for match in re.finditer(r"<script(?![^>]*\bsrc=)[^>]*>(.*?)</script>", text, re.S)]


def check_javascript(problems, notes):
    node = shutil.which("node")
    if node is None:
        notes.append("node not found: JavaScript syntax check skipped")
        return
    scratch = tempfile.mkdtemp(prefix="hard10-dry-")
    try:
        for name in PAGE_FILES:
            path = os.path.join(PAGE_DIRECTORY, name)
            if not os.path.isfile(path):
                continue
            for index, source in enumerate(inline_scripts(path)):
                script = os.path.join(scratch, "%s-%d.js" % (name.replace(".", "_"), index))
                with open(script, "w", encoding="utf-8") as handle:
                    handle.write(source)
                completed = subprocess.run([node, "--check", script], capture_output=True, text=True)
                if completed.returncode != 0:
                    problems.append("JavaScript syntax in %s: %s" % (name, completed.stderr.strip()[:200]))
    finally:
        shutil.rmtree(scratch, ignore_errors=True)


def check_scratch_fixture(problems):
    scratch_root = tempfile.mkdtemp(prefix="hard10-fixture-")
    try:
        path = os.path.join(scratch_root, "clicky-scratch")
        ensure_scratch_repo(path)
        completed = subprocess.run([sys.executable, "-m", "unittest"], cwd=path, capture_output=True, text=True, timeout=120)
        if completed.returncode != 0:
            problems.append("scratch fixture unittest failed: %s" % completed.stderr.strip()[-200:])
    except Exception as error:
        problems.append("scratch fixture: %s" % error)
    finally:
        shutil.rmtree(scratch_root, ignore_errors=True)


def check_wallpaper_finders(problems):
    for index, finder in enumerate(WALLPAPER_FINDERS):
        problems.extend(FE.validate_finder(finder, "WALLPAPER_FINDERS[%d]" % index))


def check_png_reader(problems):
    scratch = tempfile.mkdtemp(prefix="hard10-png-")
    try:
        path = os.path.join(scratch, "probe.png")
        header = b"\x89PNG\r\n\x1a\n" + struct.pack(">I", 13) + b"IHDR" + struct.pack(">II", 300, 200) + b"\x08\x06\x00\x00\x00"
        with open(path, "wb") as handle:
            handle.write(header)
        if png_size(path) != (300, 200):
            problems.append("png_size reads %r, want (300, 200)" % (png_size(path),))
    finally:
        shutil.rmtree(scratch, ignore_errors=True)


def dry_run(selected):
    problems, notes = [], []
    check_page_files(problems)
    check_javascript(problems, notes)
    check_scratch_fixture(problems)
    check_png_reader(problems)
    check_wallpaper_finders(problems)
    for number in selected:
        page = PAGE_OF[number]
        if page and not os.path.isfile(os.path.join(PAGE_DIRECTORY, page)):
            problems.append("test %d: page %s missing" % (number, page))
        if number not in PROMPTS or not PROMPTS[number].strip():
            problems.append("test %d: no prompt" % number)
        if not callable(TESTS.get(number)):
            problems.append("test %d: no runner" % number)
    print("dry run (no app touched, no Chrome, no asks)")
    for number in selected:
        print("  %2d  %-48s page=%-22s prompt=%r" % (number, TEST_NAMES[number], PAGE_OF[number] or "-", PROMPTS[number][:60]))
    for note in notes:
        print("  note: " + note)
    if problems:
        print("PROBLEMS (%d):" % len(problems))
        for problem in problems:
            print("  - " + problem)
        return 1
    print("OK: %d tests, pages, scratch fixture and PNG reader valid" % len(selected))
    return 0


def parse_only(text):
    numbers = []
    for part in text.split(","):
        part = part.strip()
        if not part:
            continue
        number = int(part)
        if number not in TESTS:
            raise argparse.ArgumentTypeError("test %d does not exist (1-10)" % number)
        numbers.append(number)
    return numbers


def parse_origin(text):
    x_text, y_text = text.split(",")
    return int(x_text), int(y_text)


def main(argv):
    parser = argparse.ArgumentParser(description="Hard10 live tests for Clicky (see module docstring).")
    parser.add_argument("--dry-run", action="store_true", help="validate pages and fixtures; touch no app")
    parser.add_argument("--only", type=parse_only, help="test number(s), e.g. 2 or 1,4")
    parser.add_argument("--run", help="run name (default: timestamp)")
    parser.add_argument("--side-origin", type=parse_origin, help="Chrome window origin X,Y for test 6")
    args = parser.parse_args(argv)
    selected = args.only or sorted(TESTS)
    if args.dry_run:
        return dry_run(selected)
    run_name = args.run or datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
    return run_selected(selected, run_name, args.side_origin)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
