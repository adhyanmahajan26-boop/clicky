"""Checkpoint -> Core ML `.mlpackage` (ML Program) + `<name>.labels.json` next to it (SPEC section 4).

    python -m signs.export_coreml --checkpoint runs/words-asl/checkpoint-best.pt --output SignWordsASL.mlpackage

Inputs: `features` [1, N, 117] float32 and `mask` [1, N] float32 (1 for real frames, 0 for padding), N = 96 for
words and 256 for spelling. Outputs: words `scores` [1, words] and `description` [1, 256]; spelling `scores`
[1, N / 2, characters + 1], log-probabilities with the CTC blank at index 0. The labels file is a JSON list: the
words, or the characters (character i is score index i + 1).

coremltools is only imported when converting, so everything else works without it.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path

import torch
from torch import nn

from .evaluate import load_evaluation_model
from .features import FEATURE_COUNT
from .training import load_checkpoint


class _WordExportWrapper(nn.Module):
    def __init__(self, word_model: nn.Module):
        super().__init__()
        self.word_model = word_model

    def forward(self, features: torch.Tensor, mask: torch.Tensor):
        scores, description = self.word_model(features, mask)
        return scores, description


class _SpellExportWrapper(nn.Module):
    """Only the log-probabilities: the app knows the output length from its own mask."""

    def __init__(self, spell_model: nn.Module):
        super().__init__()
        self.spell_model = spell_model

    def forward(self, features: torch.Tensor, mask: torch.Tensor):
        log_probabilities, output_lengths = self.spell_model(features, mask)
        return log_probabilities


def trace_checkpoint(checkpoint: dict) -> tuple[torch.jit.ScriptModule, int, list[str]]:
    """Traces the checkpoint's EMA model on its fixed input shape. Returns (traced, frame count, output names)."""
    model = load_evaluation_model(checkpoint)
    frame_count = int(checkpoint["frame_count"])
    if checkpoint["task"] == "words":
        export_module = _WordExportWrapper(model).eval()
        output_names = ["scores", "description"]
    else:
        export_module = _SpellExportWrapper(model).eval()
        output_names = ["scores"]
    example_features = torch.zeros(1, frame_count, FEATURE_COUNT)
    example_mask = torch.ones(1, frame_count)
    with torch.no_grad():
        traced = torch.jit.trace(export_module, (example_features, example_mask), check_trace=False)
    return traced, frame_count, output_names


def export_checkpoint(checkpoint_path: str, output_path: str, use_float16: bool = False) -> Path:
    try:
        import coremltools
        import numpy
    except ImportError as import_error:
        raise SystemExit("coremltools is needed for export: pip install coremltools") from import_error

    checkpoint = load_checkpoint(checkpoint_path)
    traced, frame_count, output_names = trace_checkpoint(checkpoint)
    compute_precision = coremltools.precision.FLOAT16 if use_float16 else coremltools.precision.FLOAT32
    core_ml_model = coremltools.convert(
        traced,
        inputs=[
            coremltools.TensorType(name="features", shape=(1, frame_count, FEATURE_COUNT), dtype=numpy.float32),
            coremltools.TensorType(name="mask", shape=(1, frame_count), dtype=numpy.float32),
        ],
        outputs=[coremltools.TensorType(name=output_name) for output_name in output_names],
        convert_to="mlprogram",
        compute_precision=compute_precision,
        minimum_deployment_target=coremltools.target.macOS13,
    )
    core_ml_model.short_description = (
        f"Vello sign model ({checkpoint['task']}), {frame_count} frames of the 117 SPEC features"
    )
    output_path = Path(output_path)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    core_ml_model.save(str(output_path))

    labels_path = output_path.with_name(output_path.stem + ".labels.json")
    with open(labels_path, "w", encoding="utf-8") as labels_file:
        json.dump(checkpoint["labels"], labels_file, ensure_ascii=False)
    return output_path


def main(argument_list=None) -> None:
    argument_parser = argparse.ArgumentParser(description="Export a checkpoint to Core ML.")
    argument_parser.add_argument("--checkpoint", required=True)
    argument_parser.add_argument("--output", required=True, help="e.g. SignWordsASL.mlpackage")
    argument_parser.add_argument("--float16", action="store_true", help="store and compute in float16")
    parsed_arguments = argument_parser.parse_args(argument_list)
    written_path = export_checkpoint(parsed_arguments.checkpoint, parsed_arguments.output, parsed_arguments.float16)
    print(f"wrote {written_path} and {written_path.stem}.labels.json")


if __name__ == "__main__":
    main()
