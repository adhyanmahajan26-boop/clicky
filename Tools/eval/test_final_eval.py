#!/usr/bin/env python3
"""Unit tests for the pure parts of final_eval.py (no app, no network).

Run: python3 -I Tools/eval/test_final_eval.py
"""

import importlib.util
import json
import os
import shutil
import tempfile
import unittest

EVAL_DIRECTORY = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location("final_eval", os.path.join(EVAL_DIRECTORY, "final_eval.py"))
final_eval = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(final_eval)


def box_tag(rect):
    return {"raw": "[MARK]", "cgPoint": [rect[0] + rect[2] / 2.0, rect[1] + rect[3] / 2.0], "box": list(rect)}


def point_tag(x, y):
    return {"raw": "[POINT]", "cgPoint": [x, y]}


class WilsonTests(unittest.TestCase):
    def test_reference_values(self):
        low, high = final_eval.wilson(147, 150)
        self.assertAlmostEqual(low, 0.943, places=3)
        self.assertAlmostEqual(high, 0.993, places=3)
        low, high = final_eval.wilson(54, 60)
        self.assertAlmostEqual(low, 0.799, places=3)
        self.assertAlmostEqual(high, 0.953, places=3)

    def test_edges(self):
        self.assertEqual(final_eval.wilson(0, 0), (0.0, 0.0))
        low, high = final_eval.wilson(10, 10)
        self.assertLess(low, 1.0)
        self.assertEqual(high, 1.0)
        low, high = final_eval.wilson(0, 10)
        self.assertEqual(low, 0.0)
        self.assertGreater(high, 0.0)


class HitRuleTests(unittest.TestCase):
    truth = [100, 100, 40, 20]

    def test_box_centre_tolerance_is_two_points(self):
        self.assertTrue(final_eval.base_rule(box_tag([121.5, 101, 40, 20]), self.truth))   # centre x 141.5 <= 142
        self.assertFalse(final_eval.base_rule(box_tag([123, 101, 40, 20]), self.truth))    # centre x 143
        self.assertFalse(final_eval.base_rule(box_tag([40, 60, 160, 100]), self.truth))    # area too big

    def test_point_tolerance_is_four_points(self):
        self.assertTrue(final_eval.base_rule(point_tag(143.9, 110), self.truth))
        self.assertFalse(final_eval.base_rule(point_tag(144.5, 110), self.truth))

    def test_in_order(self):
        first, second = [0, 0, 20, 20], [100, 0, 20, 20]
        tags = [box_tag(first), box_tag(second)]
        self.assertTrue(final_eval.score_in_order([first, second], tags, final_eval.base_rule)[0])
        self.assertFalse(final_eval.score_in_order([second, first], tags, final_eval.base_rule)[0])

    def test_all_instances_need_their_own_mark(self):
        first, second = [0, 0, 20, 20], [100, 0, 20, 20]
        self.assertTrue(final_eval.score_all_instances([first, second], [box_tag(second), box_tag(first)], final_eval.base_rule)[0])
        hit, reason = final_eval.score_all_instances([first, second], [box_tag(first)], final_eval.base_rule)
        self.assertFalse(hit)
        self.assertIn("1 of 2", reason)
        # Two overlapping truths, one tag hitting both: still only one instance marked.
        self.assertFalse(final_eval.score_all_instances([[0, 0, 20, 20], [1, 1, 20, 20]], [box_tag([0.5, 0.5, 20, 20])], final_eval.base_rule)[0])

    def test_drawn_underline_rule(self):
        text = [100, 100, 200, 14]
        good = {"raw": "u", "cgPoint": [200, 116], "drawn": {"kind": "underline", "rectCG": [100, 116, 200, 0]}}
        short = {"raw": "u", "cgPoint": [150, 116], "drawn": {"kind": "underline", "rectCG": [100, 116, 100, 0]}}
        self.assertTrue(final_eval.drawn_rule(good, text))
        self.assertFalse(final_eval.drawn_rule(short, text))


class GeometryTests(unittest.TestCase):
    def test_css_to_cg_at_100_percent(self):
        window = {"bounds": {"left": 60, "top": 60, "width": 1280, "height": 860}, "innerWidth": 1280, "innerHeight": 832}
        self.assertEqual(final_eval.css_to_cg([10, 20, 30, 40], window), [70.0, 108.0, 30.0, 40.0])

    def test_css_to_cg_with_page_zoom(self):
        window = {"bounds": {"left": 0, "top": 25, "width": 1000, "height": 700}, "innerWidth": 800, "innerHeight": 536}
        # zoom 1.25: content height 670 pt, top at 25 + 30.
        self.assertEqual(final_eval.css_to_cg([8, 8, 80, 16], window), [10.0, 65.0, 100.0, 20.0])

    def test_dedupe_nested(self):
        frames = [[0, 0, 100, 20], [2, 2, 50, 16], [200, 0, 100, 20], [200, 0, 100, 20]]
        self.assertEqual(final_eval.dedupe_nested(frames), [[0, 0, 100, 20], [200, 0, 100, 20]])


class CaptionTests(unittest.TestCase):
    def turn(self, tags, segments=None, mentions=0):
        return {"screens": [{"boundsCG": [0, 0, 1440, 900]}], "tags": tags, "segments": segments or [],
                "grounding": {"badgeMentionsInNarration": mentions}}

    def test_overlap_and_bounds(self):
        ring = {"raw": "r", "cgPoint": [0, 0], "drawn": {"kind": "rbox", "rectCG": [100, 100, 50, 30], "labelRectCG": [160, 100, 80, 20]}}
        outside = {"raw": "o", "cgPoint": [0, 0], "drawn": {"kind": "ellipse", "rectCG": [1420, 880, 60, 60]}}
        checks = final_eval.caption_checks(self.turn([ring, outside]), [{"event": "bubble", "rectCG": [400, 400, 300, 80]},
                                                                         {"event": "bubble", "rectCG": [150, 90, 100, 40]}])
        self.assertEqual(checks["marksOutOfBounds"], 1)
        self.assertTrue(checks["bubbleOverlap"])
        checks = final_eval.caption_checks(self.turn([ring]), [{"event": "bubble", "rectCG": [600, 600, 300, 80]}])
        self.assertFalse(checks["bubbleOverlap"])
        self.assertIsNone(final_eval.caption_checks(self.turn([ring]), [])["bubbleOverlap"])

    def test_arrow_overlap_uses_the_shaft(self):
        arrow = {"raw": "a", "cgPoint": [0, 0], "drawn": {"kind": "arrow", "rectCG": [100, 100, 200, 0], "tip": [300, 100]}}
        self.assertTrue(final_eval.caption_checks(self.turn([arrow]), [{"event": "bubble", "rectCG": [180, 90, 40, 20]}])["bubbleOverlap"])
        self.assertFalse(final_eval.caption_checks(self.turn([arrow]), [{"event": "bubble", "rectCG": [180, 130, 40, 20]}])["bubbleOverlap"])

    def test_leaks(self):
        self.assertEqual(final_eval.count_leaks(self.turn([], ["Click the Share button.", "It's next to build #7731."])), 0)
        self.assertEqual(final_eval.count_leaks(self.turn([], ["Click [12] then badge 4."], mentions=1)), 3)


class DenseTests(unittest.TestCase):
    def test_underlines_and_labels(self):
        texts = [[100, 100, 200, 14], [100, 128, 180, 14]]
        tags = [{"raw": "1", "cgPoint": [0, 0], "drawn": {"kind": "underline", "rectCG": [100, 116, 200, 0], "labelRectCG": [600, 100, 120, 20]}},
                {"raw": "2", "cgPoint": [0, 0], "drawn": {"kind": "underline", "rectCG": [100, 144, 180, 0], "labelRectCG": [600, 128, 120, 20]}}]
        self.assertEqual(final_eval.score_dense(texts, tags, texts, [[0, 0, 1440, 900]]), (True, True, ""))
        tags[1]["drawn"]["labelRectCG"] = [150, 128, 120, 20]
        self.assertEqual(final_eval.score_dense(texts, tags, texts, [[0, 0, 1440, 900]])[:2], (True, False))
        tags[0]["drawn"]["kind"] = "rbox"
        self.assertFalse(final_eval.score_dense(texts, tags, texts, [[0, 0, 1440, 900]])[0])


class MiscTests(unittest.TestCase):
    def test_backoff(self):
        schedule = final_eval.backoff_schedule()
        self.assertEqual(schedule[0], 30)
        self.assertEqual(schedule[-1], 8 * 60)
        self.assertTrue(final_eval.is_usage_limit_error("Claude usage limit reached; try again later"))
        self.assertFalse(final_eval.is_usage_limit_error("timeout"))

    def test_finder_alternatives(self):
        finder = {"role": "*", "title": ["New Note", "Compose"]}
        self.assertEqual([f["title"] for f in final_eval.finder_alternatives(finder)], ["New Note", "Compose"])

    def test_validation_catches_bad_rows(self):
        row = {"_line": 2, "id": "x1", "app": "Finder", "bundle": "com.apple.finder", "setup": "file:../etc", "prompt": "p",
               "kind": "point", "truth": json.dumps([{"role": "AXButton", "colour": "red"}, {"title": "b"}])}
        problems = final_eval.validate_ax_rows([row])
        self.assertTrue(any("inside final/fixtures" in p for p in problems))
        self.assertTrue(any("unknown truth fields" in p for p in problems))
        self.assertTrue(any("exactly one truth" in p for p in problems))
        clicky = dict(row, setup="app", truth=json.dumps([{"role": "AXButton"}]), app="Finder", prompt="open Clicky.app")
        clicky["bundle"] = "com.apple.finder"
        clicky["setup"] = "file:Clicky.app"
        self.assertTrue(any("never open Clicky" in p for p in final_eval.validate_ax_rows([clicky])))

    def test_canvas_keys(self):
        manifest = final_eval.read_manifest()
        self.assertIn("v_yellow", final_eval.canvas_keys(manifest, "video", {"t": "6"}))
        self.assertNotIn("v_yellow", final_eval.canvas_keys(manifest, "video", {"t": "2"}))
        self.assertIn("red_4", final_eval.canvas_keys(manifest, "dots", {"variant": "many"}))
        self.assertIn("task_demo_text", final_eval.canvas_keys(manifest, "table", {}))

    def test_fixture_pdf_and_terminal_script(self):
        scratch = tempfile.mkdtemp()
        try:
            self.assertIsNone(final_eval.check_pdf(final_eval.write_fixture_pdf(os.path.join(scratch, "p", "guide.pdf"))))
            script_path, pid_path = final_eval.write_terminal_script(scratch, "t1", "/tmp/it's here.txt")
            with open(script_path) as script_file:
                self.assertIn("'/tmp/it'\\''s here.txt'", script_file.read())
            self.assertTrue(pid_path.endswith("t1.pid"))
        finally:
            shutil.rmtree(scratch)

    def test_latencies_and_evidence(self):
        turn = {"timings": {"keyUp": 10.0, "firstDelta": 11.5, "firstAudio": 13.0, "end": 15.0}, "speech": {"rtf": 0.4},
                "grounding": {"isBadged": True}, "screens": [{"boundsCG": [0, 0, 1440, 900], "imageW": 2880}]}
        latency = final_eval.turn_latencies(turn)
        self.assertEqual(latency["firstAudio"], 3.0)
        self.assertEqual(latency["rtf"], 0.4)
        self.assertIsNone(latency["captionLagMs"])
        evidence = final_eval.config_evidence("baseline", turn, None)
        self.assertFalse(evidence["badges"])
        self.assertIsNone(evidence["lists"])
        self.assertIsNone(evidence["verify"])
        self.assertEqual(evidence["imagePxPerPt"], 2.0)


if __name__ == "__main__":
    unittest.main(verbosity=1)
