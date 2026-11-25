"""1b: the same word in INCLUDE and CSLTR.
Distances: cosine distance of a clip's description (the word model's last layer before the scores) to INCLUDE's centre
for its word, against the nearest OTHER centre. INCLUDE test clips are the reference. For CSLTR the window used is the
one where the word model ranks that word highest, which flatters CSLTR (it is chosen to look like the word).
Plots (experiments/csltr-diagnose/plots): each shared word's wrist paths and mid-sign hand shapes in both datasets."""
import csv, json, sys, collections, numpy as np
from pathlib import Path
HERE = Path(__file__).parent
sys.path.insert(0, str(HERE))
import matplotlib; matplotlib.use("Agg")
import matplotlib.pyplot as plt
from scoring import load_clip
from signs.landmarks import LEFT_SHOULDER, RIGHT_SHOULDER, RIGHT_HAND_START, LEFT_HAND_START, CONFIDENCE

reference = np.load(HERE / "include_reference.npz")
windows = np.load(HERE / "windows.npz")
labels = json.loads((Path.home() / "sign-data/runs/words-isl-include/labels.json").read_text())
centres = reference["centres"]

def unit(vectors):
    return vectors / np.maximum(np.linalg.norm(vectors, axis=1, keepdims=True), 1e-12)

def own_and_other(descriptions, numbers):
    similarities = unit(descriptions) @ centres.T
    own = 1 - similarities[np.arange(len(numbers)), numbers]
    masked = similarities.copy(); masked[np.arange(len(numbers)), numbers] = -np.inf
    other = 1 - masked.max(axis=1)
    rank = (similarities > similarities[np.arange(len(numbers)), numbers][:, None]).sum(axis=1) + 1
    return own, other, rank

test = reference["splits"] == "test"
own, other, rank = own_and_other(reference["descriptions"][test], reference["numbers"][test])
print(f"INCLUDE test clips ({test.sum()}): distance to own word's centre median {np.median(own):.3f}, to nearest other {np.median(other):.3f}; "
      f"own centre nearest {np.mean(rank == 1):.1%}, in nearest 5 {np.mean(rank <= 5):.1%}")
POINTING = {"i", "you", "he", "she", "we", "it"}
numbers = np.array([labels.index(word) for word in windows["words"]])
c_own, c_other, c_rank = own_and_other(windows["descriptions"], numbers)
for name, keep in (("other words", ~np.isin(windows["words"], list(POINTING))), ("pointing", np.isin(windows["words"], list(POINTING)))):
    print(f"CSLTR best windows, {name} ({keep.sum()}): to own centre median {np.median(c_own[keep]):.3f}, nearest other {np.median(c_other[keep]):.3f}; "
          f"own centre nearest {np.mean(c_rank[keep] == 1):.1%}, in nearest 5 {np.mean(c_rank[keep] <= 5):.1%}")
print("per word: INCLUDE test median own distance | CSLTR median own distance, own-centre rank median")
for word in sorted(set(windows["words"])):
    keep = windows["words"] == word
    inc = reference["numbers"][test] == labels.index(word)
    print(f"  {word:10s} INCLUDE {np.median(own[inc]) if inc.any() else float('nan'):.3f} ({inc.sum()}) | CSLTR {np.median(c_own[keep]):.3f} ({keep.sum()}), rank {np.median(c_rank[keep]):.0f}")

# ---- plots ----
plots = HERE / "plots"; plots.mkdir(exist_ok=True)
include_folder = Path.home() / "sign-data/landmarks/include"; csltr_folder = Path.home() / "sign-data/landmarks/isl-csltr-named"
include_rows = collections.defaultdict(list)
for row in csv.DictReader(open(include_folder / "manifest.csv")):
    include_rows[row["label"]].append(row)
csltr_rows = {row["clip_id"]: row for row in csv.DictReader(open(csltr_folder / "extract.csv"))}

def body_frame(clip, aspect):
    """Points in shoulder widths about the shoulder centre (x to the picture's right, y down)."""
    xy = clip[:, :, :2] * np.array([aspect, 1.0]); seen = clip[:, :, CONFIDENCE] > 0
    ok = seen[:, LEFT_SHOULDER] & seen[:, RIGHT_SHOULDER]
    if not ok.any():
        return None, seen
    centre = np.median((xy[ok, LEFT_SHOULDER] + xy[ok, RIGHT_SHOULDER]) / 2, axis=0)
    width = np.median(np.linalg.norm(xy[ok, LEFT_SHOULDER] - xy[ok, RIGHT_SHOULDER], axis=1))
    return (xy - centre) / width, seen

def hand_shape(points, seen, start, frames):
    """Mean hand shape (joints about the wrist, scaled by wrist to middle-finger base) over the given frames."""
    shapes = []
    for frame in frames:
        if seen[frame, start] and seen[frame, start + 9]:
            relative = points[frame, start:start + 21] - points[frame, start]
            shapes.append(relative / max(np.linalg.norm(relative[9]), 1e-6))
    return np.mean(shapes, axis=0) if shapes else None

BONES = [(0, 1), (1, 2), (2, 3), (3, 4), (0, 5), (5, 6), (6, 7), (7, 8), (0, 9), (9, 10), (10, 11), (11, 12), (0, 13), (13, 14), (14, 15), (15, 16), (0, 17), (17, 18), (18, 19), (19, 20)]
for word in sorted(set(windows["words"]) - POINTING):
    figure, axes = plt.subplots(1, 3, figsize=(15, 5))
    for source, colour in (("INCLUDE", "tab:blue"), ("CSLTR", "tab:red")):
        if source == "INCLUDE":
            items = [(include_folder / f"{r['clip_id']}.npy", r["fps"], float(r["width"]) / float(r["height"]), None) for r in include_rows[word][:12]]
        else:
            keep = np.where(windows["words"] == word)[0]
            items = [(csltr_folder / f"{windows['clip_ids'][i]}.npy", csltr_rows[windows["clip_ids"][i]]["fps"],
                      float(csltr_rows[windows["clip_ids"][i]]["width"]) / float(csltr_rows[windows["clip_ids"][i]]["height"]),
                      (int(windows["starts"][i]), int(windows["lengths"][i]))) for i in keep]
        for path, fps, aspect, span in items:
            clip = load_clip(path, fps)
            if span: clip = clip[span[0]:span[0] + span[1]]
            points, seen = body_frame(clip, aspect)
            if points is None: continue
            for axis_number, (start, body_wrist) in enumerate(((RIGHT_HAND_START, 52), (LEFT_HAND_START, 51))):
                wrist = np.where(seen[:, start, None], points[:, start], np.where(seen[:, body_wrist, None], points[:, body_wrist], np.nan))
                axes[axis_number].plot(wrist[:, 0], wrist[:, 1], color=colour, alpha=0.5, lw=1)
            active = [f for f in range(len(clip)) if seen[f, RIGHT_HAND_START]]
            middle = active[len(active) // 3: 2 * len(active) // 3 + 1]
            shape = hand_shape(points, seen, RIGHT_HAND_START, middle)
            if shape is not None:
                for a, b in BONES:
                    axes[2].plot([shape[a, 0], shape[b, 0]], [shape[a, 1], shape[b, 1]], color=colour, alpha=0.35, lw=1)
    for axis, title in zip(axes, ("right wrist path", "left wrist path", "right hand shape, middle third")):
        axis.set_title(title); axis.invert_yaxis(); axis.set_aspect("equal")
    for axis in axes[:2]:
        axis.plot([-0.5, 0.5], [0, 0], "k-", lw=3); axis.set_xlim(-2.5, 2.5); axis.set_ylim(2.5, -2.5)
    figure.suptitle(f"{word}: INCLUDE (blue, up to 12 clips) vs CSLTR best window (red); shoulder widths about the shoulder centre")
    figure.savefig(plots / f"{word}.png", dpi=80); plt.close(figure)
print("plots in", plots)
