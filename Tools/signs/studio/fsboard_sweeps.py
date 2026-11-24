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

Never starts by itself: it needs Addy's yes for the sweeps and the download budget it is run with. Limits
(sweep_guard.py): stops cleanly under 60 GB free; batches are cut to at most 12 GB of video (the average size so far,
counted 1.3 times over) and a batch never starts while an earlier batch's videos are on disk; `--max-sweeps` and
`--max-download-gb` are required and the job stops before a batch would pass the budget; the planned download is
printed and written to logs/fsboard-state/plan.json at start; logs/fsboard-state/read.tsv lists every clip already
read, which is never downloaded again.

    nohup /usr/bin/python3 ~/sign-data/tools/fsboard_sweeps.py --max-sweeps 1 --max-download-gb 40 > ~/sign-data/logs/fsboard.log 2>&1 &
    /usr/bin/python3 ~/sign-data/tools/fsboard_sweeps.py --finish-batch all    # no download: closes batches left on disk
Stop: kill the pid in logs/fsboard.pid (the batch being read stays on disk for --finish-batch).
"""
import argparse, csv, hashlib, json, os, random, shutil, subprocess, sys, time, urllib.parse
from collections import defaultdict
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
import sweep_guard  # noqa: E402

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
MOST_CLIPS_PER_BATCH = 500
FIRST_AVERAGE_MB = 8.8  # measured over sweep 1's first 14 batches (61.6 GB, 7,000 clips)
CONNECTIONS = 6  # FSboard's big files take far more than their share per connection: 6 here leave PopSign's 12 about half the line
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


def key_for(study, fsboard_split, record):
    return f"{study}/{fsboard_split}/{record['clipFilename']}"


def average_mb():
    sizes = STATE / "sizes.json"
    if sizes.exists():
        seen = json.loads(sizes.read_text())
        if seen.get("videos"):
            return seen["bytes"] / seen["videos"] / 1e6
    return FIRST_AVERAGE_MB


def note_sizes(downloaded_bytes, videos):
    sizes = STATE / "sizes.json"
    seen = json.loads(sizes.read_text()) if sizes.exists() else {"bytes": 0, "videos": 0}
    seen["bytes"] += downloaded_bytes; seen["videos"] += videos
    sizes.write_text(json.dumps(seen))


def download_batch(batch_name, jobs):
    folder = WORK / batch_name
    by_folder = defaultdict(list)
    for study, fsboard_split, spec_split, record in jobs:
        by_folder[(study, fsboard_split)].append(record["clipFilename"])
    for (study, fsboard_split), names in by_folder.items():
        target = folder / f"{study}-{fsboard_split}"
        target.mkdir(parents=True, exist_ok=True)
        names_file = target / "names.txt"
        names_file.write_text("\n".join(names) + "\n")
        subprocess.run([sys.executable, str(FETCH_MANY), f"{BASE}{study}/video_clips/{study}-{fsboard_split}/", str(target),
                        str(names_file), str(CONNECTIONS)], stdout=subprocess.DEVNULL)
        names_file.unlink(missing_ok=True)
    return folder


def extract_and_record(folder, batch_name, records):
    """Extracts every clip in `folder` (<study>-<split>/<clip>) without landmarks yet, keeps the signed part, writes a
    manifest row for each, adds them to the ledger and deletes the folder. No download. `records`: {(study, split,
    clipFilename): (spec split, metadata record)}."""
    present = []
    for path in sorted(folder.glob("*/*")):
        if path.name == "names.txt" or not path.is_file():
            continue
        study, fsboard_split = path.parent.name.rsplit("-", 1)
        found = records.get((study, fsboard_split, path.name))
        if found:
            present.append((study, fsboard_split, found[0], found[1], path))
    lines = [f"{clip_id_for(study, record)}\t{path}\n" for study, _, _, record, path in present
             if not (OUT / f"{clip_id_for(study, record)}.npy").exists() and not (RAW / f"{clip_id_for(study, record)}.npy").exists()]
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
    extract_rows = {}
    if (RAW / "extract.csv").exists():
        with open(RAW / "extract.csv") as extract_file:
            extract_rows = {row["clip_id"]: row for row in csv.DictReader(extract_file)}
    manifest_path = OUT / "manifest.csv"
    already = set()
    if manifest_path.exists():
        with open(manifest_path) as manifest_file:
            already = {row["clip_id"] for row in csv.DictReader(manifest_file)}
    new_file = not manifest_path.exists()
    written = 0
    with open(manifest_path, "a", newline="") as manifest_file:
        writer = csv.DictWriter(manifest_file, fieldnames=MANIFEST_COLUMNS)
        if new_file:
            writer.writeheader()
        for study, fsboard_split, spec_split, record, _ in present:
            clip_id = clip_id_for(study, record)
            if clip_id in already:
                written += 1
                continue
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
            already.add(clip_id)
            written += 1
    sweep_guard.ReadLedger(STATE / "read.tsv").add_all(key_for(study, fsboard_split, record) for study, fsboard_split, _, record, _ in present)
    shutil.rmtree(folder, ignore_errors=True)
    for path in STATE.glob(f"{batch_name}.slice*.tsv"):
        path.unlink()
    return len(present), written


def load_pools():
    already_read = set()
    if ALREADY_READ.exists():
        already_read = {stem(record) for record in json.loads(ALREADY_READ.read_text())}
    ordered, records = {}, {}
    for pool_name, study, fsboard_split, metadata_name, spec_split, per_sweep in POOLS:
        pool = [record for record in json.loads((METADATA / metadata_name).read_text())
                if not record.get("sensitiveContent") and stem(record) not in already_read]
        ordered[pool_name] = ordered_pool(pool, SEED)
        for record in pool:
            records[(study, fsboard_split, Path(record["clipFilename"]).name)] = (spec_split, record)
        log(f"{pool_name}: {len(pool)} clips usable, {len({record['signerId'] for record in pool})} signers")
    return ordered, records


def finish_batches(name, records):
    """--finish-batch: closes one batch folder (or `all`) from what is on disk, with no download."""
    folders = sorted(path for path in WORK.iterdir() if path.is_dir() and (name == "all" or path.name == name)) if WORK.exists() else []
    for folder in folders:
        clips, written = extract_and_record(folder, folder.name, records)
        log(f"{folder.name}: finished from disk, {clips} clips, {written} with landmarks and a manifest row; videos deleted")


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--max-sweeps", type=int, help="how many sweeps to run (required to download)")
    parser.add_argument("--max-download-gb", type=float, help="stop before a batch would pass this many GB this run (required to download)")
    parser.add_argument("--plan-only", action="store_true", help="print and write the planned download, then stop (no download)")
    parser.add_argument("--finish-batch", help="close a batch left on disk (a folder name in downloads/fsboard-videos, or all) without downloading")
    arguments = parser.parse_args()
    if not arguments.finish_batch and (not arguments.max_sweeps or not arguments.max_download_gb):
        parser.error("--max-sweeps and --max-download-gb are both required (there is no 'all')")
    for folder in (OUT, RAW, WORK, STATE):
        folder.mkdir(parents=True, exist_ok=True)
    ordered, records = load_pools()
    if arguments.finish_batch:
        finish_batches(arguments.finish_batch, records)
        return
    budget = sweep_guard.DownloadBudget(arguments.max_download_gb)
    (DATA / "logs/fsboard.pid").write_text(str(os.getpid()))
    try:
        ledger = sweep_guard.ReadLedger(STATE / "read.tsv")
        # Clips extracted before the ledger existed count as read.
        ledger.add_all(key_for(study, split, record) for (study, split, _), (_, record) in records.items()
                       if (OUT / f"{clip_id_for(study, record)}.npy").exists())
        plan = {}
        for sweep in range(1, arguments.max_sweeps + 1):
            jobs = []
            for pool_name, study, fsboard_split, metadata_name, spec_split, per_sweep in POOLS:
                jobs += [(study, fsboard_split, spec_split, record)
                         for record in ordered[pool_name][(sweep - 1) * per_sweep : sweep * per_sweep]]
            # interleave the pools so every batch has some of each (a stable hash: the order must survive a restart)
            jobs.sort(key=lambda job: hashlib.md5(f"{SEED}-{job[3]['clipFilename']}".encode()).hexdigest())
            plan[sweep] = [job for job in jobs if key_for(job[0], job[1], job[3]) not in ledger]
        each_mb = average_mb()
        planned_gb = sum(len(jobs) for jobs in plan.values()) * each_mb / 1000 * sweep_guard.ESTIMATE_SAFETY
        log(sweep_guard.plan_line("fsboard", arguments.max_sweeps, sum(len(jobs) for jobs in plan.values()), planned_gb,
                                  arguments.max_download_gb, exact=False))
        sweep_guard.write_plan(STATE, "fsboard", {"sweeps": arguments.max_sweeps, "planned_gb": round(planned_gb, 1),
                                                  "budget_gb": arguments.max_download_gb, "average_mb": round(each_mb, 2)})
        if arguments.plan_only:
            log("plan only: nothing downloaded")
            return
        for sweep, jobs in plan.items():
            batches = sweep_guard.cut_into_batches(jobs, [average_mb()] * len(jobs), most_items=MOST_CLIPS_PER_BATCH, exact_sizes=False)
            log(f"sweep {sweep}: {len(jobs)} clips not read yet, {len(batches)} batches")
            for number, batch in enumerate(batches):
                batch_name = f"sweep{sweep}-part{number:03d}"
                batch_gb = len(batch) * average_mb() / 1000 * sweep_guard.ESTIMATE_SAFETY
                sweep_guard.check_free_space(sweep_guard.free_gb(Path.home()))
                sweep_guard.check_no_raw_videos_left(sweep_guard.folder_gb(WORK))
                if not budget.allows(batch_gb):
                    raise sweep_guard.StopJob(f"the next batch (~{batch_gb:.1f} GB) would pass the budget "
                                              f"({budget.used_gb:.1f} of {budget.limit_gb:.0f} GB used); stopping")
                started = time.time()
                folder = download_batch(batch_name, batch)
                downloaded_gb = sweep_guard.folder_gb(folder)
                budget.spend(downloaded_gb)
                note_sizes(downloaded_gb * 1e9, sum(1 for path in folder.glob("*/*") if path.name != "names.txt"))
                downloaded = time.time()
                clips, written = extract_and_record(folder, batch_name, records)
                log(f"{batch_name}: {len(batch)} clips, {clips} downloaded ({downloaded_gb:.2f} GB; {budget.used_gb:.1f} GB this run), "
                    f"{written} written; download {downloaded - started:.0f} s, extract {time.time() - downloaded:.0f} s")
            log(f"sweep {sweep} done")
        log("every sweep asked for is done")
    except sweep_guard.StopJob as stop:
        log(f"stopped: {stop}")
    finally:
        (DATA / "logs/fsboard.pid").unlink(missing_ok=True)


if __name__ == "__main__":
    main()
