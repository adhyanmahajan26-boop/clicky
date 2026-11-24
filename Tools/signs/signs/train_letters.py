"""Still ISL letters (`SignSpellISL`): training with validation each epoch.

Each clip is one frame (`[1, 61, 3]`, from a photo); see `signs/letters.py` for the model and the split. The test
split is never read here; run `python -m signs.evaluate --checkpoint <run>/checkpoint-best.pt --split test` once, at
the end, and `python -m signs.calibrate` before exporting so the app can say "unclear" instead of a wrong letter.

    python -m signs.train_letters --data /data/signs/isl-letters --language isl --output runs/letters-isl
"""

from __future__ import annotations

import argparse
import json
from dataclasses import asdict, dataclass, field
from pathlib import Path

import torch
from torch import nn

from .data import WordClipDataset, build_word_list, load_sources, references_in_split
from .letters import (
    LETTER_MODEL_FRAME_COUNT,
    LETTERS_TASK_NAME,
    LetterModelSettings,
    assign_letter_splits,
    build_letter_model,
    describe_split_plans,
    letter_augment_settings,
)
from .model import count_parameters
from .splits import TRAIN_SPLIT, VALIDATION_SPLIT
from .train_words import evaluate_word_model
from .training import (
    DEVICE_CHOICES,
    ExponentialMovingAverage,
    JsonLinesLog,
    Stopwatch,
    default_worker_count,
    load_checkpoint,
    make_loader,
    pick_device,
    resolve_resume_path,
    save_checkpoint,
    seed_everything,
    train_one_epoch,
    warmup_then_cosine,
)

TASK_NAME = LETTERS_TASK_NAME


@dataclass
class LetterTrainingSettings:
    data_folders: list[str]
    output_folder: str
    language: str | None = None
    min_clips_per_letter: int = 3
    epochs: int = 80
    batch_size: int = 256
    learning_rate: float = 1e-3
    weight_decay: float = 0.01
    warmup_epochs: float = 2.0
    label_smoothing: float = 0.1
    gradient_clip_norm: float = 1.0
    ema_decay: float = 0.995
    hidden_width: int = 256
    dropout_rate: float = 0.2
    seed: int = 7
    test_fraction: float = 0.15
    validation_fraction: float = 0.1
    workers: int = field(default_factory=default_worker_count)
    device: str = "auto"
    resume: str | None = None
    no_augment: bool = False


def parse_arguments(argument_list=None) -> LetterTrainingSettings:
    defaults = LetterTrainingSettings(data_folders=[], output_folder="")
    argument_parser = argparse.ArgumentParser(
        description=(
            "Train the still-letter model (SignSpellISL): one frame's 117 features in, a score per letter out. "
            "Clips are one frame each in the usual manifest. Split by signer when the manifest names signers, "
            "else by clip (and said so, since then numbers are kinder than on a stranger). The run folder gets "
            "checkpoint-last.pt, checkpoint-best.pt (best validation top-1 of the EMA weights), log.jsonl, "
            "labels.json and splits.json. Next: signs.evaluate --split test, signs.calibrate, signs.export_coreml."
        )
    )
    argument_parser.add_argument("--data", nargs="+", required=True, dest="data_folders", help="packed dataset folders")
    argument_parser.add_argument("--output", required=True, dest="output_folder", help="run folder for checkpoints and logs")
    argument_parser.add_argument("--language", default=None, help="only rows of this language (asl or isl)")
    argument_parser.add_argument(
        "--min-clips-per-letter", type=int, default=defaults.min_clips_per_letter,
        help="letters with fewer training clips are left out (default %(default)s)",
    )
    argument_parser.add_argument("--epochs", type=int, default=defaults.epochs)
    argument_parser.add_argument("--batch-size", type=int, default=defaults.batch_size)
    argument_parser.add_argument("--learning-rate", type=float, default=defaults.learning_rate)
    argument_parser.add_argument("--weight-decay", type=float, default=defaults.weight_decay)
    argument_parser.add_argument("--warmup-epochs", type=float, default=defaults.warmup_epochs)
    argument_parser.add_argument("--label-smoothing", type=float, default=defaults.label_smoothing)
    argument_parser.add_argument("--gradient-clip-norm", type=float, default=defaults.gradient_clip_norm)
    argument_parser.add_argument("--ema-decay", type=float, default=defaults.ema_decay)
    argument_parser.add_argument("--hidden-width", type=int, default=defaults.hidden_width, help="the MLP's width")
    argument_parser.add_argument("--dropout-rate", type=float, default=defaults.dropout_rate)
    argument_parser.add_argument("--seed", type=int, default=defaults.seed)
    argument_parser.add_argument("--test-fraction", type=float, default=defaults.test_fraction)
    argument_parser.add_argument("--validation-fraction", type=float, default=defaults.validation_fraction)
    argument_parser.add_argument("--workers", type=int, default=defaults.workers)
    argument_parser.add_argument("--device", choices=DEVICE_CHOICES, default=defaults.device)
    argument_parser.add_argument("--resume", default=None, help="checkpoint file or run folder to carry on from")
    argument_parser.add_argument("--no-augment", action="store_true", help="no mirror, turn, size change or jitter")
    return LetterTrainingSettings(**vars(argument_parser.parse_args(argument_list)))


def letter_dataset(sources, references, letter_list, augment_settings, seed) -> WordClipDataset:
    """The word dataset does exactly what one frame needs: trim, augment, features, thin to 1 frame."""
    return WordClipDataset(sources, references, letter_list, augment_settings, seed, frame_count=LETTER_MODEL_FRAME_COUNT)


def main(argument_list=None) -> None:
    settings = parse_arguments(argument_list)
    seed_everything(settings.seed)
    device = pick_device(settings.device)
    output_folder = Path(settings.output_folder)
    output_folder.mkdir(parents=True, exist_ok=True)

    resumed_checkpoint = load_checkpoint(resolve_resume_path(settings.resume)) if settings.resume else None
    if resumed_checkpoint is not None:
        # Data, split, letters and model shape come from the run being continued.
        data_folders = resumed_checkpoint["data_folders"]
        saved_split_plans = resumed_checkpoint["signer_splits"]
        language = resumed_checkpoint["language"]
    else:
        data_folders = [str(Path(data_folder).resolve()) for data_folder in settings.data_folders]
        saved_split_plans = None
        language = settings.language

    sources = load_sources(data_folders)
    sample_references, split_plans = assign_letter_splits(
        sources,
        settings.seed,
        settings.test_fraction,
        settings.validation_fraction,
        saved_split_plans=saved_split_plans,
        language=language,
    )
    for split_line in describe_split_plans(sources, split_plans):
        print(split_line, flush=True)
    training_references = references_in_split(sample_references, TRAIN_SPLIT)
    validation_references = references_in_split(sample_references, VALIDATION_SPLIT)
    if resumed_checkpoint is not None:
        letter_list = resumed_checkpoint["labels"]
        letter_model_settings_dict = resumed_checkpoint["letter_model_settings"]
    else:
        letter_list = build_word_list(training_references, settings.min_clips_per_letter)
        letter_model_settings_dict = LetterModelSettings(
            hidden_width=settings.hidden_width, dropout_rate=settings.dropout_rate
        ).to_dict()
    if not letter_list:
        raise SystemExit("no letter has enough training clips; lower --min-clips-per-letter")

    augment_settings = None if settings.no_augment else letter_augment_settings()
    training_dataset = letter_dataset(sources, training_references, letter_list, augment_settings, settings.seed)
    validation_dataset = letter_dataset(sources, validation_references, letter_list, None, settings.seed)

    model = build_letter_model(letter_model_settings_dict, len(letter_list)).to(device)
    print(
        f"device {device}; {len(letter_list)} letters; clips: {len(training_dataset)} train, "
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
        json.dump({"data_folders": data_folders, "signer_splits": split_plans}, splits_file, indent=1, sort_keys=True)
    with open(output_folder / "labels.json", "w", encoding="utf-8") as labels_file:
        json.dump(letter_list, labels_file, ensure_ascii=False)

    loss_function = nn.CrossEntropyLoss(label_smoothing=settings.label_smoothing)

    def compute_batch_loss(model_being_trained, batch_on_device):
        features, frame_mask, letter_numbers = batch_on_device
        scores, description = model_being_trained(features, frame_mask)
        return loss_function(scores, letter_numbers)

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
                exponential_moving_average.averaged_model,
                validation_dataset,
                letter_list,
                device,
                settings.batch_size,
                settings.workers,
            )
            log_entry.update(
                validation_loss=validation_results["loss"],
                validation_top1=validation_results["top1"],
                validation_top5=validation_results["top5"],
            )
            validation_score = validation_results["top1"]
        else:
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
            "labels": letter_list,
            "letter_model_settings": letter_model_settings_dict,
            "frame_count": LETTER_MODEL_FRAME_COUNT,
            "data_folders": data_folders,
            # Named as in the other checkpoints; here each entry is a split plan {"kind", "splits"}.
            "signer_splits": split_plans,
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
