# What runs where

Theo on Mac stays the Swift app. This folder is Theo for Windows and Linux (and, optionally, a Mac build of the same thing):
one Rust engine and one Tauri window on all three. This page says, feature by feature, what each platform gets and why.

## Theo (the bots harness): all three platforms

| Piece | Mac | Windows | Linux | How |
|---|---|---|---|---|
| Bots, chats, group chats, private threads, routines | Yes | Yes | Yes | `theo-core`, the same code everywhere |
| Engine: Claude Code (`claude -p`) on your subscription | Yes | Yes | Yes | Claude Code runs on all three; Theo finds it on PATH, `~/.local/bin`, `%APPDATA%\npm` |
| Engine: OpenCode bots, with Claude standing in when it fails | Yes | Yes | Yes | |
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

### Not in this build yet (the Swift app has them)

- Theo Link (two Macs as one Theo). The protocol could be ported; nothing in it is Mac-only except Bonjour, which has mDNS equivalents.
- Theo messaging a whole group chat with `[TELL: group]`, and group "build discussions" (plan, critiques, merge).
- `[PDF:]` documents, `[CHOOSE:]` cards, `[SCREEN:]` and `[RESEARCH:]` jobs (those need Clicky and the Studio).
- Harness cards for T3 Code, Codex, Cursor, Grok and Gemini; continuing a harness's own chat.
- Connectors are Claude Code's own (claude.ai MCP servers), so they work wherever Claude Code is signed in; Theo's own MCP server (`claudia_*` tools) isn't ported.
- API-key bots (Anthropic or OpenAI-compatible keys without Claude Code).

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

- Windows: everything was compiled and tested on GitHub's Windows Server 2022 runners, not on a Windows 10/11 PC with a
  real Claude Code login. The Claude Code permission-rule paths on Windows (`//c/Users/...`) follow Claude Code's docs and
  weren't exercised against a real `claude.exe`. SmartScreen will warn about the unsigned installer.
- Linux: tested on GitHub's Ubuntu runners (22.04 for the app and installers, 24.04 for the engine), not on a desktop with a
  real Claude Code login, and not on Wayland with a person at it.
