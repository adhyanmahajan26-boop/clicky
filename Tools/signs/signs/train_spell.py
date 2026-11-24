"""Finger-spelling (CTC) training with validation each epoch. The test split is never read here; run
`python -m signs.evaluate --checkpoint <run>/checkpoint-best.pt --split test` once, at the end.

    python -m signs.train_spell --data /data/asl-fingerspelling --output runs/spell-asl
"""

from __future__ import annotations

import argparse
import json
from dataclasses import asdict, dataclass, field
from pathlib import Path

import torch
from torch import nn

from .augment import AugmentSettings
from .data import (
    SPELL_MODEL_LONGEST_FRAME_COUNT,
    SpellClipDataset,
    assign_splits,
    build_character_list,
    collate_spelling_batch,
    load_sources,
    references_in_split,
)
from .model import EncoderSettings, SignSpellModel, count_parameters
from .splits import TRAIN_SPLIT, VALIDATION_SPLIT
from .training import (
    DEVICE_CHOICES,
    ExponentialMovingAverage,
    JsonLinesLog,
    Stopwatch,
    decode_characters,
    default_worker_count,
    edit_distance,
    greedy_ctc_decode,
    load_checkpoint,
    make_loader,
    move_to_device,
    pick_device,
    resolve_resume_path,
    save_checkpoint,
    seed_everything,
    spelling_ctc_loss,
    spelling_scores,
    train_one_epoch,
    warmup_then_cosine,
)

TASK_NAME = "spelling"


@dataclass
class SpellTrainingSettings:
    data_folders: list[str]
    output_folder: str
    language: str | None = None
    epochs: int = 60
    batch_size: int = 64
    learning_rate: float = 1e-3
    weight_decay: float = 0.05
    warmup_epochs: float = 2.0
    gradient_clip_norm: float = 1.0
    ema_decay: float = 0.999
    width: int = 256
    drop_path_rate: float = 0.1
    dropout_rate: float = 0.1
    longest_frame_count: int = SPELL_MODEL_LONGEST_FRAME_COUNT
    seed: int = 7
    test_fraction: float = 0.15
    validation_fraction: float = 0.1
    workers: int = field(default_factory=default_worker_count)
    device: str = "auto"
    resume: str | None = None
    no_augment: bool = False


def parse_arguments(argument_list=None) -> SpellTrainingSettings:
    defaults = SpellTrainingSettings(data_folders=[], output_folder="")
    argument_parser = argparse.ArgumentParser(description="Train the finger-spelling (CTC) model.")
    argument_parser.add_argument("--data", nargs="+", required=True, dest="data_folders", help="packed dataset folders")
    argument_parser.add_argument("--output", required=True, dest="output_folder", help="run folder for checkpoints and logs")
    argument_parser.add_argument("--language", default=None, help="only rows of this language (asl or isl)")
    argument_parser.add_argument("--epochs", type=int, default=defaults.epochs)
    argument_parser.add_argument("--batch-size", type=int, default=defaults.batch_size)
    argument_parser.add_argument("--learning-rate", type=float, default=defaults.learning_rate)
    argument_parser.add_argument("--weight-decay", type=float, default=defaults.weight_decay)
    argument_parser.add_argument("--warmup-epochs", type=float, default=defaults.warmup_epochs)
    argument_parser.add_argument("--gradient-clip-norm", type=float, default=defaults.gradient_clip_norm)
    argument_parser.add_argument("--ema-decay", type=float, default=defaults.ema_decay)
    argument_parser.add_argument("--width", type=int, default=defaults.width)
    argument_parser.add_argument("--drop-path-rate", type=float, default=defaults.drop_path_rate)
    argument_parser.add_argument("--dropout-rate", type=float, default=defaults.dropout_rate)
    argument_parser.add_argument("--longest-frame-count", type=int, default=defaults.longest_frame_count)
    argument_parser.add_argument("--seed", type=int, default=defaults.seed)
    argument_parser.add_argument("--test-fraction", type=float, default=defaults.test_fraction)
    argument_parser.add_argument("--validation-fraction", type=float, default=defaults.validation_fraction)
    argument_parser.add_argument("--workers", type=int, default=defaults.workers)
    argument_parser.add_argument("--device", choices=DEVICE_CHOICES, default=defaults.device)
    argument_parser.add_argument("--resume", default=None, help="checkpoint file or run folder to carry on from")
    argument_parser.add_argument("--no-augment", action="store_true")
    return SpellTrainingSettings(**vars(argument_parser.parse_args(argument_list)))


def compute_spelling_batch_loss(model_being_trained, batch_on_device):
    features, frame_mask, joined_targets, target_lengths = batch_on_device
    log_probabilities, output_lengths = model_being_trained(features, frame_mask)
    return spelling_ctc_loss(log_probabilities, output_lengths, joined_targets, target_lengths)


@torch.no_grad()
def evaluate_spell_model(
    model: nn.Module,
    dataset: SpellClipDataset,
    character_list: list[str],
    device: torch.device,
    batch_size: int,
    workers: int,
    example_count: int = 10,
) -> dict:
    """Greedy CTC decoding; character error rate D / N and the Kaggle score (N − D) / N over the whole split,
    N = total target characters, D = total edit distance."""
    model.eval()
    loader = make_loader(dataset, batch_size, workers, shuffle=False, seed=0, collate_function=collate_spelling_batch)
    total_target_characters = 0
    total_edit_distance = 0
    loss_total = 0.0
    batch_count = 0
    sample_count = 0
    examples = []
    for batch in loader:
        features, frame_mask, joined_targets, target_lengths = move_to_device(batch, device)
        log_probabilities, output_lengths = model(features, frame_mask)
        loss_total += float(spelling_ctc_loss(log_probabilities, output_lengths, joined_targets, target_lengths).cpu())
        batch_count += 1
        decoded_sequences = greedy_ctc_decode(log_probabilities, output_lengths)
        target_sequences = torch.split(joined_targets.cpu(), target_lengths.cpu().tolist())
        for decoded_numbers, target_numbers_tensor in zip(decoded_sequences, target_sequences):
            target_numbers = target_numbers_tensor.tolist()
            total_target_characters += len(target_numbers)
            total_edit_distance += edit_distance(decoded_numbers, target_numbers)
            sample_count += 1
            if len(examples) < example_count:
                examples.append(
                    {
                        "target": decode_characters(target_numbers, character_list),
                        "decoded": decode_characters(decoded_numbers, character_list),
                    }
                )
    results = {"samples": sample_count, "loss": loss_total / batch_count if batch_count else None, "examples": examples}
    results.update(spelling_scores(total_target_characters, total_edit_distance))
    return results


def build_spell_model(encoder_settings_dict: dict, character_count: int) -> SignSpellModel:
    return SignSpellModel(EncoderSettings(**encoder_settings_dict), character_count)


def main(argument_list=None) -> None:
    settings = parse_arguments(argument_list)
    seed_everything(settings.seed)
    device = pick_device(settings.device)
    output_folder = Path(settings.output_folder)
    output_folder.mkdir(parents=True, exist_ok=True)

    resumed_checkpoint = load_checkpoint(resolve_resume_path(settings.resume)) if settings.resume else None
    if resumed_checkpoint is not None:
        # Data, signer split, characters and model shape come from the run being continued.
        data_folders = resumed_checkpoint["data_folders"]
        saved_signer_splits = resumed_checkpoint["signer_splits"]
        language = resumed_checkpoint["language"]
        longest_frame_count = resumed_checkpoint["frame_count"]
    else:
        data_folders = [str(Path(data_folder).resolve()) for data_folder in settings.data_folders]
        saved_signer_splits = None
        language = settings.language
        longest_frame_count = settings.longest_frame_count

    sources = load_sources(data_folders)
    sample_references, signer_splits = assign_splits(
        sources,
        settings.seed,
        settings.test_fraction,
        settings.validation_fraction,
        saved_signer_splits=saved_signer_splits,
        language=language,
    )
    training_references = references_in_split(sample_references, TRAIN_SPLIT)
    validation_references = references_in_split(sample_references, VALIDATION_SPLIT)
    if resumed_checkpoint is not None:
        character_list = resumed_checkpoint["labels"]
        encoder_settings_dict = resumed_checkpoint["encoder_settings"]
    else:
        character_list = build_character_list(training_references)
        encoder_settings_dict = EncoderSettings(
            width=settings.width,
            drop_path_rate=settings.drop_path_rate,
            dropout_rate=settings.dropout_rate,
            halve_frames_after_first_stage=True,
        ).to_dict()
    if not character_list:
        raise SystemExit("no training phrases found")

    augment_settings = None if settings.no_augment else AugmentSettings()
    training_dataset = SpellClipDataset(
        sources, training_references, character_list, augment_settings, settings.seed, longest_frame_count
    )
    validation_dataset = SpellClipDataset(
        sources, validation_references, character_list, None, settings.seed, longest_frame_count
    )

    model = build_spell_model(encoder_settings_dict, len(character_list)).to(device)
    print(
        f"device {device}; {len(character_list)} characters; samples: {len(training_dataset)} train "
        f"({training_dataset.dropped_for_length_count} dropped, phrase too long for the frames), "
        f"{len(validation_dataset)} validation; model parameters: {count_parameters(model):,}",
        flush=True,
    )

    optimizer = torch.optim.AdamW(model.parameters(), lr=settings.learning_rate, weight_decay=settings.weight_decay)
    steps_per_epoch = max(1, len(training_dataset) // settings.batch_size)
    scheduler = torch.optim.lr_scheduler.LambdaLR(
        optimizer,
        warmup_then_cosine(settings.epochs * steps_per_epoch, int(settings.warmup_epochs * steps_per_epoch)),
    )
    exponential_moving_average = ExponentialMovingAverage(model, settings.ema_decay)
    first_epoch = 0
    best_validation_score = None
    if resumed_checkpoint is not None:
        model.load_state_dict(resumed_checkpoint["model_state"])
        exponential_moving_average.load_state_dict(resumed_checkpoint["ema_state"])
        optimizer.load_state_dict(resumed_checkpoint["optimizer_state"])
        scheduler.load_state_dict(resumed_checkpoint["scheduler_state"])
        first_epoch = resumed_checkpoint["epoch"] + 1
        best_validation_score = resumed_checkpoint["best_validation_score"]
        print(f"resuming at epoch {first_epoch}", flush=True)

    with open(output_folder / "splits.json", "w", encoding="utf-8") as splits_file:
        json.dump({"data_folders": data_folders, "signer_splits": signer_splits}, splits_file, indent=1, sort_keys=True)
    with open(output_folder / "labels.json", "w", encoding="utf-8") as labels_file:
        json.dump(character_list, labels_file, ensure_ascii=False)

    training_log = JsonLinesLog(output_folder / "log.jsonl")
    for epoch in range(first_epoch, settings.epochs):
        stopwatch = Stopwatch()
        training_dataset.set_epoch(epoch)
        training_loader = make_loader(
            training_dataset,
            settings.batch_size,
            settings.workers,
            shuffle=True,
            seed=settings.seed * 1000 + epoch,
            collate_function=collate_spelling_batch,
            drop_last=len(training_dataset) > settings.batch_size,
        )
        training_loss = train_one_epoch(
            model,
            training_loader,
            compute_spelling_batch_loss,
            optimizer,
            scheduler,
            exponential_moving_average,
            device,
            settings.gradient_clip_norm,
        )
        log_entry = {"epoch": epoch, "train_loss": training_loss, "learning_rate": scheduler.get_last_lr()[0]}
        if len(validation_dataset) > 0:
            validation_results = evaluate_spell_model(
                exponential_moving_average.averaged_model,
                validation_dataset,
                character_list,
                device,
                settings.batch_size,
                settings.workers,
                example_count=3,
            )
            log_entry.update(
                validation_loss=validation_results["loss"],
                validation_character_error_rate=validation_results["character_error_rate"],
                validation_kaggle_score=validation_results["kaggle_score"],
                validation_examples=validation_results["examples"],
            )
            validation_score = validation_results["kaggle_score"]
        else:
            validation_score = -training_loss
        log_entry["seconds"] = stopwatch.seconds()
        training_log.write(log_entry)
        print(json.dumps(log_entry, ensure_ascii=False), flush=True)

        is_best = best_validation_score is None or validation_score > best_validation_score
        if is_best:
            best_validation_score = validation_score
        checkpoint = {
            "task": TASK_NAME,
            "epoch": epoch,
            "labels": character_list,
            "encoder_settings": encoder_settings_dict,
            "frame_count": longest_frame_count,
            "data_folders": data_folders,
            "signer_splits": signer_splits,
            "language": language,
            "seed": settings.seed,
            "settings": asdict(settings),
            "model_state": model.state_dict(),
            "ema_state": exponential_moving_average.state_dict(),
            "optimizer_state": optimizer.state_dict(),
            "scheduler_state": scheduler.state_dict(),
            "best_validation_score": best_validation_score,
            "validation_score": validation_score,
        }
        save_checkpoint(checkpoint, output_folder / "checkpoint-last.pt")
        if is_best:
            save_checkpoint(checkpoint, output_folder / "checkpoint-best.pt")


if __name__ == "__main__":
    main()
