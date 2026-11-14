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

From the connector hub's list ([CONNECTORS.md](CONNECTORS.md)); apps on the Claude account get their status from `claude mcp
list`, which on Claude Code 2.1 prints `name: target - ✔ Connected`, `- ! Needs authentication`, or a failure mark. Rows sort
needs sign-in, can't connect, connected, not checked, off; each failed row says when it last worked. Under each row, every
bot has a level for the app (Off, Read only, Read and draft, Everything). A sign-in waiting for the browser shows a small card
with the address to copy.

## The tray

The tray icon is the micro face of the most urgent state (failed, then needs you, then working) with the count beside it
on a Mac menu bar and in the tooltip elsewhere; calm is the awake face.

## First run

A new data folder opens on setup (`setup.completed` unset), five steps with Theo's face following along (yellow while a
step still wants something, smiling at the end, finished steps ticked):

1. Welcome.
2. Claude Code: found or not, signed in or not, from `claude --version` and `claude auth status` (its JSON; the account's
   email and ids are never passed on). Sign in or Install opens a terminal with `claude auth login` or Claude Code's own
   installer (`curl -fsSL https://claude.ai/install.sh | bash`, or `irm https://claude.ai/install.ps1 | iex` on Windows);
   only those commands can be opened. Continue waits for a sign-in; Skip for now is there too.
3. Coding runs (optional): git and the GitHub CLI, with `gh auth login` the same way.
4. Your first bot: Researcher, Builder or Writer to start from, and Make your bot.
5. Done: things to try, and anything still missing as a folded line with its button.

## Make your bot

Preview at 150 px awake, with the five main states at 36 px under it, and option rows: Body (9 finishes), Trim (7), Eyes (5,
drawn as their light pattern), On top (antennas and hats), Extra, and Shuffle. Used in setup, New bot, and by clicking a
bot's face in its chat header to change how it looks.

## Notifications

A bot that starts needing you, or fails, gets one system notification ("Designer failed · Tool crashed: …"), through
Tauri's notification plugin: Notification Center on a Mac, toasts on Windows, the desktop's notification daemon on
Linux. Not for states that were already there when the app opened, not twice for the same event, and not while you're
looking at that bot's chat.

## Not in this build

The notch, voice (Talking, Listening), and the Clicky and Dictation product pages: those are Mac-only.
