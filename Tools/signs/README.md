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

Packing brings every clip to 30 frames a second from its manifest `fps` (SPEC section 3, "Frame rate";
`signs/frame_rate.py`): a clip at 25 or 60 is resampled once, here, and from then on training and evaluation only
ever see 30 a second. Clips between 27 and 33 a second, or with `fps` 0 (unknown), are packed as they are. The
pack writes `packed.json` last; a folder packed before this rule has none and is packed again on first use.

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

Two more models, both with the same run folder, `--resume`, `--device` and `--workers` as above, and a `--help`
that explains every option:

```bash
# Runs of signs without rests (SignSentencesASL / SignSentencesISL): built sentences, CTC over the word list.
python -m signs.train_sentences --data /data/signs/asl-signs --language asl --output runs/sentences-asl \
    --start-from runs/words-asl/checkpoint-best.pt
python -m signs.train_sentences --data /data/signs/include /data/signs/isl-sentences --language isl \
    --output runs/sentences-isl --start-from runs/words-isl/checkpoint-best.pt

# Still ISL letters (SignSpellISL): one frame in, a score per letter out.
python -m signs.train_letters --data /data/signs/isl-letters --language isl --output runs/letters-isl
```

**Sentences** (`signs/sentences.py`, `signs/train_sentences.py`). Fluent signers don't rest their hands between
signs and there is no openly licensed sentence data we may ship, so sentences of 1 to 6 signs (one sign about a
quarter of the time) are built from single-sign clips of one signer: each trimmed to its frames with a hand,
sometimes shaved by up to a fifth at each end, moved and scaled onto the first clip's body, and joined by 3 to 10
in-between frames where points seen on both sides slide straight across. Training sentences are new every epoch
(`--sentences-per-epoch`, default about one use of each training clip); validation and test sentences are built
once from a fixed seed from signers never seen (`--evaluation-sentences`). A row whose label is several signs with `|`
between them (`i|go|school`) is a real continuous clip and is used as it is (training or measuring, by its split). `--start-from` takes a word
model's checkpoint and starts the encoder from it. Logged: word error rate, accuracy on one-sign sentences, and
the word error rate on real continuous clips alone. **Numbers on built sentences are not numbers on real fluent
signing**: joined clips lack the way neighbouring signs change each other. Only real continuous clips say how it
reads a person.

**Letters** (`signs/letters.py`, `signs/train_letters.py`). Clips are one frame each (`[1, 61, 3]`, from photos)
in the usual manifest. Split by signer when the manifest names signers, else by clip with the seed; the run says
which, since a split by clip lets one person be in training and test. Augmented by mirror, a small turn, size
and jitter only.

## 3. Measure

```bash
python -m signs.evaluate --checkpoint runs/words-asl/checkpoint-best.pt --split val
python -m signs.evaluate --checkpoint runs/words-asl/checkpoint-best.pt --split test   # once, for the final number
```

Prints JSON: words get top-1, top-5 and a per-word table; finger-spelling gets the character error rate and the
Kaggle score `(N - D) / N` (greedy CTC decoding); sentences get the word error rate, one-sign accuracy and the real
continuous clips' word error rate; letters the same table as words. Training never reads the test split. Report numbers on Apple
Vision landmarks apart from MediaPipe ones: add `--source apple` or `--source mediapipe`.

### Honest confidence: calibrate before exporting a word or letter model

People act on what the reader says, so a sign it isn't sure of must come out as "unclear", not as a wrong word:

```bash
python -m signs.calibrate --checkpoint runs/words-asl/checkpoint-best.pt --source apple
python -m signs.calibrate --checkpoint runs/letters-isl/checkpoint-best.pt --right-when-answered 0.97
```

It fits one temperature on the validation signers (smallest negative log likelihood), then prints, for each least
probability to answer (0.00 to 0.99), the share of validation clips answered and the share right among those. It
picks the lowest value where answered clips are right at least `--right-when-answered` of the time (default 0.95),
or says plainly that no value gets there and keeps the best. Then it prints the test signers' two numbers at that
value (the only time test is read) and, when the data has clips of signs the model was never taught, how many of
those it would wrongly answer. It writes `checkpoint-best.calibration.json` next to the checkpoint. Calibrate
again after any further training: the file remembers the weights, and export refuses a stale one.

## 4. Export to Core ML

```bash
python -m signs.export_coreml --checkpoint runs/words-asl/checkpoint-best.pt --output out/SignWordsASL.mlpackage
python -m signs.export_coreml --checkpoint runs/spell-asl/checkpoint-best.pt --output out/SignSpellASL.mlpackage --float16
```

Writes the `.mlpackage` (ML Program; inputs `features` [1, N, 117] and `mask` [1, N]; outputs `scores` and, for
words, `description`) and `<name>.labels.json` beside it. For finger-spelling, `scores` are log-probabilities with
the CTC blank at index 0 and character i of the labels at index i + 1.

```bash
python -m signs.export_coreml --checkpoint runs/sentences-asl/checkpoint-best.pt --output out/SignSentencesASL.mlpackage
python -m signs.export_coreml --checkpoint runs/sentences-isl/checkpoint-best.pt --output out/SignSentencesISL.mlpackage
python -m signs.export_coreml --checkpoint runs/letters-isl/checkpoint-best.pt --output out/SignSpellISL.mlpackage
```

Sentences: 384 frames in, `scores` [1, 192, words + 1] log-probabilities (blank 0, word i at i + 1). Letters: 1
frame in, `scores` [1, letters]. When `signs.calibrate` has written its file next to a word or letter checkpoint
(or `--calibration <file>` names one), the exported `scores` are already divided by the temperature, so a plain
softmax gives calibrated probabilities, and `<name>.reading.json` is written beside the model:
`{"leastWordProbability", "rightWhenAnsweredOnValidation", "answeredOnValidation", "temperature"}`. The app answers
only when the top probability is at least `leastWordProbability`, and says "unclear" otherwise.

## Keeping Swift in step

`signs/features.py` documents every step of the features, including the edge cases. After changing it, run
`python -m signs.make_golden` to rewrite `tests/golden/*.json`, which the ClickyCore `SignFeatures` test reads. The
same command writes `tests/golden/frame_rate/*.json` from `signs/frame_rate.py` (times, landmarks and the
landmarks at 30 a second) for the Swift frame-rate test; they sit in their own folder because the `SignFeatures`
test reads every file directly in `tests/golden/`. The pytest suite fails while either set is stale.

## Notes

- `torch.nn.functional.ctc_loss` isn't implemented on MPS in some torch versions; then only the loss is computed
  on the CPU (printed once), the model stays on the GPU.
- Augmentation and features run in the DataLoader workers (`--workers`, default up to 8; 0 on macOS, where
  spawned workers cost ~35 s an epoch on small data. With workers, batches cross as NumPy arrays so no
  torch_shm_manager process is left behind to keep the run from exiting).

## On the Mac Studio (how the data was made, and how to run it again)

Everything lives under `~/sign-data/` (never in the repo):

| Folder | What |
| --- | --- |
| `tools/` | copies of `Tools/signs/studio/*`, the built `sign-extract` (`bin/sign-extract` is the installed extractor the jobs run, copied there by hand after a build that passed its checks) |
| `venv/` | Python 3.12, torch 2.7.0 (MPS), coremltools 9.0 (its newest supported torch), numpy, pandas, pyarrow, pytest |
| `downloads/` | videos and zips while they are being read; each is deleted once its landmarks exist |
| `landmarks/<dataset>/` | SPEC clips + `manifest.csv` + `extract.csv` (one row a clip) + `failed.tsv` |
| `logs/` | one `.log` and `.pid` per detached job, and its resume state |
| `runs/`, `out/` | training runs and exported models |

Setup:

```bash
cd ~/sign-data && uv venv --python 3.12 venv
VIRTUAL_ENV=~/sign-data/venv uv pip install "torch==2.7.0" coremltools numpy pandas pyarrow pytest
cd <repo>/Packages/ClickyCore && swift build -c release --product sign-extract
mkdir -p ~/sign-data/tools/bin && cp .build/release/sign-extract ~/sign-data/tools/bin/sign-extract
cp <repo>/Tools/signs/studio/* ~/sign-data/tools/
cd <repo>/Tools/signs && ~/sign-data/venv/bin/python -m pytest tests -q
```

`sign-extract videos --list clips.tsv --out <folder> --face` reads Apple Vision landmarks (SPEC section 1; the
body pose runs on the padded picture unless `--no-pad-body`). One process tops out near 200 frames a second; four
processes with `--jobs 4` and a quarter of the list each reach about 340 with `--face`, and may share one `--out`.

Detached jobs (each resumable: run the same line again after a stop; stop one with `kill $(cat ~/sign-data/logs/<job>.pid)`):

```bash
# INCLUDE (ISL words, Zenodo 4010759, CC BY 4.0): 44 zips, one at a time; splits from AI4Bharat/INCLUDE's lists
nohup ~/sign-data/tools/include_run.sh > ~/sign-data/logs/include.log 2>&1 &
# PopSign ASL v2.1 (CC BY 4.0): balanced sweeps (per sign 24 train / 4 val / 8 test a sweep, round the participants)
nohup /usr/bin/python3 ~/sign-data/tools/popsign_sweeps.py > ~/sign-data/logs/popsign.log 2>&1 &
```

`fetch.py` downloads one big file over many range requests (Zenodo gives one connection ~0.2 MB/s);
`fetch_many.py` downloads many small files at once. The line here tops out near 10 MB/s in all (4 connections to
signdata.cc.gatech.edu already reach it), so jobs that download at the same time share it.

FSboard (finger-spelling, CC BY 4.0, `https://signdata.cc.gatech.edu/data/fsboard/`): its published landmark shards
are scrambled (see `signs/fsboard_source.py`), so `python -m signs.fsboard_source convert` refuses them; FSboard
is read from `video_clips/` with `sign-extract` instead, as a sample in sweeps:

```bash
# needs the four metadata files in ~/sign-data/downloads/fsboard/ (daun_v3-{train,validation,test}.json, dmk_v3-train.json)
nohup /usr/bin/python3 ~/sign-data/tools/fsboard_sweeps.py --sweeps 5 > ~/sign-data/logs/fsboard.log 2>&1 &
```

Sweep k is 8,000 train clips (4,000 daun_v3, 4,000 dmk_v3), 600 daun_v3 validation and 600 test, picked with a
fixed seed, one clip of each signer in turn, never `sensitiveContent`, never the 200 kept as `fsboard-apple`. Each
clip keeps only the signed part (the metadata's annotation times, 0.25 s either side); dataset `fsboard`,
source `apple`, FSboard's own splits. `studio/fsboard_gap.py` compares Apple's landmarks with
what survives of FSboard's MediaPipe ones on the same clips.

Smoke check of the whole path on whatever INCLUDE has so far (a smoke number, not a result):

```bash
cd <repo>/Tools/signs
~/sign-data/venv/bin/python -m signs.landmarks pack ~/sign-data/smoke/include
~/sign-data/venv/bin/python -m signs.train_words --data ~/sign-data/smoke/include --language isl --output ~/sign-data/runs/smoke-include --epochs 15
~/sign-data/venv/bin/python -m signs.evaluate --checkpoint ~/sign-data/runs/smoke-include/checkpoint-best.pt --split test
~/sign-data/venv/bin/python -m signs.export_coreml --checkpoint ~/sign-data/runs/smoke-include/checkpoint-best.pt --output ~/sign-data/out/SignWordsISL-smoke.mlpackage
PYTHONPATH=$PWD ~/sign-data/venv/bin/python studio/coreml_check.py ~/sign-data/runs/smoke-include/checkpoint-best.pt ~/sign-data/out/SignWordsISL-smoke.mlpackage 40
```

(`~/sign-data/smoke/include` is hard links to the INCLUDE clips listed in a copy of its manifest, so packing it
doesn't disturb the running job.)
