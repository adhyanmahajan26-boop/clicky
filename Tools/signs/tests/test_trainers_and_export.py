"""The command-line trainers, evaluation and export, end to end on tiny synthetic datasets."""

import json
import pickle

import pytest
import torch

from signs import evaluate, train_spell, train_words
from signs.augment import AugmentSettings
from signs.data import WordClipDataset, assign_splits, load_sources
from signs.export_coreml import trace_checkpoint
from signs.training import load_checkpoint
from synthetic_signs import make_spelling_dataset, make_word_dataset

SMALL_MODEL_ARGUMENTS = ["--width", "32", "--device", "cpu", "--batch-size", "16", "--warmup-epochs", "0.5"]


@pytest.fixture(scope="module")
def word_run(tmp_path_factory):
    run_folder = tmp_path_factory.mktemp("word-run")
    first_dataset = make_word_dataset(run_folder / "data-a", clips_per_word_per_signer=1, signer_count=8, seed=1)
    second_dataset = make_word_dataset(run_folder / "data-b", clips_per_word_per_signer=1, signer_count=4, seed=2)
    output_folder = run_folder / "out"
    train_words.main(
        ["--data", str(first_dataset), str(second_dataset), "--output", str(output_folder), "--epochs", "2",
         "--workers", "2", "--min-clips-per-word", "2"] + SMALL_MODEL_ARGUMENTS
    )
    return output_folder


def test_word_training_writes_checkpoints_log_and_splits(word_run):
    log_entries = [json.loads(line) for line in (word_run / "log.jsonl").read_text().splitlines()]
    assert [entry["epoch"] for entry in log_entries] == [0, 1]
    assert {"train_loss", "validation_top1", "validation_top5", "learning_rate", "seconds"} <= set(log_entries[0])
    checkpoint = load_checkpoint(word_run / "checkpoint-best.pt")
    # The same words from both datasets are one class each.
    assert checkpoint["labels"] == ["circle", "down_left", "right", "still", "up"]
    assert json.loads((word_run / "labels.json").read_text()) == checkpoint["labels"]
    signer_splits = json.loads((word_run / "splits.json").read_text())["signer_splits"]
    assert len(signer_splits) == 2 and "test" in signer_splits[0].values()


def test_word_resume_and_test_split_evaluation(word_run, capsys):
    train_words.main(
        ["--data", "ignored-when-resuming", "--output", str(word_run), "--epochs", "3", "--workers", "0",
         "--resume", str(word_run)] + SMALL_MODEL_ARGUMENTS
    )
    log_entries = [json.loads(line) for line in (word_run / "log.jsonl").read_text().splitlines()]
    assert [entry["epoch"] for entry in log_entries] == [0, 1, 2]

    capsys.readouterr()
    evaluate.main(
        ["--checkpoint", str(word_run / "checkpoint-last.pt"), "--split", "test", "--device", "cpu", "--workers", "0",
         "--source", "apple"]
    )
    results = json.loads(capsys.readouterr().out)
    assert results["split"] == "test" and results["clips"] > 0 and results["landmark_source"] == "apple"
    assert 0 <= results["top1"] <= results["top5"] <= 1
    assert set(results["per_word"]) <= {"circle", "down_left", "right", "still", "up"}


def test_spelling_training_and_evaluation(tmp_path, capsys):
    dataset_folder = make_spelling_dataset(tmp_path / "data", phrases_per_signer=5, signer_count=6)
    output_folder = tmp_path / "out"
    train_spell.main(
        ["--data", str(dataset_folder), "--output", str(output_folder), "--epochs", "2", "--workers", "0"]
        + SMALL_MODEL_ARGUMENTS
    )
    log_entries = [json.loads(line) for line in (output_folder / "log.jsonl").read_text().splitlines()]
    assert "validation_kaggle_score" in log_entries[-1]
    checkpoint = load_checkpoint(output_folder / "checkpoint-best.pt")
    assert checkpoint["labels"] == ["a", "b", "c", "d"] and checkpoint["frame_count"] == 256
    capsys.readouterr()
    evaluate.main(["--checkpoint", str(output_folder / "checkpoint-best.pt"), "--split", "test", "--device", "cpu", "--workers", "0"])
    results = json.loads(capsys.readouterr().out)
    assert results["samples"] > 0 and results["character_error_rate"] is not None
    assert results["kaggle_score"] == pytest.approx(1 - results["character_error_rate"])


def test_trace_matches_the_model_for_both_tasks(word_run, tmp_path):
    traced, frame_count, output_names = trace_checkpoint(load_checkpoint(word_run / "checkpoint-best.pt"))
    assert frame_count == 96 and output_names == ["scores", "description"]
    scores, description = traced(torch.zeros(1, 96, 117), torch.ones(1, 96))
    assert scores.shape == (1, 5) and description.shape == (1, 32)


def test_datasets_survive_pickling_for_spawned_workers(word_run):
    # macOS starts DataLoader workers with "spawn", which pickles the dataset; it must arrive without its frames
    # and make the same samples.
    checkpoint = load_checkpoint(word_run / "checkpoint-best.pt")
    sources = load_sources(checkpoint["data_folders"])
    sample_references, signer_splits = assign_splits(sources, 0, saved_signer_splits=checkpoint["signer_splits"])
    dataset = WordClipDataset(sources, sample_references, checkpoint["labels"], AugmentSettings(), seed=3)
    dataset.set_epoch(4)
    unpickled_dataset = pickle.loads(pickle.dumps(dataset))
    for original_part, unpickled_part in zip(dataset[2], unpickled_dataset[2]):
        torch.testing.assert_close(original_part, unpickled_part)


@pytest.mark.slow
def test_core_ml_conversion(word_run, tmp_path):
    pytest.importorskip("coremltools")
    from signs.export_coreml import export_checkpoint

    written_path = export_checkpoint(str(word_run / "checkpoint-best.pt"), str(tmp_path / "SignWordsTest.mlpackage"))
    assert written_path.exists()
    assert json.loads((tmp_path / "SignWordsTest.labels.json").read_text())[0] == "circle"

    import coremltools

    specification = coremltools.models.MLModel(str(written_path), skip_model_load=True).get_spec()
    assert [feature.name for feature in specification.description.input] == ["features", "mask"]
    assert [feature.name for feature in specification.description.output] == ["scores", "description"]
