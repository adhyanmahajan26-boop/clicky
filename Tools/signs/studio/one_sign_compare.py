"""The sentence model's built one-sign test sentences, and the word model on the same clips.
usage (from Tools/signs, venv python): one_sign_compare.py <sentence checkpoint> <word checkpoint> [split]"""
import sys, numpy as np, torch
from signs.data import WordClipDataset, load_sources, references_in_split
from signs.evaluate import load_evaluation_model
from signs.extra_tasks import split_references_for_checkpoint
from signs.sentences import SentenceSettings
from signs.train_sentences import measuring_dataset, default_measuring_sentence_count
from signs.training import load_checkpoint, pick_device
sentence_path, word_path = sys.argv[1], sys.argv[2]
split = sys.argv[3] if len(sys.argv) > 3 else "test"
sentence_checkpoint = load_checkpoint(sentence_path)
sources = load_sources(sentence_checkpoint["data_folders"])
references = references_in_split(split_references_for_checkpoint(sentence_checkpoint, sources), split)
count = sentence_checkpoint["evaluation_sentences"] or default_measuring_sentence_count(references, sentence_checkpoint["labels"])
dataset = measuring_dataset(sources, references, sentence_checkpoint["labels"], SentenceSettings(**sentence_checkpoint["sentence_settings"]),
                            sentence_checkpoint["seed"], count, split)
one_sign_references = [item.references[0] for item in dataset.items if item.sign_count == 1 and not item.is_real_continuous_clip]
word_checkpoint = load_checkpoint(word_path)
word_model = load_evaluation_model(word_checkpoint)
word_dataset = WordClipDataset(sources, one_sign_references, word_checkpoint["labels"], None, word_checkpoint["seed"], word_checkpoint["frame_count"])
right = 0
with torch.no_grad():
    for index in range(len(word_dataset)):
        features, mask, word_number = word_dataset[index]
        right += int(word_model(features[None], mask[None])[0][0].argmax().item() == word_number.item())
print(f"{split}: {len(one_sign_references)} one-sign sentences; word model on the same clips: {right}/{len(word_dataset)} = {right / max(len(word_dataset), 1):.1%}")
