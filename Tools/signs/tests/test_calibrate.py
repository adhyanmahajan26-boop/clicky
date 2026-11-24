"""Honest confidence: the temperature, the answer-or-"unclear" threshold, and baking both into the export."""

import json

import numpy as np
import pytest
import torch

from signs import calibrate, train_words
from signs.calibrate import (
    answered_and_right,
    calibration_path_for_checkpoint,
    choose_threshold,
    fit_temperature,
    negative_log_likelihood,
    read_calibration_for_export,
    softmax_with_temperature,
    threshold_table,
    threshold_values,
    write_reading_file,
)
from signs.export_coreml import trace_checkpoint
from signs.landmarks import ClipRecord
from signs.training import load_checkpoint, save_checkpoint
from synthetic_signs import WORD_TRAJECTORIES, write_dataset, wrist_trajectory_clip

SMALL_MODEL_ARGUMENTS = ["--width", "32", "--device", "cpu", "--batch-size", "16", "--warmup-epochs", "0.5", "--workers", "0"]


def test_temperature_undoes_a_known_overconfidence():
    generator = np.random.default_rng(0)
    calibrated_scores = generator.normal(scale=2.0, size=(6000, 5))
    # Each clip's word is drawn from the softmax of its scores, so those scores are calibrated by construction.
    calibrated_probabilities = softmax_with_temperature(calibrated_scores, 1.0)
    word_numbers = np.array([generator.choice(5, p=probabilities) for probabilities in calibrated_probabilities])
    # The same scores sharpened 3 times: the fit must find about 3.
    fitted_temperature = fit_temperature(calibrated_scores * 3, word_numbers)
    assert fitted_temperature == pytest.approx(3.0, rel=0.1)
    assert negative_log_likelihood(calibrated_scores * 3, word_numbers, fitted_temperature) < negative_log_likelihood(
        calibrated_scores * 3, word_numbers, 1.0
    )


def test_softmax_with_temperature_sums_to_one():
    probabilities = softmax_with_temperature(np.array([[1000.0, 0.0], [1.0, 2.0]]), 2.0)
    np.testing.assert_allclose(probabilities.sum(axis=1), [1, 1])


def test_threshold_values_are_clean():
    assert threshold_values(0.25) == [0.0, 0.25, 0.5, 0.75]
    assert threshold_values(0.01)[7] == 0.07 and len(threshold_values(0.01)) == 100


def test_lowest_threshold_reaching_the_wanted_share_is_chosen():
    top_probabilities = np.array([0.95, 0.9, 0.8, 0.6, 0.5, 0.3])
    is_right = np.array([True, True, True, False, True, False])
    table_rows = threshold_table(top_probabilities, is_right, [0.0, 0.4, 0.55, 0.7])
    assert [row["answered"] for row in table_rows] == [6, 5, 4, 3]
    chosen_row, reached = choose_threshold(table_rows, 0.95)
    assert reached and chosen_row["leastProbability"] == 0.7 and chosen_row["rightWhenAnswered"] == 1.0
    chosen_row, reached = choose_threshold(table_rows, 0.75)
    # 0.0 answers all 6 with 4 right (67%); 0.4 answers 5 with 4 right (80%).
    assert reached and chosen_row["leastProbability"] == 0.4
    assert answered_and_right(top_probabilities, is_right, 0.99)["rightWhenAnswered"] is None


def test_an_unreachable_share_is_said_and_the_best_is_kept():
    table_rows = threshold_table(np.array([0.9, 0.8, 0.4]), np.array([False, True, True]), [0.0, 0.5, 0.85])
    chosen_row, reached = choose_threshold(table_rows, 0.95)
    assert not reached
    assert chosen_row["leastProbability"] == 0.0 and chosen_row["rightWhenAnswered"] == pytest.approx(2 / 3)


@pytest.fixture(scope="module")
def word_run_with_untaught_signs(tmp_path_factory):
    run_folder = tmp_path_factory.mktemp("calibrate-run")
    generator = np.random.default_rng(5)
    clips_and_records = []
    for signer_number in range(8):
        for word_number, word in enumerate(WORD_TRAJECTORIES[:4]):
            for repeat in range(2):
                frame_count = int(generator.integers(20, 40))
                clip = wrist_trajectory_clip(word_number, frame_count, generator)
                clip_id = f"w-{signer_number}-{word}-{repeat}"
                clips_and_records.append(
                    (clip, ClipRecord(clip_id, "synthetic", "asl", word, f"signer{signer_number}", "", 30, 640, 480, frame_count, "apple"))
                )
    # "still" is never taught: it only appears for the validation and test signers' own split rows.
    for split, signer in (("val", "untaught-a"), ("test", "untaught-b")):
        for repeat in range(3):
            clip = wrist_trajectory_clip(4, 30, generator)
            clips_and_records.append(
                (clip, ClipRecord(f"still-{split}-{repeat}", "synthetic", "asl", "still", signer, split, 30, 640, 480, 30, "apple"))
            )
    data_folder = write_dataset(run_folder / "data", clips_and_records)
    output_folder = run_folder / "out"
    train_words.main(
        ["--data", str(data_folder), "--output", str(output_folder), "--epochs", "3", "--min-clips-per-word", "2"]
        + SMALL_MODEL_ARGUMENTS
    )
    return output_folder


def test_calibrate_writes_its_file_and_reports_untaught_signs(word_run_with_untaught_signs):
    checkpoint_path = word_run_with_untaught_signs / "checkpoint-best.pt"
    printed_lines = []
    calibration = calibrate.calibrate_checkpoint(
        str(checkpoint_path), 0.95, 0.05, device_choice="cpu", workers=0, print_line=printed_lines.append
    )
    printed_text = "\n".join(printed_lines)
    assert "least probability" in printed_text and "test signers at" in printed_text
    assert "never taught (validation signers)" in printed_text and "never taught (test signers)" in printed_text
    assert calibration["untaughtSigns"]["val"]["clips"] == 3 and calibration["untaughtSigns"]["test"]["clips"] == 3
    assert ("CAN'T REACH" in printed_text) == (not calibration["reached"])
    saved = json.loads(calibration_path_for_checkpoint(checkpoint_path).read_text())
    assert saved["temperature"] > 0 and 0 <= saved["leastWordProbability"] < 1
    assert saved["weightsFingerprint"] == calibrate.weights_fingerprint(load_checkpoint(checkpoint_path))


def test_temperature_is_baked_into_the_export_and_reading_file_written(word_run_with_untaught_signs, tmp_path):
    checkpoint_path = word_run_with_untaught_signs / "checkpoint-best.pt"
    calibrate.calibrate_checkpoint(str(checkpoint_path), device_choice="cpu", workers=0, print_line=lambda line: None)
    checkpoint = load_checkpoint(checkpoint_path)
    calibration = read_calibration_for_export(checkpoint_path, checkpoint)
    features, mask = torch.randn(1, 96, 117), torch.ones(1, 96)
    plain_traced, frame_count, output_names = trace_checkpoint(checkpoint)
    calibrated_traced, frame_count, output_names = trace_checkpoint(checkpoint, calibration["temperature"])
    plain_scores, plain_description = plain_traced(features, mask)
    calibrated_scores, calibrated_description = calibrated_traced(features, mask)
    torch.testing.assert_close(calibrated_scores, plain_scores / calibration["temperature"])
    torch.testing.assert_close(calibrated_description, plain_description)

    reading_path = write_reading_file(tmp_path / "SignWordsASL.mlpackage", calibration)
    assert reading_path.name == "SignWordsASL.reading.json"
    assert set(json.loads(reading_path.read_text())) == {
        "leastWordProbability", "rightWhenAnsweredOnValidation", "answeredOnValidation", "temperature"
    }


def test_a_calibration_for_other_weights_stops_the_export(word_run_with_untaught_signs, tmp_path):
    checkpoint_path = word_run_with_untaught_signs / "checkpoint-best.pt"
    calibrate.calibrate_checkpoint(str(checkpoint_path), device_choice="cpu", workers=0, print_line=lambda line: None)
    changed_checkpoint = load_checkpoint(checkpoint_path)
    first_weight_name = sorted(changed_checkpoint["ema_state"]["model"])[0]
    changed_checkpoint["ema_state"]["model"][first_weight_name] += 1.0
    changed_checkpoint_path = tmp_path / "checkpoint-best.pt"
    save_checkpoint(changed_checkpoint, changed_checkpoint_path)
    stale_calibration_path = calibration_path_for_checkpoint(checkpoint_path)
    with pytest.raises(SystemExit):
        read_calibration_for_export(changed_checkpoint_path, changed_checkpoint, stale_calibration_path)
    # Without a calibration file the export simply isn't calibrated.
    assert read_calibration_for_export(changed_checkpoint_path, changed_checkpoint) is None


@pytest.mark.slow
def test_calibrated_core_ml_export_writes_the_reading_file(word_run_with_untaught_signs, tmp_path):
    pytest.importorskip("coremltools")
    from signs.export_coreml import export_checkpoint

    checkpoint_path = word_run_with_untaught_signs / "checkpoint-best.pt"
    calibrate.calibrate_checkpoint(str(checkpoint_path), device_choice="cpu", workers=0, print_line=lambda line: None)
    written_path = export_checkpoint(str(checkpoint_path), str(tmp_path / "SignWordsASL.mlpackage"))
    assert written_path.exists()
    assert isinstance(json.loads((tmp_path / "SignWordsASL.labels.json").read_text()), list)
    reading = json.loads((tmp_path / "SignWordsASL.reading.json").read_text())
    assert reading["temperature"] == json.loads(calibration_path_for_checkpoint(checkpoint_path).read_text())["temperature"]


def test_calibrate_help_explains_itself(capsys):
    with pytest.raises(SystemExit):
        calibrate.main(["--help"])
    assert "unclear" in capsys.readouterr().out
