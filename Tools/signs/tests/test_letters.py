"""Still ISL letters (SignSpellISL): one frame in, a score per letter out."""

import json

import numpy as np
import pytest
import torch

from signs import calibrate, evaluate, train_letters
from signs.augment import augment_clip
from signs.export_coreml import trace_checkpoint
from signs.landmarks import LEFT_HAND_START, RIGHT_HAND_START, ClipRecord, empty_clip
from signs.letters import (
    SPLIT_BY_CLIP,
    SPLIT_BY_SIGNER,
    LetterModelSettings,
    SignLetterModel,
    assign_letter_splits,
    letter_augment_settings,
)
from signs.data import load_sources
from signs.make_golden import place_body, place_hand
from signs.training import load_checkpoint
from synthetic_signs import write_dataset

LETTERS = "abcd"
SMALL_ARGUMENTS = ["--hidden-width", "32", "--device", "cpu", "--batch-size", "16", "--warmup-epochs", "0.5", "--workers", "0"]


def letter_frame(letter: str, generator: np.random.Generator) -> np.ndarray:
    """One frame: each letter is its own hand tilt and place; b and d add the left hand (two-handed letters)."""
    letter_number = LETTERS.index(letter)
    clip = empty_clip(1)
    hand_size = generator.uniform(0.05, 0.07)
    place_body(clip, 0)
    wrist_place = (0.40 + 0.04 * letter_number, 0.55) + generator.normal(scale=0.004, size=2)
    place_hand(clip, 0, RIGHT_HAND_START, wrist_place, hand_size, tilt_degrees=-30 + 25 * letter_number)
    if letter_number % 2 == 1:
        place_hand(clip, 0, LEFT_HAND_START, (0.62, 0.6), hand_size)
    return clip


def make_letter_dataset(folder, signer_count: int, photos_per_letter: int, with_signers: bool, seed: int = 0):
    generator = np.random.default_rng(seed)
    clips_and_records = []
    for signer_number in range(signer_count):
        for letter in LETTERS:
            for photo_number in range(photos_per_letter):
                clip_id = f"letter-{signer_number}-{letter}-{photo_number}"
                signer = f"signer{signer_number}" if with_signers else ""
                clips_and_records.append(
                    (letter_frame(letter, generator),
                     ClipRecord(clip_id, "synthetic-letters", "isl", letter, signer, "", 0, 1280, 720, 1, "apple"))
                )
    return write_dataset(folder, clips_and_records)


def test_letter_model_reads_one_frame():
    model = SignLetterModel(LetterModelSettings(hidden_width=16), letter_count=26).eval()
    features = torch.randn(3, 1, 117)
    with torch.no_grad():
        scores, description = model(features, torch.ones(3, 1))
    assert scores.shape == (3, 26) and description.shape == (3, 16)


def test_letter_augmentation_keeps_one_frame():
    generator = np.random.default_rng(0)
    clip = letter_frame("b", generator)
    for repeat in range(20):
        augmented = augment_clip(clip, generator, letter_augment_settings(), 1280 / 720)
        assert augmented.shape == (1, 61, 3)
        # Both hands stay: losing one would make a different letter.
        assert augmented[0, RIGHT_HAND_START, 2] > 0 and augmented[0, LEFT_HAND_START, 2] > 0


def test_split_is_by_signer_when_named_else_by_clip(tmp_path):
    with_signers = make_letter_dataset(tmp_path / "named", signer_count=6, photos_per_letter=2, with_signers=True)
    without_signers = make_letter_dataset(tmp_path / "unnamed", signer_count=6, photos_per_letter=2, with_signers=False)
    sources = load_sources([str(with_signers), str(without_signers)])
    sample_references, split_plans = assign_letter_splits(sources, seed=3)
    assert [split_plan["kind"] for split_plan in split_plans] == [SPLIT_BY_SIGNER, SPLIT_BY_CLIP]
    named_splits = {}
    for reference in sample_references:
        if reference.source_number == 0:
            named_splits.setdefault(reference.signer, set()).add(reference.split)
        else:
            assert reference.signer == ""
    assert all(len(splits) == 1 for splits in named_splits.values())
    unnamed_splits = [reference.split for reference in sample_references if reference.source_number == 1]
    assert {"train", "val", "test"} <= set(unnamed_splits) and len(unnamed_splits) == 48
    # Saved plans give back exactly the same clips in the same splits.
    again, unused_plans = assign_letter_splits(sources, seed=99, saved_split_plans=split_plans)
    assert [(reference.source_number, reference.clip_number, reference.split) for reference in again] == [
        (reference.source_number, reference.clip_number, reference.split) for reference in sample_references
    ]


@pytest.fixture(scope="module")
def letter_run(tmp_path_factory):
    run_folder = tmp_path_factory.mktemp("letters-run")
    data_folder = make_letter_dataset(run_folder / "data", signer_count=6, photos_per_letter=3, with_signers=False)
    output_folder = run_folder / "out"
    train_letters.main(["--data", str(data_folder), "--output", str(output_folder), "--epochs", "3"] + SMALL_ARGUMENTS)
    return output_folder


def test_letter_training_writes_the_usual_run_folder(letter_run, capsys):
    log_entries = [json.loads(line) for line in (letter_run / "log.jsonl").read_text().splitlines()]
    assert [entry["epoch"] for entry in log_entries] == [0, 1, 2]
    assert "validation_top1" in log_entries[0]
    checkpoint = load_checkpoint(letter_run / "checkpoint-best.pt")
    assert checkpoint["task"] == "letters" and checkpoint["labels"] == list(LETTERS) and checkpoint["frame_count"] == 1
    assert json.loads((letter_run / "labels.json").read_text()) == list(LETTERS)
    assert json.loads((letter_run / "splits.json").read_text())["signer_splits"][0]["kind"] == SPLIT_BY_CLIP


def test_letter_resume_and_test_evaluation_say_how_it_was_split(letter_run, capsys):
    train_letters.main(
        ["--data", "ignored", "--output", str(letter_run), "--epochs", "4", "--resume", str(letter_run)] + SMALL_ARGUMENTS
    )
    assert "split by clip" in capsys.readouterr().out
    evaluate.main(["--checkpoint", str(letter_run / "checkpoint-last.pt"), "--split", "test", "--device", "cpu", "--workers", "0"])
    results = json.loads(capsys.readouterr().out)
    assert results["task"] == "letters" and results["clips"] > 0 and 0 <= results["top1"] <= 1
    assert "split by clip" in results["split_by"][0]


def test_letter_export_trace_has_scores_only_and_takes_the_temperature(letter_run):
    checkpoint = load_checkpoint(letter_run / "checkpoint-best.pt")
    traced, frame_count, output_names = trace_checkpoint(checkpoint)
    assert frame_count == 1 and output_names == ["scores"]
    features = torch.randn(1, 1, 117)
    plain_scores = traced(features, torch.ones(1, 1))
    assert plain_scores.shape == (1, 4)
    calibrated_traced, frame_count, output_names = trace_checkpoint(checkpoint, temperature=2.0)
    torch.testing.assert_close(calibrated_traced(features, torch.ones(1, 1)), plain_scores / 2.0)


def test_letters_can_be_calibrated(letter_run):
    calibration = calibrate.calibrate_checkpoint(
        str(letter_run / "checkpoint-best.pt"), device_choice="cpu", workers=0, print_line=lambda line: None
    )
    assert calibration["task"] == "letters" and calibration["temperature"] > 0


@pytest.mark.slow
def test_letter_core_ml_conversion(letter_run, tmp_path):
    pytest.importorskip("coremltools")
    import coremltools

    from signs.export_coreml import export_checkpoint

    written_path = export_checkpoint(str(letter_run / "checkpoint-best.pt"), str(tmp_path / "SignSpellISL.mlpackage"))
    specification = coremltools.models.MLModel(str(written_path), skip_model_load=True).get_spec()
    assert [feature.name for feature in specification.description.input] == ["features", "mask"]
    assert list(specification.description.input[0].type.multiArrayType.shape) == [1, 1, 117]
    assert [feature.name for feature in specification.description.output] == ["scores"]
    assert json.loads((tmp_path / "SignSpellISL.labels.json").read_text()) == list(LETTERS)


def test_train_letters_help_explains_itself(capsys):
    with pytest.raises(SystemExit):
        train_letters.main(["--help"])
    assert "one frame" in capsys.readouterr().out
