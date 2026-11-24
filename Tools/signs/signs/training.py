"""Pieces both trainers and evaluate.py share: device choice, seeding, EMA, the learning-rate schedule,
checkpoints, the JSON-lines log, the CTC loss and the metrics."""

from __future__ import annotations

import copy
import json
import math
import os
import sys
import random
import time
from pathlib import Path

import numpy as np
import torch
from torch import nn
from torch.nn import functional

DEVICE_CHOICES = ("auto", "mps", "cuda", "cpu")


def pick_device(device_choice: str = "auto") -> torch.device:
    """`auto` takes Apple's GPU (MPS) when there is one, else CUDA, else the CPU."""
    if device_choice != "auto":
        return torch.device(device_choice)
    if torch.backends.mps.is_available():
        return torch.device("mps")
    if torch.cuda.is_available():
        return torch.device("cuda")
    return torch.device("cpu")


def seed_everything(seed: int) -> None:
    random.seed(seed)
    np.random.seed(seed)
    torch.manual_seed(seed)


def default_worker_count() -> int:
    """No worker processes on macOS: they are started with "spawn", which re-imports torch in every worker every
    epoch (measured on the Mac Studio, 708 INCLUDE clips: 35 s an epoch with 4 workers, 1.1 s with none)."""
    if sys.platform == "darwin":
        return 0
    return min(8, os.cpu_count() or 1)


class ExponentialMovingAverage:
    """A slowly-moving copy of the model's weights, used for validation, the best checkpoint and export: it is
    steadier than the weights of any single step. The decay ramps up over the first steps so the average isn't
    stuck near the random starting weights."""

    def __init__(self, model: nn.Module, decay: float = 0.999):
        self.decay = decay
        self.update_count = 0
        self.averaged_model = copy.deepcopy(model).eval()
        for parameter in self.averaged_model.parameters():
            parameter.requires_grad_(False)

    @torch.no_grad()
    def update(self, model: nn.Module) -> None:
        self.update_count += 1
        effective_decay = min(self.decay, (1 + self.update_count) / (10 + self.update_count))
        model_state = model.state_dict()
        for name, averaged_value in self.averaged_model.state_dict().items():
            current_value = model_state[name].detach()
            if averaged_value.dtype.is_floating_point:
                averaged_value.mul_(effective_decay).add_(current_value, alpha=1 - effective_decay)
            else:
                averaged_value.copy_(current_value)

    def state_dict(self) -> dict:
        return {"model": self.averaged_model.state_dict(), "update_count": self.update_count, "decay": self.decay}

    def load_state_dict(self, saved_state: dict) -> None:
        self.averaged_model.load_state_dict(saved_state["model"])
        self.update_count = saved_state["update_count"]
        self.decay = saved_state["decay"]


def warmup_then_cosine(total_steps: int, warmup_steps: int, final_learning_rate_fraction: float = 0.01):
    """A LambdaLR factor: rises linearly from 0 over `warmup_steps`, then falls along a cosine to
    `final_learning_rate_fraction` of the peak at `total_steps`."""

    def learning_rate_factor(step: int) -> float:
        if step < warmup_steps:
            return (step + 1) / max(warmup_steps, 1)
        progress = min(1.0, (step - warmup_steps) / max(total_steps - warmup_steps, 1))
        cosine_factor = 0.5 * (1.0 + math.cos(math.pi * progress))
        return final_learning_rate_fraction + (1.0 - final_learning_rate_fraction) * cosine_factor

    return learning_rate_factor


def save_checkpoint(checkpoint: dict, path: str | os.PathLike) -> None:
    """Written to a temporary file and renamed, so a stopped run never leaves a broken checkpoint."""
    path = Path(path)
    temporary_path = path.with_suffix(path.suffix + ".partial")
    torch.save(checkpoint, temporary_path)
    os.replace(temporary_path, path)


def load_checkpoint(path: str | os.PathLike) -> dict:
    return torch.load(path, map_location="cpu", weights_only=False)


def resolve_resume_path(resume_argument: str) -> Path:
    """`--resume` takes a checkpoint file or a run folder (then its checkpoint-last.pt)."""
    resume_path = Path(resume_argument)
    if resume_path.is_dir():
        resume_path = resume_path / "checkpoint-last.pt"
    if not resume_path.exists():
        raise FileNotFoundError(f"no checkpoint at {resume_path}")
    return resume_path


class JsonLinesLog:
    def __init__(self, path: str | os.PathLike):
        self.path = Path(path)

    def write(self, entry: dict) -> None:
        with open(self.path, "a", encoding="utf-8") as log_file:
            log_file.write(json.dumps(entry, sort_keys=True) + "\n")


def move_to_device(tensors, device: torch.device):
    return [tensor.to(device, non_blocking=True) for tensor in tensors]


class Stopwatch:
    def __init__(self):
        self.started_at = time.monotonic()

    def seconds(self) -> float:
        return round(time.monotonic() - self.started_at, 1)


# ---- CTC ----------------------------------------------------------------------------------------------------

_ctc_loss_runs_on_this_device: dict[str, bool] = {}


def spelling_ctc_loss(
    log_probabilities: torch.Tensor,
    output_lengths: torch.Tensor,
    joined_targets: torch.Tensor,
    target_lengths: torch.Tensor,
) -> torch.Tensor:
    """Mean CTC loss (per target character) with blank 0. `log_probabilities` is [B, T, C+1].

    Runs on the model's device when torch can; when `ctc_loss` isn't implemented there (MPS in some torch
    versions) only this loss is computed on the CPU, and the gradient flows back to the device through `.to()`.
    """
    time_major_log_probabilities = log_probabilities.transpose(0, 1)  # CTC wants [T, B, C]
    device_type = log_probabilities.device.type
    if _ctc_loss_runs_on_this_device.get(device_type, True):
        try:
            return functional.ctc_loss(
                time_major_log_probabilities,
                joined_targets.to(log_probabilities.device),
                output_lengths.to(log_probabilities.device),
                target_lengths.to(log_probabilities.device),
                blank=0,
                reduction="mean",
                zero_infinity=True,
            )
        except (NotImplementedError, RuntimeError) as device_error:
            # MPS says "The operator 'aten::_ctc_loss' is not currently implemented for the MPS device".
            error_message = str(device_error).lower()
            operator_is_missing_on_device = isinstance(device_error, NotImplementedError) or (
                "not implemented" in error_message or "not currently implemented" in error_message
            )
            if device_type == "cpu" or not operator_is_missing_on_device:
                raise
            print(f"ctc_loss is not implemented on {device_type}; computing only the loss on the CPU", flush=True)
            _ctc_loss_runs_on_this_device[device_type] = False
    loss_on_cpu = functional.ctc_loss(
        time_major_log_probabilities.float().cpu(),
        joined_targets.cpu(),
        output_lengths.cpu(),
        target_lengths.cpu(),
        blank=0,
        reduction="mean",
        zero_infinity=True,
    )
    return loss_on_cpu.to(log_probabilities.device)


def greedy_ctc_decode(log_probabilities: torch.Tensor, output_lengths: torch.Tensor) -> list[list[int]]:
    """Best output per frame, repeats merged, blanks (0) removed. Returns output numbers (1 = first character)."""
    best_outputs = log_probabilities.argmax(dim=-1).cpu().numpy()
    decoded_sequences = []
    for sample_number, output_length in enumerate(output_lengths.cpu().tolist()):
        decoded_numbers = []
        previous_output = 0
        for output_number in best_outputs[sample_number, :output_length].tolist():
            if output_number != previous_output and output_number != 0:
                decoded_numbers.append(output_number)
            previous_output = output_number
        decoded_sequences.append(decoded_numbers)
    return decoded_sequences


def edit_distance(first_sequence, second_sequence) -> int:
    """Levenshtein distance (insertions, deletions and substitutions each cost 1)."""
    previous_row = list(range(len(second_sequence) + 1))
    for first_position, first_item in enumerate(first_sequence, start=1):
        current_row = [first_position]
        for second_position, second_item in enumerate(second_sequence, start=1):
            current_row.append(
                min(
                    previous_row[second_position] + 1,
                    current_row[second_position - 1] + 1,
                    previous_row[second_position - 1] + (first_item != second_item),
                )
            )
        previous_row = current_row
    return previous_row[-1]


def spelling_scores(total_target_characters: int, total_edit_distance: int) -> dict:
    """Character error rate D / N and the Kaggle competition's score (N − D) / N."""
    if total_target_characters == 0:
        return {"character_error_rate": None, "kaggle_score": None}
    return {
        "character_error_rate": total_edit_distance / total_target_characters,
        "kaggle_score": (total_target_characters - total_edit_distance) / total_target_characters,
    }


def decode_characters(output_numbers: list[int], character_list: list[str]) -> str:
    return "".join(character_list[output_number - 1] for output_number in output_numbers)


# ---- the loop both trainers share --------------------------------------------------------------------------


def train_one_epoch(
    model: nn.Module,
    training_loader,
    compute_batch_loss,
    optimizer: torch.optim.Optimizer,
    scheduler,
    exponential_moving_average: ExponentialMovingAverage,
    device: torch.device,
    gradient_clip_norm: float,
) -> float:
    """One pass over the training data. `compute_batch_loss(model, batch on device)` returns the loss.
    Returns the mean training loss."""
    model.train()
    loss_total = 0.0
    batch_count = 0
    for batch in training_loader:
        batch_on_device = move_to_device(batch, device)
        loss = compute_batch_loss(model, batch_on_device)
        optimizer.zero_grad(set_to_none=True)
        loss.backward()
        nn.utils.clip_grad_norm_(model.parameters(), gradient_clip_norm)
        optimizer.step()
        scheduler.step()
        exponential_moving_average.update(model)
        loss_total += float(loss.detach().cpu())
        batch_count += 1
    return loss_total / max(batch_count, 1)


def make_loader(dataset, batch_size: int, worker_count: int, shuffle: bool, seed: int, collate_function=None, drop_last=False):
    """Workers are not persistent, so each epoch's workers are started with the dataset's current epoch (its
    augmentation seed). The shuffle order comes from (seed) and the epoch through `shuffle_generator`."""
    from torch.utils.data import DataLoader

    shuffle_generator = torch.Generator()
    shuffle_generator.manual_seed(seed)
    if worker_count == 0:
        return DataLoader(
            dataset,
            batch_size=batch_size,
            shuffle=shuffle,
            num_workers=0,
            collate_fn=collate_function,
            drop_last=drop_last,
            generator=shuffle_generator,
        )
    # Batches cross from the workers as NumPy arrays and become tensors here. Tensors returned by a worker go
    # through torch's shared memory, which on macOS starts torch_shm_manager processes that never exit and keep the
    # training run (and pytest) from finishing.
    worker_collate = _NumpyBatchCollate(collate_function)
    worker_loader = DataLoader(
        dataset,
        batch_size=batch_size,
        shuffle=shuffle,
        num_workers=worker_count,
        collate_fn=worker_collate,
        drop_last=drop_last,
        generator=shuffle_generator,
        persistent_workers=False,
    )
    return _TensorBatches(worker_loader)


def _tensors_to_numpy(value):
    if isinstance(value, torch.Tensor):
        return value.numpy()
    if isinstance(value, dict):
        return {key: _tensors_to_numpy(item) for key, item in value.items()}
    if isinstance(value, (list, tuple)):
        return type(value)(_tensors_to_numpy(item) for item in value)
    return value


def _numpy_to_tensors(value):
    if isinstance(value, np.ndarray):
        return torch.from_numpy(value)
    if isinstance(value, dict):
        return {key: _numpy_to_tensors(item) for key, item in value.items()}
    if isinstance(value, (list, tuple)):
        return type(value)(_numpy_to_tensors(item) for item in value)
    return value


class _NumpyBatchCollate:
    """Runs in a worker: the usual collate, then every tensor in the batch turned into a NumPy array (picklable,
    so it is sent through the worker's pipe rather than shared memory)."""

    def __init__(self, collate_function=None):
        self.collate_function = collate_function

    def __call__(self, samples):
        from torch.utils.data import default_collate

        batch = (self.collate_function or default_collate)(samples)
        return _tensors_to_numpy(batch)


class _TensorBatches:
    """Iterates a worker DataLoader and turns its NumPy batches back into tensors."""

    def __init__(self, loader):
        self.loader = loader
        self.dataset = loader.dataset

    def __len__(self):
        return len(self.loader)

    def __iter__(self):
        for batch in self.loader:
            yield _numpy_to_tensors(batch)
