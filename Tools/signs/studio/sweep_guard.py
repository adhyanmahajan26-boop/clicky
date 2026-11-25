"""Limits every download sweep keeps (popsign_sweeps.py, fsboard_sweeps.py). Pure where it can be, so it is tested
(Tools/signs/tests/test_sweep_guard.py):

- the volume must have at least `MIN_FREE_GB` free before a batch starts, or the job stops cleanly;
- raw videos on disk for a job never pass `RAW_CAP_GB` at a time: batches are cut by size, and a batch can't start
  while an earlier one's videos are still there;
- a job asks for a number of sweeps and a download budget (no "all"); it stops before a batch would pass the budget;
- at start it prints the planned download for the sweeps asked for;
- what has been read is kept in a small ledger, so nothing already extracted is downloaded again.
"""
from __future__ import annotations

import json
import os
import shutil
from pathlib import Path

MIN_FREE_GB = 60.0
RAW_CAP_GB = 12.0
# Batches are cut so their estimated size, times this, stays under the cap: sizes from a listing are exact, but an
# estimate from an average isn't.
ESTIMATE_SAFETY = 1.3


class StopJob(Exception):
    """The job stops here, cleanly: the message says why."""


def free_gb(path) -> float:
    return shutil.disk_usage(str(path)).free / 1e9


def check_free_space(free: float, minimum: float = MIN_FREE_GB) -> None:
    if free < minimum:
        raise StopJob(f"only {free:.1f} GB free on the volume (at least {minimum:.0f} GB must stay free); stopping")


def folder_gb(folder) -> float:
    total = 0
    for root, _, files in os.walk(folder):
        for name in files:
            try:
                total += os.path.getsize(os.path.join(root, name))
            except OSError:
                pass
    return total / 1e9


def check_no_raw_videos_left(raw_gb: float) -> None:
    """A new batch only starts on an empty work folder, so raw videos never pile up past one batch."""
    if raw_gb > 0.05:
        raise StopJob(f"{raw_gb:.1f} GB of raw videos from an earlier batch are still on disk; finish that batch first "
                      "(--finish-batch) instead of downloading more")


def cut_into_batches(items, sizes_mb, cap_gb: float = RAW_CAP_GB, most_items: int | None = None, exact_sizes: bool = True):
    """Consecutive batches of `items` whose sizes add up to at most `cap_gb` (estimated sizes count `ESTIMATE_SAFETY`
    times over). An item bigger than the cap on its own is a batch of one. `most_items` caps the count too."""
    factor = 1.0 if exact_sizes else ESTIMATE_SAFETY
    batches, current, current_mb = [], [], 0.0
    for item, size_mb in zip(items, sizes_mb):
        size = size_mb * factor
        if current and (current_mb + size > cap_gb * 1000 or (most_items and len(current) >= most_items)):
            batches.append(current)
            current, current_mb = [], 0.0
        current.append(item)
        current_mb += size
    if current:
        batches.append(current)
    return batches


class DownloadBudget:
    """Bytes allowed this run. `allows(next_gb)` is false once the next batch would pass it."""

    def __init__(self, limit_gb: float):
        if limit_gb <= 0:
            raise ValueError("--max-download-gb must be above 0")
        self.limit_gb = limit_gb
        self.used_gb = 0.0

    def allows(self, next_gb: float) -> bool:
        return self.used_gb + next_gb <= self.limit_gb

    def spend(self, gb: float) -> None:
        self.used_gb += gb


class ReadLedger:
    """Keys of the sources already read (downloaded and extracted), one per line: never downloaded again."""

    def __init__(self, path):
        self.path = Path(path)
        self.keys = set(self.path.read_text().split("\n")) - {""} if self.path.exists() else set()

    def __contains__(self, key) -> bool:
        return key in self.keys

    def add_all(self, keys) -> None:
        new = [key for key in dict.fromkeys(keys) if key not in self.keys]
        if not new:
            return
        self.path.parent.mkdir(parents=True, exist_ok=True)
        with open(self.path, "a") as ledger_file:
            ledger_file.write("".join(f"{key}\n" for key in new))
        self.keys.update(new)


def plan_line(job_name: str, sweeps: int, items: int, planned_gb: float, budget_gb: float, exact: bool) -> str:
    kind = "from the listing's file sizes" if exact else "estimated from the average size so far"
    return (f"{job_name}: plan for {sweeps} sweep(s): {items} videos not read yet, {planned_gb:.1f} GB to download ({kind}); "
            f"budget {budget_gb:.0f} GB, at most {RAW_CAP_GB:.0f} GB of raw videos at a time, stops under {MIN_FREE_GB:.0f} GB free")


def write_plan(state_folder, job_name: str, details: dict) -> None:
    Path(state_folder).mkdir(parents=True, exist_ok=True)
    (Path(state_folder) / "plan.json").write_text(json.dumps(dict(details, job=job_name), indent=1))
