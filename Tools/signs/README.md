# Sign models: training

Python that turns sign-language landmark clips into the Core ML models the app runs. `SPEC.md` is the contract
(landmarks `[T, 61, 3]`, the 117 features, the models); read it first. Everything below runs from this folder
(`Tools/signs`), on Apple's GPU (`mps`), CUDA or the CPU (`--device auto|mps|cuda|cpu`, auto picks in that order).

```bash
cd Tools/signs
python3 -m venv .venv && .venv/bin/pip install -r requirements.txt
.venv/bin/python -m pytest tests -q          # synthetic data only, under a minute
```

## 1. Prepare data

A dataset is a folder of `<clip id>.npy` clips plus `manifest.csv` (SPEC section 1). Training reads a packed
copy (`frames.npy` + `offsets.npy` next to the manifest); it is made on first use, or by hand:

```bash
python -m signs.landmarks pack /data/signs/my-dataset
```

Pack again whenever clips or the manifest change.

**Google's Kaggle datasets** (MediaPipe landmarks): download and unzip `asl-signs` and `asl-fingerspelling`, then
first check which MediaPipe hand is the signer's right one on a sample:

```bash
python -m signs.mediapipe_sources isolated --kaggle /data/kaggle/asl-signs --check-sides
python -m signs.mediapipe_sources fingerspelling --kaggle /data/kaggle/asl-fingerspelling --check-sides
```

Both percentages should be well above 50%. If they are well below, swap `SIGNER_RIGHT_HAND_MEDIAPIPE_PART` and
`SIGNER_LEFT_HAND_MEDIAPIPE_PART` at the top of `signs/mediapipe_sources.py`. Then convert (this also packs):

```bash
python -m signs.mediapipe_sources isolated --kaggle /data/kaggle/asl-signs --output /data/signs/asl-signs
python -m signs.mediapipe_sources fingerspelling --kaggle /data/kaggle/asl-fingerspelling --output /data/signs/asl-fingerspelling
```

`--limit N` converts only the first N rows (isolated) or parquet files (finger-spelling), for a quick try.

**Apple Vision datasets** come from the app's extractor in the same clip format; just pack them.

## 2. Train

```bash
python -m signs.train_words --data /data/signs/asl-signs --language asl --output runs/words-asl
python -m signs.train_spell --data /data/signs/asl-fingerspelling --output runs/spell-asl
```

- Several datasets at once: `--data folderA folderB`. Words with the same label are one class;
  `--min-clips-per-word N` (default 5) drops rare ones.
- Splits are by signer (SPEC section 5): a manifest's own `split` column when filled, else a seeded split of each
  dataset's signers (15% test, 10% validation; `--seed`, `--test-fraction`, `--validation-fraction`). The split
  is saved in the checkpoint and `splits.json`.
- A run folder gets `checkpoint-last.pt` (every epoch), `checkpoint-best.pt` (best validation top-1, or
  finger-spelling score, of the EMA weights), `log.jsonl` (one line an epoch), `labels.json` and `splits.json`.
- Carry on after a stop: same command plus `--resume runs/words-asl` (data, split and labels come from the checkpoint;
  `--epochs` may be raised).
- Useful knobs: `--epochs`, `--batch-size`, `--learning-rate`, `--width`, `--workers`, `--no-augment`.
  Every option: `--help`.

Words: clips have frames with no hand trimmed at both ends, then are thinned evenly or padded to 96 frames.
Finger-spelling: up to 256 frames (thinned evenly when longer); a phrase too long for its frames is left out of
training; characters come from the training phrases.

## 3. Measure

```bash
python -m signs.evaluate --checkpoint runs/words-asl/checkpoint-best.pt --split val
python -m signs.evaluate --checkpoint runs/words-asl/checkpoint-best.pt --split test   # once, for the final number
```

Prints JSON: words get top-1, top-5 and a per-word table; finger-spelling gets the character error rate and the
Kaggle score `(N - D) / N` (greedy CTC decoding). Training never reads the test split. Report numbers on Apple
Vision landmarks apart from MediaPipe ones: add `--source apple` or `--source mediapipe`.

## 4. Export to Core ML

```bash
python -m signs.export_coreml --checkpoint runs/words-asl/checkpoint-best.pt --output out/SignWordsASL.mlpackage
python -m signs.export_coreml --checkpoint runs/spell-asl/checkpoint-best.pt --output out/SignSpellASL.mlpackage --float16
```

Writes the `.mlpackage` (ML Program; inputs `features` [1, N, 117] and `mask` [1, N]; outputs `scores` and, for
words, `description`) and `<name>.labels.json` beside it. For finger-spelling, `scores` are log-probabilities with
the CTC blank at index 0 and character i of the labels at index i + 1.

## Keeping Swift in step

`signs/features.py` documents every step of the features, including the edge cases. After changing it, run
`python -m signs.make_golden` to rewrite `tests/golden/*.json`, which the ClickyCore `SignFeatures` test reads. The
pytest suite fails while the golden files are stale.

## Notes

- `torch.nn.functional.ctc_loss` isn't implemented on MPS in some torch versions; then only the loss is computed
  on the CPU (printed once), the model stays on the GPU.
- Augmentation and features run in the DataLoader workers (`--workers`, default up to 8).
