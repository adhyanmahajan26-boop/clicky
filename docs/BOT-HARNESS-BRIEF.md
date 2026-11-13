# Theo bot harness: make the core work (brief for the Mac Studio session)

Written 2026-11-05 by the cloud side of the thread "Make Theo bot harness production-ready".
Addy asked for Opus at max effort, subagents allowed, and cheap models for every test run.
This is the pass that has to make Theo work as a **bot-building harness**, the thing it competes on with
OpenClaw and Hermes Agent. Nothing is done until it has been tried for real and looked at.

---------------------------------------------------------------------------------------------------
## 0. Addy's words today (verbatim, 2026-11-05 08:27 UTC)

> opus i told you to do final testing so it can be production level but you cn see form my recent things , its a bot
> building harness at its core it has not been able to develop basic structures like developing talking between bots ,
> how to write , and chats between bots private if i want to see them i press button , i only see they messaged each
> other like and i can press it to expand even it guys group kept writing so fat i doubt they read it anything also they
> didnt understand they gave option to open folders on air but try to connect to mac studio for coding which is super
> confusing and wierd after all this building they cant detect device or thier purpose or understand beyong reason you
> give them please i want it fixed [...] i want it to work like grok bot production level currently it is confused
> berween itself only how will anyone build bots on it it is competitor of open claw and hermes [...] this your last
> chane for testing use open code or cheaper haiku models so our testing doesnt get empty subscription [...] you harness
> is confused about device only and no making new folder option in choose folder for t3 code or any harness or option
> to choose already built chats in harness so we can continue man i want it done and finished with no bugs whatsover

What that means, as six jobs:

1. **Bot-to-bot messages are private.** In a chat Addy only sees one small line, "Theo messaged Coder", and one click
   expands it to the whole exchange. The other bot's own chat with Addy is not filled with it.
2. **Bots actually read each other.** In a group chat (his "IT guys") they wrote too fast, talked past each other and
   didn't understand. They take turns, read what was said, and build on it.
3. **How bots write.** One clear way to message a bot, one clear way to hand work over in a group, and a house style
   for messages. Today two mechanisms and contradictory instructions exist (see 2.B).
4. **Bots know where they are and what they're for.** Which Mac they run on, which Mac Addy is on, where folders and
   coding runs are, their own role, team and boss, and what Addy is really after. No more "pick a folder on the Air,
   then run on the Studio".
5. **Folder picker:** make a new folder right there, for T3 Code and every harness.
6. **Continue an existing chat:** pick a T3 Code thread (or Claude Code / Codex / Cursor / OpenCode / Gemini session)
   that already exists in that folder and carry on in it, instead of always starting a new one.

Plus: the "hi" fix (build 202611051238, committed on `theo-ui-crew` on the Studio, never installed) ships in this build.

---------------------------------------------------------------------------------------------------
## 1. Rules (all still apply)

- Never record the screen. Screenshots of Theo's own window only (`Tools/theoui.py shot`). Never the whole display.
- Don't move Addy's mouse, take focus or press real keys. Addy is working on the **MacBook Air** right now.
- Don't ask Addy to click macOS permission prompts. Never print, log or paste API keys.
- **All bot tests run in a test profile** (`Clicky --profile test-<name>`, see `docs/TESTING.md`), never in Addy's real
  chats. If anything lands in a real chat, clean it up and say so.
- **Cheap models only for test runs:** bots on `claude-haiku-5-5` (or OpenCode free models if its free limit has room),
  coding runs on Claude Code with Haiku at low effort, or OpenCode free. Tiny tasks ("make hello.txt that says hi").
  Opus/Sonnet only for this session's own engineering. Theo and Clicky stay on Sonnet in Addy's real setup.
- GitHub for tests: only `adhyanmahajan26-boop/theo-pr-sandbox`. No issues, comments or PRs anywhere else.
- No real bookings, payments, emails or messages to people.
- Don't kill processes you didn't start. Keep `/Applications/Theo.app` alone until the install step.
- Restarting Theo can nudge a monitor and the Studio screens: before installing on the Studio, check
  `pmset -g assertions` and wait until no video is playing.
- On the Air, install with the normal update path when Theo is idle (Link `updateWhenIdle`, or SSH install the same way
  the Nov 2 session did: `ssh adhyanmahajan@Adhyans-MacBook-Air.local`, key already in its authorized_keys; Remote Login
  may be off now, so check before relying on it).
- Stock T3 Code on the Air (v0.1.7, installed this morning) must stay stock: **Theo must not write its bots extension,
  MCP server, or anything into `~/.t3` or T3 Code's settings on the Air.** It may only use the `t3` CLI that T3 Code
  installs (`~/.t3/bin/t3`). Check `T3/ClaudiaT3Integration.swift`, `T3/T3ExtensionFiles.swift`, `T3/T3ConnectView.swift`
  for anything that does this automatically and gate it behind an explicit button.

---------------------------------------------------------------------------------------------------
## 2. What's wrong today (found by reading `theo-ui-crew` b086ad8)

### A. Bots and coding runs answer to two different "where" rules
- `Setup/DevicesSettings.swift` + ClickyCore `Link/DeviceRouting.swift`: feature `.bots` defaults to **Mac Studio**,
  so on the Air every bot message is forwarded to the Studio (`BotsStore.forwardToWorkMac`, ~line 476).
- Coding runs ignore that setting and use `TheoLink.isWorkMac` (= "has a work screen picked") instead:
  `BotsStore.submitToT3` (~978) sends every run from the Air to the Studio; `makeProjectFolder` (~588) too;
  `knownProjects` (~578) shows the Studio's project list on the Air; `projectChoice` (~560).
- But `T3HandoffButton.chooseFolder()` (`Bots/BotsView.swift` ~1562) opens an `NSOpenPanel` **on the Air**. The Air
  path is then sent to the Studio, where it doesn't exist or is a different folder. That's exactly "option to open
  folders on air but try to connect to mac studio for coding".
- Bots are never told which Mac they're on or which one Addy is using, so they can't explain or avoid it.

### B. Two contradicting bot-to-bot mechanisms
- `BotPrompts.persona` (~1346): "You may message these bots by writing **@Name** in your reply; they answer you in the
  chat". `relayMentions` (~1808) makes the other bot answer **inside Addy's chat** with the first bot, up to 3 hops.
- `directMessageNote` (`ClickyTeamStore.swift` ~679): "Put a line **[TELL: name: …]** … Writing their name … doesn't
  reach them: only that line does."
- Same turn, opposite instructions. A bot can't know which to use.
- `[TELL:]` today (`sendDirectMessage`, ~685): the room gets a bare "Messaged X privately." that can't be opened, and
  the message plus the reply are dumped into **X's own chat with Addy**, polluting it and confusing X next time.

### C. Group chats fire everyone at once
- `askTeam` (`BotsStore.swift` ~684) starts every target in a `for` loop at the same time; the critique round is
  parallel too. Each bot only sees "new since you last spoke", so members in the same round never see each other's
  replies. Result: fast, overlapping messages that don't build on each other.

### D. Folder picker and harness chats
- `chooseFolder()` sets `canChooseDirectories` but not `canCreateDirectories`, and there's no "New folder" or project
  list in the card. Nothing shows which Mac the folder is on.
- Every run starts a **new** T3 Code thread (`t3 thread start`) or a new CLI session. `HarnessCoding` only has a blind
  `--continue` / `resume --last` for follow-ups. There's no way to pick an existing chat.

### E. Bot memory lives in T3 Code's folder
- `NativeBot.memoryPath` is `~/.t3/bots/<id>/memory.md`. `~/.t3` is now stock T3 Code's data folder on the Air (its
  old contents were moved to `~/.t3-backup-20261105`). Bot memory also isn't synced over Theo Link.

---------------------------------------------------------------------------------------------------
## 3. What it has to do (the spec)

Reference designs worth 20 minutes before you build (read docs, don't copy code):
- **OpenClaw** agent-to-agent: `sessions_send` (message another agent's session, the reply comes back to the asker,
  short ping-pong capped at a few turns, then the asker carries on), `sessions_spawn` (isolated sub-agent that
  announces its result back), per-agent identity files (IDENTITY/SOUL/AGENTS.md) and a runtime line telling the agent
  which host and channel it's on. Docs: docs.openclaw.ai (multi-agent, session tools), or search for them.
- **Hermes Agent** (Nous Research): `delegate_task` sub-agents with their own context that return a summary, persistent
  memory files, environment info in the system prompt. Docs: hermes-agent.nousresearch.com, or search for them.
- **Grok Bot**, the app Addy measures Theo against: its data is in `~/.grokbot` on the Air (and maybe the Studio).
  Read-only, to see how it structures bots, their chats and bot-to-bot messages. Don't print anything secret from it.

### 3.1 One way for bots to talk, and it's private

- **In a bot's own chat (and in Theo's chat):** a bot reaches another bot only with a `[TELL: exact name: message]`
  line. Remove the @Name relay (`relayMentions`) as a way of messaging from 1:1 chats, and make every prompt say the
  same thing. `@Name` stays the hand-off inside group chats only (3.2).
- **Storage:** a private thread per pair of bots (e.g. conversation id `dm:<idA>+<idB>`, sorted), synced over Theo Link
  like other chats, with its own engine sessions per bot so each remembers earlier exchanges with that partner.
  Each exchange has an id; every DM message carries it.
- **Flow:** sender writes `[TELL: Coder: …]` → the exchange starts → Coder answers **in the private thread**, with its
  persona, the "where you are" block (3.3) and the last few messages of that pair's thread → the reply goes back to the
  sender in full (never truncated) → the sender carries on in the original chat and tells Addy what came of it.
  The sender may answer back with another `[TELL:]` to the same bot; cap an exchange at 3 round trips and one owner
  message at 12 DMs in all, and say so plainly when a cap stops it.
- **What Addy sees:** in the chat where it started, one compact card, collapsed by default:
  two small avatars, "Theo messaged Coder privately", time, a one-line preview, "2 messages", a chevron.
  While the other bot is answering it reads "Coder is replying…". One click expands it in place to the full exchange
  (author, avatar, rich text for each message); another click folds it. Use `BotChatMessage.card = "dm:<exchangeID>"`
  or similar and the existing tokens and components (`Theme/TheoTokens.swift`, `TheoComponents`, `HairlineIcon`,
  `CrewAvatar`). It must look like part of the product, not a debug line.
- **Coder's own chat with Addy is untouched.** Optionally a "Messages with other bots" list in each bot's header or
  details to browse its private threads read-only. DMs don't raise Addy's unread badges.
- **Every bot can read the DM it got.** The receiving prompt holds the whole message, says who sent it and why, and
  asks for a direct answer to that bot.

### 3.2 Group chats where bots read and take turns

- Addy posts → the group's head (manager) reads it first and either answers or hands parts out with `@Name`.
- Members who were handed something answer **one at a time**, in the order the head named them. Each sees everything
  said since Addy's message, including the member who just answered, with names. A short beat (about a second)
  between turns; the typing state shows who's writing now and nobody else.
- Member prompt: read what the others said; don't repeat a point already made; agree in a few words or add what's
  new; answer the part you were given; use `@Name` only to hand something on.
- When the last member is done, the head reads the round and writes **one** wrap-up for Addy. Then it stops.
  Members never start new rounds on their own; keep the existing chain cap.
- The critique / merge steps of a build discussion run the same way: one at a time, then the head merges.
- Stop on the group stops all of it at once.

### 3.3 Bots know where they are and what they're for

**Where things run: "Theo works on the Mac you're using."**
- A message typed on a Mac is answered on that Mac: the bot's turn, its file tools, any coding run it starts, the
  folder list it sees and any folder it makes are all on **that** Mac. Chats, bots, groups, layout, Clicky's team and
  bot memory stay the same on both Macs through Theo Link (as now, plus memory, see below).
- Split the Devices setting: **Bots & coding** (default: the Mac you're using) and **Routines** (default: Mac Studio,
  so a routine fires once, on the always-on Mac). Studio screens and the research browser stay on the Studio and keep
  being asked for over the Link as now. Migrate the old `.bots = Mac Studio` default once so existing setups move to
  the new default (check whether Addy set it by hand on either Mac first; report what you find).
- If a bot's engine can't run on this Mac (CLI missing or signed out) and the other Mac is connected, that one turn
  goes to the other Mac, and both the chat ("Answered on Mac Studio: Grok isn't signed in on this MacBook Air") and the
  bot's own prompt say so. Never silently.
- `isWorkMac` must no longer decide where coding runs or folders are. It only means "has the work screen".
- **Coding runs carry their device.** The run card shows it as a chip ("This MacBook Air" / "Mac Studio"), and the
  folder, new-folder and continue-chat choices always come from that same device. Picking "Mac Studio" from the Air
  lists the Studio's projects (synced over the Link, both ways now) and "New folder on Mac Studio…", and the run goes
  over the Link with its device named. The receiving Mac checks the folder exists before starting. It is impossible to
  pick a folder on one Mac and run on the other.
- **Bot memory:** move it out of `~/.t3` to Theo's own folder (`~/Library/Application Support/Theo/Bots/<id>/memory.md`
  or similar), migrating what exists in `~/.t3/bots` and `~/.t3-backup-20261105/bots`, and sync it over the Link
  (line union, no duplicates).

**A "where you are" block on every bot turn** (short, refreshed each turn like `ceoTurnNote`, since a resumed engine
session keeps old context). Example:
> Where you are now: you're running on Addy's MacBook Air, the Mac Addy is typing on. Folders and coding runs from
> this chat are on this MacBook Air (~/Projects: a, b, c). Ready here: Claude Code (signed in), T3 Code 0.1.7, Codex.
> Addy's other Mac, the Mac Studio, is connected; it has the hidden screens for [SCREEN:] jobs and the research
> browser. Never offer a folder on one Mac and run on the other.

**A "who you are" block** (identity and purpose, OpenClaw-style), built from the bot's name, description,
instructions, team, manager, authority and apps:
> You're Coder, Addy's coding bot. Your job: … You're on the IT guys team; your manager is Theo, the CEO. You can:
> chat, message other bots privately with [TELL:], hand coding to a harness with a ```prompt block, set routines, use
> Gmail. When a request is outside your job, say who on the team fits and offer to message them.
> Work out what Addy actually wants, not just the literal words; if the next step is obvious and safe, take it; ask one
> short question only when you really can't tell.

Keep these short. Measure the added prompt size and keep the two blocks under ~250 words together.

### 3.4 How bots write

- One protocol, the same in every prompt: `[TELL: name: message]` for a private message; `@Name` to hand work over
  inside a group chat; ```prompt / ```followup for coding; ```routine for schedules; `[SCREEN:]`, `[RESEARCH:]` as now.
  Delete contradicting sentences. Unit-test the assembled prompts for contradictions (e.g. no prompt contains both
  "writing @Name reaches them" and "only [TELL:] reaches them").
- House style for every bot message: talk to whoever you're answering; short (1–4 sentences unless asked for depth);
  no name or heading at the start; refer to what the other person actually said; never claim something happened that
  hasn't; when waiting on someone, say who and for what.

### 3.5 Folder picker with "New folder"

- The run card's folder button becomes a menu: the device's recent and known projects (one click), **New folder…**
  (asks for a name, makes `~/Projects/<name>` on that device with `git init` and an empty first commit, then selects
  it), and **Choose a folder…** (this Mac only: `NSOpenPanel` with `canCreateDirectories = true`, so its own New Folder
  button works too). Same menu wherever a folder is picked for any harness (T3 Code, Claude Code, Codex, Cursor,
  OpenCode, Grok, Gemini, Cursor cloud).
- "Make a new folder called X" in chat keeps working, on the Mac Addy typed it on.

### 3.6 Continue an existing harness chat

- Next to the folder, a **Chat** menu: "New chat" (default) plus that folder's existing chats for the chosen harness,
  newest first, with title and age. Picking one continues it, and the run card says "Continuing <title>".
- Verify every command on this Mac with `--help`; don't guess. Starting points:
  - T3 Code: `t3 thread list --project <folder> --json`, continue with `t3 thread send <id> -`. Stock T3 Code (the Air)
    has `list/start/send/show` but no `--effort` and no `thread stop`; the fork (the Studio) has both. Handle both.
  - Claude Code: sessions in `~/.claude/projects/<folder path with / and . as ->/*.jsonl`; title from the summary or
    first user message; `claude --resume <id>`.
  - Codex: `~/.codex/sessions/**/rollout-*.jsonl` (first line has the cwd); `codex resume <id>` /
    `codex exec resume <id>`.
  - Cursor: `cursor-agent ls` / `--resume <chatId>`. OpenCode: `opencode session list` / `--session <id>`.
    Gemini: `gemini --list-sessions` / `--resume <id>`. Grok: whatever its `--help` offers; if nothing, show only
    "New chat" for it.
- Bots can ask for it too: a ```prompt block with a line `Continue: <thread or session id>` (or the title Addy said)
  continues that chat. Put it in `codingHowTo`, and list the folder's recent chats in the bot's turn when Addy talks
  about carrying on earlier work.
- Follow-ups on a run keep using the exact thread or session the run is on, never "the last one in this folder".

---------------------------------------------------------------------------------------------------
## 4. How to work

1. **Start:** find the code (`~/Projects/clicky-ui-crew` on `theo-ui-crew` is where the hi fix was made; `~/jstest/theo-ui`
   is the working folder). Push `theo-ui-crew` if it's ahead of origin. Then
   `git fetch origin theo-bot-harness && git checkout -b theo-bot-harness origin/theo-bot-harness && git merge theo-ui-crew`
   and work there. This file is `docs/BOT-HARNESS-BRIEF.md` on that branch; re-read it if the cloud side updates it.
2. **See it fail first.** Read Addy's real chats (read-only) in `~/Library/Application Support/Theo` on the Studio: the
   "IT guys" group chat, recent `[TELL:]` / "Messaged … privately" exchanges, and any chat where a folder on the Air was
   picked and the run went to the Studio. Copy the relevant bits to `~/jstest/theo-ui/harness-core/evidence/` and note
   what went wrong in each. Check the Air over SSH or the Link: build, Devices settings, `~/.t3/bin/t3 --version` and
   `t3 thread --help`, which harness CLIs exist and are signed in there.
3. **Build in this order:** 3.4 + 3.1 (protocol and private messages), 3.2 (groups), 3.3 (devices, awareness, memory),
   3.5, 3.6. Pure logic goes in ClickyCore with unit tests (prompt assembly, DM threads and caps, turn order, device
   routing table, folder menus, session listing parsers for each harness). Keep files consistent with the code around
   them; use the design tokens.
4. **Subagents:** use them for the research in section 3, for checking each harness's resume flags on this Mac, for
   test passes and for an independent code review of the full diff before installing. Brief each one with this file's
   path; tell them the rules in section 1.
5. **Test for real, cheaply** (all in test profiles, Haiku or OpenCode free, tiny tasks). Every row needs evidence: a
   screenshot of Theo's window, a chat export or a log line you read.
   - DM: ask Theo (on Haiku in the test profile) to "ask Coder which database they'd use for a todo app and tell me".
     One collapsed card in Theo's chat; it expands to both messages; Coder's own chat is unchanged; Theo's answer quotes
     what Coder actually said. A second exchange with the same pair remembers the first.
   - DM caps: a prompt that makes two bots ping-pong stops at the cap with a plain message.
   - Group: a head + 3 members group; a question that needs all three. Replies come one at a time in the named order,
     never two typing at once, the later ones refer to earlier ones, no repeated points, one wrap-up from the head.
   - Protocol: an assembled-prompt test that finds no contradictions, for a CEO, a manager, a member and a group head.
   - Purpose: a bot with a narrow job asked something outside it says who fits and offers to message them.
   - Devices, on the Air for real (test profile there, or Addy's Theo only if a test profile can't run): "which Mac are
     you on, and where would code go?" answered right; "make a folder called theo-test-<n> and put hello.txt in it"
     makes it on the Air and runs on the Air; the run card shows "This MacBook Air"; choosing Mac Studio lists the
     Studio's projects and runs there. Nothing ever picks on one Mac and runs on the other. The same on the Studio.
     Turn the Link off and on: chats and DMs end up the same on both.
   - Folder menu: New folder… makes and selects it; Choose a folder… shows the New Folder button; recent projects list.
   - Continue chat: in a sandbox folder, start a T3 Code thread and a Claude Code session, then pick each from the Chat
     menu and continue it (stock T3 Code on the Air and the fork on the Studio). Follow-ups stay on that thread.
   - Regressions: all unit tests, `Tools/theo-click-test.py`, the hi-fix greetings, a normal 1:1 chat, a run with a
     draft PR on `theo-pr-sandbox`, routines fire on the Studio only.
6. **Ship:** full tests green, Release build with a proper build number, install on the Studio when nothing plays,
   host the release in `adhyanmahajan26-boop/claudia-releases` as before (Addy asked for hosting on Nov 2), update the
   Air when its Theo is idle, check the About page build on both. Commit with plain-English messages and push
   `theo-bot-harness`; merge into `theo-ui-crew` once it's installed and green.
7. **Report** to the cloud side (it relays to Addy): after step 2 (short: what you saw in the real chats, root causes
   confirmed or not), after the build is feature-complete with unit tests, after live tests (the matrix with ✅/⚠️/❌ and
   evidence paths), and after install. Write the final report and test matrix to `~/jstest/theo-ui/harness-core/` and
   `docs/TEST-MATRIX.md`. Be honest: a ⚠️ is fine, a fake ✅ is not.
