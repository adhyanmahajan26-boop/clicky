#!/bin/bash
# The small (240x320) videos of the paired sentences upscaled 4x (lanczos) before Vision, into landmarks/isl-csltr-upscaled.
DOWN=~/sign-data/downloads/isl-csltr; WORK=~/sign-data/downloads/isl-csltr-upscaled; OUT=~/sign-data/landmarks/isl-csltr-upscaled
mkdir -p $WORK $OUT; : > $WORK/list.tsv
python3 -c "
import csv, json
pairs = json.load(open('$DOWN/pairs.json')); videos = {r['clip_id']: r['zip_path'] for r in csv.DictReader(open('$DOWN/videos.csv'))}
for p in pairs.values(): print(p['small'] + '\t' + videos[p['small']])" | while IFS=$'\t' read id zp; do
  src="$DOWN/members/$zp"; [ -f "$src" ] || continue; [ -f "$OUT/$id.npy" ] && continue
  ffmpeg -v error -y -i "$src" -vf "scale=iw*4:ih*4:flags=lanczos" -c:v libx264 -crf 12 -preset fast -an "$WORK/$id.mp4" && printf "%s\t%s\n" "$id" "$WORK/$id.mp4" >> $WORK/list.tsv
done
[ -s $WORK/list.tsv ] && ~/sign-data/tools/bin/sign-extract videos --list $WORK/list.tsv --out $OUT --jobs 4 > /dev/null 2>&1
echo "upscaled $(wc -l < $WORK/list.tsv); $(ls $OUT/*.npy 2>/dev/null | wc -l) total"
