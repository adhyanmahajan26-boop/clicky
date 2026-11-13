# Theo

Theo is a team of AI bots that lives on your computer. Each bot has a job, a face and a chat; bots work in teams with a
manager, run routines on a schedule, use your apps through connectors, and start coding runs in your own folders with the
coding agent you already use. On a Mac, Theo also brings **Clicky**, a voice and screen companion (hold Control + Option
and talk: it looks at your screen, answers out loud and points at things), and system-wide **Dictation**.

Theo runs on brains you already have: a coding agent signed in with your own subscription (Claude Code, Codex, Cursor,
OpenCode, Gemini or Grok), or an API key you paste in. There is no Theo account, server or analytics, and keys you paste
stay in your Mac's Keychain.

| | Mac | Windows and Linux |
|---|---|---|
| App | `Theo.app` (Swift, this repo's root) | Theo desktop (Tauri, [crossplatform/](crossplatform/README.md)) |
| Bots, teams, routines, coding runs | Yes | Yes |
| Brains | All of the above, or an API key | Claude Code and OpenCode today; the rest are on the way |
| Clicky and Dictation | Yes | Not yet ([crossplatform/docs/PLATFORMS.md](crossplatform/docs/PLATFORMS.md)) |
| Needs | macOS 14.2 or newer | Windows 10/11 (x64), or a 64-bit Linux desktop |

## Install

One line in a terminal; run it again to update. Nothing needs an administrator password.

| | |
|---|---|
| Mac (Terminal) | `curl -fsSL https://github.com/<releases repo>/releases/latest/download/install.sh \| bash` |
| Windows (PowerShell) | `irm https://github.com/<releases repo>/releases/latest/download/install.ps1 \| iex` |
| Linux (terminal) | `curl -fsSL https://github.com/<releases repo>/releases/latest/download/install-linux.sh \| bash` |

`<releases repo>` is the repo the builds you were given are published to (for the main builds it is in
[Config/Theo.xcconfig](Config/Theo.xcconfig) as `THEO_RELEASES_REPO`). If the installer says **"this build's updates are
private"**, that repo isn't public: ask whoever gave you Theo for an installer. Details, options and how the downloads are
checked: [docs/INSTALL.md](docs/INSTALL.md) (Mac) and [crossplatform/docs/DISTRIBUTION.md](crossplatform/docs/DISTRIBUTION.md)
(Windows and Linux).

## Get started

[SETUP.md](SETUP.md) walks through the first ten minutes: install, pick a brain, add an app, make a bot.

## Build it yourself

- Mac: `open leanring-buddy.xcodeproj` and press ⌘R. It builds without any Apple account; to keep macOS permissions across
  rebuilds, sign with your own (free) team once: `Tools/setup-signing.sh`. See [SETUP.md](SETUP.md#build-from-source).
- Windows and Linux: [crossplatform/README.md](crossplatform/README.md).
- Publishing your own builds: [docs/INSTALL.md](docs/INSTALL.md#publishing-releases).

## For contributors and coding agents

[AGENTS.md](AGENTS.md) has the architecture, conventions and where to look first. [docs/TESTING.md](docs/TESTING.md) explains
the isolated test profile; never test in your real profile.
