#!/usr/bin/env python3
"""PopSign ASL v2.1 (CC BY 4.0) in balanced sweeps, so every sign has data early. Never starts by itself: it needs
Addy's yes for the sweeps and the download budget it is run with.

Sweep k takes, for every sign, the next 24 train, 4 val and 8 test videos, going round the participants in turn (one
video of each participant, then the next of each, ...) so signers are spread evenly. A sweep is cut into batches of at
most 12 GB of video (sizes from the listing, counted 1.3 times over since they are rounded). Each batch is downloaded
(12 connections), extracted with sign-extract (padded body pose, --face, 4 processes), checked, written to
<landmarks>/manifest.csv, and its videos deleted.

Limits (sweep_guard.py): stops cleanly under 60 GB free; a batch never starts while an earlier batch's videos are on
disk; `--max-sweeps` and `--max-download-gb` are required and the job stops before a batch would pass the budget; the
planned download is printed and written to logs/popsign-state/plan.json at start; logs/popsign-state/read.tsv lists
every video already read, which is never downloaded again.

    nohup /usr/bin/python3 ~/sign-data/tools/popsign_sweeps.py --max-sweeps 1 --max-download-gb 40 > ~/sign-data/logs/popsign.log 2>&1 &
    /usr/bin/python3 ~/sign-data/tools/popsign_sweeps.py --finish-batch all    # no download: closes batches left on disk
Stop: kill the pid in logs/popsign.pid (the batch being read stays on disk for --finish-batch).
"""
import argparse, csv, json, os, re, shutil, subprocess, sys, time, urllib.parse
from collections import defaultdict
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import sweep_guard  # noqa: E402

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
MANIFEST_COLUMNS = ["clip_id", "dataset", "language", "label", "signer", "split", "fps", "width", "height", "frames", "source"]
SPLITS = ("train", "val", "test")


def log(message):
    print(time.strftime("%Y-%m-%d %H:%M:%S"), message, flush=True)


def load_listing():
    """{"split/sign": [(file name, size in GB from the listing, rounded)]}. The listing is read once, from disk."""
    listing = json.loads(LISTING.read_text())
    return {key: sorted((name, float(size)) for name, size in (value or [])) for key, value in listing.items()}


def round_robin_order(files):
    """One video of each participant, then the next of each, ... (file names start with the participant code)."""
    by_participant = defaultdict(list)
    for name, size in sorted(files):
        by_participant[name.split("-")[0]].append((name, size))
    ordered, round_number = [], 0
    while True:
        taken = [videos[round_number] for participant, videos in sorted(by_participant.items()) if round_number < len(videos)]
        if not taken:
            return ordered
        ordered += taken
        round_number += 1


def clip_id_for(split, file_name):
    return f"popsign21_{split}_{file_name[:-4]}"


def key_for(split, sign, name):
    return f"{split}/{sign}/{name}"


def sweep_jobs(order, signs, sweep):
    """[(split, sign, name, size GB)] for one sweep, sign by sign."""
    jobs = []
    for sign in signs:
        for split, count in PER_SWEEP.items():
            jobs += [(split, sign, name, size) for name, size in order.get(f"{split}/{sign}", [])[(sweep - 1) * count : sweep * count]]
    return jobs


def existing_ledger():
    """The ledger, with every clip already extracted (an .npy in the landmarks folder) added, so a ledger made after
    earlier runs still covers them."""
    ledger = sweep_guard.ReadLedger(STATE / "read.tsv")
    extracted = []
    if OUT.exists():
        pattern = re.compile(r"^popsign21_(train|val|test)_(.+)$")
        for path in OUT.glob("popsign21_*.npy"):
            match = pattern.match(path.stem)
            if match:
                extracted.append((match.group(1), match.group(2)))
    # The sign is in the file name ("<participant>-<sign>-<time>-<n>"), but signs can hold "-", so the listing decides.
    return ledger, extracted


def extract_and_record(batch_folder, batch_name):
    """Extracts every video in `batch_folder` (<split>/<sign>/<name>) that has no landmarks yet, appends manifest rows
    for every video there, checks each clip, adds them to the ledger and deletes the folder. No download."""
    present = sorted((path.parent.parent.name, path.parent.name, path.name) for path in batch_folder.glob("*/*/*.mp4"))
    if not present:
        shutil.rmtree(batch_folder, ignore_errors=True)
        return 0, 0
    lines = [f"{clip_id_for(split, name)}\t{batch_folder / split / sign / name}\n" for split, sign, name in present
             if not (OUT / f"{clip_id_for(split, name)}.npy").exists()]
    processes = []
    for index in range(4):
        slice_lines = lines[index::4]
        if not slice_lines:
            continue
        slice_path = STATE / f"{batch_name}.slice{index}.tsv"
        slice_path.write_text("".join(slice_lines))
        processes.append(subprocess.Popen([str(EXTRACTOR), "videos", "--list", str(slice_path), "--out", str(OUT), "--face", "--jobs", "4"],
                                          stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL))
    for process in processes:
        process.wait()
    written = append_manifest(present)
    ledger = sweep_guard.ReadLedger(STATE / "read.tsv")
    ledger.add_all(key_for(split, sign, name) for split, sign, name in present)
    shutil.rmtree(batch_folder, ignore_errors=True)
    for path in STATE.glob(f"{batch_name}.slice*.tsv"):
        path.unlink()
    return len(present), written


def append_manifest(videos):
    """Manifest rows for [(split, sign, name)] whose clip was extracted and loads with frames; returns how many have a row."""
    import numpy as np
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
    with_rows = 0
    with open(manifest_path, "a", newline="") as manifest_file:
        writer = csv.DictWriter(manifest_file, fieldnames=MANIFEST_COLUMNS)
        if new_file:
            writer.writeheader()
        for split, sign, name in videos:
            clip_id = clip_id_for(split, name)
            if clip_id in already:
                with_rows += 1
                continue
            row = extract_rows.get(clip_id)
            clip_path = OUT / f"{clip_id}.npy"
            if row is None or not clip_path.exists():
                continue
            try:
                frames = np.load(clip_path).shape[0]
            except Exception:
                continue
            if frames == 0:
                continue
            writer.writerow({"clip_id": clip_id, "dataset": "popsign", "language": "asl", "label": sign.lower(),
                             "signer": name.split("-")[0], "split": split, "fps": row["fps"], "width": row["width"],
                             "height": row["height"], "frames": row["frames"], "source": "apple"})
            already.add(clip_id)
            with_rows += 1
    return with_rows


def download_batch(batch_name, jobs):
    folder = WORK / batch_name
    folder.mkdir(parents=True, exist_ok=True)
    names_file = folder / "names.txt"
    names_file.write_text("".join(f"{split}/{sign}/{name}\n" for split, sign, name, _ in jobs))
    subprocess.run([sys.executable, str(FETCH_MANY), BASE, str(folder), str(names_file), "12"], stdout=subprocess.DEVNULL)
    names_file.unlink(missing_ok=True)
    return folder


def finish_batches(name):
    """--finish-batch: closes one batch folder (or `all`) from what is on disk, with no download."""
    STATE.mkdir(parents=True, exist_ok=True)
    folders = sorted(path for path in WORK.iterdir() if path.is_dir() and (name == "all" or path.name == name)) if WORK.exists() else []
    for folder in folders:
        if not any(folder.glob("*/*/*.mp4")):
            continue
        videos, written = extract_and_record(folder, folder.name)
        log(f"{folder.name}: finished from disk, {videos} videos, {written} with landmarks and a manifest row; videos deleted")


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--max-sweeps", type=int, help="how many sweeps to run (required to download)")
    parser.add_argument("--max-download-gb", type=float, help="stop before a batch would pass this many GB this run (required to download)")
    parser.add_argument("--plan-only", action="store_true", help="print and write the planned download, then stop (no download)")
    parser.add_argument("--finish-batch", help="close a batch left on disk (a folder name in downloads/popsign, or all) without downloading")
    arguments = parser.parse_args()
    if not arguments.finish_batch and (not arguments.max_sweeps or not arguments.max_download_gb):
        parser.error("--max-sweeps and --max-download-gb are both required (there is no 'all')")
    for folder in (OUT, WORK, STATE):
        folder.mkdir(parents=True, exist_ok=True)
    if arguments.finish_batch:
        finish_batches(arguments.finish_batch)
        return
    budget = sweep_guard.DownloadBudget(arguments.max_download_gb)
    (DATA / "logs/popsign.pid").write_text(str(os.getpid()))
    try:
        files = load_listing()
        signs = sorted({key.split("/", 1)[1] for key in files})
        order = {key: round_robin_order(names) for key, names in files.items()}
        ledger, extracted = existing_ledger()
        sign_of = {(split, name): sign for key, names in files.items() for name, _ in names for split, sign in [key.split("/", 1)]}
        ledger.add_all(key_for(split, sign_of[(split, name + ".mp4")], name + ".mp4") for split, name in extracted if (split, name + ".mp4") in sign_of)
        plan = {sweep: [job for job in sweep_jobs(order, signs, sweep) if key_for(*job[:3]) not in ledger] for sweep in range(1, arguments.max_sweeps + 1)}
        planned_gb = sum(size for jobs in plan.values() for *_, size in jobs) * sweep_guard.ESTIMATE_SAFETY
        log(sweep_guard.plan_line("popsign", arguments.max_sweeps, sum(len(jobs) for jobs in plan.values()), planned_gb, arguments.max_download_gb, exact=False))
        sweep_guard.write_plan(STATE, "popsign", {"sweeps": arguments.max_sweeps, "planned_gb": round(planned_gb, 1),
                                                  "budget_gb": arguments.max_download_gb, "signs": len(signs)})
        if arguments.plan_only:
            log("plan only: nothing downloaded")
            return
        for sweep, jobs in plan.items():
            batches = sweep_guard.cut_into_batches(jobs, [size * 1000 for *_, size in jobs], exact_sizes=False)
            log(f"sweep {sweep}: {len(jobs)} videos not read yet, {len(batches)} batches")
            for number, batch in enumerate(batches):
                batch_name = f"sweep{sweep}-part{number:03d}"
                batch_gb = sum(size for *_, size in batch) * sweep_guard.ESTIMATE_SAFETY
                sweep_guard.check_free_space(sweep_guard.free_gb(Path.home()))
                sweep_guard.check_no_raw_videos_left(sweep_guard.folder_gb(WORK))
                if not budget.allows(batch_gb):
                    raise sweep_guard.StopJob(f"the next batch (~{batch_gb:.1f} GB) would pass the budget "
                                              f"({budget.used_gb:.1f} of {budget.limit_gb:.0f} GB used); stopping")
                started = time.time()
                folder = download_batch(batch_name, batch)
                downloaded_gb = sweep_guard.folder_gb(folder)
                budget.spend(downloaded_gb)
                downloaded = time.time()
                videos, written = extract_and_record(folder, batch_name)
                log(f"{batch_name}: {len(batch)} videos, {videos} downloaded ({downloaded_gb:.2f} GB; {budget.used_gb:.1f} GB this run), "
                    f"{written} with landmarks; download {downloaded - started:.0f} s, extract {time.time() - downloaded:.0f} s")
            log(f"sweep {sweep} done")
        log("every sweep asked for is done")
    except sweep_guard.StopJob as stop:
        log(f"stopped: {stop}")
    finally:
        (DATA / "logs/popsign.pid").unlink(missing_ok=True)


if __name__ == "__main__":
    main()
