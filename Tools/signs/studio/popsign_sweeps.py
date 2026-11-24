#!/usr/bin/env python3
"""PopSign ASL v2.1 (CC BY 4.0) in balanced sweeps, so every sign has data early.

Sweep k takes, for every sign, the next 24 train, 4 val and 8 test videos, going round the participants in turn
(one video of each participant, then the next of each, ...) so signers are spread evenly. Each batch of signs is
downloaded (12 connections, so it keeps its share of the line next to INCLUDE's 32), extracted with sign-extract (padded body pose, --face,
4 processes), checked, and its videos deleted. Manifest rows are appended to <landmarks>/manifest.csv.

Sweep 0 is special: every video of the pilot signs (hello, thankyou), re-extracted with the padded body pose.

Resumable: a finished batch leaves logs/popsign-state/sweep<k>-batch<n>.done; finished clips are skipped.
Runs until every sign is used up or it is stopped (kill the pid in logs/popsign.pid).
    nohup /usr/bin/python3 ~/sign-data/tools/popsign_sweeps.py > ~/sign-data/logs/popsign.log 2>&1 &
"""
import csv, http.client, json, os, re, shutil, subprocess, sys, time, urllib.parse, urllib.request
from collections import defaultdict
from pathlib import Path

DATA = Path.home() / "sign-data"
BASE = "https://signdata.cc.gatech.edu/data/popsign_v2_1/game/"
LISTING = DATA / "logs/popsign-v21-listing.json"
OUT = DATA / "landmarks/popsign"
WORK = DATA / "downloads/popsign"
STATE = DATA / "logs/popsign-state"
# An installed copy, refreshed by hand after a build that passed its checks, so a `swift build` in a worktree
# never hands a running job a half-written binary.
EXTRACTOR = DATA / "tools/bin/sign-extract"
FETCH_MANY = DATA / "tools/fetch_many.py"
PER_SWEEP = {"train": 24, "val": 4, "test": 8}
SIGNS_PER_BATCH = 25
PILOT_SIGNS = ["hello", "thankyou"]
MIN_FREE_GB = 8
MANIFEST_COLUMNS = ["clip_id", "dataset", "language", "label", "signer", "split", "fps", "width", "height", "frames", "source"]


def log(message):
    print(time.strftime("%Y-%m-%d %H:%M:%S"), message, flush=True)


def free_gb():
    return shutil.disk_usage(str(Path.home())).free / 1e9


def list_folder(split, sign):
    for attempt in range(6):
        try:
            request = urllib.request.Request(f"{BASE}{split}/{urllib.parse.quote(sign)}/", headers={"User-Agent": "sign-data-fetch/1.0"})
            try:
                page = urllib.request.urlopen(request, timeout=120).read()
            except http.client.IncompleteRead as cut_short:
                # train/cut and train/frenchfries: the server always ends these pages early; keep what came
                page = cut_short.partial
            return sorted(set(re.findall(r'href="([^"/]+\.mp4)/?"', page.decode("utf-8", "replace"))))
        except Exception as error:
            time.sleep(10 + attempt * 20)
    return None


def load_listing():
    listing = json.loads(LISTING.read_text())
    files = {}
    for key, value in listing.items():
        if value is None:
            split, sign = key.split("/", 1)
            names = list_folder(split, sign)
            log(f"listed {key} again: {'failed' if names is None else len(names)}")
            files[key] = names or []
        else:
            files[key] = sorted(name for name, _ in value)
    return files


def round_robin_order(file_names):
    """One video of each participant, then the next of each, ... (file names start with the participant code)."""
    by_participant = defaultdict(list)
    for name in sorted(file_names):
        by_participant[name.split("-")[0]].append(name)
    ordered, round_number = [], 0
    while True:
        taken = [videos[round_number] for participant, videos in sorted(by_participant.items()) if round_number < len(videos)]
        if not taken:
            return ordered
        ordered += taken
        round_number += 1


def clip_id_for(split, file_name):
    return f"popsign21_{split}_{file_name[:-4]}"


def extract_batch(batch_name, jobs):
    """jobs: [(split, sign, file name)]. Downloads, extracts, appends manifest rows, deletes the videos."""
    todo = [(split, sign, name) for split, sign, name in jobs if not (OUT / f"{clip_id_for(split, name)}.npy").exists()]
    if not todo:
        return 0, 0
    folder = WORK / batch_name
    by_folder = defaultdict(list)
    for split, sign, name in todo:
        by_folder[(split, sign)].append(name)
    started = time.time()
    downloaded_bytes = 0
    for (split, sign), names in by_folder.items():
        target = folder / split / sign
        target.mkdir(parents=True, exist_ok=True)
        names_file = target / "names.txt"
        names_file.write_text("\n".join(names) + "\n")
        subprocess.run([sys.executable, str(FETCH_MANY), f"{BASE}{split}/{urllib.parse.quote(sign)}/", str(target), str(names_file), "12"],
                       stdout=subprocess.DEVNULL)
    lines = []
    for split, sign, name in todo:
        path = folder / split / sign / name
        if path.exists():
            downloaded_bytes += path.stat().st_size
            lines.append(f"{clip_id_for(split, name)}\t{path}\n")
    downloaded = time.time()
    slices = [lines[index::4] for index in range(4)]
    processes = []
    for index, slice_lines in enumerate(slices):
        if not slice_lines:
            continue
        slice_path = STATE / f"{batch_name}.slice{index}.tsv"
        slice_path.write_text("".join(slice_lines))
        processes.append(subprocess.Popen([str(EXTRACTOR), "videos", "--list", str(slice_path), "--out", str(OUT), "--face", "--jobs", "4"],
                                          stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL))
    for process in processes:
        process.wait()
    extracted = time.time()
    append_manifest(todo)
    written = sum(1 for split, sign, name in todo if (OUT / f"{clip_id_for(split, name)}.npy").exists())
    shutil.rmtree(folder, ignore_errors=True)
    for path in STATE.glob(f"{batch_name}.slice*.tsv"):
        path.unlink()
    log(f"{batch_name}: {len(todo)} videos, {len(lines)} downloaded ({downloaded_bytes / 1e9:.2f} GB), {written} with landmarks; "
        f"download {downloaded - started:.0f} s ({downloaded_bytes / 1e6 / max(downloaded - started, 1):.1f} MB/s), extract {extracted - downloaded:.0f} s")
    return len(todo), written


def append_manifest(jobs):
    extract_rows = {}
    extract_path = OUT / "extract.csv"
    if extract_path.exists():
        with open(extract_path) as extract_file:
            extract_rows = {row["clip_id"]: row for row in csv.DictReader(extract_file)}
    manifest_path = OUT / "manifest.csv"
    already = set()
    if manifest_path.exists():
        with open(manifest_path) as manifest_file:
            already = {row["clip_id"] for row in csv.DictReader(manifest_file)}
    new_file = not manifest_path.exists()
    with open(manifest_path, "a", newline="") as manifest_file:
        writer = csv.DictWriter(manifest_file, fieldnames=MANIFEST_COLUMNS)
        if new_file:
            writer.writeheader()
        for split, sign, name in jobs:
            clip_id = clip_id_for(split, name)
            row = extract_rows.get(clip_id)
            if clip_id in already or row is None or not (OUT / f"{clip_id}.npy").exists():
                continue
            writer.writerow({"clip_id": clip_id, "dataset": "popsign", "language": "asl", "label": sign.lower(),
                             "signer": name.split("-")[0], "split": split, "fps": row["fps"], "width": row["width"],
                             "height": row["height"], "frames": row["frames"], "source": "apple"})
            already.add(clip_id)


def main():
    for folder in (OUT, WORK, STATE):
        folder.mkdir(parents=True, exist_ok=True)
    (DATA / "logs/popsign.pid").write_text(str(os.getpid()))
    files = load_listing()
    signs = sorted({key.split("/", 1)[1] for key in files})
    order = {key: round_robin_order(names) for key, names in files.items()}
    log(f"{len(signs)} signs, {sum(len(names) for names in files.values())} videos listed")

    batches = [("sweep0-pilot", [(split, sign, name) for sign in PILOT_SIGNS for split in PER_SWEEP for name in order.get(f"{split}/{sign}", [])])]
    sweep = 1
    while True:
        if batches:
            batch_name, jobs = batches.pop(0)
            marker = STATE / f"{batch_name}.done"
            if not marker.exists():
                while free_gb() < MIN_FREE_GB + 8:
                    log(f"waiting: {free_gb():.1f} GB free"); time.sleep(300)
                extract_batch(batch_name, jobs)
                marker.touch()
            continue
        sweep_jobs = []
        for sign in signs:
            for split, count in PER_SWEEP.items():
                names = order.get(f"{split}/{sign}", [])
                sweep_jobs += [(split, sign, name) for name in names[(sweep - 1) * count : sweep * count]]
        if not sweep_jobs:
            log("every sign is used up"); break
        log(f"sweep {sweep}: {len(sweep_jobs)} videos")
        for batch_number in range(0, len(signs), SIGNS_PER_BATCH):
            batch_signs = set(signs[batch_number : batch_number + SIGNS_PER_BATCH])
            batches.append((f"sweep{sweep}-batch{batch_number // SIGNS_PER_BATCH:02d}", [job for job in sweep_jobs if job[1] in batch_signs]))
        sweep += 1
    (DATA / "logs/popsign.pid").unlink(missing_ok=True)


if __name__ == "__main__":
    main()
