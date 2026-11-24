#!/usr/bin/env python3
"""A fixed copy of a dataset that is still growing: manifest.csv as it is now, its clips as hard links (no space).
usage: snapshot.py <dataset folder> <snapshot folder>
Training packs and reads the snapshot, so a job still adding clips can't change the data under a run."""
import csv, os, sys
from pathlib import Path
source, target = Path(sys.argv[1]), Path(sys.argv[2])
target.mkdir(parents=True, exist_ok=True)
with open(source / "manifest.csv", newline="") as manifest_file:
    rows = list(csv.reader(manifest_file))
kept = [rows[0]]
for row in rows[1:]:
    clip_path = source / f"{row[0]}.npy"
    if not clip_path.exists():
        continue
    link_path = target / clip_path.name
    if not link_path.exists():
        os.link(clip_path, link_path)
    kept.append(row)
with open(target / "manifest.csv", "w", newline="") as manifest_file:
    csv.writer(manifest_file).writerows(kept)
print(f"{len(kept) - 1} clips in {target}")
