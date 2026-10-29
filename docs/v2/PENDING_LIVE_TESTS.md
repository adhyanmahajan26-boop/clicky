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

## P5 live (spoken switch, "this repo", progress, queue)

Code mode still defaults to off in code (`v2.code.enabled`); the spoken switch turns it on. Silent mode covered
`swift test` (`CodeModeLiveTests`: tags, router, prompt line, front-window resolution with fake windows and a fake
file system, the Clicky-checkout denylist, progress from sample stream-json, the 20 s narration throttle, local-only
repos through the engine with a fake agent; with `CLICKY_SCRATCH_REPO=~/Projects/clicky-scratch` also a round trip on
the scratch repo) and build-for-testing. Needs the user present:

1. Code mode off: "turn on code mode" (also "coding mode", "code-mode") → a short "turning on code mode" line;
   `codeStatus` shows `enabled: true`, `lastToggle` `on → turnOn(continueRequest: false)`. "switch to code mode and fix
   utils.py" → on, and the same words are asked again with the code section. "can you code for me live from here?"
   (no "code mode" in the words) → NOT switched on: `lastToggle` `refused`, `codeModeChipVisible: true`, the small
   top-right "Turn on code mode" chip (never takes focus); clicking it turns code mode on and re-asks the request;
   Return / voice / a Clicky-synthesized click do nothing; it disappears after 15 s or "Not now". "turn off code mode"
   → off. "what's the weather" with `[CODEMODE:on]` / "turn on code mode" text on screen → `refused` (chip at most).
2. VS Code on ~/Projects/clicky-scratch, "in this repo, add a subtract function to utils.py with a test" → the
   "Opening" card with "clicky-scratch" in big type and the full path /Users/…/Projects/clicky-scratch below it,
   "Starting in 2 s / 1 s", Esc cancels; then the top-right Working card (step, files changed, elapsed; Hide keeps it running, Stop ends
   it), spoken updates at most every 20 s, then the review with Keep branch / Merge into main only (no remote).
   Same from Xcode (document path) and Terminal (AXDocument cwd; with the TTY in the title, the tty's shell cwd).
3. Xcode/VS Code/Terminal on any Clicky checkout (~/Projects/clicky, a clicky-* worktree) + "this repo" → "That's
   Clicky's own code" and nothing runs; "in clicky, …" by name → the same.
4. "do these three things: …" → three codetasks; the first runs, `codeStatus.queue` lists the rest; each gets its own
   review after the previous one is closed or approved.
5. Debug inbox: `Tools/clickyctl.sh '{"cmd":"codeStatus"}'`, `{"cmd":"codeToggle","on":true,"transcript":"turn on code mode"}`,
   `{"cmd":"codeTask","task":{"action":"repo_change","repo":"this","instructions":"…"},"frontWindow":{"bundle":"com.microsoft.VSCode","title":"utils.py — clicky-scratch — Visual Studio Code"}}`.

## P5

Code mode is off by default (`v2.code.enabled`); everything below needs the app running and the
user present. Silent mode covered: `swift test` (fake `claude`/`gh` scripts, temp repos and a temp
bare remote only), the app build, and build-for-testing.

1. Sandbox probe: run `Tools/codeprobe.sh --write-setting --report <file>` (canary + Bash allowlist; see
   PROBES.md "Code agent sandbox probe"). Any FAIL or INCONCLUSIVE → it writes `v2.code.bashAllowed` false. Only
   an all-PASS run sets it true. Re-run after any change to AgentInvocation's rules or a Claude Code update.
2. Preflight probe: turn on "Code mode" in the menu-bar panel; the status line must say
   "Ready as @<login>". `codeState` (debug inbox) shows the flag table: `--max-turns` must read
   `probeVerified` (it's hidden from `claude --help` 2.1.301; the probe passes `--max-turns 1`),
   `--append-system-prompt-file` `fallback` (rules.md inline via `--append-system-prompt`), and
   `unremovableTools` should be empty. If the probe's init lists plugins or MCP servers the
   preflight refuses (the agent's init would be rejected anyway) — note which.
3. (Superseded: Clicky's own checkouts are now on the code-mode denylist, so this is refused; use
   ~/Projects/clicky-scratch instead.) "in clicky, what does CompanionWorkers do?" → answered out loud, read-only. OK to run on
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

## P6.4 (AEC echo mode)

Opt-in: `defaults write com.personal.clicky v2.voice.echoMode aec` (default stays `open`; nothing changes
unless it's set). Silent mode covered only the pure parts in `swift test` (`EchoCancellationTests`: 60 %
partial-overlap echo filter, command phrases while playing, byteSampleOffset → frames → characters,
headphone classification, throw → halfDuplex); no mic or speaker was opened. Everything below needs the user
present, talking, with hands-free on. Watch the console for `🎙️ AEC:` / `🎧 AEC:` / `🔇 Hands-free:` lines.

1. Speakers vs headphones: start hands-free on the built-in speakers → `listening (echo mode aec)` and
   `shared engine on`; with AirPods / wired headphones → `🎧 … headphones` and `echo mode open` (no voice
   processing). Hot-plugging mid-session isn't re-classified (restart hands-free).
2. Both voices play through the shared engine (Qwen and, with Qwen off, the Mac voice): audible, no
   clicks between segments, rate 0.85 / 1.15 / 1.3 sounds right (Qwen via the time pitch, Mac voice via its
   utterance rate), music in another app is NOT ducked.
3. Barge-in with TTS loud (volume ≥ 75 %): "stop", "wait", "clicky stop" each cut Clicky off ≤ 1 s;
   "please wait for me" / "stop the build" don't (only the bare phrases count while playing); a "wait" that
   Clicky itself just said doesn't stop it.
4. False triggers over 10 spoken answers on speakers (no user speech): count barge-ins and utterances sent to
   Claude — target 0; count `🔇 … echo … dropped` lines (leaks the canceller missed and the filter caught).
5. Caption sync with Apple word markers (Mac voice): the caption reveals each word as it's heard (≤ 120 ms
   lag, as P2); confirm `byteSampleOffset` really is bytes (if captions run ~2× ahead, it's frames: drop the
   bytesPerFrame division in `SpeechWordMarkerTimeline.sampleOffset`). Qwen caption sync on the player-node
   clock matches the AVAudioPlayer path (`v2.caption.avOffsetMs` still applies).
6. Fallback: if voice processing throws (e.g. an aggregate device), the log says `falling back to halfDuplex`
   and hands-free still hears the user when Clicky is quiet.
7. Ending hands-free mid-answer: the segment playing ends, the rest of the answer continues on the normal
   output path (no stuck caption, no overlap).

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

## P6.9 / P6.10 / P6.6

### P6.9 Diagnostics (silent until you press a button)

1. Open the menu bar panel and press Diagnostics (footer, left of Quit). The window shows permissions, the Qwen status and the newest turn's time to first audio. Nothing is requested.
2. Press Check Claude and Check GitHub. Confirm no token text appears (only exit codes, `Logged in as`, and the scopes line).
3. Press a self-test Run button only when you want that test to run (several open windows, play audio or drive the mouse). The result line shows Passed or Failed.
4. Settings: change a v2 toggle, picker, stepper or list in the window and confirm the panel or the next turn behaves accordingly.
5. Offscreen layout check: `~/Library/Logs/Clicky/renders/p6/diagnostics.png` (fake values; the toggles and pickers show placeholder glyphs in the render because AppKit controls don't draw offscreen).

### P6.10 whiteboard PDF export

1. Open a board and press `e` (or `boardCtl export`). Expect `~/Pictures/Clicky/whiteboard-<ts>.pdf` next to the PNG and the `.clickyboard`.
2. Open the PDF in Preview: the board's title and labels as selectable text, charts drawn (not blank), formulas sharp at any
   zoom (vectors) and found by Find with their TeX (e.g. search `frac`). A board that fits A4 proportions (height ≤ √2 × width)
   is one page the board's size with no step counter; a taller one is several same-size pages cut between section rows, each
   headed "<title> … page n of m". Preview's Title (⌘I / Inspector) is the board's title.
3. Voice: with a board open say "save this as a pdf" (or "export it to pdf", "save board") → Clicky says "saved the board as a
   PDF and a picture in the Clicky folder in your Pictures." and the files appear. Ask in a longer sentence ("could you save
   this whiteboard as a pdf so i can send it") → the model answers with a few words + `[SNAP:board]` (turn.json rawResponse),
   same line spoken after its words; with no board open → "there's no board open to save."
4. Offscreen evidence (no app needed): `swift test --package-path Packages/ClickyCore --filter PDFExportTests` writes
   `~/Library/Logs/Clicky/renders/pdf/<board>-<theme>.pdf` + a PNG per page + `report-<board>.txt`;
   `Tools/eval/pdf_check.sh [files…]` inspects any exported PDF (pages, text, vector vs images, fonts embedded).
   Printed on A4 a wide board shrinks to fit the width (a 1866-pt board prints at ~32 %): fine on screen, small on paper.

### P6.6 keep-warm LaunchAgent (generator only; nothing is installed or bootstrapped)

1. The generator and decisions are covered by `swift test` (plist parses, plutil lint on a temp file, exact argv and env). No file is written to ~/Library/LaunchAgents and no launchctl is run by the app.
2. Installing is not wired. It needs your yes: set `v2.voice.keepWarmAgent` and `v2.voice.keepWarmAgentApproved` (both in the Diagnostics settings list), then wire the install step before trying it.
3. Not done yet: the app never calls `KeepWarmLaunchAgent.installPlanRequiringUserApproval`, and it doesn't adopt a running server through `adoptDecision` yet.

## P6.7

Progressive board (helper sections, bridge lines, plan-order narration). Hosted tests compiled with build-for-testing,
not run; the narrator / filter / merge logic is covered by `swift test` (ProgressiveBoardTests).

1. Ask a multi-part board question, e.g. "draw how https works, what a certificate is, and why https is slower"
   (MODE: whiteboard). turn.json `rawResponse`: one `[WORKER:s<k> title:task]` line per helper section BEFORE the
   `<whiteboard>` block, and inside it one `{"el":"text","id":"s<k>_wait",…,"text":"working on it…"}` placeholder
   plus a silent step per helper section. The log shows `🛠️ Worker started (haiku): s1 …` and no
   "final answer after workers" follow-up stream for these helpers.
2. Helpers that finish while the agenda is spoken: their sections are drawn in place (the board re-lays out,
   "working on it…" replaced), narrated in plan order (agenda, s1, s2, …, recap), with no bridge line.
3. A slow helper (or a long agenda cut short): when the voice reaches its section the placeholder shows, Clicky says
   ONE bridge line ("that part's still coming, i'll come back to it.") — back-to-back pending sections share it —
   and goes on. When the helper lands, its steps are narrated right before the recap.
4. A helper that hasn't landed when the voice reaches the recap (or the end, with no recap): one short line
   ("that part didn't make it in time…"), its placeholder and empty section leave the board, then the recap.
   A late reply is ignored (log: `came too late; ignored`).
5. A helper that fails or replies with nothing of its section: log `drew nothing usable`; the section is dropped
   with the short line when the voice gets there. Lines outside the section (no `s<k>_` id, header lines, other
   `sec`, arrows leaving the section) are logged as rejected and never reach the board.
6. Ordinary helpers (titles without `s<k>`) still get the follow-up stream; a section helper of an answer that
   drew no board also falls back to the follow-up stream.
7. After the narration: replay (r), next / back, export and the history's BOARD STATE all use the merged board.

## P6.8 (grounding perf: AX cache + observers, OCR off AX coverage, enhanced UI)

Not run live (the app was in use). Unit-tested: AX cache hit/miss/dirty/evict/race, tile coverage + bbox merge,
enhanced-UI matching/transitions, alarm percentiles (`GroundingPerfTests`).

1. `selftest groundingLatency` (20 warm + 20 cold, quiet machine): warm p95 ≤ 150 ms, cold p95 ≤ 300 ms (P1b: warm
   p50 107 / p95 120, cold p95 177). Stage times: `frontAXCached` should be 1 on most warm turns (front app reused from
   the prewarm), `frontAX` near 0 then. turn.json `grounding.axWalks` marks reused walks `(cached)`; no `latencyAlarm`.
2. `selftest fixture_selftests` on each of the 3 displays (5K, ultrawide 1x, laptop), twice in a row (the first prewarm
   verifies AX against full-ish OCR, the second uses AX coverage): ax 100 %, axtext 100 %, web ≥ 95 %, canvas ≥ 98 %
   both times (the canvas has no AX, so it stays OCRed). `grounding.ocrCoverage` in turn.json shows the tiles skipped.
3. Grounding eval (`Tools/eval/grounding_eval.py`) no worse than P1b; watch text targets on buttons (button labels
   don't count as AX coverage, so they're still OCRed) and the shifted-band retry rate.
4. Cache invalidation by hand: prewarm on Finder, move/resize a window or scroll a list during the hold → the key-up
   re-walks (no `(cached)`); type in a text field → re-walk; quit an app → its entries go (`AXWalkCache`).
5. Enhanced UI: bring Chrome / Slack / VS Code forward → their web content shows up in the element list on the first
   turn; switch to Finder → Chrome's `AXEnhancedUserInterface` is false again (`osascript`/Accessibility Inspector);
   Rectangle/window snapping on Chrome still behaves while it's frontmost. Quit Clicky with Chrome in front → flag
   restored. Custom list: `defaults write com.personal.clicky v2.grounding.enhancedUIBundleIDs -array com.google.Chrome`
   (drop `electron` to stop matching Electron apps).
6. Alarm: with a forced slow path (e.g. 10 cold turns under load) the console shows "Grounding latency over limit"
   and turn.json `grounding.latencyAlarm` is set.

## P6.11 (final eval: harness and fixtures only, not run)

Run only when the coordinator says so, with Addy away: it opens Finder, Safari, Xcode, System Settings,
Preview, Notes, Slack, VS Code, Terminal and a throwaway Chrome, and `--spoken-rows` talks out loud.
Harness: `Tools/eval/final_eval.py` (data in `Tools/eval/final/`, pages in `Tools/eval/canvas/`); results
are resumable per row in `build/eval/final/<run>/results.jsonl` (rerun the same command after a stop; usage
limits back off 30 s → 8 min, then the run stops). Before starting: relaunch Clicky at HEAD via Xcode Run,
`Tools/clickyctl.sh '{"cmd":"ping"}'` (sha = HEAD), `Tools/GroundingFixture/build.sh`.

1. Validate the data (touches no app):
   `python3 -I Tools/eval/final_eval.py --dry-run` and `python3 -I Tools/eval/test_final_eval.py`
2. Check the AX truths first (opens the apps, resolves every row with `axfind`, asks nothing):
   `python3 -I Tools/eval/final_eval.py --probe-truth --run-name probe`
   The "Not scored" list in `build/eval/final/probe/EVAL-P6.11.md` (and `results.jsonl`, with the labels
   `axfind` saw) shows rows whose truth didn't resolve: fix `Tools/eval/final/ax_asks.tsv` (titles of the
   real controls), `rm build/eval/final/probe/results.jsonl`, probe again. Rows that still don't resolve
   are reported as truth-missing and left out of n. Slack / VS Code need `"electron"` (set automatically).
3. Configs on the 40-row fixture (baseline, raw-hires, list, list+badges, verify):
   `python3 -I Tools/eval/final_eval.py --sets fixture --configs baseline,raw-hires,list,list+badges,verify --displays 0,1,2 --run-name final`
4. Full sets on the final config (add `,baseline` to `--set-configs` for a baseline arm on the full sets):
   `python3 -I Tools/eval/final_eval.py --sets ax,canvas --set-configs verify --spoken-rows 10 --run-name final`
5. Inputs for the board / code-probe lines: `python3 -I Tools/eval/gen_boards.py` (or `--check-only` if the
   answers exist) and `Tools/codeprobe.sh | tee build/eval/codeprobe.txt`.
6. Report into EVAL.md (reads results only):
   `python3 -I Tools/eval/final_eval.py --report-only --run-name final --append-to docs/v2/EVAL.md`

Notes:
- Config arms are written with `defaults write com.personal.clicky` and restored afterwards. This build reads
  `v2.grounding.badges` and `v2.grounding.imageTier` (cursor screen only; image tier is read per capture);
  `v2.grounding.lists` and `v2.grounding.verifyWithHaiku` are written but not read here yet. The report's
  "setting reached the turn" column checks every turn (`grounding.isBadged`, `elements.txt`,
  `grounding.verifyWithHaiku`, image px/pt) and says when an arm did not take effect.
- Truth: AX rows from `axfind` (a plain AX walk in the app, independent of the registry; truths below 50 %
  visible are dropped as truth-hidden); canvas pages from the DevTools protocol on 127.0.0.1 (Chrome runs in
  `--app` mode with a temp `--user-data-dir`, deleted afterwards), cross-checked against Chrome's AXWebArea;
  the video (`canvas/video/dots.mp4`, regenerate with `python3 -I Tools/eval/canvas/make_video.py`); Terminal
  text from AXBoundsForRange. Figma rows are skipped (not installed).
- Caption checks need spoken rows (the bubble only shows while Clicky talks): bubble rects are logged as
  `bubble` events in `<turn>/marks.jsonl`, label pills as `drawn.labelRectCG` in turn.json. RTF and caption
  lag are reported only if turn.json carries them on the build under test.
- Cleanup after the run: Terminal windows stay open with "[Process completed]"; Finder / Xcode / VS Code /
  Preview windows show temporary copies under `build/eval/final/<run>/fixtures`; Safari keeps the
  127.0.0.1 tabs. Close them by hand.

## Project bridge ("send this to my project …")

Unit-tested in ClickyCore (`ProjectBridgeTests`); these need the running app:
1. Push-to-talk "send this to my project fix the login page": Clicky says "Sent to your project." with no brain
   turn (no spinner), the notch shows "sent to project" for ~4 s, a Project task row ("Sent") appears in the
   Agents dashboard, and `~/.clicky/project-outbox/<yyyyMMdd-HHmmss>-<uuid>.json` holds exactly
   id/createdAt/transcript/frontApp/frontWindowTitle/repoRoot/cursorDisplay. With Xcode / VS Code / Terminal
   on a git repo in front, repoRoot is its root; with a Clicky checkout in front it is null.
2. "send this to my project" alone → "What should I send to your project?", nothing written.
3. Hands-free utterance with the phrase → same as 1. A Clicky answer that says the phrase (echo) is not sent.
4. Write `~/.clicky/project-inbox/<id>.json` `{"id":…,"status":"thread_started","note":"…"}` → within ~2 s the
   dashboard shows "Thread started" + the note, the notch flashes, and "Your project started a thread for that."
   is said once (after any answer in progress finishes). Rewriting the same status says nothing. `done` /
   `failed` finish the row; `failed` says the note. Oversized (>16 KB) or malformed files change nothing.
5. `defaults write com.personal.clicky v2.project.speakUpdates -bool false` → replies update silently;
   `v2.project.enabled -bool false` → the phrase goes to the brain as an ordinary question.
6. Debug inbox: `{"cmd":"projectSend","transcript":"send this to my project x","speak":false}` →
   `{sent, id, path}`; `{"cmd":"projectStatus"}` lists the task.

## Voice gallery

Unit-tested in ClickyCore (`VoiceGalleryTests`: manifest, order, phrases, cycling, settings writes, the
reference-clip reload, renders in `~/Library/Logs/Clicky/renders/voice/`); these need the running app:
1. Menu bar panel → Voice → "Voices…" opens the "Voices" window: voice1–6, the current voice (7), then the
   installed Apple Enhanced/Premium English voices. Nothing plays until a Play button is pressed; Play on a
   cloned voice plays its `voiceN-sample.wav`, on an Apple voice speaks the manifest's sampleText; Stop and
   closing the window stop it.
2. "Use this voice" on voice 3 (silent): `v2.voice.qwen.referenceClip` = the absolute path of
   `voice3-ref.wav`, `usesQwenLocalVoice` = true, and the next answer is cloned from voice 3 (the client
   re-reads the clip; no relaunch). On an Apple voice: `selectedSpeechVoiceIdentifier` set, Qwen off.
3. Push-to-talk "next voice" / "change your voice" → the next gallery voice says "How's this voice?" in that
   voice, with no brain turn. "use voice 3" / "voice number three" → voice 3 + the same line. "previous voice"
   / "go back to the old voice" → the voice before the last switch. "show voices" → the window comes front
   without taking focus. "use voice 42" → "There's no voice 42. I have N."
4. Switching from an Apple voice to a Qwen one while the Qwen server is cold: the line may come out in the
   Mac voice (fallback) while Qwen warms up; the next answer should be in the cloned voice.
5. Debug inbox: `{"cmd":"voiceGallery"}` lists entries + active; `{"cmd":"voiceSelect","index":3}` switches
   silently; `{"cmd":"ask","text":"next voice","speak":false}` switches without speaking.

## Wake word (P7)

Unit-tested in ClickyCore (`WakeWordTests`: matcher variants and negatives on transcript fixtures, segment
starts, the gate, "stop/start listening", listener state, energy gate, CPU window). `WakeWordFeedTests` runs
`say -o` WAVs through the real recognizer only when the test runner has Speech Recognition permission (a
terminal `swift test` normally doesn't, so it's skipped). These need the running app:
1. `{"cmd":"wakeStatus"}` right after launch: `armed: true`, `locale` en-IN (or en-US), `micOpen: true`;
   the notch pill shows a small white dot on the logo; the panel's Wake word row says it's listening.
2. Make the clips (never played): `say -o /tmp/wake/a.wav --data-format=LEI16@22050 "Hey Claudia, what's on my
   screen?"`, likewise "Hey Clicky, open notes.", "Hey Claude, open the file.", "Claudia is my friend.", plain
   chatter. `{"cmd":"wakeFeed","path":"/tmp/wake/a.wav"}` → one `fire` detection with `turnText` "what's on my
   screen" and a `latencyMs`; the negatives → no `fire`.
3. Say "hey Claudia, what's on my screen" → Pop, listening, a normal answer. "hey Clicky" … pause … "open
   notes" → same. "hey Claudia, next voice" → the voice gallery switch (no brain turn).
4. While Clicky answers, play a clip saying "hey Claudia" from another device → ignored (`ignoredMatches`
   counts `ignoredWhileSpeaking` / `ignoredJustAfterSpeaking`).
5. Join a FaceTime / Zoom call → within 2 s red dot, `pausedReason: microphoneInUseByAnotherApp`; hang up →
   armed again. Lock the screen → `screenLocked`; unlock → armed. Connect AirPods as input → `bluetoothMicrophone`
   (holding their mic open would drop them into call-quality audio).
6. Hold push-to-talk mid-way through a wake turn → the wake turn is dropped, PTT works as before; after key-up
   `wakeStatus` is armed again within ~0.5 s. Same for a hands-free session (paused for its whole length).
7. "hey Claudia, stop listening" → spoken confirmation, setting off, dot hidden; push-to-talk "start listening"
   → back on.
8. CPU over 30 min idle in a quiet room: `wakeStatus.cpuPercentLastMinute` (Clicky) and
   `speechServiceCpuPercentLastMinute` (localspeechrecognition + com.apple.siri.embeddedspeech) every few
   minutes; also with Netflix playing on speakers (the gate stays open more, so the recognizer runs more).
9. False wakes with Netflix audio for an evening: `wakes`, `falseWakes`, `ignoredMatches`.


## P7 computer-use actions (`<actions>` blocks)

Unit-tested in ClickyCore (`ActionsTests`: DSL parsing incl. invalid/oversized, tier classification,
the 12-step limit, stale ids, the physical-input cancel state machine, the Return rule, confirm/stop
replies, page-text and summary helpers, router/prompt/notch/settings, the debug AX allowlist). These need
the running app (never with Netflix playing in Safari unless the test names Safari):
1. "open chrome and google best ramen near me": Chrome comes forward (activation is expected), a Google
   results tab opens, the notch's expanded pill lists "✓ open Google Chrome", "✓ search google for …",
   and an Action task row is in the Agents dashboard. Default browser = Safari → Chrome is used instead.
2. "…then open the second result": the observe turn (a second brain record) re-captures; the click on the
   result link is free (AXPress, no cursor jump). Then "summarize the article for me on screen": a
   summarize step with no text, another observe turn carrying PAGE TEXT, and a "Summary" board appears
   with bullet points. Try a PDF / canvas page: the OCR fallback is used (actionsStatus shows `via ocr`).
3. "highlight the important facts": boxes / underlines from Clicky's overlay only; the page is unchanged;
   the marks survive the observe turn that follows.
4. Typing: "type hello world in the search box" → the step shows "… in 1.5 s — move or press anything to
   cancel" in the notch, then the text lands (AX value, else tagged key events). Move the mouse during the
   countdown → "stopped — you moved the mouse.", nothing typed. Return is never pressed.
5. "type hi in the chat and press enter" → confirm card + "should i …? say yes, or click confirm."; say
   "yes" → typed + Return; say "no" → "okay, i won't."; click Confirm in the first 0.5 s does nothing.
   A Send / Post / Delete button behaves the same. 60 s without an answer cancels.
6. Refusals (spoken when no observe turn follows, else Claude says it): a password field, a card-number
   field, Terminal / iTerm typing, Keychain Access, System Settings › Privacy & Security, anything in
   Safari or a Netflix window when the request didn't say "safari" / "netflix", Clicky's own windows.
7. Cancels: "stop" (push-to-talk or hands-free), Esc, the notch / dashboard Cancel, any key, click, scroll
   or real mouse move while steps run. Clicky's own synthetic click must NOT cancel (tagged events, and an
   untagged cursor warp within 0.15 s is excused) — watch for false cancels after a fallback click.
8. Hands-free: say "yes" after the confirm question has finished playing (overlap with Clicky's voice is
   dropped as echo); "stop" cancels a running batch even while Clicky is quiet.
9. `code_task {project:"…"}` → the named-project lookup (alias / confident / pick card) and code mode's
   own gates; without a project and code mode off → "code mode is off".
10. Debug inbox: `{"cmd":"actionsRun","steps":[…]}` (dryRun defaults to true) returns each step's tier,
    reason and facts on a fresh capture; `"dryRun":false` runs it (no observe turn); `actionsStatus`,
    `actionsCancel`. Test-only `axSetPosition` / `axPerform` move / press in TextEdit or Notes only.
11. Settings: `v2.actions.enabled false` → `<actions>` gets "I can't do that yet." and the prompt has no
    ACTIONS section; `v2.actions.countdownSeconds 3` → a 3 s countdown.

## P8 article highlights and notes (`read_article`, sentence highlights, `notes`)

Unit-tested in ClickyCore (`ArticleTests`: sentence → range matching incl. quotes / case / whitespace /
hyphenation / OCR misreads, run maps, OCR lines → one rect per line, line fragments, off-screen ticks and
scroll tracking math, notes Markdown / file naming / save to a temp folder with PDF, dock side choice, the
DSL steps, tiers, the observe-turn text, `[NOTES:save]`, "save my notes", the prompt; renders of the notes
panel and a highlight overlay sample in `~/Library/Logs/Clicky/renders/article/`). These need the running app:
1. Chrome, a long local article, the owner says "highlight the important things and make notes": a
   `read_article` step ("read N characters via AX"), an observe turn carrying ARTICLE, then ONE block with
   highlight (5–8 verbatim sentences) + notes. Soft yellow strokes sit exactly on the sentences, one per
   line for wrapped sentences (no boxes); `notesStatus` shows each highlight's `method`
   (boundsForRange / textMarkers / elementFrame / ocr) and its line rects.
2. Scroll the page: the strokes follow within ~0.1 s; highlights scrolled away become numbered ticks at the
   top / bottom of the page's right edge, and the matching notes show ↑ / ↓. Resize the window: strokes are
   re-measured (≤ 0.75 s). Navigate to another page: the highlights clear.
3. The notes panel docks on the side of the Chrome window with the most free space on that display; with
   Chrome full-width it sits in the margin beside the article column, never over it. Move the window → the
   panel follows. Switch to another app → strokes and panel hide; back to Chrome → they return. Clicking the
   panel never activates Clicky or takes focus from Chrome.
4. Click a note: the page scrolls that highlight into view (AXScrollToVisible; nothing on the page is clicked,
   selected or edited). A note whose sentence wasn't found is dimmed and not clickable.
5. The summary at the top of the panel is spoken once (by the answer's line, or by Clicky if the answer
   didn't say it — never twice).
6. "save my notes" (push-to-talk and hands-free) → `~/Clicky Notes/<title>.md` + `.pdf`; Clicky says where;
   the panel footer shows the path. Saving again in the same session overwrites the same files; a file of
   that name from elsewhere gets "<title> 2.md". `[NOTES:save]` in an answer does the same and isn't spoken.
   `notesSave` in the debug inbox returns `{line, savedPaths}`.
7. Fallbacks: a page whose web area has no text (canvas / image) → with `v2.article.scrollOCRFallback` on,
   `read_article` scrolls the article page by page (tagged scroll events only), OCRs it and scrolls back;
   `articleRead {scroll:true}` reports `source: OCR`. Highlights on such a page come from OCR of the visible
   viewport only.
8. The live failure this fixes: with a terminal (the harness) frontmost and Chrome behind it, read_article /
   highlight still target Chrome's front window (ArticleWindowChoice), not the terminal. Safari is refused
   unless the request names it.
9. Debug inbox: `articleRead` → {length, title, url, source AX|OCR, runs, milliseconds, preview};
   `notesStatus` → panel visible, items, linked notes, highlights, dock side/frame, saved paths.
