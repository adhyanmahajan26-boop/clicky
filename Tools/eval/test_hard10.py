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


class SideDisplayTests(unittest.TestCase):
    def test_target_must_be_on_side_display(self):
        side = [-1920, 155, 1920, 1080]
        self.assertTrue(hard10.check_side([point_tag(-900, 500)], [-1000, 480, 120, 40], side)[0])
        self.assertFalse(hard10.check_side([point_tag(-900, 500)], [100, 480, 120, 40], side)[0])


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


class BoardTests(unittest.TestCase):
    def test_four_nodes_pass(self):
        events = [{"type": "addNode", "id": "a"}, {"type": "addNode", "id": "b"}, {"type": "node", "nodeId": "c"},
                  {"type": "addNode", "id": "d"}, {"type": "addEdge", "from": "a", "to": "b"}]
        self.assertTrue(hard10.check_board({"boardEvents": events})[0])

    def test_three_nodes_or_empty_fail(self):
        self.assertFalse(hard10.check_board({"boardEvents": [{"type": "addNode", "id": "a"}, {"type": "addNode", "id": "b"}, {"type": "addNode", "id": "c"}]})[0])
        self.assertFalse(hard10.check_board({"boardEvents": []})[0])
        self.assertFalse(hard10.check_board({})[0])

    def test_repeated_node_ids_count_once(self):
        events = [{"type": "addNode", "id": "a"}, {"type": "updateNode", "id": "a"}]
        self.assertEqual(hard10.board_node_count(events), 1)


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


class BargeInTests(unittest.TestCase):
    def turn(self, engine="qwen", fallback=False, voice="ref-amber-01"):
        return {"speech": {"engine": engine, "fallback": fallback, "voice": voice},
                "timings": {"keyUp": 100.0, "firstAudio": 100.42}}

    def test_same_qwen_voice_passes(self):
        self.assertTrue(hard10.check_barge(self.turn(), self.turn())[0])

    def test_fallback_or_other_engine_fails(self):
        self.assertFalse(hard10.check_barge(self.turn(), self.turn(fallback=True))[0])
        self.assertFalse(hard10.check_barge(self.turn(), self.turn(engine="system"))[0])

    def test_voice_change_fails(self):
        self.assertFalse(hard10.check_barge(self.turn(), self.turn(voice="ref-other"))[0])
        self.assertFalse(hard10.check_barge({"speech": {"engine": "qwen"}}, {"speech": {"engine": "qwen"}})[0])

    def test_latency_is_key_up_to_first_audio(self):
        self.assertEqual(hard10.key_up_to_first_audio_ms(self.turn()), 420.0)
        self.assertIsNone(hard10.key_up_to_first_audio_ms({}))


class NoteTests(unittest.TestCase):
    def test_note_after_bar(self):
        self.assertEqual(hard10.note_of("[MARK:box:#76:M2N3G9024|wrong photo, use 4G9088's]"), "wrong photo, use 4G9088's")
        self.assertEqual(hard10.note_of("[POINT:#3]"), "")
        self.assertEqual(hard10.note_of(None), "")


if __name__ == "__main__":
    unittest.main()
