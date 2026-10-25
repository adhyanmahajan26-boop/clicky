# Clicky grounding baseline

- Build: `b8a1ccaa1bdd645e9eca9c4c4c377b07a8b7538c` (pid 76355), voice engine qwen
- Date: 2026-10-25 08:21
- Rules: point/legacy MARK centre inside target + 4 pt; multi-key rows in order; spans = union.

## Hits per display x kind

| display | ax | canvas | dot | mixed | web | all |
|---|---|---|---|---|---|---|
| 0 | 17/22 | 6/7 | 4/4 | 1/1 | 6/6 | **34/40** |
| 1 | 21/22 | 6/7 | 4/4 | 1/1 | 6/6 | **38/40** |
| 2 | 21/22 | 7/7 | 4/4 | 1/1 | 6/6 | **39/40** |

Total: **111/120** (92%)

## Latency keyUp -> firstAudio (10 spoken asks)

- p50 6.66 s, p95 7.48 s, min 4.60 s, max 7.48 s; engine(s): qwen
- median stage times from keyUp: keyUp 0.00s, captureDone 0.24s, handedToWriter 0.25s, requestWritten 0.86s, firstDelta 2.63s, result 4.05s, firstAudio 6.72s, end 6.72s

## Missed rows

- d0 r2 `point at the gear icon` (icon_gear) -> no tag hit icon_gear; tags: [POINT:1002,163:gear icon]
- d0 r5 `where is the trash icon` (icon_trash) -> no tag hit icon_trash; tags: [POINT:89,62:trash icon]
- d0 r6 `show me the lock icon` (icon_lock) -> no tag hit icon_lock; tags: [MARK:circle:lock icon] [POINT:522,207:lock icon:screen3]
- d0 r14 `where is row 27` (row_27) -> no tag hit row_27; tags: none
- d0 r34 `first the gear, then the trash icon` (icon_gear,icon_trash) -> no tag hit icon_gear; tags: [MARK:numberedStep(stepNumber: 1):gear] [MARK:numberedStep(stepNumber: 2):trash] [POINT:100,62:gear]
- d0 r35 `tell me the total and the rate limit error` (canvas_total,canvas_rate_limit) -> no tag hit canvas_rate_limit; tags: [MARK:circle:rate limit] [MARK:circle:total] [POINT:290,212:total]
- d1 r14 `where is row 27` (row_27) -> no tag hit row_27; tags: none
- d1 r35 `tell me the total and the rate limit error` (canvas_total,canvas_rate_limit) -> no tag hit canvas_rate_limit; tags: [MARK:circle:rate limit] [MARK:circle:total] [POINT:735,335:total]
- d2 r14 `where is row 27` (row_27) -> no tag hit row_27; tags: [MARK:circle:row 15] [POINT:153,352:row 15]

## P1a (f30792b): native capture, measured sizing, reset per row

- Build: `f30792b773c277243cd71c215baed4a7543a5f39` (pid 93250), voice engine qwen
- Date: 2026-10-25 08:56
- Rules: point/legacy MARK centre inside target + 4 pt; multi-key rows in order; spans = union.

### Hits per display x kind

| display | ax | canvas | dot | mixed | web | all |
|---|---|---|---|---|---|---|
| 0 | 19/20 | 7/7 | 4/4 | 1/1 | 6/6 | **37/38** |
| 1 | 20/20 | 6/7 | 4/4 | 1/1 | 6/6 | **37/38** |
| 2 | 20/20 | 7/7 | 4/4 | 1/1 | 6/6 | **38/38** |

Total (excluding cover rows): **112/114** (98%)

Cover rows (hit = says it can't see it, or points at the covering window): **4/6**
- d0 r39 `point at the Run button` -> said it can't see it
- d0 r40 `circle the Export as PDF button` -> said it can't see it
- d1 r39 `point at the Run button` -> guessed through the cover
- d1 r40 `circle the Export as PDF button` -> said it can't see it
- d2 r39 `point at the Run button` -> guessed through the cover
- d2 r40 `circle the Export as PDF button` -> said it can't see it

### Latency keyUp -> firstAudio (10 spoken asks)

- p50 5.79 s, p95 8.12 s, min 3.61 s, max 8.12 s; engine(s): qwen
- median stage times from keyUp: keyUp 0.00s, captureDone 0.16s, handedToWriter 0.16s, requestWritten 0.76s, firstDelta 2.29s, result 3.85s, firstAudio 5.95s, end 5.96s

### Missed rows

- d0 r2 `point at the gear icon` (icon_gear) -> no tag hit icon_gear; tags: [POINT:1167,1028:gear icon]
- d1 r35 `tell me the total and the rate limit error` (canvas_total,canvas_rate_limit) -> no tag hit canvas_rate_limit; tags: [MARK:circle:rate limit] [MARK:circle:total] [POINT:1101,501:total]

### P1a vs P0, like for like

- P0 counted cover rows in the total (all 6 "hit" by guessing) and had the unfair "row 27" row (3 misses).
- Excluding cover rows and that one row (replaced by "row 9" in P1a): **P0 105/111 (94.6%) → P1a 109/111 (98.2%)**.
- Ultrawide (d0): P0 34/40 → P1a 37/38. Small icons (gear/trash/lock) were the P0 misses.
- P0 asks carried conversation history; P1a resets before every row.
- Remaining misses: d0 gear (pointed at another gear on screen 1 at 1167,1028 model px), d1 multi-key
  order ("total and the rate limit error" marked rate limit first; the prompt doesn't force an order).
- Spoken latency keyUp→firstAudio p50 6.66 → 5.79 s; keyUp→handedToWriter over 20 asks p50 119 ms, p95 177 ms.

## P1b (6f51365 + fixes ca167c2, 546167f): AX + OCR set-of-marks, badges A/B

Run 1 below is the complete A/B run at 6f51365. Run 2 (at 546167f, after the freeze fix) was stopped on Addy's request partway through display 1 and is summarised after it.

### Self-tests (546167f build tree, before the eval)

- fixtureResolve, all 3 displays: ax 31/31 (0 pt), axtext 1/1, web 5/5 (worst 1.6 pt), canvas 7/7 (centre, worst 2.3 pt); no misses. verifyHitTest cover + park pass on every display.
- groundingLatency: warm p50 107 / p95 120 ms (n 20), cold p50 85 / p95 177 ms, prewarm ready before a 1 s key-up 20/20 (prewarm p50 827 / p95 914 ms). OCR per display 292-607 ms.
- Warm key-up stage medians: capture 49 ms, diff 38 ms, fusion 6 ms, badge layout 1 ms, badge render 8 ms.

### Run 1 (complete)

#### Hits per display x kind

| display | ax | canvas | dot | mixed | web | all |
|---|---|---|---|---|---|---|
| 0 | 40/40 | 10/14 | 8/8 | 2/2 | 11/12 | **71/76** |
| 1 | 40/40 | 13/14 | 8/8 | 1/2 | 12/12 | **74/76** |
| 2 | 40/40 | 14/14 | 8/8 | 1/2 | 12/12 | **75/76** |

Total (excluding cover rows): **220/228** (96%)

#### Buckets with Wilson 95% intervals

| badges | bucket | hits/n | rate | Wilson 95% |
|---|---|---|---|---|
| off | ax+web | 78/78 | 100.0% | 95.3–100.0% |
| off | canvas+dot | 30/33 | 90.9% | 76.4–96.9% |
| off | mixed | 2/3 | 66.7% | 20.8–93.9% |
| off | cover | 0/6 | 0.0% | 0.0–39.0% |
| off | canvas+dot d0 | 8/11 | 72.7% | |
| off | canvas+dot d1 | 11/11 | 100.0% | |
| off | canvas+dot d2 | 11/11 | 100.0% | |
| on | ax+web | 77/78 | 98.7% | 93.1–99.8% |
| on | canvas+dot | 31/33 | 93.9% | 80.4–98.3% |
| on | mixed | 2/3 | 66.7% | 20.8–93.9% |
| on | cover | 4/6 | 66.7% | 30.0–90.3% |
| on | canvas+dot d0 | 10/11 | 90.9% | |
| on | canvas+dot d1 | 10/11 | 90.9% | |
| on | canvas+dot d2 | 11/11 | 100.0% | |

Badge/id mentions in raw narration (before the speech net): **19**; ids stripped by the net: 0.

Cover rows (hit = says it can't see it, or points at the covering window): **4/12**
- d0 r39 `point at the Run button` -> said it can't see it
- d0 r40 `circle the Export as PDF button` -> said it can't see it
- d0 r39 `point at the Run button` -> no tag and no can't-see
- d0 r40 `circle the Export as PDF button` -> no tag and no can't-see
- d1 r39 `point at the Run button` -> said it can't see it
- d1 r40 `circle the Export as PDF button` -> no tag and no can't-see
- d1 r39 `point at the Run button` -> no tag and no can't-see
- d1 r40 `circle the Export as PDF button` -> no tag and no can't-see
- d2 r39 `point at the Run button` -> no tag and no can't-see
- d2 r40 `circle the Export as PDF button` -> said it can't see it
- d2 r39 `point at the Run button` -> no tag and no can't-see
- d2 r40 `circle the Export as PDF button` -> no tag and no can't-see

#### Latency keyUp -> firstAudio (10 spoken asks)

- p50 5.70 s, p95 7.96 s, min 4.07 s, max 7.96 s; engine(s): qwen
- median stage times from keyUp: keyUp 0.00s, captureDone 0.15s, handedToWriter 0.16s, requestWritten 0.74s, firstDelta 2.41s, result 4.01s, firstAudio 6.16s, end 6.16s

#### Missed rows

- d0 r20 [badges on] `where can I subscribe on this page` (web_subscribe) -> no tag hit web_subscribe; tags: [POINT:"Subscribe":Subscribe]
- d0 r25 [badges on] `what does x = 42 refer to` (canvas_x42) -> no tag hit canvas_x42; tags: [POINT:"x = 42":x = 42]
- d0 r25 [badges off] `what does x = 42 refer to` (canvas_x42) -> no tag hit canvas_x42; tags: [POINT:"x = 42":x = 42]
- d0 r26 [badges off] `highlight the total on the chart` (canvas_total) -> no tag hit canvas_total; tags: [MARK:box:"Total: 1,284":Total|this is the total] [POINT:"Total: 1,284":Total]
- d0 r35 [badges off] `tell me the total and the rate limit error` (canvas_total,canvas_rate_limit) -> no tag hit canvas_total; tags: [POINT:"Total: 1,284":Total] [MARK:underline:"rate limit exceeded (429)":Rate limit error|429 error]
- d1 r35 [badges on] `tell me the total and the rate limit error` (canvas_total,canvas_rate_limit) -> no tag hit canvas_rate_limit; tags: [POINT:"Total: 1,284":Total]
- d1 r36 [badges on] `point at the red dot then the subscribe button` (dot_red,web_subscribe) -> no tag hit web_subscribe; tags: [POINT:"Deploy failed"~0:placeholder] [MARK:circle:1067,639,16,16:Red dot] [MARK:circle:#53:Subscribe] [POINT:1067,639:Red dot]
- d2 r36 [badges off] `point at the red dot then the subscribe button` (dot_red,web_subscribe) -> no tag hit dot_red; tags: [MARK:1:"fix":Red dot|first, this one] [MARK:2:"Subscribe":Subscribe|then this one] [POINT:"Subscribe":Subscribe]

Note: the 19 "badge mentions" above were all the plain phrase "the list" describing the fixture's on-screen list or table (e.g. "row 9 is in the list on the left"), on prompts like "where is row 9". No ids or the word "badge" were spoken. The counter now ignores plain "the list" (ca167c2); this was not re-measured on a full run.

### Run 2 (partial, stopped)

- Completed: display 0 (badges on and off) and display 1 badges-on rows 1-14.
- 83 hits, 10 misses. All 10 misses are on display 0: rows 20, 25, 26, 35, 36 and 39 with badges on; rows 25, 26, 39 and 40 with badges off. Rows 39/40 are cover rows.
- Not reached: the rest of display 1, display 2, the cover summary, badge-mention counts, the spoken latency asks.

### Not yet done in P1b

- A complete A/B run on the final build, including 0 badge mentions with the corrected counter.
- Real-app asks (Finder, Safari, System Settings, Xcode, Slack, VS Code; Tools/eval/real_app_asks.py).
- d0 canvas misses: "x = 42" also appears in the fixture's results list, so the text target is ambiguous; "Total: 1,284" misses on d0 need a look.
