"""SPEC section 3, "Frame rate": landmarks are brought to 30 frames a second before anything else.

The models are trained and run on about 30 frames a second. A dataset filmed at 25 or 60, or a camera that slows
down in dim light, would otherwise show every sign faster or slower than the models learned it. This file is the
contract with the Swift side (the app resamples the camera's frames the same way), checked by the golden files in
`tests/golden/frame_rate/` (written by `signs/make_golden.py`).

The rule, step by step, exactly as both sides do it (all arithmetic in float64 / Double, the result rounded to
float32 once at the end):

1. Frame `k` was taken at time `τk` seconds: `k / fps` for a file, the camera's own time stamps in the app. Times
   must never go backwards.
2. The rate is `(T − 1) / (τlast − τ0)`. With fewer than 2 frames, or `τlast == τ0`, the rate is unknown (0).
   An unknown rate, or one from 27 to 33 (both included), leaves the landmarks unchanged.
3. Otherwise new frame `j` is at `time = τ0 + j / 30` for j = 0, 1, 2, … while `time <= τlast + 0.000001`
   (the millionth of a second keeps rounding from dropping the last frame). Written that way, not as
   `τ0 + j × (1 / 30)`, so both sides land on the same Double.
4. `i` is the last frame with `τi <= time`. When `i` is the last frame, new frame `j` is a copy of it. Otherwise
   `f = (time − τi) / (τ(i+1) − τi)` (0 to 1), rounded to 6 decimal places (`round(f × 1000000) / 1000000`, halves
   to even) so a time that lands on a frame or exactly half way can't fall either side by one bit. `f == 0` is a
   copy of frame `i` and `f == 1` a copy of frame `i + 1`; otherwise, for each of the 61 points:
   - seen in both frames `i` and `i + 1` (confidence above 0): x and y are `a + f × (b − a)` (a from frame `i`,
     b from frame `i + 1`) and the confidence is the smaller of the two;
   - otherwise the point is copied as it is (x, y and confidence) from the nearer frame: frame `i` when
     `f < 0.5`, else frame `i + 1`.

A file's frame count after the rule is known from its frame count and fps alone (`resampled_frame_count`), so
packing can size its output before reading any clip.
"""

from __future__ import annotations

import math

import numpy as np

TARGET_FRAMES_PER_SECOND = 30.0
# Rates from 27 to 33 frames a second, both included, are close enough to 30 to be left alone.
SLOWEST_RATE_LEFT_AS_IS = 27.0
FASTEST_RATE_LEFT_AS_IS = 33.0
# Added to the last frame's time so floating-point rounding can't drop the last new frame.
LAST_FRAME_TIME_ALLOWANCE_SECONDS = 1e-6
UNKNOWN_FRAME_RATE = 0.0
# How far between two frames a new time is, is rounded to a millionth before it is used.
FRACTION_ROUNDING_STEPS = 1_000_000.0

_CONFIDENCE = 2  # the (x, y, confidence) layout of SPEC section 1


def frame_rate_from_times(frame_times) -> float:
    """`(T − 1) / (τlast − τ0)`; 0 (unknown) with fewer than 2 frames or no time between the first and last."""
    frame_times = np.asarray(frame_times, dtype=np.float64)
    if frame_times.shape[0] < 2:
        return UNKNOWN_FRAME_RATE
    time_span = float(frame_times[-1] - frame_times[0])
    if time_span <= 0:
        return UNKNOWN_FRAME_RATE
    return (frame_times.shape[0] - 1) / time_span


def rate_needs_resampling(frames_per_second: float) -> bool:
    """True for a known rate below 27 or above 33 frames a second."""
    if not frames_per_second or frames_per_second <= 0 or math.isnan(frames_per_second):
        return False
    return frames_per_second < SLOWEST_RATE_LEFT_AS_IS or frames_per_second > FASTEST_RATE_LEFT_AS_IS


def new_frame_times(first_frame_time: float, last_frame_time: float) -> np.ndarray:
    """`τ0 + j / 30` for every j whose time is at most `τlast` plus a millionth of a second (step 3)."""
    # A couple more candidates than can fit, then the ones past the end are dropped: the times only grow, so this
    # keeps exactly the frames a one-at-a-time loop would.
    candidate_count = int(math.floor((last_frame_time - first_frame_time + 1.0) * TARGET_FRAMES_PER_SECOND)) + 2
    candidate_count = max(candidate_count, 1)
    candidate_times = first_frame_time + np.arange(candidate_count, dtype=np.float64) / TARGET_FRAMES_PER_SECOND
    return candidate_times[candidate_times <= last_frame_time + LAST_FRAME_TIME_ALLOWANCE_SECONDS]


def resample_landmarks_at_times(landmarks: np.ndarray, frame_times, wanted_times) -> np.ndarray:
    """Landmarks `[T, 61, 3]` taken at `frame_times` -> landmarks at `wanted_times` by step 4 of the rule.

    Every wanted time must be at or after the first frame's time. Returns float32 `[len(wanted_times), 61, 3]`."""
    frame_times = np.asarray(frame_times, dtype=np.float64)
    wanted_times = np.asarray(wanted_times, dtype=np.float64)
    landmarks_in_double = np.asarray(landmarks, dtype=np.float64)
    frame_count = landmarks_in_double.shape[0]
    resampled = np.zeros((wanted_times.shape[0],) + landmarks_in_double.shape[1:], dtype=np.float64)
    for new_frame_number, wanted_time in enumerate(wanted_times.tolist()):
        # "The last frame at or before that time": with side="right", equal times count as "at or before".
        earlier_frame = int(np.searchsorted(frame_times, wanted_time, side="right")) - 1
        if earlier_frame < 0:
            raise ValueError(f"time {wanted_time} is before the first frame ({frame_times[0]})")
        if earlier_frame >= frame_count - 1:
            resampled[new_frame_number] = landmarks_in_double[frame_count - 1]
            continue
        later_frame = earlier_frame + 1
        fraction_of_the_way = (wanted_time - frame_times[earlier_frame]) / (
            frame_times[later_frame] - frame_times[earlier_frame]
        )
        # Rounded so a time on a frame, or exactly half way, can't fall either side by one bit (Python's `round`
        # and Swift's `.toNearestOrEven` round halves the same way).
        fraction_of_the_way = round(fraction_of_the_way * FRACTION_ROUNDING_STEPS) / FRACTION_ROUNDING_STEPS
        if fraction_of_the_way <= 0.0:
            resampled[new_frame_number] = landmarks_in_double[earlier_frame]
            continue
        if fraction_of_the_way >= 1.0:
            resampled[new_frame_number] = landmarks_in_double[later_frame]
            continue
        earlier_points = landmarks_in_double[earlier_frame]
        later_points = landmarks_in_double[later_frame]
        seen_in_both = (earlier_points[:, _CONFIDENCE] > 0) & (later_points[:, _CONFIDENCE] > 0)

        nearer_points = earlier_points if fraction_of_the_way < 0.5 else later_points
        new_points = nearer_points.copy()
        new_points[seen_in_both, :2] = earlier_points[seen_in_both, :2] + fraction_of_the_way * (
            later_points[seen_in_both, :2] - earlier_points[seen_in_both, :2]
        )
        new_points[seen_in_both, _CONFIDENCE] = np.minimum(
            earlier_points[seen_in_both, _CONFIDENCE], later_points[seen_in_both, _CONFIDENCE]
        )
        resampled[new_frame_number] = new_points
    return resampled.astype(np.float32)


def resample_to_30_per_second(landmarks: np.ndarray, frame_times) -> np.ndarray:
    """Landmarks `[T, 61, 3]` and each frame's time in seconds -> landmarks at 30 frames a second.

    Returned unchanged (as a float32 copy) when the rate is unknown or from 27 to 33 frames a second."""
    landmarks = np.asarray(landmarks)
    frame_times = np.asarray(frame_times, dtype=np.float64)
    if frame_times.shape[0] != landmarks.shape[0]:
        raise ValueError(f"{landmarks.shape[0]} frames but {frame_times.shape[0]} times")
    if frame_times.shape[0] >= 2 and np.any(np.diff(frame_times) < 0):
        raise ValueError("frame times go backwards")
    if not rate_needs_resampling(frame_rate_from_times(frame_times)):
        return np.array(landmarks, dtype=np.float32)
    wanted_times = new_frame_times(float(frame_times[0]), float(frame_times[-1]))
    return resample_landmarks_at_times(landmarks, frame_times, wanted_times)


def file_frame_times(frame_count: int, frames_per_second: float) -> np.ndarray:
    """`k / fps` for a file's frames (SPEC: "k / fps for a file")."""
    return np.arange(frame_count, dtype=np.float64) / float(frames_per_second)


def resample_clip_to_30_per_second(landmarks: np.ndarray, frames_per_second: float) -> np.ndarray:
    """The same for a file whose manifest gives its `fps` (0 = unknown, left unchanged).

    The rate is judged from `fps` itself rather than from the times made from it, so a file at exactly 27 or 33
    can't be pushed over the edge by rounding."""
    landmarks = np.asarray(landmarks)
    if landmarks.shape[0] < 2 or not rate_needs_resampling(frames_per_second):
        return np.array(landmarks, dtype=np.float32)
    frame_times = file_frame_times(landmarks.shape[0], frames_per_second)
    wanted_times = new_frame_times(float(frame_times[0]), float(frame_times[-1]))
    return resample_landmarks_at_times(landmarks, frame_times, wanted_times)


def resampled_frame_count(frame_count: int, frames_per_second: float) -> int:
    """How many frames `resample_clip_to_30_per_second` returns, without reading the clip."""
    if frame_count < 2 or not rate_needs_resampling(frames_per_second):
        return frame_count
    frame_times = file_frame_times(frame_count, frames_per_second)
    return int(new_frame_times(float(frame_times[0]), float(frame_times[-1])).shape[0])
