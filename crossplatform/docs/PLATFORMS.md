# What runs where

Theo on Mac stays the Swift app. This folder is Theo for Windows and Linux (and, optionally, a Mac build of the same thing):
one Rust engine and one Tauri window on all three. This page says, feature by feature, what each platform gets and why.

## Theo (the bots harness): all three platforms

| Piece | Mac | Windows | Linux | How |
|---|---|---|---|---|
| Bots, chats, group chats, private threads, routines | Yes | Yes | Yes | `theo-core`, the same code everywhere |
| Engine: Claude Code (`claude -p`) on your subscription | Yes | Yes | Yes | Claude Code runs on all three; Theo finds it on PATH, `~/.local/bin`, `%APPDATA%\npm` |
| Engine: OpenCode, Codex, Cursor Agent, Gemini CLI and Grok on your own subscriptions | Yes | Yes | Yes | `harness.rs` `run_on_engine`; each gets the connector hub for the turn (see Brains below) |
| Engine: API keys (Anthropic, OpenAI, Google Gemini, xAI, OpenRouter, Groq, Mistral, DeepSeek, Together, Fireworks, Cerebras; Ollama and LM Studio with no key), with tools | Yes | Yes | Yes | `apichat.rs`, `brains.rs` |
| API keys | Keychain | Credential Manager | A 0600 file (`Keys/`), as the gateway token | `secrets.rs` (`com.theo.desktop.apikeys`) |
| A stand-in when a bot's brain keeps failing | Yes | Yes | Yes | The owner's choice in Settings › Brains (`v3.bots.standInBrain`), else Claude Code when it's installed |
| Tool limits for bots (no shell, writes only in its folder, no cron, secrets unreadable) | Yes | Yes (paths written as `//c/Users/...`; see "Not yet verified") | Yes | Claude Code permission rules, same as the Swift app |
| Stop, time limit, ending everything an engine started | Process groups, SIGTERM then SIGKILL | Job Objects (the whole tree ends; also when Theo itself dies) | Process groups | `procs.rs` |
| Engines left running after a crash end at the next launch | Yes | Not needed: the Job Object ends them when Theo dies | Yes | `engines-running.json`, checked by start time and boot id |
| Crash-safe files (atomic writes, damaged files kept aside, last-good copy, rescue of a cut file) | Yes | Yes (rename retried while an antivirus holds the file) | Yes | `store.rs` |
| Caps on bots messaging each other (3 round trips, 12 per message), parallel lanes (4) | Yes | Yes | Yes | |
| Group turn order (head, members one at a time, one wrap-up, 8 turns max) | Yes | Yes | Yes | |
| Retry and fallback models, never on a sign-in error | Yes | Yes | Yes | |
| Routines, catch-up window, [SILENT], only from your own words | Yes | Yes | Yes | |
| Memory in the prompt (4,000 chars), skills, recall | Yes | Yes | Yes | |
| Local API (127.0.0.1, token, no browsers, 30 a minute) | Token in Keychain | Token in Credential Manager | Token in a 0600 file (Secret Service needs a desktop keyring that servers and CI don't have) | `gateway.rs`, `secrets.rs` |
| Hooks | Executable, owned by you, not group/world-writable | `.exe`, `.cmd`, `.bat`, `.ps1`, `.py` in the hooks folder | As Mac | `hooks.rs` |
| Usage per bot and day, `/doctor`, `/new` | Yes | Yes | Yes | |
| Coding runs: own branch and worktree, commit, push, draft PR | Yes | Yes | Yes | On any coding agent: Claude Code, Codex, Cursor Agent, OpenCode, Grok or Gemini CLI (`coding.rs`). Needs `git`, and `gh` signed in for the PR |
| The run card under a final prompt: which coding agent, which folder (the projects folder's, a new one made with git and a first commit, or any other), which chat, Start | Yes | Yes | Yes | `run_choices.rs`, `app/ui/runchoices.js`; the projects folder is `coding.projectsFolder` (default: Theo's own `Projects` folder), changed from the card |
| Carrying on a coding agent's own chat, in the folder itself, with no branch, commit or push of Theo's | Yes | Yes | Yes | `harness_chats.rs` reads each agent's own store: Claude Code, Codex (rollout files), Cursor Agent (`~/.cursor/chats`), OpenCode (`opencode session list`), Grok. Gemini CLI can't resume by id, so it lists none. A bot names one with a `Continue:` line |
| Routines page: add and edit (who, what, every N minutes or hours, every hour, daily, weekdays, weekly), on and off, last runs with quiet, missed and skipped | Yes | Yes | Yes | `routine_edit.rs` (`routineSave`, `routinesList`), `app/ui/routines.js` |
| Chat cards: a long answer as a brief with a reader, `[CHOOSE:]` as a yes/no or a choice (left 10 minutes with the chat open, it picks the highlighted one), sign-in in the words of the bot's own brain (install, sign in, API key), failure, off, private messages between bots, `[PDF:]` | Yes | Yes | Yes | `app/ui/cards.js` |
| `[PDF: file]`: a real PDF of a Markdown, text or HTML file in the bot's folder, with a card that opens it | Yes | Yes | Yes | `pdf.rs`, written by Theo itself (no PDF library, standard fonts, A4) |
| `[FILE: file]` and `[SAVE FILE: file -> Desktop]`: a file a bot made as an attachment card (Open, Show in folder, Save to Desktop or Downloads; dragging it out is Mac only for now), and a copy on the Desktop or in Downloads when the owner asked | Yes | Yes | Yes | `files.rs` (Desktop and Downloads from the registry on Windows, user-dirs.dirs on Linux) |
| Home: needs you, failed, working now, finished today, asleep with the next routine | Yes | Yes | Yes | `app/ui/home.js` (the Mac's `HomeLanes`) |
| Data folder | `~/Library/Application Support/Theo-Desktop` | `%APPDATA%\Theo-Desktop` | `~/.local/share/theo-desktop` | never the Swift app's `Theo` folder |
| Projects folder for coding runs | Setting | Setting | Setting | `code.projectsFolder` (Settings › Coding runs), default `<data folder>/Projects`, made only when a run needs it; a relative path, a drive, the home folder or Theo's own data folder is refused (`paths.rs`) |
| In-app updates (Update row, Settings › Updates) | The Swift app's own | Per-user install: downloads, checks, installs silently and reopens | AppImage: replaces itself and reopens | `update.rs`, the app's `updater.rs`; see Updates below |
| Products (Theo, Clicky, Dictation on or off) | Yes | Yes | Yes | `products.rs`, Setup's "Pick what you want" and Settings › Products |
| Settings with a list of sections, Setup (Welcome and your name, brain, products, coding, first bot) | Yes | Yes | Yes | `app/ui/settings.js`, `app.js` `drawSetup` |

### Updates

The build number is baked in when the app is built (`THEO_BUILD`, the `yyyyMMddHHmm` of a release's `build-<number>` tag;
CI sets it; a build made by hand is build 0 and says so). The releases repo is `install/releases-repo`, compiled in
(`THEO_RELEASES_REPO` overrides it); Windows builds are published there from every green `main` build by
`.github/workflows/windows-release.yml` ([DISTRIBUTION.md](DISTRIBUTION.md#windows-builds-publish-themselves)). Theo checks 20 seconds after it starts and every 6 hours, and never installs by itself:
the Update row at the bottom of the sidebar says "Build N" when there is one, and pressing it updates.

- **Which release.** Theo lists the repo's releases (`/releases?per_page=100`) and takes the newest published
  `build-<number>` release that has this platform's installer (`-windows-x64-setup.exe`, `-linux-x86_64.AppImage` or
  `-linux-aarch64.AppImage`) and a `SHA256SUMS`. It never reads `/releases/latest`, which is the Mac's: a Mac-only build
  doesn't hide a Windows one, and a Windows-only build published with `gh release create … --latest=false` doesn't move
  the Mac's latest. Drafts and prereleases don't count. `install.ps1` and `install-linux.sh` pick the same way.
- **Installing.** The installer is downloaded to `<data folder>/Updates` and checked against `SHA256SUMS`; a mismatch is
  refused and deleted. On Windows a per-user install (the setup.exe, `uninstall.exe` beside the app) quits and runs the
  installer silently (`/S /UPDATE /D=<its folder>`, no admin) from a hidden PowerShell script that waits for Theo to end,
  then reopens it; `Logs/update.log` says what happened. An AppImage replaces its own file and reopens. The .msi (for
  everyone, needs an administrator), the .deb and a build made by hand open the releases page instead.
- **A private repo** is said plainly, as the Mac does (`checkFailureMessage`): "This build's updates are private". Someone
  with access saves a GitHub token in Settings › Updates; it goes in the Credential Manager (Windows), the Keychain (Mac
  build) or a 0600 file (Linux), and is only ever sent as an `Authorization` header to GitHub. A test profile never uses
  `gh auth token`.
- Control inbox: `updates {action: state | check | token | removeToken | install | openPage}` (`install` in a test profile
  only, where it downloads and checks, then writes `update install build N` in `Logs/opened.log`).

### Products

Theo, Clicky and Dictation are each on or off (`products.theo`, `products.clicky`, `products.dictation` in settings.json).
No saved choice means Theo on, Clicky and Dictation off. Setup's "Pick what you want" step chooses them (Continue needs at
least one) and finishing Setup saves all three; Settings › Products changes them later. `setupState` and the `products`
command report them. A product that's off leaves the sidebar, and its pages show a "turned off" page with its demo and a
Turn on button. With Theo off, Home shows the products. Turning Theo off only hides; routines and the local API keep their
own switches. Setup opens at launch when it was never finished, or when Theo or Clicky is on and no brain can think
(`setupState.needsSetup`, the Mac's rule); then it starts at the brain step with Not now.

### Brains

None is required. Setup's brain step offers "paste an API key" first, since it is the quickest start, then lists every agent
(Claude Code, Codex, Cursor Agent, Gemini CLI, Grok, OpenCode) with its install command and a Sign in button that opens a
terminal running that agent's own sign-in. Settings › Brains has the same list, the saved keys (only whether one is saved
ever reaches the window) and the stand-in choice. The first bot, and Theo himself when Claude Code can't answer here and he
was never changed, think with what setup found: a signed-in agent (Claude Code first), else a key on its preferred model.

How each brain runs a bot's turn, and what it may do (nobody is there to approve anything):

- Claude Code: as before, with its permission rules (`policy.rs`).
- Codex: `codex exec --json -s read-only`, the prompt on standard input, then `codex exec resume` on its thread.
- Cursor Agent: `cursor-agent -p --mode ask` (read-only), then `--resume`.
- Gemini CLI: `gemini -p "" --output-format json` with the prompt on standard input, in its default approval mode. It can't
  resume a session by id, so every turn starts afresh with the persona.
- Grok: `grok -p --permission-mode dontAsk` with only web search, web fetch and reading tools, then `--resume`.
- An API key: Theo's own tool loop (`apichat.rs`, Anthropic Messages or OpenAI-style chat completions, streamed). Its tools
  are three for its own memory folder (`memory_list`, `memory_read`, `memory_write`, which refuse paths outside it) and the
  hub apps its level allows; at most 8 rounds of tool calls a turn. Theo keeps its chat history in `APISessions/`.

A signed-out agent or a used-up plan is said plainly in the chat, once, with where to sign in.

Keeping models current (`model_freshness.rs`, the same rules as the Mac's ClickyCore `Settings/ModelFreshness.swift`): a
key's model list is read live and put newest first (embedding, speech, image and moderation models left out). At start and
every 12 hours, with Settings › Brains › Newest models › "Keep models up to date" on (the default), each bot on an older
model of a family moves to the newest of that same family on offer (Sonnet 5 to Sonnet 5.5, never Sonnet to Opus, never
onto a dated snapshot or a preview), and what moved is listed there. Control command `models {action: state|check|on|off}`.

### Coding runs

Coding runs use any coding agent, none required (`coding.rs`, the Mac's `HarnessCoding.headlessArguments`). Which one: the
owner's pick in Settings › Coding runs (`coding.target`) when it's installed here, else the first one ready in the Mac's order
(Claude Code, Codex, Cursor Agent, OpenCode, Grok, Gemini CLI), else the first one installed. "Ready" is signed in, or signed
out with a saved API key the agent reads (Claude Code `ANTHROPIC_API_KEY`, Codex `OPENAI_API_KEY`/`CODEX_API_KEY`, Grok
`XAI_API_KEY`, Gemini CLI `GEMINI_API_KEY`, OpenCode only the key of its model's provider), which is then handed to it for
the run and the chat says so ("Codex is signed out here, so … uses your saved OpenAI key"), as do Setup and Settings; a
signed-in agent never gets a key, so its work stays on the subscription. With no agent at all the run fails with what to install.
The coding model and effort (`coding.model`, `coding.effort`) are for the picked agent (Claude Code when none is picked);
any other agent runs on its own default. Each runs headless with write access in the run's folder:

- Claude Code: `claude -p --permission-mode bypassPermissions`, the prompt on standard input, then `--resume`.
- Codex: `codex exec --json -C <folder> -s workspace-write`, the prompt on standard input, then `codex exec resume`.
- Cursor Agent: `cursor-agent -p --force --trust --workspace <folder>`, then `--resume`.
- OpenCode: `opencode run --format json --dir <folder>`, then `-s <session>`.
- Grok: `grok -p --permission-mode auto` in the folder, then `--resume`.
- Gemini CLI: `gemini -p "" --approval-mode auto_edit` in the folder, trusted for the run. A follow-up starts afresh there.

### Connectors

Connectors are Theo's own, through the connector hub (`theo-connectors`, [CONNECTORS.md](CONNECTORS.md)), which ships beside
the app in every installer (a Tauri sidecar: `theo-connectors.exe` next to `theo-desktop.exe`, `/usr/bin/theo-connectors` in
the .deb, inside the AppImage and the `.app`). Claude Code isn't needed for them:

- The Connectors page lists the hub's apps: an MCP address (signed in in the browser, with a pasted token, or nothing), a
  program on this computer, and the apps on the owner's Claude account. Each server Claude Code has is added as an app on
  the Claude account the first time the page checks, once, so removing one keeps it removed.
- Each bot gets each app at a level: read only, read and draft (the default), or everything. A turn that didn't come from the
  owner's own words (a routine, another bot, the local API) reads and drafts at most: it never sends, shares or deletes.
- A turn's apps: before the turn Theo writes a ticket (`Connectors/tickets/`, deleted when the turn ends) and starts the
  engine with the hub as an MCP server called `theo` for that turn only: Claude Code through `--mcp-config` and an allow rule
  for `mcp__theo`, OpenCode through `OPENCODE_CONFIG_CONTENT`. The other agents call it `theo_apps`, as the Mac does: Codex
  through `-c mcp_servers.theo_apps.*` overrides, Cursor Agent through `.cursor/mcp.json` and Gemini CLI through a trusted
  `.gemini/settings.json` in the bots' own folder (written for the turn, removed after it, one such turn at a time), and
  Grok through its own `~/.grok/config.toml` with each tool allowed by name. An API-key bot calls the hub's `call` itself.
  The hub only offers and only runs what the ticket allows.
- A Claude Code bot keeps its direct route to apps on the Claude account (Claude Code's own `mcp__claude_ai_*` tools,
  allowed tool by tool for its level, with the rest denied). Every other combination goes through the hub.
- Bots saved before the hub named Claude Code servers ("claude.ai Gmail"). At the first start each becomes the hub app for
  that server; one whose tools Theo can't tell apart keeps the whole server ("Everything"), as it had.
- The engine finds the helper beside itself, else `THEO_CONNECTORS_BIN`, else on PATH. A test profile keeps the hub's key in
  a file (`--key-store file`) and records the sign-in address in `Logs/opened.log` instead of opening a browser.

### Teams, group chats and bot settings

Ported from the Swift app with the same words and rules (`teams.rs`, `harness_teams.rs`, `teams_control.rs`; the window's
`teams.js` and `bot-settings.js`):

- Teams: categories saved as the Mac saves them (`Bots/layout.json`: items `bot:<id>`, `leaderID`, `wantsManager`). Every
  category gets a manager (its first member who isn't the CEO) unless the owner switches "Has a manager" off. "Report to
  Theo now", or a schedule (every day at 6 pm, weekdays at 6 pm, Fridays at 5 pm, every 2 hours; a routine with target
  `report:<category>`), has each member report to the manager's chat, then the manager rolls them up into the CEO's chat;
  with no manager each member reports to the CEO directly. The CEO reads what came in at the start of its next turn, once.
  Each bot's instructions say who it reports to, and the CEO's list its teams. The last 10 reports show on the team page.
- The sidebar opens on Teams (each category with its manager first, crown and "Manager", then "Other bots", then New
  category); "Urgent first" is the other choice, remembered by the window (`theo.sidebar.sort.v2`), and a counter pill shows
  its lane without switching for good. Theo is always on top. Right-click a bot to move it, take it out, open its settings,
  turn it off, make it primary or delete it; drag a bot onto a category; right-click a category to fold, rename, report or
  delete it (its bots stay).
- Bot settings (the Settings button in a bot's header): name, what it does, look, on or off, instructions, brain, model,
  effort (Codex and Grok), authority and who it can message, its category, its apps at their levels, a fresh session, make
  primary, delete. The CEO can't be deleted.
- Group chats: New group chat, Edit (name, head, 1 to 5 other members) and Delete (its chat goes, its bots stay).
- Theo asks a whole group chat with `[TELL: <group name>: …]`: the group talks it through and its head's last word comes back
  to him (20 minutes at most). Each ask counts against the private-message budget. A message about building (plan, build,
  make, app, website, …) starts a build discussion: the head plans, each member critiques in turn, the head merges and writes
  the final prompt, and that starts the run when the owner's own words asked to build. The same happens when the owner
  writes such a message in the group chat without tagging anyone.
- In any group round, members the owner names without an @ ("Ledger: the break-even") answer after the head even if the head
  forgets them, and a member's @Name only hands on to a bot that hasn't answered yet in the round.

Control commands (theod's inbox and the window): `teams`, `teamAdd`, `teamUpdate`, `teamDelete`, `teamMember`, `teamMove`,
`teamReport`, `teamReportSchedule`, `botGet`, `botMakePrimary`; `botUpdate` also takes `effort` and `canMessage: null`.

### Not in this build yet (the Swift app has them)

- Theo Link (two Macs as one Theo). The protocol could be ported; nothing in it is Mac-only except Bonjour, which has mDNS equivalents.
- Sub-categories, pinning and hiding bots in the sidebar, and a category's own colour and symbol.
- `[SCREEN:]` jobs (they need the Mac's Clicky actions). `[RESEARCH:]` is here: see VM screens below.
- Harness cards for T3 Code, and the run card's Mac choice; coding runs in a terminal you can watch (they run headless here
  and report back in the chat). Codex chats kept only in its newer sqlite store, and Cursor Agent chats kept only in its
  `store.db`, aren't listed for carrying on yet.
- The app sign-in card for a bot blocked on one connector app (the Mac's `ConnectorHealth.blockingConnector`) and the
  permission card (macOS privacy permissions). The Connectors page shows which apps need a sign-in instead.
- Theo's own MCP server (`claudia_*` tools) isn't ported.
- Fast mode for a bot (Claude Opus and Fable only: `fastMode` for Claude Code, `speed: "fast"` on an Anthropic key). Bots
  here have no fast switch yet. Asking Claude Code which model each alias means today (the Mac's alias probe) isn't ported
  either: the Claude list here is the bundled one.

## Clicky (voice and screen helper): Mac and Windows

Windows has Clicky's core in this build: hold a chord, ask about what's on the screen, let go, and Clicky answers in a
bubble by the cursor, out loud, and points with its spark. The rules are in `crates/theo-core/src/clicky/` (tags, screens,
prompt, speech, the turn on any brain, the `clicky*` control commands); the spark, the chord and the tray item are in
`app/src-tauri/src/clicky.rs` and `clicky_voice.rs`; the overlay page is `app/ui/spark.html` and `spark.js`; Settings ›
Clicky is `app/ui/clicky.js`. It's a product of its own (`products.clicky`, off until the owner turns it on in Setup's
"Pick products" step, Settings › Products, Settings › Clicky or the tray's "Show Clicky").

| What Clicky does | Mac | Windows (this build) | Linux (X11) | Linux (Wayland) |
|---|---|---|---|---|
| Push-to-talk on a held chord | Control + Option, CGEvent tap | Ctrl + Alt by default (Settings › Clicky › Shortcut), through the app's one keyboard hook shared with Dictation (`theo_voice::hub`). Chords are exact; if Dictation is set to the same chord, Clicky stands aside and Settings says so. A brush shorter than Dictation's minimum hold does nothing | Not yet (XInput2 is feasible); "Try it" in Settings › Clicky runs a whole turn from typed words | Not yet |
| Microphone and speech to text | AVAudioEngine, Apple Speech | Dictation's: the same microphone and recognizer choice (a saved Sarvam, OpenAI, Groq, Deepgram or AssemblyAI key, else Windows' own offline recognizer) | Not yet | Not yet |
| See the screen | ScreenCaptureKit, every display | GDI capture of every monitor at its real pixels (per-monitor DPI aware), scaled to at most 1568 px on the long edge as JPEG, the cursor's monitor first as SCREEN 1, the same headers as the Mac. The spark windows are left out of the capture (`WDA_EXCLUDEFROMCAPTURE`) | Not yet: it answers from the words and says once that it can't see | No |
| Think | Claude Code (stream-json, pictures), or the helper brain | Any brain (`clicky.brain`, else Claude Code when installed, else the first saved key, else the first signed-in agent): API keys with pictures (Anthropic image blocks, OpenAI-style `image_url`), Claude Code with the Mac's stream-json message and no tools, Codex with the pictures as `-i` files; Gemini CLI, Cursor Agent, Grok and OpenCode answer from the words and say so once. A model that turns pictures down is asked again with words and remembered (`clicky.modelsWithoutImages`). The Mac's Clicky prompt, with `owner.name` | Same brains, words only | Same |
| The spark that follows the pointer, spins while thinking, flies to things | Transparent overlay panels | One transparent, click-through, never-focused, always-on-top window per monitor (`theo_voice::overlay`), the orange spark redrawn at 60 Hz only while the pointer moves; flies along an arc to `[POINT:x,y:label:screenN]` on the right monitor at its own scale; `[MARK:…]` circles, boxes, arrows, underlines, spots, highlights and numbered steps (six at most), cleared on the next question, on Esc, or 20 s after it stops talking. "Always" or "only while talking" (`clicky.spark`) | The same windows (seen working under Xvfb) | No: apps can't know the pointer or place windows |
| Speak answers | AVSpeechSynthesizer | Windows' own voices (SAPI through a hidden PowerShell), picked in Settings › Clicky › Voice | `spd-say` or `espeak-ng` when installed | Same |
| Esc stops everything | Event tap | Yes, while it's listening, thinking, talking or showing marks | Not yet (the Stop button in Settings › Clicky) | Same |

Checked where: the POINT, MARK and CLEAR rules, the coordinate mapping across monitors of different scales, the prompt and
the speech script are unit tests (`cargo test -p theo-core clicky`); suite cases K01 to K05 drive `clickyTest` (pictures
given, no screen needed) on Linux and Windows against stand-in APIs and agents, and K05 captures the real monitors, lists
the voices and speaks to a file on the Windows runners. The chord, the microphone, the spark over other apps and the
pointing on a real multi-monitor PC need a person ([WINDOWS-PC.md](WINDOWS-PC.md)).

Not in this build yet (the Mac has them): hands-free sessions (double tap), the wake word ("hey vello" for a call with Vello, "hey pointer" for Pointer Assistant), doing things on the
screen (`<actions>`, article highlights and notes), `[WORKER:]` helpers and Clicky's team, the notch pill, voice calls with Vello or any other bot (and what Vello can do on one: `[POINTER:]`, `[ROUTINE:]`, `[TELL: Vello:]`; a bot's own call voice), a bot's own `instructions.md` and `nature.md`, `[SNAP:]`
screenshots and the local fast path for spoken commands. The Mac's hidden displays would need a signed display driver on
Windows, so Windows and Linux have VM screens made of hidden browser windows instead (below).

## Dictation (hold a key, talk, the words are typed where you are): Mac and Windows

Windows has it in this build (`crates/theo-voice`, wired into the app by `app/src-tauri/src/dictation_ui.rs`, Settings ›
Dictation in `app/ui/dictation.js`). It's a product of its own (`products.dictation`, off until the owner turns it on in
Setup's "Pick products" step, Settings › Products or Settings › Dictation).

| Step | Mac | Windows | Linux (X11) | Linux (Wayland) |
|---|---|---|---|---|
| Hold a chord | Control + Fn (Fn is visible to macOS) | Ctrl + Win by default (Fn is handled by the keyboard's firmware and never reaches Windows); also Ctrl + Shift, Alt + Shift, Win + Alt, Ctrl + Shift + Space, Ctrl + Alt + Space. One `WH_KEYBOARD_LL` hook for the whole app (`theo_voice::hub`), shared with Clicky's Ctrl + Alt; chords are exact, so the two never overlap. Esc or any other key while holding cancels; letting go of Win after the chord doesn't open Start | Not yet: XInput2 is feasible | Not yet: the GlobalShortcuts portal, partial |
| Record | AVAudioEngine | WASAPI through cpal, 16 kHz mono PCM16; never asks for a permission, and says where Windows' microphone privacy switch is when it's off | Not yet (cpal over PulseAudio/PipeWire is feasible) | Same |
| Transcribe | Apple Speech always, Sarvam when its key is saved | Sarvam, OpenAI (gpt-4o-transcribe), Groq (Whisper), Deepgram (Nova-3) or AssemblyAI on a saved key; with no key, Windows' own `System.Speech` dictation through a hidden PowerShell (offline, in the languages the PC has speech for; plain words when it has none). "Automatic" tries the saved keys in that order, then Windows' own, so a failed call never loses the words | The services work; no offline recogniser | Same |
| Clean-up | Haiku through one warm Claude Code, else the helper brain, else skipped with a note | The Mac's rules (`theo_voice::cleanup`: local pass, prompt, the guard against answers), through a cheap model of Theo's own brain, else any saved API key, else a signed-in agent (Claude Code on Haiku, Codex, Gemini CLI, OpenCode), else skipped with the Mac's note. Waits 4 s for an API and 20 s for an agent, then the words go in as heard | Same code | Same code |
| Put the words in the app you're in | Accessibility insert, then paste | Paste (clipboard saved, words marked to stay out of clipboard history, Ctrl+V, the clipboard put back unless something else changed it), else typed with `SendInput` Unicode. Never into a password field (UI Automation's IsPassword, and the classic password edit style). The pill never takes focus | XTest typing or paste: feasible | Needs `wtype` or the RemoteDesktop portal. Partial |
| The chat box's mic | Yes (mic, ⌥Space, ⌘⇧D; Esc cancels, Enter keeps) | Yes (mic button, Ctrl+Shift+D; Esc cancels, Enter keeps; never sends) | The same button, where a microphone works | Same |

What's checked where: the chord rules, WAV handling, requests and answers of every service, the Windows recognizer's
script and its answers, and the clean-up rules are unit tests on Linux; every Windows-only file compiles in CI's Windows
jobs and here with `cargo check --target x86_64-pc-windows-gnu`; suite cases D01 and D02 drive `dictationTest {wav}` (a
WAV through transcribe and clean-up, no microphone) on Linux and Windows, D02 asking Windows' real recognizer on the
Windows runners. The hook, the microphone, typing into other apps and the pill need a person at a real PC
([WINDOWS-PC.md](WINDOWS-PC.md)).

## VM screens and research agents: Mac, Windows and Linux

The Mac's VM screens are virtual displays holding Chrome windows (`leanring-buddy/Studio`, `Research/`). A virtual display
on Windows needs a signed driver and admin rights, so on Windows and Linux a VM screen is a **hidden browser window**: the
owner's own Chrome or Edge started with `--headless=new`, no window, no taskbar button, nothing in Alt+Tab, no driver and
no admin. The code is `crates/theo-core/src/vmscreens/` (`browser.rs` finds and starts the browser, `cdp.rs` is a small
DevTools client, `page.rs` the rules for what may be opened and how a page is read, `mod.rs` the screens, `research.rs`
the agents); the window's part is `app/ui/vmscreens.js` and `vmscreens.css`.

| What | Mac | Windows and Linux (this build) |
|---|---|---|
| A screen | A virtual display parked in a corner, with a Chrome window on it | A headless Chrome, Edge or Chromium of its own (found in Program Files, Local AppData or on PATH; `vmScreens.browser` names one by hand), 1280 by 800, its own throwaway profile under Vello's data folder (`VMScreens/`, wiped at start), DevTools on 127.0.0.1 at a port the browser picks (`DevToolsActivePort`). Never the owner's own profile, cookies or sign-ins. Up to 4 (`vmScreens.count`, default 2) |
| Turning it on | Settings › VM screens, off by default | The same (`vmScreens.on`, off by default). Off, research still works: pages are fetched the plain way and read from their HTML |
| What a screen may open | Rules in ClickyCore `Research/BrowserResearch.swift` | `page.rs`: only `http`/`https` on a public host. Never this computer, the network around it (private, link-local, `.local`) or a page that looks like an action (sign-out, delete, checkout, unsubscribe, a token in the address). Every page load, redirects included, goes through the DevTools `Fetch` gate and is refused there if it leads somewhere else; downloads are refused |
| Reading | Accessibility, in reading order | A script in the page: the main or article part first, else the body, leaving out navigation, headers, footers, asides, forms and hidden text, at most 40,000 characters. A small JPEG of the screen every 2 s while it's working, for the tile |
| A human check (captcha, "verify you are human") | A card, never a workaround | The same: the page is skipped and a "Needs you" card in the chat offers to open it in the owner's own browser |
| When it closes | When idle, and when Theo quits | After 60 s idle, when turned off or the count lowered, and when Vello quits. Each browser is in a Job Object (Windows) or its own process group (Linux), and on the engine's list of children, so even a crash leaves no browser behind: the next start ends them |
| Research agents | `ResearchRole`, `ResearchAgentPlan`: Ideas and Info by default, up to 4 | The same jobs (Ideas, Info, Examples, Check; `research.agents` 2 to 4, `research.role.<id>`), each searching DuckDuckGo's plain results page in its own screen, opening its best pages (`research.pages`, 2 to 4, no page or site twice across agents) and having the brain in use read each as data. Then that brain writes one brief with numbered sources, saved as Markdown in `Research/` and posted as a card |
| Who can start one | Clicky's Researcher, `[RESEARCH:]` from Theo | A `[RESEARCH: question]` line in any bot's reply (taken out of the shown text; the brief lands in that chat), the `research` tool for bots on an API key (waits for the brief and answers with it), and Pointer Assistant when asked to research or look something up (spoken "Researching … in the background", the brief lands in the primary bot's chat). One research at a time, three waiting at most, 15 minutes at most |
| The panel | The VM screens panel | VM screens in the sidebar (shown while they're on): a live tile per screen with its page, address and what its agent is doing, and Stop the research. Settings › VM screens: on or off, how many, the browser found (or "Vello needs Chrome or Edge" with a link), the jobs, and Try it |

Every brain works: the readers and the brief use `clicky::ask_words` (any API key, Claude Code, Codex, OpenCode, Gemini
CLI, Cursor Agent or Grok); with no brain at all the brief is the agents' notes and sources joined in plain words.

Control commands: `vmScreens {action: state|on|off|open|read|close}` (`open {url, screen?}` reads a page on a screen and
returns its words and tile; `on {count?}`), `research {question, agents?, bot?, wait?}` and `research {action:
state|cancel}`. Suite cases V01 to V09 (`tests/suite_vmscreens.py`) run them against `tests/vm_pages.py`, a local
stand-in for the search page and the pages it links to (`test.research.searchURL`; a test profile may open 127.0.0.1),
and are skipped with the reason printed where no Chrome, Edge or Chromium is installed.

Not in this build yet (the Mac has them): research on links already on the owner's screen, the Researcher bot of Clicky's
team, live views of other apps' windows, and a VM screens panel on another linked computer.

## Not yet verified

- Windows: the installed app is driven end to end on GitHub's Windows Server 2022 and 2025 machines with the real
  Claude Code (see [WINDOWS-PC.md](WINDOWS-PC.md) for the list), but not yet on a Windows 10/11 PC with a person signing
  in. SmartScreen will warn about the unsigned installer. WINDOWS-PC.md has the 30-minute check for a real PC.
- Linux: tested on GitHub's Ubuntu runners (22.04 for the app and installers, 24.04 for the engine), not on a desktop with a
  real Claude Code login, and not on Wayland with a person at it.
