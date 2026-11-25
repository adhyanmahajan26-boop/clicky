#!/bin/zsh
# Stretch-ending settings on VALIDATION signers: FSboard spelling, PopSign words, ISL built streams.
E=~/Projects/clicky-wt-signs/Packages/ClickyCore/.build/release/sign-eval; M=~/Projects/clicky-wt-signs/Resources/SignModels
P=~/sign-data/snapshots/words-asl-popsign-s1/asl-s1-popsign; F=~/sign-data/snapshots/spell-asl-fsboard-s1/fsboard; I=~/sign-data/landmarks/include
split=${1:-val}
for still in 1.0 1.5 2.0; do for gap in 0.4 0.8; do
  args=(--stretch stillSeconds=$still --stretch endGapSeconds=$gap)
  p=$($E clips --manifest $P/manifest.csv --clips $P --models $M --language asl --split $split $args 2>&1 | awk '/read as a word|right when read|more than one/{print $NF}' | tr '\n' ' ')
  $E clips --manifest $F/manifest.csv --clips $F --models $M --language asl --split $split $args --reads /tmp/sg_f.tsv > /dev/null 2>&1
  f=$(~/sign-data/venv/bin/python - <<'PY'
import csv
from pathlib import Path
F = Path.home() / "sign-data/snapshots/spell-asl-fsboard-s1/fsboard"
truth = {r["clip_id"]: r["label"] for r in csv.DictReader(open(F / "manifest.csv"))}
def edits(a, b):
    prev = list(range(len(b) + 1))
    for i, x in enumerate(a, 1):
        cur = [i] + [0] * len(b)
        for j, y in enumerate(b, 1): cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (x != y))
        prev = cur
    return prev[-1]
e = c = ex = n = 0
for line in open("/tmp/sg_f.tsv"):
    clip, _, read = line.rstrip("\n").partition("\t"); t = truth[clip].lower().replace(" ", ""); g = read.replace("?", "").lower().replace(" ", "")
    e += edits(g, t); c += len(t); ex += g == t; n += 1
print(f"{100*e/c:.1f} {100*ex/n:.1f}")
PY
)
  s=$($E stream --manifest $I/manifest.csv --clips $I --models $M --language isl --split $split $args 2>&1 | awk '/word error rate/{print $NF}')
  print "still $still gap $gap | PopSign answered/right/>1: $p | FSboard CER/exact: $f | ISL streams WER: $s"
done; done
