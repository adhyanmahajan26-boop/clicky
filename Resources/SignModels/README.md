# Bundled sign language models

Copied into the app at `Contents/Resources/SignModels` by the target's "Sign models" build phase; `SignModelFolders`
looks here after the data folder (`~/Library/Application Support/Theo/SignModels`), so a model dropped in there still
wins. Compiled Core ML (`xcrun coremlcompiler compile`) from float16 exports (`python -m signs.export_coreml --float16`);
float16 read exactly like float32 on every test below. Measured on the signers each model learned from: see
docs/SIGN-LANGUAGE.md for what the numbers mean and what these models can't read.

| Model | From | Size | Measured |
| --- | --- | --- | --- |
| SignWordsISL | INCLUDE (CC BY 4.0) word run, epoch 54, weights fae24d3434d98e07; `.reading.json` threshold 0.95 from held-out words | 5.6 MB | INCLUDE test, 815 clips through `sign-eval clips`: 78.9% answered, 98.4% right when answered |
| SignSentencesISL | INCLUDE built sentences (v2) | 5.9 MB | `sign-eval stream`, 200 built streams of 2-5 INCLUDE test clips: 7.5% word error rate |
| SignSpellISL | ISL alphabet photos (two Mendeley sets, CC BY 4.0) | 0.2 MB | 15 of 25 letters on an unseen signer (ISLAN signer 6) |
| SignWordsASL | PopSign ASL v2.1 sweep 1 (CC BY 4.0): 562 signs, 24 train / 4 val / 8 test clips each, participants split by PopSign; epoch 64, weights e1e37f75a2e5b06d; `.reading.json` threshold 0.95 from held-out words | 5.7 MB | PopSign's 10 test signers (never seen), 4,477 clips: 76.4% right whole-clip (Python); through `sign-eval clips` 71.7% with the threshold off, 44.4% answered and 93.8% right when answered with it |
| SignSpellASL | FSboard (CC BY 4.0) sweep 1: 9,200 finger-spelled phrases, 117 train signers | 5.8 MB | FSboard's 15 test signers (never seen), 600 phrases: 7.2% character error rate (Python) |

No ASL sentence model yet: every ASL stretch is read as one sign or one spelled word. To replace a model: train and export it (Tools/signs/README.md), compile it, and copy the
`.mlmodelc` with its `.labels.json` (and `.reading.json`) here.
