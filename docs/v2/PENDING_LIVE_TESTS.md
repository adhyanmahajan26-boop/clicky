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
   Qwen again; (c) a slow segment waits (watchdog max(20 s, 10 + 3 x estimate)), never switching voices mid-answer.
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

## P5

Code mode is off by default (`v2.code.enabled`); everything below needs the app running and the
user present. Silent mode covered: `swift test` (fake `claude`/`gh` scripts, temp repos and a temp
bare remote only), the app build, and build-for-testing.

1. Sandbox probe: run `Tools/codeprobe.sh`. Any FAIL or INCONCLUSIVE → keep
   `v2.code.bashAllowed` false (the default). Only an all-PASS run may set it true.
2. Preflight probe: turn on "Code mode" in the menu-bar panel; the status line must say
   "Ready as @<login>". `codeState` (debug inbox) shows the flag table: `--max-turns` must read
   `probeVerified` (it's hidden from `claude --help` 2.1.301; the probe passes `--max-turns 1`),
   `--append-system-prompt-file` `fallback` (rules.md inline via `--append-system-prompt`), and
   `unremovableTools` should be empty. If the probe's init lists plugins or MCP servers the
   preflight refuses (the agent's init would be rejected anyway) — note which.
3. "in clicky, what does CompanionWorkers do?" → answered out loud, read-only. OK to run on
   ~/Projects/clicky because ask_repo only reads (cwd = the clone, tools Read/Grep/Glob, no
   worktree). Check afterwards: `git -C ~/Projects/clicky status` unchanged,
   `~/.clicky/code/<task>/agent.jsonl` init shows `"tools":["Read","Grep","Glob"]`,
   `permissionMode` acceptEdits, no MCP servers.
4. Sandbox PR flow — needs the user's OK to create a throwaway repo first (never a real one):
   a PR with one review comment → "fix the review comments on <sandbox> PR 1" → the panel shows
   `o/n #1 @old→new`, the diff, the reply text, the quoted argv; Approve stays disabled until the
   push dry-run finishes; Push & reply → `ls-remote` check, push, reply, resolve, then
   `gh pr checks` polling (15 s, ≤ 20 min) spoken. Also: a `.github/workflows/` change is red
   and blocks; editing a reply changes what's sent (and an edit after the click aborts);
   `repo_change` with deliver local/branch/pr (PR only if `gh pr list --head` is empty);
   "Clean up worktrees" asks when a worktree has unpushed commits.
5. Review panel by hand: the look (compare with
   `~/Library/Logs/Clicky/renders/p5/review-panel.png` from `swift test`), a click within 0.5 s
   of the panel appearing is ignored, plain click for push/PR/comment/reply, a 1.5 s hold (with
   the fill animation) for approve / request changes / merge / update branch, a short press on
   those does nothing, Return only highlights the primary button for 5 s, Esc during
   "Opening o/n #N" cancels, and the chooser appears for an ambiguous name.
6. Hosted tests (`leanring-buddyTests/CodeModeControllerTests.swift`): compiled, not run.

## P4 (CWB v1 whiteboard)

Silent-mode work: everything below draws a window, talks or flies the companion. Renders and narrator
logic are covered offscreen by `swift test` (goldens in `Packages/ClickyCore/Tests/ClickyCoreTests/Goldens/p4`,
PNGs in `~/Library/Logs/Clicky/renders/p4/`).

1. `Tools/clickyctl.sh '{"cmd":"board","path":"'$PWD'/Tools/eval/boards/https.jsonl"}'`: the panel opens on the
   mouse screen (visible frame inset 6 %), "Drawing…", then the board narrates step by step in the voice; the
   reply has `hasBoard: true`, `steps: 10`. Then `boardCtl {action: export}` → `~/Pictures/Clicky/whiteboard-<ts>.png`
   (whole board, 2×, charts not blank) + `.clickyboard` (the JSONL) next to it, PNG on the pasteboard.
   Also `boardCtl` next / back / replay / pause / state / close.
2. Ask "how does https work, why is it slower than http, and what's a certificate" ×10 (spoken, MODE hint off,
   `v2.whiteboard.auto` on): ≥ 9 answers draw a board with an agenda, 3 question sections in the order asked, and a
   recap (`boardTitle`, `boardStats` in turn.json; sections in `boardCtl state`). Repeat once with "draw a diagram
   of …" (MODE: whiteboard, `--effort medium`).
3. Reveal timing from turn.json `boardEvents`: for every step, `reveal.t − first segmentStart.t` of that step is
   ≥ 0 (never before) and ≤ 50 ms; a step without words holds 1.2 s (`hold` → `stepEnd`).
4. `selftest overlayExclusion` with the board open: the panel must not reach screenshots (Clicky is excluded by app).
5. A step whose `say` points at the real screen (e.g. `[POINT:"Safari":Safari]`): the board drops to 25 % and clicks
   pass through until that step ends; a `point` id / POINT at a board element flies the companion onto the board.
6. Keys, checked by the user (panel key): Esc closes (before any other Esc consumer), ←/→ step, Space pauses and
   resumes the voice mid-sentence, r replays from step 1, e exports, c copies the PNG, f toggles full screen
   (`v2.whiteboard.fullScreen`), 0 fits, +/− zoom. Themes: `defaults write com.personal.clicky v2.whiteboard.theme chalk`
   (and `dark`, `paper`).
7. Hands-free with the board open: "next", "back", "repeat", "pause", "continue", "close board", "save board"; while
   Clicky is speaking a command word Clicky itself just said is ignored (EchoGuard). Always: "whiteboard that" after a
   normal answer (a board of it), "go deeper on two" (a new page for the second question section).
8. Several questions with helpers: a MODE: whiteboard turn that spawns workers shows the shell (one frame per worker,
   orbiting spark) and replaces it with the board; the shell closes if no board follows.
9. A deliberately broken board (`board` with a file of mangled JSONL) → one repair call (main model, $TMPDIR/clicky-session)
   then the board, or, if that fails, the steps' words spoken with no board.
10. History: the next turn's "earlier in this conversation" carries `BOARD STATE` (≤ 4 KB).
11. Hosted tests compiled with build-for-testing, not run.

SwiftMath is pinned at 1.7.3 (`Packages/ClickyCore/Package.swift`, exact) for math images.

## P6.2 (Type this for me)

Off by default (`v2.typeForMe.enabled`); with it off a `<type>` block still opens the card, Copy
only. Silent mode covered: `swift test` (chunker, refusal rules, clean-up + 5000 cap, terminals,
plain-⌘V menu finder, clipboard restore, verification, the confirm gate's 0.5 s window, auto-repeat,
tagged events, 30 s / focus expiry), the app build and build-for-testing. Nothing was ever typed:
every confirm below needs the user's own physical Return (or click on Type) — never automate it.
Compare the look with `~/Library/Logs/Clicky/renders/p6/type-card.png` (and `type-card-refused.png`).

1. Turn on `v2.typeForMe.enabled`. Slack self-DM: "type 'testing clicky, ignore' into this
   message" → card under the caret with Slack's icon, "text area · Message …", the preview and
   "AX insert, else paste, else type". Return within 0.5 s of the card appearing does nothing;
   holding Return (auto-repeat) does nothing; a real Return types it once. Don't send it — clear it.
   The log line `⌨️ Type for me: Slack AXTextArea len=… method=… result=inserted` names the method.
2. Safari: a draft in a web form (e.g. a GitHub comment box) → Type; check it landed once, then
   clear the draft. Also click Type with the mouse (press + release on the button) instead of Return.
3. TextEdit: a multi-line text → typed with its line breaks (method ax or paste); the clipboard
   holds what it held before (~350 ms later), unless you copied something in between.
4. A terminal (Terminal / iTerm2 / Warp / Ghostty): the card asks for a second Return, line breaks
   are gone, and no Return is ever sent (the command is NOT run).
5. A secure field (a password field in Safari, or System Settings' password prompt) → card says
   it won't type, Copy only. Same with 1Password / Keychain Access focused.
6. Expiry: wait 30 s → Type greys out; switch apps or click into another field → greys out; Esc
   closes the card without stopping Clicky's speech; changing focus after confirming (during the
   0.15 s settle) → "focus moved, nothing typed"; holding ⌘ after confirming for > 2 s → aborted.
