"""Scores a few test clips with the PyTorch checkpoint and with the exported Core ML model; prints the largest gap.
usage: coreml_check.py <checkpoint> <mlpackage> [clip count]   (run from Tools/signs with the venv's python)"""
import sys
import numpy as np, torch, coremltools as ct
from signs.data import WordClipDataset, assign_splits, load_sources, references_in_split
from signs.evaluate import load_evaluation_model
from signs.training import load_checkpoint
checkpoint_path, package_path = sys.argv[1], sys.argv[2]
clip_count = int(sys.argv[3]) if len(sys.argv) > 3 else 20
checkpoint = load_checkpoint(checkpoint_path)
sources = load_sources(checkpoint["data_folders"])
references, _ = assign_splits(sources, checkpoint["seed"], saved_signer_splits=checkpoint["signer_splits"], language=checkpoint["language"])
dataset = WordClipDataset(sources, references_in_split(references, "test"), checkpoint["labels"], None, checkpoint["seed"], checkpoint["frame_count"])
model = load_evaluation_model(checkpoint)
# An export made with a calibration file divides the scores by its temperature; PyTorch's scores are divided the same.
import json, os
calibration_path = checkpoint_path.replace(".pt", ".calibration.json")
temperature = json.load(open(calibration_path)).get("temperature", 1.0) if os.path.exists(calibration_path) else 1.0
coreml_model = ct.models.MLModel(package_path)
largest_score_gap = largest_probability_gap = 0.0
same_top1 = 0
for index in range(min(clip_count, len(dataset))):
    features, mask, _ = dataset[index]
    with torch.no_grad():
        torch_scores = model(features[None], mask[None])[0][0].numpy() / temperature
    coreml_scores = coreml_model.predict({"features": features[None].numpy().astype(np.float32), "mask": mask[None].numpy().astype(np.float32)})["scores"][0]
    largest_score_gap = max(largest_score_gap, float(np.abs(torch_scores - coreml_scores).max()))
    softmax = lambda values: np.exp(values - values.max()) / np.exp(values - values.max()).sum()
    largest_probability_gap = max(largest_probability_gap, float(np.abs(softmax(torch_scores) - softmax(coreml_scores)).max()))
    same_top1 += int(torch_scores.argmax() == coreml_scores.argmax())
print(f"temperature {temperature:.4f}; clips {min(clip_count, len(dataset))}: largest score gap {largest_score_gap:.2e}, largest probability gap {largest_probability_gap:.2e}, same top-1 {same_top1}")
