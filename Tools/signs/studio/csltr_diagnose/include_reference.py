"""Whole-clip probabilities and descriptions for every INCLUDE clip, and each word's centre from its train clips."""
import numpy as np, sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).parent))
from scoring import WordScorer, load_clip, whole_clip_features, read_manifest
from signs.unknown_signs import class_centres

folder = Path.home() / "sign-data/landmarks/include"
scorer = WordScorer()
rows = [row for row in read_manifest(folder) if row["label"] in scorer.labels and (folder / f"{row['clip_id']}.npy").exists()]
features = [whole_clip_features(load_clip(folder / f"{row['clip_id']}.npy", row["fps"]), float(row["width"]), float(row["height"])) for row in rows]
probabilities, descriptions = scorer.score(features)
numbers = np.array([scorer.labels.index(row["label"]) for row in rows])
splits = np.array([row["split"] for row in rows])
centres = class_centres(descriptions[splits == "train"], numbers[splits == "train"], len(scorer.labels))
test = splits == "test"
order = np.argsort(-probabilities, axis=1)
print(f"INCLUDE test whole clip: top-1 {(order[test, 0] == numbers[test]).mean():.1%}, top-5 {(order[test, :5] == numbers[test, None]).any(1).mean():.1%} of {test.sum()}")
np.savez(Path(__file__).parent / "include_reference.npz", probabilities=probabilities, descriptions=descriptions, numbers=numbers,
         splits=splits, centres=centres, clip_ids=np.array([row["clip_id"] for row in rows]))
