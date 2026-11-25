import csv, collections
from pathlib import Path
X = Path.home() / "sign-data/experiments"; F = Path.home() / "sign-data/snapshots/spell-asl-fsboard-s1/fsboard"
truth = {r["clip_id"]: r for r in csv.DictReader(open(F / "manifest.csv"))}
def edits(a, b):
    prev = list(range(len(b) + 1))
    for i, x in enumerate(a, 1):
        cur = [i] + [0] * len(b)
        for j, y in enumerate(b, 1): cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (x != y))
        prev = cur
    return prev[-1]
norm = lambda t: t.replace("?", "").lower().replace(" ", "")
def cer(reads):
    e = c = ex = 0
    for clip, read in reads.items():
        t = norm(truth[clip]["label"]); g = norm(read); e += edits(g, t); c += len(t); ex += g == t
    return 100 * e / c, 100 * ex / len(reads)
def load(name): return {l.split("\t")[0]: (l.rstrip("\n").split("\t") + [""])[1] for l in open(X / name) if l.strip()}
print("app path      CER %.1f  exact %.1f" % cer(load("fs-val-reads.tsv")))
print("whole clip    CER %.1f  exact %.1f" % cer(load("fs-val-whole.tsv")))
rows = list(csv.DictReader(open(X / "fs-val-stretches.tsv"), delimiter="\t"))
by = collections.defaultdict(list)
for r in rows: by[r["clip_id"]].append(r)
oracle = {c: "".join(s["spelling"] for s in by.get(c, [])) for c in load("fs-val-reads.tsv")}
print("join every stretch's spelling guess (oracle for cuts + the rule)  CER %.1f exact %.1f" % cer(oracle))
counts = collections.Counter(len(v) for v in by.values()); print("stretches per phrase:", sorted(counts.items()))
kinds = collections.Counter(r["kind"] for r in rows); print("stretch kinds:", dict(kinds))
gaps = [float(b["start"]) - float(a["end"]) for v in by.values() for a, b in zip(v, v[1:])]
gaps.sort(); print("gaps between stretches (s): n", len(gaps), "median %.2f" % gaps[len(gaps)//2] if gaps else "", "p90 %.2f" % gaps[int(len(gaps)*0.9)] if gaps else "")
durs = sorted(float(r["end"]) - float(r["start"]) for r in rows); print("stretch seconds: median %.2f, under 1.0 s: %d of %d" % (durs[len(durs)//2], sum(d < 1.0 for d in durs), len(durs)))
long_ = [c for c in by if float(truth[c]["frames"]) / max(float(truth[c]["fps"]), 1) * 30 > 256]; print("phrases longer than 256 frames at 30/s:", len(long_), "of", len(by))
# error by kind of failure
single = {c: load("fs-val-reads.tsv")[c] for c, v in by.items() if len(v) == 1}
multi = {c: load("fs-val-reads.tsv")[c] for c, v in by.items() if len(v) > 1}
print("one stretch:  n %d CER %.1f exact %.1f" % ((len(single),) + cer(single)))
print("cut in two+:  n %d CER %.1f exact %.1f" % ((len(multi),) + cer(multi)))
unclear1 = {c: r for c, r in single.items() if by[c][0]["kind"] != "spelled"}
print("one stretch but not read as spelling:", len(unclear1), "; of those kinds", collections.Counter(by[c][0]["kind"] for c in unclear1))
