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
