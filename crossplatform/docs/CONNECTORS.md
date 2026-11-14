# The connector hub (`theo-connectors`)

Theo's own connectors. Before the hub, Theo had none: the Connectors page was the output of `claude mcp list`, and a user
without Claude Code had no apps at all. The hub owns the list of apps, the sign-ins and the rule for what a bot may do,
and every brain (Claude Code, Codex, Cursor, Gemini, OpenCode, Grok, an API key) is just a customer of it. Claude Code
becomes one optional way to reach an app (`claude-account`), so nothing a Claude user set up is lost.

It is one small program, the same Rust code on Mac, Windows and Linux (`crates/theo-connectors`). Both apps start it as a
helper and read the one JSON object each command prints. This page is the contract packages 2 (Windows and Linux app),
3 (Mac app) and 4 (API-key bots) code against: change it only in ways that keep older callers working.

## Files

Everything lives under `<Theo's data folder>/Connectors/`, the folder passed as `--data`:

| File | What |
|---|---|
| `connectors.json` | The list of apps. The user's own choices. Never holds a token or secret. |
| `state.json` | What the hub last saw of each app (status, reason, last worked). Safe to delete. |
| `vault/<id>.secret` | The app's sign-in, encrypted (ChaCha20-Poly1305, the app id bound in). |
| `vault.key` | The vault key, only on Linux and in test profiles. On Mac and Windows it is in the Keychain / Credential Manager, service `com.theo.connectors`, account `vault-key`. |
| `tickets/` | One file per running bot turn (see Tickets). |

Why the tokens aren't in the Keychain themselves: Windows' Credential Manager holds at most 2,560 bytes per entry, and an
access token, a refresh token and a registered client together are often more. One key in the system store and the rest
encrypted beside it works the same everywhere. Losing the key (a new Mac, a cleared Keychain) only means signing in again.

Every write is atomic (temporary file and rename, this user only on Mac and Linux), and a lock file keeps two hub
processes (a bot's `serve` and the Connectors page's `check`) from overwriting each other or refreshing the same token
twice.

## Running it

```
theo-connectors --data <folder> [--key-store system|file] <command> …
```

- `--data` falls back to `THEO_DATA`.
- `--key-store file` (or `THEO_CONNECTORS_KEY_STORE=file`) keeps the vault key in a file instead of the system store. **Use
  it in every test profile**, so tests never touch the real Keychain or Credential Manager.
- Every command prints one JSON object on one line and exits 0. A failure prints `{"ok":false,"error":"<a sentence for
  the user>"}` and exits 1. Diagnostics go to standard error. No command ever prints a token or secret.

## Apps

```json
{"id": "notion-direct", "name": "Notion", "kind": "remote", "url": "https://mcp.notion.com/mcp", "auth": "oauth"}
{"id": "linear", "name": "Linear", "kind": "remote", "url": "https://mcp.linear.app/mcp", "auth": "token"}
{"id": "files", "name": "My files", "kind": "local", "command": "npx", "args": ["-y", "@modelcontextprotocol/server-filesystem", "/Users/me/Notes"]}
{"id": "gmail", "name": "Gmail", "kind": "claude-account", "server": "claude.ai Gmail", "readTools": ["search_threads"], "writeTools": ["create_draft"]}
```

| Field | For | Meaning |
|---|---|---|
| `id` | all | Lowercase letters, digits and dashes, up to 40. Tools reach brains as `<id>__<tool>`. |
| `name` | all | What the user sees. |
| `kind` | all | `remote` (MCP over streamable HTTP), `local` (MCP over a command's standard input and output), `claude-account` (through Claude Code). |
| `enabled` | all | Default true. A disabled app shows `off` and offers no tools. |
| `url` | remote | `https://…`. Plain `http://` only for `127.0.0.1` / `localhost`. |
| `auth` | remote | `none` (default), `oauth` (sign in in the browser), `token` (a pasted token, sent as `Authorization: Bearer`). |
| `oauth.clientId`, `oauth.scopes` | remote, oauth | For a server that doesn't let apps register themselves: the client the owner registered with the provider. Its secret, if any, goes in with `set-secret <id> --client-secret`. |
| `command`, `args`, `env`, `cwd` | local | The command to start. A bare name is looked up on PATH (on Windows with `.cmd` and `.bat` too, so `npx` works). A `.py` file is run with Python. `env` holds plain settings; secret ones go in with `set-secret <id> --env NAME`. |
| `server` | claude-account | Claude Code's name for it, exactly as `claude mcp list` prints it. |
| `readTools`, `writeTools` | claude-account | The app's tools (Claude Code can't list a claude.ai app's tools without a model run, so they come from the catalog). |
| `catalogId` | all | The catalog entry it was added from. |

Fields the hub doesn't know are kept as they are, so an older helper never drops what a newer one wrote.

`add` refuses any field that looks like a secret (`token`, `secret`, `password`, `apiKey`, …), in the app or its `env`,
and says to use `set-secret`, which reads the value from standard input so it never shows in a process list.

## Commands

| Command | Prints |
|---|---|
| `catalog` | `{"ok":true,"catalog":{"version":1,"note":"…","apps":[{…app, "description","via","tested"}]}}` |
| `list [--check]` | `{"ok":true,"apps":[{…app, "status", "reason"?, "lastWorked", "lastChecked", "toolCount"?, "signedIn"}]}`. Contacts nothing unless `--check`: the status is what was last seen, except what the hub knows without asking (`off`, and `needsSignIn` for an OAuth or token app with nothing stored). |
| `add --json '<app>' [--no-check]` / `add --catalog <id> [--id <new id>]` | `{"ok":true,"app":"<id>","status":…,"reason":…,"toolCount":…}`. Checks the app straight away unless `--no-check`. |
| `remove <id>` | `{"ok":true,"removed":"<id>"}`. Forgets its sign-in and state too. |
| `enable <id>` / `disable <id>` | `{"ok":true,"app":"<id>","enabled":true\|false}` |
| `set-secret <id>` (pasted token) / `--env NAME` (local secret setting) / `--client-secret` | `{"ok":true,"app":"<id>","saved":"token"\|"env NAME"\|"client secret"}`. The value is read from standard input; empty input removes it. |
| `signin <id> [--timeout <seconds>]` | Two lines. First `{"event":"open","app":"<id>","url":"<address>"}`: open that address in the browser. Then, when the browser comes back (default limit 300 s), `{"ok":true,"event":"done","app":"<id>","status":"connected",…}` or the usual failure line. |
| `signout <id>` | `{"ok":true,"app":"<id>","status":"needsSignIn"}`. Forgets the tokens and pasted token; keeps the client the hub registered. |
| `check [<id>]` | `{"ok":true,"apps":[{"id","status","reason","toolCount"}]}`. Reconnects (refreshing a token first if needed) and records the result. All claude-account apps share one `claude mcp list`. |
| `tools <id>` | `{"ok":true,"app":"<id>","tools":[{"name","exposedName","title"?,"description"?,"inputSchema","effect","readOnly"}]}` |
| `call <id> <tool> --args '<json>' --ticket <file>` | `{"ok":true,"app":"<id>","tool":"<tool>","result":<MCP CallToolResult>}`. A tool that ran but failed is `ok:true` with `result.isError:true`; a call the ticket doesn't allow is `ok:false`. For API-key bots: the Mac app's `leanring-buddy/Providers/APIChatTools.swift` lists each app's `tools`, offers the model only those its level allows, and runs each call it makes with the turn's ticket. |
| `serve --ticket <file>` | An MCP server on standard input and output (see Bot turns). Refuses to start with a missing or expired ticket. |
| `ticket issue --json '<ticket>'` | `{"ok":true,"ticket":"<file>"}`. Writes the ticket into `tickets/` and clears tickets that expired over an hour ago. |
| `ticket revoke <file>` | `{"ok":true}`. Deletes it (only ever a file inside `tickets/`). |
| `discover-claude` | `{"ok":true,"servers":[{"server","target","status","catalogIds","suggestedId","name"}]}`: what Claude Code has, for migrating a bot's old Claude server names to claude-account apps. |

Statuses: `connected`, `needsSignIn`, `failed` (with `reason`), `off`, `unknown` (never checked).

## What a bot may do

Each tool has an **effect**:

- `read`: only looks things up.
- `change`: writes something that can be looked at and undone (a draft, a page, a label).
- `irreversible`: can't be taken back (sends, replies, forwards, deletes, shares, cancels, clears).

It comes from the tool's name first and its MCP hints second (`crates/theo-connectors/src/safety.rs`). Any word in the name
like send, reply, delete, share, cancel, clear, publish makes it irreversible, whatever the server claims. Otherwise the
first verb decides (`get_draft` reads, `create_draft` changes), then `readOnlyHint` / `destructiveHint`. A name that says
nothing counts as a change. The word lists match the Mac app's `ConnectorBridge.writeTools` and
`BotRunner.irreversibleTools`, and a test checks every Gmail, Notion, Drive, Docs and Sheets tool the Mac app knows comes
out the same way.

Each bot has a **level** per app:

| Level | Runs |
|---|---|
| `read` | `read` tools only. |
| `readAndDraft` (default) | `read` and `change`. What bots could do before the hub. |
| `full` | Everything. |

**A turn that did not come from the owner's own words (a routine, another bot, the local API) never gets more than
`readAndDraft`:** it looks things up and drafts as bots always could, and never sends, shares or deletes.
A tool the level doesn't allow is not offered to the brain, and is refused if the brain asks for it by name anyway.

## Bot turns: tickets

The ticket is how the hub knows which bot is calling without taking the bot's word for it.

```json
{"botId": "ledger", "apps": {"gmail": "readAndDraft", "files": "read"}, "ownerAsked": true, "expiresAt": "2026-11-14T09:30:00Z"}
```

1. Before the turn, the app writes the ticket into `<data>/Connectors/tickets/` (with `ticket issue`, or the file itself in
   the same shape). Expiry: the turn's own time limit plus a little.
2. It starts the brain with the hub as an MCP server for this turn only:
   `command: <helper>`, `args: ["--data", <data>, "serve", "--ticket", <file>]`. For Claude Code that is an `--mcp-config`
   for the turn plus an allow rule for `mcp__theo__*` (call the server `theo`); each other brain has its own way to take
   an MCP server for one run (on Windows and Linux: `crossplatform/docs/PLATFORMS.md`, Connectors).
3. When the turn ends, it deletes the ticket (`ticket revoke`).

The hub reads the ticket again on every tool call, so deleting it or letting it expire stops a turn's apps at once. It
refuses a ticket outside `tickets/`. What a ticket can't do is stop a program that runs as the same user and writes its
own ticket: that stays the apps' job (bots may not write into Theo's own folder).

`serve` names tools `<app id>__<tool>` (anything but letters, digits, `_` and `-` becomes `_`), puts `[App name]` at the
start of each description, and marks each with `readOnlyHint` / `destructiveHint` from its effect. Requests run on their
own threads, so a slow app doesn't hold up a quick one. A connection that broke is reopened once, but a call is only ever
tried twice when it only reads: a send could have gone through before the connection broke.

## Signing in

For `auth: oauth`, `signin` follows MCP's authorization spec: the 401's `WWW-Authenticate: Bearer resource_metadata=…`,
else `/.well-known/oauth-protected-resource`, else the server's own origin; then `/.well-known/oauth-authorization-server`
or OpenID's metadata, else `/authorize`, `/token`, `/register`. It registers itself with dynamic client registration (or
uses the owner's `oauth.clientId`), opens the authorization address with PKCE S256, a random state and `resource`, and
waits on `http://127.0.0.1:<port>/callback`. The registered client is kept and its port reused, since most servers want
the exact redirect address back. Tokens are refreshed when less than a minute is left, under a lock so rotating refresh
tokens survive two hub processes, and once more if the server answers 401 to a token that should still work. A refresh
the server refuses (`invalid_grant`) turns the app to `needsSignIn`.

The apps open the `url` from the first line in the browser themselves (the hub never opens a browser), and show the
result from the second.

## claude-account apps

The behaviour every connector had before the hub, kept as an option:

- Status: one `claude mcp list` (parser ported from `theo-core/src/connectors.rs`), matched on `server`.
- Tools: `ask` (a plain-words lookup, as `claudia_app` does today) and each tool in `readTools` and `writeTools`.
- Running one: a short `claude -p --model haiku --permission-mode dontAsk --tools ""` run allowed only that tool, with every
  changing tool the level doesn't allow denied outright, as `ConnectorBridge` in `leanring-buddy/T3/ClaudiaMCPServer.swift`
  does. `ask` may only use the app's reading tools. For an app whose tools aren't known, `ask` would have to be given the
  whole server, so it counts as irreversible and only a `full` bot gets it.
- `THEO_CONNECTORS_CLAUDE` points the hub at a stand-in Claude Code (the tests use `tests/fake_engine.py`).

A Claude bot using a claude-account app keeps its direct route (Claude Code's own `mcp__claude_ai_*` tools), which is faster.
The hub's route is for every other brain. The Windows and Linux app does this already (`theo-core/src/hub.rs`: the tools the
level allows are allowed by name, the rest denied, and a server whose tools aren't known is allowed whole only at `full`);
the Mac app is package 3.

### Migrating what bots have today

| Today | Hub app |
|---|---|
| Mac app ids `gmail`, `notion`, `calendar`, `drive`, `docs`, `sheets` | The catalog entries with the same ids (`add --catalog <id>`). |
| Windows and Linux `apps` such as `"claude.ai Gmail"` | The catalog entry whose `server` matches (`discover-claude` lists `catalogIds`), else a claude-account app with `suggestedId`. |
| Mac `hostinger`, `studio`, `hyperframes` | User-added entries on the owner's Macs (package 3): `hostinger` as claude-account `"claude.ai Hostinger Connector"`, `studio` as claude-account `"content-studio"`. HyperFrames is a skill set, not a connector. |

## The starter catalog

`crates/theo-connectors/catalog.json` is data, built into the program; a `catalog.json` next to the program replaces it
without a new build. It lists only apps whose address and sign-in were actually tested, which tonight means the six
claude-account entries (ported from the route the owner's Macs use daily). Everything else goes through "Add your own".

What was found on 13 November 2026:

- **Google** (`gmailmcp.googleapis.com/mcp/v1`, `drivemcp.googleapis.com/mcp/v1` and the Docs and Sheets ones): the servers
  answer and publish protected-resource metadata pointing at `accounts.google.com`, whose metadata has **no
  registration endpoint** and no client-ID-metadata-document support. So Theo can't register itself: Google apps need an
  OAuth client created by the owner in Google Cloud (type "Desktop app"), set as `oauth.clientId` with its secret through
  `set-secret --client-secret`, and Google reviews apps that ask for Gmail scopes. Until then Gmail, Drive, Docs and Sheets
  keep working through a Claude account. This is a decision for the owner.
- Notion, Linear, Sentry, Hostinger, Atlassian, Asana, Canva, Stripe, Vercel, GitHub, Hugging Face and Cloudflare's public MCP
  addresses could not be reached from the cloud machine the hub was built on (its network blocks them), so none are in the
  catalog yet. Each can be tried on a Mac in one go, for example:

  ```
  H=~/Library/Application\ Support/Theo   # or a test profile's folder
  theo-connectors --data "$H" add --json '{"id":"notion-direct","name":"Notion","kind":"remote","url":"https://mcp.notion.com/mcp","auth":"oauth"}'
  theo-connectors --data "$H" signin notion-direct      # open the printed url
  theo-connectors --data "$H" tools notion-direct
  ```

  An app that signs in and lists its tools can then move into `catalog.json`.

## Building

- Linux and Windows: `cargo build --release -p theo-connectors` (part of the workspace).
- Mac, universal: `cargo build --release -p theo-connectors --target aarch64-apple-darwin && cargo build --release -p theo-connectors --target x86_64-apple-darwin && lipo -create -output theo-connectors target/aarch64-apple-darwin/release/theo-connectors target/x86_64-apple-darwin/release/theo-connectors`, then sign it with the app's identity (package 3, `Tools/build-connectors-helper.sh`).
- Windows: the hub is a console program. Start it the way `theo-core/src/procs.rs` starts engines (`CREATE_NO_WINDOW`) so no
  console window flashes; the hub starts every local app's command the same way.

## Tests

`cargo test -p theo-connectors` runs the unit tests and `tests/hub_end_to_end.rs`, which drives the real program against
the stand-ins in `crossplatform/tests`:

- `echo_mcp.py` as a `local` app: added, listed as connected, its tools called through `call` and `serve`, a secret setting
  reaching the command and staying out of the list file.
- `oauth_mcp.py`, a remote app with its own OAuth server (registration, PKCE, rotating refresh tokens): sign-in with a
  stand-in browser, refresh when the token runs out and when the server stops taking it, `needsSignIn` after `signout`, and
  no token the server issued in anything the hub printed or wrote.
- Levels and tickets: a `read` ticket can't run a changing tool, a turn not from the owner never sends, an expired ticket
  runs nothing, a ticket deleted mid-turn stops it, a ticket outside `tickets/` is refused.
- `fake_engine.py` as Claude Code: claude-account statuses from `claude mcp list`, and a plain failure with no Claude Code.

## Not done yet

- MCP's older HTTP+SSE transport (2024-11-05 servers that only offer `/sse`): not supported; such a server shows `failed`.
- Sampling, elicitation and roots: the hub offers none to apps.
- Brains that cap tool names at 64 characters: the hub doesn't shorten `<id>__<tool>`; keep app ids short.
