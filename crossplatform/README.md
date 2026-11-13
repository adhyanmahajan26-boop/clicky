# Theo for Windows and Linux (and optionally Mac)

The Mac app stays the Swift app. This folder is a separate project that brings **Theo, the bots harness**, to Windows and
Linux: the harness engine rewritten in Rust, and a Tauri desktop window around it. Clicky and dictation stay Mac-only for
now; [docs/PLATFORMS.md](docs/PLATFORMS.md) says what each would take elsewhere.

```
crossplatform/
  crates/theo-core/   the engine: bots, chats, turns, limits, routines, recovery, local API, hooks, usage, doctor, coding runs
  crates/theod/       the engine as a background program, driven through a control inbox (for servers and tests)
  crates/theo-connectors/  the connector hub: Theo's own apps, sign-ins and safety rule, for every brain, Mac and Windows (docs/CONNECTORS.md)
  app/                the desktop app: Tauri 2, a plain HTML/JS window on the Theo Pixel kit (app/ui/kit), the same engine inside
  tests/              the Swift app's harness suites, ported to drive theod or the desktop app, plus installer tests
  install/            one-line installers: install-linux.sh, install.ps1
  tools/              naming installers for a release and writing SHA256SUMS
  docs/               PLATFORMS.md (what runs where), WINDOWS-PC.md (what is proven on Windows, and the real-PC check), DISTRIBUTION.md (installing, releases, signing), CONNECTORS.md (the connector hub's contract), PIXEL.md (faces, cards, connectors), screenshots/
```

## Why Rust and Tauri

Rust because the engine is mostly process control, files that must survive crashes and careful concurrency, all of which
need different system calls on each platform (process groups and signals on Mac and Linux, Job Objects on Windows), and
Rust has first-class access to both. Tauri because the window can then call the engine in-process with no server or
port, the app is small (about 10 MB, using the system's web view), and its bundler makes `.dmg`, `.msi`, NSIS `.exe`,
AppImage and `.deb` from one config. Electron was the alternative: it would bring a Node engine or a sidecar process and a
100 MB+ download for no gain here.

## How it matches the Swift harness

`theo-core` is a port of the Swift `BotsStore`, `BotRunner`, `BotPrivateMessages`, `BotRoutines`, `BotFailover`,
`BotsResume`, `TheoGateway`, `TheoHooks` and ClickyCore's `BotProtocol` and `HarnessParity`, with the same numbers (3 round
trips and 12 private messages per owner message, 4 parallel lanes, 8 group turns, retries at 3 s and 10 s, the
Sonnet→Haiku→Opus chain, a 4,000-character memory section, a catch-up window of half the period between 2 minutes and
2 hours, 30 local API requests a minute, a 7-minute turn limit) and the same prompts.

`theod` understands the Swift test profile's control-inbox commands (`botSay`, `botsState`, `botChat`, `routines`,
`uiBotStop`, `uiRunStart` …), so the original suites port with small changes. `tests/suite.py` holds 60 of them, decided
by code from theod's own files, its engine's calls and the processes left behind. A Python stand-in for `claude -p`
(`tests/fake_engine.py`) plays crashing, hanging, flooding and compromised models, so the suite runs the same on all three
platforms with no Claude login.

## Build and test

```bash
cd crossplatform
cargo test --workspace          # unit tests
cargo build -p theod
python3 tests/suite.py          # the ported suites (python on Windows)
python3 tests/install_test.py   # the Linux installer against a stand-in GitHub
cd app && npm ci && npx tauri build   # the desktop app and its installers for this platform
```

Linux needs `libwebkit2gtk-4.1-dev libappindicator3-dev librsvg2-dev patchelf` to build the app. The suite can drive the
built app too: `THEOD_BIN=app/src-tauri/target/release/theo-desktop python3 tests/suite.py` (under `xvfb-run` on a Linux
server).

Running Theo needs Claude Code installed and signed in (`claude auth login`), as on the Mac; `git` and `gh` for coding
runs. Data lives in its own folder (see PLATFORMS.md), never the Swift app's.

## Status

| Where | Result |
|---|---|
| Mac Studio | full suite 71/71; the built app 12/12; real Claude Code red-team and memory tests pass |
| GitHub Ubuntu 24.04 / Windows Server 2022 | unit tests and full suite, 83/83 each |
| GitHub Ubuntu 22.04 / Windows Server 2022 | app and installers built; the real app passes 16/16; `.deb` install, and `install.ps1` install and removal without admin |
| GitHub Windows Server 2022 and 2025 | the installed app driven end to end with the real Claude Code, 18/18 each, and updating over the last `main` build ([docs/WINDOWS-PC.md](docs/WINDOWS-PC.md)) |

Not yet run on a Windows 10/11 PC or a Linux desktop with a person signing in to Claude Code; docs/WINDOWS-PC.md has the 30-minute check for a real PC.
