# Theo test matrix

Final pass, round 2 and round 3, 2 November 2026, on the build in this commit.

✅ done and looked at. ⚠️ works as far as could be tested, the gap is stated. ❌ doesn't work.

How to read the evidence: screenshots are of Theo's own window, in `docs/evidence/final/`. Clicks go through the app's own event path in a test profile (`docs/TESTING.md`), because the owner's mouse and focus are off limits.

**This matrix is not all green.** The ⚠️ rows are real gaps. The biggest: a physical mouse click on the real window hasn't been done by me, only by the app's own events.

## Round 5 (2026-11-14): the stranger test

Theo as a brand new user meets it: a fresh profile, its own home folder, no coding agent, nothing of the original developer's (theo-fix-plan package 11). Mac: `Tools/tests/stranger_mac.py`; Windows and Linux: `crossplatform/tests/stranger.py` (see `AGENTS.md`). Run on branch `integration/any-user-all`. GitHub Actions started no job that night (billing), so the Mac and Windows columns wait for CI.

| | What | Linux | Windows | Mac |
|---|---|---|---|---|
| ✅ | First run finishes with only an API key, and Theo answers on it (and uses the echo app on it) | ✅ | not run | not run |
| ✅ | The owner's name from setup is in bots' prompts; "Addy" is in no prompt and no file | ✅ | not run | not run |
| ✅ | The echo app added in Connectors, given to a bot, used in a turn, with no Claude Code | ✅ | not run | not run |
| ⚠️ | A project folder outside the default place, and a coding run there with a stand-in harness. On Windows and Linux the stand-in has to be Claude Code: coding runs there use nothing else yet | ✅ | not run | not run |
| ⚠️ | Two linked laptops: exactly one fires routines | Mac only | Mac only | not run (unit-tested in `BrowserResearchTests`) |

## Round 4 (2026-11-05): the bot harness

Everything ran in test profiles with Claude Haiku, or OpenCode free, or Cursor Auto. "Two profiles" means two linked test profiles on one Mac Studio, one of them standing in for the Air. The real Air is a separate pass: `AIR-TESTS.md` in the evidence folder. Evidence is under `~/jstest/theo-ui/harness-core/` (`evidence/live/`, `shots/`).

| | What | Evidence |
|---|---|---|
| ✅ | Bot to bot: one collapsed card in the sender's chat, opens to both messages | `shots/dm-collapsed.png`, `dm-expanded.png` |
| ✅ | The other bot's own chat stays clean (0 new messages), the sender quotes the answer | `live/smoke-after-review.txt` |
| ✅ | A message with brackets in it arrives whole (`is arr[0] safe?`) | `live/smoke-after-review.txt` |
| ✅ | A second exchange remembers the first; threads sync between two profiles in the same order | `live/team1.txt`, `order-retest.txt` |
| ✅ | A word game between bots ends after 3 round trips | `live/team1.txt` |
| ⚠️ | The plain line at the limit didn't show live, because the models stopped first. Unit-tested only | `BotProtocolTests` |
| ✅ | A routine that messages two bots: one note, two cards, one result. Before: 3 or 4 full copies | `live/routine-brief.txt` |
| ✅ | A routine where Theo asks two group chats: one note, one result holding both answers. Before: a follow-up per group | `live/smoke-final-one.txt` |
| ✅ | Routines on both Macs: one made on the "Air" reaches the "Studio" in about a second and fires only there; its history shows on both; Pause and Delete from the "Air" apply on the "Studio" | `live/smoke-final-two.txt`, `live/smoke-routine-fires.txt` |
| ✅ | Theo has a group plan and build something: exactly one run, no stray folder | `live/smoke-final-one.txt` |
| ✅ | A continued T3 Code thread (fork, Haiku) stays one run, and the same thread carries on | `live/smoke-final-one.txt` |
| ✅ | A run sent to the other Mac reports that Mac's real answer: refused for a missing folder, started for a real one | `live/smoke-final-two.txt` |
| ✅ | Other Mac away and the run continues a chat there: no "run it here", and the chat says why | `live/smoke-final-two.txt` |
| ✅ | Bots & coding set to the Studio: "where you are" names both Macs and why, and the run card defaults to the Studio | `live/smoke-final-two.txt` |
| ✅ | New folder with a name that exists: a clear note, and nothing else is made or picked | `live/new-folder-existing.txt`, `shots/existing-folder.png` |
| ✅ | Restarting Theo doesn't mark everything as just changed, so the Mac started last no longer overrides newer edits | `live/smoke-routine-fires.txt` |
| ⚠️ | Unit-tested or read in the code, not forced live: a private turn run on the other Mac, the member waiting when the owner speaks, a continued chat whose message never went in, git failing on a new folder, continuing with a remote latest run, the chats list in a group turn | unit tests where testable |
| ✅ | Group: one at a time, later bots refer to earlier ones, one wrap-up | `live/smoke-after-review.txt`, `shots/group-chat.png` |
| ✅ | Stop on a group stops all of it at once | `live/group2.txt` |
| ✅ | Build discussion: plan, a critique from each, merge, exactly one run, no stray folder | `live/smoke-build-isolated.txt` |
| ✅ | One way to write: `[TELL: name: msg]`, `@Name` only in groups; assembled prompts unit-tested | `BotProtocolTests` |
| ✅ | Purpose: a bot asked about someone else's work passes it to them | `live/team1.txt` |
| ✅ | Where you are / who you are on every bot turn; right Mac named on both profiles | `live/devices1.txt`, unit tests |
| ✅ | A folder and a run stay on the Mac they were asked on | `live/devices2.txt` |
| ✅ | A run sent to the other Mac shows on both; a follow-up reaches that exact run | `live/devices2.txt`, `devices3.txt` |
| ✅ | Engine missing here: answered on the other Mac and says so | `live/devices2.txt` |
| ✅ | Other Mac offline: the chat says so at once, "Run it here" works, a queued message goes once on reconnect | `live/devices3.txt`, `devices4.txt`, `shots/waiting-card.png` |
| ✅ | Routing: reachable / unreachable with an engine here / with none here | `DeviceRoutingTests` |
| ✅ | Reconnect merge: no duplicates, no reordering, same-second messages, catch-up cap | `BotChatMergeTests`, `live/order-retest.txt` |
| ✅ | Bot memory moved out of `~/.t3`, written with the bot's real permission, synced | `live/order-retest.txt` |
| ✅ | Devices settings read right on both profiles | `shots/devices-settings-air.png`, `-studio.png` |
| ✅ | Folder menu on a run's card: recent projects, New folder…, Choose a folder…; every harness | `live/click-test.txt`, `shots/folder-popover-final.png`, `card-final-new.png` |
| ⚠️ | The macOS panel behind Choose a folder… wasn't opened, because it takes focus. `canCreateDirectories` is set in code | `RunChoices.swift` |
| ✅ | PR run on theo-pr-sandbox: draft PR #15 | `live/pr-run.txt` |
| ✅ | Continue a chat: Claude Code | `live/chats1.txt`, `shots/continued-run.png` |
| ✅ | Continue a chat: T3 Code fork | `live/chats1.txt` |
| ✅ | Continue a chat: OpenCode free | `live/opencode.txt` |
| ✅ | Continue a chat: Codex | `live/continue-codex.txt` |
| ✅ | Continue a chat: Grok | `live/continue-codex.txt` |
| ✅ | Continue a chat: Cursor, on Auto | `live/continue-cursor-auto.txt` |
| ⚠️ | Continue a chat: Gemini is not signed in on the Studio and has no chats. Reader unit-tested only | `HarnessChatFilesTests` |
| ⏳ | Continue a chat: stock T3 Code on the Air, with stock left stock | `AIR-TESTS.md` |
| ✅ | A plan limit shows the real reason: "Cursor Agent can't run this on your plan: …" | `live/smoke-after-review.txt` |
| ✅ | Each new run keeps its own chat: Grok takes its id up front, Cursor gets one from `create-chat`, and both continue in that same chat | `live/chat-identity.txt` |
| ✅ | Each new run keeps its own chat: two OpenCode runs started at once in one folder take turns and end with their own chats | `live/chat-identity.txt` |
| ⚠️ | Same, for Gemini (`--session-id`) and Codex (takes turns): unit-tested only. Gemini isn't signed in here, and Codex is off limits in this job | `HarnessChatGateTests`, `TheoProductionTests` |
| ⚠️ | "Couldn't tell which chat it made" on a run's card, and the follow-up that won't guess: the logic is unit-tested, the card wasn't made to show it live | `HarnessChatGateTests` |
| ✅ | Research with the Macs apart runs on this Mac and says so, without waiting | `live/research-apart.txt` |
| ✅ | A bot's research sent to the other Mac brings the real brief back to that bot. Before: "didn't come back", or an old brief | `live/research-apart.txt` |
| ✅ | Upgrade: the release build opens a copy of the Studio's real data. 14 of 14 bots, 8 runs, 6 routines, 12 chats and 507 messages match, nothing starts by itself, and memory files move byte for byte. No model calls | `live/upgrade-real-data.txt` |
| ⏳ | All of it on the real Air, on another network | `AIR-TESTS.md` |

With the Macs apart, two things still can't run here. A routine set up on the Air waits for the Mac that fires routines, and the chat says so. Hidden screens exist only on a Mac Studio, and a bot says so at once.

Tests on the final commit: ClickyCore 1,255 passed, app 100 passed.

## Round 3 (2026-11-02): Clicky's team

Quick checks on Haiku (Clicky and Theo on Sonnet) in a test profile, one per flow. Screenshots: `~/jstest/theo-final/round3/`.

| What | Result | Evidence |
|---|---|---|
| Category "Clicky" with Clicky as manager, new setup | ✅ | `clickyTeam`: leader clicky, items clicky + 3 bots, Theo alone pinned; `sidebar-and-org-chart.png` |
| Org chart: members → Clicky → Theo | ✅ | `sidebar-and-org-chart.png` |
| Memory: "remember…" through Clicky's brain | ✅ 4 s | Memory card done; found again later ("what did I say about…") in 4 s; `delegation-card-done.png` |
| Researcher: "research…" | ✅ 22 s | Avatar lit, pages in its chat, cited brief on a card; `t2-clicky-chat.png` |
| Runner: "tell Ada to…" | ✅ 9 s | Hand-off shows in Ada's chat, her answer on Runner's card |
| Hidden helper after removing Runner | ✅ 6 s | Card reads "A hidden helper"; same hand-off to Ada |
| "Clicky, point at…" typed to Theo | ✅ 6 s | Order card and Clicky's report in Theo's chat |
| Theo on his own, `[CLICKY: …]` | ✅ 5 s + 3 s | Theo → Clicky → Memory, both reports in Theo's chat |
| Order on a call (synthetic speech) | ✅ 10 s | The tag isn't read aloud; Clicky's report came back and Theo spoke it |
| Report to Theo: sub-bots → Clicky → Theo | ✅ | Three reports in Clicky's chat, the roll-up in Theo's |
| Unit tests | ✅ 1,113 in ClickyCore | `swift test` |

Not run live: a coding run started through Runner (the path it joins is the one the PR tests already cover), and pointing as seen on screen (overlays don't run in a test profile).

Found and fixed by these checks: Clicky's chat redrew forever and froze the window (a publisher re-subscribed in `body`); Memory filed a plain statement as a lookup; Clicky answered "nothing saved" from its short memory note instead of asking Memory.

## Round 2 (build 202611021157): teams, characters, managers, dictation, Clicky's voice, calls

Small tests only, on Haiku and Sonnet, in a test profile with synthetic speech. No real mic, no real key presses and no Sarvam key were used. Screenshots: `~/jstest/theo-final/round2/`.

| | What | Evidence |
|---|---|---|
| ✅ | Sidebar: team headers (tile, group glyph, semibold, manager, count, chevron), bots indented under a guide line, dark and light | `sidebar-orgchart-*.png` |
| ✅ | 16 characters with their own silhouettes, in the New bot gallery. Theo and Clicky keep their marks | `icon-gallery-new-bot-dark.png` |
| ⚠️ | The same picker in bot settings: built, the popover wasn't looked at | |
| ✅ | Manager, live on Haiku: Bo and Cy report to Ada's chat (5.4 s, 2.2 s), Ada rolls up to Theo's chat (5.4 s, 13 s in all), nothing from members straight to Theo, and Theo used the roll-up when asked | run log |
| ⚠️ | No-manager path and DMs rerouted to the manager: built on the old path, not run live this round | |
| ✅ | Dictation on synthetic audio into a background TextEdit window: words 0.13 to 0.2 s after release, Haiku done 1.6 s later, typed through Accessibility, focus never moved | `dictation-textedit-result.png` |
| ✅ | Slow clean-up: raw words go in, Haiku's version replaces them when it lands; a second sentence gets its own space | status log |
| ✅ | The real app's key listener is running with Accessibility | `dictationStatus` |
| ⚠️ | A physical hold of Control + Fn: never pressed. The chord logic is unit tested, including that Clicky's Control + Option can't trigger it | |
| ⚠️ | This Mac's Globe key opens Emoji & Symbols. Whether that pops up after the chord can't be known without a real press. Settings explains it and offers shortcuts without Fn | |
| ⚠️ | Paste route (apps with no Accessibility): shared with type-for-me, not run here because tests keep off the owner's clipboard | |
| ⚠️ | Apple's recognizer on Hinglish is weak with a synthetic voice: "kal meeting hai" became "Call meeting, hi". Sarvam is the fix, not yet tried | |
| ✅ | Clicky's voice picker: Sarvam by language, speakers, pace; Mac voices; ElevenLabs when a key exists | `voice-picker-*.png` |
| ✅ | Stop: the voice went quiet 3.5 ms after the call | `uiSpeakStop` |
| ✅ | Call on Sonnet with Apple listening and the Mac voice. First sound after the voice stops: 3.93, 4.23, 2.81, 1.81 s. About 0.6 s of that is the wait to be sure Addy finished, the rest mostly Sonnet's first words | call run |
| ✅ | Barge-in: the voice stopped about 0.38 s after the speech began, the reply marked as cut, the new question answered. Mute: nothing heard. Transcript lands in Theo's chat | `call-window-*.png` |
| ⚠️ | Live mic and echo cancelling on a real call: not run. The engine is the one hands-free uses | |
| ⚠️ | Sarvam live, everything: no key saved. REST, both listening sockets, the voice socket, realtime refused → standard socket, linear16 refused → MP3 all ran against `Tools/mock-sarvam.py`, written from Sarvam's docs. That proves Theo's side, not Sarvam's. Time to first audio on Sarvam is unknown | mock log |

Found on the way: `open` passes on its caller's environment, so a Theo started from a Claude Code session handed that session's variables to every CLI (2 to 4 s slower per turn). Theo now clears them at launch. Earlier numbers in this file may have paid that cost.

Tests: ClickyCore 1,095 passed, app 80 passed.

## Clicking

| | What | Evidence |
|---|---|---|
| ✅ | Regression click pass over Settings, sidebar, New bot, API keys: 25/25 | `Tools/theo-click-test.py` |
| ✅ | First click accepted everywhere sampled: Home 672/672, keys page 672/672 (was refused on about 60%) | `uiFirstMouse` |
| ✅ | Settings opens inside the window, on the page asked for, also on first open | setup tester |
| ⚠️ | Physical mouse click on the real window | owner to confirm |
| ⚠️ | Pickers, context menus, drag gestures | what they set is tested; the gestures can't be driven in an inactive app |

## Harness cards

| | What | Evidence |
|---|---|---|
| ✅ | Seven cards with real logos, version, account, plan | `harnesses-emails-blurred.jpg` |
| ✅ | Sign in inside Theo's terminal: link and code shown, Copy works, card flips by itself, sheet closes (stand-in CLIs for Claude, Codex, Gemini) | `signin-sheet.jpg`, real demo video |
| ✅ | Sign out asks first, runs the CLI's logout, card flips | settings tester |
| ✅ | Failed sign-in stays open with the error and the real exit code | settings tester |
| ✅ | Re-check; "Use my API key instead" goes to the keys page | settings tester |
| ✅ | Gemini CLI really installed through its card (8 s) | earlier live run |
| ⚠️ | Real browser sign-in, all harnesses: not completed, most are already signed in. Gemini waits on the owner's Google sign-in | |
| ⚠️ | T3 Code Connect self-test: its button would edit real configs, so it's checked by the real app's earlier install only | |

## Models and API keys

| | What | Evidence |
|---|---|---|
| ✅ | 19 providers plus custom, each with logo, field, reveal, Paste, Save, Test, Remove, Get a key | `keys.jpg` |
| ✅ | Bad key gives the provider's clear error on 13 providers; keys never in logs or defaults | settings tester, real demo video |
| ✅ | Save to Keychain, masked, survives restart, Remove asks first | settings tester |
| ✅ | Custom provider through the real sheet: bad URL message, works, dead port message | settings tester |
| ✅ | A bot on a custom API streams, keeps its history (local test server) | earlier live run |
| ✅ | Local providers: Ollama says it isn't running, LM Studio lists 3 models | settings tester |
| ⚠️ | Real calls with a good key: no keys on this Mac yet. Sarvam waits on the owner pasting their key | |
| ⚠️ | Harness on an API key, ElevenLabs, Deepgram, AssemblyAI voices: unit tested only, no keys | |

## Bots and runs

| | What | Evidence |
|---|---|---|
| ✅ | Real draft PRs on the final cards in a private sandbox: Claude #10 20 s, Codex #11 28 s, Cursor #12 64 s, Grok #13 40 s, T3 #14 24 s, all with Theo's own test run passing | theo-pr-sandbox, real demo video |
| ✅ | Run card in plain words: steps with progress, status from the agent, Stop, terminal behind "Show terminal" | `run-card-terminal.jpg` |
| ✅ | Result card: done chips, files, tests, Open PR, the agent's report folded up, a box for a change | `result-card.jpg` |
| ✅ | A change typed on the card lands on the same branch and PR, 32 s | PR #10, 2 runs |
| ✅ | Settings card in chat: "what model are you on", "switch to sonnet", "turn on thinking" answered with a working card and no model call. Ordinary messages stay ordinary (unit tests) | `settings-card.jpg` |
| ✅ | A normal bot asked in plain words hands off to a harness and opens a PR, 71 s | #6 |
| ✅ | PR targets the branch it was cut from | #7 |
| ✅ | Subfolder of a repo: worktree of the repo, owner's uncommitted work untouched | review flows |
| ✅ | Words like @codemirror or dev@code.org start nothing; the bot answers | review flows |
| ✅ | Env files and keys stay out of commits and off GitHub | unit tests, review flows |
| ✅ | Unpushed commits of the owner's aren't published; the card says why | review flows |
| ✅ | Stop on the card asks, stops in under a second, keeps the work, focus never moved | review flows |
| ✅ | Follow-up after Stop carries on in a new terminal, conversation continued | review flows |
| ✅ | OpenCode with its free limit used up: says so in plain words, offers another harness | `opencode-limit.jpg` |
| ⚠️ | Cursor cloud agent: unit tested only, needs a Cursor API key | |
| ✅ | New bot from stencil, Sonnet by default, model picker in the sheet | `new-bot.jpg`, bots tester |
| ✅ | Every inspector field that can be driven persists across restart | bots tester |
| ✅ | Chat streams, remembers, Stop keeps partial text, long reply scrolls | bots tester |
| ✅ | Categories: leader reports to the CEO, no leader means everyone reports, delete keeps the bots | bots tester |
| ✅ | Group chats: head hands out work and merges; delete asks first and lands on Home | bots tester |
| ✅ | Routines: from chat, New routine, Run now, pause, resume, history, delete | `routines.jpg`, bots tester |
| ✅ | Connectors: logos and status for all ten, read only | `connectors.jpg`, bots tester |
| ⚠️ | Real file drop, the + file panel, sidebar right-click menus, real drag | their actions are tested, the gestures can't be driven |

## Clicky

Numbers are from the real app with the real voice at zero volume. Nothing was audible, except one test question at about 02:33 that ran unmuted.

| | What | Number |
|---|---|---|
| ✅ | Time to first audio, short answers | median 4.3 s, worst 6.6 s (first text 2.4 to 2.8 s, Theo's voice 1.6 to 1.9 s). Measured before the voice's leading silence was trimmed, which removes up to 0.6 s more |
| ✅ | Long answers play to the last word | 233, 290, 317 words over 90, 113, 138 s, no fallback |
| ✅ | Interrupt: Esc, push-to-talk, the word "stop" | at most 0.14 s |
| ✅ | New question cuts off the old answer and gets its own | yes |
| ✅ | Pointing with the cursor on another monitor | `[POINT:398,560:Saturn:screen3]`, the spot on the right monitor. Before the fix it landed on the main monitor |
| ✅ | Marks | box marks tight, points within 4 pt on 5 of 6 hard tests. Test 1 used numbered marks with the right notes, not underlines (`build/eval/hard10`) |
| ✅ | Hard tests: research on Google, Hacker News, Wikipedia, sub-agents, topic; 3 Haiku workers; whiteboard; side board; no board for simple; article highlights (8); silent | `build/eval` logs |
| ✅ | Search action on Theo's screen, focus handed back | 0.12 s |
| ✅ | Unreadable pages are named in the brief, not guessed at | real demo video |
| ⚠️ | Named-site research on Google: passed earlier, not re-run on the very last build | |
| ⚠️ | Wake word | 13/16 on synthetic voices (was 4/16), 1 false wake in 32. Not tested on the owner's own voice. "hey Siri" also wakes Theo |
| ⚠️ | Voice quality | 6 sentences transcribed back correctly except "Sonnet" before a number. −20 to −23.5 LUFS, no clipping. Judged by Whisper and levels, not by ear |
| ⚠️ | Clicky on an API brain | no keys |

## Polish

| | What | Evidence |
|---|---|---|
| ✅ | Idle CPU of the window: Home 10.6 to 14.8%, chat 3.9 to 14%, Settings 0.1% (Home was 15 to 30%) | sampled |
| ✅ | Light and dark looked at, screen by screen | `docs/evidence/final/` |
| ⚠️ | Idle CPU still 4 to 14% with bots on screen | |
| ⚠️ | Reduce Motion: respected in code in more places; the system setting wasn't flipped | code |

## Tests

ClickyCore 1,076 passed, app 68 passed, on the final pass's commit. No failures. Round 2's counts are above.

## Videos

- Real demo: Theo's own window, recorded as frames. A true screen recording was blocked by this Mac's permission rules, so window frames were used. Clicky's cursor keeps itself out of captures, so it is drawn from its own log at the exact spot.
- Promo: recreated screens in HyperFrames.
