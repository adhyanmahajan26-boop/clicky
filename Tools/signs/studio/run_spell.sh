#!/bin/zsh
# One finger-spelling run: snapshot + pack, train_spell, then character error rate on validation and on test.
# usage: run_spell.sh <run name> <epochs> <dataset folder> [...]
set -eu
NAME=$1; EPOCHS=$2; shift 2
REPO=~/Projects/clicky-wt-signs/Tools/signs
PY=~/sign-data/venv/bin/python
RUN=~/sign-data/runs/$NAME
SNAPSHOTS=~/sign-data/snapshots/$NAME
echo $$ > ~/sign-data/logs/run-$NAME.pid
cd $REPO
data_folders=()
for folder in "$@"; do
  snapshot=$SNAPSHOTS/$(basename $folder)
  /usr/bin/python3 ~/sign-data/tools/snapshot.py $folder $snapshot
  $PY -m signs.landmarks pack $snapshot
  data_folders+=$snapshot
done
echo "$(date '+%F %T') training"
if [[ -e $RUN/checkpoint-last.pt ]]; then
  $PY -m signs.train_spell --data ignored --output $RUN --resume $RUN --epochs $EPOCHS
else
  $PY -m signs.train_spell --data $data_folders --language asl --output $RUN --epochs $EPOCHS
fi
for split in val test; do
  echo "$(date '+%F %T') evaluating on $split"
  $PY -m signs.evaluate --checkpoint $RUN/checkpoint-best.pt --split $split > $RUN/$split.json
  /usr/bin/python3 -c "import json; d=json.load(open('$RUN/$split.json')); print({k: v for k, v in d.items() if not isinstance(v, (list, dict))})"
done
echo "$(date '+%F %T') done"
rm -f ~/sign-data/logs/run-$NAME.pid
