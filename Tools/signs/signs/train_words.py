"""Isolated-sign word classifier: training with validation each epoch. The test split is never read here; run
`python -m signs.evaluate --checkpoint <run>/checkpoint-best.pt --split test` once, at the end.

    python -m signs.train_words --data /data/asl-signs --output runs/words-asl --language asl
"""

from __future__ import annotations

import argparse
import json
from dataclasses import asdict, dataclass, field
from pathlib import Path

import numpy as np
import torch
from torch import nn

from .augment import AugmentSettings
from .data import (
    WORD_MODEL_FRAME_COUNT,
    WordClipDataset,
    assign_splits,
    build_word_list,
    load_sources,
    references_in_split,
)
from .model import EncoderSettings, SignWordModel, count_parameters
from .splits import TRAIN_SPLIT, VALIDATION_SPLIT
from .training import (
    DEVICE_CHOICES,
    ExponentialMovingAverage,
    JsonLinesLog,
    Stopwatch,
    default_worker_count,
    load_checkpoint,
    make_loader,
    move_to_device,
    pick_device,
    resolve_resume_path,
    save_checkpoint,
    seed_everything,
    train_one_epoch,
    warmup_then_cosine,
)

TASK_NAME = "words"


@dataclass
class WordTrainingSettings:
    data_folders: list[str]
    output_folder: str
    language: str | None = None
    min_clips_per_word: int = 5
    epochs: int = 60
    batch_size: int = 128
    learning_rate: float = 1e-3
    weight_decay: float = 0.05
    warmup_epochs: float = 2.0
    label_smoothing: float = 0.1
    gradient_clip_norm: float = 1.0
    ema_decay: float = 0.999
    width: int = 256
    drop_path_rate: float = 0.1
    dropout_rate: float = 0.1
    seed: int = 7
    test_fraction: float = 0.15
    validation_fraction: float = 0.1
    workers: int = field(default_factory=default_worker_count)
    device: str = "auto"
    resume: str | None = None
    no_augment: bool = False


def parse_arguments(argument_list=None) -> WordTrainingSettings:
    defaults = WordTrainingSettings(data_folders=[], output_folder="")
    argument_parser = argparse.ArgumentParser(description="Train the isolated-sign word classifier.")
    argument_parser.add_argument("--data", nargs="+", required=True, dest="data_folders", help="packed dataset folders")
    argument_parser.add_argument("--output", required=True, dest="output_folder", help="run folder for checkpoints and logs")
    argument_parser.add_argument("--language", default=None, help="only rows of this language (asl or isl)")
    argument_parser.add_argument("--min-clips-per-word", type=int, default=defaults.min_clips_per_word)
    argument_parser.add_argument("--epochs", type=int, default=defaults.epochs)
    argument_parser.add_argument("--batch-size", type=int, default=defaults.batch_size)
    argument_parser.add_argument("--learning-rate", type=float, default=defaults.learning_rate)
    argument_parser.add_argument("--weight-decay", type=float, default=defaults.weight_decay)
    argument_parser.add_argument("--warmup-epochs", type=float, default=defaults.warmup_epochs)
    argument_parser.add_argument("--label-smoothing", type=float, default=defaults.label_smoothing)
    argument_parser.add_argument("--gradient-clip-norm", type=float, default=defaults.gradient_clip_norm)
    argument_parser.add_argument("--ema-decay", type=float, default=defaults.ema_decay)
    argument_parser.add_argument("--width", type=int, default=defaults.width)
    argument_parser.add_argument("--drop-path-rate", type=float, default=defaults.drop_path_rate)
    argument_parser.add_argument("--dropout-rate", type=float, default=defaults.dropout_rate)
    argument_parser.add_argument("--seed", type=int, default=defaults.seed)
    argument_parser.add_argument("--test-fraction", type=float, default=defaults.test_fraction)
    argument_parser.add_argument("--validation-fraction", type=float, default=defaults.validation_fraction)
    argument_parser.add_argument("--workers", type=int, default=defaults.workers)
    argument_parser.add_argument("--device", choices=DEVICE_CHOICES, default=defaults.device)
    argument_parser.add_argument("--resume", default=None, help="checkpoint file or run folder to carry on from")
    argument_parser.add_argument("--no-augment", action="store_true")
    return WordTrainingSettings(**vars(argument_parser.parse_args(argument_list)))


@torch.no_grad()
def evaluate_word_model(
    model: nn.Module, dataset: WordClipDataset, word_list: list[str], device: torch.device, batch_size: int, workers: int
) -> dict:
    """Top-1, top-5, mean loss and a per-word table {word: {"clips": n, "top1": accuracy}}."""
    model.eval()
    loader = make_loader(dataset, batch_size, workers, shuffle=False, seed=0)
    loss_function = nn.CrossEntropyLoss(reduction="sum")
    clip_count = 0
    loss_total = 0.0
    top1_correct = 0
    top5_correct = 0
    clips_per_word = np.zeros(len(word_list), dtype=np.int64)
    correct_per_word = np.zeros(len(word_list), dtype=np.int64)
    for batch in loader:
        features, frame_mask, word_numbers = move_to_device(batch, device)
        scores, description = model(features, frame_mask)
        loss_total += float(loss_function(scores, word_numbers).cpu())
        best_five = scores.topk(min(5, scores.shape[1]), dim=1).indices
        top1_hits = (best_five[:, 0] == word_numbers).cpu().numpy()
        top5_hits = (best_five == word_numbers[:, None]).any(dim=1).cpu().numpy()
        top1_correct += int(top1_hits.sum())
        top5_correct += int(top5_hits.sum())
        word_numbers_on_cpu = word_numbers.cpu().numpy()
        np.add.at(clips_per_word, word_numbers_on_cpu, 1)
        np.add.at(correct_per_word, word_numbers_on_cpu, top1_hits.astype(np.int64))
        clip_count += len(word_numbers_on_cpu)
    per_word_table = {
        word: {"clips": int(clips_per_word[word_number]), "top1": float(correct_per_word[word_number] / clips_per_word[word_number])}
        for word_number, word in enumerate(word_list)
        if clips_per_word[word_number] > 0
    }
    return {
        "clips": clip_count,
        "loss": loss_total / clip_count if clip_count else None,
        "top1": top1_correct / clip_count if clip_count else None,
        "top5": top5_correct / clip_count if clip_count else None,
        "per_word": per_word_table,
    }


def build_word_model(encoder_settings_dict: dict, word_count: int) -> SignWordModel:
    return SignWordModel(EncoderSettings(**encoder_settings_dict), word_count)


def main(argument_list=None) -> None:
    settings = parse_arguments(argument_list)
    seed_everything(settings.seed)
    device = pick_device(settings.device)
    output_folder = Path(settings.output_folder)
    output_folder.mkdir(parents=True, exist_ok=True)

    resumed_checkpoint = load_checkpoint(resolve_resume_path(settings.resume)) if settings.resume else None
    if resumed_checkpoint is not None:
        # The data, signer split, word list and model shape all come from the run being continued, so a resumed
        # run can't quietly train on different classes or leak test signers.
        data_folders = resumed_checkpoint["data_folders"]
        saved_signer_splits = resumed_checkpoint["signer_splits"]
        language = resumed_checkpoint["language"]
    else:
        data_folders = [str(Path(data_folder).resolve()) for data_folder in settings.data_folders]
        saved_signer_splits = None
        language = settings.language

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
        word_list = resumed_checkpoint["labels"]
        encoder_settings_dict = resumed_checkpoint["encoder_settings"]
    else:
        word_list = build_word_list(training_references, settings.min_clips_per_word)
        encoder_settings_dict = EncoderSettings(
            width=settings.width, drop_path_rate=settings.drop_path_rate, dropout_rate=settings.dropout_rate
        ).to_dict()
    if not word_list:
        raise SystemExit("no word has enough training clips; lower --min-clips-per-word")

    augment_settings = None if settings.no_augment else AugmentSettings()
    training_dataset = WordClipDataset(sources, training_references, word_list, augment_settings, settings.seed)
    validation_dataset = WordClipDataset(sources, validation_references, word_list, None, settings.seed)

    model = build_word_model(encoder_settings_dict, len(word_list)).to(device)
    print(
        f"device {device}; {len(word_list)} words; clips: {len(training_dataset)} train, {len(validation_dataset)} "
        f"validation; model parameters: {count_parameters(model):,}",
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
        json.dump(word_list, labels_file, ensure_ascii=False)

    loss_function = nn.CrossEntropyLoss(label_smoothing=settings.label_smoothing)

    def compute_batch_loss(model_being_trained, batch_on_device):
        features, frame_mask, word_numbers = batch_on_device
        scores, description = model_being_trained(features, frame_mask)
        return loss_function(scores, word_numbers)

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
            drop_last=len(training_dataset) > settings.batch_size,
        )
        training_loss = train_one_epoch(
            model,
            training_loader,
            compute_batch_loss,
            optimizer,
            scheduler,
            exponential_moving_average,
            device,
            settings.gradient_clip_norm,
        )
        log_entry = {"epoch": epoch, "train_loss": training_loss, "learning_rate": scheduler.get_last_lr()[0]}
        if len(validation_dataset) > 0:
            validation_results = evaluate_word_model(
                exponential_moving_average.averaged_model, validation_dataset, word_list, device, settings.batch_size, settings.workers
            )
            log_entry.update(
                validation_loss=validation_results["loss"],
                validation_top1=validation_results["top1"],
                validation_top5=validation_results["top5"],
            )
            validation_score = validation_results["top1"]
        else:
            # With no validation signers, the best checkpoint is simply the one with the lowest training loss.
            validation_score = -training_loss
        log_entry["seconds"] = stopwatch.seconds()
        training_log.write(log_entry)
        print(json.dumps(log_entry), flush=True)

        is_best = best_validation_score is None or validation_score > best_validation_score
        if is_best:
            best_validation_score = validation_score
        checkpoint = {
            "task": TASK_NAME,
            "epoch": epoch,
            "labels": word_list,
            "encoder_settings": encoder_settings_dict,
            "frame_count": WORD_MODEL_FRAME_COUNT,
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
