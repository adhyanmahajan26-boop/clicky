"""The sentence and still-letter models, plugged into `evaluate.py` and `export_coreml.py`.

Those two files know the word and finger-spelling checkpoints; for any other `task` they ask here, so
`python -m signs.evaluate` and `python -m signs.export_coreml` work the same way for all four models.
"""

from __future__ import annotations

import torch
from torch import nn

from .letters import LETTERS_TASK_NAME
from .sentences import SENTENCES_TASK_NAME

EXTRA_TASK_NAMES = (SENTENCES_TASK_NAME, LETTERS_TASK_NAME)


def build_extra_task_model(checkpoint: dict) -> nn.Module:
    """The model a sentence or letter checkpoint describes, with its EMA weights, in eval mode on the CPU."""
    if checkpoint["task"] == SENTENCES_TASK_NAME:
        from .train_sentences import build_sentence_model

        model = build_sentence_model(checkpoint["encoder_settings"], len(checkpoint["labels"]))
    elif checkpoint["task"] == LETTERS_TASK_NAME:
        from .letters import build_letter_model

        model = build_letter_model(checkpoint["letter_model_settings"], len(checkpoint["labels"]))
    else:
        raise ValueError(f"unknown checkpoint task {checkpoint['task']!r}")
    model.load_state_dict(checkpoint["ema_state"]["model"])
    return model.eval()


class _SentenceExportWrapper(nn.Module):
    """Only the log-probabilities [1, 192, words + 1] (blank 0, word i at i + 1), as for finger-spelling."""

    def __init__(self, sentence_model: nn.Module):
        super().__init__()
        self.sentence_model = sentence_model

    def forward(self, features: torch.Tensor, mask: torch.Tensor):
        log_probabilities, output_lengths = self.sentence_model(features, mask)
        return log_probabilities


class _LetterExportWrapper(nn.Module):
    """Only the scores [1, letters], divided by the calibration temperature so the app's plain softmax gives
    calibrated probabilities (1.0 when the model wasn't calibrated)."""

    def __init__(self, letter_model: nn.Module, temperature: float):
        super().__init__()
        self.letter_model = letter_model
        self.temperature = float(temperature)

    def forward(self, features: torch.Tensor, mask: torch.Tensor):
        scores, description = self.letter_model(features, mask)
        return scores / self.temperature


def extra_task_export_module(checkpoint: dict, model: nn.Module, temperature: float = 1.0) -> tuple[nn.Module, list[str]]:
    """(module to trace, output names) for a sentence or letter checkpoint."""
    if checkpoint["task"] == SENTENCES_TASK_NAME:
        return _SentenceExportWrapper(model).eval(), ["scores"]
    if checkpoint["task"] == LETTERS_TASK_NAME:
        return _LetterExportWrapper(model, temperature).eval(), ["scores"]
    raise ValueError(f"unknown checkpoint task {checkpoint['task']!r}")


def split_references_for_checkpoint(checkpoint: dict, sources) -> list:
    """Every clip of the checkpoint's data with the split training used (letters may be split by clip)."""
    if checkpoint["task"] == LETTERS_TASK_NAME:
        from .letters import assign_letter_splits

        sample_references, split_plans = assign_letter_splits(
            sources, checkpoint["seed"], saved_split_plans=checkpoint["signer_splits"], language=checkpoint["language"]
        )
        return sample_references
    from .data import assign_splits

    sample_references, signer_splits = assign_splits(
        sources, checkpoint["seed"], saved_signer_splits=checkpoint["signer_splits"], language=checkpoint["language"]
    )
    return sample_references


def evaluate_extra_task_checkpoint(
    checkpoint: dict,
    split: str,
    data_folders: list[str],
    device: torch.device,
    batch_size: int,
    workers: int,
    landmark_source: str | None,
) -> dict:
    """The metrics `evaluate.py` prints, for a sentence or letter checkpoint."""
    from .data import load_sources, references_in_split

    sources = load_sources(data_folders)
    split_references = references_in_split(split_references_for_checkpoint(checkpoint, sources), split)
    if landmark_source:
        split_references = [
            reference
            for reference in split_references
            if sources[reference.source_number].clip_records[reference.clip_number].source == landmark_source
        ]
    if checkpoint["task"] == SENTENCES_TASK_NAME:
        from .train_sentences import evaluate_sentence_checkpoint

        return evaluate_sentence_checkpoint(checkpoint, sources, split_references, split, device, batch_size, workers)

    from .letters import describe_split_plans
    from .train_letters import letter_dataset
    from .train_words import evaluate_word_model

    dataset = letter_dataset(sources, split_references, checkpoint["labels"], None, checkpoint["seed"])
    model = build_extra_task_model(checkpoint).to(device)
    results = evaluate_word_model(model, dataset, checkpoint["labels"], device, batch_size, workers)
    results["clips_with_a_letter_not_in_the_model"] = len(split_references) - len(dataset)
    results["split_by"] = describe_split_plans(sources, checkpoint["signer_splits"])
    return results
