"""The two Kaggle converters on tiny parquet files made here with the same columns as the real ones."""

import numpy as np
import pandas
import pytest

from signs import mediapipe_sources
from signs.landmarks import (
    BODY_START,
    CONFIDENCE,
    LEFT_BROW_MIDDLE,
    LEFT_HAND_START,
    LEFT_SHOULDER,
    MOUTH_LEFT_CORNER,
    RIGHT_HAND_START,
    RIGHT_SHOULDER,
    load_packed,
    read_clip,
    read_manifest,
)

PART_SIZES = {"face": 468, "left_hand": 21, "pose": 33, "right_hand": 21}


def landmark_place(part_name: str, landmark_index: int, frame: int) -> tuple[float, float]:
    """A distinct, predictable place for every landmark, so the test can check where each one ended up."""
    part_number = list(PART_SIZES).index(part_name)
    return 0.1 * part_number + 0.001 * landmark_index + 0.0001 * frame, 0.5 + 0.0002 * landmark_index + 0.01 * frame


def part_is_missing(part_name: str, frame: int) -> bool:
    # The left hand is missing in frame 1; everything else is always there.
    return part_name == "left_hand" and frame == 1


def write_isolated_parquet(path, frame_count: int, first_frame: int = 20):
    rows = []
    for frame in range(frame_count):
        for part_name, landmark_count in PART_SIZES.items():
            for landmark_index in range(landmark_count):
                x_place, y_place = landmark_place(part_name, landmark_index, frame)
                if part_is_missing(part_name, frame):
                    x_place = y_place = np.nan
                rows.append(
                    (first_frame + frame, f"{first_frame + frame}-{part_name}-{landmark_index}", part_name, landmark_index, x_place, y_place, 0.0)
                )
    pandas.DataFrame(rows, columns=["frame", "row_id", "type", "landmark_index", "x", "y", "z"]).to_parquet(path)


def check_converted_clip(clip: np.ndarray, frame_count: int):
    assert clip.shape == (frame_count, 61, 3)
    for frame in range(frame_count):
        np.testing.assert_allclose(clip[frame, RIGHT_HAND_START + 5, :2], landmark_place("right_hand", 5, frame), atol=1e-6)
        np.testing.assert_allclose(clip[frame, LEFT_SHOULDER, :2], landmark_place("pose", 11, frame), atol=1e-6)
        np.testing.assert_allclose(clip[frame, RIGHT_SHOULDER, :2], landmark_place("pose", 12, frame), atol=1e-6)
        np.testing.assert_allclose(clip[frame, BODY_START, :2], landmark_place("pose", 0, frame), atol=1e-6)
        np.testing.assert_allclose(clip[frame, MOUTH_LEFT_CORNER, :2], landmark_place("face", 291, frame), atol=1e-6)
        np.testing.assert_allclose(clip[frame, LEFT_BROW_MIDDLE, :2], landmark_place("face", 334, frame), atol=1e-6)
    assert np.all(clip[1, LEFT_HAND_START : LEFT_HAND_START + 21] == 0)
    assert np.all(clip[0, LEFT_HAND_START : LEFT_HAND_START + 21, CONFIDENCE] == 1)
    assert np.all(clip[:, RIGHT_HAND_START : RIGHT_HAND_START + 21, CONFIDENCE] == 1)


def test_isolated_sign_converter(tmp_path):
    kaggle_folder = tmp_path / "kaggle"
    (kaggle_folder / "train_landmark_files" / "16069").mkdir(parents=True)
    write_isolated_parquet(kaggle_folder / "train_landmark_files/16069/100015657.parquet", 3)
    write_isolated_parquet(kaggle_folder / "train_landmark_files/16069/100015658.parquet", 4)
    pandas.DataFrame(
        {
            "path": ["train_landmark_files/16069/100015657.parquet", "train_landmark_files/16069/100015658.parquet"],
            "participant_id": [16069, 16069],
            "sequence_id": [100015657, 100015658],
            "sign": ["Blow", "null"],
        }
    ).to_csv(kaggle_folder / "train.csv", index=False)

    output_folder = tmp_path / "converted"
    mediapipe_sources.main(["isolated", "--kaggle", str(kaggle_folder), "--output", str(output_folder)])
    clip_records = read_manifest(output_folder)
    assert [clip_record.label for clip_record in clip_records] == ["blow", "null"]
    assert clip_records[0].clip_id == "asl-signs-100015657" and clip_records[0].signer == "16069"
    assert (clip_records[0].source, clip_records[0].width, clip_records[0].height, clip_records[0].fps) == ("mediapipe", 0, 0, 30)
    check_converted_clip(read_clip(output_folder / "asl-signs-100015657.npy"), 3)
    check_converted_clip(load_packed(output_folder).clip(1), 4)


def write_fingerspelling_parquet(path, frame_counts_by_sequence: dict[int, int]):
    rows = []
    for sequence_id, frame_count in frame_counts_by_sequence.items():
        # Frames are written newest first to check the converter sorts them.
        for frame in reversed(range(frame_count)):
            row = {"sequence_id": sequence_id, "frame": frame}
            for coordinate_number, coordinate in enumerate("xyz"):
                for part_name, landmark_count in PART_SIZES.items():
                    for landmark_index in range(landmark_count):
                        place = landmark_place(part_name, landmark_index, frame)
                        value = place[coordinate_number] if coordinate != "z" else 0.0
                        row[f"{coordinate}_{part_name}_{landmark_index}"] = np.nan if part_is_missing(part_name, frame) else value
            rows.append(row)
    pandas.DataFrame(rows).astype({"frame": "int16"}).set_index("sequence_id").to_parquet(path)


def test_fingerspelling_converter(tmp_path):
    kaggle_folder = tmp_path / "kaggle"
    (kaggle_folder / "train_landmarks").mkdir(parents=True)
    (kaggle_folder / "supplemental_landmarks").mkdir(parents=True)
    write_fingerspelling_parquet(kaggle_folder / "train_landmarks/5414471.parquet", {1816796431: 3, 1816825349: 5})
    write_fingerspelling_parquet(kaggle_folder / "supplemental_landmarks/33432165.parquet", {77: 4})
    metadata_columns = ["path", "file_id", "sequence_id", "participant_id", "phrase"]
    pandas.DataFrame(
        [
            ["train_landmarks/5414471.parquet", 5414471, 1816796431, 217, "3 Creekhouse"],
            ["train_landmarks/5414471.parquet", 5414471, 1816825349, 107, "scales/kuhaylah"],
        ],
        columns=metadata_columns,
    ).to_csv(kaggle_folder / "train.csv", index=False)
    pandas.DataFrame(
        [["supplemental_landmarks/33432165.parquet", 33432165, 77, 5, "Hello World"]], columns=metadata_columns
    ).to_csv(kaggle_folder / "supplemental_metadata.csv", index=False)

    output_folder = tmp_path / "converted"
    mediapipe_sources.main(["fingerspelling", "--kaggle", str(kaggle_folder), "--output", str(output_folder)])
    clip_records = read_manifest(output_folder)
    assert sorted(clip_record.label for clip_record in clip_records) == ["3 creekhouse", "hello world", "scales/kuhaylah"]
    frame_count_by_clip = {clip_record.clip_id: clip_record.frames for clip_record in clip_records}
    assert frame_count_by_clip == {
        "asl-fingerspelling-1816796431": 3,
        "asl-fingerspelling-1816825349": 5,
        "asl-fingerspelling-77": 4,
    }
    check_converted_clip(read_clip(output_folder / "asl-fingerspelling-1816825349.npy"), 5)
    check_converted_clip(read_clip(output_folder / "asl-fingerspelling-77.npy"), 4)


def test_hand_side_check(tmp_path, capsys):
    clip = np.zeros((2, 61, 3), np.float32)
    clip[:, RIGHT_HAND_START] = (0.38, 0.6, 1)
    clip[:, LEFT_HAND_START] = (0.40, 0.6, 1)
    clip[:, 52] = (0.37, 0.62, 1)  # body right wrist (pose 16)
    clip[:, 51] = (0.62, 0.62, 1)  # body left wrist (pose 15)
    counts = mediapipe_sources.count_hand_sides([clip])
    assert counts == {"right_hand_frames": 2, "right_hand_nearer_pose_16": 2, "left_hand_frames": 2, "left_hand_nearer_pose_15": 0}
    assert "100.0% of 2 frames" in mediapipe_sources.describe_hand_sides(counts)

    kaggle_folder = tmp_path / "kaggle"
    kaggle_folder.mkdir()
    write_isolated_parquet(kaggle_folder / "one.parquet", 2)
    pandas.DataFrame({"path": ["one.parquet"], "participant_id": [1], "sequence_id": [1], "sign": ["a"]}).to_csv(
        kaggle_folder / "train.csv", index=False
    )
    mediapipe_sources.main(["isolated", "--kaggle", str(kaggle_folder), "--check-sides"])
    assert "pose 16" in capsys.readouterr().out


def test_hand_mapping_is_one_constant():
    sources = mediapipe_sources.mediapipe_sources_for_spec_points()
    assert sources[0] == (mediapipe_sources.SIGNER_RIGHT_HAND_MEDIAPIPE_PART, 0)
    assert sources[21] == (mediapipe_sources.SIGNER_LEFT_HAND_MEDIAPIPE_PART, 0)
    assert [landmark for part, landmark in sources[42:55]] == [0, 2, 5, 7, 8, 11, 12, 13, 14, 15, 16, 23, 24]
    assert sources[55:] == [("face", 291), ("face", 61), ("face", 0), ("face", 17), ("face", 334), ("face", 105)]
    with pytest.raises(SystemExit):
        mediapipe_sources.main(["isolated", "--kaggle", "nowhere"])
