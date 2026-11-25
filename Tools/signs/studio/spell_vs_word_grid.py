"""Tunes when a stretch counts as finger-spelling, on VALIDATION signers only: PopSign val (signs wrongly read as
spelling) and FSboard val (spelling wrongly read as signs), through sign-eval (the app's own reading)."""
import csv, itertools, json, re, subprocess, sys
from pathlib import Path
E = Path.home() / "Projects/clicky-wt-signs/Packages/ClickyCore/.build/release/sign-eval"
M = Path.home() / "Projects/clicky-wt-signs/Resources/SignModels"
P = Path.home() / "sign-data/snapshots/words-asl-popsign-s1/asl-s1-popsign"
F = Path.home() / "sign-data/snapshots/spell-asl-fsboard-s1/fsboard"
split = sys.argv[1] if len(sys.argv) > 1 else "val"
grid = list(itertools.product([0.6, 1.0, 1.5], [0.5, 0.7, 0.85], [0.6, 0.3])) if len(sys.argv) <= 2 else [tuple(json.loads(a)) for a in sys.argv[2:]]
labels = json.load(open(M / "SignWordsASL.labels.json")); labels = labels.get("labels", labels) if isinstance(labels, dict) else labels

def edits(a, b):
    previous = list(range(len(b) + 1))
    for i, x in enumerate(a, 1):
        current = [i] + [0] * len(b)
        for j, y in enumerate(b, 1):
            current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (x != y))
        previous = current
    return previous[-1]

def run(folder, settings, reads):
    args = [str(E), "clips", "--manifest", str(folder / "manifest.csv"), "--clips", str(folder), "--models", str(M), "--language", "asl", "--split", split, "--reads", reads]
    for name, value in settings.items(): args += ["--reading", f"{name}={value}"]
    out = subprocess.run(args, capture_output=True, text=True).stdout
    get = lambda key: float(re.search(rf"{key}:\s+\d+\s+([\d.]+)%", out).group(1))
    return get("read as a word"), get("right when read")

truth = {}
for folder in (P, F):
    for r in csv.DictReader(open(folder / "manifest.csv")):
        truth[r["clip_id"]] = r["label"]
words = {w.lower().replace("_", " ") for w in labels} | {w.lower() for w in labels}
print("seconds\tconfidence\twordBeats\tpopsign_answered\tpopsign_right\tpopsign_read_as_spelling\tfsboard_cer\tfsboard_exact", flush=True)
import os
GATE = os.environ.get("GATE") == "1"
SETTINGS = json.loads(os.environ["SETTINGS"]) if os.environ.get("SETTINGS") else None
if SETTINGS:
    grid = SETTINGS
    print("settings", flush=True)
if GATE:
    grid = list(itertools.product([0.6, 1.0, 1.5, 3.0], [0.15, 0.3, 0.5], [0.8, 0.6])) if len(sys.argv) <= 2 else [tuple(json.loads(a)) for a in sys.argv[2:]]
    print("travel\totherHand\tspellHand\t", flush=True)
for combo in grid:
    if SETTINGS:
        settings = combo; seconds, confidence, beats = json.dumps(combo), "", ""
    elif GATE:
        settings = {"mostSpellingWristTravelInBodySizes": combo[0], "mostShareOfFramesWithTheOtherHand": combo[1], "leastShareOfFramesWithTheSpellingHand": combo[2]}
        seconds, confidence, beats = combo
    else:
        seconds, confidence, beats = combo
        settings = {"shortestSpellingSeconds": seconds, "leastSpellingConfidence": confidence, "wordProbabilityThatBeatsSpelling": beats}
    p_answered, p_right = run(P, settings, "/tmp/grid_p.tsv")
    spelled = total = 0
    for line in open("/tmp/grid_p.tsv"):
        clip, _, read = line.rstrip("\n").partition("\t"); total += 1
        tokens = [t for t in read.split() if t != "?"]
        spelled += any(t.lower() not in words for t in tokens)
    run(F, settings, "/tmp/grid_f.tsv")
    errors = chars = exact = n = 0
    for line in open("/tmp/grid_f.tsv"):
        clip, _, read = line.rstrip("\n").partition("\t")
        target = truth[clip].lower().replace(" ", ""); got = read.replace("?", "").lower().replace(" ", "")
        errors += edits(got, target); chars += len(target); exact += got == target; n += 1
    print(f"{seconds}\t{confidence}\t{beats}\t{p_answered}\t{p_right}\t{100 * spelled / total:.1f}\t{100 * errors / chars:.1f}\t{100 * exact / n:.1f}", flush=True)
