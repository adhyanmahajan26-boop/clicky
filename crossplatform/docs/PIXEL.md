# Theo Pixel on Windows and Linux

The desktop app uses the Pixel kit as it ships (`app/ui/kit/theo-pixel.css` and `theo-pixel.js`, copied unchanged from the
design kit), so the faces, frames, timings, badges, pills, the small card (`.tc`) and connector rows (`.crow`) are the
same as the Mac app's. Screenshots are in `screenshots/`.

## What drives the faces

The engine decides each bot's state (`theo-core/src/faces.rs`, one function, unit-tested rule by rule) and reports it in
`botsState.faces`: the state, its word, one line of detail, since when, unread, and the bot's look. First match wins:

| State | When |
|---|---|
| Off | the bot is turned off |
| Needs you (yellow) | Claude Code is signed out or missing on this computer, a card in its chat waits for an answer, or its last message asks you to choose |
| Failed (red) | its last turn or coding run failed; cleared when you open its chat, press Try again, or give it new work |
| Working (green) | it's writing, or a coding run of its chat is going |
| Thinking (green) | it has started but nothing has come back yet, or messages wait behind it |
| Done | it has an unread answer, or answered in the last two minutes |
| Ready | something happened in the last ten minutes (Theo is always ready when calm) |
| Asleep | anything else |

Talking and Listening are voice states; voice isn't part of this build.

## Cards

| Card | Tone | Where it comes from |
|---|---|---|
| Sign in to Claude Code / Install Claude Code | needs | a turn failed because Claude Code is signed out (`/login`, bad key) or isn't installed; Try again asks your last message again, once |
| A failure, in plain words, with See details | failed | a turn failed any other way; Try again |
| Set up this routine? | needs | a bot wrote a routine you didn't ask for (from a page, a routine's own run, a script on the local API). Nothing is set up unless you press Set it up; it's never set up twice |
| Start this coding run? | needs | a bot wrote a coding prompt for a message that didn't ask to build. Nothing starts unless you press Start it |
| A choice | needs | `[CHOOSE: question | Option: detail | …]` in a reply; a tap sends the option |
| The run card with the five-step bar | working, done, failed | a coding run |
| Folded line | | any card once answered, a private message between bots, an older failure |

These replace the Swift harness's notes for the same events ("you didn't ask for one, so Theo didn't set it up"): the
harness's rule is unchanged (only your own words start runs and routines by themselves), and the card is how you say yes.

## Connectors

From `claude mcp list`, which on Claude Code 2.1 prints `name: target - ✔ Connected`, `- ! Needs authentication`, or a
failure mark. Rows sort needs sign-in, can't connect, connected; each failed row says when it last worked.

## The tray

The tray icon is the micro face of the most urgent state (failed, then needs you, then working) with the count beside it
on a Mac menu bar and in the tooltip elsewhere; calm is the awake face.

## Not in this build

Setup's seven steps and Settings › Products (the desktop app has no setup flow yet), the notch, alerts as system
notifications, and Make your bot's full option rows (the New bot dialog shows the look in five states with Shuffle).
