"""The sentence model (`SignSentencesASL` / `SignSentencesISL`): reads a run of signs without rests.

The finger-spelling model's shape over the word list: the shared encoder, one output row per 2 frames, 384 frames in
(192 rows), CTC with the blank at 0 and word i at i + 1. Trained on sentences built fresh every epoch from the
training signers' single-sign clips (`signs/sentences.py` says how), plus any real continuous clips (labels of
several signs joined with `|`) in the training split. Validation and test sentences are built once, with a fixed seed, from the
validation and test signers' clips, so the numbers are on signers never seen.

**Numbers on built sentences are not numbers on real fluent signing**: joined clips lack the way neighbouring
signs change each other. Real continuous clips, when the data has any, are reported apart.

`--start-from <word checkpoint>` starts the encoder from a trained word model (its averaged weights); the
frame-halving layer and the CTC head start fresh. The test split is never read here; run
`python -m signs.evaluate --checkpoint <run>/checkpoint-best.pt --split test` once, at the end.

    python -m signs.train_sentences --data /data/signs/asl-signs --language asl --output runs/sentences-asl \\
        --start-from runs/words-asl/checkpoint-best.pt
"""

from __future__ import annotations

import argparse
import json
import math
from dataclasses import asdict, dataclass, field
from pathlib import Path

import torch
from torch import nn

from .augment import AugmentSettings
from .data import assign_splits, build_word_list, collate_spelling_batch, load_sources, references_in_split
from .model import EncoderSettings, SignSpellModel, count_parameters
from .sentences import (
    SENTENCE_MODEL_FRAME_COUNT,
    SENTENCES_TASK_NAME,
    SentenceDataset,
    SentenceSettings,
    is_continuous_label,
)
from .splits import TRAIN_SPLIT, VALIDATION_SPLIT
from .training import (
    DEVICE_CHOICES,
    ExponentialMovingAverage,
    JsonLinesLog,
    Stopwatch,
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
    train_one_epoch,
    warmup_then_cosine,
)

TASK_NAME = SENTENCES_TASK_NAME
# The fixed validation and test sentences are planned from (seed + this, split number), so they stay the same
# whichever training seed changes elsewhere would otherwise disturb.
MEASURING_SEED_OFFSET = 1_000_003
MEASURING_SPLIT_NUMBERS = {"train": 0, "val": 1, "test": 2}


@dataclass
class SentenceTrainingSettings:
    data_folders: list[str]
    output_folder: str
    language: str | None = None
    min_clips_per_word: int = 5
    start_from: str | None = None
    sentences_per_epoch: int = 0
    evaluation_sentences: int = 0
    most_signs: int = 6
    one_sign_share: float = 0.25
    epochs: int = 60
    batch_size: int = 32
    learning_rate: float = 1e-3
    weight_decay: float = 0.05
    warmup_epochs: float = 2.0
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


def parse_arguments(argument_list=None) -> SentenceTrainingSettings:
    defaults = SentenceTrainingSettings(data_folders=[], output_folder="")
    argument_parser = argparse.ArgumentParser(
        description=(
            "Train the sentence model (SignSentencesASL / SignSentencesISL): a run of signs without rests, read as "
            "words by CTC (384 frames in, a row per 2 frames). Sentences of 1 to 6 signs are built fresh each epoch "
            "from the training signers' single-sign clips; validation and test sentences are built once from "
            "signers never seen. Rows whose label is several signs joined with | are real continuous clips and are used as "
            "they are. Built-sentence numbers are NOT numbers on real fluent signing. The run folder gets "
            "checkpoint-last.pt, checkpoint-best.pt (lowest validation word error rate of the EMA weights), "
            "log.jsonl, labels.json and splits.json."
        )
    )
    argument_parser.add_argument("--data", nargs="+", required=True, dest="data_folders", help="packed dataset folders")
    argument_parser.add_argument("--output", required=True, dest="output_folder", help="run folder for checkpoints and logs")
    argument_parser.add_argument("--language", default=None, help="only rows of this language (asl or isl)")
    argument_parser.add_argument(
        "--min-clips-per-word", type=int, default=defaults.min_clips_per_word,
        help="words with fewer single-sign training clips are left out (default %(default)s)",
    )
    argument_parser.add_argument(
        "--start-from", default=None,
        help="a word model's checkpoint: its encoder's averaged weights are the starting point (same width)",
    )
    argument_parser.add_argument(
        "--sentences-per-epoch", type=int, default=defaults.sentences_per_epoch,
        help="built training sentences each epoch; 0 = about one use of each training clip per epoch",
    )
    argument_parser.add_argument(
        "--evaluation-sentences", type=int, default=defaults.evaluation_sentences,
        help="built validation (and test) sentences, fixed; 0 = as many as that split has single-sign clips",
    )
    argument_parser.add_argument("--most-signs", type=int, default=defaults.most_signs, help="longest built sentence")
    argument_parser.add_argument(
        "--one-sign-share", type=float, default=defaults.one_sign_share, help="share of built sentences with one sign"
    )
    argument_parser.add_argument("--epochs", type=int, default=defaults.epochs)
    argument_parser.add_argument("--batch-size", type=int, default=defaults.batch_size)
    argument_parser.add_argument("--learning-rate", type=float, default=defaults.learning_rate)
    argument_parser.add_argument("--weight-decay", type=float, default=defaults.weight_decay)
    argument_parser.add_argument("--warmup-epochs", type=float, default=defaults.warmup_epochs)
    argument_parser.add_argument("--gradient-clip-norm", type=float, default=defaults.gradient_clip_norm)
    argument_parser.add_argument("--ema-decay", type=float, default=defaults.ema_decay)
    argument_parser.add_argument("--width", type=int, default=defaults.width, help="ignored with --start-from")
    argument_parser.add_argument("--drop-path-rate", type=float, default=defaults.drop_path_rate)
    argument_parser.add_argument("--dropout-rate", type=float, default=defaults.dropout_rate)
    argument_parser.add_argument("--seed", type=int, default=defaults.seed)
    argument_parser.add_argument("--test-fraction", type=float, default=defaults.test_fraction)
    argument_parser.add_argument("--validation-fraction", type=float, default=defaults.validation_fraction)
    argument_parser.add_argument("--workers", type=int, default=defaults.workers)
    argument_parser.add_argument("--device", choices=DEVICE_CHOICES, default=defaults.device)
    argument_parser.add_argument("--resume", default=None, help="checkpoint file or run folder to carry on from")
    argument_parser.add_argument("--no-augment", action="store_true", help="no augmentation of the built sentences")
    return SentenceTrainingSettings(**vars(argument_parser.parse_args(argument_list)))


def build_sentence_model(encoder_settings_dict: dict, word_count: int) -> SignSpellModel:
    return SignSpellModel(EncoderSettings(**encoder_settings_dict), word_count)


def encoder_settings_from_word_checkpoint(word_checkpoint: dict, settings: SentenceTrainingSettings) -> dict:
    if word_checkpoint.get("task") != "words":
        raise SystemExit(f"--start-from needs a word model's checkpoint, not a {word_checkpoint.get('task')!r} one")
    encoder_settings_dict = dict(word_checkpoint["encoder_settings"])
    encoder_settings_dict.update(
        halve_frames_after_first_stage=True, drop_path_rate=settings.drop_path_rate, dropout_rate=settings.dropout_rate
    )
    return encoder_settings_dict


def load_word_encoder(model: SignSpellModel, word_checkpoint: dict) -> list[str]:
    """Copies a word model's averaged encoder weights into `model`. Returns the encoder weights that start fresh
    (only the frame-halving layer, which a word model doesn't have)."""
    encoder_prefix = "encoder."
    word_encoder_state = {
        name[len(encoder_prefix) :]: value
        for name, value in word_checkpoint["ema_state"]["model"].items()
        if name.startswith(encoder_prefix)
    }
    load_result = model.encoder.load_state_dict(word_encoder_state, strict=False)
    if load_result.unexpected_keys:
        raise SystemExit(f"the word model's encoder doesn't fit: unexpected {load_result.unexpected_keys[:5]}")
    unexpected_fresh = [name for name in load_result.missing_keys if not name.startswith("halve_frames")]
    if unexpected_fresh:
        raise SystemExit(f"the word model's encoder doesn't fit: missing {unexpected_fresh[:5]}")
    return list(load_result.missing_keys)


def measuring_dataset(sources, references, word_list, sentence_settings, seed, sentence_count, split_name) -> SentenceDataset:
    """Validation or test sentences, built once from a fixed seed (no augmentation)."""
    return SentenceDataset(
        sources,
        references,
        word_list,
        sentence_settings,
        augment_settings=None,
        seed=(seed + MEASURING_SEED_OFFSET) * 10 + MEASURING_SPLIT_NUMBERS[split_name],
        fixed_sentence_count=sentence_count,
    )


def default_measuring_sentence_count(references, word_list) -> int:
    """One built sentence per single-sign clip of the split whose word the model has."""
    word_set = set(word_list)
    return sum(1 for reference in references if not is_continuous_label(reference.label) and reference.label.strip() in word_set)


@torch.no_grad()
def evaluate_sentence_model(
    model: nn.Module,
    dataset: SentenceDataset,
    word_list: list[str],
    device: torch.device,
    batch_size: int,
    workers: int,
    example_count: int = 10,
) -> dict:
    """Greedy CTC decoding. Word error rate = total edit distance / total words, over every sample; then the same
    for real continuous clips alone, and how often a built one-sign sentence comes out as exactly its word."""
    model.eval()
    loader = make_loader(dataset, batch_size, workers, shuffle=False, seed=0, collate_function=collate_spelling_batch)
    totals = {"words": 0, "edits": 0, "real_words": 0, "real_edits": 0, "one_sign": 0, "one_sign_right": 0}
    loss_total = 0.0
    batch_count = 0
    item_number = 0
    examples = []
    for batch in loader:
        features, frame_mask, joined_targets, target_lengths = move_to_device(batch, device)
        log_probabilities, output_lengths = model(features, frame_mask)
        loss_total += float(spelling_ctc_loss(log_probabilities, output_lengths, joined_targets, target_lengths).cpu())
        batch_count += 1
        for decoded_numbers in greedy_ctc_decode(log_probabilities, output_lengths):
            item = dataset.items[item_number]
            item_number += 1
            decoded_word_numbers = [output_number - 1 for output_number in decoded_numbers]
            edits = edit_distance(decoded_word_numbers, item.word_numbers)
            totals["words"] += item.sign_count
            totals["edits"] += edits
            if item.is_real_continuous_clip:
                totals["real_words"] += item.sign_count
                totals["real_edits"] += edits
            elif item.sign_count == 1:
                totals["one_sign"] += 1
                totals["one_sign_right"] += int(decoded_word_numbers == item.word_numbers)
            if len(examples) < example_count:
                examples.append(
                    {
                        "target": " ".join(word_list[number] if number >= 0 else "<unknown>" for number in item.word_numbers),
                        "decoded": " ".join(word_list[number] for number in decoded_word_numbers),
                        "real": item.is_real_continuous_clip,
                    }
                )

    def share(numerator: int, denominator: int):
        return numerator / denominator if denominator else None

    return {
        "samples": item_number,
        "built_sentences": item_number - sum(1 for item in dataset.items if item.is_real_continuous_clip),
        "real_continuous_clips": sum(1 for item in dataset.items if item.is_real_continuous_clip),
        "loss": loss_total / batch_count if batch_count else None,
        "word_error_rate": share(totals["edits"], totals["words"]),
        "real_continuous_word_error_rate": share(totals["real_edits"], totals["real_words"]),
        "one_sign_sentences": totals["one_sign"],
        "one_sign_accuracy": share(totals["one_sign_right"], totals["one_sign"]),
        "examples": examples,
        "note": "built sentences are joined single-sign clips, not real fluent signing",
    }


def evaluate_sentence_checkpoint(checkpoint: dict, sources, split_references, split_name, device, batch_size, workers) -> dict:
    """The same fixed sentences training measured on (for `--split val`), or the test ones."""
    sentence_settings = SentenceSettings(**checkpoint["sentence_settings"])
    sentence_count = checkpoint["evaluation_sentences"] or default_measuring_sentence_count(
        split_references, checkpoint["labels"]
    )
    dataset = measuring_dataset(
        sources, split_references, checkpoint["labels"], sentence_settings, checkpoint["seed"], sentence_count, split_name
    )
    model = build_sentence_model(checkpoint["encoder_settings"], len(checkpoint["labels"]))
    model.load_state_dict(checkpoint["ema_state"]["model"])
    return evaluate_sentence_model(model.to(device), dataset, checkpoint["labels"], device, batch_size, workers)


def main(argument_list=None) -> None:
    settings = parse_arguments(argument_list)
    seed_everything(settings.seed)
    device = pick_device(settings.device)
    output_folder = Path(settings.output_folder)
    output_folder.mkdir(parents=True, exist_ok=True)

    resumed_checkpoint = load_checkpoint(resolve_resume_path(settings.resume)) if settings.resume else None
    if resumed_checkpoint is not None:
        # Data, signer split, words, sentence recipe and model shape come from the run being continued.
        data_folders = resumed_checkpoint["data_folders"]
        saved_signer_splits = resumed_checkpoint["signer_splits"]
        language = resumed_checkpoint["language"]
        sentence_settings = SentenceSettings(**resumed_checkpoint["sentence_settings"])
        evaluation_sentences = resumed_checkpoint["evaluation_sentences"]
        # The fixed validation sentences come from the run's own seed, so they are the same after a resume.
        run_seed = resumed_checkpoint["seed"]
    else:
        data_folders = [str(Path(data_folder).resolve()) for data_folder in settings.data_folders]
        saved_signer_splits = None
        language = settings.language
        sentence_settings = SentenceSettings(most_signs=settings.most_signs, one_sign_share=settings.one_sign_share)
        evaluation_sentences = settings.evaluation_sentences
        run_seed = settings.seed

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

    word_checkpoint = None
    if resumed_checkpoint is not None:
        word_list = resumed_checkpoint["labels"]
        encoder_settings_dict = resumed_checkpoint["encoder_settings"]
    else:
        single_sign_training_references = [
            reference for reference in training_references if not is_continuous_label(reference.label)
        ]
        word_list = build_word_list(single_sign_training_references, settings.min_clips_per_word)
        if settings.start_from:
            word_checkpoint = load_checkpoint(settings.start_from)
            encoder_settings_dict = encoder_settings_from_word_checkpoint(word_checkpoint, settings)
        else:
            encoder_settings_dict = EncoderSettings(
                width=settings.width,
                drop_path_rate=settings.drop_path_rate,
                dropout_rate=settings.dropout_rate,
                halve_frames_after_first_stage=True,
            ).to_dict()
    if not word_list:
        raise SystemExit("no word has enough single-sign training clips; lower --min-clips-per-word")

    augment_settings = None if settings.no_augment else AugmentSettings()
    single_sign_training_clip_count = default_measuring_sentence_count(training_references, word_list)
    sentences_per_epoch = settings.sentences_per_epoch or max(
        1, math.ceil(single_sign_training_clip_count / sentence_settings.mean_sign_count())
    )
    training_dataset = SentenceDataset(
        sources,
        training_references,
        word_list,
        sentence_settings,
        augment_settings,
        settings.seed,
        fresh_sentence_count=sentences_per_epoch,
    )
    validation_sentence_count = evaluation_sentences or default_measuring_sentence_count(validation_references, word_list)
    validation_dataset = measuring_dataset(
        sources, validation_references, word_list, sentence_settings, run_seed, validation_sentence_count, VALIDATION_SPLIT
    )

    model = build_sentence_model(encoder_settings_dict, len(word_list)).to(device)
    if word_checkpoint is not None:
        fresh_weights = load_word_encoder(model, word_checkpoint)
        print(f"encoder from {settings.start_from}; starting fresh: {', '.join(fresh_weights) or 'nothing'}", flush=True)
    print(
        f"device {device}; {len(word_list)} words; each epoch {sentences_per_epoch} built sentences + "
        f"{len(training_dataset.real_items)} real continuous clips; validation {len(validation_dataset)} samples "
        f"({len(validation_dataset.real_items)} real); model parameters: {count_parameters(model):,}",
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

    def compute_batch_loss(model_being_trained, batch_on_device):
        features, frame_mask, joined_targets, target_lengths = batch_on_device
        log_probabilities, output_lengths = model_being_trained(features, frame_mask)
        return spelling_ctc_loss(log_probabilities, output_lengths, joined_targets, target_lengths)

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
            compute_batch_loss,
            optimizer,
            scheduler,
            exponential_moving_average,
            device,
            settings.gradient_clip_norm,
        )
        log_entry = {"epoch": epoch, "train_loss": training_loss, "learning_rate": scheduler.get_last_lr()[0]}
        if len(validation_dataset) > 0:
            validation_results = evaluate_sentence_model(
                exponential_moving_average.averaged_model,
                validation_dataset,
                word_list,
                device,
                settings.batch_size,
                settings.workers,
                example_count=3,
            )
            log_entry.update(
                validation_loss=validation_results["loss"],
                validation_word_error_rate=validation_results["word_error_rate"],
                validation_one_sign_accuracy=validation_results["one_sign_accuracy"],
                validation_real_continuous_word_error_rate=validation_results["real_continuous_word_error_rate"],
                validation_examples=validation_results["examples"],
            )
            validation_score = -validation_results["word_error_rate"]
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
            "labels": word_list,
            "encoder_settings": encoder_settings_dict,
            "frame_count": SENTENCE_MODEL_FRAME_COUNT,
            "sentence_settings": sentence_settings.to_dict(),
            "evaluation_sentences": evaluation_sentences,
            "started_from": settings.start_from if resumed_checkpoint is None else resumed_checkpoint.get("started_from"),
            "data_folders": data_folders,
            "signer_splits": signer_splits,
            "language": language,
            "seed": run_seed,
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
