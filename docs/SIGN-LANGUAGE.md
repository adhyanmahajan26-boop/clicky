# Sign language: Spell to text and Sign to text

Hand signs live in Settings › **Accessibility** (for people who sign, or who can't use their voice or hands the
usual way), turned on by its Accessibility mode switch. Mac only.

Settings › Accessibility › What signs do › **Spell to text**. The camera reads finger-spelled
letters and signs the owner taught, the panel builds the words, and Send hands them to Vello's chat (which can
pass them to Pointer Assistant or a Cursor run), straight to Pointer Assistant, or types them into the app in front.

Code: ClickyCore `HandSigns/Fingerspelling.swift` (pure, tested in `FingerspellingTests`), the app's
`HandSigns/HandSignController.swift` (camera, sending, teaching), `HandSignPanel.swift`, `HandSignSettings.swift`.

## How a frame is read

1. Apple Vision's hand pose finds up to two hands, 21 joints each, about 12 frames a second, on the Mac.
2. `HandShapeMeasure` turns one hand into 16 numbers measured in palm lengths: how far each finger reaches past
   its knuckle, where the thumb tip sits, thumb-to-fingertip distances, index-to-middle spread and crossing, the
   hand's tilt, and each finger's straightness. Left and right hands, near and far, measure the same. Up to 5
   joints Vision couldn't see are filled in from their neighbours. Two hands make 35 numbers.
3. `ASLFingerspelling` picks the nearest of 24 letter shapes (each the middle of about 55 photos of that letter
   as Vision sees them, from `fingerspell-eval shapes`), or nothing when no shape is within 2.5.
4. `TaughtSignBook` holds the owner's own signs (6 looks each when taught, up to 30 kept), read by the nearest
   look with the same number of hands; two-hand signs are also tried mirrored. A taught sign wins when nearer.
5. `FingerspellingSession`: a letter held 0.5 s counts once (a small bounce lets the same letter count again),
   no hand for 1 s ends the word, thumbs down held 0.8 s deletes, the spread open hand ("5") held 1 s sends.

## Measured accuracy (Apple Vision, `fingerspell-eval`, November 2026)

Photos from two public GitHub collections, read only for measuring and never committed: the Kaggle "ASL
Alphabet" set (60 photos a letter, one signer), a second ASL signer's webcam photos (2 a letter), and an ISL
alphabet set (702 photos, 23 letters, small 128-pixel pictures with pasted backgrounds).

| Test | Photos with a hand | Read as a letter | Right when read | Right overall |
| --- | --- | --- | --- | --- |
| ASL built in, a signer the shapes were not made from | 47 | 83% | 87% | 72% |
| ASL built in, the signer the shapes were made from (optimistic) | 1,349 | 84% | 93% | 78% |
| ASL, 5 photos of each letter taught, same signer | 1,198 | 90% | 93% | 84% |
| ISL, 5 photos of each letter taught | 387 | 65% | 81% | 52% |
| ISL, 10 photos of each letter taught | 253 | 75% | 85% | 64% |

Vision found a hand in 94% to 98% of the ASL photos and 76% of the small ISL ones. The ASL cross-signer test is
only 47 photos, so treat 72% as "around 7 in 10", not a precise number. Live use differs from photos: the hold
and bounce rules hide single bad frames, but light, framing and speed matter more.

## What it can't read

- **M and N** almost never (1 of 28 and 6 of 37 photos): the thumb hides under the fingers and Vision drops
  those joints. **T** is often read as **A**, and **U/V/R**, **K/V** and **E/S** get mixed up now and then.
- **J and Z** (they move), and every other moving sign: most ASL and ISL words are movements, not shapes.
- **Signed sentences**, facial grammar and body movement: only hands are read, one still shape at a time.
- **ISL out of the box (Experimental)**: the app ships the letter model `SignSpellISL` (25-26 two-handed letters,
  not J and Z, which move), so Spell to text reads ISL letters by itself. Measured on photos of a signer it never saw
  (ISLAN signer 6, 25 photos): 15 of 25 letters right (60%); on photos of the same people it was trained on (the
  multimodal set names no signers): 82% (56 of 68). Calibrated to answer only when sure, it answered 72% of the
  test photos and was right on 85% of those. The training photos are close-ups of hands at chest height, not a
  laptop camera's view, so expect less on your own camera until there is data from one. Without the model, ISL reads
  taught signs only: teaching works, at about 5 to 6 in 10 letters right from a few photos each.

## Sign to text (Experimental)

Settings › Accessibility › What signs do › **Sign to text**. The camera reads about 30 frames a second; Apple Vision
gives each frame's hands and body (61 landmarks, Tools/signs/SPEC.md); a stretch of signing between rests is read by
small Core ML models and becomes a line of words, sent to Vello's chat, Pointer Assistant or the app in front.

**ISL reading has only been shown to work for the signers it learned from.** Every number below that is high was
measured on the same people the models were trained on. On other people it is far weaker (ISL-CSLTR below), so expect
"?" often.

What ships, in the app's `Contents/Resources/SignModels` (Resources/SignModels in the repo; a model in the data folder
`~/Library/Application Support/Theo/SignModels` is taken first), float16, 12 MB in all:

- `SignWordsISL`: 261 ISL words from INCLUDE, with a "not sure" threshold of 0.95.
- `SignSentencesISL`: the same words in short runs without rests between them.
- `SignSpellISL`: ISL letters (not J and Z), also used by Spell to text.
- No ASL models yet: choosing ASL says "ASL isn't in this build yet. It arrives in an update." With no saved choice the
  language starts as one the build has models for (ISL today).

### Today's numbers (November 2026), each with what it was measured on

| What | Measured on | Result |
| --- | --- | --- |
| Word model, whole clip | INCLUDE's official test list (813 clips; the same 7 signers as training, since INCLUDE names no signers) | 96.9% right first guess, 99.5% in the top 5 |
| Through the app's own pipeline, threshold off | The same test list, 815 clips, read as the camera would (`sign-eval clips`) | 95.3% right |
| With the 0.95 threshold | The same 815 clips | 78.9% answered, 98.4% right when it answers, 21.1% shown as "?" |
| With the 0.95 threshold, words it was never taught | 3 folds, each holding out a tenth of the words (2,190 taught and 251 never-taught test clips) | Taught signs: 80% answered, 99% right when answered; never-taught signs wrongly given a word 8.8% of the time |
| Runs of signs | 200 streams built by joining 2 to 5 INCLUDE test clips with no rest between them (`sign-eval stream`); built, not real fluent signing | 7.5% word error rate; 97.4% of the words read were right |
| Real fluent sentences by other signers | ISL-CSLTR sentence videos, 287 of their sign glosses being INCLUDE words | 1 of 287 found |
| ISL letters | ISLAN signer 6, a signer it never saw (25 photos) | 15 of 25 right (60%) |
| ISL letters | Photos of the people it was trained on (multimodal set) | 82% (56 of 68) |

Float16 and float32 read exactly alike on the INCLUDE test clips and the built streams, and on the unseen signer's
letters; on 455 multimodal photos 454 got the same top letter.

### Why it doesn't carry over to other signers yet (first findings)

- ISL-CSLTR's other signers are seated and filmed closer; INCLUDE's stand. Their landmarks are as good as INCLUDE's
  (a raised hand is found in 78% of frames, INCLUDE 69%), so it isn't the camera picture.
- Cutting INCLUDE's clips to their signing part (no rise from rest, no drop back) still reads 94.5%, so it isn't the
  rests either.
- Even in the stretch of a CSLTR sentence that looks most like the word, its description sits far from INCLUDE's
  clips of that word (median cosine distance 0.79, against 0.10 for INCLUDE's own test clips and 0.50 to the
  nearest other word). At least one word, BEAUTIFUL, is a different sign in the two datasets (a hand circling the face
  in INCLUDE, an open hand raised high in CSLTR). ISL has regional variants, and seven signers aren't enough to learn
  a sign apart from the person making it.

### What it can't read

- Signers it hasn't learned from, reliably (above). Expect "?".
- Words outside INCLUDE's 261, and finger-spelling on the move (the letter model reads still shapes).
- Facial grammar (mouth, brows) and where a sign is placed in space: only hands and body are read.
- Fluent signing that runs signs together the way native signers do; it reads short runs best with a rest after them.
- ASL, until an update brings its models.

## Measuring it again

```bash
cd Packages/ClickyCore
swift run -c release fingerspell-eval asl <folder of letter folders>       # built-in ASL letters
swift run -c release fingerspell-eval teach <folder> 5                      # teach 5 per sign, read the rest
swift run -c release fingerspell-eval shapes <folder>                       # each sign's middle shape, as Swift
```

## Data and credits

The models were trained on (and ISL-CSLTR is used only to measure), each under CC BY 4.0:

- **INCLUDE** (ISL words): Advaith Sridhar, Rohith Gandhi Ganesan, Pratyush Kumar, Mitesh Khapra. 2020. *INCLUDE: A
  Large Scale Dataset for Indian Sign Language Recognition.* Proceedings of the 28th ACM International Conference on
  Multimedia. doi:10.1145/3394171.3413528. Data: Zenodo, doi:10.5281/zenodo.4010759. CC BY 4.0.
- **ISL-CSLTR** (measuring only, never training): Elakkiya R, Natarajan B. 2021. *ISL-CSLTR: Indian Sign Language
  Dataset for Continuous Sign Language Translation and Recognition.* Mendeley Data, V1, doi:10.17632/kcmpdxky7p.1.
  CC BY 4.0.
- **ISLAN** (ISL letters): Elakkiya R, Rajalakshmi E. 2021. *ISLAN.* Mendeley Data, V1, doi:10.17632/rc349j45m5.1.
  CC BY 4.0.
- **Multimodal ISL alphabet set** (ISL letters): Sarthak Hambir, Atharva Khandagale, Joel Santosh, Varad Gaikwad,
  Rutuja Kadam, Ved Mishra, Gagandeep Kaur, Grishma Y. Bobhate, Ghanshyam Tejani, David Bassir. 2026. *A Multimodal
  Indian Sign Language Dataset for English and Marathi Alphabet Signs and Numerical Digits with Pose and Skin
  Segmentation Representations.* Mendeley Data, V2, doi:10.17632/2tj6c7pzfk.2. CC BY 4.0.
