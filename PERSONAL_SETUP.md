# Personal Clicky — Setup

Clicky running on your Claude subscription. No API keys, no tracking.
Phases done: 1 (subscription), 2 (hands-free mode), 3 (live marks), plus the Claude spark companion with helper workers.

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

### Why the Team matters

Without a Team, Xcode signs Clicky "to run locally" (ad-hoc). macOS then
ties Accessibility and Screen Recording to that exact build, so **every
rebuild looks like a new app and the permission prompts come back**. With
your Apple ID's team selected, the signature stays the same across rebuilds
and you grant permissions once. A free Apple ID works ("Personal Team").

## 3. Grant permissions

Click the Clicky icon in the menu bar and grant:

- **Microphone** — to hear you
- **Speech Recognition** — on-device transcription
- **Accessibility** — for the push-to-talk hotkey (and later, scrolling for you)
- **Screen Recording** — to see your screen (macOS may ask you to quit and reopen the app)

Then press **Start**.

## 4. Use it

- **Hold Control + Option**, talk, let go.
- Clicky looks at your screen, answers out loud, and flies its orange spark to what it's talking about.
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
| “clear” / “clear marks” / “erase” | Removes the marks Clicky drew on screen |
| “done” / “that's it” | Ends the session and opens the captures in Finder |

**Esc** stops everything at any time. Double-tapping Control + Option again
also ends the session.

Captures are saved to `~/Pictures/Clicky/Session <date>/`.

If Clicky doesn't hear you well in hands-free mode, try turning echo
cancellation off (then quit and reopen Clicky):

```bash
defaults write com.personal.clicky handsFreeEchoCancellationDisabled -bool YES
```

## Live marks (phase 3)

When an answer involves places on your screen, Clicky draws on top of it while
it talks: **numbered steps** (1, 2, 3…) for "click this, then this", a
**circle** around the thing it's talking about, and an **arrow** for small or
easy-to-miss targets. Nothing to turn on; ask something like "how do I turn
on dark mode?" with System Settings open.

Marks go away when you ask the next question, press **Esc**, say **“clear”**
in a hands-free session, or 20 seconds after Clicky stops talking.

## The spark companion and helper workers

The orange spark next to your cursor is Clicky's main brain. It breathes
gently while idle and **spins while it's thinking**.

For questions that split into separate smaller parts (for example "compare
these three plans" or "what's wrong in each of these two windows"), the main
brain can hand the parts to **helper workers** that run at the same time on
the faster Haiku model. Each running worker is a **mini spark orbiting the big
one**; it fades away when it's done. Up to four run at once, and extra ones
wait in line. When they're all back, the main brain gives you one spoken
answer. Simple questions don't use workers.

**Esc** or saying **“stop”** cancels the main brain and every worker.

In Debug builds the menu-bar panel has a **Companion** row: **Think** makes
the spark spin and **0–4** adds simulated workers, so you can see the
animations without asking anything.

Previews: `docs/companion-preview/`.

## If Clicky keeps asking for permissions

The project is now set to Addy's Personal Team (`9JAQUUW553`), so builds are
signed with an Apple Development certificate and permissions survive rebuilds.
If the team ever goes missing (e.g. a different Mac), use one of these:

**No Apple ID needed:** run this once in Terminal:

```bash
bash ~/Projects/clicky/scripts/setup-local-signing.sh
```

It creates a local signing certificate called "Clicky Local Signing" in your
login keychain (macOS asks for your login password once) and clears Clicky's
old permission entries. After that the project is switched to sign with it,
so every rebuild keeps the same signature.

**Or, with an Apple ID:** Xcode → Settings → Accounts → **+** → sign in, then
pick your account under the target's **Signing & Capabilities → Team**.

Either way, press **⌘R** afterwards and allow each permission once. If Screen
Recording says to quit and reopen, press ⌘R again.

## Voice

Clicky speaks with **Qwen3-TTS**, a local AI voice run by MLX Core's
`mlx-serve` (free, offline). Clicky starts the voice server itself (only on
127.0.0.1) and loads the model at launch, and stops it when Clicky quits.
Long answers are spoken sentence by sentence, so it starts talking quickly.
If MLX Core isn't installed or the server can't start, Clicky falls back to
the Mac voice. Pick the voice under **Voice** in the panel (▶︎ previews it).

### Better Mac voice (fallback, free)

Clicky only sounds as good as the Mac voices installed. Out of the box macOS
has robotic "compact" voices. To fix that:

1. Click the "Sounds robotic? Download a Premium voice" link under **Voice**
   in Clicky's panel (or System Settings → Accessibility → Spoken Content).
2. **System Voice → Manage Voices…** → English → download a **Premium** voice
   (e.g. Zoe, Ava, Evan or Nathan; Premium ones are ~200–400 MB).
3. In Clicky's panel, pick it under **Voice** (or leave it on Automatic, which
   picks the best installed voice) and press ▶︎ to preview.
## What's next

- Phase 4: autopilot scroller + auto-capture
- Phase 5: "do it for me" agent (point-and-say "this, this, this — fix")
- Phase 6: screenshot markup editor
- Phase 7: session notes
