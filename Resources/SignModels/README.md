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

No ASL models yet. To replace one: train and export it (Tools/signs/README.md), compile it, and copy the
`.mlmodelc` with its `.labels.json` (and `.reading.json`) here.
