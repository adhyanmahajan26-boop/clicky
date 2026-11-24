#!/usr/bin/env python3
"""FSboard (CC BY 4.0, Google, hosted by Georgia Tech) read from its videos with Apple Vision, in sweeps.

FSboard's published landmark shards are scrambled (Tools/signs/signs/fsboard_source.py), so clips are taken from
video_clips/ instead, as a sample: sweep k = 8,000 train clips (4,000 daun_v3 + 4,000 dmk_v3), 600 daun_v3
validation and 600 daun_v3 test; five sweeps planned, each with new clips. Clips are picked with a fixed seed,
spread evenly over signers (one clip of each signer, then the next of each, ...), never sensitiveContent ones, and
never the 200 already read as dataset `fsboard-apple` (validation signers, kept out of training).

Each clip: download, `sign-extract videos --face` (padded body pose), keep only the frames of the signed part (the
metadata's annotation times relative to the clip's start, 0.25 s either side), write `<landmarks>/fsboard/<clip>.npy`
and a manifest row (dataset fsboard, language asl, label = phrase in lower case, signer = signerId, split =
FSboard's own, source apple), delete the video.

Resumable (a finished batch leaves logs/fsboard-state/<batch>.done; finished clips are skipped). Stop with
`kill $(cat ~/sign-data/logs/fsboard.pid)`.
    nohup /usr/bin/python3 ~/sign-data/tools/fsboard_sweeps.py [--sweeps 5] > ~/sign-data/logs/fsboard.log 2>&1 &
"""
import argparse, csv, hashlib, json, os, random, shutil, subprocess, sys, time, urllib.parse
from collections import defaultdict
from pathlib import Path

import numpy as np

DATA = Path.home() / "sign-data"
BASE = "https://signdata.cc.gatech.edu/data/fsboard/"
METADATA = DATA / "downloads/fsboard"
OUT = DATA / "landmarks/fsboard"
RAW = DATA / "downloads/fsboard-raw-landmarks"
WORK = DATA / "downloads/fsboard-videos"
STATE = DATA / "logs/fsboard-state"
EXTRACTOR = DATA / "tools/bin/sign-extract"
FETCH_MANY = DATA / "tools/fetch_many.py"
ALREADY_READ = DATA / "downloads/fsboard-apple/chosen.json"
SEED = 20261124
SECONDS_KEPT_EITHER_SIDE = 0.25
BATCH_SIZE = 500
CONNECTIONS = 12  # about half the line next to the PopSign sweeps' 12
# (pool name, study, FSboard split, metadata file, SPEC split, clips a sweep)
POOLS = [
    ("daun-train", "daun_v3", "train", "daun_v3-train.json", "train", 4000),
    ("dmk-train", "dmk_v3", "train", "dmk_v3-train.json", "train", 4000),
    ("daun-val", "daun_v3", "validation", "daun_v3-validation.json", "val", 600),
    ("daun-test", "daun_v3", "test", "daun_v3-test.json", "test", 600),
]
MANIFEST_COLUMNS = ["clip_id", "dataset", "language", "label", "signer", "split", "fps", "width", "height", "frames", "source"]


def log(message):
    print(time.strftime("%Y-%m-%d %H:%M:%S"), message, flush=True)


def stem(record):
    return Path(record["clipFilename"]).name.rsplit(".", 1)[0]


def ordered_pool(records, seed):
    """Seeded shuffle within each signer, then one clip of each signer in turn."""
    generator = random.Random(seed)
    by_signer = defaultdict(list)
    for record in sorted(records, key=lambda record: record["clipFilename"]):
        by_signer[record["signerId"]].append(record)
    for signer in sorted(by_signer):
        generator.shuffle(by_signer[signer])
    signers = sorted(by_signer)
    generator.shuffle(signers)
    ordered, round_number = [], 0
    while True:
        taken = [by_signer[signer][round_number] for signer in signers if round_number < len(by_signer[signer])]
        if not taken:
            return ordered
        ordered += taken
        round_number += 1


def clip_id_for(study, record):
    return f"fsboard-{study}-{stem(record)}"


def trim_to_signed_part(clip, fps, record):
    """Frame i of the video is at i / fps seconds after the clip's start (clipStartTimeS)."""
    if fps <= 0 or len(clip) == 0:
        return clip
    first_second = record["annotationStartTimeS"] - record["clipStartTimeS"] - SECONDS_KEPT_EITHER_SIDE
    last_second = record["annotationEndTimeS"] - record["clipStartTimeS"] + SECONDS_KEPT_EITHER_SIDE
    frame_times = np.arange(len(clip)) / fps
    kept = (frame_times >= first_second) & (frame_times <= last_second)
    return clip[kept]


def run_batch(batch_name, jobs):
    """jobs: [(study, fsboard split, spec split, record)]."""
    todo = [job for job in jobs if not (OUT / f"{clip_id_for(job[0], job[3])}.npy").exists()]
    if not todo:
        return
    started = time.time()
    folder = WORK / batch_name
    by_folder = defaultdict(list)
    for study, fsboard_split, spec_split, record in todo:
        by_folder[(study, fsboard_split)].append(record["clipFilename"])
    for (study, fsboard_split), names in by_folder.items():
        target = folder / f"{study}-{fsboard_split}"
        target.mkdir(parents=True, exist_ok=True)
        names_file = target / "names.txt"
        names_file.write_text("\n".join(names) + "\n")
        subprocess.run([sys.executable, str(FETCH_MANY), f"{BASE}{study}/video_clips/{study}-{fsboard_split}/", str(target),
                        str(names_file), str(CONNECTIONS)], stdout=subprocess.DEVNULL)
    lines, downloaded_bytes = [], 0
    for study, fsboard_split, spec_split, record in todo:
        path = folder / f"{study}-{fsboard_split}" / record["clipFilename"]
        if path.exists():
            downloaded_bytes += path.stat().st_size
            lines.append(f"{clip_id_for(study, record)}\t{path}\n")
    downloaded = time.time()
    processes = []
    for index in range(4):
        slice_lines = lines[index::4]
        if not slice_lines:
            continue
        slice_path = STATE / f"{batch_name}.slice{index}.tsv"
        slice_path.write_text("".join(slice_lines))
        processes.append(subprocess.Popen([str(EXTRACTOR), "videos", "--list", str(slice_path), "--out", str(RAW), "--face", "--jobs", "4"],
                                          stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL))
    for process in processes:
        process.wait()
    extracted = time.time()
    with open(RAW / "extract.csv") as extract_file:
        extract_rows = {row["clip_id"]: row for row in csv.DictReader(extract_file)}
    manifest_path = OUT / "manifest.csv"
    new_file = not manifest_path.exists()
    written = 0
    with open(manifest_path, "a", newline="") as manifest_file:
        writer = csv.DictWriter(manifest_file, fieldnames=MANIFEST_COLUMNS)
        if new_file:
            writer.writeheader()
        for study, fsboard_split, spec_split, record in todo:
            clip_id = clip_id_for(study, record)
            raw_path = RAW / f"{clip_id}.npy"
            row = extract_rows.get(clip_id)
            if row is None or not raw_path.exists():
                continue
            clip = trim_to_signed_part(np.load(raw_path), float(row["fps"]), record)
            if len(clip) == 0:
                raw_path.unlink()
                continue
            temporary_path = OUT / f".{clip_id}.partial.npy"
            np.save(temporary_path, clip.astype("<f4"))
            os.replace(temporary_path, OUT / f"{clip_id}.npy")
            writer.writerow({"clip_id": clip_id, "dataset": "fsboard", "language": "asl", "label": record["phrase"].lower(),
                             "signer": record["signerId"], "split": spec_split, "fps": row["fps"], "width": row["width"],
                             "height": row["height"], "frames": len(clip), "source": "apple"})
            raw_path.unlink()
            written += 1
    shutil.rmtree(folder, ignore_errors=True)
    for path in STATE.glob(f"{batch_name}.slice*.tsv"):
        path.unlink()
    log(f"{batch_name}: {len(todo)} clips, {len(lines)} downloaded ({downloaded_bytes / 1e9:.2f} GB), {written} written; "
        f"download {downloaded - started:.0f} s ({downloaded_bytes / 1e6 / max(downloaded - started, 1):.1f} MB/s), "
        f"extract {extracted - downloaded:.0f} s; {3600 * len(todo) / max(time.time() - started, 1):.0f} clips an hour")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--sweeps", type=int, default=5)
    arguments = parser.parse_args()
    for folder in (OUT, RAW, WORK, STATE):
        folder.mkdir(parents=True, exist_ok=True)
    (DATA / "logs/fsboard.pid").write_text(str(os.getpid()))
    already_read = set()
    if ALREADY_READ.exists():
        already_read = {stem(record) for record in json.loads(ALREADY_READ.read_text())}
    ordered = {}
    for pool_name, study, fsboard_split, metadata_name, spec_split, per_sweep in POOLS:
        records = [record for record in json.loads((METADATA / metadata_name).read_text())
                   if not record.get("sensitiveContent") and stem(record) not in already_read]
        ordered[pool_name] = ordered_pool(records, SEED)
        log(f"{pool_name}: {len(records)} clips usable, {len({record['signerId'] for record in records})} signers")
    for sweep in range(1, arguments.sweeps + 1):
        jobs = []
        for pool_name, study, fsboard_split, metadata_name, spec_split, per_sweep in POOLS:
            jobs += [(study, fsboard_split, spec_split, record)
                     for record in ordered[pool_name][(sweep - 1) * per_sweep : sweep * per_sweep]]
        # interleave the pools so every batch has some of each (a stable hash: the order must survive a restart)
        jobs.sort(key=lambda job: hashlib.md5(f"{SEED}-{job[3]['clipFilename']}".encode()).hexdigest())
        log(f"sweep {sweep}: {len(jobs)} clips")
        for batch_number in range(0, len(jobs), BATCH_SIZE):
            batch_name = f"sweep{sweep}-batch{batch_number // BATCH_SIZE:02d}"
            marker = STATE / f"{batch_name}.done"
            if marker.exists():
                continue
            while shutil.disk_usage(str(Path.home())).free / 1e9 < 16:
                log("waiting for disk space"); time.sleep(300)
            run_batch(batch_name, jobs[batch_number : batch_number + BATCH_SIZE])
            marker.touch()
        log(f"sweep {sweep} done")
    (DATA / "logs/fsboard.pid").unlink(missing_ok=True)


if __name__ == "__main__":
    main()
