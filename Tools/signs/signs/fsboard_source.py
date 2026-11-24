"""Converter from Google's FSboard finger-spelling data (CC BY 4.0) to SPEC clips + manifest.csv.

FSboard is hosted by Georgia Tech at https://signdata.cc.gatech.edu/data/fsboard/ as two studies:

- `daun_v3`: addresses, URLs and phone numbers spelled on a phone (train / validation / test).
- `dmk_v3`: MacKenzie phrases (short English sentences), train only.

Each study has `metadata/<study>-<split>.json` (one record per clip: clipFilename, phrase, signerId, and for
daun_v3 a sensitiveContent flag) and `landmarks/<study>-<split>.arrow-NNNNN-of-NNNNN` shards. A shard is an Arrow IPC
file with one column, `serialized`: each row is a `tf.train.SequenceExample` holding MediaPipe Holistic landmarks
per frame (`x_`, `y_`, `z_`, `presence_`, `visibility_` of `pose` (33 or 25 points), `left_hand`, `right_hand` (21)
and `face` (478)), plus a `timestamp` and context fields (num_frames, video_name, image_width, image_height,
image/frame_rate, image/width, image/height, signer_id, prompt). The protobuf is read here directly (no TensorFlow): its wire format is small and fixed.

**The published v3 shards are scrambled** (checked 24 Nov 2026 on daun_v3-validation shard 0 and dmk_v3-train shard
0: every one of 112,230 per-frame arrays). In each, `x_<part>` is not the x of each landmark: it is a window of the
landmarks' interleaved x, y, z values (x0, y0, z0, x1, y1, z1, …), as long as the landmark count, and `y_<part>` and
`z_<part>` are the same window moved on by one and two values. So only the first `length / 3` landmarks survive:
hand joints 0–7 of 21, pose points 0–8 of 33 (no shoulders or wrists), 160 of 478 face points. `convert_shard`
refuses such shards (`ScrambledLandmarksError`) instead of writing clips with most points missing; FSboard has to be
read from its `video_clips/` with `sign-extract` instead. `unscramble_landmarks` recovers what survives, for
comparisons only.

Points come out as SPEC says for MediaPipe: hands with confidence 1 when present, pose points with their
visibility as confidence (FSboard stores it as a logit, so it goes through a sigmoid), face (mouth, brows) with confidence 1. Clips flagged `sensitiveContent` are skipped.

    python -m signs.fsboard_source convert --shard <file.arrow-…> --metadata <study-split.json> --output <folder>
    python -m signs.fsboard_source check-sides --shard <file.arrow-…>
    python -m signs.fsboard_source schema --shard <file.arrow-…>
"""

from __future__ import annotations

import argparse
import json
import re
import struct
from pathlib import Path

import numpy as np

from .landmarks import CONFIDENCE, ClipRecord, ManifestWriter, empty_clip, write_clip
from .mediapipe_sources import count_hand_sides, describe_hand_sides, mediapipe_sources_for_spec_points

# FSboard's split names to SPEC's.
SPEC_SPLIT_BY_FSBOARD_SPLIT = {"train": "train", "validation": "val", "test": "test"}

SHARD_NAME_PATTERN = re.compile(r"^(?P<study>[^-]+)-(?P<split>[^-.]+)\.arrow-(?P<shard>\d{5})-of-(?P<shards>\d{5})$")


# ---- protobuf wire format ------------------------------------------------------------------------------------


def _read_varint(data: bytes, position: int) -> tuple[int, int]:
    value = 0
    shift = 0
    while True:
        byte = data[position]
        position += 1
        value |= (byte & 0x7F) << shift
        if byte < 0x80:
            return value, position
        shift += 7


def _fields(data: bytes):
    """Yields (field number, wire type, value) for one message; length-delimited values come as bytes."""
    position = 0
    end = len(data)
    while position < end:
        key, position = _read_varint(data, position)
        field_number, wire_type = key >> 3, key & 7
        if wire_type == 0:
            value, position = _read_varint(data, position)
        elif wire_type == 2:
            length, position = _read_varint(data, position)
            value = data[position : position + length]
            position += length
        elif wire_type == 5:
            value = data[position : position + 4]
            position += 4
        elif wire_type == 1:
            value = data[position : position + 8]
            position += 8
        else:
            raise ValueError(f"unsupported protobuf wire type {wire_type}")
        yield field_number, wire_type, value


def _parse_feature(data: bytes):
    """tf.train.Feature: bytes_list = 1, float_list = 2, int64_list = 3 (each `repeated value = 1`, numbers packed).
    Returns ('bytes', [bytes]), ('float', np.float32 array), ('int64', [int]) or (None, None) when empty."""
    for field_number, _, list_bytes in _fields(data):
        if field_number == 1:
            return "bytes", [bytes(value) for number, _, value in _fields(list_bytes) if number == 1]
        if field_number == 2:
            floats = []
            for number, wire_type, value in _fields(list_bytes):
                if number != 1:
                    continue
                floats.append(np.frombuffer(value, dtype="<f4") if wire_type == 2 else np.frombuffer(value, dtype="<f4"))
            return "float", (np.concatenate(floats) if floats else np.zeros(0, dtype=np.float32))
        if field_number == 3:
            integers = []
            for number, wire_type, value in _fields(list_bytes):
                if number != 1:
                    continue
                if wire_type == 2:
                    position = 0
                    while position < len(value):
                        integer, position = _read_varint(value, position)
                        integers.append(integer)
                else:
                    integers.append(value)
            return "int64", integers
    return None, None


def _parse_map_entries(data: bytes):
    """A protobuf map is repeated entries of {key = 1 (string), value = 2 (message)}."""
    for field_number, _, entry in _fields(data):
        if field_number != 1:
            continue
        key = None
        value = b""
        for entry_field, _, entry_value in _fields(entry):
            if entry_field == 1:
                key = bytes(entry_value).decode("utf-8")
            elif entry_field == 2:
                value = entry_value
        yield key, value


def parse_sequence_example(serialized: bytes) -> tuple[dict, dict]:
    """tf.train.SequenceExample {context = 1 (Features), feature_lists = 2 (FeatureLists)}.

    Returns (context {name: first value}, feature lists {name: [per-frame np.float32 array or int list, empty when
    the frame has none]})."""
    context = {}
    feature_lists = {}
    for field_number, _, value in _fields(serialized):
        if field_number == 1:
            for name, feature_bytes in _parse_map_entries(value):
                kind, values = _parse_feature(feature_bytes)
                if kind == "bytes":
                    context[name] = values[0].decode("utf-8") if values else ""
                elif kind in ("float", "int64"):
                    context[name] = (values[0] if len(values) else None)
                    if kind == "float" and context[name] is not None:
                        context[name] = float(context[name])
        elif field_number == 2:
            for name, feature_list_bytes in _parse_map_entries(value):
                frames = []
                for frame_field, _, feature_bytes in _fields(feature_list_bytes):
                    if frame_field != 1:
                        continue
                    kind, values = _parse_feature(feature_bytes)
                    frames.append(values if values is not None else np.zeros(0, dtype=np.float32))
                feature_lists[name] = frames
    return context, feature_lists


# ---- the scrambled layout -----------------------------------------------------------------------------------


class ScrambledLandmarksError(ValueError):
    pass


def landmarks_are_scrambled(feature_lists: dict) -> bool:
    """True when, in every frame that has values, y_<part> is x_<part> moved on by one value and z_<part> is y_<part>
    moved on by one (the published v3 layout, see the module notes)."""
    frames_checked = 0
    for part in ("pose", "right_hand", "left_hand", "face"):
        x_frames = feature_lists.get(f"x_{part}", [])
        y_frames = feature_lists.get(f"y_{part}", [])
        z_frames = feature_lists.get(f"z_{part}", [])
        for x_values, y_values, z_values in zip(x_frames, y_frames, z_frames):
            if len(x_values) < 3 or len(y_values) != len(x_values) or len(z_values) != len(x_values):
                continue
            frames_checked += 1
            if not (np.array_equal(x_values[1:], y_values[:-1]) and np.array_equal(y_values[1:], z_values[:-1])):
                return False
    return frames_checked > 0


def unscramble_landmarks(x_values, y_values, z_values) -> np.ndarray:
    """[landmarks that survive, 3] x, y, z from one scrambled frame: the interleaved values are x_values, then the last
    value of y_values and of z_values."""
    interleaved = np.concatenate([np.asarray(x_values), np.asarray(y_values)[-1:], np.asarray(z_values)[-1:]])
    surviving_landmark_count = len(interleaved) // 3
    return interleaved[: surviving_landmark_count * 3].reshape(surviving_landmark_count, 3)


# ---- to SPEC clips -------------------------------------------------------------------------------------------


def sequence_example_to_clip(feature_lists: dict, frame_count: int | None = None) -> np.ndarray:
    """[T, 61, 3]: MediaPipe x and y as they are (0–1, y down), confidence 1 for hands and face when present and the
    pose point's visibility for body points (1 when the file has no visibility for a present point)."""
    if frame_count is None:
        frame_count = max((len(frames) for frames in feature_lists.values()), default=0)
    clip = empty_clip(frame_count)
    for spec_point, (part, landmark) in enumerate(mediapipe_sources_for_spec_points()):
        x_frames = feature_lists.get(f"x_{part}", [])
        y_frames = feature_lists.get(f"y_{part}", [])
        visibility_frames = feature_lists.get(f"visibility_{part}", []) if part == "pose" else []
        for frame_index in range(min(frame_count, len(x_frames), len(y_frames))):
            x_values = x_frames[frame_index]
            y_values = y_frames[frame_index]
            if len(x_values) <= landmark or len(y_values) <= landmark:
                continue
            x_value = float(x_values[landmark])
            y_value = float(y_values[landmark])
            if not (np.isfinite(x_value) and np.isfinite(y_value)):
                continue
            confidence = 1.0
            if part == "pose" and frame_index < len(visibility_frames) and len(visibility_frames[frame_index]) > landmark:
                # FSboard stores pose visibility as a logit (values such as -1.8 and 6.0), so it is squashed to 0–1.
                visibility_logit = float(visibility_frames[frame_index][landmark])
                confidence = 1.0 / (1.0 + np.exp(-visibility_logit)) if np.isfinite(visibility_logit) else 1.0
            if confidence <= 0:
                continue
            clip[frame_index, spec_point, 0] = x_value
            clip[frame_index, spec_point, 1] = y_value
            clip[frame_index, spec_point, CONFIDENCE] = confidence
    return clip


def read_shard_rows(shard_path):
    """Yields the serialized SequenceExamples of one shard, one record batch at a time (shards are ~0.5 GB)."""
    import pyarrow.ipc

    with open(shard_path, "rb") as shard_file:
        try:
            reader = pyarrow.ipc.open_file(shard_file)
            batches = (reader.get_batch(index) for index in range(reader.num_record_batches))
        except pyarrow.lib.ArrowInvalid:
            shard_file.seek(0)
            batches = pyarrow.ipc.open_stream(shard_file)
        for batch in batches:
            for serialized in batch.column("serialized").to_pylist():
                yield serialized


def clip_key_from_video_name(video_name: str) -> tuple[str, int, int]:
    """The shards name a clip '<full video>_<start s>_<end s>.mp4' ('f896_517_20220723_145022_48.744_51.283.mp4'),
    while the metadata's clipFilename writes the same times in whole milliseconds
    ('001e_159_20220915_163110_104383_116556.mp4'). Both become (full video name, start ms, end ms)."""
    stem = Path(str(video_name)).name.rsplit(".", 1)[0]
    full_video_stem, start_text, end_text = stem.rsplit("_", 2)
    return full_video_stem, round(float(start_text) * 1000), round(float(end_text) * 1000)


def clip_key_from_metadata(record: dict) -> tuple[str, int, int]:
    full_video_stem = Path(record["fullVideoFilename"]).name.rsplit(".", 1)[0]
    return full_video_stem, round(record["annotationStartTimeS"] * 1000), round(record["annotationEndTimeS"] * 1000)


def clip_file_stem(record: dict) -> str:
    """The clip's name in the metadata and in video_clips/, without .mp4."""
    return Path(record["clipFilename"]).name.rsplit(".", 1)[0]


def load_metadata(metadata_path) -> dict:
    """{(full video, start ms, end ms): metadata record} from a <study>-<split>.json."""
    with open(metadata_path) as metadata_file:
        records = json.load(metadata_file)
    return {clip_key_from_metadata(record): record for record in records}


def convert_shard(shard_path, metadata_by_key: dict, output_folder, written_clip_ids: set | None = None) -> dict:
    """Writes one shard's clips and manifest rows. Returns counts (written, sensitive skipped, without metadata,
    empty, already there)."""
    shard_path = Path(shard_path)
    name_match = SHARD_NAME_PATTERN.match(shard_path.name)
    if not name_match:
        raise ValueError(f"not an FSboard shard name: {shard_path.name}")
    study = name_match["study"]
    split = SPEC_SPLIT_BY_FSBOARD_SPLIT.get(name_match["split"], "")
    output_folder = Path(output_folder)
    output_folder.mkdir(parents=True, exist_ok=True)
    written_clip_ids = written_clip_ids if written_clip_ids is not None else set()
    counts = {"written": 0, "sensitive": 0, "no_metadata": 0, "empty": 0, "already_there": 0}
    with ManifestWriter(output_folder, append=True) as manifest_writer:
        for serialized in read_shard_rows(shard_path):
            context, feature_lists = parse_sequence_example(serialized)
            record = metadata_by_key.get(clip_key_from_video_name(context.get("video_name", "")))
            if record is None:
                counts["no_metadata"] += 1
                continue
            if record.get("sensitiveContent"):
                counts["sensitive"] += 1
                continue
            clip_id = f"fsboard-{study}-{clip_file_stem(record)}"
            if clip_id in written_clip_ids:
                counts["already_there"] += 1
                continue
            if landmarks_are_scrambled(feature_lists):
                raise ScrambledLandmarksError(
                    f"{shard_path.name}: {context.get('video_name')} has the scrambled x/y/z layout (see signs/fsboard_source.py); "
                    "extract FSboard's video_clips with sign-extract instead"
                )
            clip = sequence_example_to_clip(feature_lists, context.get("num_frames"))
            if clip.shape[0] == 0:
                counts["empty"] += 1
                continue
            write_clip(output_folder / f"{clip_id}.npy", clip)
            manifest_writer.add(
                ClipRecord(
                    clip_id=clip_id,
                    dataset="fsboard",
                    language="asl",
                    label=str(record["phrase"]).lower(),
                    signer=str(record["signerId"]),
                    split=split,
                    fps=round(float(context.get("image/frame_rate") or 0), 3),
                    width=int(context.get("image/width") or 0),
                    height=int(context.get("image/height") or 0),
                    frames=clip.shape[0],
                    source="mediapipe",
                )
            )
            written_clip_ids.add(clip_id)
            counts["written"] += 1
    return counts


def describe_schema(shard_path, example_count: int = 3) -> str:
    lines = []
    for row_number, serialized in enumerate(read_shard_rows(shard_path)):
        if row_number >= example_count:
            break
        context, feature_lists = parse_sequence_example(serialized)
        lines.append(f"example {row_number}: context {context}")
        for name in sorted(feature_lists):
            lengths = sorted({len(values) for values in feature_lists[name]})
            lines.append(f"  {name}: {len(feature_lists[name])} frames, values per frame {lengths}")
    return "\n".join(lines)


def check_shard_sides(shard_path, sample_count: int = 200) -> dict:
    clips = []
    for row_number, serialized in enumerate(read_shard_rows(shard_path)):
        if row_number >= sample_count:
            break
        context, feature_lists = parse_sequence_example(serialized)
        clips.append(sequence_example_to_clip(feature_lists, context.get("num_frames")))
    return count_hand_sides(clips)


def main(argument_list=None) -> None:
    argument_parser = argparse.ArgumentParser(description="Convert FSboard landmark shards to SPEC clips.")
    subcommands = argument_parser.add_subparsers(dest="command", required=True)
    convert_command = subcommands.add_parser("convert")
    convert_command.add_argument("--shard", required=True, nargs="+")
    convert_command.add_argument("--metadata", required=True, help="the study-split .json the shards belong to")
    convert_command.add_argument("--output", required=True)
    for command_name in ("check-sides", "schema", "check-scrambled"):
        subcommand = subcommands.add_parser(command_name)
        subcommand.add_argument("--shard", required=True)
        subcommand.add_argument("--sample", type=int, default=200)
    parsed_arguments = argument_parser.parse_args(argument_list)

    if parsed_arguments.command == "schema":
        print(describe_schema(parsed_arguments.shard))
        return
    if parsed_arguments.command == "check-scrambled":
        scrambled_count = checked_count = 0
        for row_number, serialized in enumerate(read_shard_rows(parsed_arguments.shard)):
            if row_number >= parsed_arguments.sample:
                break
            scrambled_count += int(landmarks_are_scrambled(parse_sequence_example(serialized)[1]))
            checked_count += 1
        print(f"{scrambled_count} of {checked_count} clips have the scrambled x/y/z layout")
        return
    if parsed_arguments.command == "check-sides":
        print(describe_hand_sides(check_shard_sides(parsed_arguments.shard, parsed_arguments.sample)))
        return
    metadata_by_key = load_metadata(parsed_arguments.metadata)
    output_folder = Path(parsed_arguments.output)
    written_clip_ids = set()
    manifest_path = output_folder / "manifest.csv"
    if manifest_path.exists():
        from .landmarks import read_manifest

        written_clip_ids = {record.clip_id for record in read_manifest(output_folder)}
    for shard_path in parsed_arguments.shard:
        counts = convert_shard(shard_path, metadata_by_key, output_folder, written_clip_ids)
        print(f"{Path(shard_path).name}: {counts}", flush=True)


if __name__ == "__main__":
    main()
