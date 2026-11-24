#!/usr/bin/env python3
"""ISL-CSLTR (Mendeley kcmpdxky7p, CC BY 4.0; measuring only, never training): what sign-eval read on each sentence
video against the sentence's sign glosses. Counts the gloss words that are in the model's word list (found / missed)
and the words read that are in neither the sentence nor its glosses.
usage: csltr_measure.py <reads.tsv from sign-eval clips --reads> <isl-csltr manifest.csv> <videos.csv> <labels.json> [examples]"""
import csv, json, random, re, sys
reads_path, manifest_path, videos_path, labels_path = sys.argv[1:5]
example_count = int(sys.argv[5]) if len(sys.argv) > 5 else 12
normalised = lambda word: re.sub(r"[^a-z0-9]", "", word.lower())
vocabulary = {normalised(label) for label in json.load(open(labels_path))}
manifest = {row["clip_id"]: row for row in csv.DictReader(open(manifest_path))}
sentences = {row["clip_id"]: row["sentence"] for row in csv.DictReader(open(videos_path))}
found = missed = extra = read_total = unclear = 0
examples = []
for line in open(reads_path):
    clip_id, _, read = line.rstrip("\n").partition("\t")
    glosses = [normalised(word) for word in manifest[clip_id]["label"].split("|")]
    sentence_words = {normalised(word) for word in sentences[clip_id].split()} | set(glosses)
    in_list = [word for word in glosses if word in vocabulary]
    read_words = [normalised(word) for word in read.split() if word != "?"]
    unclear += sum(1 for word in read.split() if word == "?")
    read_total += len(read_words)
    remaining = list(read_words)
    for word in in_list:
        if word in remaining:
            remaining.remove(word)
            found += 1
        else:
            missed += 1
    extra += sum(1 for word in read_words if word not in sentence_words)
    examples.append((sentences[clip_id], " ".join(glosses), read))
print(f"videos {len(examples)}; gloss words in the word list {found + missed}: found {found}, missed {missed}; "
      f"words read {read_total}, in neither sentence nor glosses {extra}; unclear signs {unclear}")
random.seed(3)
for sentence, glosses, read in random.sample(examples, min(example_count, len(examples))):
    print(f"  '{sentence}' (glosses: {glosses}) -> {read or '(nothing)'}")
