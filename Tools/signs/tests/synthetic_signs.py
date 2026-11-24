"""Small synthetic sign datasets for the tests: no real data is needed."""

from __future__ import annotations

from pathlib import Path

import numpy as np

from signs.landmarks import LEFT_HAND_START, RIGHT_HAND_START, ClipRecord, empty_clip, pack, write_clip, write_manifest
from signs.make_golden import place_body, place_hand

WORD_TRAJECTORIES = ("circle", "right", "up", "down_left", "still")
SPELLING_ALPHABET = "abcd"


def wrist_trajectory_clip(word_number: int, frame_count: int, generator: np.random.Generator) -> np.ndarray:
    """A right hand whose wrist follows the word's own path; the five words differ only in that path."""
    clip = empty_clip(frame_count)
    start_place = np.array([0.42, 0.55]) + generator.normal(scale=0.01, size=2)
    hand_size = generator.uniform(0.05, 0.07)
    for frame in range(frame_count):
        progress = frame / max(frame_count - 1, 1)
        trajectory = WORD_TRAJECTORIES[word_number]
        if trajectory == "circle":
            offset = 0.08 * np.array([np.cos(2 * np.pi * progress) - 1, np.sin(2 * np.pi * progress)])
        elif trajectory == "right":
            offset = np.array([0.15 * progress, 0.0])
        elif trajectory == "up":
            offset = np.array([0.0, -0.15 * progress])
        elif trajectory == "down_left":
            offset = np.array([-0.1 * progress, 0.1 * progress])
        else:
            offset = np.zeros(2)
        wrist_place = start_place + offset + generator.normal(scale=0.003, size=2)
        place_body(clip, frame)
        place_hand(clip, frame, RIGHT_HAND_START, wrist_place, hand_size)
    return clip


def spelling_clip(phrase: str, generator: np.random.Generator, frames_per_character: int = 8) -> np.ndarray:
    """Each character is a held hand tilt at its own place, with a couple of moving frames between."""
    frame_count = frames_per_character * len(phrase)
    clip = empty_clip(frame_count)
    hand_size = generator.uniform(0.05, 0.07)
    for character_position, character in enumerate(phrase):
        character_number = SPELLING_ALPHABET.index(character)
        for frame_in_character in range(frames_per_character):
            frame = character_position * frames_per_character + frame_in_character
            place_body(clip, frame)
            wrist_place = (0.40 + 0.04 * character_number, 0.55) + generator.normal(scale=0.002, size=2)
            place_hand(clip, frame, RIGHT_HAND_START, wrist_place, hand_size, tilt_degrees=-30 + 25 * character_number)
            if character_number % 2 == 1:
                place_hand(clip, frame, LEFT_HAND_START, (0.62, 0.6), hand_size)
    return clip


def write_dataset(folder: Path, clips_and_records: list[tuple[np.ndarray, ClipRecord]], should_pack: bool = True) -> Path:
    folder.mkdir(parents=True, exist_ok=True)
    for clip, clip_record in clips_and_records:
        write_clip(folder / f"{clip_record.clip_id}.npy", clip)
    write_manifest(folder, [clip_record for clip, clip_record in clips_and_records])
    if should_pack:
        pack(folder)
    return folder


def make_word_dataset(folder: Path, clips_per_word_per_signer: int = 2, signer_count: int = 6, seed: int = 0) -> Path:
    generator = np.random.default_rng(seed)
    clips_and_records = []
    for signer_number in range(signer_count):
        for word_number, word in enumerate(WORD_TRAJECTORIES):
            for repeat in range(clips_per_word_per_signer):
                frame_count = int(generator.integers(20, 40))
                clip = wrist_trajectory_clip(word_number, frame_count, generator)
                clip_id = f"words-{signer_number}-{word}-{repeat}"
                clips_and_records.append(
                    (clip, ClipRecord(clip_id, "synthetic-words", "asl", word, f"signer{signer_number}", "", 30, 640, 480, frame_count, "apple"))
                )
    return write_dataset(folder, clips_and_records)


def random_phrase(generator: np.random.Generator) -> str:
    return "".join(generator.choice(list(SPELLING_ALPHABET), size=int(generator.integers(2, 5))))


def make_spelling_dataset(folder: Path, phrases_per_signer: int = 8, signer_count: int = 6, seed: int = 0) -> Path:
    generator = np.random.default_rng(seed)
    clips_and_records = []
    for signer_number in range(signer_count):
        for phrase_number in range(phrases_per_signer):
            phrase = random_phrase(generator)
            clip = spelling_clip(phrase, generator)
            clip_id = f"spell-{signer_number}-{phrase_number}"
            clips_and_records.append(
                (clip, ClipRecord(clip_id, "synthetic-spelling", "asl", phrase, f"signer{signer_number}", "", 30, 0, 0, clip.shape[0], "mediapipe"))
            )
    return write_dataset(folder, clips_and_records)
