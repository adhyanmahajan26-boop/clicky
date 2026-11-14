# Theo on a Windows PC: what's proven, and what only a real PC can check

Theo for Windows is tested by driving the real installed app on GitHub's Windows machines
(Windows Server 2022 and 2025, x64): the real installer, the real window (through WebView2's DevTools), the real
Claude Code from npm and from its own Windows installer, and the real Windows registry, Start menu and
notification system. `tests/windows_pc.py` is the test; the `windows-pc` and `windows-upgrade` jobs in
`.github/workflows/crossplatform.yml` run it and upload a summary with screenshots.

## Proven on Windows, for real

Each line is a step in `tests/windows_pc.py`, run on both Windows versions.

- The per-user installer runs silently with no admin prompt, and adds Theo to the Start menu.
- Opened from the Start menu, Theo shows first-run setup's brain step: paste an API key first, then every agent. With
  Claude Code missing, its row gives the Windows install command.
- Claude Code installed with npm (`%APPDATA%\npm\claude.cmd`, which isn't on Theo's PATH) is found, and is shown as signed out.
- Setup's Sign in button opens PowerShell running that Claude Code's `auth login`, by its full path.
- Claude Code from its own Windows installer (`irm https://claude.ai/install.ps1 | iex`) is found in `.local\bin`.
- Setup's coding step checks git and the GitHub CLI. Making the first bot lands in its chat.
- Messaging a bot runs the real Claude Code. When it's signed out, the chat shows the sign-in card with a Sign in button
  (Claude Code answers "Not logged in · Please run /login" as if it were a reply; Theo now treats that as signed out).
- A bot with 37,000+ characters of instructions over hundreds of lines still starts. Windows command lines stop at 32K
  characters (8K through cmd), so instructions and tool rules go in files and the message goes on stdin.
- Connectors on the Claude account come from the real `claude mcp list` on Windows (through the connector hub). A working
  server shows Connected, and a broken one shows Can't connect with its reason. Giving a bot an app from the Connectors page
  adds that app's tools to the bot's allowed list. The hub's helper is installed beside the app (`install_ps_test.py`).
- Open at sign-in writes the Windows Run key, and that start opens Theo in the tray with no window.
- Closing the window keeps Theo running in the tray. A bot that needs you raises a Windows notification (logged as sent by
  Windows' notification API).
- Opening Theo again while it runs brings the same window back instead of starting a second copy.
- Setup's steps are Welcome (your name), Pick a brain, Pick what you want (Theo, Clicky, Dictation), then Theo's coding
  check and first bot when Theo is on, then done.
- Quit leaves nothing running. Opening again keeps bots and chats. Setup comes back only while no brain can think (the Mac's
  rule), on its brain step with Not now.
- The Update row is at the bottom of the sidebar. Settings › Updates says which build this is and where builds come from,
  and Settings › Products has the three switches.
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

- Dictation's path from a WAV file to tidied text (`dictationTest`, suite cases D01 and D02) uses stand-in speech services
  (`tests/fake_voice.py`); D02 asks Windows' real built-in recognizer on the Windows runners. No microphone, keyboard hook
  or typing into another app is exercised in CI.
- The engine suite (`tests/suite.py`, 80+ checks on Linux and Windows) uses a stand-in for Claude Code
  (`tests/fake_engine.py`) that records what Theo asked for. It proves Theo's side (arguments, limits, budgets, files),
  not Claude Code's answers.
- Codex, Cursor Agent, Gemini CLI and Grok are played by the same stand-in in each one's own output format, and API keys
  by a stand-in model API (`tests/fake_api.py`, Anthropic and OpenAI-style). The suite proves the arguments, the hub each
  is given and the tool loop, not those programs' or providers' real answers.
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
6. **Other brains.** In setup, paste a real API key (OpenAI or Anthropic) and check the first bot answers with it. Install
   and sign in one of Codex, Cursor Agent, Gemini CLI or Grok from Settings › Brains, put a bot on it and give it an app.
7. **Display.** Check a 150% or 200% scaled screen and dark mode look right.
8. **Dictation** (about 10 minutes, a headset or the laptop's own mic). Settings › Dictation › Use Dictation (or pick it in
   Setup's products step). Then:
   - With no key saved: open Notepad, hold **Ctrl + Win**, say "this is a dictation test", let go. The pill near the bottom
     shows a moving level while you hold, "Transcribing", then "Typed" and the words, and the words land in Notepad. If
     this PC has no Windows speech recognizer for its language, the pill (and Settings › Dictation's test) says so in plain
     words and how to add one.
   - Check letting go of Win doesn't open the Start menu, Ctrl + Win + D still makes a new desktop (and doesn't dictate),
     and Esc while holding cancels.
   - Save a key (Settings › Dictation: Sarvam, OpenAI, Groq, Deepgram or AssemblyAI). Dictate a longer sentence with an
     "um" and a repeated word into Word or a browser text box; check it comes back tidied ("Tidies with …" in Settings
     says which brain), in under about 4 seconds after letting go.
   - Copy something first, dictate, then paste with Ctrl+V: your copied thing should come back, and Win+V's clipboard
     history shouldn't list the dictated words.
   - Dictate into a password box (a browser's sign-in page): nothing is typed, and the pill says it's a password field.
   - Pick another microphone and another shortcut in Settings › Dictation and check they take effect at once.
   - In a bot's chat, press the mic button in the message box (or Ctrl+Shift+D), talk, press it again: the words land in
     the box and aren't sent. Esc cancels.
   - Turn on Clicky too (if it's in this build): Ctrl + Alt is Clicky's and never starts dictation, Ctrl + Win never starts
     Clicky.
   - Turn off Windows' microphone access (Settings › Privacy & security › Microphone) and hold the chord: the pill says
     where to turn it back on.
9. **In-app update.** Install an older build with the per-user setup.exe. If the releases repo is private, open Settings ›
   Updates and save a GitHub token that can read it (the row then says it's saved in the Credential Manager, and the
   token is never shown again). Press Check for updates: the Update row at the bottom of the sidebar says "Build N". Press it (or Update to build N). Theo should close,
   update with no installer window and no admin prompt, and open again by itself on the new build. Settings › Updates
   should then say "Updated to build N", and your bots and chats should still be there.
10. **Products.** In Settings › Products, turn Theo off. The bots, groups, Routines and Usage should leave the sidebar,
   and Home should show the products page. Turn it back on and everything should come back.
11. **Unusual setups**, if you have them: a username with a space or non-English letters, a PC with no Git, a work PC whose
   AppData is on a network drive, and a Windows on ARM PC (Theo is x64 only, so it runs under emulation).
9. **Routines.** On Routines press New routine, pick a bot, write what it does, pick Weekly, a day and a time, and Add
   routine. Check the card says "Every <day> at <time> · next in …". Press Run now, then open "Last run …" to see the run.
   Edit it to Every N hours, turn it off (Paused shows), then on again; Delete asks "Delete it?" first.
10. **Chat cards.** Ask a bot for a long write-up with headings: it shows as a brief card; Open reads it in full, Share
    copies it. Ask a bot to "make a PDF of your notes" (it writes a file in its folder and adds `[PDF: notes.md]`): the PDF
    card's Open opens it in your PDF reader. Ask a bot to choose with you: a `[CHOOSE: …]` shows as buttons or a list with
    Use this and Skip. Turn a bot off in its settings: its chat shows "This bot is off" with Turn on. Ask Theo to ask another
    bot something: the private exchange folds into one card that opens.
11. **Sign-in words for each brain.** Put a bot on an agent that's signed out (Codex, say): the card says "Codex is signed
    out" with Sign in (opens a terminal) and Use an API key instead, never Claude Code. Put one on a bad API key: the card
    says the key didn't work and opens Settings.
12. **Home.** With a bot that needs you, one that failed and one working, check Home's lanes: the sign-in or choice card can
    be answered right there, Try again on the failed one, and Asleep shows a bot's next routine with Run now.
13. **The run card.** Ask a bot for a coding plan without asking it to build: the "Start this coding run?" card has the
    agent, folder and chat choices. Pick New folder…, type a name (made in the projects folder with git), Start run; or pick
    an existing folder where you've used Claude Code before and a chat from the list, and Continue chat (it carries on that
    session in the folder, no branch). Change the projects folder from the card's Change link.
14. **Connectors page.** Click a row to open its details (Reached, Last worked, Used by, each bot's level). Remove… asks
    before removing. Add your own with Address (https only) or Command.

## Known limits

- Coding runs on very deep folders can hit Windows' 260-character path limit unless long paths are turned on.
- Hooks written in Python need a real Python. The Microsoft Store stub that opens the Store won't run them.
- The .msi leaves the sign-in Run entry behind when it uninstalls. The per-user installer removes it.
- Dictation can't type into an app running as administrator (Windows keeps a normal app's keys out of it) unless Theo
  runs as administrator too. On keyboards where AltGr sends Ctrl + Alt, a Ctrl + Alt chord also fires on AltGr.
