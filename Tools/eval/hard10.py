#!/usr/bin/env python3
"""Hard10: ten hard live tests for Clicky, run against the real app by hand.

Each test sets up a fixture (a local page in a Chrome window, System Settings,
a scratch git repo, or the owner's own screen), asks Clicky one prompt through
the debug inbox, and checks the turn record (turn.json, marks.jsonl) against
ground truth. The pass rule for each test is in its docstring and in TESTS.

Usage:
  python3 -I Tools/eval/hard10.py --dry-run          read-only: prints the test display, the recorded
                                                     frontmost app and Safari state, and each test's plan
  python3 -I Tools/eval/hard10.py --only 2,5 --run NAME
  python3 -I Tools/eval/hard10.py --side-origin X,Y  Chrome origin for test 6; must lie on the test display

Owner rules (hard requirements, the owner watches Netflix full screen in Safari):
  1. Test display = the display with the largest origin.x (read from CoreGraphics by a swift -e
     helper, never hardcoded). Every test window goes there, at its top-left + (40, 40), at most
     1280x860. Tests that cannot be placed there are skipped (SKIPS).
  2. Safari is never opened, activated or used. Its pid and full-screen bounds are recorded at the
     start; the run stops if they change (Guard.check_safari, before each test and after each ask).
  3. Every ask uses speak:false (AnswerSession isSilent). Test 10 needs live speech, so it is skipped.
  4. The recorded frontmost app is restored by pid after each ask that needed the throwaway Chrome
     frontmost (Guard.focus). Nothing else is activated: no clicks, keys, cursor moves, Spaces or
     full-screen changes. If the recorded app is Safari, Chrome tests are skipped, because restoring
     it would activate Safari.
  5. Prompts name the place ("on my right monitor, in the Launch tracker window, ...").
  6. The owner-idle pause guard waits while HID idle is under 5 s and resumes at 120 s.

Pause guard: before each setup and each ask, if the owner's HID idle time is
under 5 s the run waits until it reaches 120 s. Every pause is logged to
build/eval/hard10/<run>/pauses.jsonl.

Output: build/eval/hard10/<run>/results.jsonl, results.md, preflight.json and guard.jsonl.

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
SCRATCH_REPO = os.path.expanduser("~/Projects/clicky-scratch")
SHOTS_DIRECTORY = os.path.expanduser("~/Desktop/Clicky Screenshots")
SETTINGS_BUNDLE = "com.apple.systempreferences"
SERVER_PORT = 8793
DEBUG_PORT_BASE = 9440
TEST_WINDOW_SIZE = (1280, 860)
TEST_WINDOW_INSET_PT = 40
SAFARI_NAME = "Safari"
SAFARI_BUNDLE = "com.apple.Safari"
FULLSCREEN_TOLERANCE_PT = 2.0
ASK_SPEAK = False
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


def rect_contains(outer, inner, slack=4):
    return (outer[0] - slack <= inner[0] and outer[1] - slack <= inner[1]
            and outer[0] + outer[2] + slack >= inner[0] + inner[2] and outer[1] + outer[3] + slack >= inner[1] + inner[3])


def box_covers_product(tag, product):
    """A box/rbox that covers the product's photo and price and stays inside its card (+8 pt),
    or one tight to the card. product: {"card": rect, "image": rect, "price": rect}."""
    if box_tight(tag, product["card"]):
        return True
    if drawn_kind(tag) not in BOX_KINDS or not drawn_rect(tag) or not product.get("image") or not product.get("price"):
        return False
    box = drawn_rect(tag)
    card = product["card"]
    inside = rect_contains([card[0] - 8, card[1] - 8, card[2] + 16, card[3] + 16], box, slack=0)
    return inside and rect_contains(box, product["image"]) and rect_contains(box, product["price"])


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
    drawn = tag.get("drawn") or {}
    if drawn.get("labelRectCG"):
        return drawn["labelRectCG"]
    label = drawn.get("label") or tag.get("label")
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
    products = [frame if isinstance(frame, dict) else {"card": frame} for frame in red_frames]
    mapping = match_frames(products, boxes, box_covers_product)
    if len(mapping) != len(red_frames):
        return False, "%d of %d red products boxed (photo + price inside the card)" % (len(mapping), len(red_frames))
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


def current_review(snap, since=None):
    """The open review, else the last one shown after `since` (the panel may already have closed)."""
    if isinstance(snap.get("review"), dict):
        return snap["review"]
    last = snap.get("lastReview")
    if isinstance(last, dict) and last.get("worktree") and (since is None or (last.get("shownAt") or 0) >= since):
        return last
    return None


def code_progress(reply, since=None):
    """(verdict, reason) for one codeStatus poll. verdict is "finished" (not busy, the review panel
    shows a task whose worktree is ready), "running" (busy or a task is live), or "waiting".
    A finished review needs a worktree path, so an idle panel with no task is still "waiting"."""
    snap = status_snapshot(reply)
    review = current_review(snap, since)
    busy = bool(snap.get("busy"))
    if review and review.get("worktree"):
        # A review with a worktree means the agent is done (the panel stays "busy" waiting for a click).
        return "finished", "review ready in %s" % review.get("worktree")
    if busy or (snap.get("task") and not review):
        return "running", "busy: phase %s" % snap.get("phase")
    if reports_finished(snap):
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
# Test display, Safari baseline, focus guard and prompts. The pure functions are unit-tested
# with fakes (test_hard10.py). The only system reads are the swift -e snapshot and the
# System Events frontmost-pid read; the only activation is the by-pid frontmost set.

SWIFT_SNAPSHOT_SOURCE = r'''
import AppKit
import CoreGraphics
import Foundation

var displayCount: UInt32 = 0
CGGetActiveDisplayList(0, nil, &displayCount)
var displayIDs = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
CGGetActiveDisplayList(displayCount, &displayIDs, &displayCount)
var displays: [[String: Any]] = []
for displayID in displayIDs {
    let rect = CGDisplayBounds(displayID)
    displays.append(["id": Int(displayID), "main": CGDisplayIsMain(displayID) != 0,
                     "bounds": [Double(rect.origin.x), Double(rect.origin.y), Double(rect.size.width), Double(rect.size.height)]])
}
var frontmost: [String: Any] = [:]
if let app = NSWorkspace.shared.frontmostApplication {
    frontmost = ["pid": Int(app.processIdentifier), "bundle": app.bundleIdentifier ?? "", "name": app.localizedName ?? ""]
}
var safari: [String: Any] = [:]
var safariWindows: [[String: Any]] = []
let windowInfo = (CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]]) ?? []
for window in windowInfo where (window[kCGWindowOwnerName as String] as? String) == "Safari" {
    if safari["pid"] == nil, let pid = window[kCGWindowOwnerPID as String] as? Int { safari["pid"] = pid }
    guard let boundsDict = window[kCGWindowBounds as String] as? NSDictionary,
          let rect = CGRect(dictionaryRepresentation: boundsDict as CFDictionary) else { continue }
    safariWindows.append(["layer": window[kCGWindowLayer as String] as? Int ?? -1,
                          "onScreen": window[kCGWindowIsOnscreen as String] as? Bool ?? false,
                          "bounds": [Double(rect.origin.x), Double(rect.origin.y), Double(rect.size.width), Double(rect.size.height)]])
}
safari["windows"] = safariWindows
let payload: [String: Any] = ["displays": displays, "frontmost": frontmost, "safari": safari]
let data = try! JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
print(String(data: data, encoding: .utf8)!)
'''


def parse_snapshot(text):
    """The JSON line of a swift snapshot run (swift may print warnings before it)."""
    for line in reversed((text or "").strip().splitlines()):
        if line.strip().startswith("{"):
            return json.loads(line.strip())
    raise ValueError("no JSON snapshot in the swift output")


def rects_close(first, second, tolerance=FULLSCREEN_TOLERANCE_PT):
    return len(first) == 4 and len(second) == 4 and all(abs(a - b) <= tolerance for a, b in zip(first, second))


def rect_lists_close(first, second, tolerance=FULLSCREEN_TOLERANCE_PT):
    if len(first) != len(second):
        return False
    return all(rects_close(a, b, tolerance) for a, b in zip(sorted(first), sorted(second)))


def pick_test_display(displays):
    """The display with the largest origin.x. Two displays sharing that x make the choice ambiguous."""
    usable = [display for display in displays or [] if display.get("bounds")]
    if not usable:
        raise ValueError("no displays reported")
    top = max(display["bounds"][0] for display in usable)
    tied = [display for display in usable if display["bounds"][0] == top]
    if len(tied) > 1:
        raise ValueError("%d displays share origin.x %s; the test display is ambiguous" % (len(tied), top))
    return tied[0]


def window_placement(bounds):
    """(origin, size) for a test window: top-left + inset, at most TEST_WINDOW_SIZE, inside the display."""
    x, y, width, height = bounds
    room_x, room_y = width - 2 * TEST_WINDOW_INSET_PT, height - 2 * TEST_WINDOW_INSET_PT
    if room_x < 400 or room_y < 400:
        raise ValueError("test display too small for a test window (%sx%s)" % (width, height))
    size = (int(min(TEST_WINDOW_SIZE[0], room_x)), int(min(TEST_WINDOW_SIZE[1], room_y)))
    return (int(x + TEST_WINDOW_INSET_PT), int(y + TEST_WINDOW_INSET_PT)), size


def place_phrase(displays):
    """How a prompt names the test display: it is the rightmost one whenever there are several."""
    return "right monitor" if len(displays or []) > 1 else "main monitor"


def safari_state(snapshot):
    """Safari's pid and the bounds of its on-screen full-screen windows, from a snapshot. A window is
    full screen when its bounds match a display's bounds. Only on-screen layer-0 windows count: Safari
    also keeps off-screen windows (other Spaces, hidden), which change without touching the owner's view."""
    displays = [display["bounds"] for display in snapshot.get("displays") or [] if display.get("bounds")]
    safari = snapshot.get("safari") or {}
    windows = []
    for window in safari.get("windows") or []:
        bounds = window.get("bounds")
        if window.get("layer", 0) != 0 or not window.get("onScreen") or not bounds:
            continue
        windows.append({"bounds": bounds, "fullScreen": any(rects_close(bounds, display) for display in displays)})
    return {"pid": safari.get("pid"), "windowCount": len(windows),
            "fullScreenBounds": sorted(window["bounds"] for window in windows if window["fullScreen"])}


def safari_matches(before, now):
    """(ok, reason): the same Safari process with the same full-screen window bounds."""
    if before.get("pid") is None:
        return False, "Safari was not running at the start"
    if now.get("pid") != before["pid"]:
        return False, "Safari pid is %s, was %s" % (now.get("pid"), before["pid"])
    if not rect_lists_close(before["fullScreenBounds"], now["fullScreenBounds"]):
        return False, "Safari full-screen bounds changed: %s -> %s" % (before["fullScreenBounds"], now["fullScreenBounds"])
    return True, "Safari pid %s, full-screen bounds %s unchanged" % (before["pid"], before["fullScreenBounds"])


def is_safari(frontmost):
    return (frontmost or {}).get("bundle") == SAFARI_BUNDLE or (frontmost or {}).get("name") == SAFARI_NAME


FOCUS_TESTS = {1, 2, 3, 5, 6, 7}


def plan_run(snapshot):
    """The run's layout and baseline from a snapshot: test display, window placement, prompt place,
    recorded frontmost app and Safari state. Tests that need the Chrome frontmost are skipped
    (not run) when the recorded app is Safari, since restoring it would re-activate Safari."""
    displays = snapshot.get("displays") or []
    test_display = pick_test_display(displays)
    origin, size = window_placement(test_display["bounds"])
    frontmost = snapshot.get("frontmost") or {}
    safari = safari_state(snapshot)
    problems = []
    if not frontmost.get("pid"):
        problems.append("no frontmost app recorded")
    if safari["pid"] is None:
        problems.append("Safari is not running, so there is no Safari baseline to protect")
    # The owner's rules allow a plain re-activate of their own frontmost app (Safari included) right
    # after a test app was briefly frontmost; the harness still never opens, raises or uses Safari.
    focus_allowed = True
    return {"testDisplay": test_display, "windowOrigin": origin, "windowSize": size,
            "place": place_phrase(displays), "frontmost": frontmost, "safari": safari,
            "focusAllowed": focus_allowed, "problems": problems}


def skip_reason(number, layout):
    """Why a test is not run under this layout, or None."""
    if number in SKIPS:
        return SKIPS[number]
    if number in FOCUS_TESTS and not layout.get("focusAllowed", True):
        return ("skipped: the owner's frontmost app is Safari; a Chrome test restores the frontmost app "
                "by pid, which would re-activate Safari (forbidden)")
    return None


WINDOW_TITLES = {1: "Launch tracker", 2: "Kitchen and Home", 3: "Plan draft", 5: "Board", 6: "Contact",
                 7: "Kitchen and Home"}


def prompt_for(number, place):
    """The test prompt, naming the place (rule 5). Tests without a window keep their text."""
    template = PROMPT_TEMPLATES[number]
    if number not in WINDOW_TITLES:
        return template
    return template.format(where="on my %s, in the %s window" % (place, WINDOW_TITLES[number]))


class RunStop(Exception):
    """The run must stop: Safari changed, or the owner's focus was taken and cannot be put back."""


class FocusLost(RunStop):
    pass


class Guard:
    """Safari baseline, frontmost restore and the by-pid focus change around each ask.

    activate(pid) sets one process frontmost (System Events, returns bool); read_frontmost() returns
    the frontmost pid or None; take_snapshot() returns a snapshot dict (the swift helper). All three
    are injected so the sequencing can be tested with fakes."""

    def __init__(self, baseline, activate, read_frontmost, take_snapshot, log_path=None,
                 settle_seconds=0.0, sleep=time.sleep):
        self.recorded_pid = (baseline.get("frontmost") or {}).get("pid")
        self.safari_baseline = safari_state(baseline)
        self.activate = activate
        self.read_frontmost = read_frontmost
        self.take_snapshot = take_snapshot
        self.log_path = log_path
        self.settle_seconds = settle_seconds
        self.sleep = sleep
        self.touched = False
        self.events = []

    def _log(self, event, **fields):
        record = dict(fields, event=event, time=round(time.time(), 1))
        self.events.append(record)
        if self.log_path:
            append_jsonl(self.log_path, record)

    def note_touch(self):
        """Called before this harness may have changed focus (a Chrome launch counts: Chrome takes focus)."""
        self.touched = True

    def check_safari(self, label):
        now = safari_state(self.take_snapshot())
        ok, reason = safari_matches(self.safari_baseline, now)
        self._log("safari-check", label=label, ok=ok, reason=reason)
        if not ok:
            raise RunStop("%s: %s" % (label, reason))
        return reason

    def _restore(self, label):
        """Activates the recorded app by pid and reads it back; one retry. Raises FocusLost."""
        for attempt in (1, 2):
            self.activate(self.recorded_pid)
            now = self.read_frontmost()
            if now == self.recorded_pid:
                self.touched = False
                self._log("restored", label=label, attempt=attempt, pid=now)
                return
            self._log("restore-miss", label=label, attempt=attempt, frontmost=now)
        raise FocusLost("%s: could not put frontmost pid %s back" % (label, self.recorded_pid))

    def before(self, label):
        """Before a test or an ask: Safari unchanged, and the recorded app frontmost. A focus change
        left by this harness is undone; a change this harness did not make stops the run."""
        self.check_safari(label)
        now = self.read_frontmost()
        if now == self.recorded_pid:
            self._log("frontmost-ok", label=label, pid=now)
            return
        if not self.touched:
            raise RunStop("%s: frontmost is pid %s, not the recorded pid %s, and this harness did not change focus "
                          "(the owner may have moved it)" % (label, now, self.recorded_pid))
        self._restore(label)

    def focus(self, target_pid, body, label):
        """Runs body(target_frontmost) with the target process frontmost, then restores the recorded
        app by pid, even when body raises. Returns (body result, target_frontmost). target_pid None
        means no focus change at all."""
        if target_pid is None:
            return body(False), False
        self.touched = True
        self.activate(target_pid)
        if self.settle_seconds:
            self.sleep(self.settle_seconds)
        front = self.read_frontmost() == target_pid
        self._log("activate", label=label, target=target_pid, frontmost=front)
        result, failure = None, None
        try:
            result = body(front)
        except BaseException as error:
            failure = error
        self._restore(label)
        if failure is not None:
            raise failure
        return result, front

    def settle(self, label):
        if self.touched:
            self._restore(label)

    def final(self, label):
        self.settle(label)
        self.check_safari(label)
        now = self.read_frontmost()
        self._log("final", label=label, frontmostOk=now == self.recorded_pid, frontmost=now)


def frontmost_pid_script():
    """AppleScript read: the unix id of the frontmost process. Reads only."""
    return 'tell application "System Events" to return unix id of first process whose frontmost is true'


def read_frontmost_pid():
    # lsappinfo needs no automation permission, so this can never raise a prompt on the owner's screen.
    try:
        front = subprocess.run(["lsappinfo", "front"], capture_output=True, text=True, timeout=10).stdout.strip()
        info = subprocess.run(["lsappinfo", "info", "-only", "pid", front], capture_output=True, text=True, timeout=10).stdout
    except (OSError, subprocess.TimeoutExpired):
        return None
    match = re.search(r"pid\"?=(\d+)", info)
    return int(match.group(1)) if match else None


def activate_pid(pid):
    """Sets one process frontmost by pid (the only activation the harness makes). Returns success."""
    try:
        return subprocess.run(["osascript", "-e", frontmost_script(pid)], capture_output=True, text=True,
                              timeout=10).returncode == 0
    except (OSError, subprocess.TimeoutExpired):
        return False


def query_snapshot(timeout_seconds=180):
    """Displays, the frontmost app and Safari's windows, from a swift -e helper. Read-only."""
    completed = subprocess.run(["swift", "-e", SWIFT_SNAPSHOT_SOURCE], capture_output=True, text=True,
                               timeout=timeout_seconds)
    if completed.returncode != 0:
        raise RuntimeError("swift snapshot failed: %s" % completed.stderr.strip()[-300:])
    return parse_snapshot(completed.stdout)


# ---------------------------------------------------------------------------
# Owner pause guard, asks, and records.

class Context:
    def __init__(self, run_directory, server, side_origin=None, layout=None, guard=None):
        self.run_directory = run_directory
        self.pauses_path = os.path.join(run_directory, "pauses.jsonl")
        self.server = server
        self.side_origin = side_origin
        self.layout = layout or {}
        self.guard = guard
        self.last_focus = {}
        self.paused_total = 0.0

    @property
    def place(self):
        return self.layout["place"]

    @property
    def window_origin(self):
        return self.layout["windowOrigin"]

    @property
    def window_size(self):
        return self.layout["windowSize"]


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


def owner_gate(ctx, label):
    """Before a setup or an ask: wait for the owner to be idle, then check Safari and the frontmost app."""
    wait_owner_idle(ctx)
    ctx.guard.before(label)


def ask(ctx, prompt, target_pid=None):
    """ask{speak:false} through the debug inbox, with the owner gate before each try, the
    throwaway Chrome (target_pid) frontmost for the ask only, and final_eval's usage-limit
    backoff. Sets ctx.last_focus. Returns (reply, turn)."""
    waits = FE.backoff_schedule()
    while True:
        owner_gate(ctx, "ask")
        reply, front = ctx.guard.focus(
            target_pid, lambda _: FE.clickyctl({"cmd": "ask", "text": prompt, "speak": ASK_SPEAK}, ASK_TIMEOUT_SECONDS),
            "ask")
        ctx.guard.check_safari("after ask")
        ctx.last_focus = {"targetPid": target_pid, "frontmost": front}
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
    extra = {"tags": len(turn.get("tags") or [])}
    if ctx.last_focus.get("targetPid") is not None:
        extra["chromeFrontmost"] = ctx.last_focus.get("frontmost")
    return record(number, "scored", passed, reason, turn_dir, turn, extra)


def cg_frames(window, truth, keys):
    return {key: FE.css_to_cg(truth["items"][key], window) for key in keys}


def frontmost_script(pid, activate=True):
    """AppleScript for the one Chrome process with this pid. Only sets or reads its frontmost
    flag; no clicks, keystrokes or window moves."""
    if activate:
        return 'tell application "System Events" to set frontmost of (first process whose unix id is %d) to true' % pid
    return 'tell application "System Events" to return frontmost of (first process whose unix id is %d)' % pid


# --attach-chrome PORT: use a throwaway Chrome you already started on the test display; nothing launches or takes focus.
ATTACH_PORT = None


class AttachedChrome(FE.ChromeHarness):
    """The same harness on a Chrome that's already running: one tab, reused, left running at the end."""

    def __init__(self, port, origin, size):
        self.debug_port = port
        self.process = None
        self.profile_directory = None
        targets = json.loads(urllib.request.urlopen("http://127.0.0.1:%d/json/list" % port, timeout=5).read())
        version = json.loads(urllib.request.urlopen("http://127.0.0.1:%d/json/version" % port, timeout=5).read())
        page = next(t for t in targets if t.get("type") == "page")
        self.target_id = page["id"]
        self.page = FE.DevToolsSocket(page["webSocketDebuggerUrl"])
        self.browser = FE.DevToolsSocket(version["webSocketDebuggerUrl"])
        window = self.browser.call("Browser.getWindowForTarget", {"targetId": self.target_id})
        self.browser.call("Browser.setWindowBounds", {"windowId": window["windowId"], "bounds": {
            "left": origin[0], "top": origin[1], "width": size[0], "height": size[1]}})

    def stop(self):
        for connection in (self.page, self.browser):
            if connection:
                connection.close()


def open_chrome_page(ctx, number, page, origin=None):
    """Owner gate, then a throwaway Chrome app window on the test display (ctx.window_origin unless
    origin is given), loaded with the page. Chrome may take focus when it launches, so the guard is
    told to settle focus afterwards. The window is made frontmost only during an ask (ask, Guard.focus).
    Returns (harness, state, window, truth)."""
    owner_gate(ctx, "setup test %d" % number)
    if ATTACH_PORT:
        harness = AttachedChrome(ATTACH_PORT, origin or ctx.window_origin, ctx.window_size)
    else:
        ctx.guard.note_touch()
        harness = FE.ChromeHarness(DEBUG_PORT_BASE + number, origin or ctx.window_origin, ctx.window_size)
    try:
        state = harness.load(ctx.server.url("/" + page))
    except Exception:
        harness.stop()
        raise
    truth = state.get("truth") or {}
    if not truth.get("items"):
        harness.stop()
        raise TruthMissing("%s published no truth items" % page)
    window = {"bounds": state["bounds"], "innerWidth": state["innerWidth"], "innerHeight": state["innerHeight"]}
    return harness, state, window, truth


def ask_in_chrome(ctx, harness, number):
    """ask for test number, with the throwaway Chrome frontmost for that ask and the prompt naming
    the place (attached to a Chrome already on the test display, focus never moves). Returns (reply, turn)."""
    return ask(ctx, prompt_for(number, ctx.place), None if ATTACH_PORT else harness.process.pid)


# ---------------------------------------------------------------------------
# The ten tests. Each returns one record.

# Prompts name the place (owner rule 5). {where} is filled by prompt_for from the test display.
PROMPT_TEMPLATES = {
    1: "{where}, mark rows Alpha, Delta, Kilo and Papa and note what's wrong with each",
    2: "{where}, box the three red products and note their prices",
    3: "{where}, point at the Share button",
    4: "how do I change my wallpaper",
    5: "{where}, point at the word 'Quarterly'",
    6: "{where}, point at the Submit button",
    7: "{where}, take a screenshot of that window",
    8: "explain how DNS resolution works with a diagram",
    9: CODE_PROMPT,
    10: LONG_QUESTION,
}

# Tests that are not run, with the reason logged (owner rules 1 and 3). Their functions stay in
# TESTS so they can be re-enabled once the placement or the silence condition is met.
SKIPS = {
    4: "skipped: can't place on the test display (System Settings opens where it likes and can't be positioned without scripting)",
    8: "skipped: can't place on the test display (the whiteboard panel goes on the screen the mouse is on, and the harness never moves the cursor)",
    10: "skipped: silent run (barge-in needs live speech, and no debug command routes live TTS to a file)",
}


def test_1_dense_table(ctx):
    """Dense Notion-style table, 18 rows. Pass: underline on each of Alpha, Delta, Kilo, Papa
    (and no other row), each with a note."""
    harness, _, window, truth = open_chrome_page(ctx, 1, "dense_table.html")
    try:
        frames = {key.split("_", 1)[1].capitalize(): frame
                  for key, frame in cg_frames(window, truth, truth["items"].keys()).items()}
        wanted = ["Alpha", "Delta", "Kilo", "Papa"]
        targets = {name: frames[name] for name in wanted}
        others = {name: frame for name, frame in frames.items() if name not in wanted}
        reply, turn = ask_in_chrome(ctx, harness, 1)
        return score(ctx, 1, reply, turn, lambda t, b: check_dense(t.get("tags") or [], targets, others, b))
    finally:
        harness.stop()


def test_2_product_boxes(ctx):
    """Product grid, 9 cards, 3 red. Pass: one box/rbox per red card, within 8 pt of the card
    edges (DevTools truth), each labelled within 40 pt, each note with a price."""
    harness, _, window, truth = open_chrome_page(ctx, 2, "product_grid.html")
    try:
        red_keys = truth.get("red") or []
        red_frames = []
        for key in red_keys:
            index = key.split("_", 1)[1]
            product = {"card": FE.css_to_cg(truth["items"][key], window)}
            for part in ("image", "price"):
                if truth["items"].get("%s_%s" % (part, index)):
                    product[part] = FE.css_to_cg(truth["items"]["%s_%s" % (part, index)], window)
            red_frames.append(product)
        reply, turn = ask_in_chrome(ctx, harness, 2)
        return score(ctx, 2, reply, turn, lambda t, b: check_boxes(t.get("tags") or [], red_frames, b))
    finally:
        harness.stop()


def test_3_icon_button(ctx):
    """16 px icon toolbar. Pass: a point lands inside the Share button frame plus 4 pt."""
    harness, _, window, truth = open_chrome_page(ctx, 3, "toolbar.html")
    try:
        frame = FE.css_to_cg(truth["items"]["share"], window)
        reply, turn = ask_in_chrome(ctx, harness, 3)
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
    reply, turn = ask(ctx, PROMPT_TEMPLATES[4])
    result = score(ctx, 4, reply, turn, lambda t, b: check_settings(t.get("tags") or [], frame))
    result["extra"]["truthFinder"] = finder
    result["extra"]["truthFrameCG"] = frame
    return result


def test_5_canvas_text(ctx):
    """Canvas-only text. Pass: a point lands inside the ink box of 'Quarterly' plus 4 pt."""
    harness, _, window, truth = open_chrome_page(ctx, 5, "canvas_quarterly.html")
    try:
        frame = FE.css_to_cg(truth["items"]["quarterly"], window)
        reply, turn = ask_in_chrome(ctx, harness, 5)
        return score(ctx, 5, reply, turn, lambda t, b: check_point(t.get("tags") or [], frame))
    finally:
        harness.stop()


def test_6_side_display(ctx):
    """Chrome window on the test display (the right monitor: the largest origin.x). Pass: a point
    lands on the Submit button, and the Submit frame's centre is on a non-main screen of the same
    turn. Skipped when the test display is the main display (single monitor)."""
    if is_main_screen({"boundsCG": ctx.layout["testDisplay"]["bounds"]}):
        raise Skip("skipped: the test display is the main display, so there is no side display to test")
    harness, _, window, truth = open_chrome_page(ctx, 6, "submit_form.html", ctx.side_origin or ctx.window_origin)
    try:
        frame = FE.css_to_cg(truth["items"]["submit"], window)
        reply, turn = ask_in_chrome(ctx, harness, 6)
        # The screens come from the scored turn itself, not from an earlier one.
        return score(ctx, 6, reply, turn, lambda t, b: check_side(t.get("tags") or [], frame, t.get("screens") or []))
    finally:
        harness.stop()


def test_7_screenshot(ctx):
    """Window screenshot. Pass: a snap with a path (or a new PNG in the shots folder), PNG
    size matches the window size within 10 %."""
    harness, state, _, _ = open_chrome_page(ctx, 7, "product_grid.html")
    try:
        started = time.time()
        # The window to snap is this throwaway Chrome, frontmost for the ask only (owner rule 9).
        reply, turn = ask_in_chrome(ctx, harness, 7)
        chrome_front = ctx.last_focus.get("frontmost")
        if turn is None:
            return record(7, "no-turn", False, "no turn record: %s" % (reply.get("error") or "no turnDir"))
        window_points = (state["bounds"]["width"], state["bounds"]["height"])
        dpr = state.get("dpr") or 1.0
        for path in snapshot_paths(turn, started):
            size = png_size(path) if os.path.exists(path) else None
            if size and screenshot_matches_window(size, window_points, dpr):
                return record(7, "scored", True, "PNG %dx%d matches the window %sx%s pt" % (size[0], size[1], window_points[0], window_points[1]), reply.get("turnDir"), turn, {"png": path, "chromeFrontmost": chrome_front})
        return record(7, "scored", False, "no matching PNG (candidates %d)" % len(snapshot_paths(turn, started)), reply.get("turnDir"), turn, {"chromeFrontmost": chrome_front})
    finally:
        harness.stop()


def test_8_whiteboard(ctx):
    """Whiteboard. Pass: turn.json boardEvents is non-empty and holds at least four nodes."""
    owner_gate(ctx, "test 8")
    reply, turn = ask(ctx, prompt_for(8, ctx.place))
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
    reply, turn = ask(ctx, prompt_for(9, ctx.place))
    asked_at = time.time()
    finished, preflight_reason, last_snap, last_reason = False, None, {}, "no poll"
    started = False
    while time.time() < asked_at + CODE_RUN_SECONDS:
        status = FE.clickyctl({"cmd": "codeStatus"}, 30)
        if status.get("ok") is False and "unknown" in str(status.get("error", "")).lower():
            raise TruthMissing("codeStatus is not in this build: %s" % str(status.get("error"))[:120])
        last_snap = status_snapshot(status)
        verdict, last_reason = code_progress(status, since=asked_at - 5)
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
    review = current_review(last_snap, since=asked_at - 5) or {}
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
    # Speech must play for a barge-in, so this test uses speak:true. It is in SKIPS (silent run).
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
    skipped = sum(1 for item in records if item["status"] == "skipped")
    lines += ["", "Passed %d of %d (%d skipped)." % (passed, len(records), skipped)]
    with open(os.path.join(run_directory, "results.md"), "w", encoding="utf-8") as handle:
        handle.write("\n".join(lines) + "\n")
    return passed


def leftover_harness_state():
    """Chrome processes still running from this harness (temp profiles) and profile dirs not yet deleted."""
    processes = subprocess.run(["pgrep", "-fl", "clicky-eval-chrome-"], capture_output=True, text=True).stdout.strip()
    profiles = [name for name in os.listdir(tempfile.gettempdir()) if name.startswith("clicky-eval-chrome-")]
    return processes, profiles


def print_layout(snapshot, layout):
    display = layout["testDisplay"]
    safari = layout["safari"]
    frontmost = layout["frontmost"]
    print("displays (CoreGraphics bounds, largest origin.x is the test display):")
    for item in snapshot.get("displays") or []:
        marker = " <- test display" if item["id"] == display["id"] else ""
        print("  id %s %s bounds %s%s" % (item["id"], "main" if item.get("main") else "side", item["bounds"], marker))
    print("test display: id %s; windows at %s size %sx%s; prompts say 'on my %s'" % (
        display["id"], layout["windowOrigin"], layout["windowSize"][0], layout["windowSize"][1], layout["place"]))
    print("recorded frontmost app: pid %s bundle %s (%s)" % (frontmost.get("pid"), frontmost.get("bundle") or "?", frontmost.get("name") or "?"))
    print("Safari: %s; pid %s; %d layer-0 window(s); full-screen bounds %s" % (
        "running" if safari["pid"] is not None else "NOT running", safari["pid"], safari["windowCount"], safari["fullScreenBounds"] or "none"))
    print("Chrome tests: %s" % ("allowed" if layout["focusAllowed"] else "skipped (recorded frontmost app is Safari)"))


def run_selected(selected, run_name, side_origin):
    run_directory = os.path.join(RUNS_DIRECTORY, run_name)
    os.makedirs(run_directory, exist_ok=True)
    results_path = os.path.join(run_directory, "results.jsonl")
    if not FE.clickyctl({"cmd": "ping"}, 10).get("ok"):
        print("Clicky does not answer ping on the debug inbox; start the debug build first.", file=sys.stderr)
        return 1
    snapshot = query_snapshot()
    layout = plan_run(snapshot)
    if layout["problems"]:
        print("refusing to start: %s" % "; ".join(layout["problems"]), file=sys.stderr)
        return 1
    if side_origin is not None and not point_in_bounds(side_origin, layout["testDisplay"]["bounds"]):
        print("refusing to start: --side-origin %s is not on the test display" % (side_origin,), file=sys.stderr)
        return 1
    print_layout(snapshot, layout)
    # Test-only guards in Clicky: marks and boards stay on the test display for this run.
    bounds = layout["testDisplay"]["bounds"]
    FE.clickyctl({"cmd": "markRegion", "rectCG": [float(value) for value in bounds]}, 10)
    if layout["testDisplay"].get("id") is not None:
        FE.clickyctl({"cmd": "boardDisplay", "displayID": int(layout["testDisplay"]["id"])}, 10)
    with open(os.path.join(run_directory, "preflight.json"), "w", encoding="utf-8") as handle:
        json.dump({"snapshot": snapshot, "layout": layout}, handle, indent=2, sort_keys=True)
    server = PageServer(SERVER_PORT)
    guard = Guard(snapshot, activate_pid, read_frontmost_pid, query_snapshot,
                  log_path=os.path.join(run_directory, "guard.jsonl"), settle_seconds=CHROME_SETTLE_SECONDS)
    ctx = Context(run_directory, server, side_origin, layout, guard)
    records = []
    try:
        for number in selected:
            label = "test %d" % number
            print("test %d: %s" % (number, TEST_NAMES[number]), flush=True)
            paused_before = ctx.paused_total
            stop_run = False
            reason = skip_reason(number, layout)
            if reason:
                item = record(number, "skipped", False, reason)
            else:
                try:
                    guard.before(label)
                    item = TESTS[number](ctx)
                except FE.UsageLimitStop as error:
                    item = record(number, "error", False, "usage limit, run stopped: %s" % error)
                    stop_run = True
                except RunStop as error:
                    item = record(number, "stopped", False, "run stopped: %s" % error)
                    stop_run = True
                except (TruthMissing, Skip) as error:
                    item = record(number, "truth-missing" if isinstance(error, TruthMissing) else "skipped", False, str(error))
                except Exception as error:
                    item = record(number, "error", False, "%s: %s" % (type(error).__name__, str(error)[:200]))
                try:
                    guard.settle(label)
                except RunStop as error:
                    item = record(number, "stopped", False, "focus not restored: %s" % error)
                    stop_run = True
            item["pausedSeconds"] = round(ctx.paused_total - paused_before, 1)
            records.append(item)
            with open(results_path, "a", encoding="utf-8") as handle:
                handle.write(json.dumps(item, sort_keys=True) + "\n")
            print("  %s %s: %s" % ("PASS" if item["pass"] else item["status"].upper(), item["name"], item["reason"]), flush=True)
            if stop_run:
                break
        try:
            guard.final("end of run")
        except RunStop as error:
            print("end-of-run check failed: %s" % error, flush=True)
    finally:
        server.stop()
        FE.clickyctl({"cmd": "markRegion", "clear": True}, 10)
        FE.clickyctl({"cmd": "boardDisplay", "clear": True}, 10)
        try:
            guard.settle("interrupted or stopped")
        except RunStop as error:
            print("focus could not be restored: %s" % error, file=sys.stderr)
    passed = write_report(run_directory, records)
    processes, profiles = leftover_harness_state()
    print("results: %s" % results_path)
    print("table:   %s" % os.path.join(run_directory, "results.md"))
    print("guard:   %s" % os.path.join(run_directory, "guard.jsonl"))
    print("passed %d of %d" % (passed, len(records)))
    print("leftover Chrome processes from this harness: %s" % (processes or "none"))
    print("leftover temp profiles: %s" % (", ".join(profiles) or "none"))
    return 0


# ---------------------------------------------------------------------------
# Dry run: reads only (swift snapshot, owner idle time). No app is touched, no Chrome, no asks,
# no window moves, no focus change, no files written.

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


def check_prompts(problems):
    for number in TESTS:
        if number not in PROMPT_TEMPLATES or not PROMPT_TEMPLATES[number].strip():
            problems.append("test %d: no prompt" % number)
    for number, title in WINDOW_TITLES.items():
        prompt = prompt_for(number, "right monitor")
        if "right monitor" not in prompt or title not in prompt or "{" in prompt:
            problems.append("test %d: prompt does not name the place: %r" % (number, prompt))


def dry_run(selected, side_origin=None):
    problems, notes = [], []
    check_page_files(problems)
    check_javascript(problems, notes)
    check_scratch_fixture(problems)
    check_png_reader(problems)
    check_wallpaper_finders(problems)
    check_prompts(problems)
    for number in selected:
        page = PAGE_OF[number]
        if page and not os.path.isfile(os.path.join(PAGE_DIRECTORY, page)):
            problems.append("test %d: page %s missing" % (number, page))
        if not callable(TESTS.get(number)):
            problems.append("test %d: no runner" % number)
    snapshot, layout = None, None
    print("dry run (reads only: swift snapshot and owner idle time; no app, Chrome, ask, window, focus change or file written)")
    try:
        snapshot = query_snapshot()
        layout = plan_run(snapshot)
        print_layout(snapshot, layout)
        if side_origin is not None and not point_in_bounds(side_origin, layout["testDisplay"]["bounds"]):
            problems.append("--side-origin %s is not on the test display" % (side_origin,))
        for problem in layout["problems"]:
            notes.append("a live run would refuse to start: " + problem)
    except (RuntimeError, ValueError, OSError, subprocess.TimeoutExpired) as error:
        problems.append("display, Safari or frontmost snapshot: %s" % error)
    idle = FE.owner_idle_seconds()
    print("owner HID idle: %s" % ("unknown" if idle is None else "%.1f s" % idle))
    place = layout["place"] if layout else "right monitor"
    print("tests:")
    for number in selected:
        reason = skip_reason(number, layout or {})
        if reason:
            print("  %2d  %-48s %s" % (number, TEST_NAMES[number], reason))
            continue
        print("  %2d  %-48s page=%-22s prompt=%r" % (number, TEST_NAMES[number], PAGE_OF[number] or "-",
                                                    prompt_for(number, place)[:90]))
    for note in notes:
        print("  note: " + note)
    if problems:
        print("PROBLEMS (%d):" % len(problems))
        for problem in problems:
            print("  - " + problem)
        return 1
    print("OK: %d tests, pages, scratch fixture, PNG reader, prompts and the test display valid" % len(selected))
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
    parser.add_argument("--attach-chrome", type=int, help="DevTools port of a throwaway Chrome already on the test display: nothing launches, focus never moves")
    args = parser.parse_args(argv)
    selected = args.only or sorted(TESTS)
    if args.dry_run:
        return dry_run(selected, args.side_origin)
    run_name = args.run or datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
    return run_selected(selected, run_name, args.side_origin)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
