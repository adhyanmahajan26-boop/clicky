#!/usr/bin/env python3
"""Asks Clicky 5 pointing questions in each real app, for manual review.

Each app is brought to the front with `open -a` (nothing in it is changed),
then `ask{speak:false}` runs and the resolved tags (method, confidence,
verified, frame) are collected from the turn log. Output: a JSON summary in
build/eval/real-apps-<time>.json and a markdown table on stdout.
Usage: python3 Tools/eval/real_app_asks.py [--apps "Finder,Safari,..."]
Python 3.9, standard library only.
"""

import argparse
import json
import os
import subprocess
import time

REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
CLICKYCTL = os.path.join(REPO_ROOT, "Tools", "clickyctl.sh")

APP_PROMPTS = {
    "Finder": ["point at the search field", "where's Downloads in the sidebar", "how do I switch to list view",
               "show me the back button", "circle the Applications folder"],
    "Safari": ["point at the address bar", "where's the share button", "how do I open a new tab",
               "show me the sidebar button", "circle the tab overview button"],
    "System Settings": ["where is Wi-Fi", "point at the search box", "how do I turn on dark mode",
                        "where are the Bluetooth settings", "circle Displays"],
    "Xcode": ["point at the run button", "where's the scheme picker", "show me how to hide the navigator",
              "where is the stop button", "circle the issues indicator"],
    "Slack": ["point at the search bar", "where's the compose button", "show me the activity tab",
              "circle the first channel in the sidebar", "where do I set my status"],
    "Visual Studio Code": ["point at the explorer icon", "where's the search icon", "show me the extensions view button",
                           "circle the status bar", "where is the run and debug icon"],
}


def clickyctl(command, timeout_seconds=180):
    completed = subprocess.run([CLICKYCTL, json.dumps(command), str(timeout_seconds)], capture_output=True, text=True)
    try:
        return json.loads(completed.stdout.strip() or "{}")
    except ValueError:
        return {"ok": False, "error": completed.stdout[:200]}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--apps", default=",".join(APP_PROMPTS))
    arguments = parser.parse_args()
    results = []
    for app_name in [a.strip() for a in arguments.apps.split(",") if a.strip()]:
        if subprocess.run(["open", "-a", app_name], capture_output=True).returncode != 0:
            results.append({"app": app_name, "skipped": "not installed"})
            continue
        time.sleep(2.5)
        for prompt in APP_PROMPTS.get(app_name, []):
            clickyctl({"cmd": "reset"}, 10)
            reply = clickyctl({"cmd": "ask", "text": prompt, "speak": False}, 180)
            entry = {"app": app_name, "prompt": prompt, "ok": reply.get("ok"), "turnDir": reply.get("turnDir")}
            if reply.get("turnDir"):
                with open(os.path.join(reply["turnDir"], "turn.json")) as turn_file:
                    turn = json.load(turn_file)
                entry["tags"] = [{k: t.get(k) for k in ("raw", "kind", "method", "confidence", "verified", "occludedByPID", "box", "cgPoint")}
                                 for t in turn.get("tags", [])]
                entry["grounding"] = turn.get("grounding")
                speech = turn.get("rawResponse", "")
                entry["answer"] = speech[:300]
            results.append(entry)
            print("%-18s %-40s tags=%s" % (app_name, prompt, [(t["method"], t["confidence"], t["verified"]) for t in entry.get("tags", [])]), flush=True)
    output_path = os.path.join(REPO_ROOT, "build", "eval", "real-apps-%s.json" % time.strftime("%Y%m%d-%H%M%S"))
    os.makedirs(os.path.dirname(output_path), exist_ok=True)
    with open(output_path, "w") as output_file:
        json.dump(results, output_file, indent=2)
    print("wrote", output_path)


if __name__ == "__main__":
    main()
