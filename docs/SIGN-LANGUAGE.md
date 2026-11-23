# Sign language: Spell to text

Settings › Pointer Assistant › Hand signs › What signs do › **Spell to text**. The camera reads finger-spelled
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
- **ISL out of the box**: most ISL letters use two hands, and there are no built-in ISL shapes yet. Teaching
  works, at about 5 to 6 in 10 letters right from a few photos each; on your own hand it should do better.

## Measuring it again

```bash
cd Packages/ClickyCore
swift run -c release fingerspell-eval asl <folder of letter folders>       # built-in ASL letters
swift run -c release fingerspell-eval teach <folder> 5                      # teach 5 per sign, read the rest
swift run -c release fingerspell-eval shapes <folder>                       # each sign's middle shape, as Swift
```
