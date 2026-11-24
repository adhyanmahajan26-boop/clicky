#!/bin/zsh
# INCLUDE (Zenodo 4010759): one zip at a time -> download, unpack, Vision landmarks (4 processes), manifest rows,
# delete the videos, next zip. Resumable: a zip with a .done marker is skipped; sign-extract skips finished clips.
# Run detached:  nohup ~/sign-data/tools/include_run.sh > ~/sign-data/logs/include.log 2>&1 &
set -u
DATA=~/sign-data
TOOLS=$DATA/tools
WORK=$DATA/downloads/include
OUT=$DATA/landmarks/include
LISTS=$DATA/downloads/include-lists
STATE=$DATA/logs/include-state
MIN_FREE_GB=8
mkdir -p $WORK $OUT $STATE
echo $$ > $DATA/logs/include.pid

free_gb() { df -g ~ | awk 'NR==2{print $4}'; }

while IFS=$'\t' read -r zip_name zip_bytes zip_url; do
  [[ -e $STATE/$zip_name.done ]] && continue
  zip_gb=$(( zip_bytes / 1000000000 + 1 ))
  # the zip and its unpacked videos are on disk at the same time for a moment; keep MIN_FREE_GB spare
  while (( $(free_gb) < MIN_FREE_GB + 2 * zip_gb )); do
    echo "$(date '+%F %T') waiting: only $(free_gb) GB free, need $(( MIN_FREE_GB + 2 * zip_gb ))"; sleep 300
  done
  echo "$(date '+%F %T') === $zip_name ($zip_gb GB)"
  start=$(date +%s)
  if [[ ! -d $WORK/${zip_name%.zip} ]]; then
    until /usr/bin/python3 $TOOLS/fetch.py "$zip_url" $WORK/$zip_name --connections 32 | tail -1; [[ -e $WORK/$zip_name ]]; do
      echo "$(date '+%F %T') download incomplete, retrying in 60 s"; sleep 60
    done
    downloaded=$(date +%s)
    mkdir -p $WORK/${zip_name%.zip}.unpacking
    unzip -q -o $WORK/$zip_name -d $WORK/${zip_name%.zip}.unpacking && mv $WORK/${zip_name%.zip}.unpacking $WORK/${zip_name%.zip} && rm -f $WORK/$zip_name
  else
    downloaded=$(date +%s)
  fi
  # clip list: clip_id <TAB> absolute path <TAB> path inside the dataset (as the official lists write it)
  list=$STATE/${zip_name%.zip}.tsv
  ( cd $WORK/${zip_name%.zip} && find . -type f \( -iname '*.mov' -o -iname '*.mp4' -o -iname '*.avi' \) | sed 's|^\./||' | sort ) | while IFS= read -r relative_path; do
    clip_id=$(echo "${relative_path%.*}" | tr 'A-Z' 'a-z' | sed -E 's/[^a-z0-9]+/_/g; s/^_+|_+$//g')
    printf "include_%s\t%s\t%s\n" "$clip_id" "$WORK/${zip_name%.zip}/$relative_path" "$relative_path"
  done > $list
  clips=$(wc -l < $list | tr -d ' ')
  # 4 processes x 4 jobs: one process tops out near 200 frames/s, four reach ~335 with --face
  cut -f1,2 $list > $list.2col
  awk -v prefix="$STATE/slice." '{ print > (prefix (NR % 4)) }' $list.2col
  for slice in $STATE/slice.[0-3](N); do
    $TOOLS/sign-extract videos --list $slice --out $OUT --face --jobs 4 > $slice.log 2>&1 &
  done
  wait
  extracted=$(date +%s)
  grep -h "^done:" $STATE/slice.*.log
  rm -f $STATE/slice.* $list.2col
  /usr/bin/python3 $TOOLS/include_manifest.py $OUT $list $LISTS
  missing=$(cut -f1 $list | while read -r clip_id; do [[ -e $OUT/$clip_id.npy ]] || echo x; done | wc -l | tr -d ' ')
  echo "$(date '+%F %T') $zip_name: $clips clips, $missing without landmarks; download+unzip $(( downloaded - start )) s, extract $(( extracted - downloaded )) s"
  rm -rf $WORK/${zip_name%.zip}
  touch $STATE/$zip_name.done
done < $TOOLS/include-zips.tsv
echo "$(date '+%F %T') INCLUDE finished"
rm -f $DATA/logs/include.pid
