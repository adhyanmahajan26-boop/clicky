#!/usr/bin/env python3
"""Grounding eval for Clicky: how accurately do its marks land?

For every display and every row of grounding_prompts.tsv it opens the
GroundingFixture on that display (cursor parked on it, so it is SCREEN 1),
asks Clicky the row's prompt through the debug inbox with speak:false, then
scores the tags Clicky logged in turn.json against the fixture's ground truth.

Hit rules (CG global points):
  - a POINT, or a legacy MARK centre, hits when it lies inside the target
    frame grown by 4 pt;
  - a v2 box mark (logged with a "box" field, from P1b on) hits when its
    centre lies inside target + 2 pt and its area is <= 4 x target + 400 pt^2;
  - multi-key rows need one hitting tag per key, in order;
  - a span key "row_3..row_5" is scored against the union of those frames.

Also measures keyUp -> firstAudio for --latency-asks spoken asks.

Usage: python3 Tools/eval/grounding_eval.py [--displays 0,1,2] [--rows N]
       [--latency-asks 10] [--badges on|off|ab] [--out docs/v2/EVAL.md]

With --badges ab every row is asked twice (badges on, then off, toggled
through the v2.grounding.badges default) and both arms are reported with
Wilson 95% intervals.
Python 3.9, standard library only.
"""

import argparse
import json
import math
import os
import signal
import statistics
import subprocess
import sys
import time

REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
CLICKYCTL = os.path.join(REPO_ROOT, "Tools", "clickyctl.sh")
FIXTURE_BINARY = os.path.join(REPO_ROOT, "build", "GroundingFixture.app", "Contents", "MacOS", "GroundingFixture")
GROUND_TRUTH_PATH = os.path.expanduser("~/.clicky/fixture/groundtruth.json")
PROMPTS_PATH = os.path.join(os.path.dirname(__file__), "grounding_prompts.tsv")

POINT_TOLERANCE_PT = 4.0
# Must match fixtureCoverPadding in GroundingFixture.swift.
COVER_PADDING_PT = 20.0
CANT_SEE_PHRASES = ("can't see", "cannot see", "can not see", "don't see", "do not see", "not visible",
                    "hidden", "covered", "blocked", "obscured", "behind")
BOX_CENTER_TOLERANCE_PT = 2.0

LATENCY_PROMPTS = [
    "what app is in front right now, in one sentence?",
    "give me a one sentence summary of what's on my screen",
    "what's the title of the window under my cursor?",
    "say hi in five words",
    "what colour is most of my screen?",
    "how many windows can you see? one sentence",
    "name one button you can see",
    "what time does it look like it is, roughly? short answer",
    "is there any text about pull requests on screen? one sentence",
    "tell me one thing you notice on screen, briefly",
]


def clickyctl(command, timeout_seconds=120):
    """Send one debug-inbox command and return the parsed reply."""
    completed = subprocess.run(
        [CLICKYCTL, json.dumps(command), str(timeout_seconds)],
        capture_output=True, text=True, timeout=timeout_seconds + 15,
    )
    try:
        return json.loads(completed.stdout.strip() or "{}")
    except json.JSONDecodeError:
        return {"ok": False, "error": "bad reply: " + completed.stdout[:200]}


def git_head():
    return subprocess.run(["git", "-C", REPO_ROOT, "rev-parse", "HEAD"], capture_output=True, text=True).stdout.strip()


def require_single_clean_clicky():
    """Refuse unless exactly one Clicky runs, from DerivedData, built from HEAD."""
    pids = subprocess.run(["pgrep", "-f", "Clicky.app/Contents/MacOS/Clicky"], capture_output=True, text=True).stdout.split()
    if len(pids) != 1:
        sys.exit("refusing: expected exactly one Clicky process, found %d" % len(pids))
    ping = clickyctl({"cmd": "ping"}, 10)
    if not ping.get("ok"):
        sys.exit("refusing: ping failed: %s" % ping.get("error"))
    result = ping["result"]
    if "/DerivedData/" not in result.get("exe", ""):
        sys.exit("refusing: running Clicky is not a DerivedData build: %s" % result.get("exe"))
    head = git_head()
    if result.get("sha") != head:
        sys.exit("refusing: running Clicky sha %s != HEAD %s (commit, then relaunch via Xcode Run)" % (result.get("sha"), head))
    return result


def read_prompt_rows():
    rows = []
    with open(PROMPTS_PATH, encoding="utf-8") as prompts_file:
        header = prompts_file.readline().rstrip("\n").split("\t")
        for line in prompts_file:
            if not line.strip():
                continue
            fields = line.rstrip("\n").split("\t")
            fields += [""] * (len(header) - len(fields))
            rows.append(dict(zip(header, fields)))
    return rows


def wait_for_ground_truth(expected_pid, settle_seconds, timeout_seconds=20):
    deadline = time.time() + timeout_seconds
    while time.time() < deadline:
        try:
            with open(GROUND_TRUTH_PATH) as ground_truth_file:
                ground_truth = json.load(ground_truth_file)
            if ground_truth.get("ready") and ground_truth.get("pid") == expected_pid:
                break
        except (OSError, json.JSONDecodeError):
            pass
        time.sleep(0.2)
    else:
        return None
    # Scroll / cover happen a little after ready and rewrite the file.
    time.sleep(settle_seconds)
    with open(GROUND_TRUTH_PATH) as ground_truth_file:
        return json.load(ground_truth_file)


def start_fixture(display_index, flags):
    arguments = [FIXTURE_BINARY, "--display", str(display_index), "--park-cursor"]
    settle_seconds = 0.5
    for flag in [f for f in flags.split(";") if f]:
        if flag == "scroll":
            arguments += ["--scroll-after", "1"]
            settle_seconds = max(settle_seconds, 2.0)
        elif flag.startswith("cover:"):
            arguments += ["--cover", flag.split(":", 1)[1]]
            settle_seconds = max(settle_seconds, 3.5)
    try:
        os.remove(GROUND_TRUTH_PATH)
    except OSError:
        pass
    process = subprocess.Popen(arguments, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    ground_truth = wait_for_ground_truth(process.pid, settle_seconds)
    return process, ground_truth


def stop_fixture(process, ground_truth):
    helper_pid = (ground_truth or {}).get("helperPid")
    for pid in [helper_pid, process.pid]:
        if pid:
            try:
                os.kill(pid, signal.SIGTERM)
            except OSError:
                pass
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        process.kill()


def target_frame(key, frames_by_key):
    """Frame for a key or a span 'row_3..row_5' (union of the rows)."""
    if ".." in key:
        start_key, end_key = key.split("..")
        prefix = start_key.rsplit("_", 1)[0]
        start_number, end_number = int(start_key.rsplit("_", 1)[1]), int(end_key.rsplit("_", 1)[1])
        frames = [frames_by_key.get("%s_%d" % (prefix, n)) for n in range(start_number, end_number + 1)]
        if any(f is None for f in frames):
            return None
        min_x = min(f[0] for f in frames)
        min_y = min(f[1] for f in frames)
        max_x = max(f[0] + f[2] for f in frames)
        max_y = max(f[1] + f[3] for f in frames)
        return [min_x, min_y, max_x - min_x, max_y - min_y]
    return frames_by_key.get(key)


def tag_hits_target(tag, frame):
    x, y, width, height = frame
    box = tag.get("box")
    if box:
        center_x, center_y = box[0] + box[2] / 2.0, box[1] + box[3] / 2.0
        grow = BOX_CENTER_TOLERANCE_PT
        inside = (x - grow) <= center_x <= (x + width + grow) and (y - grow) <= center_y <= (y + height + grow)
        return inside and box[2] * box[3] <= 4 * width * height + 400
    point_x, point_y = tag["cgPoint"]
    grow = POINT_TOLERANCE_PT
    return (x - grow) <= point_x <= (x + width + grow) and (y - grow) <= point_y <= (y + height + grow)


def score_row(keys, tags, frames_by_key):
    """One hitting tag per key, in order (greedy in-order match)."""
    tag_index = 0
    for key in keys:
        frame = target_frame(key, frames_by_key)
        if frame is None:
            return False, "unknown key %s" % key
        while tag_index < len(tags) and not tag_hits_target(tags[tag_index], frame):
            tag_index += 1
        if tag_index >= len(tags):
            return False, "no tag hit %s" % key
        tag_index += 1
    return True, ""


def score_cover_row(keys, tags, frames_by_key, raw_response):
    """A covered item can't be seen: a hit means Clicky says so, or points
    at the window covering it (never a confident guess through it)."""
    lowered_response = raw_response.lower()
    if any(phrase in lowered_response for phrase in CANT_SEE_PHRASES):
        return True, "said it can't see it"
    frame = target_frame(keys[0], frames_by_key)
    if frame is None:
        return False, "unknown key %s" % keys[0]
    cover_frame = [frame[0] - COVER_PADDING_PT, frame[1] - COVER_PADDING_PT,
                   frame[2] + 2 * COVER_PADDING_PT, frame[3] + 2 * COVER_PADDING_PT]
    # A tag on the covering window but not on the hidden item's own spot.
    for tag in tags:
        if tag_hits_target(tag, cover_frame) and not tag_hits_target(tag, frame):
            return True, "pointed at the cover"
    return False, "guessed through the cover" if tags else "no tag and no can't-see"


def run_grounding(display_indexes, row_limit, badge_arms):
    rows = read_prompt_rows()[:row_limit] if row_limit else read_prompt_rows()
    results = []
    for display_index in display_indexes:
      for badge_arm in badge_arms:
        set_badges(badge_arm == "on")
        for row_number, row in enumerate(rows, start=1):
            keys = [k.strip() for k in row["keys"].split(",") if k.strip()]
            # Each row starts fresh: no conversation history from earlier rows.
            clickyctl({"cmd": "reset"}, 10)
            process, ground_truth = start_fixture(display_index, row.get("flags", ""))
            record = {"display": display_index, "row": row_number, "prompt": row["prompt"], "keys": keys,
                      "kind": row["kind"], "flags": row.get("flags", ""), "hit": False, "reason": "", "badges": badge_arm}
            try:
                if not ground_truth:
                    record["reason"] = "fixture not ready"
                    results.append(record)
                    continue
                frames_by_key = {item["key"]: item["frameCG"] for item in ground_truth["items"]}
                reply = clickyctl({"cmd": "ask", "text": row["prompt"], "speak": False}, 150)
                turn_directory = reply.get("turnDir")
                if not reply.get("ok") or not turn_directory:
                    record["reason"] = "ask failed: %s" % reply.get("error")
                    results.append(record)
                    continue
                with open(os.path.join(turn_directory, "turn.json")) as turn_file:
                    turn = json.load(turn_file)
                record["turnDir"] = turn_directory
                record["tags"] = [t["raw"] for t in turn.get("tags", [])]
                grounding = turn.get("grounding") or {}
                record["badgeMentions"] = grounding.get("badgeMentionsInNarration", 0)
                record["speechLeaks"] = grounding.get("speechLeakCount", 0)
                screens = turn.get("screens", [])
                if not screens or screens[0].get("displayID") != ground_truth.get("displayID"):
                    record["reason"] = "SCREEN 1 is not the fixture display"
                    results.append(record)
                    continue
                if row["kind"] == "cover":
                    record["hit"], record["reason"] = score_cover_row(keys, turn.get("tags", []), frames_by_key, turn.get("rawResponse", ""))
                else:
                    record["hit"], record["reason"] = score_row(keys, turn.get("tags", []), frames_by_key)
                results.append(record)
            finally:
                stop_fixture(process, ground_truth)
            print("display %d badges %-3s row %2d %-5s %s" % (display_index, badge_arm, row_number, "HIT" if record["hit"] else "miss", row["prompt"]), flush=True)
    return results


def run_latency(ask_count):
    samples = []
    for prompt in LATENCY_PROMPTS[:ask_count]:
        clickyctl({"cmd": "reset"}, 10)
        reply = clickyctl({"cmd": "ask", "text": prompt, "speak": True}, 150)
        turn_directory = reply.get("turnDir")
        if not turn_directory:
            continue
        with open(os.path.join(turn_directory, "turn.json")) as turn_file:
            turn = json.load(turn_file)
        timings = turn.get("timings", {})
        if "keyUp" in timings and "firstAudio" in timings:
            samples.append({
                "seconds": timings["firstAudio"] - timings["keyUp"],
                "engine": turn.get("speech", {}).get("engine"),
                "fallback": turn.get("speech", {}).get("fallback"),
                "stages": {k: round(v - timings["keyUp"], 3) for k, v in sorted(timings.items(), key=lambda kv: kv[1])},
            })
        # Let the answer finish speaking before the next ask.
        time.sleep(8)
        clickyctl({"cmd": "stop"}, 10)
    return samples


def wilson_interval(hits, total, z=1.96):
    """Wilson score 95% interval for hits/total, as (low, high)."""
    if total == 0:
        return (0.0, 0.0)
    proportion = hits / total
    denominator = 1 + z * z / total
    centre = (proportion + z * z / (2 * total)) / denominator
    margin = z * math.sqrt(proportion * (1 - proportion) / total + z * z / (4 * total * total)) / denominator
    return (max(0.0, centre - margin), min(1.0, centre + margin))


def set_badges(enabled):
    subprocess.run(["defaults", "write", "com.personal.clicky", "v2.grounding.badges", "-bool", "YES" if enabled else "NO"], check=False)


def bucket_of(kind):
    if kind in ("ax", "web"):
        return "ax+web"
    if kind in ("canvas", "dot"):
        return "canvas+dot"
    return kind


def percentile(values, fraction):
    ordered = sorted(values)
    if not ordered:
        return None
    index = min(len(ordered) - 1, max(0, int(round(fraction * (len(ordered) - 1)))))
    return ordered[index]


def write_report(output_path, ping_result, grounding_results, latency_samples):
    lines = ["# Clicky grounding baseline", ""]
    lines.append("- Build: `%s` (pid %s), voice engine %s" % (ping_result.get("sha"), ping_result.get("pid"), ping_result.get("voiceEngine")))
    lines.append("- Date: %s" % time.strftime("%Y-%m-%d %H:%M"))
    lines.append("- Rules: point/legacy MARK centre inside target + %.0f pt; multi-key rows in order; spans = union." % POINT_TOLERANCE_PT)
    lines.append("")
    lines.append("## Hits per display x kind")
    lines.append("")
    cover_results = [r for r in grounding_results if r["kind"] == "cover"]
    grounding_results = [r for r in grounding_results if r["kind"] != "cover"]
    kinds = sorted({r["kind"] for r in grounding_results})
    displays = sorted({r["display"] for r in grounding_results})
    lines.append("| display | " + " | ".join(kinds) + " | all |")
    lines.append("|---" * (len(kinds) + 2) + "|")
    for display_index in displays:
        cells = []
        for kind in kinds:
            subset = [r for r in grounding_results if r["display"] == display_index and r["kind"] == kind]
            cells.append("%d/%d" % (sum(r["hit"] for r in subset), len(subset)) if subset else "-")
        everything = [r for r in grounding_results if r["display"] == display_index]
        cells.append("**%d/%d**" % (sum(r["hit"] for r in everything), len(everything)))
        lines.append("| %d | " % display_index + " | ".join(cells) + " |")
    total_hits = sum(r["hit"] for r in grounding_results)
    lines.append("")
    lines.append("Total (excluding cover rows): **%d/%d** (%.0f%%)" % (total_hits, len(grounding_results), 100.0 * total_hits / max(1, len(grounding_results))))
    lines.append("")
    arms = sorted({r.get("badges", "on") for r in grounding_results + cover_results})
    lines.append("### Buckets with Wilson 95% intervals")
    lines.append("")
    lines.append("| badges | bucket | hits/n | rate | Wilson 95% |")
    lines.append("|---|---|---|---|---|")
    for arm in arms:
        for bucket in ["ax+web", "canvas+dot", "mixed", "cover"]:
            subset = [r for r in grounding_results + cover_results if r.get("badges", "on") == arm and bucket_of(r["kind"]) == bucket]
            if not subset:
                continue
            hits = sum(r["hit"] for r in subset)
            low, high = wilson_interval(hits, len(subset))
            lines.append("| %s | %s | %d/%d | %.1f%% | %.1f–%.1f%% |" % (arm, bucket, hits, len(subset), 100.0 * hits / len(subset), 100 * low, 100 * high))
        for display_index in displays:
            subset = [r for r in grounding_results if r.get("badges", "on") == arm and r["display"] == display_index and bucket_of(r["kind"]) == "canvas+dot"]
            if subset:
                hits = sum(r["hit"] for r in subset)
                lines.append("| %s | canvas+dot d%d | %d/%d | %.1f%% | |" % (arm, display_index, hits, len(subset), 100.0 * hits / len(subset)))
    mentions = sum(r.get("badgeMentions", 0) for r in grounding_results + cover_results)
    leaks = sum(r.get("speechLeaks", 0) for r in grounding_results + cover_results)
    lines.append("")
    lines.append("Badge/id mentions in raw narration (before the speech net): **%d**; ids stripped by the net: %d." % (mentions, leaks))
    lines.append("")
    if cover_results:
        lines.append("Cover rows (hit = says it can't see it, or points at the covering window): **%d/%d**" % (
            sum(r["hit"] for r in cover_results), len(cover_results)))
        for result in cover_results:
            lines.append("- d%d r%d `%s` -> %s" % (result["display"], result["row"], result["prompt"], result["reason"]))
        lines.append("")
    if latency_samples:
        seconds = [s["seconds"] for s in latency_samples]
        engines = sorted({str(s["engine"]) + (" (fallback)" if s["fallback"] else "") for s in latency_samples})
        lines.append("## Latency keyUp -> firstAudio (%d spoken asks)" % len(seconds))
        lines.append("")
        lines.append("- p50 %.2f s, p95 %.2f s, min %.2f s, max %.2f s; engine(s): %s" % (
            percentile(seconds, 0.5), percentile(seconds, 0.95), min(seconds), max(seconds), ", ".join(engines)))
        median_stages = {}
        for stage in latency_samples[0]["stages"]:
            values = [s["stages"][stage] for s in latency_samples if stage in s["stages"]]
            median_stages[stage] = statistics.median(values)
        lines.append("- median stage times from keyUp: " + ", ".join("%s %.2fs" % kv for kv in sorted(median_stages.items(), key=lambda kv: kv[1])))
        lines.append("")
    lines.append("## Missed rows")
    lines.append("")
    for result in grounding_results:
        if not result["hit"]:
            lines.append("- d%d r%d [badges %s] `%s` (%s) -> %s; tags: %s" % (
                result["display"], result["row"], result.get("badges", "on"), result["prompt"], ",".join(result["keys"]), result["reason"],
                " ".join(result.get("tags", [])) or "none"))
    with open(output_path, "w", encoding="utf-8") as report_file:
        report_file.write("\n".join(lines) + "\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--displays", default="0,1,2")
    parser.add_argument("--rows", type=int, default=0, help="only the first N prompt rows (0 = all)")
    parser.add_argument("--latency-asks", type=int, default=10)
    parser.add_argument("--badges", default="on", choices=["on", "off", "ab"])
    parser.add_argument("--out", default=os.path.join(REPO_ROOT, "docs", "v2", "EVAL.md"))
    arguments = parser.parse_args()

    if not os.path.exists(FIXTURE_BINARY):
        sys.exit("build the fixture first: Tools/GroundingFixture/build.sh")
    ping_result = require_single_clean_clicky()
    was_hands_free = bool(ping_result.get("handsFree"))
    clickyctl({"cmd": "handsfree", "on": False}, 10)
    try:
        display_indexes = [int(d) for d in arguments.displays.split(",") if d != ""]
        badge_arms = ["on", "off"] if arguments.badges == "ab" else [arguments.badges]
        grounding_results = run_grounding(display_indexes, arguments.rows, badge_arms)
        latency_samples = run_latency(arguments.latency_asks) if arguments.latency_asks else []
    finally:
        set_badges(True)
        clickyctl({"cmd": "handsfree", "on": was_hands_free}, 10)
        clickyctl({"cmd": "clear"}, 10)

    raw_output_directory = os.path.join(REPO_ROOT, "build", "eval")
    os.makedirs(raw_output_directory, exist_ok=True)
    with open(os.path.join(raw_output_directory, "results-%s.json" % time.strftime("%Y%m%d-%H%M%S")), "w") as raw_file:
        json.dump({"grounding": grounding_results, "latency": latency_samples}, raw_file, indent=2)
    write_report(arguments.out, ping_result, grounding_results, latency_samples)
    print("wrote %s" % arguments.out)


if __name__ == "__main__":
    main()
