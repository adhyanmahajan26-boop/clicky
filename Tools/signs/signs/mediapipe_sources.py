"""Converters from Google's two Kaggle MediaPipe datasets to SPEC clips + manifest.csv.

- "Isolated Sign Language Recognition" (Kaggle `asl-signs`): `train.csv` (path, participant_id, sequence_id,
  sign); each path is a long-format parquet (frame, row_id, type, landmark_index, x, y, z), 543 rows a frame.
- "ASL Fingerspelling" (Kaggle `asl-fingerspelling`): `train.csv` and `supplemental_metadata.csv` (path, file_id,
  sequence_id, participant_id, phrase); each parquet holds many sequences in wide format (frame, x_face_0 …,
  x_left_hand_0 …, x_pose_0 …, x_right_hand_0 …, the same for y_ and z_), indexed by sequence_id.

Both write `source=mediapipe`, `width=height=0` (unknown), `fps=30`. Missing parts are NaN in the files and
become confidence 0. These datasets carry no pose visibility, so a body point that is present gets confidence 1.

    python -m signs.mediapipe_sources isolated --kaggle /data/kaggle/asl-signs --output /data/signs/asl-signs
    python -m signs.mediapipe_sources fingerspelling --kaggle /data/kaggle/asl-fingerspelling --output /data/signs/asl-fingerspelling
    python -m signs.mediapipe_sources isolated --kaggle /data/kaggle/asl-signs --check-sides
"""

from __future__ import annotations

import argparse
import os
from collections import defaultdict
from pathlib import Path

import numpy as np

from .landmarks import (
    BODY_START,
    CONFIDENCE,
    LEFT_BODY_WRIST,
    LEFT_HAND_START,
    RIGHT_BODY_WRIST,
    RIGHT_HAND_START,
    WRIST_JOINT,
    ClipRecord,
    ManifestWriter,
    empty_clip,
    write_clip,
)

# Which MediaPipe hand block is the signer's own right hand. MediaPipe Holistic means `right_hand` to be the
# person's right hand (like pose 16, the right wrist), but that only holds if the recording wasn't mirrored and
# the model got it right. Check on real data with `--check-sides` before converting: if `right_hand`'s wrist is
# mostly nearer pose 15 (left wrist) than pose 16, swap these two names.
SIGNER_RIGHT_HAND_MEDIAPIPE_PART = "right_hand"
SIGNER_LEFT_HAND_MEDIAPIPE_PART = "left_hand"

MEDIAPIPE_POSE_LANDMARKS_FOR_BODY_POINTS = (0, 2, 5, 7, 8, 11, 12, 13, 14, 15, 16, 23, 24)
# Mouth: left corner, right corner, middle of the upper lip, middle of the lower lip; then left brow, right brow.
MEDIAPIPE_FACE_LANDMARKS_FOR_MOUTH_AND_BROW_POINTS = (291, 61, 0, 17, 334, 105)
MOUTH_START = 55

KAGGLE_FRAMES_PER_SECOND = 30
HAND_JOINT_COUNT = 21


def mediapipe_sources_for_spec_points() -> list[tuple[str, int]]:
    """For each of the 61 SPEC points in order, the MediaPipe (part, landmark index) it is read from."""
    sources = [(SIGNER_RIGHT_HAND_MEDIAPIPE_PART, joint) for joint in range(HAND_JOINT_COUNT)]
    sources += [(SIGNER_LEFT_HAND_MEDIAPIPE_PART, joint) for joint in range(HAND_JOINT_COUNT)]
    sources += [("pose", pose_landmark) for pose_landmark in MEDIAPIPE_POSE_LANDMARKS_FOR_BODY_POINTS]
    sources += [("face", face_landmark) for face_landmark in MEDIAPIPE_FACE_LANDMARKS_FOR_MOUTH_AND_BROW_POINTS]
    assert len(sources) == 61 and sources[BODY_START][0] == "pose" and sources[MOUTH_START][0] == "face"
    return sources


def _fill_points(clip: np.ndarray, frame_positions, spec_points, x_values, y_values) -> None:
    """Writes x, y and confidence 1 where both x and y are numbers; NaN stays missing (all zero)."""
    point_is_present = np.isfinite(x_values) & np.isfinite(y_values)
    clip[frame_positions[point_is_present], spec_points[point_is_present], 0] = x_values[point_is_present]
    clip[frame_positions[point_is_present], spec_points[point_is_present], 1] = y_values[point_is_present]
    clip[frame_positions[point_is_present], spec_points[point_is_present], CONFIDENCE] = 1.0


# ---- isolated signs (long format) --------------------------------------------------------------------------


def isolated_sign_parquet_to_clip(parquet_path: str | os.PathLike) -> np.ndarray:
    import pyarrow.parquet

    table = pyarrow.parquet.read_table(parquet_path, columns=["frame", "type", "landmark_index", "x", "y"])
    return isolated_sign_columns_to_clip(
        table.column("frame").to_numpy(),
        np.asarray(table.column("type").to_pylist(), dtype=object),
        table.column("landmark_index").to_numpy(),
        table.column("x").to_numpy(zero_copy_only=False).astype(np.float64),
        table.column("y").to_numpy(zero_copy_only=False).astype(np.float64),
    )


def isolated_sign_columns_to_clip(frame_values, part_values, landmark_index_values, x_values, y_values) -> np.ndarray:
    unique_frames, frame_positions = np.unique(frame_values, return_inverse=True)
    clip = empty_clip(len(unique_frames))
    spec_point_by_part_and_landmark = {
        source: spec_point for spec_point, source in enumerate(mediapipe_sources_for_spec_points())
    }
    for part_name in ("right_hand", "left_hand", "pose", "face"):
        rows_of_this_part = part_values == part_name
        if not rows_of_this_part.any():
            continue
        landmark_indices = landmark_index_values[rows_of_this_part].astype(np.int64)
        largest_landmark_index = max(int(landmark_indices.max()), 0)
        spec_point_lookup = np.full(largest_landmark_index + 1, -1, dtype=np.int64)
        for (source_part, source_landmark), spec_point in spec_point_by_part_and_landmark.items():
            if source_part == part_name and source_landmark <= largest_landmark_index:
                spec_point_lookup[source_landmark] = spec_point
        spec_points = spec_point_lookup[landmark_indices]
        row_is_used = spec_points >= 0
        _fill_points(
            clip,
            frame_positions[rows_of_this_part][row_is_used],
            spec_points[row_is_used],
            x_values[rows_of_this_part][row_is_used],
            y_values[rows_of_this_part][row_is_used],
        )
    return clip


def convert_isolated_signs(kaggle_folder, output_folder, dataset_name: str = "asl-signs", limit: int | None = None) -> int:
    """Converts every row of train.csv (or the first `limit`). Returns the number of clips written."""
    import pandas

    kaggle_folder = Path(kaggle_folder)
    output_folder = Path(output_folder)
    output_folder.mkdir(parents=True, exist_ok=True)
    metadata = pandas.read_csv(kaggle_folder / "train.csv", dtype=str, keep_default_na=False)
    if limit is not None:
        metadata = metadata.head(limit)
    written_clip_count = 0
    with ManifestWriter(output_folder) as manifest_writer:
        for row_number, metadata_row in enumerate(metadata.itertuples(index=False)):
            clip = isolated_sign_parquet_to_clip(kaggle_folder / metadata_row.path)
            if clip.shape[0] == 0:
                continue
            clip_id = f"{dataset_name}-{metadata_row.sequence_id}"
            write_clip(output_folder / f"{clip_id}.npy", clip)
            manifest_writer.add(
                ClipRecord(
                    clip_id=clip_id,
                    dataset=dataset_name,
                    language="asl",
                    label=str(metadata_row.sign).strip().lower(),
                    signer=str(metadata_row.participant_id),
                    split="",
                    fps=KAGGLE_FRAMES_PER_SECOND,
                    width=0,
                    height=0,
                    frames=clip.shape[0],
                    source="mediapipe",
                )
            )
            written_clip_count += 1
            if row_number % 5000 == 0:
                print(f"{row_number + 1} / {len(metadata)}", flush=True)
    return written_clip_count


# ---- finger-spelling (wide format, many sequences per file) -------------------------------------------------


def fingerspelling_column_names() -> tuple[list[str], list[str]]:
    """The x and y column names to read, one per SPEC point, in SPEC order."""
    x_column_names = [f"x_{part}_{landmark}" for part, landmark in mediapipe_sources_for_spec_points()]
    y_column_names = [f"y_{part}_{landmark}" for part, landmark in mediapipe_sources_for_spec_points()]
    return x_column_names, y_column_names


def read_fingerspelling_parquet(parquet_path) -> dict[int, np.ndarray]:
    """Reads one fingerspelling parquet (only the 124 columns needed) and returns {sequence_id: clip}."""
    import pyarrow.parquet

    x_column_names, y_column_names = fingerspelling_column_names()
    table = pyarrow.parquet.read_table(parquet_path, columns=["sequence_id", "frame"] + x_column_names + y_column_names)
    sequence_ids = table.column("sequence_id").to_numpy()
    frame_numbers = table.column("frame").to_numpy()
    x_values = np.stack(
        [table.column(column_name).to_numpy(zero_copy_only=False) for column_name in x_column_names], axis=1
    ).astype(np.float32)
    y_values = np.stack(
        [table.column(column_name).to_numpy(zero_copy_only=False) for column_name in y_column_names], axis=1
    ).astype(np.float32)
    del table

    row_order = np.lexsort((frame_numbers, sequence_ids))
    sorted_sequence_ids = sequence_ids[row_order]
    distinct_sequence_ids, first_rows, row_counts = np.unique(sorted_sequence_ids, return_index=True, return_counts=True)
    clips_by_sequence = {}
    for sequence_id, first_row, row_count in zip(distinct_sequence_ids, first_rows, row_counts):
        rows = row_order[first_row : first_row + row_count]
        clip = empty_clip(row_count)
        sequence_x = x_values[rows]
        sequence_y = y_values[rows]
        point_is_present = np.isfinite(sequence_x) & np.isfinite(sequence_y)
        clip[:, :, 0] = np.where(point_is_present, sequence_x, 0.0)
        clip[:, :, 1] = np.where(point_is_present, sequence_y, 0.0)
        clip[:, :, CONFIDENCE] = point_is_present.astype(np.float32)
        clips_by_sequence[int(sequence_id)] = clip
    return clips_by_sequence


def convert_fingerspelling(
    kaggle_folder,
    output_folder,
    metadata_file_names=("train.csv", "supplemental_metadata.csv"),
    dataset_name: str = "asl-fingerspelling",
    limit_files: int | None = None,
) -> int:
    """Streams one parquet at a time (each holds about a thousand sequences and is 1–2.5 GB). Returns the number
    of clips written."""
    import pandas

    kaggle_folder = Path(kaggle_folder)
    output_folder = Path(output_folder)
    output_folder.mkdir(parents=True, exist_ok=True)
    metadata_rows_by_path = defaultdict(list)
    for metadata_file_name in metadata_file_names:
        metadata_path = kaggle_folder / metadata_file_name
        if not metadata_path.exists():
            print(f"skipping missing {metadata_path}")
            continue
        metadata = pandas.read_csv(metadata_path, dtype=str, keep_default_na=False)
        for metadata_row in metadata.itertuples(index=False):
            metadata_rows_by_path[metadata_row.path].append(metadata_row)

    parquet_paths = sorted(metadata_rows_by_path)
    if limit_files is not None:
        parquet_paths = parquet_paths[:limit_files]
    written_clip_count = 0
    with ManifestWriter(output_folder) as manifest_writer:
        for file_number, parquet_path in enumerate(parquet_paths):
            clips_by_sequence = read_fingerspelling_parquet(kaggle_folder / parquet_path)
            for metadata_row in metadata_rows_by_path[parquet_path]:
                clip = clips_by_sequence.get(int(metadata_row.sequence_id))
                if clip is None or clip.shape[0] == 0:
                    print(f"sequence {metadata_row.sequence_id} not in {parquet_path}; skipped")
                    continue
                clip_id = f"{dataset_name}-{metadata_row.sequence_id}"
                write_clip(output_folder / f"{clip_id}.npy", clip)
                manifest_writer.add(
                    ClipRecord(
                        clip_id=clip_id,
                        dataset=dataset_name,
                        language="asl",
                        label=str(metadata_row.phrase).lower(),
                        signer=str(metadata_row.participant_id),
                        split="",
                        fps=KAGGLE_FRAMES_PER_SECOND,
                        width=0,
                        height=0,
                        frames=clip.shape[0],
                        source="mediapipe",
                    )
                )
                written_clip_count += 1
            print(f"file {file_number + 1} / {len(parquet_paths)}: {parquet_path}", flush=True)
    return written_clip_count


# ---- handedness check ---------------------------------------------------------------------------------------


def count_hand_sides(clips) -> dict:
    """Over frames where a hand's wrist and both body wrists are seen: how often the SPEC right hand's wrist is
    nearer the body's right wrist (pose 16) than its left (pose 15), and the same for the left hand."""
    counts = {"right_hand_frames": 0, "right_hand_nearer_pose_16": 0, "left_hand_frames": 0, "left_hand_nearer_pose_15": 0}
    for clip in clips:
        both_body_wrists_seen = (clip[:, LEFT_BODY_WRIST, CONFIDENCE] > 0) & (clip[:, RIGHT_BODY_WRIST, CONFIDENCE] > 0)
        for hand_start, frame_key, nearer_key, own_side_wrist, other_side_wrist in (
            (RIGHT_HAND_START, "right_hand_frames", "right_hand_nearer_pose_16", RIGHT_BODY_WRIST, LEFT_BODY_WRIST),
            (LEFT_HAND_START, "left_hand_frames", "left_hand_nearer_pose_15", LEFT_BODY_WRIST, RIGHT_BODY_WRIST),
        ):
            hand_wrist = hand_start + WRIST_JOINT
            usable_frames = both_body_wrists_seen & (clip[:, hand_wrist, CONFIDENCE] > 0)
            distance_to_own_side = np.linalg.norm(clip[usable_frames, hand_wrist, :2] - clip[usable_frames, own_side_wrist, :2], axis=1)
            distance_to_other_side = np.linalg.norm(clip[usable_frames, hand_wrist, :2] - clip[usable_frames, other_side_wrist, :2], axis=1)
            counts[frame_key] += int(usable_frames.sum())
            counts[nearer_key] += int((distance_to_own_side < distance_to_other_side).sum())
    return counts


def describe_hand_sides(counts: dict) -> str:
    def share(numerator: int, denominator: int) -> str:
        return f"{100.0 * numerator / denominator:.1f}%" if denominator else "no frames"

    return (
        f"MediaPipe '{SIGNER_RIGHT_HAND_MEDIAPIPE_PART}' (used as the signer's right hand): wrist nearer pose 16 "
        f"(right wrist) than pose 15 in {share(counts['right_hand_nearer_pose_16'], counts['right_hand_frames'])} "
        f"of {counts['right_hand_frames']} frames\n"
        f"MediaPipe '{SIGNER_LEFT_HAND_MEDIAPIPE_PART}' (used as the signer's left hand): wrist nearer pose 15 "
        f"(left wrist) than pose 16 in {share(counts['left_hand_nearer_pose_15'], counts['left_hand_frames'])} "
        f"of {counts['left_hand_frames']} frames\n"
        "Well above 50% for both means the mapping is right; well below means swap the two constants at the top "
        "of signs/mediapipe_sources.py."
    )


def check_isolated_sign_sides(kaggle_folder, sample_count: int = 200, seed: int = 0) -> dict:
    import pandas

    kaggle_folder = Path(kaggle_folder)
    metadata = pandas.read_csv(kaggle_folder / "train.csv", dtype=str, keep_default_na=False)
    sampled_rows = metadata.sample(n=min(sample_count, len(metadata)), random_state=seed)
    clips = (isolated_sign_parquet_to_clip(kaggle_folder / path) for path in sampled_rows["path"])
    return count_hand_sides(clips)


def check_fingerspelling_sides(kaggle_folder, sample_count: int = 200, seed: int = 0) -> dict:
    """Reads one randomly chosen parquet of train.csv and checks up to `sample_count` of its sequences."""
    import pandas

    kaggle_folder = Path(kaggle_folder)
    metadata = pandas.read_csv(kaggle_folder / "train.csv", dtype=str, keep_default_na=False)
    chosen_path = sorted(metadata["path"].unique())[np.random.default_rng(seed).integers(metadata["path"].nunique())]
    clips_by_sequence = read_fingerspelling_parquet(kaggle_folder / chosen_path)
    sampled_clips = list(clips_by_sequence.values())[:sample_count]
    return count_hand_sides(sampled_clips)


def main(argument_list=None) -> None:
    argument_parser = argparse.ArgumentParser(description="Convert Google's Kaggle MediaPipe datasets to SPEC clips.")
    subcommands = argument_parser.add_subparsers(dest="dataset_kind", required=True)
    for dataset_kind in ("isolated", "fingerspelling"):
        subcommand = subcommands.add_parser(dataset_kind)
        subcommand.add_argument("--kaggle", required=True, help="the unzipped Kaggle competition folder")
        subcommand.add_argument("--output", help="SPEC dataset folder to write (clips + manifest.csv)")
        subcommand.add_argument("--check-sides", action="store_true", help="only print the handedness check")
        subcommand.add_argument("--sample", type=int, default=200, help="sequences read by --check-sides")
        subcommand.add_argument("--limit", type=int, default=None, help="isolated: rows; fingerspelling: parquet files")
        subcommand.add_argument("--no-pack", action="store_true", help="don't pack the output folder afterwards")
    parsed_arguments = argument_parser.parse_args(argument_list)

    if parsed_arguments.check_sides:
        if parsed_arguments.dataset_kind == "isolated":
            counts = check_isolated_sign_sides(parsed_arguments.kaggle, parsed_arguments.sample)
        else:
            counts = check_fingerspelling_sides(parsed_arguments.kaggle, parsed_arguments.sample)
        print(describe_hand_sides(counts))
        return
    if not parsed_arguments.output:
        argument_parser.error("--output is needed to convert")
    if parsed_arguments.dataset_kind == "isolated":
        written_clip_count = convert_isolated_signs(parsed_arguments.kaggle, parsed_arguments.output, limit=parsed_arguments.limit)
    else:
        written_clip_count = convert_fingerspelling(
            parsed_arguments.kaggle, parsed_arguments.output, limit_files=parsed_arguments.limit
        )
    print(f"wrote {written_clip_count} clips to {parsed_arguments.output}")
    if not parsed_arguments.no_pack:
        from .landmarks import pack

        pack(parsed_arguments.output)
        print(f"packed {parsed_arguments.output}")


if __name__ == "__main__":
    main()
