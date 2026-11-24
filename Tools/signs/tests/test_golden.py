"""The golden files are the contract with Swift: they must be stable and match what features.py makes now."""

import json

import numpy as np

from signs.features import compute_features
from signs.make_golden import DEFAULT_GOLDEN_FOLDER, write_golden_files


def test_make_golden_is_stable_across_runs(tmp_path):
    first_paths = write_golden_files(tmp_path / "first")
    second_paths = write_golden_files(tmp_path / "second")
    assert len(first_paths) >= 6
    for first_path, second_path in zip(first_paths, second_paths):
        assert first_path.read_bytes() == second_path.read_bytes()


def test_committed_golden_files_are_current(tmp_path):
    fresh_paths = write_golden_files(tmp_path)
    for fresh_path in fresh_paths:
        committed_path = DEFAULT_GOLDEN_FOLDER / fresh_path.name
        assert committed_path.exists(), f"run `python -m signs.make_golden` ({fresh_path.name} is missing)"
        assert committed_path.read_bytes() == fresh_path.read_bytes(), f"{fresh_path.name} is stale: run make_golden"


def test_golden_features_recompute_from_their_own_landmarks():
    for golden_path in sorted(DEFAULT_GOLDEN_FOLDER.glob("*.json")):
        golden = json.loads(golden_path.read_text())
        landmarks = np.array(golden["landmarks"], dtype=np.float32)
        assert 6 <= landmarks.shape[0] <= 20 and landmarks.shape[1:] == (61, 3)
        features = compute_features(landmarks, golden["width"], golden["height"])
        np.testing.assert_allclose(features, np.array(golden["features"]), atol=1.5e-6, err_msg=golden_path.name)
