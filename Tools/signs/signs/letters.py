"""Still ISL letters (`SignSpellISL`, SPEC section 4): one frame's 117 features -> a score per letter.

ISL finger-spelling is mostly still two-handed shapes, so one frame is enough and a small MLP reads it. The
training clips are one frame each (`[1, 61, 3]`, made from photos by the Swift extractor) in the usual
`manifest.csv`; a longer clip is read by its first frame with a hand (it is trimmed, then thinned to 1 frame).

The model takes the same inputs as the others, `[1, 1, 117]` features and a `[1, 1]` mask, so the app feeds it the
same way. It returns `(scores, description)` like the word model, so the word model's evaluation and calibration
code works on it unchanged; only `scores` is exported.

Splits (SPEC section 5): by signer when a dataset's manifest names signers. A dataset with no signers at all is
split by clip with a seed instead, and the trainer says so, since then the same person can be in training and in
test and the numbers come out kinder than they would be on a stranger.
"""

from __future__ import annotations

import copy
import dataclasses
from dataclasses import asdict, dataclass

import torch
from torch import nn

from .augment import AugmentSettings
from .data import SampleReference, assign_splits
from .features import FEATURE_COUNT
from .landmarks import PackedDataset
from .model import masked_mean_over_time

LETTERS_TASK_NAME = "letters"
LETTER_MODEL_FRAME_COUNT = 1
SPLIT_BY_SIGNER = "signer"
SPLIT_BY_CLIP = "clip"


@dataclass
class LetterModelSettings:
    feature_count: int = FEATURE_COUNT
    hidden_width: int = 256
    dropout_rate: float = 0.2

    def to_dict(self) -> dict:
        return asdict(self)


class SignLetterModel(nn.Module):
    """[B, N, 117] features + [B, N] mask -> (scores [B, letters], description [B, hidden width]).

    The frames are averaged over the mask first; with N = 1 (the exported shape) that is just the one frame."""

    def __init__(self, settings: LetterModelSettings, letter_count: int):
        super().__init__()
        self.settings = settings
        hidden_width = settings.hidden_width
        self.input_normalize = nn.LayerNorm(settings.feature_count)
        self.first_layer = nn.Sequential(
            nn.Linear(settings.feature_count, hidden_width), nn.LayerNorm(hidden_width), nn.GELU()
        )
        self.second_layer = nn.Sequential(nn.Linear(hidden_width, hidden_width), nn.LayerNorm(hidden_width), nn.GELU())
        self.dropout = nn.Dropout(settings.dropout_rate)
        self.classifier = nn.Linear(hidden_width, letter_count)

    def forward(self, features: torch.Tensor, frame_mask: torch.Tensor) -> tuple[torch.Tensor, torch.Tensor]:
        frame_features = masked_mean_over_time(features, frame_mask)
        first_hidden = self.first_layer(self.input_normalize(frame_features))
        description = first_hidden + self.second_layer(self.dropout(first_hidden))
        scores = self.classifier(self.dropout(description))
        return scores, description


def build_letter_model(letter_model_settings_dict: dict, letter_count: int) -> SignLetterModel:
    return SignLetterModel(LetterModelSettings(**letter_model_settings_dict), letter_count)


def letter_augment_settings() -> AugmentSettings:
    """Mirror, a small turn, a size change and jitter. Everything that works along time (trimming, speed, dropped
    frames, a hand lost for a few frames) is off: there is only one frame, and losing a hand there would turn a
    two-handed letter into a different one."""
    return AugmentSettings(
        mirror_probability=0.5,
        rotation_probability=0.5,
        largest_rotation_degrees=10.0,
        scale_probability=0.5,
        largest_scale_change=0.15,
        x_stretch_probability=0.0,
        shift_probability=0.0,
        jitter_probability=0.7,
        time_scale_probability=0.0,
        trim_probability=0.0,
        hand_drop_probability=0.0,
        frame_drop_probability=0.0,
        joint_drop_probability=0.2,
        joint_drop_rate=0.02,
        fewest_frames_kept=1,
    )


def source_names_signers(source: PackedDataset, language: str | None) -> bool:
    return any(
        clip_record.signer.strip()
        for clip_record in source.clip_records
        if language is None or clip_record.language == language
    )


def assign_letter_splits(
    sources: list[PackedDataset],
    seed: int,
    test_fraction: float = 0.15,
    validation_fraction: float = 0.1,
    saved_split_plans: list[dict] | None = None,
    language: str | None = None,
) -> tuple[list[SampleReference], list[dict]]:
    """Every clip with its split, and one plan per source: {"kind": "signer" | "clip", "splits": {key: split}}.

    A source whose manifest names signers is split by signer exactly as the other trainers do (`assign_splits`).
    A source with no signers is split the same way with each clip id in place of a signer (same seeding and
    fractions). A row whose
    manifest `split` is filled keeps it either way. With `saved_split_plans` (from a checkpoint) nothing is made:
    the saved plan is followed, so evaluation reads exactly the clips training held out."""
    sample_references = []
    split_plans = []
    for source_number, source in enumerate(sources):
        saved_plan = saved_split_plans[source_number] if saved_split_plans is not None else None
        if saved_plan is not None:
            split_kind = saved_plan["kind"]
        else:
            split_kind = SPLIT_BY_SIGNER if source_names_signers(source, language) else SPLIT_BY_CLIP

        if split_kind == SPLIT_BY_SIGNER:
            split_source = source
        else:
            # The same signer split, with each clip standing in as its own "signer": a shallow copy whose manifest
            # rows carry the clip id as the signer, so `assign_splits` does the work (and keeps manifest splits).
            split_source = copy.copy(source)
            split_source.clip_records = [
                dataclasses.replace(clip_record, signer=clip_record.clip_id) for clip_record in source.clip_records
            ]
        source_references, split_keys = assign_splits(
            [split_source],
            seed,
            test_fraction,
            validation_fraction,
            saved_signer_splits=[saved_plan["splits"]] if saved_plan is not None else None,
            language=language,
        )
        for reference in source_references:
            reference.source_number = source_number
            reference.signer = source.clip_records[reference.clip_number].signer
        sample_references.extend(source_references)
        split_plans.append({"kind": split_kind, "splits": split_keys[0]})
    return sample_references, split_plans


def describe_split_plans(sources: list[PackedDataset], split_plans: list[dict]) -> list[str]:
    """One plain line per dataset saying how it was split."""
    lines = []
    for source, split_plan in zip(sources, split_plans):
        if split_plan["kind"] == SPLIT_BY_SIGNER:
            lines.append(f"{source.folder.name}: split by signer ({len(split_plan['splits'])} signers)")
        else:
            lines.append(
                f"{source.folder.name}: split by clip, because the manifest names no signers; the same person can be "
                f"in training and in test, so these numbers are kinder than on a stranger"
            )
    return lines
