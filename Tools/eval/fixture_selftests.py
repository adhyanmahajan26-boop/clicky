#!/usr/bin/env python3
"""Runs the grounding fixture self-tests on every display.

For each NSScreen index: start GroundingFixture (cursor parked on it, so it is
SCREEN 1), run `selftest fixtureResolve`, then restart it with --cover share
for `verifyHitTest` mode cover, and once more for mode park.
Usage: python3 Tools/eval/fixture_selftests.py [--displays 0,1,2]
Python 3.9, standard library only.
"""

import argparse
import json
import os
import signal
import subprocess
import time

REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
CLICKYCTL = os.path.join(REPO_ROOT, "Tools", "clickyctl.sh")
FIXTURE_BINARY = os.path.join(REPO_ROOT, "build", "GroundingFixture.app", "Contents", "MacOS", "GroundingFixture")
GROUND_TRUTH_PATH = os.path.expanduser("~/.clicky/fixture/groundtruth.json")


def clickyctl(command, timeout_seconds=180):
    completed = subprocess.run([CLICKYCTL, json.dumps(command), str(timeout_seconds)], capture_output=True, text=True)
    return json.loads(completed.stdout.strip() or "{}")


def start_fixture(display_index, extra_arguments, settle_seconds):
    try:
        os.remove(GROUND_TRUTH_PATH)
    except OSError:
        pass
    process = subprocess.Popen([FIXTURE_BINARY, "--display", str(display_index), "--park-cursor"] + extra_arguments,
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    deadline = time.time() + 20
    while time.time() < deadline:
        try:
            with open(GROUND_TRUTH_PATH) as ground_truth_file:
                if json.load(ground_truth_file).get("ready"):
                    break
        except (OSError, ValueError):
            pass
        time.sleep(0.2)
    time.sleep(settle_seconds)
    return process


def stop_fixture(process):
    try:
        with open(GROUND_TRUTH_PATH) as ground_truth_file:
            helper_pid = json.load(ground_truth_file).get("helperPid")
        if helper_pid:
            os.kill(helper_pid, signal.SIGTERM)
    except (OSError, ValueError):
        pass
    process.terminate()
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        process.kill()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--displays", default="0,1,2")
    arguments = parser.parse_args()
    summary = []
    for display_index in [int(d) for d in arguments.displays.split(",")]:
        process = start_fixture(display_index, [], 1.0)
        resolve = clickyctl({"cmd": "selftest", "name": "fixtureResolve"})
        stop_fixture(process)

        process = start_fixture(display_index, ["--cover", "share"], 3.5)
        cover = clickyctl({"cmd": "selftest", "name": "verifyHitTest", "mode": "cover"})
        stop_fixture(process)

        process = start_fixture(display_index, [], 1.0)
        park = clickyctl({"cmd": "selftest", "name": "verifyHitTest", "mode": "park"})
        stop_fixture(process)

        entry = {"display": display_index, "fixtureResolve": resolve, "verifyCover": cover, "verifyPark": park}
        summary.append(entry)
        print(json.dumps({
            "display": display_index,
            "resolveOK": resolve.get("ok"),
            "counts": (resolve.get("result") or {}).get("counts"),
            "worstErrorPt": (resolve.get("result") or {}).get("worstErrorPt"),
            "misses": (resolve.get("result") or {}).get("misses"),
            "coverOK": cover.get("ok"), "cover": cover.get("result"),
            "parkOK": park.get("ok"), "park": park.get("result"),
        }, indent=1), flush=True)
    os.makedirs(os.path.join(REPO_ROOT, "build", "eval"), exist_ok=True)
    with open(os.path.join(REPO_ROOT, "build", "eval", "fixture-selftests.json"), "w") as output_file:
        json.dump(summary, output_file, indent=2)


if __name__ == "__main__":
    main()
