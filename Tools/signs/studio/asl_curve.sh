#!/bin/zsh
# ASL learning curve: the word model on 25%, 50% and 100% of sweep 1's training clips per sign (6, 12, 24), the same
# validation and test signers, 60 epochs each, one seed. Training only.
echo $$ > ~/sign-data/logs/asl-curve.pid
REPO=~/Projects/clicky-wt-signs/Tools/signs; PY=~/sign-data/venv/bin/python
/usr/bin/python3 - <<'PYEOF'
import csv, os, collections
from pathlib import Path
src = Path.home() / "sign-data/experiments/asl-s1-popsign"
rows = list(csv.DictReader(open(src / "manifest.csv")))
for share, per_sign in (("25", 6), ("50", 12), ("100", 24)):
    out = Path.home() / f"sign-data/experiments/asl-curve-{share}"; out.mkdir(parents=True, exist_ok=True)
    kept = [r for r in rows if r["split"] != "train"]
    by_sign = collections.defaultdict(lambda: collections.defaultdict(list))
    for r in sorted((r for r in rows if r["split"] == "train"), key=lambda r: r["clip_id"]):
        by_sign[r["label"]][r["signer"]].append(r)
    for sign, by_signer in by_sign.items():
        chosen, n = [], 0
        while len(chosen) < per_sign and any(n < len(v) for v in by_signer.values()):
            chosen += [v[n] for s, v in sorted(by_signer.items()) if n < len(v)]; n += 1
        kept += chosen[:per_sign]
    with open(out / "manifest.csv", "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=list(rows[0].keys())); w.writeheader()
        for r in kept:
            link = out / f"{r['clip_id']}.npy"
            if not link.exists(): os.symlink(os.path.realpath(src / f"{r['clip_id']}.npy"), link)
            w.writerow(r)
    print(share, sum(1 for r in kept if r["split"] == "train"), "training clips")
PYEOF
cd $REPO
for share in 25 50 100; do
  ( $PY -m signs.landmarks pack ~/sign-data/experiments/asl-curve-$share > /dev/null
    $PY -m signs.train_words --data ~/sign-data/experiments/asl-curve-$share --language asl --output ~/sign-data/experiments/asl-curve-runs/$share --epochs 60
    $PY -m signs.evaluate --checkpoint ~/sign-data/experiments/asl-curve-runs/$share/checkpoint-best.pt --split test > ~/sign-data/experiments/asl-curve-runs/$share-test.json
  ) > ~/sign-data/logs/asl-curve-$share.log 2>&1 &
done
wait; echo "$(date '+%F %T') curve done"; rm -f ~/sign-data/logs/asl-curve.pid
