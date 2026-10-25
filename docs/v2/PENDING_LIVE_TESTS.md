# Pending live tests

Checks that draw on screen, talk, or move windows and apps. They were deferred
while Addy was using the Mac (silent mode) and run in one batch when he's away.
Before starting: relaunch Clicky at HEAD via Xcode Run, then
`Tools/clickyctl.sh '{"cmd":"ping"}'` (the sha must equal HEAD).

## P1b (left over)

1. Complete badge A/B eval on the final build:
   `python3 -I Tools/eval/grounding_eval.py --displays 0,1,2 --badges ab --latency-asks 10 --out build/eval/EVAL-p1b.md`
   - ax+web ≥ 98 %, canvas+dot ≥ 90 % (ultrawide d0 split into half-images if its dot+canvas < 90 %)
   - badge mentions in raw narration = 0 (counter fixed in ca167c2: plain "the list" no longer counts)
   - Wilson intervals; keep badges unless "off" wins by ≥ 3
   - the 10 spoken latency asks at the end talk out loud: Addy must be away
2. Real-app asks, reviewed and logged in docs/v2/EVAL.md:
   `python3 -I Tools/eval/real_app_asks.py` (Finder, Safari, System Settings, Xcode, + Slack / VS Code if installed).
   It brings each app to the front.
3. Look into the d0 canvas misses ("x = 42" is ambiguous with the results list; "Total: 1,284").

## P1c

All in `Tools/eval/p1c_checks.sh` (builds the fixture, runs `p1c_checks.py`, then the eval with the drawn rule):

1. Scroll tracking: fixture `--scroll-after 3 --scroll-duration 1.5`, `marks` with
   `[MARK:circle:"Row 12":Row 12]` (+ "Row 1"): the Row 12 mark is ≤ 2 pt from the new truth
   ≤ 200 ms after `scrollEndedAt`; "Row 1" (scrolled out) is hidden ≤ 200 ms.
2. `[MARK:underline:"Deploy failed"]` + `--move-after 3`: cleared ≤ 600 ms after `movedAt`.
3. `verifyHitTest` with live marks (`cover+marks`, `park+marks`).
4. `selftest recheckExclusion`: a Clicky label "Zebra 4821" over empty canvas is NOT found;
   the canvas string "Total: 1,284" is found ≤ 6 pt.
5. `selftest markRoundTrip`: a ring on every display, include-self sRGB capture, orange centroid
   ≤ 2 native px (companion parked away first).
6. Eval n≈120 with Wilson intervals and the stricter drawn-hit rules (grounding_eval.py now
   reports both): rings contain the corners of truth.insetBy(1); arrow tip ≤ pad + 8 pt from the
   truth with its ray hitting it; underline spans ≥ 80 % of the width at maxY…+6.

Acceptance once live: ax+web ≥ 98 %, canvas+dot ≥ 90 %, both ≥ P1b; re-check p95 ≤ 80 ms
(turn.json `drawn.recheck.ms`); idle tracker ≤ 20 AX calls/s with 9 marks (`axRate` events in
`<turn>/marks.jsonl`).

Also still to do once live: hosted tests (`xcodebuild test -only-testing:leanring-buddyTests`
starts the app binary, so it was skipped in silent mode).

## P2

1. `selftest qwenCaptionSync`: 20 Qwen WAVs (synthesized to files, no playback) vs on-device
   `SFSpeechURLRecognitionRequest` word timestamps; p95 ≤ 250 ms.
2. 10 spoken asks per engine (Qwen, then the Mac voice): caption lag p95 ≤ 120 ms (Apple) /
   ≤ 250 ms (Qwen); tags fire ≤ 100 ms after their anchor (`firedTags` in turn.json, each once);
   0 badge leaks; 0 bubble/mark overlap.
3. `selftest overlayExclusion` with the caption bubble showing (it must not reach screenshots).
4. Eval row "show me how to search then open build settings" → numbered MARKs, no `<whiteboard>`.
5. ask + say "stop" → silent within 3 s, history ends in "[interrupted]"; and "wait for the build"
   spoken by Clicky must not stop itself (EchoGuard).
6. keyUp → firstAudio p50 ≤ 3.5 s (was 5.7 s): `grounding_eval.py --latency-asks 10`.
7. Effort low vs medium: `grounding_eval.py --effort low` then `--effort medium` (same rows),
   compare hits and latency.
8. Whether the TTS passes the Mac's echo cancellation with the mic open (open vs halfDuplex,
   `defaults write com.personal.clicky v2.voice.echoMode halfDuplex`).
9. Hosted tests (`xcodebuild test -only-testing:leanring-buddyTests`); compiled, not run.
