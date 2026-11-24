"""Honest confidence: when the model isn't sure of a sign, the app says "unclear" rather than a wrong word.

People act on what the reader says, so a word it isn't sure of must not come out as a word. Given a word (or
still-letter) checkpoint and its data, this:

1. Fits one temperature on the validation signers: the scores are divided by it before the softmax, and it is
   the one that makes the validation clips' negative log likelihood smallest (the likelihood is convex in
   1 / temperature, so a golden-section search finds the best one).
2. For each "least probability to answer" (0.00, 0.01, … 0.99) works out, on validation, the share of clips the
   model would answer (top probability at least that) and the share right among those answered. The chosen value
   is the lowest one where answered clips are right at least `--right-when-answered` of the time (default 0.95).
   When no value gets there it says so plainly and takes the one with the best share right.
3. Prints the same two numbers on the test signers at the chosen value (the only time test is read), and, when the
   data holds clips of signs the model was never taught, how many of those it would wrongly answer.

It writes `<checkpoint>.calibration.json` next to the checkpoint (for example `checkpoint-best.calibration.json`).
`python -m signs.export_coreml` reads that file when it is there: it divides the exported scores by the
temperature, so the app's plain softmax gives calibrated probabilities, and writes `<model name>.reading.json`
next to the `.mlpackage`: `{"leastWordProbability", "rightWhenAnsweredOnValidation", "answeredOnValidation",
"temperature"}`. The file remembers a fingerprint of the checkpoint's weights, so a checkpoint trained further
after calibrating can't be exported with a stale temperature.

    python -m signs.calibrate --checkpoint runs/words-asl/checkpoint-best.pt --source apple
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
from pathlib import Path

import numpy as np
import torch

from .data import WordClipDataset, load_sources, references_in_split
from .evaluate import load_evaluation_model
from .extra_tasks import split_references_for_checkpoint
from .letters import LETTERS_TASK_NAME
from .splits import TEST_SPLIT, VALIDATION_SPLIT
from .training import DEVICE_CHOICES, default_worker_count, load_checkpoint, make_loader, move_to_device, pick_device

WORDS_TASK_NAME = "words"
CALIBRATED_TASK_NAMES = (WORDS_TASK_NAME, LETTERS_TASK_NAME)
CALIBRATION_FILE_SUFFIX = ".calibration.json"
READING_FILE_SUFFIX = ".reading.json"
DEFAULT_RIGHT_WHEN_ANSWERED = 0.95
DEFAULT_THRESHOLD_STEP = 0.01
# 1 / temperature is searched between these: temperatures from 0.05 (sharpen a lot) to 20 (flatten a lot).
SMALLEST_INVERSE_TEMPERATURE = 0.05
LARGEST_INVERSE_TEMPERATURE = 20.0


# ---- the numbers -------------------------------------------------------------------------------------------------


def softmax_with_temperature(scores: np.ndarray, temperature: float) -> np.ndarray:
    scaled_scores = np.asarray(scores, dtype=np.float64) / temperature
    scaled_scores = scaled_scores - scaled_scores.max(axis=1, keepdims=True)
    exponentials = np.exp(scaled_scores)
    return exponentials / exponentials.sum(axis=1, keepdims=True)


def negative_log_likelihood(scores: np.ndarray, word_numbers: np.ndarray, temperature: float) -> float:
    """Mean −log p(right word) with the scores divided by `temperature`."""
    scaled_scores = np.asarray(scores, dtype=np.float64) / temperature
    largest_scores = scaled_scores.max(axis=1, keepdims=True)
    log_partition = np.log(np.exp(scaled_scores - largest_scores).sum(axis=1)) + largest_scores[:, 0]
    right_scores = scaled_scores[np.arange(len(word_numbers)), word_numbers]
    return float(np.mean(log_partition - right_scores))


def fit_temperature(scores: np.ndarray, word_numbers: np.ndarray, search_steps: int = 80) -> float:
    """The temperature with the smallest validation negative log likelihood.

    As a function of 1 / temperature the likelihood is a log-sum-exp of straight lines minus a straight line,
    which is convex, so a golden-section search over 1 / temperature finds the one best value."""
    golden_ratio_part = (math.sqrt(5) - 1) / 2

    def loss_at(inverse_temperature: float) -> float:
        return negative_log_likelihood(scores, word_numbers, 1.0 / inverse_temperature)

    low, high = SMALLEST_INVERSE_TEMPERATURE, LARGEST_INVERSE_TEMPERATURE
    inner_low = high - golden_ratio_part * (high - low)
    inner_high = low + golden_ratio_part * (high - low)
    loss_at_inner_low, loss_at_inner_high = loss_at(inner_low), loss_at(inner_high)
    for search_step in range(search_steps):
        if loss_at_inner_low <= loss_at_inner_high:
            high, inner_high, loss_at_inner_high = inner_high, inner_low, loss_at_inner_low
            inner_low = high - golden_ratio_part * (high - low)
            loss_at_inner_low = loss_at(inner_low)
        else:
            low, inner_low, loss_at_inner_low = inner_low, inner_high, loss_at_inner_high
            inner_high = low + golden_ratio_part * (high - low)
            loss_at_inner_high = loss_at(inner_high)
    return 1.0 / ((low + high) / 2)


def threshold_values(threshold_step: float) -> list[float]:
    """0, step, 2 × step, … below 1, rounded so 0.07 is 0.07 and not 0.07000000000000001."""
    step_count = int(round(1.0 / threshold_step))
    return [round(step_number * threshold_step, 6) for step_number in range(step_count) if step_number * threshold_step < 1]


def answered_and_right(top_probabilities: np.ndarray, is_right: np.ndarray, least_probability: float) -> dict:
    """Share of clips answered (top probability ≥ `least_probability`) and the share right among those."""
    is_answered = top_probabilities >= least_probability
    answered_count = int(is_answered.sum())
    right_answered_count = int((is_answered & is_right).sum())
    return {
        "leastProbability": least_probability,
        "clips": int(len(top_probabilities)),
        "answered": answered_count,
        "answeredShare": answered_count / len(top_probabilities) if len(top_probabilities) else None,
        "rightWhenAnswered": right_answered_count / answered_count if answered_count else None,
    }


def threshold_table(top_probabilities: np.ndarray, is_right: np.ndarray, thresholds: list[float]) -> list[dict]:
    return [answered_and_right(top_probabilities, is_right, threshold) for threshold in thresholds]


def choose_threshold(table_rows: list[dict], wanted_right_when_answered: float) -> tuple[dict, bool]:
    """(row, reached): the lowest threshold whose answered clips are right at least `wanted_right_when_answered`
    of the time; else the row with the best share right (the lowest such threshold on a tie) and False."""
    for row in table_rows:
        if row["rightWhenAnswered"] is not None and row["rightWhenAnswered"] >= wanted_right_when_answered:
            return row, True
    rows_with_answers = [row for row in table_rows if row["rightWhenAnswered"] is not None]
    if not rows_with_answers:
        return table_rows[0], False
    best_share_right = max(row["rightWhenAnswered"] for row in rows_with_answers)
    best_row = next(row for row in rows_with_answers if row["rightWhenAnswered"] == best_share_right)
    return best_row, False


# ---- reading the model's scores ----------------------------------------------------------------------------------


@torch.no_grad()
def collect_scores(model, dataset: WordClipDataset, device: torch.device, batch_size: int, workers: int) -> tuple[np.ndarray, np.ndarray]:
    """(scores [N, words] float64, the dataset's word numbers [N])."""
    model.eval()
    loader = make_loader(dataset, batch_size, workers, shuffle=False, seed=0)
    all_scores = []
    all_word_numbers = []
    for batch in loader:
        features, frame_mask, word_numbers = move_to_device(batch, device)
        scores, description = model(features, frame_mask)
        all_scores.append(scores.float().cpu().numpy().astype(np.float64))
        all_word_numbers.append(word_numbers.cpu().numpy())
    if not all_scores:
        return np.zeros((0, 0)), np.zeros(0, dtype=np.int64)
    return np.concatenate(all_scores), np.concatenate(all_word_numbers)


def split_datasets(checkpoint: dict, sources, split_references) -> tuple[WordClipDataset, WordClipDataset]:
    """(clips of words the model has, clips of signs it was never taught) for one split."""
    labels = checkpoint["labels"]
    frame_count = int(checkpoint["frame_count"])
    known_dataset = WordClipDataset(sources, split_references, labels, None, checkpoint["seed"], frame_count)
    label_set = set(labels)
    untaught_references = [reference for reference in split_references if reference.label not in label_set]
    # The word dataset keeps only clips whose label is in its list, so it gets the untaught labels as its list;
    # those numbers are never compared with the model's.
    untaught_labels = sorted({reference.label for reference in untaught_references})
    untaught_dataset = WordClipDataset(sources, untaught_references, untaught_labels, None, checkpoint["seed"], frame_count)
    return known_dataset, untaught_dataset


# ---- the files ---------------------------------------------------------------------------------------------------


def calibration_path_for_checkpoint(checkpoint_path: str | Path) -> Path:
    checkpoint_path = Path(checkpoint_path)
    return checkpoint_path.with_name(checkpoint_path.stem + CALIBRATION_FILE_SUFFIX)


def weights_fingerprint(checkpoint: dict) -> str:
    """A short hash of the averaged weights the export uses, so a calibration is only ever used with them."""
    digest = hashlib.sha256()
    for name, value in sorted(checkpoint["ema_state"]["model"].items()):
        digest.update(name.encode("utf-8"))
        digest.update(value.detach().cpu().contiguous().numpy().tobytes())
    return digest.hexdigest()[:16]


def read_calibration_for_export(checkpoint_path: str | Path, checkpoint: dict, calibration_path: str | Path | None = None) -> dict | None:
    """The calibration made for this checkpoint, or None when there is none. A file made for other weights stops
    the export: exporting with a temperature that doesn't belong to the model would make every probability wrong."""
    if calibration_path is None:
        calibration_path = calibration_path_for_checkpoint(checkpoint_path)
        if not calibration_path.exists():
            return None
    calibration = json.loads(Path(calibration_path).read_text(encoding="utf-8"))
    if calibration.get("weightsFingerprint") != weights_fingerprint(checkpoint):
        raise SystemExit(
            f"{calibration_path} was made for other weights than {checkpoint_path}; run "
            f"`python -m signs.calibrate --checkpoint {checkpoint_path}` again"
        )
    return calibration


def write_reading_file(model_output_path: str | Path, calibration: dict) -> Path:
    """`<model name>.reading.json` next to the `.mlpackage`: what the app needs to say "unclear"."""
    model_output_path = Path(model_output_path)
    reading_path = model_output_path.with_name(model_output_path.stem + READING_FILE_SUFFIX)
    reading = {
        "leastWordProbability": calibration["leastWordProbability"],
        "rightWhenAnsweredOnValidation": calibration["rightWhenAnsweredOnValidation"],
        "answeredOnValidation": calibration["answeredOnValidation"],
        "temperature": calibration["temperature"],
    }
    if "leastWordProbabilityChosenFrom" in calibration:
        # the threshold came from held-out words (signs.unknown_signs apply): say so, with its numbers
        reading["leastWordProbabilityChosenFrom"] = calibration["leastWordProbabilityChosenFrom"]
    reading_path.write_text(json.dumps(reading, indent=1) + "\n", encoding="utf-8")
    return reading_path


# ---- the command -------------------------------------------------------------------------------------------------


def _percent(share) -> str:
    return "  -  " if share is None else f"{100 * share:5.1f}%"


def calibrate_checkpoint(
    checkpoint_path: str,
    wanted_right_when_answered: float = DEFAULT_RIGHT_WHEN_ANSWERED,
    threshold_step: float = DEFAULT_THRESHOLD_STEP,
    data_folders: list[str] | None = None,
    device_choice: str = "auto",
    batch_size: int = 128,
    workers: int = 0,
    landmark_source: str | None = None,
    table_every: int = 5,
    print_line=print,
) -> dict:
    """Does the whole job and writes the calibration file. Returns what it wrote."""
    checkpoint = load_checkpoint(checkpoint_path)
    if checkpoint["task"] not in CALIBRATED_TASK_NAMES:
        raise SystemExit(f"calibration is for word and letter models, not {checkpoint['task']!r} ones")
    device = pick_device(device_choice)
    if data_folders:
        data_folders = [str(Path(data_folder).resolve()) for data_folder in data_folders]
    else:
        data_folders = checkpoint["data_folders"]
    sources = load_sources(data_folders)
    sample_references = split_references_for_checkpoint(checkpoint, sources)
    if landmark_source:
        sample_references = [
            reference
            for reference in sample_references
            if sources[reference.source_number].clip_records[reference.clip_number].source == landmark_source
        ]
    model = load_evaluation_model(checkpoint).to(device)

    validation_known, validation_untaught = split_datasets(
        checkpoint, sources, references_in_split(sample_references, VALIDATION_SPLIT)
    )
    validation_scores, validation_word_numbers = collect_scores(model, validation_known, device, batch_size, workers)
    if len(validation_word_numbers) == 0:
        raise SystemExit("no validation clips of the model's words: nothing to calibrate on")

    temperature = fit_temperature(validation_scores, validation_word_numbers)
    print_line(
        f"temperature {temperature:.4f} (validation negative log likelihood "
        f"{negative_log_likelihood(validation_scores, validation_word_numbers, 1.0):.4f} -> "
        f"{negative_log_likelihood(validation_scores, validation_word_numbers, temperature):.4f}, "
        f"{len(validation_word_numbers)} clips)"
    )
    if not SMALLEST_INVERSE_TEMPERATURE * 1.01 < 1.0 / temperature < LARGEST_INVERSE_TEMPERATURE * 0.99:
        print_line("  (the temperature is at the edge of what is searched, 0.05 to 20: the scores are far from probabilities; check the training)")
    validation_probabilities = softmax_with_temperature(validation_scores, temperature)
    validation_top = validation_probabilities.max(axis=1)
    validation_is_right = validation_probabilities.argmax(axis=1) == validation_word_numbers
    table_rows = threshold_table(validation_top, validation_is_right, threshold_values(threshold_step))
    chosen_row, reached = choose_threshold(table_rows, wanted_right_when_answered)

    print_line("")
    print_line("least probability  answered  right when answered   (validation signers)")
    for row_number, row in enumerate(table_rows):
        if row_number % table_every != 0 and row is not chosen_row:
            continue
        marker = "   <- chosen" if row is chosen_row else ""
        print_line(
            f"      {row['leastProbability']:.2f}         {_percent(row['answeredShare'])}     "
            f"{_percent(row['rightWhenAnswered'])}{marker}"
        )
    print_line("")
    if reached:
        print_line(
            f"answer only at {chosen_row['leastProbability']:.2f} or more: on validation it then answers "
            f"{_percent(chosen_row['answeredShare']).strip()} of clips and is right on "
            f"{_percent(chosen_row['rightWhenAnswered']).strip()} of those (wanted {100 * wanted_right_when_answered:.0f}%)"
        )
    else:
        print_line(
            f"CAN'T REACH {100 * wanted_right_when_answered:.0f}% right when answered on validation at any threshold. "
            f"The best is {_percent(chosen_row['rightWhenAnswered']).strip()} at {chosen_row['leastProbability']:.2f}, "
            f"answering {_percent(chosen_row['answeredShare']).strip()} of clips; that is what is saved."
        )

    least_probability = chosen_row["leastProbability"]
    untaught_results = {}
    validation_untaught_scores, unused_numbers = collect_scores(model, validation_untaught, device, batch_size, workers)
    if len(validation_untaught_scores):
        untaught_results[VALIDATION_SPLIT] = _untaught_answered(validation_untaught_scores, temperature, least_probability)

    # The test signers are read only here, for the final two numbers at the chosen threshold.
    test_known, test_untaught = split_datasets(checkpoint, sources, references_in_split(sample_references, TEST_SPLIT))
    test_scores, test_word_numbers = collect_scores(model, test_known, device, batch_size, workers)
    test_results = None
    if len(test_word_numbers):
        test_probabilities = softmax_with_temperature(test_scores, temperature)
        test_results = answered_and_right(
            test_probabilities.max(axis=1), test_probabilities.argmax(axis=1) == test_word_numbers, least_probability
        )
        print_line(
            f"test signers at {least_probability:.2f}: answers {_percent(test_results['answeredShare']).strip()} of "
            f"{test_results['clips']} clips, right on {_percent(test_results['rightWhenAnswered']).strip()} of those"
        )
    else:
        print_line("test signers: no clips of the model's words")
    test_untaught_scores, unused_numbers = collect_scores(model, test_untaught, device, batch_size, workers)
    if len(test_untaught_scores):
        untaught_results[TEST_SPLIT] = _untaught_answered(test_untaught_scores, temperature, least_probability)
    for split_name, untaught in untaught_results.items():
        split_words = "validation" if split_name == VALIDATION_SPLIT else "test"
        print_line(
            f"signs it was never taught ({split_words} signers): it would wrongly answer {untaught['answered']} of "
            f"{untaught['clips']} clips ({_percent(untaught['answeredShare']).strip()}) at {least_probability:.2f}"
        )

    calibration = {
        "task": checkpoint["task"],
        "checkpoint": str(checkpoint_path),
        "epoch": checkpoint["epoch"],
        "weightsFingerprint": weights_fingerprint(checkpoint),
        "landmarkSource": landmark_source or "all",
        "temperature": temperature,
        "leastWordProbability": least_probability,
        "rightWhenAnsweredOnValidation": chosen_row["rightWhenAnswered"],
        "answeredOnValidation": chosen_row["answeredShare"],
        "wantedRightWhenAnswered": wanted_right_when_answered,
        "reached": reached,
        "validationClips": int(len(validation_word_numbers)),
        "validationTable": table_rows,
        "test": test_results,
        "untaughtSigns": untaught_results,
    }
    calibration_path = calibration_path_for_checkpoint(checkpoint_path)
    calibration_path.write_text(json.dumps(calibration, indent=1) + "\n", encoding="utf-8")
    print_line(f"wrote {calibration_path}; signs.export_coreml reads it next to the checkpoint")
    return calibration


def _untaught_answered(scores: np.ndarray, temperature: float, least_probability: float) -> dict:
    top_probabilities = softmax_with_temperature(scores, temperature).max(axis=1)
    answered_count = int((top_probabilities >= least_probability).sum())
    return {"clips": int(len(top_probabilities)), "answered": answered_count, "answeredShare": answered_count / len(top_probabilities)}


def main(argument_list=None) -> None:
    argument_parser = argparse.ArgumentParser(
        description=(
            "Make a word (or still-letter) model's confidence honest. Fits a temperature on the validation signers, "
            "then finds the least top probability at which answered clips are right often enough, so the app says "
            "'unclear' below it instead of a wrong word. Prints the validation table, the test signers' numbers at "
            "the chosen value, and how often signs the model was never taught would be answered. Writes "
            "<checkpoint>.calibration.json, which signs.export_coreml then bakes into the model (scores divided by "
            "the temperature) and turns into <model name>.reading.json."
        )
    )
    argument_parser.add_argument("--checkpoint", required=True, help="a words or letters checkpoint")
    argument_parser.add_argument(
        "--right-when-answered", type=float, default=DEFAULT_RIGHT_WHEN_ANSWERED,
        help="the share of answered clips that must be right (default %(default)s)",
    )
    argument_parser.add_argument(
        "--threshold-step", type=float, default=DEFAULT_THRESHOLD_STEP,
        help="the least-probability values tried are 0, this, twice this, ... below 1 (default %(default)s)",
    )
    argument_parser.add_argument("--data", nargs="+", default=None, help="dataset folders, if they moved since training")
    argument_parser.add_argument(
        "--source", choices=("apple", "mediapipe"), default=None,
        help="only clips whose landmarks came from this; use apple when there are enough, since the app's are",
    )
    argument_parser.add_argument("--device", choices=DEVICE_CHOICES, default="auto")
    argument_parser.add_argument("--batch-size", type=int, default=128)
    argument_parser.add_argument("--workers", type=int, default=default_worker_count())
    parsed_arguments = argument_parser.parse_args(argument_list)
    if not 0 < parsed_arguments.right_when_answered <= 1:
        argument_parser.error("--right-when-answered must be above 0 and at most 1")
    if not 0 < parsed_arguments.threshold_step < 1:
        argument_parser.error("--threshold-step must be between 0 and 1")
    calibrate_checkpoint(
        parsed_arguments.checkpoint,
        parsed_arguments.right_when_answered,
        parsed_arguments.threshold_step,
        parsed_arguments.data,
        parsed_arguments.device,
        parsed_arguments.batch_size,
        parsed_arguments.workers,
        parsed_arguments.source,
    )


if __name__ == "__main__":
    main()
