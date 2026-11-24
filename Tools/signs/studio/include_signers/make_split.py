"""A leave-one-signer-out copy of INCLUDE: clips symlinked, manifest with `signer` filled from sessions → signers
(signers.json: {session number: signer name}) and the split written out: the held-out signer is test, one other
signer is validation, the rest train. Clips of sessions with no signer (tiny or unnamed) are left out.
usage: make_split.py <test signer> <validation signer> <out folder>"""
import csv, json, sys, os
from pathlib import Path
HERE = Path(__file__).parent
test_signer, validation_signer, out = sys.argv[1], sys.argv[2], Path(sys.argv[3])
sessions = json.load(open(HERE / "sessions.json"))
signers = json.load(open(HERE / "signers.json"))
signer_of = {clip: signers[str(n)] for n, s in enumerate(sessions) if str(n) in signers for clip in s["clips"]}
source = Path.home() / "sign-data/landmarks/include"
out.mkdir(parents=True, exist_ok=True)
counts = {"train": 0, "val": 0, "test": 0}
with open(source / "manifest.csv") as manifest_in, open(out / "manifest.csv", "w", newline="") as manifest_out:
    reader = csv.DictReader(manifest_in); writer = csv.DictWriter(manifest_out, fieldnames=reader.fieldnames); writer.writeheader()
    for row in reader:
        signer = signer_of.get(row["clip_id"])
        if signer is None: continue
        row["signer"] = signer
        row["split"] = "test" if signer == test_signer else "val" if signer == validation_signer else "train"
        counts[row["split"]] += 1
        link = out / f"{row['clip_id']}.npy"
        if not link.exists(): os.symlink(source / f"{row['clip_id']}.npy", link)
        writer.writerow(row)
print(out.name, counts)
