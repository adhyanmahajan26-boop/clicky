"""How often Vision finds a hand while the body pose says that wrist is raised (above the rest line), per dataset
and picture size. usage: hand_found.py <landmarks folder> [max clips]"""
import csv, sys, collections, numpy as np
from pathlib import Path
from signs.landmarks import read_clip, LEFT_SHOULDER, RIGHT_SHOULDER, LEFT_HAND_START, RIGHT_HAND_START, CONFIDENCE
folder = Path(sys.argv[1]); limit = int(sys.argv[2]) if len(sys.argv) > 2 else 10**9
rows = list(csv.DictReader(open(folder / "manifest.csv")))[:limit]
totals = collections.defaultdict(lambda: [0, 0, 0, 0])  # raised frames, hand found, all frames, any hand
for row in rows:
    path = folder / f"{row['clip_id']}.npy"
    if not path.exists(): continue
    clip = read_clip(path); aspect = float(row["width"]) / float(row["height"])
    key = f"{row['width']}x{row['height']}"
    seen = clip[:, :, CONFIDENCE] > 0
    shoulders = seen[:, LEFT_SHOULDER] & seen[:, RIGHT_SHOULDER]
    mid_y = (clip[:, LEFT_SHOULDER, 1] + clip[:, RIGHT_SHOULDER, 1]) / 2
    width = np.hypot((clip[:, LEFT_SHOULDER, 0] - clip[:, RIGHT_SHOULDER, 0]) * aspect, clip[:, LEFT_SHOULDER, 1] - clip[:, RIGHT_SHOULDER, 1])
    rest = mid_y + 1.0 * width
    for body_wrist, hand_start in ((51, LEFT_HAND_START), (52, RIGHT_HAND_START)):
        raised = shoulders & seen[:, body_wrist] & (clip[:, body_wrist, 1] < rest)
        totals[key][0] += raised.sum(); totals[key][1] += (raised & seen[:, hand_start]).sum()
    totals[key][2] += len(clip); totals[key][3] += (seen[:, RIGHT_HAND_START] | seen[:, LEFT_HAND_START]).sum()
for key, (raised, found, frames, anyhand) in sorted(totals.items()):
    print(f"{folder.name} {key}: raised-wrist frames {raised}, hand found in {found / max(raised, 1):.1%}; frames with any hand {anyhand / max(frames, 1):.1%} of {frames}")
