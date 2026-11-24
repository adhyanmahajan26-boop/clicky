import numpy as np
import pytest

from signs.features import (
    FEATURE_COUNT,
    compute_feature_details,
    compute_features,
    fill_short_gaps,
    fit_to_frame_count,
    hand_seen_flags,
    thin_evenly_frame_indices,
    trim_frames_without_hands,
)
from signs.landmarks import LEFT_HAND_START, LEFT_SHOULDER, NOSE, RIGHT_HAND_START, RIGHT_SHOULDER, empty_clip


def straight_hand_clip(wrist_places, add_shoulders=True) -> np.ndarray:
    """A right hand with joint j at wrist + (0.01 × (j − 9), −0.1) for j = 1…20, so the middle knuckle (joint 9)
    sits exactly 0.1 above the wrist. Shoulders at (0.7, 0.4) (left) and (0.3, 0.4) (right)."""
    clip = empty_clip(len(wrist_places))
    for frame, (wrist_x, wrist_y) in enumerate(wrist_places):
        clip[frame, RIGHT_HAND_START] = (wrist_x, wrist_y, 1.0)
        for joint in range(1, 21):
            clip[frame, RIGHT_HAND_START + joint] = (wrist_x + 0.01 * (joint - 9), wrist_y - 0.1, 1.0)
        if add_shoulders:
            clip[frame, LEFT_SHOULDER] = (0.7, 0.4, 1.0)
            clip[frame, RIGHT_SHOULDER] = (0.3, 0.4, 1.0)
    return clip


def test_one_hand_with_shoulders_worked_out_by_hand():
    features = compute_features(straight_hand_clip([(0.5, 0.5)]))
    assert features.shape == (1, FEATURE_COUNT) and features.dtype == np.float32
    # Hand size = 0.1, so joint j is (0.1 × (j − 9), −1); the wrist is (0, 0).
    expected_right_hand = [0.0, 0.0] + [value for joint in range(1, 21) for value in (0.1 * (joint - 9), -1.0)]
    np.testing.assert_allclose(features[0, 0:42], expected_right_hand, atol=1e-5)
    assert np.all(features[0, 42:84] == 0)
    # Body size = 0.4 (shoulder to shoulder), centre (0.5, 0.4): right wrist = (0, 0.1) / 0.4.
    np.testing.assert_allclose(features[0, 84:86], [0.0, 0.25], atol=1e-6)
    assert np.all(features[0, 86:88] == 0)
    # Left shoulder is body point 5 (features 98, 99), right shoulder body point 6 (100, 101).
    np.testing.assert_allclose(features[0, 98:102], [0.5, 0.0, -0.5, 0.0], atol=1e-6)
    body_features_without_shoulders = np.delete(features[0, 88:114], [10, 11, 12, 13])
    assert np.all(body_features_without_shoulders == 0)
    np.testing.assert_array_equal(features[0, 114:117], [1.0, 0.0, 1.0])


def test_known_picture_size_multiplies_x_first():
    # Width / height = 2: every x doubles before anything is measured. The knuckle offset (0, −0.1) is unchanged,
    # so hand size stays 0.1 and joint x numbers double; shoulders are now 0.8 apart, centre (1.0, 0.4).
    features = compute_features(straight_hand_clip([(0.5, 0.5)]), width=200, height=100)
    expected_right_hand = [0.0, 0.0] + [value for joint in range(1, 21) for value in (0.2 * (joint - 9), -1.0)]
    np.testing.assert_allclose(features[0, 0:42], expected_right_hand, atol=1e-5)
    np.testing.assert_allclose(features[0, 84:86], [0.0, 0.125], atol=1e-6)
    np.testing.assert_allclose(features[0, 98:102], [0.5, 0.0, -0.5, 0.0], atol=1e-6)


def test_no_shoulders_uses_wrist_median_and_hand_size_percentile():
    clip = straight_hand_clip([(0.2, 0.5), (0.4, 0.5)], add_shoulders=False)
    # Make the second frame's hand twice as big: knuckle 0.2 above the wrist.
    clip[1, RIGHT_HAND_START + 1 : RIGHT_HAND_START + 21, 1] = 0.5 - 0.2
    details = compute_feature_details(clip)
    # 90th percentile of [0.1, 0.2] = 0.1 + 0.9 × 0.1.
    assert details.hand_size == pytest.approx(0.19, abs=1e-6)
    assert details.body_size == pytest.approx(3.5 * 0.19, abs=1e-6)
    np.testing.assert_allclose(details.centre, [[0.3, 0.5], [0.3, 0.5]], atol=1e-6)
    np.testing.assert_allclose(details.features[:, 84], [-0.1 / 0.665, 0.1 / 0.665], atol=1e-6)
    assert np.all(details.features[:, 116] == 0)


def test_gap_filling_rules():
    clip = empty_clip(12)
    for frame, x_place in [(0, 0.1), (3, 0.4), (4, 0.5), (9, 0.9), (10, 0.2)]:
        clip[frame, NOSE] = (x_place, 0.3, 1.0)
    filled = fill_short_gaps(clip.astype(np.float64))
    # Frames 1–2: a 2-frame gap, put on the line with confidence 0.5.
    np.testing.assert_allclose(filled[1:3, NOSE], [[0.2, 0.3, 0.5], [0.3, 0.3, 0.5]], atol=1e-9)
    # Frames 5–8: a 4-frame gap is still filled.
    np.testing.assert_allclose(filled[5:9, NOSE, 0], [0.58, 0.66, 0.74, 0.82], atol=1e-9)
    # Frame 11: after the last seen frame, so not filled.
    assert np.all(filled[11, NOSE] == 0)

    clip = empty_clip(8)
    clip[0, NOSE] = (0.1, 0.1, 1.0)
    clip[6, NOSE] = (0.7, 0.1, 1.0)
    filled = fill_short_gaps(clip.astype(np.float64))
    assert np.all(filled[1:6, NOSE] == 0), "a 5-frame gap is too long to fill"


def test_hand_seen_needs_wrist_and_eleven_other_joints():
    clip = straight_hand_clip([(0.5, 0.5)] * 3)
    clip[1, RIGHT_HAND_START + 11 : RIGHT_HAND_START + 21] = 0.0  # 10 others left
    clip[2, RIGHT_HAND_START + 12 : RIGHT_HAND_START + 21] = 0.0  # 11 others left
    np.testing.assert_array_equal(hand_seen_flags(clip, RIGHT_HAND_START), [True, False, True])
    clip[0, RIGHT_HAND_START] = 0.0  # no wrist
    np.testing.assert_array_equal(hand_seen_flags(clip, RIGHT_HAND_START), [False, False, True])


def test_degenerate_hand_size_gives_zero_joint_features():
    clip = straight_hand_clip([(0.5, 0.5)] * 2)
    clip[:, RIGHT_HAND_START : RIGHT_HAND_START + 21, :2] = (0.5, 0.5)
    details = compute_feature_details(clip)
    assert details.hand_size == 1.0 and details.hand_size_is_degenerate
    assert np.all(details.features[:, 0:84] == 0)
    assert np.all(details.features[:, 114] == 1)


def test_no_hand_and_nothing_seen():
    features = compute_features(empty_clip(5))
    assert features.shape == (5, FEATURE_COUNT) and np.all(features == 0)
    assert compute_features(empty_clip(0)).shape == (0, FEATURE_COUNT)


def test_centre_before_the_shoulders_appear_is_the_first_one_seen():
    clip = straight_hand_clip([(0.5, 0.5)] * 4)
    clip[:2, LEFT_SHOULDER] = 0.0
    clip[:2, RIGHT_SHOULDER] = 0.0
    clip[2:, LEFT_SHOULDER, 0] = 0.8  # midpoint (0.55, 0.4) from frame 2 on
    details = compute_feature_details(clip)
    np.testing.assert_allclose(details.centre, [[0.55, 0.4]] * 4, atol=1e-6)
    np.testing.assert_array_equal(details.features[:, 116], [0, 0, 1, 1])


def test_thinning_and_padding():
    np.testing.assert_array_equal(thin_evenly_frame_indices(10, 4), [0, 3, 6, 9])
    kept = thin_evenly_frame_indices(200, 96)
    assert kept[0] == 0 and kept[-1] == 199 and len(kept) == 96 and np.all(np.diff(kept) > 0)
    fitted, mask = fit_to_frame_count(np.ones((30, FEATURE_COUNT), np.float32), 96)
    assert fitted.shape == (96, FEATURE_COUNT) and mask.sum() == 30 and np.all(fitted[30:] == 0)


def test_trim_frames_without_hands():
    clip = straight_hand_clip([(0.5, 0.5)] * 6)
    clip[[0, 1, 5], RIGHT_HAND_START : RIGHT_HAND_START + 21] = 0.0
    assert trim_frames_without_hands(clip).shape[0] == 3
    assert trim_frames_without_hands(empty_clip(4)).shape[0] == 4


def test_left_hand_block_mirrors_right_hand_layout():
    clip = straight_hand_clip([(0.5, 0.5)])
    clip[:, LEFT_HAND_START : LEFT_HAND_START + 21] = clip[:, RIGHT_HAND_START : RIGHT_HAND_START + 21]
    features = compute_features(clip)
    np.testing.assert_allclose(features[0, 42:84], features[0, 0:42])
    np.testing.assert_allclose(features[0, 86:88], features[0, 84:86])
    np.testing.assert_array_equal(features[0, 114:116], [1, 1])
