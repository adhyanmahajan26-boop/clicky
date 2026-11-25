#!/bin/zsh
# One leave-one-signer-out word run on INCLUDE: build the split folder, pack it, train, evaluate on the held-out signer.
# usage: run_loso.sh <run name> <test signer> <validation signer> [train_words options...]
set -eu
NAME=$1; TEST=$2; VAL=$3; shift 3
H=~/sign-data/experiments/include-signers
REPO=~/Projects/clicky-wt-signs/Tools/signs
PY=~/sign-data/venv/bin/python
DATA=~/sign-data/experiments/loso-data/$TEST-$VAL
RUN=~/sign-data/experiments/loso-runs/$NAME
echo $$ > ~/sign-data/logs/loso-$NAME.pid
mkdir -p ${DATA:h} ${RUN:h}
[[ -e $DATA/manifest.csv ]] || { /usr/bin/python3 $H/make_split.py $TEST $VAL $DATA; cd $REPO; $PY -m signs.landmarks pack $DATA; }
cd $REPO
echo "$(date '+%F %T') training $NAME"
$PY -m signs.train_words --data $DATA --language isl --output $RUN "$@"
$PY -m signs.evaluate --checkpoint $RUN/checkpoint-best.pt --split test > $RUN/test.json
/usr/bin/python3 -c "import json; d=json.load(open('$RUN/test.json')); print('$NAME', {k: v for k, v in d.items() if not isinstance(v, (list, dict))})"
rm -f ~/sign-data/logs/loso-$NAME.pid
