#!/usr/bin/env python3
"""P6.11 final eval for Clicky: where do its marks land in real apps?

Three sets, all scored against ground truth Clicky's grounding never sees:

  fixture  the 40-row GroundingFixture (grounding_prompts.tsv), asked once per
           config to compare configs: baseline, raw-hires, list, list+badges,
           verify (= list+badges + v2.grounding.verifyWithHaiku). Toggled with
           `defaults write com.personal.clicky ...` like grounding_eval.py;
           every turn is checked for evidence that the setting took effect.
  ax       >= 150 asks in Finder, Safari, Xcode, System Settings, Preview,
           Notes, Slack and VS Code (final/ax_asks.tsv). Setup = `open -a` of
           the test app (never Clicky) on a temporary copy of final/fixtures;
           truth = the debug inbox's `axfind` (a plain AX walk of that app).
  canvas   >= 60 asks on local canvas pages (canvas/*.html, served by
           `python3 -m http.server --bind 127.0.0.1`, opened in Chrome with
           remote debugging on 127.0.0.1 and a throwaway --user-data-dir; the
           truth comes over the DevTools protocol and is mapped to CG with the
           window bounds), the Notion-style dense table, a paused video with
           known squares, and Terminal text (truth = axfind AXBoundsForRange).
           Figma rows only when Figma is installed and logged in (skipped).

Hit rules (CG points, from grounding_eval.py): a box mark's centre inside the
truth + 2 pt (area <= 4 x truth + 400 pt^2), a POINT inside truth + 4 pt; the
stricter drawn rule is reported next to it. multi rows: one hit per step, in
order. all rows ("circle all X"): every instance has its own hitting tag.
dense rows: in order, every mark drawn as an underline that passes the drawn
rule against the row's text, and every label in clear space (no table text
under it, inside the display).

Caption checks (turn.json + marks.jsonl): bubble vs marks overlap (spoken rows
only: the bubble shows while Clicky talks), marks inside display bounds, badge
/ id leaks. Latencies from turn.json timings; TTFA = firstAudio - keyUp on
spoken rows; RTF and caption lag when turn.json carries them.

Resumable: one JSON line per row in build/eval/final/<run>/results.jsonl; rows
already there are skipped. Usage-limit errors back off 30 s -> 8 min, then the
run stops (rerun to resume). `reset` before every row.

  python3 -I Tools/eval/final_eval.py --dry-run          # validates data only, touches no app
  python3 -I Tools/eval/final_eval.py --probe-truth      # opens the test apps, axfind only, no asks
  python3 -I Tools/eval/final_eval.py --sets fixture,ax,canvas --run-name final
  python3 -I Tools/eval/final_eval.py --report-only --run-name final --append-to docs/v2/EVAL.md

Python 3.9, standard library only.
"""

import argparse
import base64
import importlib.util
import json
import math
import os
import re
import shutil
import socket
import statistics
import struct
import subprocess
import sys
import tempfile
import time
import urllib.request

EVAL_DIRECTORY = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.abspath(os.path.join(EVAL_DIRECTORY, "..", ".."))
CLICKYCTL = os.path.join(REPO_ROOT, "Tools", "clickyctl.sh")
DATA_DIRECTORY = os.path.join(EVAL_DIRECTORY, "final")
CANVAS_DIRECTORY = os.path.join(EVAL_DIRECTORY, "canvas")
AX_ASKS_PATH = os.path.join(DATA_DIRECTORY, "ax_asks.tsv")
CANVAS_ASKS_PATH = os.path.join(DATA_DIRECTORY, "canvas_asks.tsv")
FIXTURES_DIRECTORY = os.path.join(DATA_DIRECTORY, "fixtures")
MANIFEST_PATH = os.path.join(CANVAS_DIRECTORY, "manifest.json")
RUNS_DIRECTORY = os.path.join(REPO_ROOT, "build", "eval", "final")
GEN_BOARDS_DIRECTORY = os.path.join(REPO_ROOT, "build", "eval", "gen_boards")
PACKAGE_PATH = os.path.join(REPO_ROOT, "Packages", "ClickyCore")
DEFAULTS_DOMAIN = "com.personal.clicky"
CHROME_BINARY = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"

MIN_AX_ASKS = 150
MIN_CANVAS_ASKS = 60
BACKOFF_SECONDS = [30, 60, 120, 240, 480]
USAGE_LIMIT_PATTERN = re.compile(r"usage limit|rate limit|limit reached|too many requests|\b429\b|overloaded|try again later", re.IGNORECASE)
LEAK_PATTERN = re.compile(r"\[\s*\d{1,4}\s*\]|\b(?:badge|element|id)\s*#?\s*\d{1,4}\b", re.IGNORECASE)

APP_BUNDLES = {
    "Finder": "com.apple.finder",
    "Safari": "com.apple.Safari",
    "Xcode": "com.apple.dt.Xcode",
    "System Settings": "com.apple.systempreferences",
    "Preview": "com.apple.Preview",
    "Notes": "com.apple.Notes",
    "Slack": "com.tinyspeck.slackmacgap",
    "Visual Studio Code": "com.microsoft.VSCode",
}
ELECTRON_BUNDLES = {"com.tinyspeck.slackmacgap", "com.microsoft.VSCode"}
TERMINAL_BUNDLE = "com.apple.Terminal"
CHROME_BUNDLE = "com.google.Chrome"
ASK_KINDS = {"point", "mark", "multi", "all", "dense"}
FINDER_FIELDS = {"role", "subrole", "title", "match", "nth", "order", "all", "ancestor", "within", "text", "textNth", "window", "electron"}

# Config arms. None deletes the key. Keys this build does not read still get
# written; each turn is then checked for evidence (see config_evidence).
CONFIGS = {
    "baseline": {"v2.grounding.lists": False, "v2.grounding.badges": False, "v2.grounding.imageTier": "standard", "v2.grounding.verifyWithHaiku": False},
    "raw-hires": {"v2.grounding.lists": False, "v2.grounding.badges": False, "v2.grounding.imageTier": "high", "v2.grounding.verifyWithHaiku": False},
    "list": {"v2.grounding.lists": True, "v2.grounding.badges": False, "v2.grounding.imageTier": "high", "v2.grounding.verifyWithHaiku": False},
    "list+badges": {"v2.grounding.lists": True, "v2.grounding.badges": True, "v2.grounding.imageTier": "high", "v2.grounding.verifyWithHaiku": False},
    "verify": {"v2.grounding.lists": True, "v2.grounding.badges": True, "v2.grounding.imageTier": "high", "v2.grounding.verifyWithHaiku": True},
}
CONFIG_ORDER = ["baseline", "raw-hires", "list", "list+badges", "verify"]
FINAL_CONFIG = "verify"


# ---------------------------------------------------------------------------
# grounding_eval.py (the P0-P1c rules and the fixture driver), loaded by path
# because python3 -I leaves the script directory off sys.path.

def load_grounding_eval():
    spec = importlib.util.spec_from_file_location("grounding_eval", os.path.join(EVAL_DIRECTORY, "grounding_eval.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


GE = load_grounding_eval()


# ---------------------------------------------------------------------------
# Pure helpers (unit-tested in test_final_eval.py).

def wilson(hits, total, z=1.96):
    """Wilson score interval for hits/total (95 % by default), as (low, high)."""
    if total <= 0:
        return (0.0, 0.0)
    proportion = hits / float(total)
    denominator = 1.0 + z * z / total
    centre = (proportion + z * z / (2.0 * total)) / denominator
    margin = z * math.sqrt(proportion * (1.0 - proportion) / total + z * z / (4.0 * total * total)) / denominator
    return (max(0.0, centre - margin), min(1.0, centre + margin))


def percentile(values, fraction):
    ordered = sorted(v for v in values if v is not None)
    if not ordered:
        return None
    index = min(len(ordered) - 1, max(0, int(round(fraction * (len(ordered) - 1)))))
    return ordered[index]


def backoff_schedule():
    """Seconds to wait after each usage-limit error: 30 s doubling to 8 min."""
    return list(BACKOFF_SECONDS)


def is_usage_limit_error(text):
    return bool(USAGE_LIMIT_PATTERN.search(text or ""))


def rect_contains(outer, inner, tolerance=0.5):
    return (inner[0] >= outer[0] - tolerance and inner[1] >= outer[1] - tolerance
            and inner[0] + inner[2] <= outer[0] + outer[2] + tolerance and inner[1] + inner[3] <= outer[1] + outer[3] + tolerance)


def rects_intersect(first, second):
    return not (first[0] + first[2] <= second[0] or second[0] + second[2] <= first[0]
                or first[1] + first[3] <= second[1] or second[1] + second[3] <= first[1])


def dedupe_nested(frames):
    """Drops frames lying inside another one (an AX parent and its child both
    matched an "all" truth): every instance is counted once, by its outer frame."""
    unique = []
    for index, frame in enumerate(frames):
        if any(other_index != index and rect_contains(other, frame, 1.0) and (list(other) != list(frame) or other_index < index)
               for other_index, other in enumerate(frames)):
            continue
        unique.append(frame)
    return unique


def css_to_cg(rect, window):
    """Viewport CSS px -> CG global points.

    window: {"bounds": {left, top, width, height}} (DevTools
    Browser.getWindowForTarget, screen DIPs = points, CG orientation) and the
    page's innerWidth / innerHeight (CSS px). Chrome on macOS has no side
    borders: the content is the window's full width, aligned to its bottom.
    Page zoom = content width in points / innerWidth.
    """
    bounds = window["bounds"]
    zoom = bounds["width"] / float(window["innerWidth"])
    content_left = bounds["left"] + (bounds["width"] - window["innerWidth"] * zoom) / 2.0
    content_top = bounds["top"] + bounds["height"] - window["innerHeight"] * zoom
    return [round(content_left + rect[0] * zoom, 2), round(content_top + rect[1] * zoom, 2), round(rect[2] * zoom, 2), round(rect[3] * zoom, 2)]


def base_rule(tag, frame):
    return GE.tag_hits_target(tag, frame)


def drawn_rule(tag, frame):
    return GE.tag_hits_target_drawn(tag, frame)


def score_in_order(frames, tags, rule):
    """One hitting tag per frame, in order (greedy, like grounding_eval.score_row)."""
    tag_index = 0
    for step, frame in enumerate(frames, start=1):
        while tag_index < len(tags) and not rule(tags[tag_index], frame):
            tag_index += 1
        if tag_index >= len(tags):
            return False, "no tag hit step %d" % step
        tag_index += 1
    return True, ""


def score_all_instances(frames, tags, rule):
    """Every frame needs its own hitting tag (bipartite matching)."""
    candidates = [[tag_index for tag_index, tag in enumerate(tags) if rule(tag, frame)] for frame in frames]
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

    matched = sum(1 for frame_index in range(len(frames)) if assign(frame_index, set()))
    if matched == len(frames):
        return True, ""
    return False, "%d of %d instances marked" % (matched, len(frames))


def score_any(frames, tags, rule):
    if any(rule(tag, frames[0]) for tag in tags):
        return True, ""
    return False, "no tag hit" if tags else "no tags"


def score_by_kind(kind, frames, tags, rule):
    if kind in ("multi", "dense"):
        return score_in_order(frames, tags, rule)
    if kind == "all":
        return score_all_instances(frames, tags, rule)
    return score_any(frames, tags, rule)


def mark_tags(tags):
    return [tag for tag in tags if tag.get("drawn")]


def score_dense(text_frames, tags, table_texts, display_bounds):
    """Dense-table rule: in order, each mark an underline passing the drawn
    rule against the row's text span; every label clear of all table text and
    inside a display. Returns (underlines_ok, labels_ok, reason)."""
    marks = mark_tags(tags)
    tag_index = 0
    used = []
    for step, frame in enumerate(text_frames, start=1):
        while tag_index < len(marks) and not (marks[tag_index]["drawn"].get("kind") == "underline" and drawn_rule(marks[tag_index], frame)):
            tag_index += 1
        if tag_index >= len(marks):
            return False, None, "step %d: no underline under the row text" % step
        used.append(marks[tag_index])
        tag_index += 1
    labels = [tag["drawn"].get("labelRectCG") for tag in used]
    if any(label is None for label in labels):
        return True, None, "label rects not logged"
    for label in labels:
        if any(rects_intersect(label, text) for text in table_texts):
            return True, False, "a label covers table text"
        if display_bounds and not any(rect_contains(bounds, label) for bounds in display_bounds):
            return True, False, "a label leaves the display"
    return True, True, ""


def drawn_rect_for_overlap(drawn):
    """The area a drawn mark covers, for the bubble overlap check."""
    rect = list(drawn.get("rectCG") or [0, 0, 0, 0])
    if drawn.get("kind") == "underline":
        return [rect[0], rect[1] - 1.5, rect[2], 3.0]
    if drawn.get("kind") == "arrow":
        return None
    return rect


def segment_hits_rect(start, end, rect, samples=24):
    for step in range(samples + 1):
        fraction = step / float(samples)
        x = start[0] + (end[0] - start[0]) * fraction
        y = start[1] + (end[1] - start[1]) * fraction
        if rect[0] <= x <= rect[0] + rect[2] and rect[1] <= y <= rect[1] + rect[3]:
            return True
    return False


def arrow_endpoints(drawn):
    rect = drawn.get("rectCG") or [0, 0, 0, 0]
    tip = drawn.get("tip")
    if not tip:
        return None
    tail_x = rect[0] if abs(rect[0] - tip[0]) > 1e-6 else rect[0] + rect[2]
    tail_y = rect[1] if abs(rect[1] - tip[1]) > 1e-6 else rect[1] + rect[3]
    return (tail_x, tail_y), (tip[0], tip[1])


def count_leaks(turn):
    """Badge / element-id leaks: the app's own counters plus ids in the spoken segments."""
    grounding = turn.get("grounding") or {}
    spoken = " ".join(turn.get("segments") or [])
    return int(grounding.get("badgeMentionsInNarration", 0) or 0) + len(LEAK_PATTERN.findall(spoken))


def caption_checks(turn, mark_events):
    """{marksOutOfBounds, bubbleOverlap (None when no bubble was logged), leaks}."""
    screens = [screen["boundsCG"] for screen in turn.get("screens", []) if screen.get("boundsCG")]
    out_of_bounds = 0
    covered = []
    for tag in mark_tags(turn.get("tags", [])):
        drawn = tag["drawn"]
        pieces = []
        if drawn.get("kind") == "arrow":
            endpoints = arrow_endpoints(drawn)
            if endpoints:
                pieces += [[endpoints[0][0], endpoints[0][1], 0, 0], [endpoints[1][0], endpoints[1][1], 0, 0]]
        else:
            pieces.append(drawn.get("rectCG") or [0, 0, 0, 0])
        if drawn.get("labelRectCG"):
            pieces.append(drawn["labelRectCG"])
        if screens and any(not any(rect_contains(bounds, piece) for bounds in screens) for piece in pieces):
            out_of_bounds += 1
        covered.append(drawn)
    bubbles = [event["rectCG"] for event in mark_events if event.get("event") == "bubble" and event.get("rectCG")]
    overlap = None
    if bubbles:
        final_bubble = bubbles[-1]
        overlap = False
        for drawn in covered:
            if drawn.get("kind") == "arrow":
                endpoints = arrow_endpoints(drawn)
                if endpoints and segment_hits_rect(endpoints[0], endpoints[1], final_bubble):
                    overlap = True
            else:
                area = drawn_rect_for_overlap(drawn)
                if area and rects_intersect(area, final_bubble):
                    overlap = True
            if drawn.get("labelRectCG") and rects_intersect(drawn["labelRectCG"], final_bubble):
                overlap = True
    return {"marksOutOfBounds": out_of_bounds, "bubbleOverlap": overlap, "bubbles": len(bubbles), "leaks": count_leaks(turn)}


def find_number(container, names):
    """First numeric value under any of `names`, searched one level deep."""
    if not isinstance(container, dict):
        return None
    for name in names:
        value = container.get(name)
        if isinstance(value, (int, float)):
            return float(value)
        if isinstance(value, list) and value and all(isinstance(v, (int, float)) for v in value):
            return float(statistics.median(value))
    for value in container.values():
        if isinstance(value, dict):
            for name in names:
                inner = value.get(name)
                if isinstance(inner, (int, float)):
                    return float(inner)
    return None


def turn_latencies(turn):
    timings = turn.get("timings") or {}
    key_up = timings.get("keyUp")
    result = {}
    if key_up is not None:
        for stage in ("captureDone", "firstDelta", "result", "firstSegment", "firstAudio", "end"):
            if stage in timings:
                result[stage] = round(timings[stage] - key_up, 3)
    result["rtf"] = find_number(turn.get("speech") or {}, ["rtf", "realTimeFactor"])
    result["captionLagMs"] = find_number(turn, ["captionLagMs", "lagMs"])
    return result


def config_evidence(config_name, turn, turn_directory):
    """Did the arm's settings reach this turn? {setting: True/False/None (no evidence)}."""
    wanted = CONFIGS.get(config_name) or {}
    grounding = turn.get("grounding") or {}
    evidence = {}
    if "v2.grounding.badges" in wanted and "isBadged" in grounding:
        evidence["badges"] = bool(grounding["isBadged"]) == bool(wanted["v2.grounding.badges"])
    if "v2.grounding.lists" in wanted:
        elements_path = os.path.join(turn_directory or "", "elements.txt")
        has_lists = os.path.exists(elements_path) and os.path.getsize(elements_path) > 0
        evidence["lists"] = has_lists == bool(wanted["v2.grounding.lists"]) if turn_directory else None
    if "v2.grounding.verifyWithHaiku" in wanted:
        flag = grounding.get("verifyWithHaiku")
        evidence["verify"] = None if flag is None else bool(flag) == bool(wanted["v2.grounding.verifyWithHaiku"])
    screens = turn.get("screens") or []
    if screens and screens[0].get("boundsCG"):
        evidence["imagePxPerPt"] = round(screens[0].get("imageW", 0) / max(1.0, screens[0]["boundsCG"][2]), 3)
    return evidence


# ---------------------------------------------------------------------------
# Data files.

def read_tsv(path):
    rows = []
    with open(path, encoding="utf-8") as tsv_file:
        header = tsv_file.readline().rstrip("\n").split("\t")
        for line_number, line in enumerate(tsv_file, start=2):
            if not line.strip():
                continue
            fields = line.rstrip("\n").split("\t")
            if len(fields) > len(header):
                raise ValueError("%s:%d has %d fields, header has %d" % (path, line_number, len(fields), len(header)))
            fields += [""] * (len(header) - len(fields))
            row = dict(zip(header, fields))
            row["_line"] = line_number
            rows.append(row)
    return rows


def read_manifest():
    with open(MANIFEST_PATH, encoding="utf-8") as manifest_file:
        return json.load(manifest_file)["pages"]


def parse_params(text):
    params = {}
    for part in [p for p in (text or "").split("&") if p]:
        key, _, value = part.partition("=")
        params[key] = value
    return params


def canvas_keys(manifest, page, params):
    """Truth keys a page publishes for these params (mirrors the page JS)."""
    spec = manifest[page]
    variant = params.get("variant", "default")
    if page == "text":
        return {item["key"] for item in spec["items"]}
    if page == "dots":
        return {dot["key"] for dot in spec["variants"][variant]["dots"]}
    if page == "shapes":
        return {shape["key"] for shape in spec["variants"][variant]["shapes"]}
    if page == "chart":
        return set(spec["keys"])
    if page == "table":
        return {task["key"] for task in spec["tasks"]} | {task["key"] + "_text" for task in spec["tasks"]}
    if page == "video":
        time_value = float(params.get("t", "2"))
        for segment in spec["segments"]:
            if segment["start"] <= time_value < segment["end"]:
                return {square["key"] for square in segment["squares"]}
        return set()
    return set()


def finder_alternatives(finder):
    """A finder's title may list alternatives; one axfind query per title."""
    title = finder.get("title")
    if isinstance(title, list):
        return [dict(finder, title=t) for t in title]
    return [finder]


def validate_finder(finder, where):
    problems = []
    if not isinstance(finder, dict):
        return ["%s: truth entry is not an object" % where]
    unknown = set(finder) - FINDER_FIELDS
    if unknown:
        problems.append("%s: unknown truth fields %s" % (where, sorted(unknown)))
    title = finder.get("title")
    if title is not None and not (isinstance(title, str) and title) and not (isinstance(title, list) and title and all(isinstance(t, str) and t for t in title)):
        problems.append("%s: title must be a non-empty string or list of strings" % where)
    if finder.get("match", "exact") not in ("exact", "contains", "prefix"):
        problems.append("%s: bad match %r" % (where, finder.get("match")))
    if "nth" in finder and not (isinstance(finder["nth"], int) and finder["nth"] >= 1):
        problems.append("%s: nth must be an int >= 1" % where)
    if finder.get("window", "main") not in ("main", "only-main", "menubar"):
        problems.append("%s: bad window %r" % (where, finder.get("window")))
    if "within" in finder:
        problems += validate_finder(finder["within"], where + ".within")
    if not finder.get("role") and not finder.get("title") and not finder.get("subrole"):
        problems.append("%s: needs a role, subrole or title" % where)
    return problems


def validate_ax_rows(rows):
    problems = []
    seen_ids = set()
    for row in rows:
        where = "ax_asks.tsv:%d (%s)" % (row["_line"], row.get("id"))
        if row["id"] in seen_ids:
            problems.append("%s: duplicate id" % where)
        seen_ids.add(row["id"])
        if row["app"] not in APP_BUNDLES:
            problems.append("%s: unknown app %r" % (where, row["app"]))
        elif APP_BUNDLES[row["app"]] != row["bundle"]:
            problems.append("%s: bundle %s != %s" % (where, row["bundle"], APP_BUNDLES[row["app"]]))
        if "clicky" in (row["app"] + row["bundle"] + row["setup"]).lower():
            problems.append("%s: never open Clicky from the eval" % where)
        problems += validate_setup(row["setup"], where)
        if not row["prompt"].strip():
            problems.append("%s: empty prompt" % where)
        if row["kind"] not in ASK_KINDS - {"dense"}:
            problems.append("%s: bad kind %r" % (where, row["kind"]))
        try:
            truth = json.loads(row["truth"])
        except ValueError as error:
            problems.append("%s: truth is not JSON (%s)" % (where, error))
            continue
        if not isinstance(truth, list) or not truth:
            problems.append("%s: truth must be a non-empty list" % where)
            continue
        for index, finder in enumerate(truth):
            problems += validate_finder(finder, "%s truth[%d]" % (where, index))
        if row["kind"] in ("point", "mark") and len(truth) != 1:
            problems.append("%s: %s rows take exactly one truth" % (where, row["kind"]))
        if row["kind"] == "multi" and len(truth) < 2:
            problems.append("%s: multi rows need >= 2 steps" % where)
        if row["kind"] == "all" and not (len(truth) >= 2 or (len(truth) == 1 and truth[0].get("all"))):
            problems.append("%s: all rows need >= 2 truths or one with \"all\": true" % where)
        if row["kind"] != "all" and any(finder.get("all") for finder in truth if isinstance(finder, dict)):
            problems.append("%s: \"all\": true only on all rows" % where)
    return problems


def validate_setup(setup, where):
    if setup == "app":
        return []
    if setup.startswith("file:"):
        relative_path = setup[len("file:"):]
        if ".." in relative_path.split("/") or relative_path.startswith("/"):
            return ["%s: setup path must stay inside final/fixtures" % where]
        if relative_path == "preview/guide.pdf":
            return []  # generated at run time by write_fixture_pdf
        if not os.path.exists(os.path.join(FIXTURES_DIRECTORY, relative_path)):
            return ["%s: fixture %s missing" % (where, relative_path)]
        return []
    if setup.startswith("url:"):
        problems = []
        for path in setup[len("url:"):].split("|"):
            page_file = path.split("?", 1)[0].lstrip("/")
            if not path.startswith("/") or not os.path.exists(os.path.join(CANVAS_DIRECTORY, page_file)):
                problems.append("%s: page %s missing under canvas/" % (where, path))
        return problems
    return ["%s: setup must be app | file:<fixture> | url:/<page>[|/<page>...]" % where]


def validate_canvas_rows(rows, manifest):
    problems = []
    seen_ids = set()
    for row in rows:
        where = "canvas_asks.tsv:%d (%s)" % (row["_line"], row.get("id"))
        if row["id"] in seen_ids:
            problems.append("%s: duplicate id" % where)
        seen_ids.add(row["id"])
        page = row["page"]
        if page not in manifest:
            problems.append("%s: unknown page %r" % (where, page))
            continue
        if row["kind"] not in ASK_KINDS:
            problems.append("%s: bad kind %r" % (where, row["kind"]))
        if row["kind"] == "dense" and page != "table":
            problems.append("%s: dense rows belong to the table page" % where)
        try:
            keys = json.loads(row["keys"])
        except ValueError as error:
            problems.append("%s: keys not JSON (%s)" % (where, error))
            continue
        if not isinstance(keys, list) or not keys or not all(isinstance(k, str) for k in keys):
            problems.append("%s: keys must be a non-empty list of strings" % where)
            continue
        if row["kind"] in ("point", "mark") and len(keys) != 1:
            problems.append("%s: %s rows take one key" % (where, row["kind"]))
        if row["kind"] in ("multi", "all") and len(keys) < 2:
            problems.append("%s: %s rows need >= 2 keys" % (where, row["kind"]))
        if row["kind"] == "dense" and len(keys) < 5:
            problems.append("%s: dense rows mark >= 5 rows" % where)
        params = parse_params(row["params"])
        if page == "terminal":
            file_name = params.get("file", "")
            text_path = os.path.join(CANVAS_DIRECTORY, "terminal", file_name)
            if file_name not in manifest["terminal"]["files"] or not os.path.exists(text_path):
                problems.append("%s: terminal file %r missing" % (where, file_name))
                continue
            with open(text_path, encoding="utf-8") as text_file:
                text = text_file.read()
            for key in keys:
                if text.count(key) != 1:
                    problems.append("%s: %r appears %d times in %s (needs exactly 1)" % (where, key, text.count(key), file_name))
            continue
        if not os.path.exists(os.path.join(CANVAS_DIRECTORY, manifest[page]["file"])):
            problems.append("%s: page file %s missing" % (where, manifest[page]["file"]))
        if page in ("dots", "shapes") and params.get("variant", "default") not in manifest[page]["variants"]:
            problems.append("%s: unknown variant %r" % (where, params.get("variant")))
            continue
        if row["kind"] == "dense" and sorted(params.get("spread", "").split(",")) != sorted(keys):
            problems.append("%s: dense rows need spread=<their keys> (non-adjacent rows)" % where)
        if page == "table" and params.get("spread"):
            task_keys = {task["key"] for task in manifest["table"]["tasks"]}
            if any(k not in task_keys for k in params["spread"].split(",")) or len(params["spread"].split(",")) > 6:
                problems.append("%s: spread lists unknown tasks or more than 6" % where)
        available = canvas_keys(manifest, page, params)
        for key in keys:
            if key not in available:
                problems.append("%s: key %r not published by %s with %s" % (where, key, page, row["params"] or "defaults"))
    return problems


def validate_static_files(manifest):
    problems = []
    for page, spec in manifest.items():
        if "file" not in spec:
            continue
        path = os.path.join(CANVAS_DIRECTORY, spec["file"])
        if not os.path.exists(path):
            problems.append("canvas page %s missing" % spec["file"])
            continue
        with open(path, encoding="utf-8") as page_file:
            html = page_file.read()
        if 'src="common.js"' not in html:
            problems.append("%s does not load common.js" % spec["file"])
        if "Fixture.publish(" not in html:
            problems.append("%s never publishes its truth" % spec["file"])
        title_match = re.search(r"<title>(.*?)</title>", html, re.IGNORECASE | re.DOTALL)
        if not title_match or "truth" in title_match.group(1).lower() or "{" in title_match.group(1):
            problems.append("%s needs a neutral <title> (the model reads it on screen)" % spec["file"])
    for name in ("common.js", "safari_page.html", "make_video.py"):
        if not os.path.exists(os.path.join(CANVAS_DIRECTORY, name)):
            problems.append("canvas/%s missing" % name)
    video_path = os.path.join(CANVAS_DIRECTORY, manifest["video"]["src"])
    if not os.path.exists(video_path):
        problems.append("video %s missing: run python3 -I Tools/eval/canvas/make_video.py (needs a local ffmpeg)" % manifest["video"]["src"])
    else:
        with open(video_path, "rb") as video_file:
            if video_file.read(12)[4:8] != b"ftyp":
                problems.append("video %s is not an MP4" % manifest["video"]["src"])
    for segment in manifest["video"]["segments"]:
        for square in segment["squares"]:
            x, y, w, h = square["rect"]
            if x < 0 or y < 0 or x + w > manifest["video"]["width"] or y + h > manifest["video"]["height"]:
                problems.append("video square %s at %s leaves the frame" % (square["key"], square["rect"]))
    return problems


# ---------------------------------------------------------------------------
# Generated fixtures (no app needed).

def write_fixture_pdf(path):
    """A small 2-page PDF for the Preview rows, built by hand (stdlib only)."""
    pages_text = [
        ["Lumen User Guide", "1. Installing the CLI", "Run brew install lumen, then lumen init.", "2. Your first project", "Projects live in ~/Lumen."],
        ["Troubleshooting", "Error 429: wait and retry.", "Disk full: free some space.", "Contact: ops@example.test"],
    ]
    objects = []

    def add(body):
        objects.append(body)
        return len(objects)

    font_id = add(b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>")
    page_ids = []
    pages_id_placeholder = len(objects) + 1 + 2 * len(pages_text)
    for lines in pages_text:
        stream_lines = ["BT", "/F1 28 Tf", "72 720 Td", "(%s) Tj" % lines[0], "/F1 14 Tf"]
        for line in lines[1:]:
            stream_lines += ["0 -34 Td", "(%s) Tj" % line.replace("(", "\\(").replace(")", "\\)")]
        stream_lines.append("ET")
        stream = "\n".join(stream_lines).encode("latin-1")
        content_id = add(b"<< /Length %d >>\nstream\n" % len(stream) + stream + b"\nendstream")
        page_ids.append(add(("<< /Type /Page /Parent %d 0 R /MediaBox [0 0 612 792] /Contents %d 0 R /Resources << /Font << /F1 %d 0 R >> >> >>"
                             % (pages_id_placeholder, content_id, font_id)).encode("latin-1")))
    pages_id = add(("<< /Type /Pages /Kids [%s] /Count %d >>" % (" ".join("%d 0 R" % p for p in page_ids), len(page_ids))).encode("latin-1"))
    assert pages_id == pages_id_placeholder
    catalog_id = add(("<< /Type /Catalog /Pages %d 0 R >>" % pages_id).encode("latin-1"))
    output = bytearray(b"%PDF-1.4\n")
    offsets = []
    for number, body in enumerate(objects, start=1):
        offsets.append(len(output))
        output += b"%d 0 obj\n" % number + body + b"\nendobj\n"
    xref_offset = len(output)
    output += b"xref\n0 %d\n0000000000 65535 f \n" % (len(objects) + 1)
    for offset in offsets:
        output += b"%010d 00000 n \n" % offset
    output += b"trailer\n<< /Size %d /Root %d 0 R >>\nstartxref\n%d\n%%%%EOF\n" % (len(objects) + 1, catalog_id, xref_offset)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as pdf_file:
        pdf_file.write(bytes(output))
    return path


def check_pdf(path):
    with open(path, "rb") as pdf_file:
        data = pdf_file.read()
    if not data.startswith(b"%PDF-") or not data.rstrip().endswith(b"%%EOF"):
        return "bad PDF header/trailer"
    xref_offset = int(data.rsplit(b"startxref", 1)[1].split()[0])
    if data[xref_offset:xref_offset + 4] != b"xref":
        return "startxref does not point at xref"
    entries = data[xref_offset:].split(b"\n")[3:]
    for entry in entries:
        if not entry.endswith(b" n ") and not entry.endswith(b" n"):
            break
        offset = int(entry[:10])
        if not re.match(rb"\d+ 0 obj", data[offset:offset + 12]):
            return "xref offset %d is not an object" % offset
    return None


def write_terminal_script(directory, row_id, text_path):
    """A .command file Terminal runs in a new window: prints the text, then
    waits (its pid goes to <id>.pid so the run can end it afterwards)."""
    script_path = os.path.join(directory, "%s.command" % row_id)
    pid_path = os.path.join(directory, "%s.pid" % row_id)
    with open(script_path, "w", encoding="utf-8") as script_file:
        script_file.write("#!/bin/bash\nclear\ncat %s\necho $$ > %s\nexec sleep 900\n" % (shell_quote(text_path), shell_quote(pid_path)))
    os.chmod(script_path, 0o700)
    return script_path, pid_path


def shell_quote(text):
    return "'" + text.replace("'", "'\\''") + "'"


# ---------------------------------------------------------------------------
# Talking to Clicky (live runs only; --dry-run never gets here).

def clickyctl(command, timeout_seconds=120):
    completed = subprocess.run([CLICKYCTL, json.dumps(command), str(timeout_seconds)],
                               capture_output=True, text=True, timeout=timeout_seconds + 15)
    try:
        return json.loads(completed.stdout.strip() or "{}")
    except ValueError:
        return {"ok": False, "error": "bad reply: " + completed.stdout[:200]}


class UsageLimitStop(Exception):
    pass


def ask_with_backoff(prompt, speak):
    """ask{speak}; usage-limit errors wait 30 s, 1, 2, 4, 8 min, then stop the run."""
    waits = backoff_schedule()
    while True:
        reply = clickyctl({"cmd": "ask", "text": prompt, "speak": speak}, 240)
        error_text = str(reply.get("error") or "")
        turn = read_turn(reply.get("turnDir"))
        if turn and turn.get("error"):
            error_text += " " + str(turn["error"])
        if not is_usage_limit_error(error_text):
            return reply, turn
        if not waits:
            raise UsageLimitStop(error_text[:200])
        wait_seconds = waits.pop(0)
        print("  usage limit (%s); waiting %d s" % (error_text[:80], wait_seconds), flush=True)
        time.sleep(wait_seconds)


def read_turn(turn_directory):
    if not turn_directory:
        return None
    try:
        with open(os.path.join(turn_directory, "turn.json"), encoding="utf-8") as turn_file:
            return json.load(turn_file)
    except (OSError, ValueError):
        return None


def read_mark_events(turn_directory):
    events = []
    try:
        with open(os.path.join(turn_directory or "", "marks.jsonl"), encoding="utf-8") as events_file:
            for line in events_file:
                try:
                    events.append(json.loads(line))
                except ValueError:
                    pass
    except OSError:
        pass
    return events


def axfind(finder, bundle):
    """Resolves one truth finder (trying title alternatives). Returns
    (frames or None, visibleFraction, error)."""
    last_error = "no query"
    for query in finder_alternatives(finder):
        command = dict(query, cmd="axfind", bundle=bundle)
        if bundle in ELECTRON_BUNDLES:
            command["electron"] = True
        reply = clickyctl(command, 30)
        if reply.get("ok"):
            result = reply["result"]
            if query.get("all"):
                frames = dedupe_nested(result.get("frames") or [])
                fractions = result.get("visibleFractions") or [1.0]
                return frames, min(fractions) if fractions else 0.0, None
            return [result["frameCG"]], result.get("visibleFraction", 1.0), None
        last_error = str(reply.get("error"))
        sample = (reply.get("result") or {}).get("sample") if isinstance(reply.get("result"), dict) else None
        if sample:
            last_error += " | seen: " + "; ".join(sample[:8])
    return None, 0.0, last_error


def resolve_truth(finders, bundle):
    """Frames per step ("all" finders expand to several), or an error."""
    frames = []
    lowest_visible = 1.0
    for finder in finders:
        found, visible, error = axfind(finder, bundle)
        if found is None:
            return None, 0.0, "truth: %s" % error
        frames.extend(found)
        lowest_visible = min(lowest_visible, visible)
    return frames, lowest_visible, None


def open_app(app_name, target=None):
    if "clicky" in app_name.lower() or (target and "clicky.app" in target.lower()):
        raise RuntimeError("refusing to open Clicky from the eval")
    arguments = ["open", "-a", app_name] + ([target] if target else [])
    return subprocess.run(arguments, capture_output=True, text=True).returncode == 0


def app_installed(app_name):
    """Looks in the usual folders (never `open -R`, which would show Finder)."""
    folders = ["/Applications", "/System/Applications", "/System/Applications/Utilities", os.path.expanduser("~/Applications")]
    return any(os.path.isdir(os.path.join(folder, app_name + ".app")) for folder in folders)


# ---------------------------------------------------------------------------
# Defaults (config arms), saved and restored around a run.

def snapshot_defaults(keys):
    snapshot = {}
    for key in keys:
        completed = subprocess.run(["defaults", "read", DEFAULTS_DOMAIN, key], capture_output=True, text=True)
        snapshot[key] = completed.stdout.strip() if completed.returncode == 0 else None
    return snapshot


def write_default(key, value):
    if value is None:
        subprocess.run(["defaults", "delete", DEFAULTS_DOMAIN, key], capture_output=True)
    elif isinstance(value, bool):
        subprocess.run(["defaults", "write", DEFAULTS_DOMAIN, key, "-bool", "YES" if value else "NO"], check=False)
    elif isinstance(value, int):
        subprocess.run(["defaults", "write", DEFAULTS_DOMAIN, key, "-int", str(value)], check=False)
    else:
        subprocess.run(["defaults", "write", DEFAULTS_DOMAIN, key, str(value)], check=False)


def restore_defaults(snapshot):
    for key, raw_value in snapshot.items():
        if raw_value is None:
            write_default(key, None)
        elif raw_value in ("0", "1") and key != "v2.grounding.imageTier":
            write_default(key, raw_value == "1")
        else:
            write_default(key, raw_value)


def apply_config(config_name):
    for key, value in CONFIGS[config_name].items():
        write_default(key, value)
    time.sleep(0.5)


# ---------------------------------------------------------------------------
# Chrome over the DevTools protocol (127.0.0.1 only, throwaway profile).

class DevToolsSocket:
    """Minimal RFC 6455 client (text frames, masking, ping/pong) for CDP."""

    def __init__(self, websocket_url, timeout_seconds=15):
        match = re.match(r"ws://(127\.0\.0\.1|localhost):(\d+)(/.*)", websocket_url)
        if not match:
            raise RuntimeError("refusing non-loopback DevTools URL %s" % websocket_url)
        host, port, path = match.group(1), int(match.group(2)), match.group(3)
        self.sock = socket.create_connection((host, port), timeout=timeout_seconds)
        key = base64.b64encode(os.urandom(16)).decode("ascii")
        request = ("GET %s HTTP/1.1\r\nHost: %s:%d\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                   "Sec-WebSocket-Key: %s\r\nSec-WebSocket-Version: 13\r\n\r\n" % (path, host, port, key))
        self.sock.sendall(request.encode("ascii"))
        response = b""
        while b"\r\n\r\n" not in response:
            chunk = self.sock.recv(4096)
            if not chunk:
                raise RuntimeError("DevTools handshake closed")
            response += chunk
        if b" 101 " not in response.split(b"\r\n", 1)[0]:
            raise RuntimeError("DevTools handshake failed: %r" % response[:80])
        self.buffer = response.split(b"\r\n\r\n", 1)[1]
        self.next_id = 0

    def _read_exact(self, count):
        while len(self.buffer) < count:
            chunk = self.sock.recv(65536)
            if not chunk:
                raise RuntimeError("DevTools socket closed")
            self.buffer += chunk
        data, self.buffer = self.buffer[:count], self.buffer[count:]
        return data

    def _send_frame(self, opcode, payload):
        header = bytearray([0x80 | opcode])
        length = len(payload)
        if length < 126:
            header.append(0x80 | length)
        elif length < 65536:
            header += bytes([0x80 | 126]) + struct.pack(">H", length)
        else:
            header += bytes([0x80 | 127]) + struct.pack(">Q", length)
        mask = os.urandom(4)
        masked = bytes(byte ^ mask[index % 4] for index, byte in enumerate(payload))
        self.sock.sendall(bytes(header) + mask + masked)

    def _receive_message(self):
        message = b""
        while True:
            first, second = self._read_exact(2)
            opcode, length = first & 0x0F, second & 0x7F
            if length == 126:
                length = struct.unpack(">H", self._read_exact(2))[0]
            elif length == 127:
                length = struct.unpack(">Q", self._read_exact(8))[0]
            mask = self._read_exact(4) if second & 0x80 else None
            payload = self._read_exact(length)
            if mask:
                payload = bytes(byte ^ mask[index % 4] for index, byte in enumerate(payload))
            if opcode == 0x9:
                self._send_frame(0xA, payload)
                continue
            if opcode == 0x8:
                raise RuntimeError("DevTools socket closed by Chrome")
            message += payload
            if first & 0x80:
                return json.loads(message.decode("utf-8"))

    def call(self, method, params=None):
        self.next_id += 1
        self._send_frame(0x1, json.dumps({"id": self.next_id, "method": method, "params": params or {}}).encode("utf-8"))
        while True:
            message = self._receive_message()
            if message.get("id") == self.next_id:
                if "error" in message:
                    raise RuntimeError("%s: %s" % (method, message["error"]))
                return message.get("result", {})

    def close(self):
        try:
            self.sock.close()
        except OSError:
            pass


class ChromeHarness:
    """Chrome with --remote-debugging-address=127.0.0.1 and a temp profile, in
    --app mode (no tab strip or address bar), one window, reused across rows."""

    def __init__(self, debug_port, origin, size):
        if not os.path.exists(CHROME_BINARY):
            raise RuntimeError("Google Chrome is not installed")
        self.debug_port = debug_port
        self.profile_directory = tempfile.mkdtemp(prefix="clicky-eval-chrome-")
        self.process = subprocess.Popen([
            CHROME_BINARY, "--remote-debugging-address=127.0.0.1", "--remote-debugging-port=%d" % debug_port,
            "--user-data-dir=%s" % self.profile_directory, "--no-first-run", "--no-default-browser-check",
            "--disable-extensions", "--disable-sync", "--disable-background-networking", "--disable-component-update",
            "--disable-features=Translate,MediaRouter", "--autoplay-policy=no-user-gesture-required",
            "--window-position=%d,%d" % origin, "--window-size=%d,%d" % size, "--app=about:blank",
        ], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        self.page = None
        self.browser = None
        self.target_id = None
        deadline = time.time() + 20
        while time.time() < deadline and self.page is None:
            try:
                targets = json.loads(urllib.request.urlopen("http://127.0.0.1:%d/json/list" % debug_port, timeout=2).read())
                version = json.loads(urllib.request.urlopen("http://127.0.0.1:%d/json/version" % debug_port, timeout=2).read())
                page = next(t for t in targets if t.get("type") == "page")
                self.target_id = page["id"]
                self.page = DevToolsSocket(page["webSocketDebuggerUrl"])
                self.browser = DevToolsSocket(version["webSocketDebuggerUrl"])
            except (OSError, ValueError, StopIteration, RuntimeError):
                time.sleep(0.3)
        if self.page is None:
            self.stop()
            raise RuntimeError("Chrome DevTools did not come up on 127.0.0.1:%d" % debug_port)

    def load(self, url, timeout_seconds=15):
        """Navigates, waits for window.__ready, returns (truth, window metrics)."""
        self.page.call("Page.navigate", {"url": url})
        deadline = time.time() + timeout_seconds
        while time.time() < deadline:
            ready = self.page.call("Runtime.evaluate", {"expression": "window.__ready === true", "returnByValue": True})
            if ready.get("result", {}).get("value") is True:
                break
            time.sleep(0.2)
        else:
            raise RuntimeError("page never set window.__ready: %s" % url)
        expression = ("JSON.stringify({truth: window.__truth || null, error: window.__error || null, innerWidth: innerWidth, "
                      "innerHeight: innerHeight, outerWidth: outerWidth, outerHeight: outerHeight, screenX: screenX, "
                      "screenY: screenY, dpr: devicePixelRatio})")
        value = self.page.call("Runtime.evaluate", {"expression": expression, "returnByValue": True})["result"]["value"]
        page_state = json.loads(value)
        if page_state.get("error"):
            raise RuntimeError("page error: %s" % page_state["error"])
        window = self.browser.call("Browser.getWindowForTarget", {"targetId": self.target_id})
        page_state["bounds"] = window["bounds"]
        return page_state

    def stop(self):
        for connection in (self.page, self.browser):
            if connection:
                connection.close()
        if self.process and self.process.poll() is None:
            self.process.terminate()
            try:
                self.process.wait(10)
            except subprocess.TimeoutExpired:
                self.process.kill()
        shutil.rmtree(self.profile_directory, ignore_errors=True)


class LocalServer:
    """python3 -m http.server --bind 127.0.0.1 over Tools/eval/canvas."""

    def __init__(self, port):
        self.port = port
        self.process = subprocess.Popen([sys.executable, "-I", "-m", "http.server", str(port), "--bind", "127.0.0.1",
                                         "--directory", CANVAS_DIRECTORY], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        deadline = time.time() + 10
        while time.time() < deadline:
            try:
                urllib.request.urlopen("http://127.0.0.1:%d/manifest.json" % port, timeout=1).read()
                return
            except OSError:
                time.sleep(0.2)
        self.stop()
        raise RuntimeError("local http server did not start on 127.0.0.1:%d" % port)

    def url(self, path):
        return "http://127.0.0.1:%d%s" % (self.port, path)

    def stop(self):
        if self.process.poll() is None:
            self.process.terminate()
            self.process.wait(5)


# ---------------------------------------------------------------------------
# Results file (resumable).

class Results:
    FINAL_STATUSES = {"scored", "truth-missing", "truth-hidden", "skipped"}

    def __init__(self, run_directory):
        os.makedirs(run_directory, exist_ok=True)
        self.path = os.path.join(run_directory, "results.jsonl")
        self.records = {}
        if os.path.exists(self.path):
            with open(self.path, encoding="utf-8") as results_file:
                for line in results_file:
                    try:
                        record = json.loads(line)
                    except ValueError:
                        continue
                    self.records[record["key"]] = record

    def done(self, key):
        return self.records.get(key, {}).get("status") in self.FINAL_STATUSES

    def add(self, record):
        self.records[record["key"]] = record
        with open(self.path, "a", encoding="utf-8") as results_file:
            results_file.write(json.dumps(record, sort_keys=True) + "\n")

    def all(self):
        return list(self.records.values())


def score_turn(record, kind, frames, turn, turn_directory, config_name, spoken, dense_texts=None):
    """Fills the scored fields of `record` from one turn."""
    tags = turn.get("tags", [])
    record["tags"] = [tag.get("raw") for tag in tags]
    record["hit"], record["reason"] = score_by_kind(kind, frames, tags, base_rule)
    record["hitDrawn"], record["reasonDrawn"] = score_by_kind(kind, frames, tags, drawn_rule)
    mark_events = read_mark_events(turn_directory)
    record["caption"] = caption_checks(turn, mark_events)
    record["latency"] = turn_latencies(turn)
    record["evidence"] = config_evidence(config_name, turn, turn_directory)
    record["spoken"] = spoken
    record["status"] = "scored"


# ---------------------------------------------------------------------------
# Set runners.

def require_clicky():
    return GE.require_single_clean_clicky()


def spoken_for(index, spoken_rows):
    return index < spoken_rows


def run_fixture_set(results, configs, displays, row_limit, spoken_rows):
    rows = GE.read_prompt_rows()[:row_limit] if row_limit else GE.read_prompt_rows()
    for config_name in configs:
        apply_config(config_name)
        for display_index in displays:
            for row_number, row in enumerate(rows, start=1):
                key = "fixture:%s:d%d:r%02d" % (config_name, display_index, row_number)
                if results.done(key):
                    continue
                keys = [k.strip() for k in row["keys"].split(",") if k.strip()]
                record = {"key": key, "set": "fixture", "config": config_name, "display": display_index, "row": row_number,
                          "prompt": row["prompt"], "kind": row["kind"], "group": row["kind"], "status": "error"}
                clickyctl({"cmd": "reset"}, 10)
                process, ground_truth = GE.start_fixture(display_index, row.get("flags", ""))
                try:
                    if not ground_truth:
                        record["reason"] = "fixture not ready"
                        results.add(record)
                        continue
                    frames_by_key = {item["key"]: item["frameCG"] for item in ground_truth["items"]}
                    speak = spoken_for(row_number - 1, spoken_rows) and config_name == FINAL_CONFIG
                    reply, turn = ask_with_backoff(row["prompt"], speak)
                    if not reply.get("ok") or not turn:
                        record["reason"] = "ask failed: %s" % reply.get("error")
                        results.add(record)
                        continue
                    turn_directory = reply["turnDir"]
                    record["turnDir"] = turn_directory
                    tags = turn.get("tags", [])
                    if row["kind"] == "cover":
                        record["hit"], record["reason"] = GE.score_cover_row(keys, tags, frames_by_key, turn.get("rawResponse", ""))
                        record["tags"] = [t.get("raw") for t in tags]
                        record["caption"] = caption_checks(turn, read_mark_events(turn_directory))
                        record["latency"] = turn_latencies(turn)
                        record["evidence"] = config_evidence(config_name, turn, turn_directory)
                        record["status"] = "scored"
                    else:
                        frames = [GE.target_frame(k, frames_by_key) for k in keys]
                        if any(f is None for f in frames):
                            record["status"], record["reason"] = "truth-missing", "unknown fixture key"
                        else:
                            score_turn(record, "multi" if len(frames) > 1 else "point", frames, turn, turn_directory, config_name, speak)
                    results.add(record)
                finally:
                    GE.stop_fixture(process, ground_truth)
                print("fixture %-11s d%d r%02d %-5s %s" % (config_name, display_index, row_number,
                                                           "HIT" if record.get("hit") else record.get("status"), row["prompt"]), flush=True)


def prepare_run_fixtures(run_directory):
    """Fresh copy of final/fixtures (apps may write into it) + the PDF."""
    destination = os.path.join(run_directory, "fixtures")
    if not os.path.exists(destination):
        shutil.copytree(FIXTURES_DIRECTORY, destination)
    write_fixture_pdf(os.path.join(destination, "preview", "guide.pdf"))
    return destination


def run_setup(row, fixtures_directory, server, previous_setup):
    app_name = row["app"]
    setup = row["setup"]
    if setup == "app":
        open_app(app_name)
    elif setup.startswith("file:"):
        open_app(app_name, os.path.join(fixtures_directory, setup[len("file:"):]))
    elif setup.startswith("url:"):
        if setup != previous_setup:
            for path in setup[len("url:"):].split("|"):
                open_app(app_name, server.url(path))
                time.sleep(0.8)
        else:
            open_app(app_name)
    time.sleep(3.0 if setup != previous_setup else 1.2)


def run_ax_set(results, config_name, run_directory, server, rows, spoken_rows, probe_only=False):
    fixtures_directory = prepare_run_fixtures(run_directory)
    installed = {}
    previous_setup = None
    for index, row in enumerate(rows):
        key = "ax:%s:%s" % ("probe" if probe_only else config_name, row["id"])
        if results.done(key):
            continue
        record = {"key": key, "set": "ax", "config": config_name, "id": row["id"], "app": row["app"], "group": row["app"],
                  "prompt": row["prompt"], "kind": row["kind"], "status": "error"}
        if row["app"] not in installed:
            installed[row["app"]] = app_installed(row["app"])
        if not installed[row["app"]]:
            record["status"], record["reason"] = "skipped", "%s not installed" % row["app"]
            results.add(record)
            continue
        clickyctl({"cmd": "reset"}, 10)
        clickyctl({"cmd": "clear"}, 10)
        run_setup(row, fixtures_directory, server, previous_setup)
        previous_setup = row["setup"]
        finders = json.loads(row["truth"])
        frames, visible, error = resolve_truth(finders, row["bundle"])
        record["truth"] = frames
        if error:
            record["status"], record["reason"] = "truth-missing", error
        elif visible < 0.5:
            record["status"], record["reason"] = "truth-hidden", "visible fraction %.2f" % visible
        elif probe_only:
            record["status"], record["reason"] = "scored", "probe only"
            record["hit"] = None
        if record["status"] == "error":
            speak = spoken_for(index, spoken_rows)
            reply, turn = ask_with_backoff(row["prompt"], speak)
            if not reply.get("ok") or not turn:
                record["reason"] = "ask failed: %s" % reply.get("error")
            else:
                record["turnDir"] = reply["turnDir"]
                score_turn(record, row["kind"], frames, turn, reply["turnDir"], config_name, speak)
                after, _, _ = resolve_truth(finders, row["bundle"])
                if after and any(max(abs(a - b) for a, b in zip(first, second)) > 2 for first, second in zip(frames, after)):
                    record["truthMoved"] = True
        results.add(record)
        print("ax %-8s %-5s %-18s %-12s %s" % (row["id"], "HIT" if record.get("hit") else "", row["app"], record["status"], row["prompt"]), flush=True)


def run_canvas_set(results, config_name, run_directory, server, rows, spoken_rows, chrome_port, chrome_origin, chrome_size):
    manifest = read_manifest()
    terminal_directory = os.path.join(run_directory, "terminal")
    os.makedirs(terminal_directory, exist_ok=True)
    chrome = None
    try:
        for index, row in enumerate(rows):
            key = "canvas:%s:%s" % (config_name, row["id"])
            if results.done(key):
                continue
            record = {"key": key, "set": "canvas", "config": config_name, "id": row["id"], "page": row["page"], "group": row["page"],
                      "prompt": row["prompt"], "kind": row["kind"], "status": "error"}
            keys = json.loads(row["keys"])
            params = parse_params(row["params"])
            clickyctl({"cmd": "reset"}, 10)
            clickyctl({"cmd": "clear"}, 10)
            dense_texts = None
            pid_path = None
            try:
                if row["page"] == "terminal":
                    script_path, pid_path = write_terminal_script(terminal_directory, row["id"], os.path.join(CANVAS_DIRECTORY, "terminal", params["file"]))
                    open_app("Terminal", script_path)
                    time.sleep(3.0)
                    frames = []
                    for text in keys:
                        found, visible, error = axfind({"role": "AXTextArea", "window": "only-main", "text": text}, TERMINAL_BUNDLE)
                        if found is None:
                            raise LookupError(error)
                        frames.extend(found)
                else:
                    if chrome is None:
                        chrome = ChromeHarness(chrome_port, chrome_origin, chrome_size)
                    page_file = manifest[row["page"]]["file"]
                    state = chrome.load(server.url("/%s?%s" % (page_file, row["params"])))
                    time.sleep(1.0)
                    truth_items = state["truth"]["items"]
                    frames = [css_to_cg(truth_items[k], state) for k in keys]
                    record["window"] = {"bounds": state["bounds"], "innerWidth": state["innerWidth"], "dpr": state["dpr"]}
                    web_area, _, _ = axfind({"role": "AXWebArea", "window": "only-main"}, CHROME_BUNDLE)
                    if web_area:
                        origin = css_to_cg([0, 0, 0, 0], state)
                        record["webAreaDeltaPt"] = round(max(abs(web_area[0][0] - origin[0]), abs(web_area[0][1] - origin[1])), 2)
                    if row["kind"] == "dense":
                        dense_texts = {
                            "text": [css_to_cg(truth_items[k + "_text"], state) for k in keys],
                            "all": [css_to_cg(rect, state) for rect in state["truth"].get("texts", [])],
                        }
                record["truth"] = frames
                speak = spoken_for(index, spoken_rows)
                reply, turn = ask_with_backoff(row["prompt"], speak)
                if not reply.get("ok") or not turn:
                    record["reason"] = "ask failed: %s" % reply.get("error")
                else:
                    record["turnDir"] = reply["turnDir"]
                    score_turn(record, row["kind"], frames, turn, reply["turnDir"], config_name, speak)
                    if dense_texts:
                        displays = [s["boundsCG"] for s in turn.get("screens", [])]
                        underlines, labels, reason = score_dense(dense_texts["text"], turn.get("tags", []), dense_texts["all"], displays)
                        record["denseUnderlines"], record["denseLabelsClear"], record["denseReason"] = underlines, labels, reason
            except LookupError as error:
                record["status"], record["reason"] = "truth-missing", str(error)
            except (RuntimeError, KeyError, OSError) as error:
                record["reason"] = "setup: %s" % error
            finally:
                if pid_path and os.path.exists(pid_path):
                    try:
                        with open(pid_path) as pid_file:
                            os.kill(int(pid_file.read().strip()), 15)
                    except (OSError, ValueError):
                        pass
            results.add(record)
            print("canvas %-6s %-5s %-9s %-12s %s" % (row["id"], "HIT" if record.get("hit") else "", row["page"], record["status"], row["prompt"]), flush=True)
    finally:
        if chrome:
            chrome.stop()


def figma_status():
    if not app_installed("Figma"):
        return "skipped: Figma not installed"
    support_directory = os.path.expanduser("~/Library/Application Support/Figma")
    if not os.path.isdir(support_directory) or not any("session" in name.lower() or "cookies" in name.lower() for name in os.listdir(support_directory)):
        return "skipped: Figma not logged in"
    return "skipped: Figma rows not written yet (installed and logged in)"


# ---------------------------------------------------------------------------
# Report.

def rate_cell(records, field="hit"):
    subset = [r for r in records if r.get(field) is not None]
    if not subset:
        return "-", None
    hits = sum(1 for r in subset if r.get(field))
    low, high = wilson(hits, len(subset))
    return "%d/%d (%.1f%%, %.1f–%.1f%%)" % (hits, len(subset), 100.0 * hits / len(subset), 100 * low, 100 * high), hits / float(len(subset))


def board_parse_rate():
    answers = sorted(name for name in os.listdir(GEN_BOARDS_DIRECTORY) if name.endswith(".txt") and name[:-4].isdigit()) if os.path.isdir(GEN_BOARDS_DIRECTORY) else []
    if not answers:
        return "not run (no build/eval/gen_boards/*.txt; run `python3 -I Tools/eval/gen_boards.py`)"
    try:
        subprocess.run(["swift", "build", "--package-path", PACKAGE_PATH, "--product", "cwb-check"], check=True, capture_output=True)
        bin_directory = subprocess.run(["swift", "build", "--package-path", PACKAGE_PATH, "--show-bin-path"], check=True,
                                       capture_output=True, text=True).stdout.strip()
    except (OSError, subprocess.CalledProcessError) as error:
        return "cwb-check build failed: %s" % error
    parsed = 0
    for name in answers:
        completed = subprocess.run([os.path.join(bin_directory, "cwb-check"), os.path.join(GEN_BOARDS_DIRECTORY, name)], capture_output=True, text=True)
        try:
            parsed += 1 if json.loads(completed.stdout.strip()).get("ok") else 0
        except ValueError:
            pass
    low, high = wilson(parsed, len(answers))
    return "%d/%d (%.1f%%, Wilson %.1f–%.1f%%) parse without the Haiku repair" % (parsed, len(answers), 100.0 * parsed / len(answers), 100 * low, 100 * high)


def code_probe_summary():
    for name in ("codeprobe.txt", "codeprobe.log", "codeprobe.json"):
        path = os.path.join(REPO_ROOT, "build", "eval", name)
        if os.path.exists(path):
            with open(path, encoding="utf-8", errors="replace") as probe_file:
                text = probe_file.read()
            counts = {word: len(re.findall(r"\b%s\b" % word, text)) for word in ("PASS", "FAIL", "INCONCLUSIVE")}
            return "build/eval/%s: %d PASS, %d FAIL, %d INCONCLUSIVE" % (name, counts["PASS"], counts["FAIL"], counts["INCONCLUSIVE"])
    return "no results file (run `Tools/codeprobe.sh | tee build/eval/codeprobe.txt`)"


def write_report(records, output_path, ping_result, figma_note):
    lines = ["## P6.11 final eval", ""]
    lines.append("- Build: `%s`; date %s; final config `%s`" % ((ping_result or {}).get("sha", "?"), time.strftime("%Y-%m-%d %H:%M"), FINAL_CONFIG))
    lines.append("- Rules: box centre in truth + 2 pt (area <= 4x + 400 pt²), POINT + 4 pt; drawn rule from grounding_eval.py; "
                 "multi in order; all = every instance its own mark; dense = underlines + labels clear of table text.")
    lines.append("- Wilson 95 % intervals in brackets. Rows whose truth could not be read (truth-missing / truth-hidden) are not in n.")
    lines.append("")
    scored = [r for r in records if r.get("status") == "scored" and r.get("hit") is not None]

    fixture = [r for r in scored if r["set"] == "fixture"]
    if fixture:
        lines += ["### Configs on the 40-row fixture", "", "| config | hits (rule) | drawn rule | Δ vs baseline | setting reached the turn |", "|---|---|---|---|---|"]
        baseline_rate = rate_cell([r for r in fixture if r["config"] == "baseline"])[1]
        for config_name in CONFIG_ORDER:
            subset = [r for r in fixture if r["config"] == config_name]
            if not subset:
                continue
            cell, rate = rate_cell(subset)
            drawn_cell, _ = rate_cell(subset, "hitDrawn")
            delta = "-" if baseline_rate is None or rate is None or config_name == "baseline" else "%+.1f pt" % (100 * (rate - baseline_rate))
            evidence_notes = []
            for setting in ("badges", "lists", "verify"):
                values = [r.get("evidence", {}).get(setting) for r in subset]
                known = [v for v in values if v is not None]
                if not known:
                    evidence_notes.append("%s: no evidence" % setting)
                elif not all(known):
                    evidence_notes.append("%s: NOT applied on %d/%d" % (setting, known.count(False), len(known)))
            ratios = sorted({r.get("evidence", {}).get("imagePxPerPt") for r in subset if r.get("evidence", {}).get("imagePxPerPt")})
            if ratios:
                evidence_notes.append("img px/pt %s" % "/".join(str(x) for x in ratios[:3]))
            lines.append("| %s | %s | %s | %s | %s |" % (config_name, cell, drawn_cell, delta, "; ".join(evidence_notes) or "ok"))
        lines.append("")

    for set_name, title in (("ax", "AX-rich apps"), ("canvas", "Canvas, video, dense table and Terminal")):
        subset = [r for r in scored if r["set"] == set_name]
        all_rows = [r for r in records if r["set"] == set_name]
        if not all_rows:
            continue
        lines += ["### %s" % title, ""]
        set_baseline_rate = rate_cell([r for r in subset if r["config"] == "baseline"])[1]
        fixture_baseline_rate = rate_cell([r for r in fixture if r["config"] == "baseline"])[1]
        for config_name in sorted({r["config"] for r in subset}, key=lambda c: CONFIG_ORDER.index(c) if c in CONFIG_ORDER else 99):
            arm = [r for r in subset if r["config"] == config_name]
            cell, rate = rate_cell(arm)
            drawn_cell, _ = rate_cell(arm, "hitDrawn")
            if set_baseline_rate is not None and config_name != "baseline":
                delta = "; Δ vs baseline arm %+.1f pt" % (100 * (rate - set_baseline_rate))
            elif fixture_baseline_rate is not None and config_name != "baseline":
                delta = "; vs fixture baseline %.1f%% (no baseline arm on this set)" % (100 * fixture_baseline_rate)
            else:
                delta = ""
            lines.append("- **%s**: %s; drawn rule %s%s" % (config_name, cell, drawn_cell, delta))
        lines += ["", "| group | %s | drawn |" % FINAL_CONFIG, "|---|---|---|"]
        final_arm = [r for r in subset if r["config"] == FINAL_CONFIG]
        for group in sorted({r["group"] for r in final_arm}):
            group_rows = [r for r in final_arm if r["group"] == group]
            lines.append("| %s | %s | %s |" % (group, rate_cell(group_rows)[0], rate_cell(group_rows, "hitDrawn")[0]))
        for kind in sorted({r["kind"] for r in final_arm}):
            kind_rows = [r for r in final_arm if r["kind"] == kind]
            lines.append("| kind: %s | %s | %s |" % (kind, rate_cell(kind_rows)[0], rate_cell(kind_rows, "hitDrawn")[0]))
        missing = [r for r in all_rows if r.get("status") in ("truth-missing", "truth-hidden", "skipped")]
        if missing:
            lines += ["", "Not scored (%d): " % len(missing) + "; ".join("%s %s (%s)" % (r.get("id"), r["status"], (r.get("reason") or "")[:60]) for r in missing[:40])]
        lines.append("")
        if set_name == "canvas":
            dense = [r for r in final_arm if r["kind"] == "dense"]
            if dense:
                underlines = sum(1 for r in dense if r.get("denseUnderlines"))
                labels_known = [r for r in dense if r.get("denseLabelsClear") is not None]
                lines.append("Dense table: underlines in order %d/%d; labels in clear space %s." % (
                    underlines, len(dense), "%d/%d" % (sum(1 for r in labels_known if r["denseLabelsClear"]), len(labels_known)) if labels_known else "not logged"))
            deltas = [r["webAreaDeltaPt"] for r in records if r.get("webAreaDeltaPt") is not None]
            if deltas:
                lines.append("Chrome truth mapping vs AXWebArea origin: max %.2f pt over %d rows." % (max(deltas), len(deltas)))
            lines.append("Figma: %s." % figma_note)
            lines.append("")

    lines += ["### Latency, captions, leaks", ""]
    for stage in ("captureDone", "firstDelta", "result", "end"):
        values = [r.get("latency", {}).get(stage) for r in scored]
        values = [v for v in values if v is not None]
        if values:
            lines.append("- keyUp → %s: p50 %.2f s, p95 %.2f s (n=%d)" % (stage, percentile(values, 0.5), percentile(values, 0.95), len(values)))
    spoken = [r for r in scored if r.get("spoken")]
    ttfa = [r.get("latency", {}).get("firstAudio") for r in spoken if r.get("latency", {}).get("firstAudio") is not None]
    lines.append("- TTFA (keyUp → firstAudio, spoken rows): " + ("p50 %.2f s, p95 %.2f s (n=%d)" % (percentile(ttfa, 0.5), percentile(ttfa, 0.95), len(ttfa)) if ttfa else "no spoken rows"))
    rtf = [r.get("latency", {}).get("rtf") for r in spoken if r.get("latency", {}).get("rtf") is not None]
    lines.append("- RTF: " + ("median %.2f (n=%d)" % (statistics.median(rtf), len(rtf)) if rtf else "not in turn.json on this build"))
    lag = [r.get("latency", {}).get("captionLagMs") for r in spoken if r.get("latency", {}).get("captionLagMs") is not None]
    lines.append("- Caption lag: " + ("p50 %.0f ms, p95 %.0f ms (n=%d)" % (percentile(lag, 0.5), percentile(lag, 0.95), len(lag)) if lag else "not in turn.json on this build (see selftest qwenCaptionSync)"))
    with_bubbles = [r for r in spoken if (r.get("caption") or {}).get("bubbleOverlap") is not None]
    lines.append("- Bubble over a mark (final placement, spoken rows): %s" % (
        "%d/%d" % (sum(1 for r in with_bubbles if r["caption"]["bubbleOverlap"]), len(with_bubbles)) if with_bubbles else "no bubble events logged"))
    lines.append("- Turns with a mark outside its display: %d/%d" % (sum(1 for r in scored if (r.get("caption") or {}).get("marksOutOfBounds")), len(scored)))
    lines.append("- Badge / id leaks (raw narration counter + ids in spoken segments): %d" % sum((r.get("caption") or {}).get("leaks", 0) for r in scored))
    moved = [r for r in records if r.get("truthMoved")]
    if moved:
        lines.append("- Truth moved > 2 pt during the ask (window changed): %s" % ", ".join(r.get("id", r["key"]) for r in moved))
    lines += ["", "### Boards and code probe", "", "- Board parse rate (cwb-check): %s" % board_parse_rate(), "- Code probe: %s" % code_probe_summary(), ""]

    misses = [r for r in scored if not r.get("hit") and r["config"] == FINAL_CONFIG]
    if misses:
        lines += ["### Misses (%s)" % FINAL_CONFIG, ""]
        for record in misses:
            lines.append("- %s `%s` (%s) -> %s; tags: %s" % (record.get("id") or record["key"], record["prompt"], record["kind"], record.get("reason"),
                                                              " ".join(t for t in (record.get("tags") or []) if t) or "none"))
        lines.append("")
    os.makedirs(os.path.dirname(output_path), exist_ok=True)
    with open(output_path, "w", encoding="utf-8") as report_file:
        report_file.write("\n".join(lines) + "\n")
    return "\n".join(lines)


# ---------------------------------------------------------------------------
# Dry run: validates every data file, touches no app.

def dry_run():
    problems = []
    manifest = read_manifest()
    ax_rows = read_tsv(AX_ASKS_PATH)
    canvas_rows = read_tsv(CANVAS_ASKS_PATH)
    problems += validate_ax_rows(ax_rows)
    problems += validate_canvas_rows(canvas_rows, manifest)
    problems += validate_static_files(manifest)
    if len(ax_rows) < MIN_AX_ASKS:
        problems.append("AX set has %d asks (< %d)" % (len(ax_rows), MIN_AX_ASKS))
    if len(canvas_rows) < MIN_CANVAS_ASKS:
        problems.append("canvas set has %d asks (< %d)" % (len(canvas_rows), MIN_CANVAS_ASKS))
    fixture_rows = GE.read_prompt_rows()
    if len(fixture_rows) != 40:
        problems.append("grounding_prompts.tsv has %d rows (expected 40)" % len(fixture_rows))
    if FINAL_CONFIG not in CONFIGS or set(CONFIG_ORDER) != set(CONFIGS):
        problems.append("config table inconsistent")
    scratch = tempfile.mkdtemp(prefix="final-eval-dry-")
    try:
        pdf_problem = check_pdf(write_fixture_pdf(os.path.join(scratch, "guide.pdf")))
        if pdf_problem:
            problems.append("fixture PDF: %s" % pdf_problem)
        script_path, _ = write_terminal_script(scratch, "dry", os.path.join(CANVAS_DIRECTORY, "terminal", "build_log.txt"))
        if subprocess.run(["/bin/bash", "-n", script_path]).returncode != 0:
            problems.append("terminal script has a syntax error")
    finally:
        shutil.rmtree(scratch, ignore_errors=True)
    for module_path in [os.path.join(CANVAS_DIRECTORY, "make_video.py"), __file__]:
        with open(module_path, encoding="utf-8") as source_file:
            compile(source_file.read(), module_path, "exec")
    low, high = wilson(147, 150)
    if not (abs(low - 0.943) < 0.001 and abs(high - 0.993) < 0.001):
        problems.append("wilson(147,150) = (%.3f, %.3f)" % (low, high))

    by_app = {}
    for row in ax_rows:
        by_app[row["app"]] = by_app.get(row["app"], 0) + 1
    by_page = {}
    for row in canvas_rows:
        by_page[row["page"]] = by_page.get(row["page"], 0) + 1
    kinds = {}
    for row in ax_rows + canvas_rows:
        kinds[row["kind"]] = kinds.get(row["kind"], 0) + 1
    print("dry run (no app touched)")
    print("  fixture set: %d rows x %d configs (%s)" % (len(fixture_rows), len(CONFIGS), ", ".join(CONFIG_ORDER)))
    print("  AX set:      %d asks  %s" % (len(ax_rows), ", ".join("%s %d" % kv for kv in by_app.items())))
    print("  canvas set:  %d asks  %s" % (len(canvas_rows), ", ".join("%s %d" % kv for kv in by_page.items())))
    print("  kinds:       %s" % ", ".join("%s %d" % kv for kv in sorted(kinds.items())))
    print("  pages: %s; video %s; fixtures: %s" % (", ".join(sorted(spec["file"] for spec in manifest.values() if "file" in spec)),
                                                  manifest["video"]["src"], ", ".join(sorted(os.listdir(FIXTURES_DIRECTORY)))))
    if problems:
        print("PROBLEMS (%d):" % len(problems))
        for problem in problems:
            print("  - " + problem)
        return 1
    print("OK: all fixtures and data files valid")
    return 0


# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--dry-run", action="store_true", help="validate data files only; touches no app")
    parser.add_argument("--probe-truth", action="store_true", help="open the test apps and resolve every AX truth with axfind; no asks")
    parser.add_argument("--report-only", action="store_true", help="rebuild the report from results.jsonl; touches no app")
    parser.add_argument("--sets", default="fixture,ax,canvas")
    parser.add_argument("--configs", default=",".join(CONFIG_ORDER), help="arms for the fixture set")
    parser.add_argument("--set-configs", default=FINAL_CONFIG, help="arms for the ax/canvas sets (e.g. verify,baseline)")
    parser.add_argument("--displays", default="0", help="fixture displays, e.g. 0,1,2")
    parser.add_argument("--fixture-rows", type=int, default=0, help="first N fixture rows (0 = all 40)")
    parser.add_argument("--apps", default="", help="only these apps (comma-separated) in the ax set")
    parser.add_argument("--limit", type=int, default=0, help="first N rows of the ax / canvas sets")
    parser.add_argument("--spoken-rows", type=int, default=0, help="first N rows of each set are spoken (captions, TTFA); talks out loud")
    parser.add_argument("--run-name", default="final")
    parser.add_argument("--port", type=int, default=8765, help="local http server port (127.0.0.1)")
    parser.add_argument("--chrome-port", type=int, default=9333, help="Chrome remote debugging port (127.0.0.1)")
    parser.add_argument("--chrome-origin", default="60,60")
    parser.add_argument("--chrome-size", default="1280,860")
    parser.add_argument("--out", default="", help="report path (default build/eval/final/<run>/EVAL-P6.11.md)")
    parser.add_argument("--append-to", default="", help="also append the report section to this file (docs/v2/EVAL.md)")
    arguments = parser.parse_args()

    if arguments.dry_run:
        sys.exit(dry_run())

    run_directory = os.path.join(RUNS_DIRECTORY, arguments.run_name)
    results = Results(run_directory)
    output_path = arguments.out or os.path.join(run_directory, "EVAL-P6.11.md")
    ping_result = None
    figma_note = figma_status() if not arguments.report_only else "see the live run"

    if not arguments.report_only:
        if dry_run() != 0:
            sys.exit("fix the data problems above first")
        ping_result = require_clicky()
        sets = [s for s in arguments.sets.split(",") if s]
        ax_rows = read_tsv(AX_ASKS_PATH)
        if arguments.apps:
            wanted_apps = {a.strip() for a in arguments.apps.split(",")}
            ax_rows = [r for r in ax_rows if r["app"] in wanted_apps]
        canvas_rows = read_tsv(CANVAS_ASKS_PATH)
        if arguments.limit:
            ax_rows, canvas_rows = ax_rows[:arguments.limit], canvas_rows[:arguments.limit]
        touched_keys = sorted({key for config in CONFIGS.values() for key in config} | {"v2.claude.effortOverride"})
        saved_defaults = snapshot_defaults(touched_keys)
        was_hands_free = bool(ping_result.get("handsFree"))
        clickyctl({"cmd": "handsfree", "on": False}, 10)
        server = LocalServer(arguments.port)
        try:
            if arguments.probe_truth:
                run_ax_set(results, "probe", run_directory, server, ax_rows, 0, probe_only=True)
            else:
                if "fixture" in sets:
                    if not os.path.exists(GE.FIXTURE_BINARY):
                        sys.exit("build the fixture first: Tools/GroundingFixture/build.sh")
                    run_fixture_set(results, [c for c in arguments.configs.split(",") if c], [int(d) for d in arguments.displays.split(",") if d],
                                    arguments.fixture_rows, arguments.spoken_rows)
                for config_name in [c for c in arguments.set_configs.split(",") if c]:
                    apply_config(config_name)
                    if "ax" in sets:
                        run_ax_set(results, config_name, run_directory, server, ax_rows, arguments.spoken_rows)
                    if "canvas" in sets:
                        origin = tuple(int(v) for v in arguments.chrome_origin.split(","))
                        size = tuple(int(v) for v in arguments.chrome_size.split(","))
                        run_canvas_set(results, config_name, run_directory, server, canvas_rows, arguments.spoken_rows,
                                       arguments.chrome_port, origin, size)
        except UsageLimitStop as stop:
            print("stopping: usage limit still hit after 8 min of backoff (%s); rerun the same command to resume" % stop, flush=True)
        finally:
            server.stop()
            restore_defaults(saved_defaults)
            clickyctl({"cmd": "handsfree", "on": was_hands_free}, 10)
            clickyctl({"cmd": "clear"}, 10)

    report = write_report(results.all(), output_path, ping_result, figma_note)
    if arguments.append_to:
        with open(arguments.append_to, "a", encoding="utf-8") as eval_file:
            eval_file.write("\n" + report + "\n")
    print("wrote %s" % output_path)


if __name__ == "__main__":
    main()
