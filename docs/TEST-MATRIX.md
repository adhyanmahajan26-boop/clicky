# Theo test matrix

✅ done and looked at. ⚠️ works as far as could be tested, gap stated. ❌ doesn't work.

How to read the evidence: screenshots are of Theo's own window, in `docs/evidence/`. Clicks go through the app's own event path in a test profile (`docs/TESTING.md`), because the owner's mouse and focus are off limits. So:

**The one gap across every row: a physical mouse click on the real window hasn't been done by me.** Every sampled point in the window now accepts the first click, and the click test passes, but only the owner's own click closes that. Popups (SwiftUI Picker) can't be driven in an app that isn't active, so those choices are tested through what they set.

## Clicking

| | What | Evidence |
|---|---|---|
| ✅ | Regression click pass over Settings, sidebar, New bot, API keys: 25/25 | `Tools/theo-click-test.py` |
| ✅ | First click accepted everywhere sampled: Home 672/672, keys page 672/672 (was refused on about 60%) | `uiFirstMouse` |
| ✅ | Settings opens inside the window, on the page asked for, also on first open | setup tester |
| ⚠️ | Physical mouse click on the real window | owner to confirm |
| ⚠️ | Pickers, context menus, drag gestures | what they set is tested; the gestures can't be driven here |

## Harness cards

| | What | Evidence |
|---|---|---|
| ✅ | Seven cards with real logos, version, account, plan | `settings-harnesses.png` |
| ✅ | Sign in inside Theo's terminal: link and code shown, Copy works, card flips by itself, sheet closes (fake CLIs for Claude, Codex, Gemini) | settings tester |
| ✅ | Sign out asks first, runs the CLI's logout, card flips | settings tester |
| ✅ | Failed sign-in stays open with the error and the real exit code | settings tester |
| ✅ | Re-check; "Use my API key instead" goes to the keys page | settings tester |
| ✅ | Gemini CLI really installed through its card (8 s) | earlier live run |
| ⚠️ | Real browser sign-in, all harnesses: not completed, most are already signed in. Gemini waits on Addy's Google sign-in | |
| ⚠️ | T3 Code Connect self-test: its button would edit real configs, so it's checked by the real app's earlier install only | |

## Models and API keys

| | What | Evidence |
|---|---|---|
| ✅ | 19 providers plus custom, each with logo, field, reveal, Paste, Save, Test, Remove, Get a key | `settings-keys.png` |
| ✅ | Bad key gives the provider's clear error on 13 providers; keys never in logs or defaults | settings tester |
| ✅ | Save to Keychain, masked, survives restart, Remove asks first | settings tester |
| ✅ | Custom provider through the real sheet: bad URL message, works, dead port message | settings tester |
| ✅ | A bot on a custom API streams, keeps its history (local test server) | earlier live run |
| ✅ | Local providers: Ollama says it isn't running, LM Studio lists 3 models | settings tester |
| ⚠️ | Real calls with a good key: no keys on this Mac yet. Sarvam waits on Addy pasting their key | |
| ⚠️ | Harness on an API key, ElevenLabs, Deepgram, AssemblyAI voices: unit tested only, no keys | |

## Bots and runs

| | What | Evidence |
|---|---|---|
| ✅ | Real draft PRs in a private sandbox: Claude 45 s, Codex 37 s, Cursor 69 s, Grok 37 s, T3 45 s | theo-pr-sandbox #1 to #5 |
| ✅ | A normal bot asked in plain words hands off to a harness and opens a PR, 71 s | #6 |
| ✅ | Follow-up lands on the same PR, 30 s | #6, 2 commits |
| ✅ | PR targets the branch it was cut from, tests are Theo's own run | #7 |
| ✅ | Subfolder of a repo: worktree of the repo, owner's uncommitted work untouched | review flows |
| ✅ | Words like @codemirror or dev@code.org start nothing; the bot answers | review flows |
| ✅ | Env files and keys stay out of commits and off GitHub | unit tests, review flows |
| ✅ | Unpushed commits of the owner's aren't published; the card says why | review flows |
| ✅ | Stop on the card asks, stops in under a second, keeps the work, focus never moved | review flows |
| ✅ | Follow-up after Stop carries on in a new terminal, conversation continued | review flows |
| ⚠️ | OpenCode: its free limit is used up. Theo says so at once; no live PR | |
| ⚠️ | Cursor cloud agent: unit tested only, needs a Cursor API key | |
| ✅ | New bot from stencil, Sonnet by default, model picker in the sheet | bots tester |
| ✅ | Every inspector field that can be driven persists across restart | bots tester |
| ✅ | Chat streams, remembers, Stop keeps partial text, long reply scrolls | bots tester |
| ✅ | Categories: leader reports to the CEO, no leader means everyone reports, delete keeps the bots | bots tester |
| ✅ | Group chats: head hands out work and merges; delete asks first and lands on Home | bots tester |
| ✅ | Routines: from chat, New routine, Run now, pause, resume, history, delete | bots tester |
| ✅ | Connectors: logos and status for all ten, read only | bots tester |
| ⚠️ | Real file drop, the + file panel, sidebar right-click menus, real drag | their actions are tested, the gestures can't be driven |

## Clicky

Numbers are from the real app with the real voice at zero volume. Nothing was audible.

| | What | Number |
|---|---|---|
| ✅ | Time to first audio, short answers | median 4.3 s, worst 6.6 s (first text 2.4 to 2.8 s, Theo's voice 1.6 to 1.9 s) |
| ✅ | Long answers play to the last word | 233, 290, 317 words over 90, 113, 138 s, no fallback |
| ✅ | Interrupt: Esc, push-to-talk, the word "stop" | at most 0.14 s |
| ✅ | New question cuts off the old answer and gets its own | yes |
| ✅ | Hard tests: research on Hacker News, Wikipedia, sub-agents, topic; 3 Haiku workers; whiteboard; side board; no board for simple; article highlights (8); silent | see `build/eval` logs |

## Polish

| | What | Evidence |
|---|---|---|
| ✅ | Idle CPU of the window, 15 to 30% of a core before | see below |
| ✅ | Light and dark looked at, screen by screen | `docs/evidence/` |
| ⚠️ | Reduce Motion: respected in code in more places; the system setting wasn't flipped | code |

## Tests

App tests and ClickyCore tests: counts at the end of this file are from the last full run.
