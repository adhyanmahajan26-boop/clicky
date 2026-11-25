"""Saying "not sure" about signs the model was never taught: the experiment that decides how word models do it.

A real signer makes many signs outside the word list, so a word model must not answer all of them with some word it
knows. Three rules are compared on held-out words (never in training, so the test is honest):

- top probability: answer only when the calibrated top probability is at least a threshold (what calibrate.py does);
- "not a sign I know": the same, with one extra class trained on clips that are not words of the list (other sign
  languages' signs, hands moving without signing); that class winning counts as not answered;
- distance: answer only when the clip's description vector (the model's second output) is near the centre of some
  taught word's training clips (cosine distance to the nearest centre at most a threshold).

    # 1. INCLUDE with 26 words held out (their train and validation clips dropped, their test clips kept as never taught)
    python -m signs.unknown_signs holdout --data /data/include --output /data/include-holdout --count 26 --seed 0
    # 2. clips that are not words of the list, for model B's extra class
    python -m signs.unknown_signs not-a-sign --output /data/not-a-sign --language isl --popsign /data/popsign \\
        --nonsigning /data/fsboard-nonsigning --per-sign 4
    # 3. train (train_words) and calibrate (calibrate) as usual, then
    python -m signs.unknown_signs table --checkpoint runs/a/checkpoint-best.pt --heldout /data/include-holdout/heldout.json
    python -m signs.unknown_signs table --checkpoint runs/b/checkpoint-best.pt --heldout /data/include-holdout/heldout.json \\
        --not-a-sign-label "not a sign"

Thresholds are chosen on the taught validation clips (to answer 90% of them); the test clips, taught and never
taught, are only read to print the numbers.

**How a word model's "not sure" threshold is chosen** (the rule since round 6: top probability, threshold from
held-out words). `folds` holds out three different seeded tenths of the words, trains and calibrates one model per
fold, pools the three folds' test clips and picks the lowest threshold at which never-taught signs are wrongly
answered at most `--most-wrongly-answered` of the time (default 0.10); `apply` writes it, with the numbers it was
chosen from, into the full model's calibration file, which `export_coreml` turns into `.reading.json`:

    python -m signs.unknown_signs folds --data /data/include --language isl --output runs/include-folds
    python -m signs.calibrate --checkpoint runs/words-isl/checkpoint-best.pt --source apple
    python -m signs.unknown_signs apply --checkpoint runs/words-isl/checkpoint-best.pt --folds runs/include-folds/folds.json
    python -m signs.export_coreml --checkpoint runs/words-isl/checkpoint-best.pt --output out/SignWordsISL.mlpackage
"""

from __future__ import annotations

import argparse
import csv
import json
import os
import random
from collections import defaultdict
from pathlib import Path

import numpy as np

NOT_A_SIGN_LABEL = "not a sign"
MANIFEST_COLUMNS = ["clip_id", "dataset", "language", "label", "signer", "split", "fps", "width", "height", "frames", "source"]
PROBABILITY_THRESHOLDS = [round(step * 0.05, 2) for step in range(20)]
TAUGHT_SHARE_TO_ANSWER = 0.90


# ---- the numbers (pure, tested) ------------------------------------------------------------------------------------


def answer_table_row(
    answered: np.ndarray, right: np.ndarray, is_taught: np.ndarray
) -> dict:
    """For one rule at one threshold: share of taught clips answered, share right among those answered, and share of
    never-taught clips answered (each of those is a wrong answer, since no taught word is right for them)."""
    answered = np.asarray(answered, dtype=bool)
    right = np.asarray(right, dtype=bool)
    is_taught = np.asarray(is_taught, dtype=bool)
    taught_answered = answered & is_taught
    taught_count = int(is_taught.sum())
    never_taught_count = int((~is_taught).sum())
    return {
        "taught_answered": float(taught_answered.sum() / taught_count) if taught_count else float("nan"),
        "taught_right_when_answered": float((taught_answered & right).sum() / taught_answered.sum()) if taught_answered.any() else float("nan"),
        "taught_right_overall": float((taught_answered & right).sum() / taught_count) if taught_count else float("nan"),
        "never_taught_wrongly_answered": float((answered & ~is_taught).sum() / never_taught_count) if never_taught_count else float("nan"),
    }


def probability_rule(probabilities: np.ndarray, threshold: float, reject_class: int | None = None) -> tuple[np.ndarray, np.ndarray]:
    """(answered, answer index): the top class when its probability is at least the threshold and it isn't the
    "not a sign I know" class."""
    top_class = probabilities.argmax(axis=1)
    top_probability = probabilities.max(axis=1)
    answered = top_probability >= threshold
    if reject_class is not None:
        answered &= top_class != reject_class
    return answered, top_class


def class_centres(descriptions: np.ndarray, class_numbers: np.ndarray, class_count: int) -> np.ndarray:
    """Each class's centre: the mean of its training clips' unit-length descriptions, made unit length again. A class
    with no clips gets a zero centre (never nearest)."""
    unit_descriptions = descriptions / np.maximum(np.linalg.norm(descriptions, axis=1, keepdims=True), 1e-12)
    centres = np.zeros((class_count, descriptions.shape[1]), dtype=np.float64)
    for class_number in range(class_count):
        members = unit_descriptions[class_numbers == class_number]
        if len(members):
            centre = members.mean(axis=0)
            centres[class_number] = centre / max(np.linalg.norm(centre), 1e-12)
    return centres


def nearest_centre_distances(descriptions: np.ndarray, centres: np.ndarray) -> np.ndarray:
    """Cosine distance (1 − cosine similarity) from each description to the nearest class centre."""
    unit_descriptions = descriptions / np.maximum(np.linalg.norm(descriptions, axis=1, keepdims=True), 1e-12)
    similarities = unit_descriptions @ centres.T
    return 1.0 - similarities.max(axis=1)


def threshold_for_answered_share(values_of_taught_validation: np.ndarray, share: float, answer_when_low: bool) -> float:
    """The threshold at which `share` of the taught validation clips are answered. For a probability (answered when
    high) it is the (1 − share) quantile; for a distance (answered when low) the `share` quantile."""
    values = np.sort(np.asarray(values_of_taught_validation, dtype=np.float64))
    if len(values) == 0:
        return 0.0
    quantile = share if answer_when_low else 1.0 - share
    return float(np.quantile(values, quantile, method="lower" if not answer_when_low else "higher"))


# ---- making the datasets ---------------------------------------------------------------------------------------------


def _read_manifest_rows(folder: Path) -> list[dict]:
    with open(folder / "manifest.csv", newline="") as manifest_file:
        return list(csv.DictReader(manifest_file))


def _write_manifest_rows(folder: Path, rows: list[dict]) -> None:
    with open(folder / "manifest.csv", "w", newline="") as manifest_file:
        writer = csv.DictWriter(manifest_file, fieldnames=MANIFEST_COLUMNS)
        writer.writeheader()
        for row in rows:
            writer.writerow({column: row.get(column, "") for column in MANIFEST_COLUMNS})


def _link_clip(source_folder: Path, output_folder: Path, clip_id: str, new_clip_id: str | None = None) -> None:
    target = output_folder / f"{new_clip_id or clip_id}.npy"
    if not target.exists():
        os.link(source_folder / f"{clip_id}.npy", target)


def choose_held_out_words(words: list[str], count: int, seed: int) -> list[str]:
    return sorted(random.Random(seed).sample(sorted(words), count))


def make_holdout_dataset(source_folder, output_folder, count: int, seed: int, min_test_clips: int = 1) -> list[str]:
    """Copies a dataset (hard links) with `count` words held out: their train and validation clips are dropped and
    their test clips kept (they are the never-taught test). Held out only among words that have test clips. Writes
    heldout.json and returns the held-out words."""
    source_folder, output_folder = Path(source_folder), Path(output_folder)
    output_folder.mkdir(parents=True, exist_ok=True)
    rows = _read_manifest_rows(source_folder)
    test_clips_per_word = defaultdict(int)
    for row in rows:
        if row["split"] == "test":
            test_clips_per_word[row["label"]] += 1
    candidates = [word for word, test_count in test_clips_per_word.items() if test_count >= min_test_clips]
    held_out = choose_held_out_words(candidates, count, seed)
    held_out_set = set(held_out)
    kept_rows = [row for row in rows if row["label"] not in held_out_set or row["split"] == "test"]
    for row in kept_rows:
        _link_clip(source_folder, output_folder, row["clip_id"])
    _write_manifest_rows(output_folder, kept_rows)
    (output_folder / "heldout.json").write_text(json.dumps({"words": held_out, "seed": seed, "source": str(source_folder)}, indent=1))
    return held_out


def make_not_a_sign_dataset(
    output_folder,
    language: str,
    label: str = NOT_A_SIGN_LABEL,
    other_sign_folders: list[str] = (),
    nonsigning_folders: list[str] = (),
    per_sign: int = 4,
    validation_fraction: float = 0.15,
    seed: int = 0,
) -> dict:
    """Clips that are not words of the list, all labelled `label` in `language`: up to `per_sign` clips of each sign of
    other sign-language datasets (spread over signs and signers), and every clip of the non-signing folders (hands
    moving without signing). Each clip goes to train or validation (never test: the test is the word dataset's own)."""
    output_folder = Path(output_folder)
    output_folder.mkdir(parents=True, exist_ok=True)
    generator = random.Random(seed)
    rows = []
    for folder in other_sign_folders:
        folder = Path(folder)
        clips_by_sign = defaultdict(list)
        for row in _read_manifest_rows(folder):
            if (folder / f"{row['clip_id']}.npy").exists():
                clips_by_sign[row["label"]].append(row)
        for sign in sorted(clips_by_sign):
            sign_rows = sorted(clips_by_sign[sign], key=lambda row: row["clip_id"])
            generator.shuffle(sign_rows)
            # one clip of each signer first, so a sign's few clips come from different people
            by_signer = defaultdict(list)
            for row in sign_rows:
                by_signer[row["signer"]].append(row)
            spread = []
            while len(spread) < per_sign and any(by_signer.values()):
                for signer in sorted(by_signer):
                    if by_signer[signer] and len(spread) < per_sign:
                        spread.append(by_signer[signer].pop(0))
            for row in spread:
                rows.append((folder, row))
    for folder in nonsigning_folders:
        folder = Path(folder)
        for row in _read_manifest_rows(folder):
            if (folder / f"{row['clip_id']}.npy").exists():
                rows.append((folder, row))
    written = []
    for folder, row in rows:
        new_clip_id = f"not-a-sign-{row['clip_id']}"
        _link_clip(folder, output_folder, row["clip_id"], new_clip_id)
        written.append({**row, "clip_id": new_clip_id, "dataset": "not-a-sign", "language": language, "label": label,
                        "signer": f"{row.get('dataset', '')}:{row.get('signer', '')}",
                        "split": "val" if generator.random() < validation_fraction else "train"})
    _write_manifest_rows(output_folder, written)
    return {"clips": len(written), "train": sum(row["split"] == "train" for row in written), "val": sum(row["split"] == "val" for row in written)}


# ---- scoring a checkpoint -----------------------------------------------------------------------------------------


def _scores_and_descriptions(model, dataset, device, batch_size: int = 128):
    import torch

    from .training import make_loader, move_to_device

    scores, descriptions = [], []
    with torch.no_grad():
        for batch in make_loader(dataset, batch_size, 0, shuffle=False, seed=0):
            features, mask, _ = move_to_device(batch, device)
            batch_scores, batch_descriptions = model(features, mask)
            scores.append(batch_scores.float().cpu().numpy())
            descriptions.append(batch_descriptions.float().cpu().numpy())
    return np.concatenate(scores), np.concatenate(descriptions)


def unknown_sign_tables(checkpoint_path: str, held_out_words: list[str], not_a_sign_label: str | None = None, device_choice: str = "auto") -> dict:
    from .calibrate import CALIBRATION_FILE_SUFFIX, softmax_with_temperature
    from .data import WordClipDataset, assign_splits, load_sources, references_in_split
    from .evaluate import load_evaluation_model
    from .splits import TEST_SPLIT, TRAIN_SPLIT, VALIDATION_SPLIT
    from .training import load_checkpoint, pick_device

    checkpoint = load_checkpoint(checkpoint_path)
    labels = list(checkpoint["labels"])
    calibration_path = Path(str(checkpoint_path).removesuffix(".pt") + CALIBRATION_FILE_SUFFIX)
    temperature = json.loads(calibration_path.read_text())["temperature"] if calibration_path.exists() else 1.0
    device = pick_device(device_choice)
    model = load_evaluation_model(checkpoint).to(device)
    sources = load_sources(checkpoint["data_folders"])
    references, _ = assign_splits(sources, checkpoint["seed"], saved_signer_splits=checkpoint["signer_splits"], language=checkpoint["language"])
    held_out_set = set(held_out_words)
    reject_class = labels.index(not_a_sign_label) if not_a_sign_label and not_a_sign_label in labels else None
    # Every clip's label must be in the dataset's list to be made into features; held-out words get their own numbers
    # after the model's, which the model never outputs.
    feature_labels = labels + sorted(held_out_set - set(labels))

    def clips(split, keep):
        chosen = [reference for reference in references_in_split(references, split) if keep(reference.label)]
        dataset = WordClipDataset(sources, chosen, feature_labels, None, checkpoint["seed"], checkpoint["frame_count"])
        scores, descriptions = _scores_and_descriptions(model, dataset, device)
        true_numbers = np.array([feature_labels.index(reference.label) for reference in dataset.sample_references])
        return softmax_with_temperature(scores, temperature), descriptions, true_numbers

    is_taught_word = lambda label: label in labels and label != not_a_sign_label
    train_probabilities, train_descriptions, train_numbers = clips(TRAIN_SPLIT, is_taught_word)
    validation_probabilities, validation_descriptions, validation_numbers = clips(VALIDATION_SPLIT, is_taught_word)
    test_probabilities, test_descriptions, test_numbers = clips(TEST_SPLIT, lambda label: is_taught_word(label) or label in held_out_set)
    test_is_taught = np.array([number < len(labels) for number in test_numbers])

    tables = {"checkpoint": str(checkpoint_path), "temperature": temperature, "taught_words": len(labels) - (reject_class is not None),
              "held_out_words": len(held_out_set), "test_taught_clips": int(test_is_taught.sum()),
              "test_never_taught_clips": int((~test_is_taught).sum()), "rules": {}}

    probability_rows = []
    for threshold in PROBABILITY_THRESHOLDS:
        answered, answers = probability_rule(test_probabilities, threshold, reject_class)
        probability_rows.append({"threshold": threshold, **answer_table_row(answered, answers == test_numbers, test_is_taught)})
    validation_top = validation_probabilities.max(axis=1)
    if reject_class is not None:
        # a validation clip where "not a sign" wins counts as not answered at any threshold
        validation_top = np.where(validation_probabilities.argmax(axis=1) == reject_class, -1.0, validation_top)
    chosen_threshold = threshold_for_answered_share(validation_top, TAUGHT_SHARE_TO_ANSWER, answer_when_low=False)
    answered, answers = probability_rule(test_probabilities, chosen_threshold, reject_class)
    tables["rules"]["top probability" + (" + not a sign" if reject_class is not None else "")] = {
        "rows": probability_rows,
        "at_90_percent_of_taught_validation": {"threshold": chosen_threshold, **answer_table_row(answered, answers == test_numbers, test_is_taught)},
    }

    centres = class_centres(train_descriptions, train_numbers, len(labels))
    if reject_class is not None:
        centres[reject_class] = 0.0
    validation_distances = nearest_centre_distances(validation_descriptions, centres)
    test_distances = nearest_centre_distances(test_descriptions, centres)
    test_answers = test_probabilities.argmax(axis=1)
    distance_rows = []
    for share in (1.0, 0.98, 0.95, 0.9, 0.85, 0.8, 0.7, 0.6, 0.5):
        threshold = threshold_for_answered_share(validation_distances, share, answer_when_low=True)
        answered = test_distances <= threshold
        distance_rows.append({"taught_validation_share": share, "threshold": threshold,
                              **answer_table_row(answered, test_answers == test_numbers, test_is_taught)})
    tables["rules"]["distance to nearest word centre"] = {
        "rows": distance_rows,
        "at_90_percent_of_taught_validation": next(row for row in distance_rows if row["taught_validation_share"] == 0.9),
    }
    return tables


# ---- the threshold from held-out words ---------------------------------------------------------------------------


def held_out_word_folds(words: list[str], fold_count: int, fraction: float, seed: int) -> list[list[str]]:
    """`fold_count` disjoint sets of `fraction` of the words each, seeded."""
    shuffled = sorted(words)
    random.Random(seed).shuffle(shuffled)
    per_fold = max(1, round(len(shuffled) * fraction))
    if per_fold * fold_count > len(shuffled):
        raise ValueError(f"{fold_count} folds of {per_fold} words need more than {len(shuffled)} words")
    return [sorted(shuffled[fold * per_fold : (fold + 1) * per_fold]) for fold in range(fold_count)]


def pooled_threshold_table(fold_results: list[dict], thresholds: list[float]) -> list[dict]:
    """Each fold's test clips carry `top_probability`, `right` and `taught`; the rows are over all folds pooled."""
    top = np.concatenate([np.asarray(result["top_probability"], dtype=np.float64) for result in fold_results])
    right = np.concatenate([np.asarray(result["right"], dtype=bool) for result in fold_results])
    taught = np.concatenate([np.asarray(result["taught"], dtype=bool) for result in fold_results])
    return [{"threshold": threshold, **answer_table_row(top >= threshold, right, taught)} for threshold in thresholds]


def lowest_threshold_with_few_wrong_answers(rows: list[dict], most_wrongly_answered: float) -> dict:
    """The first row (rows are in rising threshold order) whose never-taught share answered is at most the limit; the
    last row when none gets there."""
    for row in rows:
        if row["never_taught_wrongly_answered"] <= most_wrongly_answered:
            return {**row, "reached": True}
    return {**rows[-1], "reached": False}


def fold_test_results(checkpoint_path: str, held_out_words: list[str], device_choice: str = "auto") -> dict:
    """For one fold's calibrated model: each test clip's calibrated top probability, whether that top word is right,
    and whether its word was taught."""
    from .calibrate import CALIBRATION_FILE_SUFFIX, softmax_with_temperature
    from .data import WordClipDataset, assign_splits, load_sources, references_in_split
    from .evaluate import load_evaluation_model
    from .splits import TEST_SPLIT
    from .training import load_checkpoint, pick_device

    checkpoint = load_checkpoint(checkpoint_path)
    labels = list(checkpoint["labels"])
    calibration_path = Path(str(checkpoint_path).removesuffix(".pt") + CALIBRATION_FILE_SUFFIX)
    temperature = json.loads(calibration_path.read_text())["temperature"]
    device = pick_device(device_choice)
    model = load_evaluation_model(checkpoint).to(device)
    sources = load_sources(checkpoint["data_folders"])
    references, _ = assign_splits(sources, checkpoint["seed"], saved_signer_splits=checkpoint["signer_splits"], language=checkpoint["language"])
    held_out_set = set(held_out_words)
    feature_labels = labels + sorted(held_out_set - set(labels))
    chosen = [reference for reference in references_in_split(references, TEST_SPLIT) if reference.label in labels or reference.label in held_out_set]
    dataset = WordClipDataset(sources, chosen, feature_labels, None, checkpoint["seed"], checkpoint["frame_count"])
    scores, _ = _scores_and_descriptions(model, dataset, device)
    probabilities = softmax_with_temperature(scores, temperature)
    true_numbers = np.array([feature_labels.index(reference.label) for reference in dataset.sample_references])
    return {
        "checkpoint": str(checkpoint_path),
        "temperature": temperature,
        "held_out_words": sorted(held_out_set),
        "top_probability": probabilities.max(axis=1).tolist(),
        "right": (probabilities.argmax(axis=1) == true_numbers).tolist(),
        "taught": (true_numbers < len(labels)).tolist(),
    }


def run_folds(data_folder, language: str, output_folder, fold_count: int = 3, fraction: float = 0.1, seed: int = 0,
              epochs: int = 120, most_wrongly_answered: float = 0.10, device_choice: str = "auto",
              person_changes: str = "") -> dict:
    """Builds the held-out datasets, trains and calibrates one model per fold (skipping any already trained), pools the
    folds and picks the threshold. Writes and returns `<output>/folds.json`. `person_changes`: the same
    `--person-changes` the full model trains with, so the threshold comes from models trained the same way."""
    from . import calibrate, train_words
    from .landmarks import pack

    output_folder = Path(output_folder)
    output_folder.mkdir(parents=True, exist_ok=True)
    words = sorted({row["label"] for row in _read_manifest_rows(Path(data_folder)) if row["language"] == language})
    folds = held_out_word_folds(words, fold_count, fraction, seed)
    fold_results = []
    for fold_number, held_out in enumerate(folds):
        fold_data = output_folder / f"fold{fold_number}-data"
        fold_run = output_folder / f"fold{fold_number}-run"
        if not (fold_data / "manifest.csv").exists():
            source_rows = _read_manifest_rows(Path(data_folder))
            held_out_set = set(held_out)
            fold_data.mkdir(parents=True, exist_ok=True)
            kept_rows = [row for row in source_rows if row["label"] not in held_out_set or row["split"] == "test"]
            for row in kept_rows:
                _link_clip(Path(data_folder), fold_data, row["clip_id"])
            _write_manifest_rows(fold_data, kept_rows)
            pack(fold_data)
        if not (fold_run / "checkpoint-best.pt").exists():
            train_words.main(["--data", str(fold_data), "--language", language, "--output", str(fold_run), "--epochs", str(epochs)]
                             + (["--person-changes", person_changes] if person_changes else []))
        calibrate.main(["--checkpoint", str(fold_run / "checkpoint-best.pt"), "--source", "apple"])
        fold_results.append(fold_test_results(str(fold_run / "checkpoint-best.pt"), held_out, device_choice))
    thresholds = [round(step * 0.01, 2) for step in range(100)]
    rows = pooled_threshold_table(fold_results, thresholds)
    chosen = lowest_threshold_with_few_wrong_answers(rows, most_wrongly_answered)
    result = {
        "data": str(data_folder), "language": language, "folds": fold_count, "fraction_held_out": fraction, "seed": seed,
        "held_out_words": folds, "most_wrongly_answered": most_wrongly_answered,
        "test_taught_clips": int(sum(sum(result["taught"]) for result in fold_results)),
        "test_never_taught_clips": int(sum(len(result["taught"]) - sum(result["taught"]) for result in fold_results)),
        "chosen": chosen, "rows": rows,
    }
    (output_folder / "folds.json").write_text(json.dumps(result, indent=1) + "\n")
    return result


def validation_answers_at(checkpoint_path: str, temperature: float, threshold: float, device_choice: str = "auto") -> tuple[float, float]:
    """Share of validation clips answered at `threshold`, and share right among those."""
    from .calibrate import softmax_with_temperature
    from .data import WordClipDataset, assign_splits, load_sources, references_in_split
    from .evaluate import load_evaluation_model
    from .splits import VALIDATION_SPLIT
    from .training import load_checkpoint, pick_device

    checkpoint = load_checkpoint(checkpoint_path)
    device = pick_device(device_choice)
    model = load_evaluation_model(checkpoint).to(device)
    sources = load_sources(checkpoint["data_folders"])
    references, _ = assign_splits(sources, checkpoint["seed"], saved_signer_splits=checkpoint["signer_splits"], language=checkpoint["language"])
    dataset = WordClipDataset(sources, references_in_split(references, VALIDATION_SPLIT), list(checkpoint["labels"]), None,
                              checkpoint["seed"], checkpoint["frame_count"])
    scores, _ = _scores_and_descriptions(model, dataset, device)
    probabilities = softmax_with_temperature(scores, temperature)
    true_numbers = np.array([dataset.word_number_by_word[reference.label] for reference in dataset.sample_references])
    answered = probabilities.max(axis=1) >= threshold
    right = probabilities.argmax(axis=1) == true_numbers
    return float(answered.mean()) if len(answered) else 0.0, float((answered & right).sum() / max(answered.sum(), 1))


def apply_threshold(checkpoint_path: str, folds_path: str) -> dict:
    """Puts the held-out-words threshold into the full model's calibration file (made by `signs.calibrate`, whose
    temperature stays), with the numbers it was chosen from; `export_coreml` copies them into `.reading.json`."""
    from .calibrate import CALIBRATION_FILE_SUFFIX

    calibration_path = Path(str(checkpoint_path).removesuffix(".pt") + CALIBRATION_FILE_SUFFIX)
    calibration = json.loads(calibration_path.read_text())
    folds = json.loads(Path(folds_path).read_text())
    chosen = folds["chosen"]
    calibration["leastWordProbabilityFromValidation"] = calibration["leastWordProbability"]
    calibration["leastWordProbability"] = chosen["threshold"]
    # What the new threshold does on the full model's own validation signers (the old numbers were for the old one).
    answered_share, right_share = validation_answers_at(checkpoint_path, calibration["temperature"], chosen["threshold"])
    calibration["answeredOnValidation"] = answered_share
    calibration["rightWhenAnsweredOnValidation"] = right_share
    calibration["leastWordProbabilityChosenFrom"] = {
        "rule": f"lowest top-probability threshold where never-taught signs are wrongly answered at most {folds['most_wrongly_answered']:.0%} of the time",
        "folds": folds["folds"], "fractionHeldOut": folds["fraction_held_out"], "seed": folds["seed"],
        "testTaughtClips": folds["test_taught_clips"], "testNeverTaughtClips": folds["test_never_taught_clips"],
        "neverTaughtWronglyAnswered": chosen["never_taught_wrongly_answered"],
        "taughtAnswered": chosen["taught_answered"], "taughtRightWhenAnswered": chosen["taught_right_when_answered"],
        "reached": chosen["reached"],
    }
    calibration_path.write_text(json.dumps(calibration, indent=1) + "\n", encoding="utf-8")
    return calibration


def main(argument_list=None) -> None:
    parser = argparse.ArgumentParser(description="The never-taught-signs experiment (see the module notes).")
    commands = parser.add_subparsers(dest="command", required=True)
    holdout = commands.add_parser("holdout")
    holdout.add_argument("--data", required=True)
    holdout.add_argument("--output", required=True)
    holdout.add_argument("--count", type=int, default=26)
    holdout.add_argument("--seed", type=int, default=0)
    other = commands.add_parser("not-a-sign")
    other.add_argument("--output", required=True)
    other.add_argument("--language", required=True)
    other.add_argument("--label", default=NOT_A_SIGN_LABEL)
    other.add_argument("--popsign", nargs="*", default=[], help="datasets of other signs (any language)")
    other.add_argument("--nonsigning", nargs="*", default=[], help="datasets of hands moving without signing")
    other.add_argument("--per-sign", type=int, default=4)
    other.add_argument("--seed", type=int, default=0)
    table = commands.add_parser("table")
    table.add_argument("--checkpoint", required=True)
    table.add_argument("--heldout", required=True, help="heldout.json from the holdout command")
    table.add_argument("--not-a-sign-label", default=None)
    table.add_argument("--device", default="auto")
    folds = commands.add_parser("folds", help="the threshold from held-out words")
    folds.add_argument("--data", required=True)
    folds.add_argument("--language", required=True)
    folds.add_argument("--output", required=True)
    folds.add_argument("--folds", type=int, default=3)
    folds.add_argument("--fraction", type=float, default=0.1)
    folds.add_argument("--seed", type=int, default=0)
    folds.add_argument("--epochs", type=int, default=120)
    folds.add_argument("--most-wrongly-answered", type=float, default=0.10)
    folds.add_argument("--device", default="auto")
    folds.add_argument("--person-changes", default="", help="the same --person-changes the full model trains with")
    apply = commands.add_parser("apply", help="write the folds' threshold into a full model's calibration file")
    apply.add_argument("--checkpoint", required=True)
    apply.add_argument("--folds", required=True, help="folds.json from the folds command")
    arguments = parser.parse_args(argument_list)
    if arguments.command == "holdout":
        held_out = make_holdout_dataset(arguments.data, arguments.output, arguments.count, arguments.seed)
        print(f"held out {len(held_out)} words: {', '.join(held_out)}")
    elif arguments.command == "folds":
        result = run_folds(arguments.data, arguments.language, arguments.output, arguments.folds, arguments.fraction,
                           arguments.seed, arguments.epochs, arguments.most_wrongly_answered, arguments.device,
                           arguments.person_changes)
        print(f"{'threshold':>9}  {'taught answered':>15}  {'right when answered':>19}  {'never-taught answered':>21}")
        for row in result["rows"][::5]:
            print(f"{row['threshold']:9.2f}  {row['taught_answered']:15.1%}  {row['taught_right_when_answered']:19.1%}  {row['never_taught_wrongly_answered']:21.1%}")
        chosen = result["chosen"]
        print(f"chosen: {chosen['threshold']:.2f} ({'reached' if chosen['reached'] else 'NOT reached'} at most "
              f"{arguments.most_wrongly_answered:.0%} never-taught answered): taught answered {chosen['taught_answered']:.1%}, "
              f"right when answered {chosen['taught_right_when_answered']:.1%}, never-taught answered {chosen['never_taught_wrongly_answered']:.1%} "
              f"(pooled over {result['folds']} folds: {result['test_taught_clips']} taught, {result['test_never_taught_clips']} never-taught test clips)")
    elif arguments.command == "apply":
        calibration = apply_threshold(arguments.checkpoint, arguments.folds)
        print(f"leastWordProbability {calibration['leastWordProbabilityFromValidation']} -> {calibration['leastWordProbability']}")
    elif arguments.command == "not-a-sign":
        print(make_not_a_sign_dataset(arguments.output, arguments.language, arguments.label, arguments.popsign,
                                      arguments.nonsigning, arguments.per_sign, seed=arguments.seed))
    else:
        held_out = json.loads(Path(arguments.heldout).read_text())["words"]
        print(json.dumps(unknown_sign_tables(arguments.checkpoint, held_out, arguments.not_a_sign_label, arguments.device), indent=1))


if __name__ == "__main__":
    main()
