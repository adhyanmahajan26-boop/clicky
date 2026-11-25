"""Where each INCLUDE clip's signer stands in the picture (the camera stays put within a session): median shoulder
centre x, y and shoulder width over the clip's first 10 frames (resting), and the hips' centre y when seen.
Writes placement.json: [clip_id, mvi number, label, split, [cx, cy, width, hip_y]]."""
import csv, json, re, numpy as np
from pathlib import Path
import sys; sys.path.insert(0, str(Path.home() / "Projects/clicky-wt-signs/Tools/signs"))
from signs.landmarks import read_clip, LEFT_SHOULDER, RIGHT_SHOULDER, CONFIDENCE
folder = Path.home() / "sign-data/landmarks/include"
out = []
for row in csv.DictReader(open(folder / "manifest.csv")):
    clip = read_clip(folder / f"{row['clip_id']}.npy")[:10]
    aspect = float(row["width"]) / float(row["height"])
    seen = clip[:, :, CONFIDENCE] > 0
    ok = seen[:, LEFT_SHOULDER] & seen[:, RIGHT_SHOULDER]
    if not ok.any():
        continue
    xy = clip[:, :, :2] * np.array([aspect, 1.0])
    centre = np.median((xy[ok, LEFT_SHOULDER] + xy[ok, RIGHT_SHOULDER]) / 2, axis=0)
    width = float(np.median(np.linalg.norm(xy[ok, LEFT_SHOULDER] - xy[ok, RIGHT_SHOULDER], axis=1)))
    hips = seen[:, 53] & seen[:, 54] if clip.shape[1] > 54 else np.zeros(len(clip), bool)
    hip_y = float(np.median((xy[hips, 53, 1] + xy[hips, 54, 1]) / 2)) if hips.any() else None
    number = re.search(r"mvi_(\d+)", row["clip_id"])
    out.append([row["clip_id"], int(number.group(1)) if number else -1, row["label"], row["split"], [float(centre[0]), float(centre[1]), width, hip_y]])
json.dump(out, open(Path(__file__).parent / "placement.json", "w"))
numbers = [r[1] for r in out]
print(len(out), "clips;", len(numbers) - len(set(numbers)), "repeated MVI numbers; range", min(numbers), max(numbers))
