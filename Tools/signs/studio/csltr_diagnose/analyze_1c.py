"""1c: landmark quality for the same CSLTR sentence at 320x240 and 1920x1080 (and the small one upscaled 4x before
Vision, when extracted into landmarks/isl-csltr-upscaled under the small clip's id).
Per clip: share of raised-wrist frames (body pose) with that hand found; mean hand confidence; jitter (median frame
to frame jump of the hand's joints after removing the wrist's own path, in shoulder widths); and the share of
raised-wrist frames with the body wrist and the hand's wrist more than half a shoulder width apart (a hand put on
the wrong arm or a wrong body pose)."""
import csv, json, sys, numpy as np
from pathlib import Path
from signs.landmarks import read_clip, LEFT_SHOULDER, RIGHT_SHOULDER, LEFT_HAND_START, RIGHT_HAND_START, CONFIDENCE

DATA = Path.home() / "sign-data"
pairs = json.loads((DATA / "downloads/isl-csltr/pairs.json").read_text())

def manifest(folder):
    path = folder / "manifest.csv"
    if not path.exists():
        path = folder / "extract.csv"
    return {row["clip_id"]: row for row in csv.DictReader(open(path))} if path.exists() else {}

def measure(path, width, height):
    clip = read_clip(path); aspect = width / height
    seen = clip[:, :, CONFIDENCE] > 0
    shoulders = seen[:, LEFT_SHOULDER] & seen[:, RIGHT_SHOULDER]
    xy = clip[:, :, :2] * np.array([aspect, 1.0])
    shoulder_width = np.median(np.linalg.norm(xy[shoulders, LEFT_SHOULDER] - xy[shoulders, RIGHT_SHOULDER], axis=1)) if shoulders.any() else np.nan
    rest = (xy[:, LEFT_SHOULDER, 1] + xy[:, RIGHT_SHOULDER, 1]) / 2 + shoulder_width
    raised_total = found = apart = 0; confidences = []; jumps = []
    for body_wrist, start in ((51, LEFT_HAND_START), (52, RIGHT_HAND_START)):
        raised = shoulders & seen[:, body_wrist] & (xy[:, body_wrist, 1] < rest)
        hand = seen[:, start]
        raised_total += raised.sum(); found += (raised & hand).sum()
        both = raised & hand
        apart += (np.linalg.norm(xy[both, body_wrist] - xy[both, start], axis=1) > 0.5 * shoulder_width).sum()
        confidences += list(clip[hand, start:start + 21, CONFIDENCE].mean(axis=1))
        shape = xy[:, start:start + 21] - xy[:, start:start + 1]
        steady = hand[1:] & hand[:-1]
        if steady.any():
            jumps += list(np.linalg.norm(shape[1:][steady] - shape[:-1][steady], axis=2).mean(axis=1) / shoulder_width)
    return {"raised": int(raised_total), "found": found / max(raised_total, 1), "confidence": float(np.mean(confidences)) if confidences else np.nan,
            "jitter": float(np.median(jumps)) if jumps else np.nan, "wrong_wrist": apart / max(found, 1), "shoulder_width": float(shoulder_width)}

folders = {"original": DATA / "landmarks/isl-csltr", "upscaled": DATA / "landmarks/isl-csltr-upscaled"}
rows = {name: manifest(folder) for name, folder in folders.items()}
print(f"{'sentence':30s} {'version':18s} {'raised':>6s} {'found':>6s} {'conf':>5s} {'jitter':>6s} {'wrong':>6s}")
totals = {}
for sentence, pair in pairs.items():
    for size, clip_id in (("320x240", pair["small"]), ("1920x1080", pair["big"]), ("320x240 upscaled", pair["small"])):
        version = "upscaled" if "upscaled" in size else "original"
        row = rows[version].get(clip_id)
        if row is None or not (folders[version] / f"{clip_id}.npy").exists():
            continue
        result = measure(folders[version] / f"{clip_id}.npy", float(row["width"]), float(row["height"]))
        totals.setdefault(size, []).append(result)
        print(f"{sentence[:30]:30s} {size:18s} {result['raised']:6d} {result['found']:6.1%} {result['confidence']:5.2f} {result['jitter']:6.3f} {result['wrong_wrist']:6.1%}")
print()
for size, results in totals.items():
    raised = sum(r["raised"] for r in results)
    found = sum(r["found"] * r["raised"] for r in results) / max(raised, 1)
    print(f"{size:18s} clips {len(results)}: hand found {found:.1%} of {raised} raised-wrist frames; median jitter {np.nanmedian([r['jitter'] for r in results]):.3f} "
          f"shoulder widths; hand far from its body wrist {np.nanmean([r['wrong_wrist'] for r in results]):.1%}; confidence {np.nanmean([r['confidence'] for r in results]):.2f}")
