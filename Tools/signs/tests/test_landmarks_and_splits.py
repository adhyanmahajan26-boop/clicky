import pickle

import numpy as np

from signs.landmarks import (
    ClipRecord,
    PackedDataset,
    empty_clip,
    load_packed,
    read_clip,
    read_manifest,
    write_clip,
    write_manifest,
)
from signs.splits import split_signers
from synthetic_signs import write_dataset


def test_clip_file_format(tmp_path):
    clip = np.random.default_rng(0).random((5, 61, 3)).astype(np.float32)
    write_clip(tmp_path / "a.npy", clip)
    with open(tmp_path / "a.npy", "rb") as clip_file:
        assert clip_file.read(8) == b"\x93NUMPY\x01\x00"  # format 1.0
    np.testing.assert_array_equal(read_clip(tmp_path / "a.npy"), clip)
    assert np.load(tmp_path / "a.npy").dtype.str == "<f4"


def test_manifest_round_trip_keeps_words_as_text(tmp_path):
    clip_records = [
        ClipRecord("c1", "ds", "asl", "nan", "7", "", 30, 0, 0, 12, "mediapipe"),
        ClipRecord("c2", "ds", "isl", "null, maybe", "8", "test", 29.97, 1920, 1080, 3, "apple"),
    ]
    write_manifest(tmp_path, clip_records)
    assert read_manifest(tmp_path) == clip_records
    header = (tmp_path / "manifest.csv").read_text().splitlines()[0]
    assert header == "clip_id,dataset,language,label,signer,split,fps,width,height,frames,source"


def test_packed_dataset_round_trip(tmp_path):
    generator = np.random.default_rng(1)
    clips_and_records = []
    for clip_number, frame_count in enumerate([3, 0, 7, 1]):
        clip = generator.random((frame_count, 61, 3)).astype(np.float32)
        clips_and_records.append(
            (clip, ClipRecord(f"clip{clip_number}", "ds", "asl", "word", "s", "", 30, 0, 0, frame_count, "apple"))
        )
    write_dataset(tmp_path, clips_and_records)
    packed = load_packed(tmp_path)
    assert len(packed) == 4
    assert np.load(tmp_path / "frames.npy", mmap_mode="r").shape == (11, 61, 3)
    for clip_number, (clip, clip_record) in enumerate(clips_and_records):
        np.testing.assert_array_equal(packed.clip(clip_number), clip)
    # A dataset sent to a loader worker carries no frames; the worker opens its own memory map.
    unpickled = pickle.loads(pickle.dumps(packed))
    assert unpickled._packed_frames is None
    np.testing.assert_array_equal(unpickled.clip(2), clips_and_records[2][0])
    assert isinstance(unpickled, PackedDataset)


def test_empty_clip_is_all_missing():
    assert empty_clip(3).shape == (3, 61, 3) and not empty_clip(3).any()


def test_signer_split_is_seeded_disjoint_and_order_free():
    signers = [f"p{number}" for number in range(40)]
    first = split_signers(signers, seed=3)
    assert first == split_signers(list(reversed(signers)) + signers, seed=3)
    assert first != split_signers(signers, seed=4)
    split_counts = {split: sum(1 for value in first.values() if value == split) for split in ("train", "val", "test")}
    assert split_counts == {"train": 30, "val": 4, "test": 6}
    small = split_signers(["a", "b", "c"], seed=0)
    assert sorted(small.values()) == ["test", "train", "val"]
    assert split_signers(["only"], seed=0) == {"only": "train"}
