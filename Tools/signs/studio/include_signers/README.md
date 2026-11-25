# INCLUDE's signers, found again

INCLUDE names no signers, and its official train/val/test lists share them, so its test numbers are same-signer
numbers. These scripts recover who signed each clip, to measure the word model on people it never saw.

1. `placement.py`: where each clip's signer stands in the picture over its first 10 frames (shoulder centre and
   width, hips). The camera stays put within a recording session, so this is steady inside a session and jumps
   between sessions.
2. `sessions_from_placement.py`: clips close in camera file number (MVI, at most 25 apart), shoulder height
   (< 0.008 picture heights) and shoulder width (< 0.012) are linked; each connected group is a session.
   Result: 56 sessions (`sessions.json`); 46 hold all but 20 of the 4,280 clips.
3. `fetch_session_frames.sh` + `tile.py`: one video per session fetched from Zenodo by HTTP range (then deleted),
   one frame each, tiled with the session numbers.
4. `signers.json`: session → signer, named by eye from those frames (face and clothes). 26 people. Where two
   sessions might be the same person (13/23/47, 14/29, 25/33, 1/30, 42/44, 0/48) they are merged, so a held-out
   signer can't leak into training through a session that is really theirs. Session 55 (41 clips, no frame) and the
   10 sessions of 1-4 clips are left out.
5. `make_split.py <test> <val> <folder>`: a leave-one-signer-out copy (symlinks and a manifest with the split
   written out); `run_loso.sh` trains and evaluates on it; `ablation.sh` and `ablation2.sh` are the runs whose
   numbers are in docs/SIGN-LANGUAGE.md.

Paths are the Studio's (`~/sign-data`); nothing here is training data.
