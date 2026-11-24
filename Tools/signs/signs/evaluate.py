"""Loads a checkpoint (its EMA weights) and prints metrics on one split as JSON.

The signers of each split are the ones saved in the checkpoint, so `--split test` reads exactly the signers
training held out. Run the test split once, for the final number (SPEC section 5).

    python -m signs.evaluate --checkpoint runs/words-asl/checkpoint-best.pt --split test
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

from .data import SpellClipDataset, WordClipDataset, assign_splits, load_sources, references_in_split
from .splits import SPLIT_NAMES
from .training import DEVICE_CHOICES, default_worker_count, load_checkpoint, pick_device


def load_evaluation_model(checkpoint: dict):
    """The model a checkpoint describes, with its EMA weights, in eval mode on the CPU."""
    from .train_spell import TASK_NAME as SPELL_TASK_NAME
    from .train_spell import build_spell_model
    from .train_words import TASK_NAME as WORDS_TASK_NAME
    from .train_words import build_word_model

    if checkpoint["task"] == WORDS_TASK_NAME:
        model = build_word_model(checkpoint["encoder_settings"], len(checkpoint["labels"]))
    elif checkpoint["task"] == SPELL_TASK_NAME:
        model = build_spell_model(checkpoint["encoder_settings"], len(checkpoint["labels"]))
    else:
        raise ValueError(f"unknown checkpoint task {checkpoint['task']!r}")
    model.load_state_dict(checkpoint["ema_state"]["model"])
    return model.eval()


def evaluate_checkpoint(
    checkpoint_path: str,
    split: str,
    data_folders: list[str] | None = None,
    device_choice: str = "auto",
    batch_size: int = 128,
    workers: int = 0,
    landmark_source: str | None = None,
) -> dict:
    """`landmark_source` ("apple" or "mediapipe") keeps only clips from that landmark maker: SPEC section 5 asks
    for numbers on Apple Vision landmarks to be reported apart from MediaPipe ones."""
    from .train_spell import evaluate_spell_model
    from .train_words import TASK_NAME as WORDS_TASK_NAME
    from .train_words import evaluate_word_model

    checkpoint = load_checkpoint(checkpoint_path)
    device = pick_device(device_choice)
    if data_folders:
        if len(data_folders) != len(checkpoint["data_folders"]):
            raise SystemExit("--data must list the same number of folders, in the same order, as training used")
        data_folders = [str(Path(data_folder).resolve()) for data_folder in data_folders]
    else:
        data_folders = checkpoint["data_folders"]
    sources = load_sources(data_folders)
    sample_references, signer_splits = assign_splits(
        sources,
        checkpoint["seed"],
        saved_signer_splits=checkpoint["signer_splits"],
        language=checkpoint["language"],
    )
    split_references = references_in_split(sample_references, split)
    if landmark_source:
        split_references = [
            reference
            for reference in split_references
            if sources[reference.source_number].clip_records[reference.clip_number].source == landmark_source
        ]
    model = load_evaluation_model(checkpoint).to(device)
    labels = checkpoint["labels"]

    if checkpoint["task"] == WORDS_TASK_NAME:
        dataset = WordClipDataset(sources, split_references, labels, None, checkpoint["seed"], checkpoint["frame_count"])
        results = evaluate_word_model(model, dataset, labels, device, batch_size, workers)
        results["clips_with_a_word_not_in_the_model"] = len(split_references) - len(dataset)
    else:
        # Every sample is scored here, even one whose phrase is longer than its frames allow: dropping those
        # would flatter the number.
        dataset = SpellClipDataset(
            sources,
            split_references,
            labels,
            None,
            checkpoint["seed"],
            checkpoint["frame_count"],
            drop_targets_too_long_for_the_frames=False,
        )
        results = evaluate_spell_model(model, dataset, labels, device, batch_size, workers)
    return {
        "checkpoint": str(checkpoint_path),
        "task": checkpoint["task"],
        "epoch": checkpoint["epoch"],
        "split": split,
        "landmark_source": landmark_source or "all",
        **results,
    }


def main(argument_list=None) -> None:
    argument_parser = argparse.ArgumentParser(description="Print a checkpoint's metrics on one split as JSON.")
    argument_parser.add_argument("--checkpoint", required=True)
    argument_parser.add_argument("--split", choices=SPLIT_NAMES, default="val")
    argument_parser.add_argument("--data", nargs="+", default=None, help="dataset folders, if they moved since training")
    argument_parser.add_argument("--device", choices=DEVICE_CHOICES, default="auto")
    argument_parser.add_argument("--batch-size", type=int, default=128)
    argument_parser.add_argument("--workers", type=int, default=default_worker_count())
    argument_parser.add_argument(
        "--source", choices=("apple", "mediapipe"), default=None, help="only clips whose landmarks came from this"
    )
    parsed_arguments = argument_parser.parse_args(argument_list)
    results = evaluate_checkpoint(
        parsed_arguments.checkpoint,
        parsed_arguments.split,
        parsed_arguments.data,
        parsed_arguments.device,
        parsed_arguments.batch_size,
        parsed_arguments.workers,
        parsed_arguments.source,
    )
    json.dump(results, sys.stdout, indent=1, ensure_ascii=False)
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
