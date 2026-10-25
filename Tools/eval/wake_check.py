#!/usr/bin/env python3
"""Wake-word check for Clicky: feed generated clips through the debug inbox and score detections.

Two modes:
  feed     (default) generates clips with `say -o <file>.aiff` (written to a temp folder, never played),
           sends each to Clicky as {"cmd":"wakeFeed","path":...} and scores detections and latency.
           Positives must be detected; negatives must not.
  passive  --passive-minutes N (default 30): polls {"cmd":"wakeStatus"} every 30 s, samples Clicky's
           CPU % with ps, and counts false wakes (the increase in the wakeStatus false-wake count).
           No audio is recorded or played by this harness.

Usage:
  python3 -I Tools/eval/wake_check.py --dry-run              prints the clips, commands and the pass rule; writes nothing
  python3 -I Tools/eval/wake_check.py --run NAME              feed mode; results in build/eval/wake/<run>/
  python3 -I Tools/eval/wake_check.py --passive --passive-minutes 30 --run NAME

Clicky fields the harness reads (checked defensively):
  wakeFeed reply:  detected (bool), phrase (str), latencyMs (number); also accepted under "result"
  wakeStatus reply: falseWakes (int), wakes (int), pid (int); CPU falls back to pgrep -x for the pid
"""

import argparse
import datetime
import importlib.util
import json
import os
import shutil
import statistics
import subprocess
import sys
import tempfile
import time

EVAL_DIRECTORY = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.abspath(os.path.join(EVAL_DIRECTORY, "..", ".."))
RUNS_DIRECTORY = os.path.join(REPO_ROOT, "build", "eval", "wake")
POSITIVE = [
    "hey claudia what's on my screen",
    "hey clicky open notes",
]
NEGATIVE = [
    "hey claude open",
    "claudia is my friend",
    "we should get lunch tomorrow",
    "the build finished about ten minutes ago",
    "can you pass the salt",
]
PASSIVE_INTERVAL_SECONDS = 30
PASSIVE_DEFAULT_MINUTES = 30
FEED_TIMEOUT_SECONDS = 60
SAY_TIMEOUT_SECONDS = 60
CLICKY_PROCESS_NAME = "Clicky"


def load_module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


FE = load_module("final_eval", os.path.join(EVAL_DIRECTORY, "final_eval.py"))


# ---------------------------------------------------------------------------
# Pure checks (unit-tested in test_p7.py).

def slug(text):
    return "".join(ch if ch.isalnum() else "_" for ch in text.lower()).strip("_")[:60]


def build_cases():
    """Every clip to feed: (file name, text, expected). Positives first, then negatives."""
    cases = []
    for text in POSITIVE:
        cases.append({"file": slug(text) + ".aiff", "text": text, "expected": "positive"})
    for text in NEGATIVE:
        cases.append({"file": slug(text) + ".aiff", "text": text, "expected": "negative"})
    return cases


def reply_detection(reply):
    """(detected, phrase, latency_ms) from a wakeFeed reply, also accepting a nested "result"."""
    payload = reply.get("result") if isinstance(reply.get("result"), dict) else reply
    if not isinstance(payload, dict):
        return False, None, None
    detected = bool(payload.get("detected"))
    phrase = payload.get("phrase")
    latency = payload.get("latencyMs")
    return detected, phrase, float(latency) if isinstance(latency, (int, float)) else None


def score_wake(results):
    """results: [{expected: positive|negative, detected: bool, latencyMs: number|None}].
    Returns counts, detection and false-wake rates, median latency, and pass/fail with the reason."""
    positives = [item for item in results if item.get("expected") == "positive"]
    negatives = [item for item in results if item.get("expected") == "negative"]
    hits = sum(1 for item in positives if item.get("detected"))
    false_wakes = sum(1 for item in negatives if item.get("detected"))
    latencies = [item["latencyMs"] for item in positives if item.get("detected") and item.get("latencyMs") is not None]
    rate = hits / len(positives) if positives else 0.0
    passed = bool(positives) and hits == len(positives) and false_wakes == 0
    if not positives:
        reason = "no positive clips"
    elif passed:
        reason = "all %d positives detected, no negative woke Clicky" % len(positives)
    else:
        reason = "%d/%d positives detected, %d false wake(s) on negatives" % (hits, len(positives), false_wakes)
    return {
        "positives": len(positives), "detected": hits, "negatives": len(negatives), "falseWakes": false_wakes,
        "detectionRate": round(rate, 3),
        "medianLatencyMs": round(statistics.median(latencies), 1) if latencies else None,
        "pass": passed, "reason": reason,
    }


def cpu_summary(samples):
    """samples: [cpu percent]. Returns mean, max and sample count (None when there are none)."""
    values = [float(value) for value in samples if isinstance(value, (int, float))]
    if not values:
        return {"samples": 0, "meanPercent": None, "maxPercent": None}
    return {"samples": len(values), "meanPercent": round(statistics.mean(values), 2), "maxPercent": round(max(values), 2)}


def false_wake_delta(first_count, last_count):
    """Increase in Clicky's false-wake count across the passive run (0 when unknown or it went down)."""
    if first_count is None or last_count is None:
        return None
    return max(0, int(last_count) - int(first_count))


def passive_plan(minutes):
    polls = int(minutes * 60 // PASSIVE_INTERVAL_SECONDS)
    return {"minutes": minutes, "intervalSeconds": PASSIVE_INTERVAL_SECONDS, "polls": polls,
            "records": "no audio is recorded; only wakeStatus counters and ps CPU are sampled"}


def say_command(path, text):
    """`say -o` writes an AIFF file. There is no output device: nothing is played."""
    return ["say", "-o", path, text]


def results_markdown(report):
    lines = ["# Wake check", "", "| Clip | Expected | Detected | Phrase | Latency (ms) |", "|---|---|---|---|---|"]
    for item in report["clips"]:
        latency = "" if item.get("latencyMs") is None else "%.0f" % item["latencyMs"]
        lines.append("| %s | %s | %s | %s | %s |" % (item["text"], item["expected"],
                                                  "yes" if item.get("detected") else "no", item.get("phrase") or "", latency))
    summary = report["summary"]
    lines += ["", "Positives detected %d of %d; false wakes %d of %d negatives; median latency %s ms; %s." % (
        summary["detected"], summary["positives"], summary["falseWakes"], summary["negatives"],
        summary["medianLatencyMs"], "PASS" if summary["pass"] else "FAIL: " + summary["reason"])]
    return "\n".join(lines) + "\n"


# ---------------------------------------------------------------------------
# Live pieces (never run by --dry-run or the unit tests).

def make_clip(directory, case):
    path = os.path.join(directory, case["file"])
    completed = subprocess.run(say_command(path, case["text"]), capture_output=True, text=True, timeout=SAY_TIMEOUT_SECONDS)
    if completed.returncode != 0 or not os.path.exists(path):
        raise RuntimeError("say failed for %r: %s" % (case["text"], completed.stderr.strip()[:160]))
    return path


def feed_mode(run_name, cases):
    run_directory = os.path.join(RUNS_DIRECTORY, run_name)
    os.makedirs(run_directory, exist_ok=True)
    if not FE.clickyctl({"cmd": "ping"}, 10).get("ok"):
        print("Clicky does not answer ping on the debug inbox; start the debug build first.", file=sys.stderr)
        return 1
    scratch = tempfile.mkdtemp(prefix="wake-clips-")
    results = []
    try:
        for case in cases:
            path = make_clip(scratch, case)
            started = time.time()
            reply = FE.clickyctl({"cmd": "wakeFeed", "path": path}, FEED_TIMEOUT_SECONDS)
            wall_ms = round((time.time() - started) * 1000.0, 1)
            detected, phrase, latency = reply_detection(reply)
            if latency is None and detected:
                latency = wall_ms
            results.append({"text": case["text"], "file": case["file"], "expected": case["expected"],
                            "detected": detected, "phrase": phrase, "latencyMs": latency,
                            "error": None if reply.get("ok") is not False else str(reply.get("error"))[:160]})
            print("  %-9s %-40s detected=%s latency=%s" % (case["expected"], case["text"], detected,
                                                         "-" if latency is None else "%.0f ms" % latency), flush=True)
    finally:
        shutil.rmtree(scratch, ignore_errors=True)
    summary = score_wake(results)
    report = {"clips": results, "summary": summary, "generated": datetime.datetime.now().isoformat(timespec="seconds")}
    with open(os.path.join(run_directory, "results.json"), "w", encoding="utf-8") as handle:
        json.dump(report, handle, indent=2, sort_keys=True)
    with open(os.path.join(run_directory, "results.md"), "w", encoding="utf-8") as handle:
        handle.write(results_markdown(report))
    print("results: %s" % os.path.join(run_directory, "results.json"))
    print("summary: %s" % summary["reason"])
    return 0 if summary["pass"] else 1


def clicky_pid():
    try:
        output = subprocess.run(["pgrep", "-x", CLICKY_PROCESS_NAME], capture_output=True, text=True, timeout=10).stdout
    except (OSError, subprocess.TimeoutExpired):
        return None
    first = output.split()
    return int(first[0]) if first else None


def cpu_percent(pid):
    if pid is None:
        return None
    try:
        output = subprocess.run(["ps", "-o", "%cpu=", "-p", str(pid)], capture_output=True, text=True, timeout=10).stdout
    except (OSError, subprocess.TimeoutExpired):
        return None
    try:
        return float(output.strip())
    except ValueError:
        return None


def passive_mode(run_name, minutes):
    run_directory = os.path.join(RUNS_DIRECTORY, run_name)
    os.makedirs(run_directory, exist_ok=True)
    plan = passive_plan(minutes)
    samples, first_count, last_count = [], None, None
    log_path = os.path.join(run_directory, "passive.jsonl")
    print("passive: %d min, a poll every %d s; no audio is recorded" % (minutes, PASSIVE_INTERVAL_SECONDS), flush=True)
    for index in range(plan["polls"]):
        status = FE.clickyctl({"cmd": "wakeStatus"}, 30)
        payload = status.get("result") if isinstance(status.get("result"), dict) else status
        count = payload.get("falseWakes") if isinstance(payload, dict) else None
        if first_count is None:
            first_count = count
        last_count = count if count is not None else last_count
        pid = payload.get("pid") if isinstance(payload, dict) and payload.get("pid") else clicky_pid()
        cpu = cpu_percent(pid)
        samples.append(cpu)
        with open(log_path, "a", encoding="utf-8") as handle:
            handle.write(json.dumps({"poll": index, "t": round(time.time(), 1), "cpu": cpu, "falseWakes": count}) + "\n")
        time.sleep(PASSIVE_INTERVAL_SECONDS)
    report = {"plan": plan, "cpu": cpu_summary(samples), "falseWakes": false_wake_delta(first_count, last_count)}
    with open(os.path.join(run_directory, "passive_summary.json"), "w", encoding="utf-8") as handle:
        json.dump(report, handle, indent=2, sort_keys=True)
    print("cpu: %s" % report["cpu"])
    print("false wakes during the run: %s" % report["falseWakes"])
    return 0


def dry_run(passive, minutes):
    cases = build_cases()
    print("dry run: nothing generated, sent or played; the Clicky inbox is not called")
    print("feed mode: %d clips (%d positive, %d negative)" % (len(cases), len(POSITIVE), len(NEGATIVE)))
    for case in cases:
        print("  %-9s %-44s -> say -o <tmp>/%s %r" % (case["expected"], case["text"], case["file"], case["text"]))
    print("  commands: {\"cmd\":\"ping\"}, then {\"cmd\":\"wakeFeed\",\"path\":<tmp>/<file>} per clip")
    print("  pass rule: every positive detected and no negative detected")
    plan = passive_plan(minutes)
    print("passive mode (--passive): %d min, %d polls every %d s of {\"cmd\":\"wakeStatus\"}, ps CPU %%; "
          "no audio recorded" % (plan["minutes"], plan["polls"], plan["intervalSeconds"]))
    print("OK: wake check plan valid")
    return 0


def main(argv):
    parser = argparse.ArgumentParser(description="Wake-word feed and passive checks for Clicky (see module docstring).")
    parser.add_argument("--dry-run", action="store_true", help="print the plan; generate and send nothing")
    parser.add_argument("--passive", action="store_true", help="30-minute passive mode: wakeStatus, CPU, false wakes")
    parser.add_argument("--passive-minutes", type=int, default=PASSIVE_DEFAULT_MINUTES)
    parser.add_argument("--run", help="run name (default: timestamp)")
    args = parser.parse_args(argv)
    if args.dry_run:
        return dry_run(args.passive, args.passive_minutes)
    run_name = args.run or datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
    if args.passive:
        return passive_mode(run_name, args.passive_minutes)
    return feed_mode(run_name, build_cases())


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
