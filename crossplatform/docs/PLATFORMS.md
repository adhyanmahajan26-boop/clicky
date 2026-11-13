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
| Coding runs: own branch and worktree, commit, push, draft PR | Yes | Yes | Yes | Needs `git`, and `gh` signed in for the PR |
| Data folder | `~/Library/Application Support/Theo-Desktop` | `%APPDATA%\Theo-Desktop` | `~/.local/share/theo-desktop` | never the Swift app's `Theo` folder |

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

### Connectors

Connectors are Theo's own, through the connector hub (`theo-connectors`, [CONNECTORS.md](CONNECTORS.md)), which ships beside
the app in every installer (a Tauri sidecar: `theo-connectors.exe` next to `theo-desktop.exe`, `/usr/bin/theo-connectors` in
the .deb, inside the AppImage and the `.app`). Claude Code isn't needed for them:

- The Connectors page lists the hub's apps: an MCP address (signed in in the browser, with a pasted token, or nothing), a
  program on this computer, and the apps on the owner's Claude account. Each server Claude Code has is added as an app on
  the Claude account the first time the page checks, once, so removing one keeps it removed.
- Each bot gets each app at a level: read only, read and draft (the default), or everything. A turn that didn't come from the
  owner's own words (a routine, another bot, the local API) only reads.
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

### Not in this build yet (the Swift app has them)

- Theo Link (two Macs as one Theo). The protocol could be ported; nothing in it is Mac-only except Bonjour, which has mDNS equivalents.
- Theo messaging a whole group chat with `[TELL: group]`, and group "build discussions" (plan, critiques, merge).
- `[PDF:]` documents, `[CHOOSE:]` cards, `[SCREEN:]` and `[RESEARCH:]` jobs (those need Clicky and the Studio).
- Harness cards for T3 Code; coding runs on Codex, Cursor, Grok and Gemini (bots think with them, coding runs use Claude
  Code); continuing a harness's own chat.
- Theo's own MCP server (`claudia_*` tools) isn't ported.

## Clicky (voice and screen helper): Mac only for now

Clicky leans on macOS for every one of its senses. What each would need elsewhere:

| What Clicky does | Mac API | Windows | Linux (X11) | Linux (Wayland, the default on Ubuntu and Fedora) |
|---|---|---|---|---|
| Push-to-talk on a held key | CGEvent tap | Low-level keyboard hook: feasible | XInput2: feasible | GlobalShortcuts portal (GNOME 48+, KDE): press works, release isn't reliable everywhere. Partial |
| Microphone | AVAudioEngine | WASAPI (cpal): feasible | PulseAudio/PipeWire (cpal): feasible | Same: feasible |
| Speech to text, on-device | Apple Speech | No good built-in offline recogniser for every language: bundle whisper.cpp (~150 MB model) or use Sarvam/Deepgram with a key | Same | Same |
| See the screen | ScreenCaptureKit | Windows.Graphics.Capture: feasible | XGetImage: feasible | ScreenCast portal: asks permission each session (or a restore token). Partial |
| The cursor companion that follows the pointer and flies to things | Transparent overlay windows | Layered, click-through topmost window: feasible | ARGB override-redirect window: feasible | Not possible: apps can't know the global pointer position or place windows. No |
| Read and press UI elements | Accessibility (AX) | UI Automation: feasible, similar coverage | AT-SPI: works for GTK/Qt, little from Chromium/Electron apps unless started with accessibility on | Same as X11 for reading; pressing needs the RemoteDesktop portal with consent. Partial |
| Speak answers | AVSpeechSynthesizer | SAPI / WinRT SpeechSynthesizer: feasible | speech-dispatcher, espeak-ng or Piper: feasible (robotic without Piper) | Same |
| "Hey Clicky" wake word | Apple Speech, always on-device | Needs a local keyword model (openWakeWord, Porcupine): feasible | Same | Same |
| Studio hidden screens | CGVirtualDisplay | Indirect Display driver: a signed kernel-mode driver. Not realistic | Xvfb/virtual outputs: feasible on X11 | No |

Verdict: a Windows Clicky is a real project (weeks, not days) and could match most of the Mac version except the Studio
screens. Linux on X11 is similar. On Wayland the cursor companion can't exist and seeing or pressing things needs a
permission prompt, so it would be a lesser, panel-only helper. None of it is half-built here.

## Dictation (hold a key, talk, the words are typed where you are): Mac only for now

| Step | Mac | Windows | Linux (X11) | Linux (Wayland) |
|---|---|---|---|---|
| Hold Control + Fn | Fn is visible to macOS | Fn is handled by the keyboard's firmware and never reaches Windows: needs another chord (for example Ctrl + Win) | Same: another chord | Same, through the portal |
| Record and transcribe | Apple Speech + Sarvam + Haiku clean-up | whisper.cpp or Sarvam, then the same Haiku clean-up through Claude Code: feasible | Same | Same |
| Put the words in the app you're in | Accessibility insert, then paste | SendInput (Unicode) or UI Automation, then paste: feasible | XTest typing or paste: feasible | Needs `wtype` (wlroots compositors only) or the RemoteDesktop portal, or paste with the clipboard portal. Partial |

Verdict: Windows dictation is very doable (about a week's work), X11 too; Wayland depends on the desktop.

## Not yet verified

- Windows: the installed app is driven end to end on GitHub's Windows Server 2022 and 2025 machines with the real
  Claude Code (see [WINDOWS-PC.md](WINDOWS-PC.md) for the list), but not yet on a Windows 10/11 PC with a person signing
  in. SmartScreen will warn about the unsigned installer. WINDOWS-PC.md has the 30-minute check for a real PC.
- Linux: tested on GitHub's Ubuntu runners (22.04 for the app and installers, 24.04 for the engine), not on a desktop with a
  real Claude Code login, and not on Wayland with a person at it.
