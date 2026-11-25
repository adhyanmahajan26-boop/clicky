#!/bin/zsh
# One word-model run, start to finish: snapshot + pack the data, train, calibrate on validation (temperature), take
# the "not sure" threshold from held-out words (three folds), evaluate once on test, export to Core ML with the
# calibration, check Core ML against PyTorch.
# usage: [PERSON_CHANGES=hand_turn,perspective] run_words.sh <run name> <asl|isl> <epochs> <dataset folder> [<dataset folder> ...]
# PERSON_CHANGES goes to train_words --person-changes, and to the threshold folds so they train the same way.
# Detached: nohup ~/sign-data/tools/run_words.sh words-isl-include isl 120 ~/sign-data/landmarks/include > ~/sign-data/logs/run-words-isl-include.log 2>&1 &
set -eu
NAME=$1; LANGUAGE=$2; EPOCHS=$3; shift 3
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
  $PY -m signs.train_words --data ignored --output $RUN --resume $RUN --epochs $EPOCHS
else
  $PY -m signs.train_words --data $data_folders --language $LANGUAGE --output $RUN --epochs $EPOCHS ${PERSON_CHANGES:+--person-changes $PERSON_CHANGES}
fi
echo "$(date '+%F %T') calibrating"
$PY -m signs.calibrate --checkpoint $RUN/checkpoint-best.pt --source apple
# The "not sure" threshold comes from held-out words (signs.unknown_signs folds, README): three models with a
# tenth of the words held out each, then the full model's calibration file gets that threshold.
echo "$(date '+%F %T') threshold from held-out words"
$PY -m signs.unknown_signs folds --data ${data_folders[1]} --language $LANGUAGE --output $RUN-folds --epochs $EPOCHS ${PERSON_CHANGES:+--person-changes $PERSON_CHANGES}
$PY -m signs.unknown_signs apply --checkpoint $RUN/checkpoint-best.pt --folds $RUN-folds/folds.json
echo "$(date '+%F %T') evaluating on test"
$PY -m signs.evaluate --checkpoint $RUN/checkpoint-best.pt --split test > $RUN/test.json
/usr/bin/python3 -c "import json; d=json.load(open('$RUN/test.json')); print({k: v for k, v in d.items() if not isinstance(v, (list, dict))})"
mkdir -p $RUN/export
$PY -m signs.export_coreml --checkpoint $RUN/checkpoint-best.pt --output $RUN/export/SignWords${(U)LANGUAGE}.mlpackage 2>&1 | grep -v -i warn
PYTHONPATH=$REPO $PY ~/sign-data/tools/coreml_check.py $RUN/checkpoint-best.pt $RUN/export/SignWords${(U)LANGUAGE}.mlpackage 40 2>&1 | grep -v -i warn | tail -1
echo "$(date '+%F %T') done"
rm -f ~/sign-data/logs/run-$NAME.pid
