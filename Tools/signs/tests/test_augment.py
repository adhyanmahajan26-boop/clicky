import numpy as np

from signs.augment import (
    AugmentSettings,
    augment_clip,
    drop_hand_for_stretch,
    jitter_joints,
    mirror,
    resample_time,
    rotate,
    scale,
    shift,
    stretch_x,
    trim_ends,
)
from signs.features import compute_features
from signs.landmarks import (
    CONFIDENCE,
    LEFT_HAND_START,
    LEFT_SHOULDER,
    MOUTH_LEFT_CORNER,
    MOUTH_RIGHT_CORNER,
    RIGHT_HAND_START,
    RIGHT_SHOULDER,
)
from synthetic_signs import wrist_trajectory_clip


def example_clip(frame_count=24, seed=0):
    clip = wrist_trajectory_clip(0, frame_count, np.random.default_rng(seed))
    clip[5:8, 30] = 0.0  # a few missing points
    return clip


def assert_missing_points_are_zero(clip):
    missing = clip[:, :, CONFIDENCE] <= 0
    assert np.all(clip[missing] == 0)


def test_mirror_twice_is_identity():
    clip = example_clip()
    twice_mirrored = mirror(mirror(clip))
    np.testing.assert_allclose(twice_mirrored, clip, atol=1e-6)
    np.testing.assert_array_equal(twice_mirrored[:, :, CONFIDENCE], clip[:, :, CONFIDENCE])


def test_mirror_swaps_sides_and_seen_flags():
    clip = example_clip()  # right hand only
    mirrored = mirror(clip)
    assert np.all(mirrored[:, RIGHT_HAND_START : RIGHT_HAND_START + 21, CONFIDENCE] == 0)
    np.testing.assert_allclose(mirrored[:, LEFT_HAND_START, 0], 1.0 - clip[:, RIGHT_HAND_START, 0], atol=1e-6)
    np.testing.assert_allclose(mirrored[:, LEFT_SHOULDER, 0], 1.0 - clip[:, RIGHT_SHOULDER, 0], atol=1e-6)
    np.testing.assert_allclose(mirrored[:, MOUTH_RIGHT_CORNER, 0], 1.0 - clip[:, MOUTH_LEFT_CORNER, 0], atol=1e-6)
    original_features = compute_features(clip)
    mirrored_features = compute_features(mirrored)
    np.testing.assert_array_equal(mirrored_features[:, 114], original_features[:, 115])
    np.testing.assert_array_equal(mirrored_features[:, 115], original_features[:, 114])
    assert_missing_points_are_zero(mirrored)


def test_spatial_changes_keep_missing_points_and_rotation_keeps_distances():
    clip = example_clip()
    for changed in (rotate(clip, 12.0), scale(clip, 1.15), stretch_x(clip, 1.3), shift(clip, 0.05, -0.02)):
        assert changed.shape == clip.shape
        np.testing.assert_array_equal(changed[:, :, CONFIDENCE], clip[:, :, CONFIDENCE])
        assert_missing_points_are_zero(changed)
    rotated = rotate(clip, 12.0)
    original_distance = np.linalg.norm(clip[:, 0, :2] - clip[:, 9, :2], axis=1)
    rotated_distance = np.linalg.norm(rotated[:, 0, :2] - rotated[:, 9, :2], axis=1)
    np.testing.assert_allclose(rotated_distance, original_distance, atol=1e-5)
    # Rotation, scale and shift don't change the hand's shape features (only its tilt, for rotation).
    np.testing.assert_allclose(compute_features(shift(clip, 0.05, 0.03)), compute_features(clip), atol=1e-4)
    np.testing.assert_allclose(compute_features(scale(clip, 1.2)), compute_features(clip), atol=1e-4)


def test_time_resampling_lengths_and_no_blending_with_missing():
    clip = example_clip(20)
    assert resample_time(clip, 1.4).shape[0] == 28
    assert resample_time(clip, 0.7).shape[0] == 14
    resampled = resample_time(clip, 1.37)
    assert_missing_points_are_zero(resampled)
    seen_confidences = resampled[:, :, CONFIDENCE][resampled[:, :, CONFIDENCE] > 0]
    assert np.all(seen_confidences >= 0.79), "a point is only blended between two seen frames"
    np.testing.assert_allclose(resample_time(clip, 1.0), clip, atol=1e-6)


def test_trim_drop_and_jitter():
    clip = example_clip(20)
    assert trim_ends(clip, 6, 6, fewest_frames_kept=10).shape[0] == 10
    dropped = drop_hand_for_stretch(clip, RIGHT_HAND_START, 3, 4)
    assert np.all(dropped[3:7, 0:21] == 0) and np.all(dropped[7, 0:21, CONFIDENCE] > 0)
    jittered = jitter_joints(clip, np.random.default_rng(1), 0.03, 0.05)
    assert_missing_points_are_zero(jittered)
    assert 0 < np.abs(jittered - clip).max() < 0.05


def test_augment_clip_is_seeded_and_safe():
    clip = example_clip(30)
    settings = AugmentSettings(
        mirror_probability=1, rotation_probability=1, scale_probability=1, x_stretch_probability=1,
        shift_probability=1, jitter_probability=1, time_scale_probability=1, trim_probability=1,
        hand_drop_probability=1, frame_drop_probability=1, joint_drop_probability=1,
    )
    first = augment_clip(clip, np.random.default_rng(5), settings, picture_aspect=4 / 3)
    second = augment_clip(clip, np.random.default_rng(5), settings, picture_aspect=4 / 3)
    np.testing.assert_array_equal(first, second)
    assert first.dtype == np.float32 and first.shape[1:] == (61, 3) and first.shape[0] >= settings.fewest_frames_kept
    assert_missing_points_are_zero(first)
    np.testing.assert_array_equal(clip, example_clip(30)), "the input is never changed"
    for seed in range(20):
        compute_features(augment_clip(clip, np.random.default_rng(seed), AugmentSettings()))
