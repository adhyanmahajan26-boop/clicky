# Sign to text: the contract between the camera, the training code and the app

Vello reads sign language in three steps: the camera picture becomes **landmarks** (Apple Vision, on the Mac),
landmarks become **features**, and small models turn features into **words and letters**. Training (Python, on
the Mac Studio) and the app (Swift) must build exactly the same features, so this file is the one place that
says what they are. `Tools/signs/tests/golden/` holds landmarks with the features Python made from them; a
ClickyCore test checks Swift makes the same numbers.

Nothing here ships a picture or a video. Datasets stay on the training Mac and are never committed.

## 1. Landmarks: one clip is `[T, 61, 3]` float32

Every frame has 61 points, each `(x, y, confidence)`:

- `x`, `y` are in the picture, 0 to 1, **x to the right, y down** (Vision gives y up: flip it), from an
  unmirrored picture. `confidence` 0 means the point wasn't seen; then `x = y = 0`.
- "Right" and "left" are always **the signer's own** right and left.

| Index | Points | Order |
| --- | --- | --- |
| 0–20 | right hand | wrist, thumb CMC, MP, IP, tip, index MCP, PIP, DIP, tip, middle …, ring …, little … (Vision's 21, the same order as MediaPipe's 0–20) |
| 21–41 | left hand | the same |
| 42–54 | body | nose, left eye, right eye, left ear, right ear, left shoulder, right shoulder, left elbow, right elbow, left wrist, right wrist, left hip, right hip |
| 55–58 | mouth | left corner, right corner, middle of the upper lip, middle of the lower lip (outer edge) |
| 59–60 | brows | middle of the left brow, middle of the right brow |

From MediaPipe Holistic (the Google datasets): hands are `right_hand` / `left_hand` 0–20 with confidence 1 when
present; body is pose 0, 2, 5, 7, 8, 11, 12, 13, 14, 15, 16, 23, 24 with its `visibility` as confidence (1 when
absent from the file but the point is there); mouth is face 291, 61, 0, 17; brows are face 334, 105.

From Apple Vision: hands from `VNDetectHumanHandPoseRequest` (joint confidence under 0.3 counts as not seen;
a hand with fewer than 12 joints seen is dropped), body from `VNDetectHumanBodyPoseRequest` (the biggest person),
mouth and brows from `VNDetectFaceLandmarksRequest` when asked for. Which hand is which is decided by
`SignHandSides` in ClickyCore (section 2), never by Python, so the app and the extractor always agree.

**The body pose runs on a padded picture.** Vision's body pose finds nobody in a close head-and-shoulders picture
(a laptop or phone camera at arm's length: shoulders in 0 of 68 frames of a clip where they are plainly there).
So the app and the extractor (`sign-extract --pad-body`) both shrink the upright picture to at most 640 pixels on
its long side, put it at the top middle of a mid-grey canvas 2 times as wide and 1.6 times as tall, run the body
pose on that, and turn the points back into the picture's own 0 to 1; a point that lands outside the picture
counts as not seen. Hands and face are read from the picture itself. On half-body video the padded and plain
body pose agree to within 0.006 of the picture, which is why INCLUDE's clips, extracted before this rule, stand.

A clip on disk is `<clip id>.npy` (NumPy format 1.0, little-endian float32, C order, shape `[T, 61, 3]`). A
dataset is a folder of those plus `manifest.csv`:

`clip_id,dataset,language,label,signer,split,fps,width,height,frames,source`

`language` is `asl` or `isl`; `label` is the word or the spelled phrase in lower case (a clip of several signs
in a row has them in order with `|` between, `i|go|school`, since one sign's own name may hold a space); `split` is the
dataset's own `train` / `val` / `test` when it has one by signer, else empty; `source` is `apple` or
`mediapipe`; `width` and `height` are the picture's, 0 when the dataset doesn't say.

## 2. Which hand is which (`SignHandSides`, Swift only)

Vision returns up to two hands with a guess at left or right (its guess is named for the signer, and matched the
body on 98% of hands in a check on real video). With a body in the picture, each hand goes to the side whose
body wrist is nearer its own wrist (both hands can't take the same side: the nearer pair wins, the other hand
takes the side left over). A hand's place is its wrist, or the middle of its seen joints when the wrist is
hidden; distances count x multiplied by `width / height`. With only one body wrist seen and two hands, the
nearer hand takes that side; with one body wrist and one hand, Vision's guess decides. With no body, Vision's
own guess is used; when it says "unknown" or gives both hands the same side, the hand further to the picture's
left is the signer's right (a single hand in the picture's left half is the signer's right).

Apple's body joints are named for the person (`leftShoulder` is on the picture's right). Its face landmarks are
named for the picture (`leftEyebrow` is the signer's right brow), so the extractor swaps them. Body and face
points also need confidence 0.3. The mouth corners are the two `outerLips` points furthest apart; the lip
middles are the points nearest halfway along the mouth on the eyes' side and the chin's side; a brow's middle is
the average of its points.

## 3. Features: one frame is 117 numbers

Made by `signs/features.py` and by ClickyCore `SignFeatures`, the same way:

1. **Short gaps are filled.** A point missing for at most 4 frames in a row, seen before and after, is put on
   the straight line between the two (confidence 0.5). A hand counts as seen in a frame when its wrist and at
   least 11 other joints are.
2. **Sizes.** `hand size` is the 90th percentile, over the frames a hand is seen, of the distance from its wrist
   to its middle knuckle (both hands pooled). `body size` is the median distance between the shoulders over
   the frames both are seen; with no such frame it is `3.5 × hand size`. `centre` in a frame is the midpoint of
   the shoulders; in a frame without both, the last frame's centre; before any, the first one seen; with no
   shoulders in the whole clip, the median of the seen wrists' places. Distances are measured with x multiplied
   by `width / height` when the picture's size is known (so x and y are the same size), else as they are.
   The app keeps the same numbers over the stretch of frames it is reading.
3. **Per frame**, in this order:
   - 0–41: right hand, each of its 21 joints as `(joint − wrist) / hand size`, x then y. Zeros when not seen.
   - 42–83: left hand, the same.
   - 84–85: right wrist as `(wrist − centre) / body size`; 86–87: left wrist. Zeros when not seen.
   - 88–113: the 13 body points as `(point − centre) / body size`. Zeros for one not seen.
   - 114, 115, 116: right hand seen, left hand seen, both shoulders seen (1 or 0).

Mouth and brows are kept in the landmark files but are not features yet.

The exact rules for the cases this leaves open (which joint is the middle knuckle, the percentile, a hand or
body too small to measure, nothing seen at all) are in the notes at the top of `signs/features.py`, which Swift
follows line by line.

**Frame rate.** The models read 30 frames a second. Landmarks that come slower than 27 or faster than 33 (a
dataset filmed at 25 or 60, a camera that slows down in dim light) are brought to 30 before anything else. Frame
`k` was taken at time `τk` (`k / fps` for a file, the camera's own time stamps in the app, where the rate is
`(T − 1) / (τlast − τ0)` over the stretch). New frame `j` is at `τ0 + j / 30`, for every such time up to `τlast`
(plus a millionth of a second, so rounding can't drop the last one). With `i` the last frame at or before that
time and `f` how far the time is from frame `i` to frame `i + 1` (0 to 1, rounded to 6 decimal places): `f = 0`
copies frame `i` and `f = 1` copies frame `i + 1`; otherwise a point seen in both takes the place that far along
the line between them and the smaller of the two confidences, and any other point is copied as it is from the
nearer frame (`i` when `f < 0.5`, else `i + 1`). `Tools/signs/tests/golden/frame_rate/` holds examples
both sides are checked against.

**Order.** A stretch of frames is first brought to 30 frames a second when it needs it, then cut to run from the
first frame with a hand to the last (on the
landmarks as seen, before gaps are filled), then its features are made over all its frames, and only then is it
thinned or padded to the model's frame count: frame `k` of `N` kept from `T` is frame
`floor(k × (T − 1) / (N − 1) + 0.5)`. The app does the same in the same order.

A model takes `[1, N, 117]` float32 and `[1, N]` of 1 for real frames and 0 for padding, at about 30 frames a
second. Frame-to-frame change is worked out inside the model, not here.

## 4. The models

| File | Reads | In | Out |
| --- | --- | --- | --- |
| `SignWordsASL.mlpackage` | one ASL sign | 96 frames | a score per word in `SignWordsASL.labels.json`, and a description of the sign (as many numbers as the model is wide), which is what a sign the owner teaches is compared by |
| `SignWordsISL.mlpackage` | one ISL sign | 96 frames | the same for `SignWordsISL.labels.json` |
| `SignSpellASL.mlpackage` | ASL finger-spelling on the move | 256 frames | 128 rows of scores, one per 2 frames (CTC): score 0 is the blank, score `i + 1` is character `i` of `SignSpellASL.labels.json` |
| `SignSpellISL.mlpackage` | one still ISL letter (two hands) | 1 frame | a score per letter in `SignSpellISL.labels.json` |
| `SignSentencesASL.mlpackage` | a run of ASL signs without rests | 384 frames | 192 rows of scores, one per 2 frames (CTC): score 0 is the blank, score `i + 1` is word `i` of `SignSentencesASL.labels.json` |
| `SignSentencesISL.mlpackage` | a run of ISL signs without rests | 384 frames | the same for `SignSentencesISL.labels.json` |

A sign longer than the model's frames is thinned evenly to fit; a shorter one is padded at the end.

The sentence models are trained on sentences joined from single-sign clips (and any real continuous clips), so
their numbers on joined sentences are not numbers on real fluent signing.

A word or letter model that has been calibrated has `<name>.reading.json` beside it:
`{"leastWordProbability", "rightWhenAnsweredOnValidation", "answeredOnValidation", "temperature"}`. Its `scores`
are already divided by `temperature`, so a plain softmax gives calibrated probabilities; the app answers only when
the top probability is at least `leastWordProbability` and says the sign is unclear otherwise. The other two
numbers are what that threshold did on the validation signers.

## 5. Honest measuring

Every number we report is on **signers the model never saw** in training. Each dataset's signers are split
once (`signs/splits.py`, seeded) into train, validation and test, and the test signers are only read to print
the final number. Numbers on Apple Vision landmarks (what the app's camera makes) are reported apart from
numbers on MediaPipe landmarks, since the app never sees MediaPipe's.
