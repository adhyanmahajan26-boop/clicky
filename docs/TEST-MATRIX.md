# Theo test matrix

Final pass, 2 November 2026, on the build in this commit.

✅ done and looked at. ⚠️ works as far as could be tested, the gap is stated. ❌ doesn't work.

How to read the evidence: screenshots are of Theo's own window, in `docs/evidence/final/`. Clicks go through the app's own event path in a test profile (`docs/TESTING.md`), because the owner's mouse and focus are off limits.

**This matrix is not all green.** The ⚠️ rows are real gaps. The biggest: a physical mouse click on the real window hasn't been done by me, only by the app's own events.

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

ClickyCore 1,076 passed, app 68 passed, on this commit. No failures.

## Videos

- Real demo: Theo's own window, recorded as frames. A true screen recording was blocked by this Mac's permission rules, so window frames were used. Clicky's cursor keeps itself out of captures, so it is drawn from its own log at the exact spot.
- Promo: recreated screens in HyperFrames.
