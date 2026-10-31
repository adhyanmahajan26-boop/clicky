#!/usr/bin/env python3
"""P1c live checks (draw on screen; run only when nobody is using the Mac).

  1. scroll tracking: fixture --scroll-after 3 --scroll-duration 1.5, marks on
     "Row 12" and "Row 1". Within 200 ms of scrollEndedAt the Row 12 mark is
     <= 2 pt from its new truth and the Row 1 mark (scrolled out) is hidden.
  2. untracked clear: [MARK:underline:"Deploy failed"] + --move-after 3 ->
     the mark is removed <= 600 ms after movedAt.
  3. verifyHitTest cover+marks and park+marks.
  4. selftest recheckExclusion (fixture up).
  5. selftest markRoundTrip.
Each check runs on --displays (default 0,1,2). Output: JSON summary on stdout
and build/eval/p1c-checks-<time>.json.
Python 3.9, standard library only.
"""

import argparse
import json
import math
import os
import signal
import subprocess
import time

REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
CLICKYCTL = os.path.join(REPO_ROOT, "Tools", "clickyctl.sh")
FIXTURE_BINARY = os.path.join(REPO_ROOT, "build", "GroundingFixture.app", "Contents", "MacOS", "GroundingFixture")
GROUND_TRUTH_PATH = os.path.expanduser("~/.clicky/fixture/groundtruth.json")


def clickyctl(command, timeout_seconds=120):
    completed = subprocess.run([CLICKYCTL, json.dumps(command), str(timeout_seconds)], capture_output=True, text=True)
    try:
        return json.loads(completed.stdout.strip() or "{}")
    except ValueError:
        return {"ok": False, "error": completed.stdout[:200]}


def read_ground_truth():
    try:
        with open(GROUND_TRUTH_PATH) as ground_truth_file:
            return json.load(ground_truth_file)
    except (OSError, ValueError):
        return None


def start_fixture(display_index, extra_arguments):
    if os.path.exists(GROUND_TRUTH_PATH):
        os.remove(GROUND_TRUTH_PATH)
    process = subprocess.Popen([FIXTURE_BINARY, "--display", str(display_index), "--park-cursor"] + extra_arguments,
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    deadline = time.time() + 20
    while time.time() < deadline:
        ground_truth = read_ground_truth()
        if ground_truth and ground_truth.get("ready"):
            return process, ground_truth
        time.sleep(0.2)
    process.terminate()
    return None, None


def stop_fixture(process):
    """Stops the fixture AND its --cover helper (a separate process that
    would otherwise stay on screen as a grey box)."""
    try:
        helper_pid = (read_ground_truth() or {}).get("helperPid")
        if helper_pid:
            os.kill(helper_pid, signal.SIGTERM)
    except OSError:
        pass
    if process:
        process.terminate()
        try:
            process.wait(5)
        except subprocess.TimeoutExpired:
            process.kill()


def wait_for_key(key, timeout_seconds):
    deadline = time.time() + timeout_seconds
    while time.time() < deadline:
        ground_truth = read_ground_truth()
        if ground_truth and ground_truth.get(key):
            return ground_truth
        time.sleep(0.05)
    return None


def frame_of(ground_truth, key):
    for item in ground_truth.get("items", []):
        if item["key"] == key:
            return item["frameCG"]
    return None


def read_mark_events(turn_directory):
    events = []
    try:
        with open(os.path.join(turn_directory, "marks.jsonl")) as events_file:
            for line in events_file:
                events.append(json.loads(line))
    except OSError:
        pass
    return events


def rect_offset(first, second):
    return math.hypot((first[0] + first[2] / 2) - (second[0] + second[2] / 2), (first[1] + first[3] / 2) - (second[1] + second[3] / 2))


def check_scroll_tracking(display_index):
    """The mark must move with its row: its displacement equals the row's
    (the mark sits on the row's text, so absolute centres differ)."""
    process, ground_truth = start_fixture(display_index, ["--scroll-after", "3", "--scroll-duration", "1.5"])
    if not process:
        return {"ok": False, "error": "fixture not ready"}
    try:
        row_12_before = frame_of(ground_truth, "row_12")
        row_1_before = frame_of(ground_truth, "row_1")
        reply = clickyctl({"cmd": "marks", "tags": '[MARK:circle:"Row 12":Row 12] [MARK:circle:"Row 1":Row 1]'}, 30)
        turn_directory = reply.get("turnDir")
        boxes = [tag.get("box") for tag in (reply.get("result") or [])]
        after = wait_for_key("scrollEndedAt", 10)
        time.sleep(0.5)
        if not after or not turn_directory or len(boxes) < 2 or not boxes[0]:
            return {"ok": False, "error": "no scrollEndedAt, turn or boxes", "reply": str(reply)[:200]}
        scroll_ended_ms = after["scrollEndedAt"]
        row_12_after = frame_of(after, "row_12")
        truth_shift = row_12_after[1] - row_12_before[1]
        events = read_mark_events(turn_directory)
        moves = [e for e in events if e.get("event") == "move" and e["t"] <= scroll_ended_ms + 200]
        # Row 12's mark: the moves that started near its box.
        row_12_moves = [e for e in moves if abs(e["rectCG"][0] - boxes[0][0]) < 2 and abs(e["rectCG"][1] - boxes[0][1]) < abs(truth_shift) + 40]
        if not row_12_moves:
            return {"ok": False, "error": "no move events for Row 12", "events": len(events)}
        mark_shift = row_12_moves[-1]["rectCG"][1] - boxes[0][1]
        shift_error = abs(mark_shift - truth_shift)
        last_move_lag = row_12_moves[-1]["t"] - scroll_ended_ms
        hides = [e for e in events if e.get("event") in ("hide", "remove") and e["t"] <= scroll_ended_ms + 200]
        return {"ok": shift_error <= 2 and bool(hides), "row12ShiftErrorPt": round(shift_error, 2), "truthShiftPt": truth_shift,
                "lastMoveVsScrollEndMs": last_move_lag, "row1Hidden": bool(hides), "events": len(events)}
    finally:
        stop_fixture(process)


def check_untracked_clear(display_index):
    process, _ = start_fixture(display_index, ["--move-after", "3"])
    if not process:
        return {"ok": False, "error": "fixture not ready"}
    try:
        reply = clickyctl({"cmd": "marks", "tags": '[MARK:underline:"Deploy failed"]'}, 30)
        turn_directory = reply.get("turnDir")
        moved = wait_for_key("movedAt", 10)
        time.sleep(1.0)
        if not moved or not turn_directory:
            return {"ok": False, "error": "no movedAt or turn", "reply": reply}
        removals = [e for e in read_mark_events(turn_directory) if e.get("event") == "remove"]
        latency = min((e["t"] - moved["movedAt"] for e in removals), default=None)
        return {"ok": latency is not None and latency <= 600, "clearedAfterMs": latency}
    finally:
        stop_fixture(process)


def run_selftest(name, mode=None, timeout_seconds=120):
    command = {"cmd": "selftest", "name": name}
    if mode:
        command["mode"] = mode
    reply = clickyctl(command, timeout_seconds)
    return {"ok": bool(reply.get("ok")), "result": reply.get("result")}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--displays", default="0,1,2")
    arguments = parser.parse_args()
    summary = {}
    for display_index in [int(d) for d in arguments.displays.split(",") if d.strip()]:
        clickyctl({"cmd": "reset"}, 10)
        results = {"scrollTracking": check_scroll_tracking(display_index)}
        clickyctl({"cmd": "clear"}, 10)
        results["untrackedClear"] = check_untracked_clear(display_index)
        clickyctl({"cmd": "clear"}, 10)
        for mode in ("cover+marks", "park+marks"):
            fixture_arguments = ["--cover", "share"] if mode.startswith("cover") else []
            process, _ = start_fixture(display_index, fixture_arguments)
            try:
                time.sleep(3.5 if fixture_arguments else 0.5)
                results["verifyHitTest " + mode] = run_selftest("verifyHitTest", mode)
            finally:
                stop_fixture(process)
        process, _ = start_fixture(display_index, [])
        try:
            results["recheckExclusion"] = run_selftest("recheckExclusion")
        finally:
            stop_fixture(process)
        summary["display %d" % display_index] = results
        print(json.dumps({display_index: results}), flush=True)
    summary["markRoundTrip"] = run_selftest("markRoundTrip")
    output_path = os.path.join(REPO_ROOT, "build", "eval", "p1c-checks-%s.json" % time.strftime("%Y%m%d-%H%M%S"))
    os.makedirs(os.path.dirname(output_path), exist_ok=True)
    with open(output_path, "w") as output_file:
        json.dump(summary, output_file, indent=2)
    print("wrote", output_path)


if __name__ == "__main__":
    main()
