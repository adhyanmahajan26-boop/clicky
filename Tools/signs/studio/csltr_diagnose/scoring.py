"""The INCLUDE word model on whole clips and on sliding windows, with its description vectors (run from Tools/signs
with PYTHONPATH=.)."""
import csv, json, numpy as np, torch
from pathlib import Path
from signs.evaluate import load_evaluation_model
from signs.features import compute_features, fit_to_frame_count, trim_frames_without_hands, frames_with_a_hand
from signs.frame_rate import resample_clip_to_30_per_second
from signs.landmarks import read_clip
from signs.training import load_checkpoint

RUN = Path.home() / "sign-data/runs/words-isl-include"


class WordScorer:
    def __init__(self, checkpoint_path=RUN / "checkpoint-best.pt"):
        self.checkpoint = load_checkpoint(str(checkpoint_path))
        self.model = load_evaluation_model(self.checkpoint)
        self.labels = self.checkpoint["labels"]
        self.frame_count = self.checkpoint["frame_count"]
        calibration = json.loads(Path(str(checkpoint_path).replace(".pt", ".calibration.json")).read_text())
        self.temperature = calibration["temperature"]

    def score(self, feature_list):
        """[(features [T,117])] -> (probabilities [N, words], descriptions [N, D])."""
        fitted = [fit_to_frame_count(features, self.frame_count) for features in feature_list]
        probabilities, descriptions = [], []
        with torch.no_grad():
            for start in range(0, len(fitted), 256):
                batch = fitted[start:start + 256]
                features = torch.from_numpy(np.stack([item[0] for item in batch]))
                masks = torch.from_numpy(np.stack([item[1] for item in batch]))
                scores, description = self.model(features, masks)
                probabilities.append(torch.softmax(scores / self.temperature, dim=1).numpy())
                descriptions.append(description.numpy())
        return np.concatenate(probabilities), np.concatenate(descriptions)


def load_clip(path, fps):
    return resample_clip_to_30_per_second(read_clip(path), float(fps))


def whole_clip_features(clip, width, height):
    return compute_features(trim_frames_without_hands(clip), width, height)


def windows(clip, lengths=(30, 45, 60, 90), stride=5):
    """(start, length) of every window with a hand in at least a third of its frames."""
    has_hand = frames_with_a_hand(clip)
    found = []
    for length in lengths:
        if len(clip) < length:
            continue
        for start in range(0, len(clip) - length + 1, stride):
            if has_hand[start:start + length].mean() >= 1 / 3:
                found.append((start, length))
    if not found and has_hand.any():
        found.append((0, len(clip)))
    return found


def read_manifest(folder):
    with open(Path(folder) / "manifest.csv") as manifest_file:
        return list(csv.DictReader(manifest_file))
