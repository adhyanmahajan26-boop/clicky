#!/bin/zsh
# Leave-one-signer-out ablation: 4 held-out signers (folds run side by side), 4 variants each, one after another.
H=~/sign-data/experiments/include-signers
echo $$ > ~/sign-data/logs/loso-ablation.pid
fold() {
  local test=$1 val=X
  $H/run_loso.sh loso-$test-base $test $val --epochs 120
  $H/run_loso.sh loso-$test-aug $test $val --epochs 120 --person-changes bones,hand_turn,perspective,time_warp
  $H/run_loso.sh loso-$test-small $test $val --epochs 120 --width 128 --dropout-rate 0.3 --drop-path-rate 0.2
  $H/run_loso.sh loso-$test-small-aug $test $val --epochs 120 --width 128 --dropout-rate 0.3 --drop-path-rate 0.2 --person-changes bones,hand_turn,perspective,time_warp
}
for t in K Q W N; do fold $t > ~/sign-data/logs/loso-fold-$t.log 2>&1 & done
wait
echo "$(date '+%F %T') all folds done"
rm -f ~/sign-data/logs/loso-ablation.pid
