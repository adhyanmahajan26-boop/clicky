#!/bin/zsh
# Current model vs hand_turn+perspective, seeds 1 and 2 (seed 0 = the earlier runs), on the 4 held-out signers.
# Two at a time, niced, so round 1's extraction keeps the machine first.
H=~/sign-data/experiments/include-signers
echo $$ > ~/sign-data/logs/loso-seeds.pid
jobs_list=()
for seed in 1 2; do for t in K Q W N; do
  jobs_list+="$t base-s$seed --seed $seed"
  jobs_list+="$t turn-perspective-s$seed --seed $seed --person-changes hand_turn,perspective"
done; done
run_one() { local t=$1 v=$2; shift 2; nice -n 10 $H/run_loso.sh loso-$t-$v $t X --epochs 120 "$@" > ~/sign-data/logs/loso-seeds-$t-$v.log 2>&1 }
i=0
for spec in $jobs_list; do
  run_one ${=spec} &
  i=$((i+1)); if (( i % 2 == 0 )); then wait; fi
done
wait; echo "$(date '+%F %T') seeds done"; rm -f ~/sign-data/logs/loso-seeds.pid
