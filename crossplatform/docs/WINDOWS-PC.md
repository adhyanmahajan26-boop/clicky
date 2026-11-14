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

- Clicky's turns in CI (`clickyTest`, suite cases K01 to K05) get the pictures from the test and stand-in brains
  (`tests/fake_api.py`, `tests/fake_engine.py`); K05 captures the Windows runner's real monitors and speaks to a file with
  its real voices. No microphone, keyboard hook or spark over another app is exercised.
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
9. **Clicky** (about 10 minutes; best with two monitors, one of them scaled to 150% or more). Settings › Clicky › Turn on
   (or pick it in Setup's products step, or the tray's "Show Clicky"). Then:
   - The orange spark sits by the pointer on every monitor and follows it smoothly. Clicks go through it to whatever is
     underneath, it never takes focus from the app you're typing in, and it stays over a maximized window.
   - Open a web page, hold **Ctrl + Alt**, ask "where's the search box?", let go. The spark pulses while you talk, spins
     while it thinks, an answer appears in a bubble by the pointer and is spoken, and the spark flies to the search box and
     back. Ask about something on the other monitor: it flies there and lands on the right spot, also on the scaled one.
   - Ask "walk me through the settings on this page": numbered steps or circles appear on the screen and clear after about
     20 seconds, or at once on Esc. Esc while it's talking stops the voice.
   - Settings › Clicky: pick another voice and press Hear it; set the spark to "Only while talking" and check it hides when
     idle; pick another shortcut and check it works at once and Ctrl + Alt no longer does.
   - Brains: with only an API key (Anthropic or OpenAI) it should still see the screen; put Clicky on Gemini CLI (Brain row)
     and check it says once that it can't see the screen and answers from your words.
   - Type a question in "Try it" and press Ask: the same turn runs without the microphone, and the answer shows there too.
   - Turn on Dictation with its own chord too: Ctrl + Alt is only Clicky's, Ctrl + Win only Dictation's. Set Dictation to
     Ctrl + Alt as well: Settings › Clicky says the two share keys and Clicky stands aside.
   - Turn Clicky off: the spark goes away on every monitor and Ctrl + Alt does nothing.
10. **Unusual setups**, if you have them: a username with a space or non-English letters, a PC with no Git, a work PC whose
   AppData is on a network drive, and a Windows on ARM PC (Theo is x64 only, so it runs under emulation).

## Known limits

- Coding runs on very deep folders can hit Windows' 260-character path limit unless long paths are turned on.
- Hooks written in Python need a real Python. The Microsoft Store stub that opens the Store won't run them.
- The .msi leaves the sign-in Run entry behind when it uninstalls. The per-user installer removes it.
- Dictation can't type into an app running as administrator (Windows keeps a normal app's keys out of it) unless Theo
  runs as administrator too. On keyboards where AltGr sends Ctrl + Alt, a Ctrl + Alt chord also fires on AltGr.
- Clicky's Ctrl + Alt has the same AltGr catch: typing an AltGr letter cancels the listen at once, but someone who holds
  AltGr alone will wake Clicky; pick another shortcut in Settings › Clicky on those keyboards. Clicky can't see a window
  that blocks capture (some video players, DRM content): those parts of the picture come back black.
