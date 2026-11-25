"""INCLUDE test clips scored whole, cut to their signing part (a wrist above the rest line, one shoulder width under the
shoulders, as SignStretchSettings), and cut to the middle 60% of that: how much does the word model lean on the
rise from rest and the drop back?"""
import sys, numpy as np
from pathlib import Path
HERE = Path(__file__).parent; sys.path.insert(0, str(HERE))
from scoring import WordScorer, load_clip, whole_clip_features, read_manifest
from signs.features import compute_features
from signs.landmarks import LEFT_SHOULDER, RIGHT_SHOULDER, RIGHT_HAND_START, LEFT_HAND_START, CONFIDENCE

def signing_part(clip, aspect):
    xy = clip[:, :, :2] * np.array([aspect, 1.0]); seen = clip[:, :, CONFIDENCE] > 0
    ok = seen[:, LEFT_SHOULDER] & seen[:, RIGHT_SHOULDER]
    if not ok.any(): return clip
    mid = np.median((xy[ok, LEFT_SHOULDER, 1] + xy[ok, RIGHT_SHOULDER, 1]) / 2)
    width = np.median(np.linalg.norm(xy[ok, LEFT_SHOULDER] - xy[ok, RIGHT_SHOULDER], axis=1))
    raised = np.zeros(len(clip), bool)
    for start, body in ((RIGHT_HAND_START, 52), (LEFT_HAND_START, 51)):
        y = np.where(seen[:, start], xy[:, start, 1], np.where(seen[:, body], xy[:, body, 1], np.inf))
        raised |= y < mid + width
    if not raised.any(): return clip
    first, last = np.argmax(raised), len(raised) - 1 - np.argmax(raised[::-1])
    return clip[first:last + 1]

folder = Path.home() / "sign-data/landmarks/include"
scorer = WordScorer()
rows = [r for r in read_manifest(folder) if r["split"] == "test" and r["label"] in scorer.labels]
variants = {"whole": [], "signing part": [], "middle 60% of it": []}
truth = np.array([scorer.labels.index(r["label"]) for r in rows]); kept_share = []
for row in rows:
    w, h = float(row["width"]), float(row["height"])
    clip = load_clip(folder / f"{row['clip_id']}.npy", row["fps"])
    part = signing_part(clip, w / h); kept_share.append(len(part) / len(clip))
    n = len(part); middle = part[int(0.2 * n): max(int(0.8 * n), int(0.2 * n) + 1)]
    variants["whole"].append(whole_clip_features(clip, w, h))
    variants["signing part"].append(compute_features(part, w, h))
    variants["middle 60% of it"].append(compute_features(middle, w, h))
print(f"{len(rows)} INCLUDE test clips; signing part keeps {np.mean(kept_share):.0%} of the frames on average")
for name, features in variants.items():
    probabilities, _ = scorer.score(features); order = np.argsort(-probabilities, axis=1)
    print(f"  {name:18s} top-1 {(order[:, 0] == truth).mean():.1%}  top-5 {(order[:, :5] == truth[:, None]).any(1).mean():.1%}")
