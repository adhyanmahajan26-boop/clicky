#!/usr/bin/env python3
"""Unit tests for the pure checks, the WAV code and the local p8 pages in p8_voice.py.
No app, no Chrome, no network, no audio, no `say`.

Run: python3 -I Tools/eval/test_p8.py
"""

import array
import importlib.util
import io
import os
import re
import shutil
import struct
import subprocess
import tempfile
import unittest
from contextlib import redirect_stdout

EVAL_DIRECTORY = os.path.dirname(os.path.abspath(__file__))
PAGE_DIRECTORY = os.path.join(EVAL_DIRECTORY, "p8")


def read_text(path):
    with open(path, encoding="utf-8") as handle:
        return handle.read()


def load(name, file_name):
    spec = importlib.util.spec_from_file_location(name, os.path.join(EVAL_DIRECTORY, file_name))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


P8 = load("p8_voice", "p8_voice.py")


def reply(parsed=None, **extra):
    payload = {"parsed": parsed}
    payload.update(extra)
    return {"ok": True, "result": payload}


class PageChecks(unittest.TestCase):
    def test_search_page_publishes_truth_and_records_submits(self):
        text = read_text(os.path.join(PAGE_DIRECTORY, "search.html"))
        self.assertIn('src="common.js"', text)
        self.assertIn("P8.publish(", text)
        self.assertIn("window.__submitted", text)
        self.assertIn('id="q"', text)

    def test_article_has_twenty_paragraphs_and_eight_facts(self):
        text = read_text(os.path.join(PAGE_DIRECTORY, "article_long.html"))
        self.assertGreaterEqual(P8.count_paragraphs(text), P8.ARTICLE_MIN_PARAGRAPHS)
        self.assertEqual(P8.count_facts(text), P8.FACT_COUNT)
        self.assertIn("P8.publish(", text)

    def test_article_facts_are_numbered_one_to_eight(self):
        text = read_text(os.path.join(PAGE_DIRECTORY, "article_long.html"))
        self.assertEqual(sorted(int(n) for n in re.findall(r'data-fact="(\d+)"', text)), list(range(1, 9)))

    def test_common_js_defines_p8(self):
        text = read_text(os.path.join(PAGE_DIRECTORY, "common.js"))
        self.assertIn("window.P8", text)
        self.assertNotIn("P7", text)

    @unittest.skipUnless(shutil.which("node"), "node not installed")
    def test_inline_scripts_pass_node_check(self):
        scratch = tempfile.mkdtemp(prefix="p8-test-")
        try:
            for name in ("search.html", "article_long.html", "common.js"):
                text = read_text(os.path.join(PAGE_DIRECTORY, name))
                sources = [text] if name.endswith(".js") else re.findall(r"<script(?![^>]*\bsrc=)[^>]*>(.*?)</script>", text, re.S)
                for index, source in enumerate(sources):
                    path = os.path.join(scratch, "%s-%d.js" % (name.replace(".", "_"), index))
                    with open(path, "w", encoding="utf-8") as handle:
                        handle.write(source)
                    completed = subprocess.run(["node", "--check", path], capture_output=True, text=True)
                    self.assertEqual(completed.returncode, 0, "%s: %s" % (name, completed.stderr))
        finally:
            shutil.rmtree(scratch, ignore_errors=True)


class EnterChecks(unittest.TestCase):
    def test_enter_passes_when_submitted_contains_phrase(self):
        self.assertTrue(P8.check_enter(["Weather in Delhi"])[0])
        self.assertTrue(P8.check_enter(["weather in delhi!"])[0])

    def test_enter_fails_without_submit_or_with_other_text(self):
        self.assertFalse(P8.check_enter([])[0])
        self.assertFalse(P8.check_enter(["weather in mumbai"])[0])
        self.assertFalse(P8.check_enter(None)[0])

    def test_variant_needs_the_typed_search_submitted(self):
        self.assertTrue(P8.check_enter_variant(["weather in delhi"], "weather in delhi")[0])
        self.assertFalse(P8.check_enter_variant([], "weather in delhi")[0])


class ArticleChecks(unittest.TestCase):
    ARTICLE = "Async functions can suspend without blocking a thread.  Actors serialize access to state."

    def test_quotes_must_be_verbatim_ignoring_case_and_spacing(self):
        items = [{"note": "a", "quote": "Async functions can suspend\nwithout blocking a thread."},
                 {"note": "b", "quote": "Actors SERIALIZE access"},
                 {"note": "c", "quote": "Actors never block"},
                 {"note": "d"}]
        good = P8.verbatim_notes(items, self.ARTICLE)
        self.assertEqual([item["note"] for item in good], ["a", "b"])

    def test_article_notes_need_seven_highlights_visible_panel_and_five_quotes(self):
        quotes = ["Async functions can suspend without blocking a thread."] * 5
        status = {"visible": True, "items": [{"note": str(i), "quote": quotes[i]} for i in range(5)]}
        article = self.ARTICLE + " " + quotes[0]
        self.assertTrue(P8.check_article_notes(7, status, article)[0])
        self.assertFalse(P8.check_article_notes(6, status, article)[0])
        self.assertFalse(P8.check_article_notes(7, dict(status, visible=False), article)[0])
        short = dict(status, items=status["items"][:4])
        self.assertFalse(P8.check_article_notes(7, short, article)[0])

    def test_highlights_after_scroll(self):
        self.assertTrue(P8.check_highlights_after_scroll(8, "notesStatus.articleHighlights")[0])
        self.assertFalse(P8.check_highlights_after_scroll(3, "marks.jsonl")[0])
        self.assertFalse(P8.check_highlights_after_scroll(None, "none")[0])

    def test_saved_notes_must_hold_five_quotes(self):
        quotes = ["Quote number %d is here." % i for i in range(6)]
        saved = "\n".join("- %s" % quote for quote in quotes[:5])
        self.assertTrue(P8.check_saved_notes(saved, quotes)[0])
        self.assertFalse(P8.check_saved_notes(saved.replace(quotes[0], ""), quotes)[0])
        self.assertFalse(P8.check_saved_notes("", quotes)[0])


class FastPathChecks(unittest.TestCase):
    def test_plan_has_ten_commands_and_three_negatives(self):
        self.assertEqual(len(P8.FAST_PATH_CASES), 10)
        self.assertEqual(len(P8.FAST_PATH_NEGATIVES), 3)
        self.assertEqual(P8.FAST_PATH_LIMIT_SECONDS, 1.0)

    def test_parsed_of_and_unparsed(self):
        self.assertEqual(P8.parsed_of(reply({"action": "volume.up"}))["action"], "volume.up")
        self.assertIsNone(P8.parsed_of(reply(None)))
        self.assertTrue(P8.is_unparsed(reply(None)))
        self.assertTrue(P8.is_unparsed(reply({"action": "none"})))
        self.assertTrue(P8.is_unparsed(reply({"action": "volume.up", "matched": False})))
        self.assertFalse(P8.is_unparsed(reply({"action": "mute"})))

    def test_expectation_checks_every_token(self):
        good = reply({"action": "volume.set", "level": 30})
        self.assertTrue(P8.expectation_met(good, ["volume", "30"]))
        self.assertFalse(P8.expectation_met(good, ["volume", "mute"]))
        self.assertFalse(P8.expectation_met(reply(None), ["mute"]))

    def test_fast_path_passes_only_under_one_second_and_expected_action(self):
        cases = [{"text": "mute", "tokens": ["mute"], "seconds": 0.2, "reply": reply({"action": "audio.mute"})}]
        self.assertTrue(P8.check_fast_path(cases)[0])
        slow = [dict(cases[0], seconds=1.2)]
        self.assertFalse(P8.check_fast_path(slow)[0])
        wrong = [dict(cases[0], tokens=["unmute"])]
        self.assertFalse(P8.check_fast_path(wrong)[0])
        unknown = [dict(cases[0], seconds=None)]
        self.assertFalse(P8.check_fast_path(unknown)[0])

    def test_negatives_must_not_parse(self):
        self.assertTrue(P8.check_fast_negatives([{"text": "x", "reply": reply(None)}])[0])
        self.assertFalse(P8.check_fast_negatives([{"text": "go back in time", "reply": reply({"action": "nav.back"})}])[0])


class FollowUpChecks(unittest.TestCase):
    def test_chain_summary_reads_wakes_and_commands(self):
        wakes, commands = P8.chain_summary({"ok": True, "result": {"wakes": 1, "followUpCommands": ["new tab", "that's all"]}})
        self.assertEqual(wakes, 1)
        self.assertEqual(commands, ["new tab", "that's all"])

    def test_chain_summary_accepts_nested_follow_up_and_dict_items(self):
        wakes, commands = P8.chain_summary({"wakeCount": 1, "followUp": {"commands": [{"text": "a"}, {"text": "b", "recognized": False}, {"text": "c"}]}})
        self.assertEqual(wakes, 1)
        self.assertEqual(len(commands), 2)

    def test_follow_up_needs_one_wake_and_three_commands(self):
        self.assertTrue(P8.check_follow_up(1, ["a", "b", "c"])[0])
        self.assertFalse(P8.check_follow_up(2, ["a", "b", "c"])[0])
        self.assertFalse(P8.check_follow_up(1, ["a", "b"])[0])
        self.assertFalse(P8.check_follow_up(None, [])[0])

    def test_follow_up_script_matches_expected_counts(self):
        self.assertEqual(len(P8.FOLLOW_UP_SCRIPT), 3)
        self.assertEqual(P8.EXPECTED_FOLLOW_UP_COMMANDS, 3)
        self.assertEqual(P8.EXPECTED_WAKES, 1)


class ShellChecks(unittest.TestCase):
    def test_refusal_needs_refused_tier_and_shell_reason(self):
        refused = {"ok": True, "result": {"tierDecisions": [{"verb": "type", "tier": "refused", "reason": "shell is not allowed"}]}}
        self.assertTrue(P8.check_shell(refused)[0])
        other = {"result": {"tierDecisions": [{"verb": "type", "tier": "refused", "reason": "password field"}]}}
        self.assertFalse(P8.check_shell(other)[0])
        allowed = {"result": {"tierDecisions": [{"verb": "type", "tier": "free", "reason": "shell"}]}}
        self.assertFalse(P8.check_shell(allowed)[0])


class WakeDiagnostics(unittest.TestCase):
    def test_fields_are_picked_up_when_present(self):
        status = {"ok": True, "result": {"errorsByCode": {"E1": 2}, "nearMisses": 4, "deviceSampleRate": 48000, "other": 1}}
        found = P8.wake_diagnostics(status)
        self.assertEqual(found, {"errorsByCode": {"E1": 2}, "nearMisses": 4, "deviceSampleRate": 48000})
        self.assertEqual(P8.wake_diagnostics({"ok": False}), {})


class WavChecks(unittest.TestCase):
    def test_float_wav_header_and_round_trip(self):
        samples = array.array("f", [0.0, 0.5, -0.5, 1.0])
        data = P8.make_float_wav(samples, 48000)
        self.assertEqual(data[:4], b"RIFF")
        self.assertEqual(data[8:12], b"WAVE")
        tag, channels, rate = struct.unpack("<HHI", data[20:28])
        self.assertEqual((tag, channels, rate), (3, 1, 48000))
        parsed = P8.parse_wav(data)
        self.assertEqual(parsed["format"], 3)
        self.assertEqual(parsed["bits"], 32)
        self.assertEqual(list(parsed["samples"]), list(samples))

    def test_pcm16_wav_is_read_and_scaled(self):
        raw = array.array("h", [16384, -16384, 0]).tobytes()
        fmt = struct.pack("<HHIIHH", 1, 1, 48000, 96000, 2, 16)
        data = (b"RIFF" + struct.pack("<I", 4 + 8 + len(fmt) + 8 + len(raw)) + b"WAVE" + b"fmt " +
                struct.pack("<I", len(fmt)) + fmt + b"data" + struct.pack("<I", len(raw)) + raw)
        parsed = P8.parse_wav(data)
        self.assertAlmostEqual(parsed["samples"][0], 0.5, places=4)
        self.assertAlmostEqual(parsed["samples"][1], -0.5, places=4)

    def test_concatenation_inserts_gaps_between_clips_only(self):
        a = array.array("f", [0.5]) * 10
        b = array.array("f", [0.25]) * 4
        out = P8.concatenate_clips([a, b], 0.00025, 48000)  # 12 samples of silence
        self.assertEqual(len(out), 10 + 12 + 4)
        self.assertEqual(out[10], 0.0)
        self.assertEqual(out[22], 0.25)
        self.assertEqual(len(P8.concatenate_clips([a], 1.0, 48000)), 10)

    def test_two_second_gaps_at_48k(self):
        clip = array.array("f", [0.1]) * 4800  # 0.1 s
        out = P8.concatenate_clips([clip, clip, clip], P8.FOLLOW_UP_GAP_SECONDS, 48000)
        self.assertEqual(len(out), 3 * 4800 + 2 * 2 * 48000)
        self.assertAlmostEqual(len(out) / 48000.0, 0.3 + 4.0, places=3)

    def test_follow_up_wav_reads_clips_and_rejects_wrong_rate(self):
        scratch = tempfile.mkdtemp(prefix="p8-test-wav-")
        try:
            clip = P8.make_float_wav(array.array("f", [0.2]) * 4800, 48000)
            paths = []
            for index in range(3):
                path = os.path.join(scratch, "c%d.wav" % index)
                with open(path, "wb") as handle:
                    handle.write(clip)
                paths.append(path)
            parsed = P8.parse_wav(P8.follow_up_wav_bytes(paths))
            self.assertEqual(len(parsed["samples"]), 3 * 4800 + 2 * 2 * 48000)
            wrong = os.path.join(scratch, "wrong.wav")
            with open(wrong, "wb") as handle:
                handle.write(P8.make_float_wav(array.array("f", [0.2]) * 441, 44100))
            with self.assertRaises(ValueError):
                P8.follow_up_wav_bytes([wrong])
        finally:
            shutil.rmtree(scratch, ignore_errors=True)

    def test_say_command_asks_for_48k_float(self):
        command = P8.say_command("/tmp/x.wav", "new tab")
        self.assertIn("--data-format=LEF32@48000", command)
        self.assertIn("--file-format=WAVE", command)
        self.assertEqual(command[-1], "new tab")

    def test_parse_rejects_non_wave(self):
        with self.assertRaises(ValueError):
            P8.parse_wav(b"nope")

    def test_self_check_passes(self):
        ok, note = P8.wav_self_check()
        self.assertTrue(ok, note)

    def test_expected_duration(self):
        self.assertAlmostEqual(P8.expected_duration_seconds([1.0, 1.0, 1.0]), 7.0)


class PlanChecks(unittest.TestCase):
    def test_test_ids_and_plan_are_complete(self):
        self.assertEqual(P8.ALL_IDS, ["1", "1b", "2", "3", "4", "5"])
        for key in P8.ALL_IDS:
            self.assertIn(key, P8.TESTS_PLAN)
            self.assertIn(key, P8.TESTS)
            for field in ("name", "setup", "pass", "cleanup"):
                self.assertTrue(P8.TESTS_PLAN[key][field], "%s lacks %s" % (key, field))

    def test_parse_only(self):
        self.assertEqual(P8.parse_only("1,1b, 4"), ["1", "1b", "4"])
        with self.assertRaises(Exception):
            P8.parse_only("9")

    def test_markdown_table_has_the_required_columns(self):
        table = P8.markdown_table([{"test": "3", "name": "Fast", "status": "scored", "pass": True,
                                    "reason": "ok", "wallSeconds": 1.2, "steps": 10}])
        self.assertIn("| Test | Pass | Time (s) | Steps | Notes |", table)
        self.assertIn("| 3 Fast | pass | 1.2 | 10 | ok |", table)

    def test_dry_run_passes_and_prints_plan(self):
        buffer = io.StringIO()
        with redirect_stdout(buffer):
            code = P8.dry_run()
        output = buffer.getvalue()
        self.assertEqual(code, 0, output)
        self.assertIn("WAV self-check: ok", output)
        self.assertIn("fast path", output)


if __name__ == "__main__":
    unittest.main()
