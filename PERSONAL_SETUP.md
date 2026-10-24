# Personal Clicky — Setup

Clicky running on your Claude subscription. No API keys, no tracking.
Phases done: 1 (subscription) and 2 (hands-free mode).

## 1. Sign Claude Code in (once)

```bash
claude auth login
```

Sign in with your Claude account (Pro or Max). Check it worked:

```bash
claude auth status
```

`"loggedIn": true` means you're ready.

## 2. Open and run in Xcode

```bash
open leanring-buddy.xcodeproj
```

1. Click the blue **leanring-buddy** project at the top of the left sidebar.
2. Select the **leanring-buddy** target → **Signing & Capabilities**.
3. Under **Team**, choose your own Apple ID (add it via Xcode → Settings → Accounts if needed).
4. Press **⌘R**.

Always run from Xcode with ⌘R. Building from Terminal makes macOS forget the
app's permissions.

## 3. Grant permissions

Click the Clicky icon in the menu bar and grant:

- **Microphone** — to hear you
- **Speech Recognition** — on-device transcription
- **Accessibility** — for the push-to-talk hotkey (and later, scrolling for you)
- **Screen Recording** — to see your screen (macOS may ask you to quit and reopen the app)

Then press **Start**.

## 4. Use it

- **Hold Control + Option**, talk, let go.
- Clicky looks at your screen, answers out loud, and flies its blue cursor to what it's talking about.
- Pick **Sonnet** (faster) or **Opus** (smarter) in the menu-bar panel.
- The panel shows **"Claude subscription connected"** when Claude Code is signed in. If it says signed out, run `claude auth login` and click the row to re-check.

## Hands-free mode (phase 2)

**Double-tap Control + Option** (or click **Start hands-free session** in the
menu-bar panel). A pill appears at the top of your screen: the mic stays
open and you just talk.

| Say | What happens |
|---|---|
| anything else | Goes to Claude with a screenshot, answered out loud |
| “wait” / “stop” / “hold on” | Cuts Clicky off instantly and pauses |
| “go” / “keep going” | Un-pauses |
| “capture” / “screenshot” | Saves a full-resolution screenshot (camera count in the pill goes up) |
| “slower” / “faster” | Sets scroll speed for the autopilot (phase 4) |
| “done” / “that's it” | Ends the session and opens the captures in Finder |

**Esc** stops everything at any time. Double-tapping Control + Option again
also ends the session.

Captures are saved to `~/Pictures/Clicky/Session <date>/`.

If Clicky doesn't hear you well in hands-free mode, try turning echo
cancellation off (then quit and reopen Clicky):

```bash
defaults write com.personal.clicky handsFreeEchoCancellationDisabled -bool YES
```

## Better voice (optional, free)

System Settings → Accessibility → Spoken Content → System Voice → Manage Voices,
and download a **Premium** or **Enhanced** English voice. Clicky picks the best
one installed automatically.

## What's next

- Phase 3: live marks (circles, arrows, numbered steps)
- Phase 4: autopilot scroller + auto-capture
- Phase 5: "do it for me" agent (point-and-say "this, this, this — fix")
- Phase 6: screenshot markup editor
- Phase 7: session notes
