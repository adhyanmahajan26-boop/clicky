# Theo on a Windows PC: what's proven, and what only a real PC can check

Theo for Windows is tested by driving the real installed app on GitHub's Windows machines
(Windows Server 2022 and 2025, x64): the real installer, the real window (through WebView2's DevTools), the real
Claude Code from npm and from its own Windows installer, and the real Windows registry, Start menu and
notification system. `tests/windows_pc.py` is the test; the `windows-pc` and `windows-upgrade` jobs in
`.github/workflows/crossplatform.yml` run it and upload a summary with screenshots.

## Proven on Windows, for real

Each line is a step in `tests/windows_pc.py`, run on both Windows versions.

- The per-user installer runs silently with no admin prompt, and adds Theo to the Start menu.
- Opened from the Start menu, Theo shows first-run setup. With Claude Code missing it gives the Windows install command.
- Claude Code installed with npm (`%APPDATA%\npm\claude.cmd`, which isn't on Theo's PATH) is found, and is shown as signed out.
- Setup's Sign in button opens PowerShell running that Claude Code's `auth login`, by its full path.
- Claude Code from its own Windows installer (`irm https://claude.ai/install.ps1 | iex`) is found in `.local\bin`.
- Setup's coding step checks git and the GitHub CLI. Making the first bot lands in its chat.
- Messaging a bot runs the real Claude Code. When it's signed out, the chat shows the sign-in card with a Sign in button
  (Claude Code answers "Not logged in · Please run /login" as if it were a reply; Theo now treats that as signed out).
- A bot with 37,000+ characters of instructions over hundreds of lines still starts. Windows command lines stop at 32K
  characters (8K through cmd), so instructions and tool rules go in files and the message goes on stdin.
- Connectors come from the real `claude mcp list` on Windows. A working server shows Connected, and a broken one shows
  Can't connect with its reason. Giving a bot an app from the Connectors page adds that app's tools to the bot's allowed list.
- Open at sign-in writes the Windows Run key, and that start opens Theo in the tray with no window.
- Closing the window keeps Theo running in the tray. A bot that needs you raises a Windows notification (logged as sent by
  Windows' notification API).
- Opening Theo again while it runs brings the same window back instead of starting a second copy.
- Quit leaves nothing running. Opening again keeps bots and chats, and setup isn't shown again.
- Uninstall removes the app, the Start menu shortcut and the sign-in entry, and keeps your bots and chats.
- The .msi installs for everyone, opens, finds the same data and uninstalls.
- Installing the new build over the last build from `main` replaces the app and keeps bots and chats.

## Proven only when a Claude account is given to the test

If the repository has a `CLAUDE_CODE_OAUTH_TOKEN` secret (made with `claude setup-token`), the same run also checks these
against a real Claude account. Without it, the summary says they were skipped.

- Claude Code is signed in, and a bot answers in its chat.
- The long bot got every line of its instructions, and all of a 20,000-character message.
- A bot reads a web page (WebFetch from Windows).
- A bot uses the connector it was given, and a bot without it can't.
- The tool limits hold on Windows: no reading `~/.ssh` or another bot's memory (including by a relative or
  upper-case path), no writing outside its folder, no PowerShell or Bash. Its own memory stays writable.

## Simulated, not real

- The engine suite (`tests/suite.py`, 80+ checks on Linux and Windows) uses a stand-in for Claude Code
  (`tests/fake_engine.py`) that records what Theo asked for. It proves Theo's side (arguments, limits, budgets, files),
  not Claude Code's answers.
- The connectors in the Windows test are two local test servers (`tests/echo_mcp.py` and a missing program), not claude.ai
  connectors such as Gmail or Notion.
- The sign-in test checks that PowerShell starts with the right command. No one types in the browser sign-in.

## Only a real PC with a person can check

About 30 minutes on a Windows 10 or 11 PC:

1. **SmartScreen.** The installer isn't signed, so Windows warns "Windows protected your PC". Check More info then Run
   anyway works, and that Defender doesn't quarantine `Theo.exe` or `theod.exe`.
2. **Sign in.** In setup, press Sign in, finish the browser sign-in, and check Theo shows Signed in without a restart.
3. **Your own connectors.** Connect Gmail or Notion on claude.ai, check they show Connected on the Connectors page, give one
   to a bot and ask it to use it.
4. **Notifications and tray.** With the window closed, give a bot a job that needs you. Check the toast appears with Theo's
   name and icon, note what clicking it does, and check the tray icon's right-click menu has Open Theo and Quit Theo.
5. **Restart the PC.** Theo should start in the tray at sign-in, with no window.
6. **Display.** Check a 150% or 200% scaled screen and dark mode look right.
7. **Unusual setups**, if you have them: a username with a space or non-English letters, a PC with no Git, a work PC whose
   AppData is on a network drive, and a Windows on ARM PC (Theo is x64 only, so it runs under emulation).

## Known limits

- Coding runs on very deep folders can hit Windows' 260-character path limit unless long paths are turned on.
- Hooks written in Python need a real Python. The Microsoft Store stub that opens the Store won't run them.
- The .msi leaves the sign-in Run entry behind when it uninstalls. The per-user installer removes it.
