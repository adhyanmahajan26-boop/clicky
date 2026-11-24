"""The sign models: a shared encoder, a word classifier and a finger-spelling (CTC) model.

Everything in `forward` is written to trace into a fixed graph for Core ML (`torch.jit.trace` on fixed shapes):
no Python branches that depend on the data, no in-place masked writes, and the padding mask applied by
multiplication. Padded frames never change the result for real frames: convolutions see zeros there (the same
as their own zero padding), attention gives padded keys a large negative bias, and pooling is a masked mean.
"""

from __future__ import annotations

from dataclasses import asdict, dataclass

import torch
from torch import nn
from torch.nn import functional

from .features import (
    COORDINATE_FEATURE_COUNT,
    FEATURE_COUNT,
    LEFT_HAND_FEATURES_START,
    LEFT_HAND_SEEN_FEATURE,
    LEFT_WRIST_FEATURES_START,
    RIGHT_HAND_FEATURES_START,
    RIGHT_HAND_SEEN_FEATURE,
    RIGHT_WRIST_FEATURES_START,
)

# Added to attention scores of padded keys. Large enough that softmax gives them exactly 0 in float32 and
# float16, but finite (unlike -inf) so Core ML conversion and float16 stay well behaved.
PADDED_KEY_ATTENTION_BIAS = -1.0e4


@dataclass
class EncoderSettings:
    feature_count: int = FEATURE_COUNT
    width: int = 256
    stage_count: int = 2
    conv_blocks_per_stage: int = 3
    kernel_size: int = 17
    conv_expansion: int = 2
    head_count: int = 4
    mlp_expansion: int = 2
    drop_path_rate: float = 0.1
    dropout_rate: float = 0.1
    # Finger-spelling only: one stride-2 convolution after stage 1, so there is one output per 2 frames.
    halve_frames_after_first_stage: bool = False

    def to_dict(self) -> dict:
        return asdict(self)


def masked_mean_over_time(sequence: torch.Tensor, frame_mask: torch.Tensor) -> torch.Tensor:
    """sequence [B, T, C], frame_mask [B, T] -> [B, C], the mean over real frames only."""
    mask_column = frame_mask.unsqueeze(-1)
    real_frame_count = torch.clamp(mask_column.sum(dim=1), min=1.0)
    return (sequence * mask_column).sum(dim=1) / real_frame_count


class DropPath(nn.Module):
    """Stochastic depth: in training, skips a residual branch for a random part of the batch."""

    def __init__(self, drop_probability: float):
        super().__init__()
        self.drop_probability = drop_probability

    def forward(self, branch_output: torch.Tensor) -> torch.Tensor:
        if not self.training or self.drop_probability == 0.0:
            return branch_output
        keep_probability = 1.0 - self.drop_probability
        keep_per_sample = torch.bernoulli(
            torch.full((branch_output.shape[0], 1, 1), keep_probability, device=branch_output.device)
        )
        return branch_output * keep_per_sample / keep_probability


class EfficientChannelAttention(nn.Module):
    """ECA: a gate per channel from a small 1-D convolution across the channels' time averages."""

    def __init__(self, kernel_size: int = 5):
        super().__init__()
        self.channel_convolution = nn.Conv1d(1, 1, kernel_size, padding=kernel_size // 2, bias=False)

    def forward(self, sequence: torch.Tensor, frame_mask: torch.Tensor) -> torch.Tensor:
        channel_averages = masked_mean_over_time(sequence, frame_mask)  # [B, C]
        channel_gates = torch.sigmoid(self.channel_convolution(channel_averages.unsqueeze(1))).squeeze(1)
        return sequence * channel_gates.unsqueeze(1)


class DepthwiseConvBlock(nn.Module):
    """Expand, depthwise convolution over time, LayerNorm, channel attention, project back; residual."""

    def __init__(self, width: int, kernel_size: int, expansion: int, drop_path_rate: float, dropout_rate: float):
        super().__init__()
        expanded_width = width * expansion
        self.expand = nn.Linear(width, expanded_width)
        self.activation = nn.SiLU()
        self.depthwise_convolution = nn.Conv1d(
            expanded_width, expanded_width, kernel_size, padding=kernel_size // 2, groups=expanded_width
        )
        # LayerNorm works on each frame by itself, so padded frames can't change real frames (BatchNorm could).
        self.normalize = nn.LayerNorm(expanded_width)
        self.channel_attention = EfficientChannelAttention()
        self.project = nn.Linear(expanded_width, width)
        self.dropout = nn.Dropout(dropout_rate)
        self.drop_path = DropPath(drop_path_rate)

    def forward(self, sequence: torch.Tensor, frame_mask: torch.Tensor) -> torch.Tensor:
        mask_column = frame_mask.unsqueeze(-1)
        expanded = self.activation(self.expand(sequence)) * mask_column
        convolved = self.depthwise_convolution(expanded.transpose(1, 2)).transpose(1, 2)
        convolved = self.normalize(convolved) * mask_column
        attended = self.channel_attention(convolved, frame_mask)
        branch_output = self.dropout(self.project(attended))
        return (sequence + self.drop_path(branch_output)) * mask_column


class TransformerBlock(nn.Module):
    """Pre-norm self-attention and MLP. Attention is written out by hand (not nn.MultiheadAttention) so the
    padding bias is a plain addition that traces and converts cleanly."""

    def __init__(self, width: int, head_count: int, mlp_expansion: int, drop_path_rate: float, dropout_rate: float):
        super().__init__()
        self.head_count = head_count
        self.head_width = width // head_count
        self.attention_normalize = nn.LayerNorm(width)
        self.query_key_value = nn.Linear(width, 3 * width)
        self.attention_output = nn.Linear(width, width)
        self.mlp_normalize = nn.LayerNorm(width)
        self.mlp = nn.Sequential(
            nn.Linear(width, width * mlp_expansion),
            nn.GELU(),
            nn.Dropout(dropout_rate),
            nn.Linear(width * mlp_expansion, width),
        )
        self.dropout = nn.Dropout(dropout_rate)
        self.drop_path = DropPath(drop_path_rate)

    def forward(self, sequence: torch.Tensor, frame_mask: torch.Tensor) -> torch.Tensor:
        batch_size, frame_count, width = sequence.shape
        mask_column = frame_mask.unsqueeze(-1)

        normalized = self.attention_normalize(sequence)
        queries, keys, values = self.query_key_value(normalized).chunk(3, dim=-1)
        # [B, T, C] -> [B, heads, T, head width]
        queries = queries.reshape(batch_size, frame_count, self.head_count, self.head_width).transpose(1, 2)
        keys = keys.reshape(batch_size, frame_count, self.head_count, self.head_width).transpose(1, 2)
        values = values.reshape(batch_size, frame_count, self.head_count, self.head_width).transpose(1, 2)
        attention_scores = torch.matmul(queries, keys.transpose(-1, -2)) * (self.head_width**-0.5)
        padded_key_bias = (1.0 - frame_mask)[:, None, None, :] * PADDED_KEY_ATTENTION_BIAS  # [B, 1, 1, T]
        attention_weights = torch.softmax(attention_scores + padded_key_bias, dim=-1)
        attended = torch.matmul(self.dropout(attention_weights), values)
        attended = attended.transpose(1, 2).reshape(batch_size, frame_count, width)
        sequence = (sequence + self.drop_path(self.dropout(self.attention_output(attended)))) * mask_column

        mlp_output = self.mlp(self.mlp_normalize(sequence))
        return (sequence + self.drop_path(self.dropout(mlp_output))) * mask_column


def _motion_feature_groups() -> torch.Tensor:
    """[3, 114] one-hot: which coordinate columns belong to the right hand (row 0), left hand (row 1) or body
    (row 2). A hand's columns are its 42 joint numbers and its 2 wrist-from-centre numbers."""
    groups = torch.zeros(3, COORDINATE_FEATURE_COUNT)
    groups[2, :] = 1.0
    for hand_row, hand_start, wrist_start in (
        (0, RIGHT_HAND_FEATURES_START, RIGHT_WRIST_FEATURES_START),
        (1, LEFT_HAND_FEATURES_START, LEFT_WRIST_FEATURES_START),
    ):
        for column in list(range(hand_start, hand_start + 42)) + [wrist_start, wrist_start + 1]:
            groups[:, column] = 0.0
            groups[hand_row, column] = 1.0
    return groups


class SignEncoder(nn.Module):
    """[B, T, 117] features + [B, T] mask -> [B, T', width] (T' = T, or ceil(T / 2) for finger-spelling)."""

    def __init__(self, settings: EncoderSettings):
        super().__init__()
        self.settings = settings
        width = settings.width
        motion_input_count = settings.feature_count + 2 * COORDINATE_FEATURE_COUNT  # 117 + 114 + 114 = 345
        self.register_buffer("motion_feature_groups", _motion_feature_groups(), persistent=False)
        self.stem = nn.Linear(motion_input_count, width)
        self.stem_normalize = nn.LayerNorm(width)

        total_block_count = settings.stage_count * (settings.conv_blocks_per_stage + 1)
        drop_path_rates = [
            settings.drop_path_rate * block_number / max(total_block_count - 1, 1)
            for block_number in range(total_block_count)
        ]
        self.stages = nn.ModuleList()
        block_number = 0
        for stage_number in range(settings.stage_count):
            stage_blocks = nn.ModuleList()
            for conv_block_number in range(settings.conv_blocks_per_stage):
                stage_blocks.append(
                    DepthwiseConvBlock(
                        width,
                        settings.kernel_size,
                        settings.conv_expansion,
                        drop_path_rates[block_number],
                        settings.dropout_rate,
                    )
                )
                block_number += 1
            stage_blocks.append(
                TransformerBlock(
                    width, settings.head_count, settings.mlp_expansion, drop_path_rates[block_number], settings.dropout_rate
                )
            )
            block_number += 1
            self.stages.append(stage_blocks)

        if settings.halve_frames_after_first_stage:
            # Kernel 3, stride 2, padding 1: output frame i reads input frames 2i − 1, 2i, 2i + 1.
            self.halve_frames = nn.Conv1d(width, width, kernel_size=3, stride=2, padding=1)
            self.halve_frames_normalize = nn.LayerNorm(width)
        self.final_normalize = nn.LayerNorm(width)

    def motion_inputs(self, features: torch.Tensor, frame_mask: torch.Tensor) -> torch.Tensor:
        """The 117 features plus the change of the 114 coordinates since 1 and since 2 frames ago -> 345.

        A change is 0 at the first frames, at padded frames, and for a hand's numbers when that hand isn't seen
        in either of the two frames (its numbers jump to or from zero there, which isn't motion)."""
        coordinates = features[:, :, :COORDINATE_FEATURE_COUNT]
        always_one = torch.ones_like(frame_mask)
        group_is_seen = torch.stack(
            [features[:, :, RIGHT_HAND_SEEN_FEATURE], features[:, :, LEFT_HAND_SEEN_FEATURE], always_one], dim=-1
        )  # [B, T, 3]
        column_is_valid = torch.matmul(group_is_seen, self.motion_feature_groups) * frame_mask.unsqueeze(-1)

        motion_parts = [features]
        for lag in (1, 2):
            earlier_coordinates = functional.pad(coordinates, (0, 0, lag, 0))[:, :-lag, :]
            earlier_column_is_valid = functional.pad(column_is_valid, (0, 0, lag, 0))[:, :-lag, :]
            change = (coordinates - earlier_coordinates) * column_is_valid * earlier_column_is_valid
            motion_parts.append(change)
        return torch.cat(motion_parts, dim=-1)

    def forward(self, features: torch.Tensor, frame_mask: torch.Tensor) -> tuple[torch.Tensor, torch.Tensor]:
        """Returns (encoded [B, T', width], mask [B, T'])."""
        mask_column = frame_mask.unsqueeze(-1)
        sequence = self.stem_normalize(self.stem(self.motion_inputs(features, frame_mask))) * mask_column
        for stage_number, stage_blocks in enumerate(self.stages):
            for block in stage_blocks:
                sequence = block(sequence, frame_mask)
            if stage_number == 0 and self.settings.halve_frames_after_first_stage:
                sequence = self.halve_frames(sequence.transpose(1, 2)).transpose(1, 2)
                # Padding is only ever at the end, so output frame i is real exactly when input frame 2i is.
                frame_mask = frame_mask[:, ::2]
                sequence = self.halve_frames_normalize(sequence) * frame_mask.unsqueeze(-1)
        sequence = self.final_normalize(sequence) * frame_mask.unsqueeze(-1)
        return sequence, frame_mask


class SignWordModel(nn.Module):
    """One isolated sign -> a score per word, plus the pooled description vector."""

    def __init__(self, encoder_settings: EncoderSettings, word_count: int, head_dropout_rate: float = 0.2):
        super().__init__()
        self.encoder = SignEncoder(encoder_settings)
        self.head_dropout = nn.Dropout(head_dropout_rate)
        self.classifier = nn.Linear(encoder_settings.width, word_count)

    def forward(self, features: torch.Tensor, frame_mask: torch.Tensor) -> tuple[torch.Tensor, torch.Tensor]:
        encoded, encoded_mask = self.encoder(features, frame_mask)
        description = masked_mean_over_time(encoded, encoded_mask)
        scores = self.classifier(self.head_dropout(description))
        return scores, description


class SignSpellModel(nn.Module):
    """Finger-spelling -> log-probabilities per 2 frames over (blank, characters...), blank at index 0."""

    def __init__(self, encoder_settings: EncoderSettings, character_count: int):
        super().__init__()
        if not encoder_settings.halve_frames_after_first_stage:
            raise ValueError("the spelling model needs halve_frames_after_first_stage=True")
        self.encoder = SignEncoder(encoder_settings)
        self.classifier = nn.Linear(encoder_settings.width, character_count + 1)

    def forward(self, features: torch.Tensor, frame_mask: torch.Tensor) -> tuple[torch.Tensor, torch.Tensor]:
        """Returns (log-probabilities [B, ceil(T / 2), characters + 1], output lengths [B] int64)."""
        encoded, encoded_mask = self.encoder(features, frame_mask)
        log_probabilities = torch.log_softmax(self.classifier(encoded), dim=-1)
        output_lengths = encoded_mask.sum(dim=1).round().to(torch.int64)
        return log_probabilities, output_lengths


def count_parameters(model: nn.Module) -> int:
    return sum(parameter.numel() for parameter in model.parameters())
