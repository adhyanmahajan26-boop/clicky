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

- Clicky's team: `clickyTeam` (the team, its category and recent jobs), `clickyTeam {action: "delegate", duty, task}`, `clickyTeam {action: "order", text}` (the CEO's order to Clicky), `clickyTeam {action: "memorySearch", query}`. `ask {text, speak: false, owner: true}` is a message typed in Clicky's chat.
- Voice: `uiDictationFeed {path, app, window}` (a sound file through dictation into a background window), `uiDictationField`, `uiDictationStatus`, `uiDictationPill {state}`, `uiDictationKeys {flags}`; `uiCallStart`, `uiCallFeed {path, silence}`, `uiCallStatus`, `uiCallMute`, `uiCallEnd`; `uiSpeak`, `uiSpeakStop`; `uiSet {key, value}`, `uiTestKey {provider, value}`.

`Tools/theo-click-test.py <out>` is the regression pass over the main screens.

To use Accessibility and Speech, start the profile through LaunchServices (`open -g -n Clicky.app --args --profile test-x`), not from a shell, so the app answers for its own permissions. Never ask for a permission in a test.

With no Sarvam key: `Tools/mock-sarvam.py` stands in for its REST and sockets. Set `uiSet test.sarvam.base = http://127.0.0.1:8765` and `uiTestKey {provider: "sarvam", value: "anything"}`. For a live test with the owner's saved key: `uiSet test.sarvam.useOwnerKey = true` (the key is read where it is, never copied or shown).

## Rules
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
