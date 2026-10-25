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

## P3 (Qwen via mlx-serve)

Probe results and the voice decision are in docs/v2/EVAL.md "P3 probe". Live checks (all talk out loud):

1. `ttsLatency`: 10 spoken asks with Qwen; warm first segment (segment queued → first audio) p50 ≤ 600 ms.
2. `ttsIntelligibility`: Qwen WAVs of 20 answer-like sentences (lexicon applied) transcribed on-device;
   WER ≤ 15 % against the caption text.
3. 20 ask / stop cycles (push-to-talk barge-in and spoken "stop"): silent within 300 ms each time, no audio
   from an older answer afterwards (engine epoch), history ends in "[interrupted]".
4. Fallback: (a) closed port: `defaults write com.personal.clicky v2.debug.ttsPortOverride -int 11299`,
   relaunch → status "Qwen unavailable: nothing on port 11299", the Mac voice speaks, nothing spawned on 11299
   (then `defaults delete com.personal.clicky v2.debug.ttsPortOverride`); (b) kill mlx-serve mid-answer → the Mac
   voice speaks the rest of that answer, the supervisor respawns it (at most once per 60 s) and the next answer is
   Qwen again; (c) a slow segment (watchdog 1.0 + 0.6 x chars/15 s) → only that segment in the Mac voice.
5. Adopt on relaunch: quit Clicky → mlx-serve keeps running (`lsof -nP -iTCP:11234 -sTCP:LISTEN`, pid in
   `~/.clicky/mlx-serve.pid` when Clicky started it) → relaunch → "Qwen ready (…)" with no second server.
   Also: a server bound to `*:11234` → "Qwen unavailable: not loopback-only", Mac voice, the server is untouched.
6. Gaps between Qwen segments p95 ≤ 50 ms (segment end → next segment start, turn.json).
7. Caption lag p95 ≤ 120 ms with Qwen (WordTiming on the original caption words; also at v2.voice.rate 1.3).
8. keyUp → firstAudio p50 (`grounding_eval.py --latency-asks 10`), compared with P2.
9. Echo: while Clicky speaks only stop / wait / "clicky stop" act (EchoGuard); other speech heard until
   output latency + 0.25 s after the last audio is dropped as echo; music is not ducked during hands-free.
10. Hands-free "slower" / "faster" and push-to-talk "slower" / "faster" step 0.85 → 1.0 → 1.15 → 1.3 for
    both voices; captions stay on the words at every rate.
11. Panel: speaker / instruct / presets / "Test voice" / status line (the button speaks only when clicked).
12. Hosted tests (`xcodebuild test -only-testing:leanring-buddyTests`, includes QwenP3HostedTests with the
    URLProtocol stub); compiled with build-for-testing, not run.

Questions for the user:
- Listen to `build/eval/p3-lexicon/*-{raw,lexicon}.wav` (p3 worktree): are "P R", "number 12", "Git Hub",
  "X code", "Swift U I", "Jason", "Control Option", "version 2.1" better than the raw readings? And is rate 1.3
  still comfortable to follow?
- If the first-segment latency misses (p50 > 600 ms): try an 8-bit Qwen3-TTS build (needs a download, not done).
- Load the CustomVoice model so speaker "Ryan" + the instruct take effect (the Base model ignores them)?
