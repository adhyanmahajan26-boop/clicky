"""SPEC section 3, "Frame rate": landmarks are brought to 30 frames a second, once, when a dataset is packed."""

import json

import numpy as np
import pytest

from signs.frame_rate import (
    frame_rate_from_times,
    new_frame_times,
    resample_clip_to_30_per_second,
    resample_landmarks_at_times,
    resample_to_30_per_second,
    resampled_frame_count,
)
from signs.landmarks import PACKED_DESCRIPTION_FILE_NAME, ClipRecord, PackedDataset, empty_clip, is_packed, load_packed
from signs.make_golden import (
    DEFAULT_FRAME_RATE_GOLDEN_FOLDER,
    frame_rate_golden_cases,
    write_frame_rate_golden_files,
)
from synthetic_signs import write_dataset, wrist_trajectory_clip


def moving_clip(frame_count: int, seed: int = 0) -> np.ndarray:
    return wrist_trajectory_clip(0, frame_count, np.random.default_rng(seed))


@pytest.mark.parametrize("frames_per_second", [0, 27, 29.97, 30, 33])
def test_rates_from_27_to_33_and_unknown_are_left_alone(frames_per_second):
    clip = moving_clip(20)
    np.testing.assert_array_equal(resample_clip_to_30_per_second(clip, frames_per_second), clip)
    assert resampled_frame_count(20, frames_per_second) == 20


def test_too_few_frames_are_left_alone():
    assert resample_clip_to_30_per_second(empty_clip(0), 60).shape == (0, 61, 3)
    one_frame = moving_clip(1)
    np.testing.assert_array_equal(resample_to_30_per_second(one_frame, [4.2]), one_frame)
    assert frame_rate_from_times([1.0, 1.0]) == 0


def test_sixty_a_second_keeps_every_other_frame():
    clip = moving_clip(13)
    resampled = resample_clip_to_30_per_second(clip, 60)
    assert resampled.shape == (7, 61, 3)
    np.testing.assert_allclose(resampled, clip[::2], atol=1e-6)


def test_last_frame_is_not_lost_to_rounding():
    # 0.1 s at 10 a second: new frames at 0, 1/30, 2/30 and 3/30, which is 0.1 only up to rounding.
    assert len(new_frame_times(0.0, 0.1)) == 4
    assert len(new_frame_times(5.0, 5.1)) == 4


def test_seen_points_slide_with_the_smaller_confidence_and_others_come_from_the_nearer_frame():
    clip = empty_clip(2)
    clip[0, 0] = (0.2, 0.4, 0.9)
    clip[1, 0] = (0.4, 0.6, 0.5)
    clip[0, 1] = (0.3, 0.3, 0.7)  # seen only in the first frame
    clip[1, 2] = (0.6, 0.6, 0.8)  # seen only in the second frame
    resampled = resample_landmarks_at_times(clip, [0.0, 1.0], [0.25, 0.75])
    np.testing.assert_allclose(resampled[0, 0], (0.25, 0.45, 0.5), atol=1e-6)
    np.testing.assert_allclose(resampled[1, 0], (0.35, 0.55, 0.5), atol=1e-6)
    np.testing.assert_array_equal(resampled[0, 1], clip[0, 1])
    np.testing.assert_array_equal(resampled[1, 1], (0, 0, 0))
    np.testing.assert_array_equal(resampled[0, 2], (0, 0, 0))
    np.testing.assert_array_equal(resampled[1, 2], clip[1, 2])


def test_times_that_go_backwards_are_refused():
    with pytest.raises(ValueError):
        resample_to_30_per_second(moving_clip(3), [0.0, 0.2, 0.1])


@pytest.mark.parametrize("frames_per_second", [5, 12.5, 15, 24, 25, 26.9, 33.1, 48, 50, 59.94, 60, 120])
def test_frame_count_is_known_without_the_clip(frames_per_second):
    for frame_count in (2, 3, 7, 31, 100):
        resampled = resample_clip_to_30_per_second(moving_clip(frame_count), frames_per_second)
        assert resampled.shape[0] == resampled_frame_count(frame_count, frames_per_second)
        assert resampled.dtype == np.float32


def test_packing_brings_clips_to_30_a_second_and_marks_the_pack(tmp_path):
    clips_and_records = [
        (moving_clip(31, 1), ClipRecord("fast", "ds", "asl", "word", "s1", "", 60, 640, 480, 31, "apple")),
        (moving_clip(20, 2), ClipRecord("usual", "ds", "asl", "word", "s1", "", 30, 640, 480, 20, "apple")),
        (moving_clip(11, 3), ClipRecord("slow", "ds", "asl", "word", "s1", "", 25, 640, 480, 11, "apple")),
    ]
    write_dataset(tmp_path, clips_and_records)
    packed = load_packed(tmp_path)
    assert [packed.clip(number).shape[0] for number in range(3)] == [16, 20, 13]
    assert [clip_record.frames for clip_record in packed.clip_records] == [16, 20, 13]
    np.testing.assert_allclose(packed.clip(0), resample_clip_to_30_per_second(clips_and_records[0][0], 60))
    np.testing.assert_array_equal(packed.clip(1), clips_and_records[1][0])

    # A pack made before the frame-rate rule has no description file: it is packed again on first use.
    (tmp_path / PACKED_DESCRIPTION_FILE_NAME).unlink()
    assert not is_packed(tmp_path)
    with pytest.raises(FileNotFoundError):
        PackedDataset(tmp_path)
    assert load_packed(tmp_path).clip(0).shape[0] == 16


# ---- the golden files Swift is checked against -----------------------------------------------------------------


def test_frame_rate_golden_files_are_current_and_stable(tmp_path):
    first_paths = write_frame_rate_golden_files(tmp_path / "first")
    second_paths = write_frame_rate_golden_files(tmp_path / "second")
    assert [path.name for path in first_paths] == [f"{case['name']}.json" for case in frame_rate_golden_cases()]
    for first_path, second_path in zip(first_paths, second_paths):
        assert first_path.read_bytes() == second_path.read_bytes()
        committed_path = DEFAULT_FRAME_RATE_GOLDEN_FOLDER / first_path.name
        assert committed_path.exists(), f"run `python -m signs.make_golden` ({first_path.name} is missing)"
        assert committed_path.read_bytes() == first_path.read_bytes(), f"{first_path.name} is stale: run make_golden"


def test_frame_rate_golden_files_have_the_agreed_shape_and_recompute():
    golden_paths = sorted(DEFAULT_FRAME_RATE_GOLDEN_FOLDER.glob("*.json"))
    assert {path.stem for path in golden_paths} == {
        "fps_25", "fps_60", "fps_15_points_come_and_go", "uneven_camera_times_about_20", "fps_29_97_unchanged",
        "single_frame", "two_frames",
    }
    for golden_path in golden_paths:
        golden = json.loads(golden_path.read_text())
        assert set(golden) == {"name", "description", "times", "landmarks", "resampled"}
        landmarks = np.array(golden["landmarks"], dtype=np.float32)
        assert landmarks.shape == (len(golden["times"]), 61, 3)
        resampled = resample_to_30_per_second(landmarks, golden["times"])
        np.testing.assert_allclose(resampled, np.array(golden["resampled"]), atol=1.5e-6, err_msg=golden_path.name)
    unchanged = json.loads((DEFAULT_FRAME_RATE_GOLDEN_FOLDER / "fps_29_97_unchanged.json").read_text())
    assert unchanged["resampled"] == unchanged["landmarks"]


def test_golden_cases_are_not_on_a_knife_edge():
    """Swift and Python do the same Double arithmetic, but a time sitting exactly on a frame or half way between
    two could still go either way by one bit. Nudging every new time by far more than that must not change a
    golden answer by more than the files' rounding."""
    for case in frame_rate_golden_cases():
        times = np.asarray(case["times"], dtype=np.float64)
        if frame_rate_from_times(times) == 0 or 27 <= frame_rate_from_times(times) <= 33:
            continue
        wanted_times = new_frame_times(times[0], times[-1])
        expected = resample_landmarks_at_times(case["landmarks"], times, wanted_times)
        for nudge in (-1e-9, 1e-9):
            nudged_times = wanted_times.copy()
            nudged_times[1:] += nudge  # new frame 0 is exactly the first frame's time on both sides
            nudged = resample_landmarks_at_times(case["landmarks"], times, nudged_times)
            np.testing.assert_allclose(nudged, expected, atol=1e-6, err_msg=case["name"])
