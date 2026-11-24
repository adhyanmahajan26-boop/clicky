#!/bin/zsh
# The rest of sweep 1, PopSign then FSboard, one after the other (so raw videos never pass 12 GB in all). Budgets are
# what each job's plan.json said was left of sweep 1, plus 10% (25.7 -> 28.3 GB, 19.4 -> 21.3 GB). Stops after sweep 1.
echo $$ > ~/sign-data/logs/round1-rest.pid
/usr/bin/python3 ~/sign-data/tools/popsign_sweeps.py --max-sweeps 1 --max-download-gb 28.3 >> ~/sign-data/logs/popsign.log 2>&1
/usr/bin/python3 ~/sign-data/tools/fsboard_sweeps.py --max-sweeps 1 --max-download-gb 21.3 >> ~/sign-data/logs/fsboard.log 2>&1
echo "$(date '+%F %T') round 1 rest done"
rm -f ~/sign-data/logs/round1-rest.pid
