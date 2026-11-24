"""SPEC section 3: one frame of landmarks becomes 117 numbers.

This file is the contract with ClickyCore `SignFeatures` (Swift). Both must make the same numbers, checked by the
golden files in `tests/golden/` (written by `signs/make_golden.py`). Every step below quotes the SPEC wording and
then says exactly how it is done, including the cases the SPEC leaves open, so Swift can follow it line by line.

The work is done in float64 and the result is rounded to float32 once at the end, so Swift (in Double, or Float
with a tolerance of about 1e-5) lands on the same numbers.

Steps, in order:

0. Clean-up and picture shape. A point counts as seen when its confidence is above 0; a point not seen gets
   x = y = confidence = 0. "Distances are measured with x multiplied by width / height when the picture's size is
   known": when width > 0 and height > 0, every x is multiplied by width / height here, once, before anything
   else, so every later number (gap filling, sizes, centre, features) is in the same units. With width or height
   0 (unknown) x stays as it is.
1. "Short gaps are filled. A point missing for at most 4 frames in a row, seen before and after, is put on the
   straight line between the two (confidence 0.5)." Each of the 61 points on its own. A filled point counts as
   seen from here on. "A hand counts as seen in a frame when its wrist and at least 11 other joints are", counted
   after filling.
2. Sizes and centre:
   - hand size: "the 90th percentile, over the frames a hand is seen, of the distance from its wrist to its middle
     knuckle (both hands pooled)". The middle knuckle is joint 9 (middle finger MCP). Only frames where the hand
     is seen and joint 9 is seen give a distance. The percentile is the linear one: sort the n distances,
     rank = 0.9 × (n − 1), value = sorted[floor(rank)] + (rank − floor(rank)) × (sorted[floor(rank) + 1] −
     sorted[floor(rank)]) (numpy's default, Excel's PERCENTILE.INC).
     When there is no such distance, or the size is below 1e-6 (degenerate), hand size is 1.0 and the hand joint
     features (0–83) are all zero for the whole clip; the wrist features and seen flags are kept.
   - body size: "the median distance between the shoulders over the frames both are seen" (the median of an even
     count is the mean of the two middle values); "with no such frame it is 3.5 × hand size". A median below 1e-6
     counts as no such frame.
   - centre: "the midpoint of the shoulders" in frames where both are seen; "in a frame without both, the last
     frame's centre" (the nearest earlier frame with both shoulders); "before any, the first one seen" (the first
     frame with both shoulders); "with no shoulders in the whole clip, the median of the seen wrists' places": the
     hand wrists (points 0 and 21) of every frame where that hand is seen, both hands pooled, x and y each their
     own median. With no seen hand either, the middle of the picture: (0.5 × width / height, 0.5) when the size
     is known, else (0.5, 0.5).
3. Per frame, in this order:
   - 0–41: right hand, joints 0–20, each as ((x − wrist x) / hand size, (y − wrist y) / hand size), x then y for
     each joint before the next joint. All zeros when the hand isn't seen; zeros for a single joint not seen in a
     seen hand.
   - 42–83: left hand, the same.
   - 84–85: right wrist (point 0) as (wrist − centre) / body size; 86–87: left wrist (point 21). Zeros when that
     hand isn't seen.
   - 88–113: the 13 body points (42–54) as (point − centre) / body size, x then y. Zeros for one not seen.
   - 114, 115, 116: right hand seen, left hand seen, both shoulders seen (after filling), 1 or 0.

Thinning to a model's frame count (SPEC section 4) happens after the features, on the 117-number frames:
`thin_evenly_frame_indices` gives the exact frames to keep.
"""

from __future__ import annotations

from dataclasses import dataclass

import numpy as np

from .landmarks import (
    BODY_POINT_COUNT,
    BODY_START,
    CONFIDENCE,
    HAND_JOINT_COUNT,
    LEFT_HAND_START,
    LEFT_SHOULDER,
    MIDDLE_KNUCKLE_JOINT,
    POINTS_PER_FRAME,
    RIGHT_HAND_START,
    RIGHT_SHOULDER,
    WRIST_JOINT,
    check_clip_shape,
)

FEATURE_COUNT = 117
LONGEST_FILLED_GAP_FRAMES = 4
FILLED_POINT_CONFIDENCE = 0.5
# A hand needs its wrist and at least this many of its other 20 joints to count as seen.
FEWEST_OTHER_JOINTS_FOR_A_SEEN_HAND = 11
HAND_SIZE_PERCENTILE = 90.0
BODY_SIZE_PER_HAND_SIZE_WHEN_NO_SHOULDERS = 3.5
# A hand or body size smaller than this is treated as unmeasurable rather than divided by.
SMALLEST_USABLE_SIZE = 1e-6

RIGHT_HAND_FEATURES_START = 0
LEFT_HAND_FEATURES_START = 42
RIGHT_WRIST_FEATURES_START = 84
LEFT_WRIST_FEATURES_START = 86
BODY_FEATURES_START = 88
RIGHT_HAND_SEEN_FEATURE = 114
LEFT_HAND_SEEN_FEATURE = 115
BOTH_SHOULDERS_SEEN_FEATURE = 116
# The first 114 numbers are coordinates; the last 3 are seen flags. The model takes frame-to-frame changes of the
# coordinates only.
COORDINATE_FEATURE_COUNT = 114


@dataclass
class FeatureDetails:
    """The 117 features plus the numbers they were made from, for golden files and debugging."""

    features: np.ndarray  # [T, 117] float32
    filled_landmarks: np.ndarray  # [T, 61, 3] float64, after aspect correction and gap filling
    right_hand_seen: np.ndarray  # [T] bool
    left_hand_seen: np.ndarray  # [T] bool
    both_shoulders_seen: np.ndarray  # [T] bool
    hand_size: float
    hand_size_is_degenerate: bool
    body_size: float
    centre: np.ndarray  # [T, 2] float64


def aspect_corrected(landmarks: np.ndarray, width: float, height: float) -> np.ndarray:
    """Step 0: float64 copy with unseen points zeroed, and x multiplied by width / height when both are known."""
    check_clip_shape(landmarks)
    points = np.array(landmarks, dtype=np.float64)
    point_is_seen = points[:, :, CONFIDENCE] > 0
    points[~point_is_seen] = 0.0
    if width > 0 and height > 0:
        points[:, :, 0] *= float(width) / float(height)
    return points


def fill_short_gaps(points: np.ndarray) -> np.ndarray:
    """Step 1: a point missing for at most 4 frames in a row, seen before and after, goes on the straight line
    between the two seen places, with confidence 0.5. Returns a new array; `points` is [T, 61, 3]."""
    frame_count = points.shape[0]
    filled_points = points.copy()
    if frame_count == 0:
        return filled_points
    point_is_seen = points[:, :, CONFIDENCE] > 0
    frame_numbers = np.arange(frame_count)[:, None]  # [T, 1], broadcast over the 61 points

    # For every frame and point: the nearest frame at or before it where the point was seen (-1 if none) and the
    # nearest frame at or after it (T if none).
    previous_seen_frame = np.maximum.accumulate(np.where(point_is_seen, frame_numbers, -1), axis=0)
    next_seen_frame = np.minimum.accumulate(
        np.where(point_is_seen, frame_numbers, frame_count)[::-1], axis=0
    )[::-1]
    gap_length = next_seen_frame - previous_seen_frame - 1
    should_fill = (
        ~point_is_seen
        & (previous_seen_frame >= 0)
        & (next_seen_frame < frame_count)
        & (gap_length <= LONGEST_FILLED_GAP_FRAMES)
    )
    if not should_fill.any():
        return filled_points

    safe_previous_frame = np.clip(previous_seen_frame, 0, frame_count - 1)
    safe_next_frame = np.clip(next_seen_frame, 0, frame_count - 1)
    point_numbers = np.arange(POINTS_PER_FRAME)[None, :]
    previous_place = points[safe_previous_frame, point_numbers, :2]  # [T, 61, 2]
    next_place = points[safe_next_frame, point_numbers, :2]
    frame_distance = np.maximum(safe_next_frame - safe_previous_frame, 1)
    fraction_of_the_way = (frame_numbers - safe_previous_frame) / frame_distance  # [T, 61]
    interpolated_place = previous_place + fraction_of_the_way[:, :, None] * (next_place - previous_place)

    filled_points[should_fill, :2] = interpolated_place[should_fill]
    filled_points[should_fill, CONFIDENCE] = FILLED_POINT_CONFIDENCE
    return filled_points


def hand_seen_flags(points: np.ndarray, hand_start: int) -> np.ndarray:
    """A hand counts as seen in a frame when its wrist and at least 11 of its other 20 joints are seen. [T] bool."""
    joint_is_seen = points[:, hand_start : hand_start + HAND_JOINT_COUNT, CONFIDENCE] > 0
    wrist_is_seen = joint_is_seen[:, WRIST_JOINT]
    other_joints_seen_count = joint_is_seen.sum(axis=1) - wrist_is_seen.astype(np.int64)
    return wrist_is_seen & (other_joints_seen_count >= FEWEST_OTHER_JOINTS_FOR_A_SEEN_HAND)


def measure_hand_size(
    points: np.ndarray, right_hand_seen: np.ndarray, left_hand_seen: np.ndarray
) -> tuple[float, bool]:
    """Step 2, hand size. Returns (hand size, is degenerate); a degenerate size is returned as 1.0."""
    pooled_wrist_to_knuckle_distances = []
    for hand_start, hand_is_seen in ((RIGHT_HAND_START, right_hand_seen), (LEFT_HAND_START, left_hand_seen)):
        knuckle_point = hand_start + MIDDLE_KNUCKLE_JOINT
        wrist_point = hand_start + WRIST_JOINT
        frame_is_measurable = hand_is_seen & (points[:, knuckle_point, CONFIDENCE] > 0)
        knuckle_offset = points[frame_is_measurable, knuckle_point, :2] - points[frame_is_measurable, wrist_point, :2]
        pooled_wrist_to_knuckle_distances.append(np.sqrt((knuckle_offset**2).sum(axis=1)))
    all_distances = np.concatenate(pooled_wrist_to_knuckle_distances)
    if all_distances.size == 0:
        return 1.0, True
    hand_size = float(np.percentile(all_distances, HAND_SIZE_PERCENTILE))
    if hand_size < SMALLEST_USABLE_SIZE:
        return 1.0, True
    return hand_size, False


def measure_body_size(points: np.ndarray, both_shoulders_seen: np.ndarray, hand_size: float) -> float:
    """Step 2, body size: median shoulder-to-shoulder distance, else 3.5 × hand size."""
    shoulder_offset = points[both_shoulders_seen, LEFT_SHOULDER, :2] - points[both_shoulders_seen, RIGHT_SHOULDER, :2]
    shoulder_distances = np.sqrt((shoulder_offset**2).sum(axis=1))
    if shoulder_distances.size > 0:
        body_size = float(np.median(shoulder_distances))
        if body_size >= SMALLEST_USABLE_SIZE:
            return body_size
    return BODY_SIZE_PER_HAND_SIZE_WHEN_NO_SHOULDERS * hand_size


def find_centre_per_frame(
    points: np.ndarray,
    both_shoulders_seen: np.ndarray,
    right_hand_seen: np.ndarray,
    left_hand_seen: np.ndarray,
    width: float,
    height: float,
) -> np.ndarray:
    """Step 2, centre: [T, 2]. See the module notes for each case."""
    frame_count = points.shape[0]
    if both_shoulders_seen.any():
        shoulder_midpoints = (points[:, LEFT_SHOULDER, :2] + points[:, RIGHT_SHOULDER, :2]) / 2.0
        frame_numbers = np.arange(frame_count)
        # Each frame takes the midpoint of the latest frame (itself included) with both shoulders...
        latest_frame_with_shoulders = np.maximum.accumulate(np.where(both_shoulders_seen, frame_numbers, -1))
        # ...and frames before the first such frame take the first one.
        first_frame_with_shoulders = int(np.argmax(both_shoulders_seen))
        latest_frame_with_shoulders[latest_frame_with_shoulders < 0] = first_frame_with_shoulders
        return shoulder_midpoints[latest_frame_with_shoulders]

    seen_wrist_places = np.concatenate(
        [
            points[right_hand_seen, RIGHT_HAND_START + WRIST_JOINT, :2],
            points[left_hand_seen, LEFT_HAND_START + WRIST_JOINT, :2],
        ]
    )
    if seen_wrist_places.shape[0] > 0:
        clip_centre = np.median(seen_wrist_places, axis=0)
    else:
        picture_aspect = float(width) / float(height) if width > 0 and height > 0 else 1.0
        clip_centre = np.array([0.5 * picture_aspect, 0.5])
    return np.tile(clip_centre, (frame_count, 1))


def compute_feature_details(landmarks: np.ndarray, width: float = 0, height: float = 0) -> FeatureDetails:
    points = aspect_corrected(landmarks, width, height)
    points = fill_short_gaps(points)
    frame_count = points.shape[0]

    right_hand_seen = hand_seen_flags(points, RIGHT_HAND_START)
    left_hand_seen = hand_seen_flags(points, LEFT_HAND_START)
    both_shoulders_seen = (points[:, LEFT_SHOULDER, CONFIDENCE] > 0) & (points[:, RIGHT_SHOULDER, CONFIDENCE] > 0)

    hand_size, hand_size_is_degenerate = measure_hand_size(points, right_hand_seen, left_hand_seen)
    body_size = measure_body_size(points, both_shoulders_seen, hand_size)
    centre = find_centre_per_frame(points, both_shoulders_seen, right_hand_seen, left_hand_seen, width, height)

    features = np.zeros((frame_count, FEATURE_COUNT), dtype=np.float64)

    hand_blocks = (
        (RIGHT_HAND_START, right_hand_seen, RIGHT_HAND_FEATURES_START, RIGHT_WRIST_FEATURES_START),
        (LEFT_HAND_START, left_hand_seen, LEFT_HAND_FEATURES_START, LEFT_WRIST_FEATURES_START),
    )
    for hand_start, hand_is_seen, hand_features_start, wrist_features_start in hand_blocks:
        hand_points = points[:, hand_start : hand_start + HAND_JOINT_COUNT, :]  # [T, 21, 3]
        wrist_place = hand_points[:, WRIST_JOINT, :2]  # [T, 2]
        joint_is_usable = (hand_points[:, :, CONFIDENCE] > 0) & hand_is_seen[:, None]
        if hand_size_is_degenerate:
            # Without a usable hand size the joint shapes can't be scaled, so they are left as zeros.
            joint_is_usable[:] = False
        joints_from_wrist = (hand_points[:, :, :2] - wrist_place[:, None, :]) / hand_size  # [T, 21, 2]
        joints_from_wrist[~joint_is_usable] = 0.0
        features[:, hand_features_start : hand_features_start + 2 * HAND_JOINT_COUNT] = joints_from_wrist.reshape(
            frame_count, 2 * HAND_JOINT_COUNT
        )

        wrist_from_centre = (wrist_place - centre) / body_size
        wrist_from_centre[~hand_is_seen] = 0.0
        features[:, wrist_features_start : wrist_features_start + 2] = wrist_from_centre

    body_points = points[:, BODY_START : BODY_START + BODY_POINT_COUNT, :]  # [T, 13, 3]
    body_from_centre = (body_points[:, :, :2] - centre[:, None, :]) / body_size
    body_from_centre[~(body_points[:, :, CONFIDENCE] > 0)] = 0.0
    features[:, BODY_FEATURES_START : BODY_FEATURES_START + 2 * BODY_POINT_COUNT] = body_from_centre.reshape(
        frame_count, 2 * BODY_POINT_COUNT
    )

    features[:, RIGHT_HAND_SEEN_FEATURE] = right_hand_seen
    features[:, LEFT_HAND_SEEN_FEATURE] = left_hand_seen
    features[:, BOTH_SHOULDERS_SEEN_FEATURE] = both_shoulders_seen

    return FeatureDetails(
        features=features.astype(np.float32),
        filled_landmarks=points,
        right_hand_seen=right_hand_seen,
        left_hand_seen=left_hand_seen,
        both_shoulders_seen=both_shoulders_seen,
        hand_size=hand_size,
        hand_size_is_degenerate=hand_size_is_degenerate,
        body_size=body_size,
        centre=centre,
    )


def compute_features(landmarks: np.ndarray, width: float = 0, height: float = 0) -> np.ndarray:
    """`[T, 61, 3]` landmarks -> `[T, 117]` float32 features (SPEC section 3)."""
    return compute_feature_details(landmarks, width, height).features


def thin_evenly_frame_indices(frame_count: int, target_frame_count: int) -> np.ndarray:
    """Which frames to keep when a clip of `frame_count` frames is thinned evenly to `target_frame_count`.

    Frame k of the result is source frame floor(k × (frame_count − 1) / (target_frame_count − 1) + 0.5), so the
    first and last frames are always kept. Done in whole numbers so Swift gets exactly the same frames (no
    floating-point or banker's-rounding differences).
    """
    if frame_count <= target_frame_count:
        return np.arange(frame_count, dtype=np.int64)
    if target_frame_count == 1:
        return np.zeros(1, dtype=np.int64)
    output_positions = np.arange(target_frame_count, dtype=np.int64)
    span = target_frame_count - 1
    return (2 * output_positions * (frame_count - 1) + span) // (2 * span)


def fit_to_frame_count(features: np.ndarray, target_frame_count: int) -> tuple[np.ndarray, np.ndarray]:
    """SPEC section 4: a longer clip is thinned evenly, a shorter one padded with zeros at the end.

    Returns (features [N, 117] float32, mask [N] float32 with 1 for real frames and 0 for padding)."""
    kept_features = features[thin_evenly_frame_indices(features.shape[0], target_frame_count)]
    fitted_features = np.zeros((target_frame_count, features.shape[1]), dtype=np.float32)
    fitted_features[: kept_features.shape[0]] = kept_features
    frame_mask = np.zeros(target_frame_count, dtype=np.float32)
    frame_mask[: kept_features.shape[0]] = 1.0
    return fitted_features, frame_mask


def frames_with_a_hand(landmarks: np.ndarray) -> np.ndarray:
    """[T] bool: frames where either hand counts as seen in the raw landmarks (no gap filling)."""
    raw_points = np.asarray(landmarks)
    return hand_seen_flags(raw_points, RIGHT_HAND_START) | hand_seen_flags(raw_points, LEFT_HAND_START)


def trim_frames_without_hands(landmarks: np.ndarray) -> np.ndarray:
    """Drops leading and trailing frames where no hand is seen. A clip with no hand at all is kept whole."""
    frame_has_a_hand = frames_with_a_hand(landmarks)
    if not frame_has_a_hand.any():
        return landmarks
    first_frame_with_a_hand = int(np.argmax(frame_has_a_hand))
    last_frame_with_a_hand = len(frame_has_a_hand) - 1 - int(np.argmax(frame_has_a_hand[::-1]))
    return landmarks[first_frame_with_a_hand : last_frame_with_a_hand + 1]
