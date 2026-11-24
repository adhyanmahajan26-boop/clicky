"""Writes `tests/golden/*.json`: small landmark clips with the features Python computes from them, for the Swift
`SignFeatures` test to check against (SPEC section 3).

Each file holds `name`, `description`, `width`, `height` (0 = unknown), `landmarks` ([T][61][3]), `features`
([T][117]), and, to help find where a difference starts, `hand_size`, `hand_size_is_degenerate`, `body_size` and
`centre` ([T][2], in aspect-corrected units). Landmarks are rounded to 4 decimals before the features are made,
so the file's landmarks are exactly what the features came from; features and sizes are rounded to 6 decimals.

It also writes `tests/golden/frame_rate/*.json` (SPEC section 3, "Frame rate"), each with `name`, `description`,
`times` ([T] seconds), `landmarks` ([T][61][3]) and `resampled` ([T2][61][3], the landmarks at 30 frames a
second, or the landmarks themselves when the rule leaves them alone). Times are rounded to 6 decimals and
landmarks to 4 before resampling; the resampled numbers are rounded to 6. They live in their own folder because
the Swift `SignFeatures` test reads every `*.json` directly in `tests/golden/`.

    python -m signs.make_golden            # writes Tools/signs/tests/golden/ and its frame_rate/ folder
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path

import numpy as np

from .features import compute_feature_details
from .frame_rate import resample_to_30_per_second
from .landmarks import (
    CONFIDENCE,
    HAND_JOINT_COUNT,
    LEFT_HAND_START,
    LEFT_SHOULDER,
    MOUTH_START,
    NOSE,
    RIGHT_HAND_START,
    empty_clip,
)

DEFAULT_GOLDEN_FOLDER = Path(__file__).resolve().parent.parent / "tests" / "golden"
DEFAULT_FRAME_RATE_GOLDEN_FOLDER = DEFAULT_GOLDEN_FOLDER / "frame_rate"

# A right hand pointing up, in units where the wrist-to-middle-knuckle distance is 1 (y down, as in the picture).
RIGHT_HAND_SHAPE = np.array(
    [
        [0.00, 0.00],  # wrist
        [-0.30, -0.20], [-0.55, -0.45], [-0.70, -0.70], [-0.80, -0.90],  # thumb CMC, MP, IP, tip
        [-0.25, -1.00], [-0.28, -1.40], [-0.30, -1.65], [-0.32, -1.85],  # index MCP, PIP, DIP, tip
        [0.00, -1.00], [0.00, -1.45], [0.00, -1.75], [0.00, -1.95],  # middle
        [0.22, -0.95], [0.25, -1.35], [0.27, -1.60], [0.28, -1.80],  # ring
        [0.42, -0.85], [0.47, -1.15], [0.50, -1.35], [0.52, -1.50],  # little
    ]
)

# The signer faces the camera in an unmirrored picture, so their right side is on the picture's left.
BODY_AND_FACE_PLACES = {
    42: (0.50, 0.30),  # nose
    43: (0.52, 0.28),  # left eye
    44: (0.48, 0.28),  # right eye
    45: (0.55, 0.29),  # left ear
    46: (0.45, 0.29),  # right ear
    47: (0.60, 0.45),  # left shoulder
    48: (0.40, 0.45),  # right shoulder
    49: (0.65, 0.60),  # left elbow
    50: (0.35, 0.60),  # right elbow
    51: (0.62, 0.70),  # left wrist
    52: (0.38, 0.70),  # right wrist
    53: (0.57, 0.85),  # left hip
    54: (0.43, 0.85),  # right hip
    55: (0.52, 0.36),  # mouth left corner
    56: (0.48, 0.36),  # mouth right corner
    57: (0.50, 0.35),  # upper lip
    58: (0.50, 0.37),  # lower lip
    59: (0.53, 0.26),  # left brow
    60: (0.47, 0.26),  # right brow
}


def place_hand(clip: np.ndarray, frame: int, hand_start: int, wrist_place, hand_size: float, tilt_degrees: float = 0.0) -> None:
    """Puts a hand (the left hand is the right hand's shape mirrored) with its wrist at `wrist_place`."""
    hand_shape = RIGHT_HAND_SHAPE.copy()
    if hand_start == LEFT_HAND_START:
        hand_shape[:, 0] *= -1
    tilt_radians = np.deg2rad(tilt_degrees)
    rotation = np.array([[np.cos(tilt_radians), -np.sin(tilt_radians)], [np.sin(tilt_radians), np.cos(tilt_radians)]])
    joint_places = hand_shape @ rotation.T * hand_size + np.asarray(wrist_place)
    clip[frame, hand_start : hand_start + HAND_JOINT_COUNT, :2] = joint_places
    clip[frame, hand_start : hand_start + HAND_JOINT_COUNT, CONFIDENCE] = 0.9


def place_body(clip: np.ndarray, frame: int, sway: float = 0.0, points=None) -> None:
    for point, (x_place, y_place) in BODY_AND_FACE_PLACES.items():
        if points is not None and point not in points:
            continue
        clip[frame, point] = (x_place + sway, y_place, 0.8)


def make_missing(clip: np.ndarray, frames, points) -> None:
    for frame in frames:
        clip[frame, points] = 0.0


def golden_cases() -> list[dict]:
    cases = []

    clip = empty_clip(12)
    for frame in range(12):
        place_body(clip, frame, sway=0.002 * frame)
        place_hand(clip, frame, RIGHT_HAND_START, (0.40 + 0.01 * frame, 0.55 - 0.012 * frame), 0.06, tilt_degrees=3 * frame)
        place_hand(clip, frame, LEFT_HAND_START, (0.62, 0.60), 0.055)
    cases.append(dict(name="two_hands_known_size", width=640, height=480, landmarks=clip,
                      description="Both hands and the body in every frame; picture size known (x × 4/3)."))

    clip = empty_clip(10)
    for frame in range(10):
        place_body(clip, frame)
        place_hand(clip, frame, RIGHT_HAND_START, (0.42, 0.50 - 0.01 * frame), 0.05 + 0.001 * frame)
    cases.append(dict(name="one_hand_unknown_size", width=0, height=0, landmarks=clip,
                      description="Right hand only, body seen, picture size unknown."))

    clip = empty_clip(6)
    for frame in range(6):
        place_body(clip, frame, sway=0.003 * frame)
    cases.append(dict(name="no_hands", width=1280, height=720, landmarks=clip,
                      description="Body only, no hand in any frame: hand size 1.0 (degenerate), body size from the shoulders."))

    clip = empty_clip(20)
    for frame in range(20):
        place_body(clip, frame)
        place_hand(clip, frame, RIGHT_HAND_START, (0.38 + 0.005 * frame, 0.52), 0.06, tilt_degrees=-2 * frame)
        place_hand(clip, frame, LEFT_HAND_START, (0.63, 0.58 - 0.004 * frame), 0.058)
    right_hand_points = list(range(RIGHT_HAND_START, RIGHT_HAND_START + HAND_JOINT_COUNT))
    make_missing(clip, [3, 4], right_hand_points)  # 2 frames: filled
    make_missing(clip, range(9, 15), right_hand_points)  # 6 frames: too long, stays missing
    make_missing(clip, [0], list(range(LEFT_HAND_START, LEFT_HAND_START + HAND_JOINT_COUNT)))  # at the start: not filled
    make_missing(clip, [7], [RIGHT_HAND_START + 8])  # one fingertip for one frame: filled
    make_missing(clip, range(14, 20), list(range(LEFT_HAND_START + 11, LEFT_HAND_START + 21)))  # 10 joints to the end: hand not seen
    make_missing(clip, [5, 6], [NOSE])  # filled
    cases.append(dict(name="gaps", width=0, height=0, landmarks=clip,
                      description="Short gaps (filled, confidence 0.5), a 6-frame gap (not filled), a gap at the start, "
                                  "a hand with too few joints at the end."))

    clip = empty_clip(8)
    for frame in range(8):
        place_hand(clip, frame, RIGHT_HAND_START, (0.35, 0.60 - 0.01 * frame), 0.07)
        if frame >= 2:
            place_hand(clip, frame, LEFT_HAND_START, (0.65, 0.62), 0.065)
        place_body(clip, frame, points={MOUTH_START, MOUTH_START + 1})
    cases.append(dict(name="no_shoulders", width=640, height=480, landmarks=clip,
                      description="Hands but no body: centre is the median of the seen wrists, body size 3.5 × hand size."))

    clip = empty_clip(14)
    for frame in range(14):
        place_hand(clip, frame, RIGHT_HAND_START, (0.40, 0.55 + 0.005 * frame), 0.06)
        if frame >= 5:
            place_body(clip, frame, sway=0.004 * frame)
    make_missing(clip, range(8, 14), [LEFT_SHOULDER])
    cases.append(dict(name="shoulders_seen_later", width=1920, height=1080, landmarks=clip,
                      description="No body for 5 frames (centre = first frame with shoulders), then one shoulder lost "
                                  "for the last 6 frames (centre = last frame with both)."))

    clip = empty_clip(6)
    for frame in range(6):
        place_body(clip, frame)
        clip[frame, RIGHT_HAND_START : RIGHT_HAND_START + HAND_JOINT_COUNT] = (0.4, 0.6, 0.9)
    cases.append(dict(name="degenerate_hand", width=0, height=0, landmarks=clip,
                      description="Every right-hand joint on the same spot: hand size 0 -> 1.0, joint features zero."))

    clip = empty_clip(6)
    cases.append(dict(name="nothing_seen", width=0, height=0, landmarks=clip,
                      description="Nothing seen at all: every feature is 0."))

    for case in cases:
        # Rounded so the JSON's landmarks are exactly the ones the features were made from.
        case["landmarks"] = np.round(case["landmarks"].astype(np.float64), 4).astype(np.float32)
    return cases


def _rounded(value: float, decimals: int = 6) -> float:
    rounded_value = round(float(value), decimals)
    return 0.0 if rounded_value == 0 else rounded_value  # no "-0.0" in the files


def _compact_json_list(values) -> str:
    return json.dumps(values, separators=(",", ":"))


def golden_file_text(case: dict) -> str:
    details = compute_feature_details(case["landmarks"], case["width"], case["height"])
    landmark_lines = [
        _compact_json_list([[_rounded(value, 4) for value in point] for point in frame])
        for frame in case["landmarks"].tolist()
    ]
    feature_lines = [_compact_json_list([_rounded(value) for value in frame]) for frame in details.features.tolist()]
    centre_lines = [_compact_json_list([_rounded(value) for value in frame]) for frame in details.centre.tolist()]
    header_fields = {
        "name": case["name"],
        "description": case["description"],
        "width": case["width"],
        "height": case["height"],
        "hand_size": _rounded(details.hand_size),
        "hand_size_is_degenerate": bool(details.hand_size_is_degenerate),
        "body_size": _rounded(details.body_size),
    }
    text_lines = ["{"]
    for field_name, field_value in header_fields.items():
        text_lines.append(f" {json.dumps(field_name)}: {json.dumps(field_value, ensure_ascii=False)},")
    for field_name, field_lines in (("centre", centre_lines), ("landmarks", landmark_lines), ("features", feature_lines)):
        text_lines.append(f" {json.dumps(field_name)}: [")
        text_lines.append(",\n".join("  " + line for line in field_lines))
        text_lines.append(" ]" + ("," if field_name != "features" else ""))
    text_lines.append("}")
    return "\n".join(text_lines) + "\n"


def write_golden_files(golden_folder=DEFAULT_GOLDEN_FOLDER) -> list[Path]:
    golden_folder = Path(golden_folder)
    golden_folder.mkdir(parents=True, exist_ok=True)
    written_paths = []
    for case in golden_cases():
        golden_path = golden_folder / f"{case['name']}.json"
        golden_path.write_text(golden_file_text(case), encoding="utf-8")
        written_paths.append(golden_path)
    return written_paths


# ---- frame rate (SPEC section 3, "Frame rate") ----------------------------------------------------------------


def _signer_frame(clip: np.ndarray, frame: int, progress: float, with_right_hand=True, with_left_hand=True) -> None:
    """Body in place, the right hand sweeping right and up as `progress` goes from 0 to 1, the left hand still."""
    place_body(clip, frame, sway=0.01 * progress)
    if with_right_hand:
        place_hand(clip, frame, RIGHT_HAND_START, (0.36 + 0.12 * progress, 0.62 - 0.10 * progress), 0.06,
                   tilt_degrees=20 * progress)
    if with_left_hand:
        place_hand(clip, frame, LEFT_HAND_START, (0.63, 0.60), 0.055)


def _file_times(frame_count: int, frames_per_second: float, first_time: float = 0.0) -> list[float]:
    return [first_time + frame / frames_per_second for frame in range(frame_count)]


def frame_rate_golden_cases() -> list[dict]:
    """Each case's points keep one confidence while seen, except where a case says otherwise, so a time that lands
    exactly on a frame or half way between two (25 and 60 a second do) can't make Swift and Python differ."""
    cases = []

    clip = empty_clip(11)
    for frame in range(11):
        _signer_frame(clip, frame, frame / 10)
    cases.append(dict(name="fps_25", times=_file_times(11, 25), landmarks=clip,
                      description="25 a second for 0.4 s: 11 frames become 13; every point seen throughout."))

    clip = empty_clip(13)
    for frame in range(13):
        _signer_frame(clip, frame, frame / 12)
    cases.append(dict(name="fps_60", times=_file_times(13, 60), landmarks=clip,
                      description="60 a second for 0.2 s: 13 frames become 7; every point seen throughout."))

    clip = empty_clip(8)
    for frame in range(8):
        _signer_frame(clip, frame, frame / 7, with_right_hand=frame != 6, with_left_hand=frame >= 3)
    make_missing(clip, [3], [NOSE])
    clip[5:, RIGHT_HAND_START + 8, CONFIDENCE] = 0.6  # the index fingertip less sure later on: the smaller is kept
    # At 15 a second every other new frame is half way between two old ones; after rounding the times, the pairs
    # 1-2 and 4-5 are exactly half way, so nothing comes or goes between those two pairs' frames.
    cases.append(dict(name="fps_15_points_come_and_go", times=_file_times(8, 15), landmarks=clip,
                      description="15 a second: 8 frames become 15. The right hand is lost in frame 6, the left hand "
                                  "comes in at frame 3, the nose is lost in frame 3 and a fingertip's confidence drops "
                                  "from frame 5: points seen on one side only are copied from the nearer frame."))

    uneven_times = [3.217, 3.269, 3.315, 3.368, 3.414, 3.466, 3.52, 3.567]
    clip = empty_clip(8)
    for frame in range(8):
        _signer_frame(clip, frame, frame / 7, with_left_hand=frame != 5)
    clip[:, LEFT_SHOULDER, CONFIDENCE] = [0.8, 0.7, 0.9, 0.6, 0.8, 0.75, 0.85, 0.8]
    cases.append(dict(name="uneven_camera_times_about_20", times=uneven_times, landmarks=clip,
                      description="Camera time stamps about 20 a second, unevenly spaced and not starting at 0 "
                                  "(rate 7 / 0.35 s = 20): 8 frames become 11. The left hand is lost in frame 5 and a "
                                  "shoulder's confidence changes from frame to frame."))

    clip = empty_clip(6)
    for frame in range(6):
        _signer_frame(clip, frame, frame / 5)
    cases.append(dict(name="fps_29_97_unchanged", times=_file_times(6, 29.97), landmarks=clip,
                      description="29.97 a second is between 27 and 33: returned unchanged."))

    clip = empty_clip(1)
    _signer_frame(clip, 0, 0.5)
    cases.append(dict(name="single_frame", times=[0.5], landmarks=clip,
                      description="One frame: the rate is unknown, so it is returned unchanged."))

    clip = empty_clip(2)
    _signer_frame(clip, 0, 0.0, with_left_hand=False)
    _signer_frame(clip, 1, 1.0, with_right_hand=False)
    clip[1, 42:55, CONFIDENCE] = 0.6
    cases.append(dict(name="two_frames", times=[0.0, 0.11], landmarks=clip,
                      description="Two frames 0.11 s apart (about 9 a second) become 4. The right hand is only in "
                                  "the first, the left only in the second; the body is less sure in the second, so "
                                  "its slid points take the smaller confidence."))

    for case in cases:
        case["times"] = [round(float(time), 6) for time in case["times"]]
        case["landmarks"] = np.round(case["landmarks"].astype(np.float64), 4).astype(np.float32)
    return cases


def frame_rate_golden_file_text(case: dict) -> str:
    resampled = resample_to_30_per_second(case["landmarks"], case["times"])
    landmark_lines = [
        _compact_json_list([[_rounded(value, 4) for value in point] for point in frame])
        for frame in case["landmarks"].tolist()
    ]
    resampled_lines = [
        _compact_json_list([[_rounded(value) for value in point] for point in frame]) for frame in resampled.tolist()
    ]
    text_lines = ["{"]
    for field_name in ("name", "description"):
        text_lines.append(f" {json.dumps(field_name)}: {json.dumps(case[field_name], ensure_ascii=False)},")
    text_lines.append(f' "times": {_compact_json_list([_rounded(time) for time in case["times"]])},')
    for field_name, field_lines in (("landmarks", landmark_lines), ("resampled", resampled_lines)):
        text_lines.append(f" {json.dumps(field_name)}: [")
        text_lines.append(",\n".join("  " + line for line in field_lines))
        text_lines.append(" ]" + ("," if field_name != "resampled" else ""))
    text_lines.append("}")
    return "\n".join(text_lines) + "\n"


def write_frame_rate_golden_files(golden_folder=DEFAULT_FRAME_RATE_GOLDEN_FOLDER) -> list[Path]:
    golden_folder = Path(golden_folder)
    golden_folder.mkdir(parents=True, exist_ok=True)
    written_paths = []
    for case in frame_rate_golden_cases():
        golden_path = golden_folder / f"{case['name']}.json"
        golden_path.write_text(frame_rate_golden_file_text(case), encoding="utf-8")
        written_paths.append(golden_path)
    return written_paths


def main(argument_list=None) -> None:
    argument_parser = argparse.ArgumentParser(description="Write the golden feature files for the Swift test.")
    argument_parser.add_argument("--output", default=str(DEFAULT_GOLDEN_FOLDER))
    parsed_arguments = argument_parser.parse_args(argument_list)
    for written_path in write_golden_files(parsed_arguments.output):
        print(f"wrote {written_path}")
    for written_path in write_frame_rate_golden_files(Path(parsed_arguments.output) / "frame_rate"):
        print(f"wrote {written_path}")


if __name__ == "__main__":
    main()
