#!/bin/zsh
# Round 5 item 2: model A (INCLUDE minus 26 held-out words) and model B (the same + a "not a sign" class), each
# trained, calibrated, then scored on the held-out words.
set -eu
REPO=~/Projects/clicky-wt-signs/Tools/signs
PY=~/sign-data/venv/bin/python
EXP=~/sign-data/experiments
cd $REPO
echo $$ > ~/sign-data/logs/unknown-experiment.pid
run() {
  local name=$1; shift
  if [[ ! -e ~/sign-data/runs/$name/checkpoint-best.pt ]]; then
    $PY -m signs.train_words --data "$@" --language isl --output ~/sign-data/runs/$name --epochs 120 > ~/sign-data/logs/run-$name.log 2>&1
  fi
  $PY -m signs.calibrate --checkpoint ~/sign-data/runs/$name/checkpoint-best.pt --source apple >> ~/sign-data/logs/run-$name.log 2>&1
}
run unknown-a $EXP/include-holdout &
run unknown-b $EXP/include-holdout $EXP/not-a-sign &
wait
$PY -m signs.unknown_signs table --checkpoint ~/sign-data/runs/unknown-a/checkpoint-best.pt --heldout $EXP/include-holdout/heldout.json > $EXP/table-a.json
$PY -m signs.unknown_signs table --checkpoint ~/sign-data/runs/unknown-b/checkpoint-best.pt --heldout $EXP/include-holdout/heldout.json --not-a-sign-label "not a sign" > $EXP/table-b.json
echo "$(date '+%F %T') done"
rm -f ~/sign-data/logs/unknown-experiment.pid
