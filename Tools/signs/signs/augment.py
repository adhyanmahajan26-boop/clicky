"""Augmentations on raw landmarks `[T, 61, 3]`, before features.

Every function takes a clip and returns a new one; none changes its input. A point with confidence 0 is missing
and stays exactly (0, 0, 0): spatial changes only move seen points. Randomness always comes from a
`numpy.random.Generator` passed in, so a seed gives the same result every time.
"""

from __future__ import annotations

from dataclasses import dataclass

import numpy as np

from .landmarks import (
    CONFIDENCE,
    HAND_JOINT_COUNT,
    LEFT_HAND_START,
    LEFT_SHOULDER,
    MIDDLE_KNUCKLE_JOINT,
    MIRRORED_POINT_PAIRS,
    POINTS_PER_FRAME,
    RIGHT_HAND_START,
    RIGHT_SHOULDER,
    WRIST_JOINT,
)


@dataclass
class AugmentSettings:
    mirror_probability: float = 0.5
    rotation_probability: float = 0.5
    largest_rotation_degrees: float = 15.0
    scale_probability: float = 0.5
    largest_scale_change: float = 0.2  # ±20%
    x_stretch_probability: float = 0.5
    # Stands in for not knowing the picture's width / height: x is stretched by a factor from this range.
    smallest_x_stretch: float = 0.75
    largest_x_stretch: float = 1.33
    shift_probability: float = 0.5
    largest_shift: float = 0.08  # in picture units
    jitter_probability: float = 0.5
    hand_joint_jitter_in_hand_sizes: float = 0.03
    other_point_jitter_in_hand_sizes: float = 0.05
    time_scale_probability: float = 0.5
    smallest_time_scale: float = 0.7
    largest_time_scale: float = 1.4
    trim_probability: float = 0.5
    most_trimmed_frames_each_end: int = 6
    hand_drop_probability: float = 0.3
    longest_hand_drop_frames: int = 6
    most_hand_drops: int = 2
    frame_drop_probability: float = 0.3
    frame_drop_rate: float = 0.05
    joint_drop_probability: float = 0.3
    joint_drop_rate: float = 0.02
    # Trimming and dropping frames never take a clip below this many frames.
    fewest_frames_kept: int = 8


def _seen_mask(landmarks: np.ndarray) -> np.ndarray:
    return landmarks[:, :, CONFIDENCE] > 0


def _zero_missing_points(landmarks: np.ndarray) -> np.ndarray:
    landmarks[~_seen_mask(landmarks)] = 0.0
    return landmarks


def mirror(landmarks: np.ndarray) -> np.ndarray:
    """The clip as if the picture were flipped left to right: x -> 1 − x for seen points, and every left thing
    becomes the matching right thing (the two hand blocks, eyes, ears, shoulders, elbows, wrists, hips, mouth
    corners and brows), since "right" always means the signer's own right."""
    mirrored = landmarks.astype(np.float32, copy=True)
    point_is_seen = _seen_mask(mirrored)
    mirrored[:, :, 0] = np.where(point_is_seen, 1.0 - mirrored[:, :, 0], 0.0)

    swapped_point_order = np.arange(POINTS_PER_FRAME)
    right_hand_points = np.arange(RIGHT_HAND_START, RIGHT_HAND_START + HAND_JOINT_COUNT)
    left_hand_points = np.arange(LEFT_HAND_START, LEFT_HAND_START + HAND_JOINT_COUNT)
    swapped_point_order[right_hand_points] = left_hand_points
    swapped_point_order[left_hand_points] = right_hand_points
    for left_point, right_point in MIRRORED_POINT_PAIRS:
        swapped_point_order[left_point] = right_point
        swapped_point_order[right_point] = left_point
    return mirrored[:, swapped_point_order, :]


def shoulder_centre(landmarks: np.ndarray) -> np.ndarray:
    """The clip's mean shoulder midpoint, else the mean of every seen point, else the picture's middle. [2]"""
    point_is_seen = _seen_mask(landmarks)
    both_shoulders_seen = point_is_seen[:, LEFT_SHOULDER] & point_is_seen[:, RIGHT_SHOULDER]
    if both_shoulders_seen.any():
        midpoints = (landmarks[both_shoulders_seen, LEFT_SHOULDER, :2] + landmarks[both_shoulders_seen, RIGHT_SHOULDER, :2]) / 2
        return midpoints.mean(axis=0)
    if point_is_seen.any():
        return landmarks[point_is_seen, :2].mean(axis=0)
    return np.array([0.5, 0.5], dtype=np.float32)


def _apply_linear_map_about_centre(
    landmarks: np.ndarray, linear_map: np.ndarray, centre: np.ndarray, picture_aspect: float
) -> np.ndarray:
    """Moves seen points by `linear_map` (2×2) about `centre`, working in units where x and y are the same size
    (x × picture_aspect), so a rotation stays a rotation on a picture that isn't square."""
    moved = landmarks.astype(np.float32, copy=True)
    point_is_seen = _seen_mask(moved)
    aspect_scaling = np.array([picture_aspect, 1.0], dtype=np.float64)
    places = moved[:, :, :2].astype(np.float64) * aspect_scaling
    centre_in_square_units = np.asarray(centre, dtype=np.float64) * aspect_scaling
    moved_places = (places - centre_in_square_units) @ linear_map.T + centre_in_square_units
    moved[:, :, :2] = np.where(point_is_seen[:, :, None], moved_places / aspect_scaling, 0.0)
    return moved


def rotate(landmarks: np.ndarray, angle_degrees: float, picture_aspect: float = 1.0) -> np.ndarray:
    """Rotation about the shoulder centre."""
    angle_radians = np.deg2rad(angle_degrees)
    rotation = np.array(
        [[np.cos(angle_radians), -np.sin(angle_radians)], [np.sin(angle_radians), np.cos(angle_radians)]]
    )
    return _apply_linear_map_about_centre(landmarks, rotation, shoulder_centre(landmarks), picture_aspect)


def scale(landmarks: np.ndarray, scale_factor: float) -> np.ndarray:
    """Uniform scale about the shoulder centre (the signer nearer or further from the camera)."""
    return _apply_linear_map_about_centre(landmarks, np.eye(2) * scale_factor, shoulder_centre(landmarks), 1.0)


def stretch_x(landmarks: np.ndarray, stretch_factor: float) -> np.ndarray:
    """x stretched about the shoulder centre: what an unknown picture width / height does to the numbers."""
    return _apply_linear_map_about_centre(
        landmarks, np.diag([stretch_factor, 1.0]), shoulder_centre(landmarks), 1.0
    )


def shift(landmarks: np.ndarray, x_shift: float, y_shift: float) -> np.ndarray:
    shifted = landmarks.astype(np.float32, copy=True)
    point_is_seen = _seen_mask(shifted)
    shifted[:, :, 0] = np.where(point_is_seen, shifted[:, :, 0] + x_shift, 0.0)
    shifted[:, :, 1] = np.where(point_is_seen, shifted[:, :, 1] + y_shift, 0.0)
    return shifted


def typical_hand_size(landmarks: np.ndarray) -> float:
    """Median wrist-to-middle-knuckle distance over every frame either hand shows both; 0.05 if never seen."""
    point_is_seen = _seen_mask(landmarks)
    distances = []
    for hand_start in (RIGHT_HAND_START, LEFT_HAND_START):
        wrist_point = hand_start + WRIST_JOINT
        knuckle_point = hand_start + MIDDLE_KNUCKLE_JOINT
        both_seen = point_is_seen[:, wrist_point] & point_is_seen[:, knuckle_point]
        offsets = landmarks[both_seen, knuckle_point, :2] - landmarks[both_seen, wrist_point, :2]
        distances.append(np.sqrt((offsets.astype(np.float64) ** 2).sum(axis=1)))
    all_distances = np.concatenate(distances)
    if all_distances.size == 0 or np.median(all_distances) <= 0:
        return 0.05
    return float(np.median(all_distances))


def jitter_joints(
    landmarks: np.ndarray,
    generator: np.random.Generator,
    hand_joint_jitter_in_hand_sizes: float,
    other_point_jitter_in_hand_sizes: float,
) -> np.ndarray:
    """Independent small noise on every seen point of every frame, measured in hand sizes so it is the same
    for a signer near or far from the camera."""
    jittered = landmarks.astype(np.float32, copy=True)
    hand_size = typical_hand_size(landmarks)
    noise_size_per_point = np.full(POINTS_PER_FRAME, other_point_jitter_in_hand_sizes * hand_size)
    noise_size_per_point[RIGHT_HAND_START : LEFT_HAND_START + HAND_JOINT_COUNT] = (
        hand_joint_jitter_in_hand_sizes * hand_size
    )
    noise = generator.normal(size=(landmarks.shape[0], POINTS_PER_FRAME, 2)) * noise_size_per_point[None, :, None]
    point_is_seen = _seen_mask(jittered)
    jittered[:, :, :2] = np.where(point_is_seen[:, :, None], jittered[:, :, :2] + noise, 0.0)
    return jittered


def resample_time(landmarks: np.ndarray, time_scale: float) -> np.ndarray:
    """The clip played slower (time_scale > 1, more frames) or faster (< 1, fewer frames).

    New frame k sits at source time k × (T − 1) / (new T − 1). A point seen in both source frames around that
    time is put on the line between them (confidence too); otherwise it takes the nearer source frame's value,
    so a missing point is never blended with a seen one."""
    frame_count = landmarks.shape[0]
    new_frame_count = max(2, int(round(frame_count * time_scale)))
    if frame_count < 2:
        return landmarks.astype(np.float32, copy=True)
    source_times = np.arange(new_frame_count) * (frame_count - 1) / (new_frame_count - 1)
    earlier_frame = np.floor(source_times).astype(np.int64)
    later_frame = np.minimum(earlier_frame + 1, frame_count - 1)
    fraction_of_the_way = (source_times - earlier_frame)[:, None, None]

    earlier_values = landmarks[earlier_frame].astype(np.float64)
    later_values = landmarks[later_frame].astype(np.float64)
    interpolated_values = earlier_values + fraction_of_the_way * (later_values - earlier_values)
    nearer_values = np.where(fraction_of_the_way < 0.5, earlier_values, later_values)
    seen_in_both = (earlier_values[:, :, CONFIDENCE] > 0) & (later_values[:, :, CONFIDENCE] > 0)
    resampled = np.where(seen_in_both[:, :, None], interpolated_values, nearer_values)
    return resampled.astype(np.float32)


def trim_ends(landmarks: np.ndarray, leading_frames: int, trailing_frames: int, fewest_frames_kept: int) -> np.ndarray:
    frame_count = landmarks.shape[0]
    room_to_trim = max(0, frame_count - fewest_frames_kept)
    leading_frames = min(leading_frames, room_to_trim)
    trailing_frames = min(trailing_frames, room_to_trim - leading_frames)
    return landmarks[leading_frames : frame_count - trailing_frames].astype(np.float32, copy=True)


def drop_hand_for_stretch(landmarks: np.ndarray, hand_start: int, first_frame: int, frame_count: int) -> np.ndarray:
    """One hand missing for a few frames: what the detector does when a fast hand blurs."""
    dropped = landmarks.astype(np.float32, copy=True)
    dropped[first_frame : first_frame + frame_count, hand_start : hand_start + HAND_JOINT_COUNT, :] = 0.0
    return dropped


def drop_frames(landmarks: np.ndarray, frame_is_dropped: np.ndarray) -> np.ndarray:
    """Removes whole frames (the camera skipping frames)."""
    return landmarks[~frame_is_dropped].astype(np.float32, copy=True)


def drop_joints(landmarks: np.ndarray, point_is_dropped: np.ndarray) -> np.ndarray:
    """Single points made missing ([T, 61] bool)."""
    dropped = landmarks.astype(np.float32, copy=True)
    dropped[point_is_dropped] = 0.0
    return dropped


def augment_clip(
    landmarks: np.ndarray,
    generator: np.random.Generator,
    settings: AugmentSettings,
    picture_aspect: float = 1.0,
) -> np.ndarray:
    """Applies each augmentation with its own probability. `picture_aspect` is width / height when known, so
    rotations are true rotations on the picture; pass 1.0 when it isn't known."""
    augmented = landmarks.astype(np.float32, copy=True)

    if generator.random() < settings.trim_probability:
        augmented = trim_ends(
            augmented,
            int(generator.integers(0, settings.most_trimmed_frames_each_end + 1)),
            int(generator.integers(0, settings.most_trimmed_frames_each_end + 1)),
            settings.fewest_frames_kept,
        )
    if generator.random() < settings.time_scale_probability:
        augmented = resample_time(
            augmented, generator.uniform(settings.smallest_time_scale, settings.largest_time_scale)
        )
    if generator.random() < settings.frame_drop_probability and augmented.shape[0] > settings.fewest_frames_kept:
        frame_is_dropped = generator.random(augmented.shape[0]) < settings.frame_drop_rate
        if (~frame_is_dropped).sum() >= settings.fewest_frames_kept:
            augmented = drop_frames(augmented, frame_is_dropped)

    if generator.random() < settings.mirror_probability:
        augmented = mirror(augmented)
    if generator.random() < settings.rotation_probability:
        augmented = rotate(
            augmented,
            generator.uniform(-settings.largest_rotation_degrees, settings.largest_rotation_degrees),
            picture_aspect,
        )
    if generator.random() < settings.scale_probability:
        augmented = scale(
            augmented, generator.uniform(1 - settings.largest_scale_change, 1 + settings.largest_scale_change)
        )
    if generator.random() < settings.x_stretch_probability:
        # Uniform in log space, so stretching and squeezing by the same factor are equally likely.
        log_stretch = generator.uniform(np.log(settings.smallest_x_stretch), np.log(settings.largest_x_stretch))
        augmented = stretch_x(augmented, float(np.exp(log_stretch)))
    if generator.random() < settings.shift_probability:
        augmented = shift(
            augmented,
            generator.uniform(-settings.largest_shift, settings.largest_shift),
            generator.uniform(-settings.largest_shift, settings.largest_shift),
        )
    if generator.random() < settings.jitter_probability:
        augmented = jitter_joints(
            augmented,
            generator,
            settings.hand_joint_jitter_in_hand_sizes,
            settings.other_point_jitter_in_hand_sizes,
        )

    if generator.random() < settings.hand_drop_probability and augmented.shape[0] > 1:
        hand_drop_count = int(generator.integers(1, settings.most_hand_drops + 1))
        for hand_drop_number in range(hand_drop_count):
            hand_start = RIGHT_HAND_START if generator.random() < 0.5 else LEFT_HAND_START
            stretch_length = int(generator.integers(1, settings.longest_hand_drop_frames + 1))
            first_frame = int(generator.integers(0, augmented.shape[0]))
            augmented = drop_hand_for_stretch(augmented, hand_start, first_frame, stretch_length)
    if generator.random() < settings.joint_drop_probability:
        point_is_dropped = generator.random(augmented.shape[:2]) < settings.joint_drop_rate
        augmented = drop_joints(augmented, point_is_dropped)

    return _zero_missing_points(augmented)
