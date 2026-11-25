#!/bin/zsh
# The two person changes that helped, alone: hand turn and camera height, on the same 4 held-out signers.
H=~/sign-data/experiments/include-signers
echo $$ > ~/sign-data/logs/loso-ablation3.pid
for t in K Q W N; do $H/run_loso.sh loso-$t-turn-perspective $t X --epochs 120 --person-changes hand_turn,perspective > ~/sign-data/logs/loso3-fold-$t.log 2>&1 & done
wait; echo "$(date '+%F %T') done"; rm -f ~/sign-data/logs/loso-ablation3.pid
