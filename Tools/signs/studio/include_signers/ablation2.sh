#!/bin/zsh
# Which person change helps: all four minus one, on the same 4 held-out signers.
H=~/sign-data/experiments/include-signers
echo $$ > ~/sign-data/logs/loso-ablation2.pid
fold() {
  local test=$1
  $H/run_loso.sh loso-$test-aug-nobones $test X --epochs 120 --person-changes hand_turn,perspective,time_warp
  $H/run_loso.sh loso-$test-aug-noturn $test X --epochs 120 --person-changes bones,perspective,time_warp
  $H/run_loso.sh loso-$test-aug-noperspective $test X --epochs 120 --person-changes bones,hand_turn,time_warp
  $H/run_loso.sh loso-$test-aug-nowarp $test X --epochs 120 --person-changes bones,hand_turn,perspective
}
for t in K Q W N; do fold $t > ~/sign-data/logs/loso2-fold-$t.log 2>&1 & done
wait
echo "$(date '+%F %T') all folds done"; rm -f ~/sign-data/logs/loso-ablation2.pid
