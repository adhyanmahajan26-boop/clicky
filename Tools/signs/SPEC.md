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

A clip on disk is `<clip id>.npy` (NumPy format 1.0, little-endian float32, C order, shape `[T, 61, 3]`). A
dataset is a folder of those plus `manifest.csv`:

`clip_id,dataset,language,label,signer,split,fps,width,height,frames,source`

`language` is `asl` or `isl`; `label` is the word or the spelled phrase in lower case; `split` is the
dataset's own `train` / `val` / `test` when it has one by signer, else empty; `source` is `apple` or
`mediapipe`; `width` and `height` are the picture's, 0 when the dataset doesn't say.

## 2. Which hand is which (`SignHandSides`, Swift only)

Vision returns up to two hands with a guess at left or right. With a body in the picture, each hand goes to the
side whose body wrist is nearer its own wrist (both hands can't take the same side: the nearer pair wins, the
other hand takes the side left over). With no body, Vision's own guess is used; when it says "unknown" or
gives both hands the same side, the hand further to the picture's left is the signer's right.

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

A model takes `[1, N, 117]` float32 and `[1, N]` of 1 for real frames and 0 for padding, at about 30 frames a
second. Frame-to-frame change is worked out inside the model, not here.

## 4. The models

| File | Reads | In | Out |
| --- | --- | --- | --- |
| `SignWordsASL.mlpackage` | one ASL sign | 96 frames | a score per word in `SignWordsASL.labels.json`, and a description of the sign (as many numbers as the model is wide), which is what a sign the owner teaches is compared by |
| `SignWordsISL.mlpackage` | one ISL sign | 96 frames | the same for `SignWordsISL.labels.json` |
| `SignSpellASL.mlpackage` | ASL finger-spelling on the move | 256 frames | a score per character per 2 frames (CTC, blank first), characters in `SignSpellASL.labels.json` |
| `SignSpellISL.mlpackage` | one still ISL letter (two hands) | 1 frame | a score per letter |

A sign longer than the model's frames is thinned evenly to fit; a shorter one is padded at the end.

## 5. Honest measuring

Every number we report is on **signers the model never saw** in training. Each dataset's signers are split
once (`signs/splits.py`, seeded) into train, validation and test, and the test signers are only read to print
the final number. Numbers on Apple Vision landmarks (what the app's camera makes) are reported apart from
numbers on MediaPipe landmarks, since the app never sees MediaPipe's.
