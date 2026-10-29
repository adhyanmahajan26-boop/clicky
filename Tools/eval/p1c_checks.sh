#!/bin/bash
# P1c live checks: scroll tracking, untracked clear, verifyHitTest with marks,
# recheckExclusion, markRoundTrip, then the eval with the drawn-hit rule.
# Draws on screen: run only when nobody is using the Mac.
set -euo pipefail
cd "$(dirname "$0")/../.."
Tools/GroundingFixture/build.sh
python3 -I Tools/eval/p1c_checks.py "$@"
python3 -I Tools/eval/grounding_eval.py --displays 0,1,2 --badges on --latency-asks 0 --out build/eval/EVAL-p1c.md
