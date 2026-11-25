#!/bin/bash
# One video per INCLUDE session, a frame from each, then the video is deleted.
cd ~/sign-data/experiments/include-signers/peek
echo $$ > ~/sign-data/logs/include-peek.pid
cut -f3 plan.tsv | sort -u | while read url; do
  awk -F'\t' -v u="$url" '$3==u{print $4}' plan.tsv > want.txt
  python3 ~/sign-data/tools/remote_zip.py "$url" extract want.txt videos > /dev/null 2>&1
  awk -F'\t' -v u="$url" '$3==u{print $1"\t"$4}' plan.tsv | while IFS=$'\t' read n member; do
    [ -f "s$(printf %02d $n).jpg" ] && continue; f="videos/$member"; [ -f "$f" ] || continue
    ffmpeg -nostdin -v error -y -ss 0.4 -i "$f" -frames:v 1 -vf "crop=ih*0.75:ih:iw/2-ih*0.375:0,scale=-2:300" "s$(printf %02d $n).jpg"
    rm -f "$f"
  done
  echo "$(date '+%T') $url done"
done
echo finished; rm -f ~/sign-data/logs/include-peek.pid
