# Theo design system (2026-11 redesign)

One sidebar, chat full width, bot settings as a slide-over, one accent.

## Layout
- Window 1100x720 (min 860x560), transparent unified title bar.
- Sidebar 248 (220–300, Cmd+\ collapses): New bot (Cmd+N), Search (Cmd+K); Home; pinned (Clicky, Theo, user pins) with no header; Bots and Groups sections with collapsible user categories (sentence case, 11 pt text-3); footer Notes, Routines, Connectors, Settings (Cmd+,).
- Rows 32 pt, 8 pt radius, 20 pt avatar tile, name 13/medium, no subtitle; trailing 6 pt dot for working (accent) or unread (text-1).
- Detail toolbar 52 pt: avatar 24, name 15/semibold, model chip menu; right: search, new chat, sidebar.right, ellipsis.
- Bot settings: right slide-over 340 pt over a black 0.18 scrim; never shrinks the chat. Esc closes.

## Tokens
Accent (ember): dark #E8704F, light #D9532F — primary button, focus ring, send, selection dot only.
Dark: bg #0E0E10, surface-1 #17171A, surface-2 #1E1E22, hover white 5%, selected white 9%, border white 8%, border-strong white 14%, text #F2F2F4 / #A1A1AA / #6B6B75 / #4A4A52, success #3FB87A, warning #E5A94B, danger #E5594F, info #5B8DEF.
Light: bg #FAFAF9, surface-1 #FFFFFF, surface-2 #F5F5F3, hover black 4%, selected black 7%, border black 10%, border-strong black 16%, text #17171A / #5C5C66 / #8E8E98, success #1F9D63, warning #B7791F, danger #D1453B, info #3B6FD4.
Type: title 22/semibold, headline 15/semibold, body 14 (chat 15, line spacing 1.5), row 13/medium, caption 12, micro 11/medium, code 13 mono, section labels 11/semibold text-3.
Spacing 4 8 12 16 24 32 48. Radii 6 (chips) 8 (rows, buttons) 12 (cards, composer, code) 16 (panels, sheets).
Shadows only on floating UI. No gradients on cards, no emoji in chrome, one accent button per view.

## Bot tiles
Rounded square, radius 28% (continuous), soft two-hue gradient (A → B), 1 px inner stroke white 18%, glyph or 1–2 letter monogram in SF Rounded bold at 46%.
Palette: ember #F2784B→#E0476A, amber #F5B13D→#E8782E, lime #9BD14B→#3FA65C, teal #3FC8B4→#2E8FB8, sky #4EA8F0→#4A6FE0, indigo #6E7BF0→#8A55E0, violet #A468EB→#D152B8, rose #F06A8F→#E24A58, slate #7C8697→#4D5666, graphite #3A3A42→#1E1E24.
Clicky: flat ember tile with the spark-cursor glyph. Theo: graphite tile, white T. Groups: 2x2 mosaic of member tiles.

## Chat
Column max 720. Assistant text full width, no bubble, avatar + name once per run, hover actions (copy, retry). User: right bubble surface-2, radius 16. Composer: surface-1, radius 12, plus / @ / model chip / mic / send (28 pt accent circle; stop while generating). Code blocks surface-2 with a 28 pt header strip.

## Motion
Hovers .snappy(0.18); panels spring(0.35, 0.86) with 24 pt slide + fade; message arrival fade + 6 pt rise 0.2 s; streaming text appended without per-character animation; respect Reduce Motion.
