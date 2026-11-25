# Why the ISL word model doesn't carry over to ISL-CSLTR (round 7)

Run from Tools/signs with `PYTHONPATH=.` and the venv's python; paths are the Studio's (`~/sign-data`). ISL-CSLTR is
used to measure only, never to train.

- `prepare.py`, `extract_loop.sh`: CSLTR's sentence videos named by a key word ("afraid.MP4" in "i am afraid of that"),
  by camera number and the 10 sentences filmed at both sizes, extracted with sign-extract as they download.
  The key-word files are whole sentences, not single signs: CSLTR has no word-level videos, only still photos.
- `scoring.py`: the INCLUDE word model on whole clips and sliding windows (30-90 frames), with its descriptions.
- `analyze_1a.py`: the model on whole sentence clips against the key word, and whether each INCLUDE word of the
  sentence's glosses reaches top-1/top-5 in some window, against words not in the sentence.
- `include_reference.py`, `analyze_1b.py`: description distance to INCLUDE's centre for the word, and plots of wrist
  paths and hand shapes (into `plots/`).
- `include_cut.py`: INCLUDE test clips cut to their signing part (does the model lean on the rise from rest?).
- `hand_found.py`, `analyze_1c.py`, `jitter_reference.py`, `upscale.sh`: landmark quality at 240x320 and 1920x1080,
  and the small videos upscaled 4x before Vision.

Findings are in docs/SIGN-LANGUAGE.md.
