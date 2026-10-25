#!/usr/bin/env python3
"""Unit tests for the pure checks in hard10.py (no app, no Chrome, no network).

Run: python3 -I Tools/eval/test_hard10.py
"""

import importlib.util
import os
import shutil
import struct
import tempfile
import unittest

EVAL_DIRECTORY = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location("hard10", os.path.join(EVAL_DIRECTORY, "hard10.py"))
hard10 = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(hard10)


def underline_tag(rect, raw="[MARK:underline:#1]"):
    return {"raw": raw, "kind": "mark", "drawn": {"kind": "underline", "rectCG": rect}}


def box_tag(rect, kind="rbox", raw="[MARK:box:#2|$129]"):
    return {"raw": raw, "kind": "mark", "cgPoint": [rect[0] + rect[2] / 2.0, rect[1] + rect[3] / 2.0],
            "drawn": {"kind": kind, "rectCG": rect, "radius": 8}}


def point_tag(x, y):
    return {"raw": "[POINT:#3]", "kind": "point", "cgPoint": [x, y]}


class PointRuleTests(unittest.TestCase):
    def test_inside_and_within_four_points(self):
        frame = [100, 100, 50, 20]
        self.assertTrue(hard10.point_hits_frame([125, 110], frame))
        self.assertTrue(hard10.point_hits_frame([96, 110], frame))   # 4 pt left of the frame
        self.assertTrue(hard10.point_hits_frame([125, 124], frame))  # 4 pt below the frame

    def test_five_points_outside_fails(self):
        frame = [100, 100, 50, 20]
        self.assertFalse(hard10.point_hits_frame([95, 110], frame))
        self.assertFalse(hard10.point_hits_frame([125, 125.5], frame))
        self.assertFalse(hard10.point_hits_frame(None, frame))

    def test_check_point_uses_any_tag(self):
        frame = [100, 100, 50, 20]
        passed, _ = hard10.check_point([point_tag(10, 10), point_tag(120, 110)], frame)
        self.assertTrue(passed)
        passed, _ = hard10.check_point([point_tag(10, 10)], frame)
        self.assertFalse(passed)
        passed, _ = hard10.check_point([], frame)
        self.assertFalse(passed)


class BoxTightnessTests(unittest.TestCase):
    def test_within_eight_points_on_every_edge(self):
        frame = [100, 100, 200, 150]
        self.assertTrue(hard10.box_tight(box_tag([92, 92, 216, 166]), frame))  # 8 pt out on every side
        self.assertTrue(hard10.box_tight(box_tag([100, 100, 200, 150]), frame))

    def test_nine_points_off_one_edge_fails(self):
        frame = [100, 100, 200, 150]
        self.assertFalse(hard10.box_tight(box_tag([91, 100, 209, 150]), frame))  # left edge 9 pt out
        self.assertFalse(hard10.box_tight(box_tag([100, 100, 200, 159]), frame))  # bottom edge 9 pt out

    def test_only_box_and_rbox_count(self):
        frame = [100, 100, 200, 150]
        self.assertFalse(hard10.box_tight(underline_tag([100, 250, 200, 0]), frame))
        self.assertFalse(hard10.box_tight(box_tag([100, 100, 200, 150], kind="ellipse"), frame))
        self.assertTrue(hard10.box_tight(box_tag([100, 100, 200, 150], kind="box"), frame))


class AdjacencyTests(unittest.TestCase):
    def test_rect_gap(self):
        self.assertEqual(hard10.rect_gap([0, 0, 10, 10], [20, 0, 10, 10]), 10.0)   # 10 pt apart
        self.assertEqual(hard10.rect_gap([0, 0, 10, 10], [5, 5, 10, 10]), 0.0)     # overlap
        self.assertAlmostEqual(hard10.rect_gap([0, 0, 10, 10], [13, 14, 5, 5]), 5.0)  # diagonal 3-4-5

    def test_label_at_40_passes_and_41_fails(self):
        box = [0, 0, 100, 100]
        self.assertTrue(hard10.label_is_adjacent(box, [140, 0, 50, 20]))
        self.assertFalse(hard10.label_is_adjacent(box, [141, 0, 50, 20]))

    def test_attached_label_wins_and_bubbles_are_one_to_one(self):
        first = box_tag([0, 0, 100, 100])
        second = box_tag([300, 0, 100, 100])
        first["drawn"]["label"] = {"rectCG": [0, 110, 80, 30]}
        bubbles = [[410, 0, 60, 30]]
        labels = hard10.assign_labels([[0, 0, 100, 100], [300, 0, 100, 100]], [first, second], bubbles)
        self.assertEqual(labels[0], [0, 110, 80, 30])
        self.assertEqual(labels[1], [410, 0, 60, 30])
        # one bubble cannot serve two tags
        labels = hard10.assign_labels([[0, 0, 100, 100], [60, 0, 100, 100]], [box_tag([0, 0, 100, 100]), box_tag([60, 0, 100, 100])], [[120, 0, 40, 20]])
        self.assertEqual(sum(1 for label in labels if label is not None), 1)

    def test_dedupe_bubbles_keeps_last_rect_per_label(self):
        events = [{"event": "bubble", "rectCG": [10, 0, 360, 36]}, {"event": "bubble", "rectCG": [10, 0, 360, 90]},
                  {"event": "bubble", "rectCG": [500, 0, 360, 36]}, {"event": "axRate", "marks": 1}]
        self.assertEqual(hard10.dedupe_bubbles(events), [[10, 0, 360, 90], [500, 0, 360, 36]])


class MatchingTests(unittest.TestCase):
    def test_each_frame_needs_its_own_tag(self):
        frames = [[0, 0, 100, 100], [0, 0, 100, 100]]
        tags = [point_tag(50, 50)]
        self.assertEqual(len(hard10.match_frames(frames, tags, hard10.FE.drawn_rule)), 1)
        tags.append(point_tag(60, 60))
        self.assertEqual(len(hard10.match_frames(frames, tags, hard10.FE.drawn_rule)), 2)


class DenseTableTests(unittest.TestCase):
    def rows(self):
        targets = {"Alpha": [0, 0, 1000, 30], "Delta": [0, 90, 1000, 30], "Kilo": [0, 210, 1000, 30], "Papa": [0, 390, 1000, 30]}
        others = {"Bravo": [0, 30, 1000, 30], "Echo": [0, 120, 1000, 30]}
        return targets, others

    def test_passes_with_underlines_and_legend_notes(self):
        # Each underline sits on the bottom edge of its row (row bottom = line y, within 6 pt).
        targets, others = self.rows()
        tags = [underline_tag([0, 30, 1000, 0], raw="[MARK:underline:#1|due date passed]"),
                underline_tag([0, 120, 1000, 0], raw="[MARK:underline:#2|owner missing]"),
                underline_tag([0, 240, 1000, 0], raw="[MARK:underline:#3|duplicate]"),
                underline_tag([0, 420, 1000, 0], raw="[MARK:underline:#4|no sign-off]")]
        passed, reason = hard10.check_dense(tags, targets, others, [])
        self.assertTrue(passed, reason)

    def test_missing_target_fails(self):
        targets, others = self.rows()
        tags = [underline_tag([0, 30, 1000, 0], raw="[MARK:u|a]"), underline_tag([0, 120, 1000, 0], raw="[MARK:u|b]"),
                underline_tag([0, 240, 1000, 0], raw="[MARK:u|c]")]
        passed, reason = hard10.check_dense(tags, targets, others, [])
        self.assertFalse(passed)
        self.assertIn("Papa", reason)

    def test_underline_on_other_row_fails(self):
        targets, others = self.rows()
        tags = [underline_tag([0, 30, 1000, 0], raw="[MARK:u|a]"), underline_tag([0, 120, 1000, 0], raw="[MARK:u|b]"),
                underline_tag([0, 240, 1000, 0], raw="[MARK:u|c]"), underline_tag([0, 420, 1000, 0], raw="[MARK:u|d]"),
                underline_tag([0, 150, 1000, 0], raw="[MARK:u|extra]")]
        passed, reason = hard10.check_dense(tags, targets, others, [])
        self.assertFalse(passed)
        self.assertIn("not a target", reason)

    def test_target_without_note_fails(self):
        targets, others = self.rows()
        tags = [underline_tag([0, 30, 1000, 0], raw="[MARK:u]"), underline_tag([0, 120, 1000, 0], raw="[MARK:u]"),
                underline_tag([0, 240, 1000, 0], raw="[MARK:u]"), underline_tag([0, 420, 1000, 0], raw="[MARK:u]")]
        passed, reason = hard10.check_dense(tags, targets, others, [])
        self.assertFalse(passed)
        self.assertIn("no note", reason)


class ProductBoxTests(unittest.TestCase):
    def test_three_tight_boxes_with_price_labels(self):
        red = [[100, 100, 300, 330], [500, 100, 300, 330], [900, 100, 300, 330]]
        tags = [box_tag([102, 98, 304, 334], raw="[MARK:box:#1|$129]"),
                box_tag([498, 100, 300, 330], raw="[MARK:box:#2|$64]"),
                box_tag([900, 100, 300, 330], raw="[MARK:box:#3|$89]")]
        for index, tag in enumerate(tags):
            tag["drawn"]["label"] = {"rectCG": [red[index][0], red[index][1] + 340, 120, 24]}
        passed, reason = hard10.check_boxes(tags, red, [])
        self.assertTrue(passed, reason)

    def test_box_on_wrong_card_fails(self):
        red = [[100, 100, 300, 330], [500, 100, 300, 330], [900, 100, 300, 330]]
        tags = [box_tag([100, 100, 300, 330], raw="[MARK:box:#1|$1]"),
                box_tag([500, 100, 300, 330], raw="[MARK:box:#2|$1]"),
                box_tag([300, 100, 300, 330], raw="[MARK:box:#3|$1]")]
        passed, _ = hard10.check_boxes(tags, red, [[0, 0, 1, 1]] * 3)
        self.assertFalse(passed)

    def test_label_41_points_away_fails(self):
        red = [[100, 100, 300, 330]]
        tag = box_tag([100, 100, 300, 330], raw="[MARK:box:#1|$129]")
        tag["drawn"]["label"] = {"rectCG": [441, 100, 50, 20]}
        passed, reason = hard10.check_boxes([tag], red, [])
        self.assertFalse(passed)
        self.assertIn("label", reason)

    def test_note_without_price_fails(self):
        red = [[100, 100, 300, 330]]
        tag = box_tag([100, 100, 300, 330], raw="[MARK:box:#1|nice mug]")
        tag["drawn"]["label"] = {"rectCG": [100, 440, 50, 20]}
        passed, reason = hard10.check_boxes([tag], red, [])
        self.assertFalse(passed)
        self.assertIn("price", reason)


class SettingsTests(unittest.TestCase):
    def test_first_step_on_wallpaper_and_two_steps(self):
        wallpaper = [20, 300, 180, 24]
        self.assertTrue(hard10.check_settings([point_tag(60, 310), point_tag(400, 400)], wallpaper)[0])

    def test_first_step_elsewhere_fails(self):
        wallpaper = [20, 300, 180, 24]
        self.assertFalse(hard10.check_settings([point_tag(400, 400), point_tag(60, 310)], wallpaper)[0])

    def test_single_step_fails(self):
        self.assertFalse(hard10.check_settings([point_tag(60, 310)], [20, 300, 180, 24])[0])


class ScreenshotTests(unittest.TestCase):
    def test_size_within_ten_percent_of_window_points_or_retina(self):
        self.assertTrue(hard10.screenshot_matches_window((1100, 1000), (1100, 1000), 1.0))
        self.assertTrue(hard10.screenshot_matches_window((1000, 905), (1100, 1000), 1.0))   # about 9 % short
        self.assertFalse(hard10.screenshot_matches_window((800, 1000), (1100, 1000), 1.0))  # 27 % short
        self.assertTrue(hard10.screenshot_matches_window((2200, 2000), (1100, 1000), 2.0))  # retina

    def test_png_size_reads_ihdr(self):
        scratch = tempfile.mkdtemp(prefix="hard10-test-")
        try:
            path = os.path.join(scratch, "a.png")
            with open(path, "wb") as handle:
                handle.write(b"\x89PNG\r\n\x1a\n" + struct.pack(">I", 13) + b"IHDR" + struct.pack(">II", 640, 480) + b"\x08\x06\x00\x00\x00")
            self.assertEqual(hard10.png_size(path), (640, 480))
            with open(path, "wb") as handle:
                handle.write(b"not a png at all, just text padding..")
            self.assertIsNone(hard10.png_size(path))
        finally:
            shutil.rmtree(scratch, ignore_errors=True)

    def test_snapshot_paths_prefers_reported_snap(self):
        self.assertEqual(hard10.snapshot_paths({"snaps": [{"path": "/tmp/x.png"}]}, 0), ["/tmp/x.png"])


class CodeModeTests(unittest.TestCase):
    def test_finished_detection_is_recursive(self):
        self.assertTrue(hard10.reports_finished({"ok": True, "result": {"tasks": [{"state": "finished"}]}}))
        self.assertTrue(hard10.reports_finished({"done": True}))
        self.assertFalse(hard10.reports_finished({"ok": True, "result": {"state": "awaitingApproval"}}))

    def test_check_code_needs_all_parts(self):
        diff = "+def multiply(a, b):\n+    return a * b\n"
        test = "+    def test_multiply(self):\n+        self.assertEqual(multiply(2, 3), 6)\n"
        self.assertTrue(hard10.check_code(True, diff, test, 0)[0])
        self.assertFalse(hard10.check_code(False, diff, test, 0)[0])
        self.assertFalse(hard10.check_code(True, "", test, 0)[0])
        self.assertFalse(hard10.check_code(True, diff, "", 0)[0])
        self.assertFalse(hard10.check_code(True, diff, test, 1)[0])

    def test_scratch_fixture_passes_its_own_unittest(self):
        scratch = tempfile.mkdtemp(prefix="hard10-fixture-test-")
        try:
            path = os.path.join(scratch, "clicky-scratch")
            base = hard10.ensure_scratch_repo(path)
            self.assertEqual(len(base), 40)
            self.assertEqual(hard10.ensure_scratch_repo(path), base)  # idempotent
            import subprocess
            import sys
            run = subprocess.run([sys.executable, "-m", "unittest"], cwd=path, capture_output=True, text=True, timeout=120)
            self.assertEqual(run.returncode, 0, run.stderr)
        finally:
            shutil.rmtree(scratch, ignore_errors=True)


class NoteTests(unittest.TestCase):
    def test_note_after_bar(self):
        self.assertEqual(hard10.note_of("[MARK:box:#76:M2N3G9024|wrong photo, use 4G9088's]"), "wrong photo, use 4G9088's")
        self.assertEqual(hard10.note_of("[POINT:#3]"), "")
        self.assertEqual(hard10.note_of(None), "")


# Real excerpts from the first live run (turn 20261025-161310-2311ea8c and 20261025-161343-7cabd9d6).
SIDE_SCREENS = [
    {"boundsCG": [0, 0, 3440, 1440], "displayID": 1, "header": 'SCREEN 1 "DELL S3425DW" (main, cursor here) image 2000x837 px', "n": 1},
    {"boundsCG": [-1920, 155, 1920, 1080], "displayID": 4, "header": 'SCREEN 2 "DELL S2725QC (2)" (left of main) image 1456x819 px', "n": 2},
    {"boundsCG": [3440, 198, 1920, 1080], "displayID": 5, "header": 'SCREEN 3 "DELL S2725QC (1)" (right of main) image 1456x819 px', "n": 3},
]
SIDE_SUBMIT_FRAME = [4297.31, 733.5, 84.69, 36.0]
SIDE_REAL_TAG = {"raw": '[POINT:"Submit":Submit:screen3]', "kind": "point", "screen": 3, "verified": True,
                 "cgPoint": [3885.3192892987627, 364.59999999504333]}

WHITEBOARD_EXCERPT = """<whiteboard>
{"wb":1,"title":"How DNS resolution works","dir":"LR","sections":[{"id":"agenda","title":"Agenda"},{"id":"q1","title":"Resolving example.com","q":"how does dns resolution work"},{"id":"recap","title":"Recap"}]}
{"el":"list","id":"ag","sec":"agenda","title":"Coming up","items":["Browser asks a resolver","Resolver asks root, then TLD, then authoritative","Answer comes back and gets cached"],"ordered":true}
{"el":"box","id":"br","sec":"q1","text":"Browser","shape":"round","color":"blue","icon":"safari"}
{"el":"box","id":"rec","sec":"q1","text":"Recursive resolver (your ISP or 1.1.1.1)","shape":"round","color":"purple","icon":"server.rack"}
{"el":"box","id":"root","sec":"q1","text":"Root server","shape":"rect","color":"orange"}
{"el":"box","id":"tld","sec":"q1","text":".com TLD server","shape":"rect","color":"green"}
{"el":"box","id":"auth","sec":"q1","text":"Authoritative server for example.com","shape":"rect","color":"red"}
{"el":"arrow","id":"a1","sec":"q1","from":"br","to":"rec","text":"where is example.com?","style":"solid","head":"end"}
{"el":"callout","id":"c1","sec":"q1","target":"rec","style":"tip","text":"Each answer is cached for its time to live, so repeat lookups are instant."}
{"el":"list","id":"rc","sec":"recap","title":"Key points","items":["The resolver does the legwork, not your browser"],"ordered":false}
{"step":1,"show":["ag"],"hl":["ag"],"say":"here's the plan.","focus":"agenda"}
</whiteboard>"""
WHITEBOARD_THREE_NODES = """<whiteboard>
{"el":"box","id":"br","sec":"q1","text":"Browser"}
{"el":"box","id":"rec","sec":"q1","text":"Recursive resolver"}
{"el":"box","id":"root","sec":"q1","text":"Root server"}
{"el":"arrow","id":"a1","sec":"q1","from":"br","to":"rec"}
</whiteboard>"""
BOARD_EVENTS_EXCERPT = [{"kind": "segmentStart", "segment": 3, "step": 1, "t": 1792925044.993565},
                        {"kind": "reveal", "step": 1, "t": 1792925044.993565},
                        {"kind": "stepEnd", "segment": 4, "step": 1, "t": 1792925054.0401568}]

# Real first-run codeStatus (ok reply, nothing started: the preflight refused the task).
CODE_STATUS_IDLE = {"ok": True, "error": None, "result": {
    "busy": False, "enabled": True, "lastNarration": None, "narrateProgress": True, "panelMode": "review",
    "panelVisible": False, "phase": "Idle", "queue": [], "task": None,
    "preflight": "Off: plugins load in headless runs (hyperframes, cowork-plugin-management, searchfit-seo), so the agent's init would be rejected"}}
CODE_STATUS_RUNNING = {"ok": True, "error": None, "result": {
    "busy": True, "enabled": True, "panelMode": "working", "phase": "Working", "preflight": "OK",
    "task": {"action": "edit", "repo": "clicky-scratch", "instructions": "add a function multiply with a test", "flow": "review"},
    "progress": {"step": "editing utils.py", "changedFiles": 1, "elapsedSeconds": 40, "toolCalls": 6, "running": True}}}
CODE_STATUS_REVIEW = {"ok": True, "error": None, "result": {
    "busy": False, "enabled": True, "panelMode": "review", "panelVisible": True, "phase": "Ready for review", "preflight": "OK",
    "task": {"action": "edit", "repo": "clicky-scratch", "instructions": "add a function multiply with a test", "flow": "review"},
    "review": {"header": "Review changes", "worktree": "/Users/adhyanmahajan/Projects/clicky-scratch-worktrees/multiply",
               "buttons": ["approve", "discard"], "changedFiles": ["utils.py", "tests/test_utils.py"], "blockers": []}}}

# Real first-run barge-in turns: the cancelled first turn has no engine; the follow-up is qwen.
BARGE_FIRST = {"transcript": "explain in detail, step by step and in several paragraphs, how a transistor amplifies a small signal into a larger one",
               "rawResponse": "", "speech": {"fallback": False}, "error": "CancellationError()",
               "timings": {"keyUp": 1792926019.932239}}
BARGE_FOLLOW = {"transcript": "quick one, what is the capital of France?", "rawResponse": "the capital of france is paris.",
                "speech": {"engine": "qwen", "fallback": False, "voice": "clicky-voice.wav"},
                "timings": {"keyUp": 1792926021.229897, "firstAudio": 1792926026.006393}}
BARGE_SPEAKING = {"seen": True, "engine": None, "fallback": False}


class SideDisplayTests(unittest.TestCase):
    def test_real_turn_submit_frame_is_on_right_display(self):
        # The old check used the wrong display; the frame is on SCREEN 3 (right), so containment passes
        # and only the point rule can fail.
        passed, reason = hard10.check_side([SIDE_REAL_TAG], SIDE_SUBMIT_FRAME, SIDE_SCREENS)
        self.assertFalse(passed)
        self.assertIn("no point within 4 pt", reason)
        self.assertNotIn("not on the side display", reason)

    def test_point_on_side_frame_passes(self):
        tag = {"raw": "[POINT:4300,740]", "kind": "point", "cgPoint": [4300, 740]}
        self.assertTrue(hard10.check_side([tag], SIDE_SUBMIT_FRAME, SIDE_SCREENS)[0])

    def test_frame_centre_on_main_display_fails(self):
        self.assertFalse(hard10.check_side([point_tag(120, 120)], [100, 100, 80, 36], SIDE_SCREENS)[0])

    def test_left_display_frame_passes_with_a_point(self):
        self.assertTrue(hard10.check_side([point_tag(-940, 500)], [-1000, 480, 120, 40], SIDE_SCREENS)[0])

    def test_frame_straddling_displays_uses_centre(self):
        # Centre at x=3440 is on the right display, not main (main ends at x=3440, exclusive).
        self.assertEqual(hard10.screen_under_frame([3400, 700, 80, 36], SIDE_SCREENS)["n"], 3)

    def test_no_screens_in_turn_fails(self):
        self.assertFalse(hard10.check_side([point_tag(4300, 740)], SIDE_SUBMIT_FRAME, [])[0])


class BoardTests(unittest.TestCase):
    def test_real_whiteboard_counts_box_and_callout_nodes(self):
        turn = {"boardEvents": BOARD_EVENTS_EXCERPT, "rawResponse": "intro.\n\n" + WHITEBOARD_EXCERPT}
        self.assertEqual(hard10.whiteboard_node_ids(turn["rawResponse"]), {"br", "rec", "root", "tld", "auth", "c1"})
        passed, reason = hard10.check_board(turn)
        self.assertTrue(passed, reason)

    def test_three_nodes_fail(self):
        passed, reason = hard10.check_board({"boardEvents": BOARD_EVENTS_EXCERPT, "rawResponse": WHITEBOARD_THREE_NODES})
        self.assertFalse(passed)
        self.assertIn("3 board nodes", reason)

    def test_board_not_played_fails(self):
        self.assertFalse(hard10.check_board({"boardEvents": [], "rawResponse": WHITEBOARD_EXCERPT})[0])
        self.assertFalse(hard10.check_board({"rawResponse": WHITEBOARD_EXCERPT})[0])

    def test_no_whiteboard_block_has_no_nodes(self):
        self.assertEqual(hard10.whiteboard_node_ids("just prose, no board"), set())

    def test_edges_lists_and_sections_are_not_nodes(self):
        text = '<whiteboard>\n{"el":"arrow","id":"a"}\n{"el":"edge","id":"e"}\n{"el":"list","id":"l"}\n{"el":"text","id":"t"}\n{"el":"section","id":"s"}\n</whiteboard>'
        self.assertEqual(hard10.whiteboard_node_ids(text), set())

    def test_repeated_ids_count_once(self):
        text = '<whiteboard>\n{"el":"box","id":"a"}\n{"el":"box","id":"a"}\n</whiteboard>'
        self.assertEqual(hard10.whiteboard_node_ids(text), {"a"})


class BargeInTests(unittest.TestCase):
    def test_real_turns_pass_when_speech_was_seen_playing(self):
        passed, reason = hard10.check_barge(BARGE_FIRST, BARGE_FOLLOW, BARGE_SPEAKING)
        self.assertTrue(passed, reason)

    def test_first_turn_engine_from_turn_json_is_enough(self):
        first = {"speech": {"engine": "qwen", "fallback": False, "voice": "clicky-voice.wav"}}
        self.assertTrue(hard10.check_barge(first, BARGE_FOLLOW, {"seen": False})[0])

    def test_first_engine_unknown_and_never_seen_fails(self):
        self.assertFalse(hard10.check_barge(BARGE_FIRST, BARGE_FOLLOW, {"seen": False})[0])

    def test_speechstate_engine_is_used_when_turn_has_none(self):
        self.assertTrue(hard10.check_barge(BARGE_FIRST, BARGE_FOLLOW, {"seen": True, "engine": "qwen"})[0])
        self.assertFalse(hard10.check_barge(BARGE_FIRST, BARGE_FOLLOW, {"seen": True, "engine": "system"})[0])

    def test_fallback_anywhere_fails(self):
        fallback_first = {"speech": {"fallback": True}}
        self.assertFalse(hard10.check_barge(fallback_first, BARGE_FOLLOW, BARGE_SPEAKING)[0])
        self.assertFalse(hard10.check_barge(BARGE_FIRST, BARGE_FOLLOW, {"seen": True, "fallback": True})[0])
        fallback_follow = {"speech": {"engine": "qwen", "fallback": True, "voice": "clicky-voice.wav"}}
        self.assertFalse(hard10.check_barge(BARGE_FIRST, fallback_follow, BARGE_SPEAKING)[0])

    def test_follow_up_must_be_qwen_on_clicky_voice(self):
        other_voice = {"speech": {"engine": "qwen", "fallback": False, "voice": "ref-other"}}
        system = {"speech": {"engine": "system", "fallback": False}}
        self.assertFalse(hard10.check_barge(BARGE_FIRST, other_voice, BARGE_SPEAKING)[0])
        self.assertFalse(hard10.check_barge(BARGE_FIRST, system, BARGE_SPEAKING)[0])

    def test_first_turn_on_another_voice_fails(self):
        first = {"speech": {"engine": "qwen", "fallback": False, "voice": "ref-other"}}
        self.assertFalse(hard10.check_barge(first, BARGE_FOLLOW, BARGE_SPEAKING)[0])

    def test_speaking_info_reads_a_speechstate_reply(self):
        playing = {"ok": True, "result": {"isPlaying": True, "isSpeaking": True, "captionVisible": True}}
        idle = {"ok": True, "result": {"isPlaying": False, "isSpeaking": False}}
        self.assertTrue(hard10.speaking_info(playing)["seen"])
        self.assertFalse(hard10.speaking_info(idle)["seen"])
        self.assertEqual(hard10.speaking_info({"ok": True, "result": {"isSpeaking": True, "engine": "qwen"}})["engine"], "qwen")

    def test_latency_is_key_up_to_first_audio(self):
        self.assertEqual(hard10.key_up_to_first_audio_ms(BARGE_FOLLOW), 4776.5)
        self.assertIsNone(hard10.key_up_to_first_audio_ms({}))


class CodeProgressTests(unittest.TestCase):
    def test_first_run_idle_status_is_waiting_with_preflight_reason(self):
        verdict, _ = hard10.code_progress(CODE_STATUS_IDLE)
        self.assertEqual(verdict, "waiting")
        self.assertTrue(hard10.preflight_failed(CODE_STATUS_IDLE["result"]["preflight"]))
        self.assertIn("rejected", CODE_STATUS_IDLE["result"]["preflight"])

    def test_busy_is_running(self):
        self.assertEqual(hard10.code_progress(CODE_STATUS_RUNNING)[0], "running")

    def test_review_with_worktree_is_finished(self):
        verdict, reason = hard10.code_progress(CODE_STATUS_REVIEW)
        self.assertEqual(verdict, "finished")
        self.assertIn("clicky-scratch-worktrees/multiply", reason)

    def test_review_without_worktree_is_not_finished(self):
        status = {"result": {"busy": False, "panelMode": "review", "task": {"action": "edit"}, "review": {"worktree": None}}}
        self.assertEqual(hard10.code_progress(status)[0], "waiting")

    def test_preflight_words(self):
        self.assertTrue(hard10.preflight_failed("Off"))
        self.assertTrue(hard10.preflight_failed("Preflight failed: git missing"))
        self.assertFalse(hard10.preflight_failed("Checking…"))
        self.assertFalse(hard10.preflight_failed("Not checked yet"))
        self.assertFalse(hard10.preflight_failed("OK"))


class WallpaperFinderTests(unittest.TestCase):
    def test_every_finder_is_valid_axfind(self):
        for finder in hard10.WALLPAPER_FINDERS:
            self.assertEqual(hard10.FE.validate_finder(finder, "finder"), [])

    def test_searches_any_role_by_contains_inside_the_sidebar_first(self):
        first = hard10.WALLPAPER_FINDERS[0]
        self.assertEqual(first["role"], "*")
        self.assertEqual(first["match"], "contains")
        self.assertEqual(first["title"], "Wallpaper")
        self.assertIn(first["within"]["role"], ("AXOutline", "AXList"))

    def test_sidebar_rows_cells_and_anywhere_are_all_tried(self):
        ancestors = {finder.get("ancestor") for finder in hard10.WALLPAPER_FINDERS}
        self.assertTrue({"AXRow", "AXCell", None} <= ancestors)
        self.assertIsNone(hard10.WALLPAPER_FINDERS[-1].get("within"))


class ChromeFrontTests(unittest.TestCase):
    def test_script_only_sets_or_reads_the_frontmost_flag_of_one_pid(self):
        script = hard10.frontmost_script(4242)
        self.assertIn("unix id is 4242", script)
        self.assertIn("set frontmost", script)
        read = hard10.frontmost_script(4242, activate=False)
        self.assertIn("return frontmost", read)
        for forbidden in ("click", "keystroke", "key code", "position", "bounds"):
            self.assertNotIn(forbidden, script + read)



if __name__ == "__main__":
    unittest.main()
