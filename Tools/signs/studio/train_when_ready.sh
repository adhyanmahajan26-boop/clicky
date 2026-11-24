#!/bin/zsh
# Waits for each sweep's end and starts the training run that belongs to it (round 4 C2, C3, C4):
#   PopSign after sweeps 1, 3, 5 -> words-asl-popsign-s<k> (+ sign-eval clips on its test split)
#   FSboard after sweeps 1, 3, 5 -> spell-asl-fsboard-s<k>
# A sweep k is over when the job's log says "sweep <k+1>:" (PopSign) or "sweep <k> done" (FSboard).
set -u
echo $$ > ~/sign-data/logs/train-when-ready.pid
LOGS=~/sign-data/logs
started=()
while true; do
  for k in 1 3 5; do
    name=words-asl-popsign-s$k
    if [[ ${started[(Ie)$name]} -eq 0 ]] && grep -qE "sweep $((k + 1)): |every sign is used up" $LOGS/popsign.log; then
      started+=$name
      echo "$(date '+%F %T') starting $name"
      ( ~/sign-data/tools/run_words.sh $name asl 100 ~/sign-data/landmarks/popsign > $LOGS/run-$name.log 2>&1
        ~/sign-data/tools/bin/sign-eval clips --manifest ~/sign-data/snapshots/$name/popsign/manifest.csv --clips ~/sign-data/snapshots/$name/popsign \
          --models ~/sign-data/runs/$name/export --language asl --split test > $LOGS/sign-eval-$name.log 2>&1 ) &
    fi
    name=spell-asl-fsboard-s$k
    if [[ ${started[(Ie)$name]} -eq 0 ]] && grep -q "sweep $k done" $LOGS/fsboard.log; then
      started+=$name
      echo "$(date '+%F %T') starting $name"
      ~/sign-data/tools/run_spell.sh $name 60 ~/sign-data/landmarks/fsboard > $LOGS/run-$name.log 2>&1 &
    fi
  done
  [[ ${#started} -ge 6 ]] && break
  sleep 120
done
wait
echo "$(date '+%F %T') all six runs started and finished"
rm -f $LOGS/train-when-ready.pid
