"""Runs of signs without rests: building sentences from single-sign clips, and the sentence model end to end."""

import json

import numpy as np
import pytest
import torch

from signs import evaluate, train_sentences, train_words
from signs.augment import AugmentSettings
from signs.data import assign_splits, load_sources
from signs.export_coreml import trace_checkpoint
from signs.landmarks import CONFIDENCE, LEFT_SHOULDER, RIGHT_HAND_START, ClipRecord
from signs.sentences import (
    UNKNOWN_WORD_NUMBER,
    SentenceDataset,
    SentencePlanner,
    SentenceSettings,
    body_placement,
    choose_sign_count,
    in_between_frames,
    join_signs,
    move_onto_body,
    real_continuous_items,
    shave_ends,
)
from signs.training import load_checkpoint
from synthetic_signs import WORD_TRAJECTORIES, make_word_dataset, write_dataset, wrist_trajectory_clip

SMALL_MODEL_ARGUMENTS = ["--width", "32", "--device", "cpu", "--batch-size", "8", "--warmup-epochs", "0.5", "--workers", "0"]
NO_SHAVING = SentenceSettings(shave_probability=0.0)


def test_sign_counts_keep_one_sign_sentences_common():
    generator = np.random.default_rng(0)
    sign_counts = np.array([choose_sign_count(generator, SentenceSettings()) for draw in range(4000)])
    assert sign_counts.min() == 1 and sign_counts.max() == 6
    assert np.mean(sign_counts == 1) == pytest.approx(0.25, abs=0.03)
    assert SentenceSettings().mean_sign_count() == pytest.approx(0.25 + 0.75 * 4)


def test_shaving_takes_at_most_a_fifth_off_each_end():
    clip = wrist_trajectory_clip(0, 30, np.random.default_rng(1))
    generator = np.random.default_rng(2)
    for draw in range(50):
        shaved = shave_ends(clip, generator, SentenceSettings())
        assert 30 - 2 * 6 <= shaved.shape[0] <= 30
        start = int(np.argmax([np.array_equal(clip[frame], shaved[0]) for frame in range(30)]))
        assert start <= 6 and np.array_equal(clip[start : start + shaved.shape[0]], shaved)


def test_in_between_frames_slide_points_seen_on_both_sides():
    clip = wrist_trajectory_clip(1, 10, np.random.default_rng(3))
    last_frame = clip[-1].copy()
    next_first_frame = clip[0].copy()
    next_first_frame[LEFT_SHOULDER] = 0.0  # unseen on one side: unseen in between
    next_first_frame[RIGHT_HAND_START, CONFIDENCE] = 0.4
    joining = in_between_frames(last_frame, next_first_frame, 3)
    assert joining.shape == (3, 61, 3)
    np.testing.assert_allclose(
        joining[1, RIGHT_HAND_START, :2], (last_frame[RIGHT_HAND_START, :2] + next_first_frame[RIGHT_HAND_START, :2]) / 2, atol=1e-6
    )
    assert joining[1, RIGHT_HAND_START, CONFIDENCE] == pytest.approx(0.4)
    assert not joining[:, LEFT_SHOULDER].any()
    assert not joining[:, 21:42].any()  # no left hand on either side


def test_clips_are_brought_onto_the_first_clips_body():
    generator = np.random.default_rng(4)
    first_clip = wrist_trajectory_clip(0, 20, generator)
    other_clip = wrist_trajectory_clip(2, 20, generator)
    # The second signer stands further away and to the side: smaller and moved.
    other_seen = other_clip[:, :, CONFIDENCE] > 0
    other_clip[:, :, :2] = np.where(other_seen[:, :, None], other_clip[:, :, :2] * 0.6 + 0.2, 0.0)
    first_placement = body_placement(first_clip, 640, 480)
    moved = move_onto_body(other_clip, body_placement(other_clip, 640, 480), first_placement)
    moved_placement = body_placement(moved, 640, 480)
    np.testing.assert_allclose(moved_placement.centre, first_placement.centre, atol=1e-5)
    assert moved_placement.body_size == pytest.approx(first_placement.body_size, rel=1e-5)
    assert np.array_equal(moved[:, :, CONFIDENCE] > 0, other_seen)
    assert not moved[~other_seen].any()


def test_joined_sentence_is_the_signs_and_the_frames_between():
    generator = np.random.default_rng(5)
    sign_clips = [(wrist_trajectory_clip(word_number, 25, generator), 640, 480) for word_number in (0, 1, 3)]
    sentence = join_signs(sign_clips, np.random.default_rng(6), NO_SHAVING)
    in_between_frame_count = sentence.shape[0] - 75
    assert 2 * 3 <= in_between_frame_count <= 2 * 10
    np.testing.assert_allclose(sentence[:25], sign_clips[0][0], atol=1e-6)  # the first clip is the reference


def make_mixed_dataset(folder):
    """Single signs for 6 signers plus real continuous clips (signs joined with |) for every signer."""
    generator = np.random.default_rng(7)
    clips_and_records = []
    for signer_number in range(6):
        for word_number, word in enumerate(WORD_TRAJECTORIES):
            for repeat in range(2):
                clip = wrist_trajectory_clip(word_number, int(generator.integers(20, 30)), generator)
                clips_and_records.append(
                    (clip, ClipRecord(f"s{signer_number}-{word}-{repeat}", "synthetic", "asl", word, f"p{signer_number}", "", 30, 640, 480, clip.shape[0], "apple"))
                )
        for phrase_number, phrase in enumerate(("circle|up", "right|still|down_left", "up|wave")):
            parts = [wrist_trajectory_clip(WORD_TRAJECTORIES.index(word) if word in WORD_TRAJECTORIES else 4, 20, generator) for word in phrase.split("|")]
            clip = np.concatenate(parts)
            clips_and_records.append(
                (clip, ClipRecord(f"real-{signer_number}-{phrase_number}", "synthetic", "asl", phrase, f"p{signer_number}", "", 30, 640, 480, clip.shape[0], "apple"))
            )
    return write_dataset(folder, clips_and_records)


def test_real_continuous_clips_are_used_as_they_are(tmp_path):
    sources = load_sources([str(make_mixed_dataset(tmp_path / "data"))])
    sample_references, signer_splits = assign_splits(sources, seed=1)
    word_list = sorted(WORD_TRAJECTORIES)
    measuring_items = real_continuous_items(sample_references, word_list, keep_clips_with_unknown_words=True)
    training_items = real_continuous_items(sample_references, word_list, keep_clips_with_unknown_words=False)
    assert len(measuring_items) == 18 and len(training_items) == 12  # "up wave": wave isn't a word the model has
    wave_item = next(item for item in measuring_items if item.sign_count == 2 and UNKNOWN_WORD_NUMBER in item.word_numbers)
    assert wave_item.word_numbers == [word_list.index("up"), UNKNOWN_WORD_NUMBER]
    # Built sentences never take a real continuous clip as one of their signs.
    planner = SentencePlanner(sources, sample_references, word_list)
    assert all("|" not in reference.label for reference in planner.single_sign_references)


def test_built_sentences_keep_to_one_signer(tmp_path):
    sources = load_sources([str(make_word_dataset(tmp_path / "data", clips_per_word_per_signer=2, signer_count=5))])
    sample_references, signer_splits = assign_splits(sources, seed=1)
    planner = SentencePlanner(sources, sample_references, sorted(WORD_TRAJECTORIES))
    for item in planner.plan_sentences(200, np.random.default_rng(0), SentenceSettings()):
        assert len({reference.signer for reference in item.references}) == 1
        assert not item.is_real_continuous_clip and 1 <= item.sign_count <= 6


def test_measuring_sentences_are_fixed_and_training_ones_fresh_each_epoch(tmp_path):
    sources = load_sources([str(make_mixed_dataset(tmp_path / "data"))])
    sample_references, signer_splits = assign_splits(sources, seed=1)
    word_list = sorted(WORD_TRAJECTORIES)
    first = SentenceDataset(sources, sample_references, word_list, SentenceSettings(), None, seed=11, fixed_sentence_count=12)
    second = SentenceDataset(sources, sample_references, word_list, SentenceSettings(), None, seed=11, fixed_sentence_count=12)
    assert len(first) == 12 + 18
    for item_number in (0, 5, 20):
        for first_part, second_part in zip(first[item_number], second[item_number]):
            torch.testing.assert_close(first_part, second_part)
    features, frame_mask, targets = first[20]
    assert features.shape[1] == 117 and features.shape[0] <= 384 and targets.min() >= 1

    training = SentenceDataset(sources, sample_references, word_list, SentenceSettings(), None, seed=11, fresh_sentence_count=10)
    epoch_zero_words = [item.word_numbers for item in training.items]
    training.set_epoch(1)
    assert [item.word_numbers for item in training.items] != epoch_zero_words
    assert len(training) == 10 + 12


@pytest.fixture(scope="module")
def sentence_run(tmp_path_factory):
    run_folder = tmp_path_factory.mktemp("sentence-run")
    data_folder = make_mixed_dataset(run_folder / "data")
    word_folder = run_folder / "words"
    train_words.main(
        ["--data", str(data_folder), "--output", str(word_folder), "--epochs", "1", "--min-clips-per-word", "2"]
        + ["--width", "32", "--device", "cpu", "--batch-size", "16", "--warmup-epochs", "0.5", "--workers", "0"]
    )
    output_folder = run_folder / "out"
    train_sentences.main(
        ["--data", str(data_folder), "--output", str(output_folder), "--epochs", "2", "--min-clips-per-word", "2",
         "--start-from", str(word_folder / "checkpoint-best.pt")] + SMALL_MODEL_ARGUMENTS
    )
    return output_folder, word_folder


def test_sentence_training_starts_from_the_word_encoder_and_logs_word_error_rate(sentence_run):
    output_folder, word_folder = sentence_run
    log_entries = [json.loads(line) for line in (output_folder / "log.jsonl").read_text().splitlines()]
    assert [entry["epoch"] for entry in log_entries] == [0, 1]
    assert {"validation_word_error_rate", "validation_one_sign_accuracy", "validation_real_continuous_word_error_rate"} <= set(log_entries[0])
    checkpoint = load_checkpoint(output_folder / "checkpoint-best.pt")
    assert checkpoint["task"] == "sentences" and checkpoint["frame_count"] == 384
    assert checkpoint["labels"] == sorted(WORD_TRAJECTORIES)
    assert json.loads((output_folder / "labels.json").read_text()) == checkpoint["labels"]

    # A fresh run (one step) from the word model starts with the word model's encoder weights.
    word_checkpoint = load_checkpoint(word_folder / "checkpoint-best.pt")
    model = train_sentences.build_sentence_model(checkpoint["encoder_settings"], len(checkpoint["labels"]))
    fresh = train_sentences.load_word_encoder(model, word_checkpoint)
    assert fresh and all(name.startswith("halve_frames") for name in fresh)
    torch.testing.assert_close(model.encoder.stem.weight, word_checkpoint["ema_state"]["model"]["encoder.stem.weight"])


def test_sentence_resume_and_test_evaluation(sentence_run, capsys):
    output_folder, word_folder = sentence_run
    validation_results_before = evaluate.evaluate_checkpoint(
        str(output_folder / "checkpoint-last.pt"), "val", device_choice="cpu", workers=0
    )
    train_sentences.main(
        ["--data", "ignored", "--output", str(output_folder), "--epochs", "3", "--resume", str(output_folder)]
        + SMALL_MODEL_ARGUMENTS
    )
    log_entries = [json.loads(line) for line in (output_folder / "log.jsonl").read_text().splitlines()]
    assert [entry["epoch"] for entry in log_entries] == [0, 1, 2]
    validation_results_after = evaluate.evaluate_checkpoint(str(output_folder / "checkpoint-last.pt"), "val", device_choice="cpu", workers=0)
    # The same fixed validation sentences before and after the resume.
    assert [example["target"] for example in validation_results_before["examples"]] == [
        example["target"] for example in validation_results_after["examples"]
    ]
    capsys.readouterr()
    evaluate.main(["--checkpoint", str(output_folder / "checkpoint-last.pt"), "--split", "test", "--device", "cpu", "--workers", "0"])
    results = json.loads(capsys.readouterr().out)
    assert results["task"] == "sentences" and results["split"] == "test"
    assert results["built_sentences"] > 0 and results["real_continuous_clips"] > 0
    assert results["word_error_rate"] is not None and results["one_sign_sentences"] >= 0
    assert "not real fluent signing" in results["note"]


def test_sentence_export_trace(sentence_run):
    output_folder, word_folder = sentence_run
    traced, frame_count, output_names = trace_checkpoint(load_checkpoint(output_folder / "checkpoint-best.pt"))
    assert frame_count == 384 and output_names == ["scores"]
    log_probabilities = traced(torch.zeros(1, 384, 117), torch.ones(1, 384))
    assert log_probabilities.shape == (1, 192, len(WORD_TRAJECTORIES) + 1)


@pytest.mark.slow
def test_sentence_core_ml_conversion(sentence_run, tmp_path):
    pytest.importorskip("coremltools")
    import coremltools

    from signs.export_coreml import export_checkpoint

    output_folder, word_folder = sentence_run
    written_path = export_checkpoint(str(output_folder / "checkpoint-best.pt"), str(tmp_path / "SignSentencesASL.mlpackage"))
    specification = coremltools.models.MLModel(str(written_path), skip_model_load=True).get_spec()
    assert list(specification.description.input[0].type.multiArrayType.shape) == [1, 384, 117]
    assert [feature.name for feature in specification.description.output] == ["scores"]
    assert json.loads((tmp_path / "SignSentencesASL.labels.json").read_text()) == sorted(WORD_TRAJECTORIES)
    assert not (tmp_path / "SignSentencesASL.reading.json").exists()


def test_train_sentences_help_explains_itself(capsys):
    with pytest.raises(SystemExit):
        train_sentences.main(["--help"])
    help_text_on_one_line = " ".join(capsys.readouterr().out.split())  # argparse wraps lines anywhere
    assert "NOT numbers on real fluent signing" in help_text_on_one_line


def test_sentence_dataset_survives_pickling_for_spawned_workers(tmp_path):
    # macOS starts DataLoader workers with "spawn", which pickles the dataset with this epoch's planned sentences.
    import pickle

    sources = load_sources([str(make_mixed_dataset(tmp_path / "data"))])
    sample_references, signer_splits = assign_splits(sources, seed=1)
    training = SentenceDataset(
        sources, sample_references, sorted(WORD_TRAJECTORIES), SentenceSettings(), AugmentSettings(), seed=5,
        fresh_sentence_count=6,
    )
    training.set_epoch(3)
    unpickled = pickle.loads(pickle.dumps(training))
    for item_number in (0, 4):
        for original_part, unpickled_part in zip(training[item_number], unpickled[item_number]):
            torch.testing.assert_close(original_part, unpickled_part)
