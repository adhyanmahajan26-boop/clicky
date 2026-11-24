"""Landmark layout (SPEC section 1), clip files, manifest.csv and the packed dataset form.

A clip is `[T, 61, 3]` float32: 61 points per frame, each `(x, y, confidence)`, x to the right and y down in
the picture (0 to 1), confidence 0 meaning the point wasn't seen (then x = y = 0). "Right" and "left" are always
the signer's own.
"""

from __future__ import annotations

import argparse
import csv
import json
import os
from dataclasses import dataclass, fields
from pathlib import Path

import numpy as np

POINTS_PER_FRAME = 61
VALUES_PER_POINT = 3  # x, y, confidence
X_COORDINATE = 0
Y_COORDINATE = 1
CONFIDENCE = 2

# Each hand is 21 joints in Vision's (and MediaPipe's) order: wrist, thumb CMC, MP, IP, tip, then index, middle,
# ring and little finger, each MCP (knuckle), PIP, DIP, tip.
HAND_JOINT_COUNT = 21
RIGHT_HAND_START = 0
LEFT_HAND_START = 21
WRIST_JOINT = 0
# The middle finger's knuckle (MCP). Wrist to here is the hand's size (SPEC section 3, step 2).
MIDDLE_KNUCKLE_JOINT = 9

BODY_START = 42
BODY_POINT_COUNT = 13
NOSE = 42
LEFT_EYE = 43
RIGHT_EYE = 44
LEFT_EAR = 45
RIGHT_EAR = 46
LEFT_SHOULDER = 47
RIGHT_SHOULDER = 48
LEFT_ELBOW = 49
RIGHT_ELBOW = 50
LEFT_BODY_WRIST = 51
RIGHT_BODY_WRIST = 52
LEFT_HIP = 53
RIGHT_HIP = 54

MOUTH_START = 55
MOUTH_LEFT_CORNER = 55
MOUTH_RIGHT_CORNER = 56
UPPER_LIP_MIDDLE = 57
LOWER_LIP_MIDDLE = 58

LEFT_BROW_MIDDLE = 59
RIGHT_BROW_MIDDLE = 60

# Points that trade places when the picture is mirrored (the signer's left becomes their right). The two hand
# blocks are swapped as whole blocks; these are the single points with a left and a right twin.
MIRRORED_POINT_PAIRS = (
    (LEFT_EYE, RIGHT_EYE),
    (LEFT_EAR, RIGHT_EAR),
    (LEFT_SHOULDER, RIGHT_SHOULDER),
    (LEFT_ELBOW, RIGHT_ELBOW),
    (LEFT_BODY_WRIST, RIGHT_BODY_WRIST),
    (LEFT_HIP, RIGHT_HIP),
    (MOUTH_LEFT_CORNER, MOUTH_RIGHT_CORNER),
    (LEFT_BROW_MIDDLE, RIGHT_BROW_MIDDLE),
)

MANIFEST_FILE_NAME = "manifest.csv"
PACKED_FRAMES_FILE_NAME = "frames.npy"
PACKED_OFFSETS_FILE_NAME = "offsets.npy"
# Written last by `pack`: says the packed frames are at 30 a second (SPEC section 3, "Frame rate"). A pack made
# before that rule has no such file, so it counts as not packed and is packed again on first use.
PACKED_DESCRIPTION_FILE_NAME = "packed.json"
PACKED_DESCRIPTION = {"frames_per_second": 30, "frame_rate_rule": "SPEC section 3, Frame rate"}
MANIFEST_COLUMNS = (
    "clip_id",
    "dataset",
    "language",
    "label",
    "signer",
    "split",
    "fps",
    "width",
    "height",
    "frames",
    "source",
)


def empty_clip(frame_count: int) -> np.ndarray:
    """A clip with nothing seen: every point has confidence 0 and x = y = 0."""
    return np.zeros((frame_count, POINTS_PER_FRAME, VALUES_PER_POINT), dtype=np.float32)


def check_clip_shape(landmarks: np.ndarray) -> None:
    if landmarks.ndim != 3 or landmarks.shape[1:] != (POINTS_PER_FRAME, VALUES_PER_POINT):
        raise ValueError(f"a clip must be [T, {POINTS_PER_FRAME}, {VALUES_PER_POINT}], got {landmarks.shape}")


def write_clip(path: str | os.PathLike, landmarks: np.ndarray) -> None:
    """Writes `<clip id>.npy`: NumPy format 1.0, little-endian float32, C order, `[T, 61, 3]`."""
    check_clip_shape(landmarks)
    little_endian_landmarks = np.ascontiguousarray(landmarks, dtype="<f4")
    with open(path, "wb") as clip_file:
        np.lib.format.write_array(clip_file, little_endian_landmarks, version=(1, 0), allow_pickle=False)


def read_clip(path: str | os.PathLike) -> np.ndarray:
    landmarks = np.load(path, allow_pickle=False).astype(np.float32, copy=False)
    check_clip_shape(landmarks)
    return landmarks


@dataclass
class ClipRecord:
    """One row of manifest.csv."""

    clip_id: str
    dataset: str
    language: str
    label: str
    signer: str
    split: str
    fps: float
    width: int
    height: int
    frames: int
    source: str


def read_manifest(folder: str | os.PathLike) -> list[ClipRecord]:
    """Reads manifest.csv with every text column kept as text (a label such as "null" or "nan" stays a word)."""
    manifest_path = Path(folder) / MANIFEST_FILE_NAME
    clip_records = []
    with open(manifest_path, newline="", encoding="utf-8") as manifest_file:
        for row in csv.DictReader(manifest_file):
            clip_records.append(
                ClipRecord(
                    clip_id=row["clip_id"],
                    dataset=row["dataset"],
                    language=row["language"],
                    label=row["label"],
                    signer=row["signer"],
                    split=row.get("split", "") or "",
                    fps=float(row["fps"] or 0),
                    width=int(float(row["width"] or 0)),
                    height=int(float(row["height"] or 0)),
                    frames=int(float(row["frames"])),
                    source=row["source"],
                )
            )
    return clip_records


def write_manifest(folder: str | os.PathLike, clip_records: list[ClipRecord]) -> None:
    manifest_path = Path(folder) / MANIFEST_FILE_NAME
    with open(manifest_path, "w", newline="", encoding="utf-8") as manifest_file:
        manifest_writer = csv.writer(manifest_file)
        manifest_writer.writerow(MANIFEST_COLUMNS)
        for clip_record in clip_records:
            manifest_writer.writerow(_manifest_row_values(clip_record))


def _manifest_row_values(clip_record: ClipRecord) -> list[str]:
    row_values = []
    for field in fields(ClipRecord):
        value = getattr(clip_record, field.name)
        # fps is written as a whole number when it is one, so a manifest reads "30", not "30.0".
        if field.name == "fps" and float(value).is_integer():
            value = int(value)
        row_values.append(str(value))
    return row_values


class ManifestWriter:
    """Appends manifest rows one at a time, so a long conversion keeps what it has done if it stops."""

    def __init__(self, folder: str | os.PathLike):
        self.manifest_path = Path(folder) / MANIFEST_FILE_NAME
        self.manifest_file = open(self.manifest_path, "w", newline="", encoding="utf-8")
        self.manifest_writer = csv.writer(self.manifest_file)
        self.manifest_writer.writerow(MANIFEST_COLUMNS)

    def add(self, clip_record: ClipRecord) -> None:
        self.manifest_writer.writerow(_manifest_row_values(clip_record))

    def close(self) -> None:
        self.manifest_file.close()

    def __enter__(self) -> "ManifestWriter":
        return self

    def __exit__(self, *exception_details) -> None:
        self.close()


def pack(folder: str | os.PathLike) -> None:
    """Packs a folder of clip .npy files into `frames.npy` + `offsets.npy` next to manifest.csv.

    `frames.npy` is every clip's frames one after another, float32 `[total_frames, 61, 3]`, in manifest row order;
    `offsets.npy` is int64 `[clip_count, 2]` holding each clip's (first frame, frame count). Reading thousands of
    tiny files per epoch is slow, while one memory-mapped file is fast and shared by every loader process.

    Each clip is brought to 30 frames a second from its manifest `fps` on the way in (`signs/frame_rate.py`), so
    every model, in training and evaluation, only ever sees 30 a second; offsets count the packed frames.
    """
    # Imported here because frame_rate is a small leaf module and this keeps landmarks importable on its own.
    from .frame_rate import resample_clip_to_30_per_second, resampled_frame_count

    folder = Path(folder)
    # Until the new pack is complete, the folder must not look packed (the old description could vouch for a
    # half-replaced pack).
    (folder / PACKED_DESCRIPTION_FILE_NAME).unlink(missing_ok=True)
    clip_records = read_manifest(folder)
    clip_frame_counts = []
    for clip_record in clip_records:
        # Opening with mmap only reads the header, so this first pass is quick even for big datasets.
        clip_array = np.load(folder / f"{clip_record.clip_id}.npy", mmap_mode="r", allow_pickle=False)
        check_clip_shape(clip_array)
        if clip_array.shape[0] != clip_record.frames:
            raise ValueError(
                f"{clip_record.clip_id}: manifest says {clip_record.frames} frames, file has {clip_array.shape[0]}"
            )
        clip_frame_counts.append(resampled_frame_count(clip_array.shape[0], clip_record.fps))

    clip_frame_counts_array = np.asarray(clip_frame_counts, dtype=np.int64)
    clip_offsets = np.zeros((len(clip_records), 2), dtype=np.int64)
    if len(clip_records) > 0:
        clip_offsets[1:, 0] = np.cumsum(clip_frame_counts_array)[:-1]
        clip_offsets[:, 1] = clip_frame_counts_array
    total_frame_count = int(clip_frame_counts_array.sum())

    # Written under temporary names and renamed at the end, so a stopped pack never leaves a half file that
    # looks finished.
    temporary_frames_path = folder / (PACKED_FRAMES_FILE_NAME + ".partial")
    temporary_offsets_path = folder / (PACKED_OFFSETS_FILE_NAME + ".partial")
    packed_frames = np.lib.format.open_memmap(
        temporary_frames_path,
        mode="w+",
        dtype="<f4",
        shape=(total_frame_count, POINTS_PER_FRAME, VALUES_PER_POINT),
        version=(1, 0),
    )
    for clip_record, (first_frame, frame_count) in zip(clip_records, clip_offsets):
        packed_frames[first_frame : first_frame + frame_count] = resample_clip_to_30_per_second(
            read_clip(folder / f"{clip_record.clip_id}.npy"), clip_record.fps
        )
    packed_frames.flush()
    del packed_frames
    with open(temporary_offsets_path, "wb") as offsets_file:
        np.lib.format.write_array(offsets_file, clip_offsets, version=(1, 0), allow_pickle=False)
    os.replace(temporary_frames_path, folder / PACKED_FRAMES_FILE_NAME)
    os.replace(temporary_offsets_path, folder / PACKED_OFFSETS_FILE_NAME)
    (folder / PACKED_DESCRIPTION_FILE_NAME).write_text(json.dumps(PACKED_DESCRIPTION, sort_keys=True), encoding="utf-8")


def is_packed(folder: str | os.PathLike) -> bool:
    folder = Path(folder)
    if not ((folder / PACKED_FRAMES_FILE_NAME).exists() and (folder / PACKED_OFFSETS_FILE_NAME).exists()):
        return False
    try:
        packed_description = json.loads((folder / PACKED_DESCRIPTION_FILE_NAME).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return False
    return packed_description == PACKED_DESCRIPTION


class PackedDataset:
    """A packed dataset folder: manifest rows plus memory-mapped frames.

    The memory map is opened lazily and dropped when pickled, so DataLoader worker processes (started with
    "spawn" on macOS) each open their own map instead of copying every frame through a pipe.
    """

    def __init__(self, folder: str | os.PathLike):
        self.folder = Path(folder).resolve()
        if not is_packed(self.folder):
            raise FileNotFoundError(f"{self.folder} is not packed: run `python -m signs.landmarks pack {folder}`")
        self.clip_records = read_manifest(self.folder)
        self.clip_offsets = np.load(self.folder / PACKED_OFFSETS_FILE_NAME, allow_pickle=False)
        if len(self.clip_offsets) != len(self.clip_records):
            raise ValueError(f"{self.folder}: offsets.npy and manifest.csv disagree on the clip count; pack again")
        # The packed clips are at 30 frames a second, so a clip's frame count is the packed one, not the file's.
        for clip_record, (first_frame, packed_frame_count) in zip(self.clip_records, self.clip_offsets):
            clip_record.frames = int(packed_frame_count)
        self._packed_frames = None

    def __len__(self) -> int:
        return len(self.clip_records)

    @property
    def packed_frames(self) -> np.ndarray:
        if self._packed_frames is None:
            self._packed_frames = np.load(self.folder / PACKED_FRAMES_FILE_NAME, mmap_mode="r", allow_pickle=False)
        return self._packed_frames

    def clip(self, clip_index: int) -> np.ndarray:
        """One clip's landmarks as its own float32 array (a copy, safe to change)."""
        first_frame, frame_count = self.clip_offsets[clip_index]
        return np.array(self.packed_frames[first_frame : first_frame + frame_count], dtype=np.float32)

    def __getstate__(self) -> dict:
        picklable_state = dict(self.__dict__)
        picklable_state["_packed_frames"] = None
        return picklable_state


def load_packed(folder: str | os.PathLike, pack_if_needed: bool = True) -> PackedDataset:
    if pack_if_needed and not is_packed(folder):
        print(f"packing {folder} (first use)", flush=True)
        pack(folder)
    return PackedDataset(folder)


def main() -> None:
    argument_parser = argparse.ArgumentParser(description="Landmark dataset tools.")
    subcommands = argument_parser.add_subparsers(dest="command", required=True)
    pack_command = subcommands.add_parser("pack", help="pack a dataset folder into frames.npy + offsets.npy")
    pack_command.add_argument("folders", nargs="+")
    parsed_arguments = argument_parser.parse_args()
    if parsed_arguments.command == "pack":
        for folder in parsed_arguments.folders:
            pack(folder)
            print(f"packed {folder}")


if __name__ == "__main__":
    main()
