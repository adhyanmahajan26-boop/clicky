# Testing Theo without touching the owner's Mac

Theo has a test profile: `Clicky --profile test` (or `test-<name>` for another one beside it). It's the same app with its own home folder (`~/Library/Application Support/Theo-Test[-name]/home`), preferences domain, Keychain service and pasteboard. It stays out of the Dock and menu bar, never takes focus, and doesn't start the mic, spark overlay, pill or key tap.

`Tools/theoui.py` drives it. Clicks are real AppKit events sent from inside the app, so hit testing and controls behave for real, but the owner's pointer never moves.

```
export THEOUI_PROFILE=clicks        # your own instance; leave unset for the default one
export THEOUI_OUT=/some/folder      # where screenshots go
python3 Tools/theoui.py start       # or: start /path/to/Clicky
python3 Tools/theoui.py shot NAME   # screenshot of Theo's window only (2x, points*2 = pixels)
python3 Tools/theoui.py text        # the words on screen with their boxes in window points
python3 Tools/theoui.py clicktext "Words" [index]
python3 Tools/theoui.py cmd '{"cmd":"uiState"}'
python3 Tools/theoui.py stop
```

Commands for `cmd`:
- `uiState`, `uiWindows`, `uiMenus`, `uiHitMap`, `uiFirstMouse {step}`
- `uiGo {pane}`: home, notes, connectors, routines, clicky, `bot:<id>`, `group:<id>`, `category:<id>`, `settings:<look|clicky|coding|keys|voice|screen|permissions|updates|about>`
- `uiClick {x, y}` in window points from the top left; `uiHover`, `uiScroll {x, y, dy}`, `uiType {text}`, `uiKey {key, modifiers}`
- `uiMenuChoose {x, y, item}`: clicks a picker or menu and picks an item (omit `item` to list them). `uiRightClickChoose` for context menus.
- `uiResponderAction {action}`: e.g. `paste:`; `uiPasteboard {text}` sets the profile's private pasteboard.
- `uiBots {action, ...}`: addCategory, move, pin, hide, leader, report, deleteCategory (what drags and context menus do).
- `uiShowPanel` (the menu-bar panel), `uiStopRun {id}`.
- App commands: `botCreate`, `botUpdate`, `botDelete`, `botSay {bot, text}`, `botChat {id, limit}`, `botsState`, `groupSave`, `groupDelete`, `routines {action, id}`, `harnessState {refresh}`, `harnessSet {codingTarget, codingModel, codingEffort, defaultHarness}`, `terminalText {id}`.

- Runs: `uiRunStart` (with `await: true` it answers whether the run really started), `uiRunFollowup`, `uiChatsList {harness, folder}` (what the Chat menu offers), `uiRunPane {run}` (the screen of a run's terminal, what Watch shows).
- Crew and Studio: `uiSeedDemo` (a team and a chat with every card), `uiCrew {pointer: {x, y}}` (a stand-in pointer in window points, the real one stays put; `{pointer: null}` lets go), `uiStudio {action: on|off|state|panel|assign|clear, botID or botName, screen, tile}`, `uiSetDefaults {key, value}`. `test.studio.model` set before launch tests the Mac Studio gate. Boops need `uiClick`; `uiClickPost` doesn't reach a sheet.
- Clicky's team: `clickyTeam` (the team, its category and recent jobs), `clickyTeam {action: "delegate", duty, task}`, `clickyTeam {action: "order", text}` (the CEO's order to Clicky), `clickyTeam {action: "memorySearch", query}`. `ask {text, speak: false, owner: true}` is a message typed in Clicky's chat.
- Voice: `uiDictationFeed {path, app, window}` (a sound file through dictation into a background window), `uiDictationField`, `uiDictationStatus`, `uiDictationPill {state}`, `uiDictationKeys {flags}`; `uiComposerDictation {action: state|toggle|stop|cancel|dismiss|feed|key|cursor|permissions}` (the composer's dictation: `feed {path, realTime, stopAtEnd}` sends a sound file down the mic's path, `key {key, up}` runs a key through the real handling, `permissions {microphone, speech}` forces a status, `noMic {on}` runs the no-usable-mic path, and the profile never opens the mic); `uiCallStart`, `uiCallFeed {path, silence}`, `uiCallStatus`, `uiCallMute`, `uiCallEnd`; `uiSpeak`, `uiSpeakStop`; `uiSet {key, value}`, `uiTestKey {provider, value}`.

- Bots and harnesses: `uiBotPrompt {bot, room?}` (everything a bot is told, as it would go out), `uiChatsList {harness, folder}` (what the Chat choice offers), `uiRunStart {prompt, title, folder, harness, model, effort, room, mac, chat}` (what Start on a run's card does), `uiRunFollowup {run, text}`, `uiGroupStop {id}`. `botChat` returns `at`, `card`, `exchange` and `run` too; `botsState` returns `replyingIn` and the live exchanges and private threads.

`Tools/theo-click-test.py <out>` is the regression pass over the main screens.

## Two Macs on one Mac

Two test profiles can stand in for two Macs, each with its own home folder and `~/Projects`, over a real Theo Link on ports of their own. Neither touches the owner's pairing, since a test profile links by address only:

```
defaults write com.personal.clicky.test-mba test.link.name "Adhyan’s MacBook Air"
defaults write com.personal.clicky.test-mba test.studio.model "MacBookAir10,1"
defaults write com.personal.clicky.test-mba v2.setup.completed -bool true
defaults write com.personal.clicky.test-mba v3.bots.freshStart -bool true
# in one profile: uiLink {action: start, port: 47401}, which returns the code
# in the other: uiLink {action: start, code, port: 47402, dialHost: "127.0.0.1", dialPort: 47401}
```

`uiLink {action: down | up | state}` takes the link away and brings it back. A profile needs `up` after a restart. `uiSetDefaults {key: "test.engines.missing", value: ["claude"]}` makes an engine count as signed out on that side. Both profiles share one disk, so a folder check can't tell them apart: test a refused folder with a path that doesn't exist anywhere.

To use Accessibility and Speech, start the profile through LaunchServices (`open -g -n Clicky.app --args --profile test-x`), not from a shell, so the app answers for its own permissions. Never ask for a permission in a test.

Products: a fresh test profile has nothing on until Setup's "Pick products" step (or `v2.setup.completed`, which keeps all three on). `uiSetDefaults {key: "test.demos.time", value: 4.5}` holds every product demo at that second for a screenshot; remove it to let them loop. Dictation is blocked without a Sarvam key: `uiTestKey {provider: "sarvam", value: "anything"}` unblocks it (restart the profile so the cached key list sees it).

With no Sarvam key: `Tools/mock-sarvam.py` stands in for its REST and sockets. Set `uiSet test.sarvam.base = http://127.0.0.1:8765` and `uiTestKey {provider: "sarvam", value: "anything"}`. For a live test with the owner's saved key: `uiSet test.sarvam.useOwnerKey = true` (the key is read where it is, never copied or shown).

## Rules
- A test profile can hold a copy of real bots signed in as the owner, so its routines never fire on schedule (`test.routines.run` overrides that). An older build has no such gate: pause routines in any copy it might read.
- A test profile's child processes get its home folder, so never start a browser from one: Chrome comes up as a new, empty copy.
- A coding agent started from a test profile has the owner's real HOME. Prompts in tests must say "the current folder", never `~/...`: a `~/Projects/x` in a prompt lands in the owner's real `~/Projects`.
- Studio screens drop the owner's monitors out of HDR while they exist, and each on or off nudges a monitor. Either can interrupt a video. Don't toggle them without the owner's OK that nothing's playing.
- Studio screens are real displays for the whole Mac while they're on, so keep tests short and check the real monitors are back after turning them off. Never turn on Live capture in a test.
- Agents started from a test profile keep the owner's real home, because their sign-ins live there, so `~` in a shell means the real one. Theo tells bots the profile's full Projects path and rewrites `~/Projects` in anything it sends an agent, but any other `~` path in a test prompt still reaches real folders. Say "the current folder" in test prompts.
- Never record the screen. Screenshots of Theo's window only (`theoui.py shot`). Never screenshot the whole display.
- Don't move the pointer, take focus or press real keys. Don't open apps.
- Never print, log or paste API keys.
- Don't sign out of, or finish signing in to, a real account. Don't open browser tabs.
- Bots run in the test profile only. Use cheap models (claude-haiku-5-5) unless testing a specific harness.
- GitHub: only `adhyanmahajan26-boop/theo-pr-sandbox`.
- Keep `/Applications/Theo.app` (the owner's running Theo) alone unless told otherwise.

## Known limits of this kind of test
- The app stays inactive, so the menu bar can't reach it: test a shortcut's action with `uiResponderAction`, and that the Edit menu has it with `uiMenus`.
- Real drags can't be synthesized: `uiBots` tests what a drop does, not the drag gesture.
- A physical first click on a background window can't be tested this way: `uiFirstMouse` shows every view accepts it.
