#!/bin/zsh
# FSboard clips read with Apple Vision (dataset fsboard-apple): extract the downloaded videos, write manifest rows.
# usage: fsboard_apple.sh <videos folder> <chosen.json (the metadata records)> <split>
set -u
VIDEOS=$1; CHOSEN=$2; SPLIT=$3
OUT=~/sign-data/landmarks/fsboard-apple
STATE=~/sign-data/logs/fsboard-apple-state
mkdir -p $OUT $STATE
/usr/bin/python3 -c "
import json, sys, os
for r in json.load(open('$CHOSEN')):
    stem = os.path.basename(r['clipFilename']).rsplit('.', 1)[0]
    path = os.path.join('$VIDEOS', r['clipFilename'])
    if os.path.exists(path): print(f'fsboard-apple-{stem}\t{path}')
" > $STATE/list.tsv
awk -v prefix="$STATE/slice." '{ print > (prefix (NR % 4)) }' $STATE/list.tsv
for slice in $STATE/slice.[0-3](N); do ~/sign-data/tools/bin/sign-extract videos --list $slice --out $OUT --face --jobs 4 > $slice.log 2>&1 & done
wait
grep -h "^done:" $STATE/slice.*.log
rm -f $STATE/slice.*
/usr/bin/python3 - "$OUT" "$CHOSEN" "$SPLIT" <<'PY'
import csv, json, os, sys
out, chosen, split = sys.argv[1:4]
extract = {r["clip_id"]: r for r in csv.DictReader(open(os.path.join(out, "extract.csv")))}
manifest_path = os.path.join(out, "manifest.csv")
already = {r["clip_id"] for r in csv.DictReader(open(manifest_path))} if os.path.exists(manifest_path) else set()
columns = ["clip_id","dataset","language","label","signer","split","fps","width","height","frames","source"]
new = not os.path.exists(manifest_path); added = 0
with open(manifest_path, "a", newline="") as f:
    w = csv.DictWriter(f, fieldnames=columns)
    if new: w.writeheader()
    for r in json.load(open(chosen)):
        if r.get("sensitiveContent"): continue
        clip_id = "fsboard-apple-" + os.path.basename(r["clipFilename"]).rsplit(".", 1)[0]
        e = extract.get(clip_id)
        if clip_id in already or e is None or not os.path.exists(os.path.join(out, clip_id + ".npy")): continue
        w.writerow({"clip_id": clip_id, "dataset": "fsboard-apple", "language": "asl", "label": r["phrase"].lower(), "signer": r["signerId"],
                    "split": split, "fps": e["fps"], "width": e["width"], "height": e["height"], "frames": e["frames"], "source": "apple"})
        added += 1
print(f"manifest: {added} rows added")
PY
