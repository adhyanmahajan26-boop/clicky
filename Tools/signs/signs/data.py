"""Which clips go where (datasets, splits, labels) and the torch Datasets that turn clips into model inputs.

Each sample is made in the DataLoader worker: read the clip from the packed frames, trim frames with no hand at
the ends, augment (training only), compute the 117 features, then fit to the model's frame count.
"""

from __future__ import annotations

import math
from collections import Counter
from dataclasses import dataclass

import numpy as np
import torch
from torch.utils.data import Dataset

from .augment import AugmentSettings, augment_clip
from .features import compute_features, fit_to_frame_count, thin_evenly_frame_indices, trim_frames_without_hands
from .landmarks import PackedDataset, load_packed
from .splits import SPLIT_NAMES, TEST_SPLIT, TRAIN_SPLIT, VALIDATION_SPLIT, split_signers

WORD_MODEL_FRAME_COUNT = 96
SPELL_MODEL_LONGEST_FRAME_COUNT = 256

_SPLIT_SPELLINGS = {
    "train": TRAIN_SPLIT,
    "training": TRAIN_SPLIT,
    "val": VALIDATION_SPLIT,
    "valid": VALIDATION_SPLIT,
    "validation": VALIDATION_SPLIT,
    "dev": VALIDATION_SPLIT,
    "test": TEST_SPLIT,
}


@dataclass
class SampleReference:
    """One clip: which packed dataset, which row, and its label, signer and split."""

    source_number: int
    clip_number: int
    label: str
    signer: str
    split: str


def load_sources(data_folders: list[str]) -> list[PackedDataset]:
    return [load_packed(data_folder) for data_folder in data_folders]


def assign_splits(
    sources: list[PackedDataset],
    seed: int,
    test_fraction: float = 0.15,
    validation_fraction: float = 0.1,
    saved_signer_splits: list[dict[str, str]] | None = None,
    language: str | None = None,
) -> tuple[list[SampleReference], list[dict[str, str]]]:
    """Every clip of every source with its split.

    A row whose manifest `split` is filled keeps it (the dataset's own signer split). The other rows of a source
    are split by signer with `split_signers` (signers of different sources never mix: "1" in one dataset is a
    different person from "1" in another). With `saved_signer_splits` (from a checkpoint) the saved signer
    assignment is used instead of making one, so evaluation reads exactly the signers training held out; a
    signer missing from it is left out. Returns (references, signer split per source).
    """
    sample_references = []
    signer_splits_per_source = []
    for source_number, source in enumerate(sources):
        rows_needing_a_split = []
        for clip_number, clip_record in enumerate(source.clip_records):
            if language and clip_record.language != language:
                continue
            manifest_split = _SPLIT_SPELLINGS.get(clip_record.split.strip().lower(), "")
            if manifest_split:
                sample_references.append(
                    SampleReference(source_number, clip_number, clip_record.label, clip_record.signer, manifest_split)
                )
            else:
                rows_needing_a_split.append(clip_number)

        if saved_signer_splits is not None:
            split_by_signer = dict(saved_signer_splits[source_number])
        else:
            split_by_signer = split_signers(
                [source.clip_records[clip_number].signer for clip_number in rows_needing_a_split],
                seed,
                test_fraction=test_fraction,
                validation_fraction=validation_fraction,
            )
        signer_splits_per_source.append(split_by_signer)
        for clip_number in rows_needing_a_split:
            clip_record = source.clip_records[clip_number]
            signer_split = split_by_signer.get(str(clip_record.signer))
            if signer_split in SPLIT_NAMES:
                sample_references.append(
                    SampleReference(source_number, clip_number, clip_record.label, clip_record.signer, signer_split)
                )
    return sample_references, signer_splits_per_source


def references_in_split(sample_references: list[SampleReference], split: str) -> list[SampleReference]:
    return [reference for reference in sample_references if reference.split == split]


def build_word_list(training_references: list[SampleReference], min_clips_per_word: int) -> list[str]:
    """Words with at least `min_clips_per_word` training clips, sorted. The same label from several datasets is
    one word."""
    clips_per_word = Counter(reference.label for reference in training_references)
    return sorted(word for word, clip_count in clips_per_word.items() if clip_count >= min_clips_per_word)


def build_character_list(training_references: list[SampleReference]) -> list[str]:
    """Every character in the training phrases, sorted. Model output 0 is the CTC blank, so character i of this
    list is output i + 1."""
    return sorted({character for reference in training_references for character in reference.label})


def ctc_frames_needed(target_numbers: list[int]) -> int:
    """CTC needs one output per character plus a blank between each pair of equal neighbours."""
    repeated_neighbours = sum(
        1 for position in range(1, len(target_numbers)) if target_numbers[position] == target_numbers[position - 1]
    )
    return len(target_numbers) + repeated_neighbours


class _ClipDatasetBase(Dataset):
    def __init__(
        self,
        sources: list[PackedDataset],
        sample_references: list[SampleReference],
        augment_settings: AugmentSettings | None,
        seed: int,
    ):
        self.sources = sources
        self.sample_references = sample_references
        self.augment_settings = augment_settings
        self.seed = seed
        self.epoch = 0

    def set_epoch(self, epoch: int) -> None:
        """Augmentation for sample i in epoch e always comes from the seed (seed, e, i), whichever worker makes it.
        Loaders are made without persistent workers, so each epoch's workers get the new epoch."""
        self.epoch = epoch

    def __len__(self) -> int:
        return len(self.sample_references)

    def make_features(self, sample_number: int) -> np.ndarray:
        reference = self.sample_references[sample_number]
        source = self.sources[reference.source_number]
        clip_record = source.clip_records[reference.clip_number]
        landmarks = trim_frames_without_hands(source.clip(reference.clip_number))
        if self.augment_settings is not None:
            generator = np.random.default_rng([self.seed, self.epoch, sample_number])
            picture_aspect = clip_record.width / clip_record.height if clip_record.width > 0 and clip_record.height > 0 else 1.0
            landmarks = augment_clip(landmarks, generator, self.augment_settings, picture_aspect)
        return compute_features(landmarks, clip_record.width, clip_record.height)


class WordClipDataset(_ClipDatasetBase):
    """Returns (features [96, 117], mask [96], word number)."""

    def __init__(
        self,
        sources: list[PackedDataset],
        sample_references: list[SampleReference],
        word_list: list[str],
        augment_settings: AugmentSettings | None = None,
        seed: int = 0,
        frame_count: int = WORD_MODEL_FRAME_COUNT,
    ):
        word_number_by_word = {word: word_number for word_number, word in enumerate(word_list)}
        known_word_references = [reference for reference in sample_references if reference.label in word_number_by_word]
        super().__init__(sources, known_word_references, augment_settings, seed)
        self.word_number_by_word = word_number_by_word
        self.frame_count = frame_count

    def __getitem__(self, sample_number: int):
        fitted_features, frame_mask = fit_to_frame_count(self.make_features(sample_number), self.frame_count)
        word_number = self.word_number_by_word[self.sample_references[sample_number].label]
        return torch.from_numpy(fitted_features), torch.from_numpy(frame_mask), torch.tensor(word_number)


class SpellClipDataset(_ClipDatasetBase):
    """Returns (features [T ≤ 256, 117], mask [T], character numbers [L]); characters not in the list are left
    out of the target."""

    def __init__(
        self,
        sources: list[PackedDataset],
        sample_references: list[SampleReference],
        character_list: list[str],
        augment_settings: AugmentSettings | None = None,
        seed: int = 0,
        longest_frame_count: int = SPELL_MODEL_LONGEST_FRAME_COUNT,
        drop_targets_too_long_for_the_frames: bool = True,
    ):
        self.output_number_by_character = {character: position + 1 for position, character in enumerate(character_list)}
        self.longest_frame_count = longest_frame_count
        kept_references = []
        self.dropped_for_length_count = 0
        for reference in sample_references:
            target_numbers = self.target_numbers(reference.label)
            if not target_numbers:
                continue
            # Judged on the manifest's frame count before trimming and augmenting; the few samples those make too
            # short give an infinite CTC loss, which the trainer's zero_infinity=True ignores.
            manifest_frames = sources[reference.source_number].clip_records[reference.clip_number].frames
            output_frame_count = math.ceil(min(manifest_frames, longest_frame_count) / 2)
            if drop_targets_too_long_for_the_frames and ctc_frames_needed(target_numbers) > output_frame_count:
                self.dropped_for_length_count += 1
                continue
            kept_references.append(reference)
        super().__init__(sources, kept_references, augment_settings, seed)

    def target_numbers(self, phrase: str) -> list[int]:
        return [self.output_number_by_character[character] for character in phrase if character in self.output_number_by_character]

    def __getitem__(self, sample_number: int):
        features = self.make_features(sample_number)
        features = features[thin_evenly_frame_indices(features.shape[0], self.longest_frame_count)]
        target_numbers = self.target_numbers(self.sample_references[sample_number].label)
        return (
            torch.from_numpy(np.ascontiguousarray(features)),
            torch.ones(features.shape[0]),
            torch.tensor(target_numbers, dtype=torch.int64),
        )


def collate_spelling_batch(samples):
    """Pads features and masks to the longest clip in the batch; targets are joined end to end (CTC's form).

    Returns (features [B, T, 117], mask [B, T], targets [sum L], target lengths [B])."""
    longest_frame_count = max(max(features.shape[0] for features, frame_mask, targets in samples), 1)
    batch_size = len(samples)
    feature_count = samples[0][0].shape[1]
    batch_features = torch.zeros(batch_size, longest_frame_count, feature_count)
    batch_mask = torch.zeros(batch_size, longest_frame_count)
    for sample_number, (features, frame_mask, targets) in enumerate(samples):
        batch_features[sample_number, : features.shape[0]] = features
        batch_mask[sample_number, : features.shape[0]] = frame_mask
    joined_targets = torch.cat([targets for features, frame_mask, targets in samples])
    target_lengths = torch.tensor([targets.shape[0] for features, frame_mask, targets in samples], dtype=torch.int64)
    return batch_features, batch_mask, joined_targets, target_lengths
