# Clicky v2 probes (P1a)

Measured 2026-10-25 on build f30792b (Mac Studio M3 Ultra, macOS 27.0, claude 2.1.301).
Main model alias `sonnet` resolves to **claude-sonnet-5-5** (from the CLI's system/init event).

## Transport flags

```
~/.local/bin/claude -p --input-format stream-json --output-format stream-json --verbose
  --include-partial-messages --model <alias> --system-prompt-file ~/.clicky/session/<name>.md
  --tools "" --strict-mcp-config --disable-slash-commands --no-session-persistence
  --setting-sources user --settings '{"disableAllHooks":true}'
```

- `--system-prompt-file` is not listed in `claude --help` but works (verified: a file saying "only reply
  PINEAPPLE" made the model reply PINEAPPLE). `ClaudeArgs` keeps an inline `--system-prompt` fallback.
- cwd `$TMPDIR/clicky-session`, recreated empty once per launch (calls run concurrently, so it is
  never deleted mid-call). Prompt files `~/.clicky/session/*.md`, 0600 in a 0700 directory.
- `~/.claude/settings.json` (read-only check): keys agentPushNotifEnabled, crossSessionInbound,
  editorMode, effortLevel, enabledPlugins, extraKnownMarketplaces, inputNeededNotifEnabled, model,
  modelSettings, permissions, skip*Prompt, switchModelsOnFlag, theme, verbose. No hooks defined.

## transportProbe

| probe | result |
|---|---|
| (a) random 6-digit code | sent 032731, reply "032731" — pass |
| (b) stored image size | sent 2576x1078, transcript stored **1999x837**; only `<session-id>.jsonl` deleted (its empty project folder `-private-var-…-T-clicky-session` remains) |
| (c) `transformations.oversized_image: "error"` | correct size succeeded, 3200x1340 did **not** error → field ignored → **dropped** |
| (d) text-only token baseline | usage input 2 + cache_creation 834 + cache_read 0 = 836 vs ~40 estimated → ~796 tokens overhead; model confirms `graphify` is in its context → **~/.claude/CLAUDE.md is injected** even with `--setting-sources user` |

## tierProbe (main model claude-sonnet-5-5)

| size sent | r | max error | result |
|---|---|---|---|
| 2576x1078 (ultrawide, cursor tier) | 1.00 | 3 px | pass, no correction |
| 1920x1080 (4K, cursor tier) | 1.00 | 0 px | pass, no correction |

`effectiveMaxEdge` = none. Stored under `v2.grounding.probe["claude-sonnet-5-5"]`.

Why (b) and the tier probe agree: Claude Code downsizes images above ~2000 px on the long edge and
tells the model the original size ("original WxH, displayed at …"), and the model answers in the
original coordinates (r = 1.00). Precision is therefore that of the ~2000 px image; sending 2576 px
only adds payload (~0.1-0.2 s more stdin write). Candidate follow-up: cap the cursor tier at 2000.

## Geometry self-tests

- calibration (includeSelf, sRGB, 3 pt magenta crosshairs, 4 corners inset 40 pt + centre):
  ultrawide 1x worst 0.24 native px; both 4Ks (2 px/pt) 0.00 — all ≤ 1 native px.
- overlayExclusion (200x200 magenta square per display, production filter excluding Clicky by app):
  0.000% magenta in every square.
- legacyCenter: 0.71 / 0.66 / 1.55 pt (the ultrawide on the standard tier at 2.19 pt per model px;
  the residual is the half-pixel centre convention).
