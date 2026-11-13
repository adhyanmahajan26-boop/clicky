# Theo against Hermes and OpenClaw

What two well-known agent harnesses provide, item by item, and whether Theo does it. Checked on 12 Nov 2026 against
Hermes Agent (NousResearch/hermes-agent, commit 34ecc0fa) and OpenClaw (openclaw/openclaw, commit 46350dafd), from their
own docs in those repos. "Probe" means a test in `Tools/parity-probes` that runs Theo in a test profile and decides the verdict
from Theo's files, the engine's calls and its processes. "Torture" means the 31-test suite from the earlier harness proof.

Grades: **Yes**, **Partly**, **No**. "Before" is branch theo-harness-review; "Now" is theo-harness-parity.

| # | Capability | Hermes | OpenClaw | Theo before | Theo now | How it was checked |
|---|---|---|---|---|---|---|
| 1 | An always-on process that owns the agents, their sessions and schedules | gateway | Gateway | Yes (the app, opens at login) | Yes | torture |
| 2 | Many agents, each with its own persona, workspace and sessions | profiles | multi-agent routing | Yes (bots) | Yes | torture |
| 3 | Persistent memory put into every session, with a size limit | MEMORY.md 2,200 chars, USER.md | MEMORY.md, USER.md | Partly: a file the bot is told to read; no limit | Yes: in the prompt, 4,000 chars, oversize shows start + newest and asks for a tidy | probes `memory_in_prompt`, `memory_cap` |
| 4 | A shared profile of the owner every agent sees | USER.md | USER.md | Partly (Theo's roster and team context; no shared owner file) | Partly | code |
| 5 | Recall of what was said before the current session | `session_search` (FTS5) | `sessions_search` | No: a lost session got the last 8 lines | Yes: the bot Greps its own chat, its group chats and its private threads (no search index) | probes `recall`, `recall_groups` (real Haiku) |
| 6 | Skills: procedures the agent writes itself and loads when a task matches | SKILL.md, agent-created | SKILL.md, ClawHub | No (`Skill` tool blocked, no skills) | Yes, except sync between Macs and a hub | probes `skills_create`, `skills_reuse` (real Haiku; the second bot's engine Read the first bot's SKILL.md) |
| 7 | Scheduled jobs with history, pause, run now | cron | automation jobs | Yes (routines) | Yes | torture |
| 8 | A missed run is caught up only if it's recent | grace window | scheduling slots | No: any old slot fired once on opening | Yes: half the period, 2 min to 2 h; older is recorded as missed | probes `catchup_stale`, `catchup_recent` |
| 9 | A check that finds nothing stays quiet | heartbeat `[SILENT]` / `NO_REPLY` | heartbeat → jobs | No: every run posted | Yes, for a bot's routines and a group's (`[SILENT]`) | probes `quiet_routine`, `quiet_group_routine` |
| 10 | A job fired by an outside event (webhook) | webhook-triggered cron | webhooks, Gmail PubSub | No | Yes: `POST /v1/routines/<id>/run` on the local API | probe `gateway_routine` |
| 11 | Programs on the machine can message an agent over HTTP | API server | OpenAI-style HTTP API | Partly: the control inbox and the T3 page server take any command as the owner's own words | Yes: local API, off by default, Keychain token, never counts as the owner | probes `gateway_*` |
| 12 | Chat apps (Telegram, Slack, WhatsApp, iMessage…) as channels | 6+ platforms | 20+ channels | No | No | — |
| 13 | Retry a failing model, then fall back to others | fallback providers | auth rotation + model fallback | Partly: OpenCode's free limit → Haiku only | Yes: 2 retries, then Sonnet → Haiku → Opus for Claude bots; Claude Code stands in for OpenCode and API-key bots | probes `retry_same_model`, `fallback_chain`, `no_fallback_on_auth`, `nonclaude_fallback` |
| 14 | Delegation to other agents | `delegate_task`, parallel batches | sub-agents, lanes | Partly: `[TELL:]`, one at a time; Clicky's team | Yes: different bots answer at the same time (4 by default), same caps | torture, probes `parallel_delegation`, `parallel_caps` |
| 15 | Caps on agents messaging each other in loops | iteration limits | queue caps | Yes (3 round trips, 12 a message) | Yes, also for messages from the local API | torture, probe `gateway_dm_cap` |
| 16 | What a message does while the agent is busy | interrupt and redirect | steer / followup / collect / interrupt | Partly: each waits its turn; Stop | Partly | code |
| 17 | Tool policy and sandbox per agent | approvals, write-safe root | sandbox modes, tool policy | Partly: no shell, writes only its folder, sends blocked; reads anywhere | Partly (reads: enforcement thread) | torture, code |
| 18 | Hooks on lifecycle events (session start, tool calls, boot) | event hooks, BOOT.md | internal hooks | No | Partly: owner scripts on app-started, turn-finished, routine-finished, gateway-message; no hooks around tool calls | probe `hooks` |
| 19 | Long sessions compacted | `/compress` | compaction | Partly: Claude Code compacts its own sessions; API-key bots don't | Partly | code |
| 20 | Interrupted work resumes after a crash or restart | session DB | restart recovery | Yes | Yes | torture, faults thread |
| 21 | Several devices as one assistant | — | nodes | Yes (two Macs over Theo Link) | Yes | torture |
| 22 | Usage and cost per agent | `/usage`, `/insights` | usage tracking | No for bots (Clicky's turns are logged) | Yes for Claude Code and OpenCode bots (by day, in settings and `/v1/usage`); API-key bots not counted | probe `usage` |
| 23 | Start a fresh session, retry or undo a turn | `/new`, `/retry`, `/undo` | `/new`, `/reset` | Partly (model and effort by words; no reset) | Partly: `/new` and a settings button; no retry or undo | probe `fresh_session` |
| 24 | A health check / doctor | `hermes doctor` | `openclaw doctor` | Partly (state commands, logs) | Yes: `/doctor` in any chat, control inbox, `/v1/doctor` | probe `doctor` |
| 25 | MCP tools | yes | yes | Yes (connectors, Theo's MCP server) | Yes | torture |
| 26 | Hand coding to coding agents | Codex runtime, worktrees | ACP agents, CLI backends | Yes (7 harnesses, branch, draft PR) | Yes | torture |

## Probe results

`docs/evidence/harness-parity`: `before` is theo-harness-review (12 round-one probes, 9 fail; 8 round-two probes, see `before-round-two`),
`after` is theo-harness-parity on a fresh profile (all 29 probes). The local-API probes have no "before": there was nothing to probe.
`owner_routine_control` shows the not-the-owner test can see a routine being added. On the old build `recall_groups` also got the answer, by asking Theo privately (Theo is told about group chats); on the new build the bot Grepped the group chat's file itself, which is what the probe now checks.

Totals now: 19 Yes, 6 Partly, 1 No (before: 8, 10, 8).

## What changed on theo-harness-parity

- `Bots/BotFailover.swift`, ClickyCore `EngineFailure` / `EngineFailoverPlan`: overloaded, rate-limited and 5xx errors are retried on the same model (3 s, then 10 s), then the turn moves along `v3.bots.fallbackModels` (default Sonnet, Haiku, Opus, skipping the bot's own). A missing model goes straight to the chain. A sign-in problem is never retried. The reply says which model answered. Stop ends a wait.
- Skills (`BotSkills`, ClickyCore `BotSkill`, `BotSkillsPrompt`): a bot writes `memory/<bot>/skills/<name>/SKILL.md` with `name` and `description` front matter; the owner can put shared ones in `memory/skills/`. Every bot's prompt lists all skills with their paths (40 at most), and the bot reads one before a matching task.
- Memory (`BotMemoryPrompt`): the memory file's contents go into the persona on every turn, up to 4,000 characters.
- Recall (`BotRecallPrompt`): bots are told where their chat is saved and to Grep it.
- Routines: `[SILENT]` from a routine run posts nothing and records the run as `quiet` (`RoutineQuiet`); a slot missed while Theo was closed runs only within its catch-up window, otherwise it's recorded as `missed` (`RoutineCatchUp`).
- Local API (`Bots/TheoGateway.swift`, ClickyCore `TheoGatewayHTTP`): see `AGENTS.md`.
- Round two: `[TELL:]` lines to different bots run at the same time (`v3.bots.parallelMessages`, default 4), checked against the caps first; usage and cost per bot and day (`BotUsage`, ClickyCore `BotUsageLedger`); hooks (`TheoHooks`, ClickyCore `TheoHookFiles`); `/new` and `/doctor` (`TheoDoctor+App.swift`); recall over group chats and private threads; quiet group routines; Claude Code standing in for other engines.

## Gaps that remain

- Chat apps as channels. See below: each needs something only Addy can make.
- Skills don't sync between the two Macs yet, and bot memory syncs by line union, so a line removed on one Mac comes back from the other and undoes a tidy-up. Both are with the coding-runs and two-Macs work.
- Reads aren't limited to a bot's folder, and the older T3 page server on 127.0.0.1:47320 and the control inbox run every command as the owner's own words. Both are with the enforcement work.
- Recall is a Grep: no search index and no summarising, so a very long history is slow to search.
- No hooks around tool calls (Hermes's `pre_tool_call`): Claude Code runs the tools, and Theo only sees the turn.
- No `/retry` or `/undo`, no structured output for delegation (Hermes's `output_schema`), no usage for API-key bots.

## What chat-app channels would need from Addy

Theo would talk to each one from the Mac itself, so none needs a public address or an open port. Each is a few hundred lines on top of the local API's "outside message" path, and every sender would be checked against an allowlist before anything reaches a bot.

| Channel | What Addy makes or grants | How Theo would connect |
|---|---|---|
| Telegram | A bot from @BotFather (its token), and Addy's numeric Telegram user id for the allowlist | Long-polling the Bot API (`getUpdates`) from the Mac |
| Slack | A Slack app in Addy's workspace with Socket Mode on: a bot token (`xoxb-…`) and an app-level token (`xapp-…`, `connections:write`), scopes `chat:write`, `im:history`, `app_mentions:read`; Addy's member id | Socket Mode WebSocket from the Mac |
| iMessage | A Mac signed in to Messages (ideally a separate Apple ID for the bot), Full Disk Access for Theo to read `~/Library/Messages/chat.db`, and Automation permission for Messages to send | Reading the Messages database, sending through Messages (OpenClaw uses the `imsg` CLI for both) |
| Discord | A bot application (its token) with the Message Content intent, invited to a server; Addy's user id | Discord gateway WebSocket from the Mac |
| WhatsApp | Either a Meta WhatsApp Business account with Cloud API access, which also needs a public HTTPS webhook, or linking a phone with an unofficial WhatsApp Web client, which can get the number banned | Not recommended without Addy deciding which |

Tokens would go in the Keychain like the local API's. Telegram is the quickest to add: one token and one user id.
