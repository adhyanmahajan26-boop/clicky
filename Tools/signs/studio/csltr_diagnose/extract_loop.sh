#!/bin/bash
# Extracts CSLTR named videos as they finish downloading; stops when the downloads are done and nothing is left.
HERE=~/sign-data/experiments/csltr-diagnose
OUT=~/sign-data/landmarks/isl-csltr-named
echo $$ > ~/sign-data/logs/csltr-extract.pid
while true; do
  python3 $HERE/prepare.py
  if [ -s $HERE/list.tsv ]; then
    ~/sign-data/tools/bin/sign-extract videos --list $HERE/list.tsv --out $OUT --jobs 4 > /dev/null 2>&1
    echo "$(date '+%F %T') extracted $(wc -l < $HERE/list.tsv) ($(ls $OUT/*.npy | wc -l) total)"
  fi
  if ! pgrep -f "remote_zip.py.*extract" > /dev/null; then
    python3 $HERE/prepare.py
    [ -s $HERE/list.tsv ] || break
  fi
  sleep 60
done
echo "$(date '+%F %T') done"
rm -f ~/sign-data/logs/csltr-extract.pid
