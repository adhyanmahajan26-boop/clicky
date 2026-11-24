"""FSboard shards: a tiny made-up shard written the way Google's are (Arrow IPC, one `serialized` column of
tf.train.SequenceExample bytes), read back into SPEC clips and manifest rows, and the scrambled layout refused."""

import json
import struct

import numpy as np
import pytest

from signs import fsboard_source
from signs.landmarks import CONFIDENCE, LEFT_HAND_START, RIGHT_HAND_START, read_clip, read_manifest

pyarrow = pytest.importorskip("pyarrow")


# ---- a minimal protobuf writer, the mirror of the reader under test ----


def _varint(value: int) -> bytes:
    out = bytearray()
    while True:
        byte = value & 0x7F
        value >>= 7
        if value:
            out.append(byte | 0x80)
        else:
            out.append(byte)
            return bytes(out)


def _length_delimited(field_number: int, payload: bytes) -> bytes:
    return _varint(field_number << 3 | 2) + _varint(len(payload)) + payload


def _float_feature(values) -> bytes:
    packed = struct.pack(f"<{len(values)}f", *values)
    float_list = _length_delimited(1, packed) if len(values) else b""
    return _length_delimited(2, float_list)


def _int_feature(value: int) -> bytes:
    return _length_delimited(3, _length_delimited(1, _varint(value)))


def _bytes_feature(text: str) -> bytes:
    return _length_delimited(1, _length_delimited(1, text.encode()))


def _map(entries: dict) -> bytes:
    return b"".join(
        _length_delimited(1, _length_delimited(1, key.encode()) + _length_delimited(2, value)) for key, value in entries.items()
    )


def _sequence_example(context: dict, feature_lists: dict) -> bytes:
    lists = {name: b"".join(_length_delimited(1, frame) for frame in frames) for name, frames in feature_lists.items()}
    return _length_delimited(1, _map(context)) + _length_delimited(2, _map(lists))


def _example_clip(video_name: str, frame_count: int, scrambled: bool = False) -> bytes:
    """Pose (25 points), a right hand on the picture's left near pose 16, no left hand, a face of 478 points."""
    rng = np.random.default_rng(len(video_name))
    feature_lists = {}
    sizes = {"pose": 25, "right_hand": 21, "left_hand": 0, "face": 478}
    for part, size in sizes.items():
        for axis in ("x", "y", "z", "presence", "visibility"):
            feature_lists[f"{axis}_{part}"] = []
        for frame_index in range(frame_count):
            x_values = rng.uniform(0.2, 0.8, size).astype(np.float32)
            y_values = rng.uniform(0.2, 0.8, size).astype(np.float32)
            z_values = rng.uniform(-0.1, 0.1, size).astype(np.float32)
            if part == "pose":
                x_values[16], y_values[16] = 0.3, 0.7  # the signer's right wrist, on the picture's left
                x_values[15], y_values[15] = 0.7, 0.7
            if part == "right_hand" and size:
                x_values[0], y_values[0] = 0.31, 0.69
            if scrambled and size:
                interleaved = np.stack([x_values, y_values, z_values], axis=1).reshape(-1)
                x_values, y_values, z_values = interleaved[0:size], interleaved[1 : size + 1], interleaved[2 : size + 2]
            visibility = np.full(size, 5.0 if part == "pose" else 0.0, dtype=np.float32)
            for axis, values in (("x", x_values), ("y", y_values), ("z", z_values), ("presence", visibility), ("visibility", visibility)):
                feature_lists[f"{axis}_{part}"].append(_float_feature(values.tolist()))
    feature_lists["timestamp"] = [_length_delimited(3, _length_delimited(1, _varint(index))) for index in range(frame_count)]
    context = {
        "video_name": _bytes_feature(video_name),
        "signer_id": _bytes_feature("ab12"),
        "num_frames": _int_feature(frame_count),
        "image/width": _int_feature(1080),
        "image/height": _int_feature(1920),
        "image/frame_rate": _length_delimited(2, _length_delimited(1, struct.pack("<f", 29.875))),
        "prompt": _bytes_feature("12 Main St"),
    }
    return _sequence_example(context, feature_lists)


def _write_shard(path, serialized_examples):
    table = pyarrow.table({"serialized": pyarrow.array(serialized_examples, type=pyarrow.binary())})
    with pyarrow.OSFile(str(path), "wb") as sink, pyarrow.ipc.new_file(sink, table.schema) as writer:
        writer.write_table(table)


def _metadata_record(full_video: str, start: float, end: float, phrase: str, sensitive: bool):
    return {
        "clipFilename": f"{full_video}_{round(start * 1000)}_{round(end * 1000)}.mp4",
        "fullVideoFilename": f"{full_video}.mp4",
        "annotationStartTimeS": start,
        "annotationEndTimeS": end,
        "phrase": phrase,
        "signerId": "ab12",
        "sensitiveContent": sensitive,
    }


def test_a_made_up_shard_becomes_spec_clips_and_manifest_rows(tmp_path):
    shard_path = tmp_path / "daun_v3-validation.arrow-00000-of-00001"
    _write_shard(
        shard_path,
        [
            _example_clip("ab12_1_20220101_000000_48.744_51.283.mp4", 4),
            _example_clip("ab12_1_20220101_000000_60.5_61.25.mp4", 3),  # flagged sensitive below
            _example_clip("zz99_9_20220101_000000_1.0_2.0.mp4", 2),  # not in the metadata
        ],
    )
    metadata_path = tmp_path / "daun_v3-validation.json"
    metadata_path.write_text(json.dumps([
        _metadata_record("ab12_1_20220101_000000", 48.744, 51.283, "12 Main St", False),
        _metadata_record("ab12_1_20220101_000000", 60.5, 61.25, "something private", True),
    ]))
    output_folder = tmp_path / "out"
    counts = fsboard_source.convert_shard(shard_path, fsboard_source.load_metadata(metadata_path), output_folder)
    assert counts == {"written": 1, "sensitive": 1, "no_metadata": 1, "empty": 0, "already_there": 0}

    records = read_manifest(output_folder)
    assert len(records) == 1
    record = records[0]
    assert record.clip_id == "fsboard-daun_v3-ab12_1_20220101_000000_48744_51283"
    assert (record.dataset, record.language, record.label, record.signer, record.split, record.source) == (
        "fsboard", "asl", "12 main st", "ab12", "val", "mediapipe")
    assert (record.width, record.height, record.frames) == (1080, 1920, 4)
    assert abs(record.fps - 29.875) < 1e-3

    clip = read_clip(output_folder / f"{record.clip_id}.npy")
    assert clip.shape == (4, 61, 3)
    assert (clip[:, RIGHT_HAND_START : RIGHT_HAND_START + 21, CONFIDENCE] == 1).all()
    assert (clip[:, LEFT_HAND_START : LEFT_HAND_START + 21, CONFIDENCE] == 0).all()
    assert np.allclose(clip[:, RIGHT_HAND_START, :2], [0.31, 0.69])
    # pose visibility (a logit in FSboard) becomes the body points' confidence
    assert np.allclose(clip[:, 42:55, CONFIDENCE], 1 / (1 + np.exp(-5.0)))

    # a second shard appends to the same manifest instead of starting it again
    second_shard_path = tmp_path / "daun_v3-validation.arrow-00001-of-00001"
    _write_shard(second_shard_path, [_example_clip("ab12_1_20220101_000000_60.5_61.25.mp4", 3)])
    fsboard_source.convert_shard(second_shard_path, fsboard_source.load_metadata(metadata_path), output_folder)
    assert len(read_manifest(output_folder)) == 1


def test_sides_follow_the_pose_wrists():
    context, feature_lists = fsboard_source.parse_sequence_example(_example_clip("ab12_1_x_000000_1.0_2.0.mp4", 3))
    clip = fsboard_source.sequence_example_to_clip(feature_lists, context["num_frames"])
    from signs.mediapipe_sources import count_hand_sides

    counts = count_hand_sides([clip])
    assert counts["right_hand_frames"] == 3 and counts["right_hand_nearer_pose_16"] == 3


def test_the_scrambled_layout_is_found_refused_and_partly_recovered(tmp_path):
    serialized = _example_clip("ab12_1_20220101_000000_48.744_51.283.mp4", 2, scrambled=True)
    context, feature_lists = fsboard_source.parse_sequence_example(serialized)
    assert fsboard_source.landmarks_are_scrambled(feature_lists)
    assert not fsboard_source.landmarks_are_scrambled(fsboard_source.parse_sequence_example(_example_clip("ab12_x_1.0_2.0.mp4", 2))[1])

    recovered = fsboard_source.unscramble_landmarks(
        feature_lists["x_right_hand"][0], feature_lists["y_right_hand"][0], feature_lists["z_right_hand"][0]
    )
    assert recovered.shape == (7, 3)  # 21 + 2 values: 7 whole landmarks
    assert np.allclose(recovered[0, :2], [0.31, 0.69])

    shard_path = tmp_path / "dmk_v3-train.arrow-00000-of-00001"
    _write_shard(shard_path, [serialized])
    metadata = {fsboard_source.clip_key_from_video_name("ab12_1_20220101_000000_48.744_51.283.mp4"):
                _metadata_record("ab12_1_20220101_000000", 48.744, 51.283, "hello", False)}
    with pytest.raises(fsboard_source.ScrambledLandmarksError):
        fsboard_source.convert_shard(shard_path, metadata, tmp_path / "out")


def test_clip_names_in_the_shards_and_the_metadata_match():
    assert fsboard_source.clip_key_from_video_name("001e_159_20220915_163110_104.383_116.556.mp4") == fsboard_source.clip_key_from_metadata(
        _metadata_record("001e_159_20220915_163110", 104.383, 116.556, "x", False)
    )
