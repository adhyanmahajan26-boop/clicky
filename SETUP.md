# Setting up Theo

From nothing to a bot that does something for you, in about ten minutes.

## 1. Install

Open a terminal and paste the line for your computer. Run the same line again later to update; on a Mac, Theo's own
**Update** button (bottom of the sidebar) does it too.

| | |
|---|---|
| Mac (Terminal) | `curl -fsSL https://github.com/<releases repo>/releases/latest/download/install.sh \| bash` |
| Windows (PowerShell) | `irm https://github.com/<releases repo>/releases/latest/download/install.ps1 \| iex` |
| Linux | `curl -fsSL https://github.com/<releases repo>/releases/latest/download/install-linux.sh \| bash` |

`<releases repo>` is wherever the builds you were given are published. The installer checks the download's checksum and,
on a Mac, who signed it, and changes nothing if either is wrong. If it says **"this build's updates are private"**, the
releases repo isn't public: ask whoever gave you Theo for an installer. More: [docs/INSTALL.md](docs/INSTALL.md).

**Mac permissions.** On first launch macOS asks for the microphone (an Allow box). Accessibility and Screen Recording are
switched on in System Settings › Privacy & Security, where Theo may be listed as **Clicky**. Theo's Setup guide opens the
right page for each. You only grant them once: updates keep them.

**Windows.** The installer isn't code-signed yet, so the first time Theo opens SmartScreen may say "Windows protected your
PC": choose More info, then Run anyway.

## 2. Pick a brain

Theo doesn't come with a model of its own. It uses one you already have, and you can mix them: each bot can have its own.

- **A coding agent you're signed in to**: Claude Code, Codex, Cursor, OpenCode, Gemini or Grok, on your own subscription.
  The Setup guide shows which are installed and signed in, and can install one and sign it in inside Theo's own terminal.
- **An API key**: paste one in the Setup guide, or later in Settings › Models & API keys. It stays in your Keychain.

You don't need all of them. One is enough to start; on Windows and Linux that's Claude Code or OpenCode for now.

The Setup guide also asks which products you want (Theo's bots, Clicky the voice companion, Dictation) and which voice
to use. Everything there can be changed later in Settings.

## 3. Add an app

Bots reach your other apps (mail, calendar, docs, your own servers) through **connectors**. Open **Connectors** in the
sidebar to see what's available and sign in to an app. Then give the app to a bot in that bot's settings.

## 4. Make a bot

In the sidebar, choose **New bot** (or New bot on a team's page, to put it in that team). Give it:

- a name and a one-line job ("reads my inbox every morning and tells me what needs an answer");
- a brain (step 2);
- the apps it may use (step 3).

Then talk to it in its chat. To make it do something on a schedule, add a **New routine** on the bot's page. To have it
change code, name a folder and ask: it starts a coding run there with your coding agent, on a new branch, and shows the
result in the chat. Nothing is pushed or merged without you.

## Build from source

Mac (needs Xcode):

```bash
git clone <this repo> && cd <repo>
open leanring-buddy.xcodeproj    # then ⌘R
```

That builds without an Apple account: Xcode signs the app to run on your Mac only, and macOS asks for its permissions
again after each rebuild. To stop that, sign with your own team once (a free Apple ID works):

```bash
Tools/setup-signing.sh              # uses the team of the Apple Development certificate in your keychain
Tools/setup-signing.sh ABCDE12345   # or name the team
```

It writes `Config/Signing.local.xcconfig`, which git ignores, so nobody's team is committed. To publish your own builds
(and have installs and updates come from your repo), see [docs/INSTALL.md](docs/INSTALL.md#publishing-releases).

Windows and Linux: [crossplatform/README.md](crossplatform/README.md).

Trying changes: use a test profile (`--profile test`, [docs/TESTING.md](docs/TESTING.md)) so your real bots, chats and
permissions are never touched.
