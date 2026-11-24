"""The never-taught-signs experiment: its numbers on made-up scores, and the held-out and not-a-sign datasets."""

import csv
import json

import numpy as np

from signs import unknown_signs
from signs.landmarks import empty_clip, write_clip


def test_a_table_row_counts_answers_rights_and_never_taught_answers():
    answered = np.array([True, True, False, True, False])
    right = np.array([True, False, False, False, False])
    is_taught = np.array([True, True, True, False, False])
    row = unknown_signs.answer_table_row(answered, right, is_taught)
    assert row["taught_answered"] == 2 / 3
    assert row["taught_right_when_answered"] == 0.5
    assert row["taught_right_overall"] == 1 / 3
    assert row["never_taught_wrongly_answered"] == 0.5


def test_the_probability_rule_never_answers_with_the_not_a_sign_class():
    probabilities = np.array([[0.7, 0.2, 0.1], [0.1, 0.1, 0.8], [0.4, 0.35, 0.25]])
    answered, answers = unknown_signs.probability_rule(probabilities, 0.5, reject_class=2)
    assert answered.tolist() == [True, False, False]
    assert answers.tolist() == [0, 2, 0]
    answered_without_reject, _ = unknown_signs.probability_rule(probabilities, 0.3)
    assert answered_without_reject.tolist() == [True, True, True]


def test_distances_are_to_the_nearest_class_centre():
    descriptions = np.array([[1.0, 0.0], [2.0, 0.1], [0.0, 1.0], [0.1, 3.0]])
    centres = unknown_signs.class_centres(descriptions, np.array([0, 0, 1, 1]), 3)
    assert np.allclose(np.linalg.norm(centres[:2], axis=1), 1)
    assert np.allclose(centres[2], 0)  # a class with no clips is never nearest
    distances = unknown_signs.nearest_centre_distances(np.array([[1.0, 0.02], [1.0, 1.0]]), centres)
    assert distances[0] < 0.01
    assert abs(distances[1] - (1 - np.cos(np.pi / 4))) < 0.05


def test_thresholds_answer_the_asked_share_of_taught_validation():
    probabilities = np.linspace(0.05, 1.0, 20)
    threshold = unknown_signs.threshold_for_answered_share(probabilities, 0.9, answer_when_low=False)
    assert (probabilities >= threshold).mean() >= 0.9
    distances = np.linspace(0.0, 0.95, 20)
    threshold = unknown_signs.threshold_for_answered_share(distances, 0.9, answer_when_low=True)
    assert (distances <= threshold).mean() >= 0.9


def _write_dataset(folder, rows):
    folder.mkdir(parents=True, exist_ok=True)
    with open(folder / "manifest.csv", "w", newline="") as manifest_file:
        writer = csv.DictWriter(manifest_file, fieldnames=unknown_signs.MANIFEST_COLUMNS)
        writer.writeheader()
        for row in rows:
            writer.writerow(row)
            write_clip(folder / f"{row['clip_id']}.npy", empty_clip(int(row["frames"])))


def _row(clip_id, label, split, signer="", dataset="include", language="isl"):
    return {"clip_id": clip_id, "dataset": dataset, "language": language, "label": label, "signer": signer, "split": split,
            "fps": 25, "width": 1920, "height": 1080, "frames": 4, "source": "apple"}


def test_held_out_words_keep_only_their_test_clips(tmp_path):
    rows = []
    for word in ("cat", "dog", "fish", "bird"):
        rows += [_row(f"{word}-{split}", word, split) for split in ("train", "val", "test")]
    _write_dataset(tmp_path / "include", rows)
    held_out = unknown_signs.make_holdout_dataset(tmp_path / "include", tmp_path / "holdout", count=2, seed=3)
    assert len(held_out) == 2
    assert held_out == unknown_signs.make_holdout_dataset(tmp_path / "include", tmp_path / "holdout-again", count=2, seed=3)
    with open(tmp_path / "holdout" / "manifest.csv") as manifest_file:
        kept = list(csv.DictReader(manifest_file))
    for row in kept:
        assert row["label"] not in held_out or row["split"] == "test"
        assert (tmp_path / "holdout" / f"{row['clip_id']}.npy").exists()
    assert len(kept) == 4 * 3 - 2 * 2
    assert json.loads((tmp_path / "holdout" / "heldout.json").read_text())["words"] == held_out


def test_not_a_sign_clips_are_spread_over_signs_and_never_in_test(tmp_path):
    other_rows = [_row(f"ps-{sign}-{signer}-{take}", sign, "train", signer=signer, dataset="popsign", language="asl")
                  for sign in ("hello", "thankyou") for signer in ("a", "b", "c") for take in range(3)]
    _write_dataset(tmp_path / "popsign", other_rows)
    _write_dataset(tmp_path / "nonsigning", [_row(f"lead-{number}", "zzz", "test", dataset="fsboard-nonsigning") for number in range(5)])
    counts = unknown_signs.make_not_a_sign_dataset(tmp_path / "not-a-sign", "isl", other_sign_folders=[tmp_path / "popsign"],
                                                    nonsigning_folders=[tmp_path / "nonsigning"], per_sign=3, seed=1)
    assert counts["clips"] == 2 * 3 + 5
    with open(tmp_path / "not-a-sign" / "manifest.csv") as manifest_file:
        written = list(csv.DictReader(manifest_file))
    assert {row["label"] for row in written} == {unknown_signs.NOT_A_SIGN_LABEL}
    assert {row["language"] for row in written} == {"isl"}
    assert {row["split"] for row in written} <= {"train", "val"}
    hello_signers = {row["signer"] for row in written if "-hello-" in row["clip_id"]}
    assert len(hello_signers) == 3  # one clip of each signer before a second of any


def test_word_folds_are_disjoint_tenths():
    words = [f"w{number}" for number in range(40)]
    folds = unknown_signs.held_out_word_folds(words, 3, 0.1, seed=5)
    assert [len(fold) for fold in folds] == [4, 4, 4]
    assert len(set(folds[0]) | set(folds[1]) | set(folds[2])) == 12
    assert folds == unknown_signs.held_out_word_folds(words, 3, 0.1, seed=5)


def test_the_threshold_is_the_lowest_with_few_never_taught_answers():
    fold_results = [
        {"top_probability": [0.9, 0.8, 0.3, 0.6], "right": [True, True, False, False], "taught": [True, True, False, False]},
        {"top_probability": [0.95, 0.4], "right": [True, False], "taught": [True, False]},
    ]
    rows = unknown_signs.pooled_threshold_table(fold_results, [0.0, 0.35, 0.5, 0.7])
    assert [row["never_taught_wrongly_answered"] for row in rows] == [1.0, 2 / 3, 1 / 3, 0.0]
    chosen = unknown_signs.lowest_threshold_with_few_wrong_answers(rows, 0.10)
    assert chosen["threshold"] == 0.7 and chosen["reached"]
    assert chosen["taught_answered"] == 1.0
    never = unknown_signs.lowest_threshold_with_few_wrong_answers(rows[:2], 0.10)
    assert not never["reached"] and never["threshold"] == 0.35
