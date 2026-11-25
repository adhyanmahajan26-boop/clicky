"""1a: the INCLUDE word model on CSLTR sentence videos, threshold off.
  - whole clip vs the file's key word (when it is one of INCLUDE's words): top-1 / top-5
  - every sliding window: does each INCLUDE word of the sentence's glosses reach top-1 / top-5 somewhere, against
    INCLUDE words NOT in the sentence (the chance of a word turning up in some window anyway)
Writes windows.npz (per clip and present word: best window, its rank and description) for 1b."""
import csv, json, sys, collections, numpy as np
from pathlib import Path
HERE = Path(__file__).parent
sys.path.insert(0, str(HERE))
from scoring import WordScorer, load_clip, whole_clip_features, windows
from signs.features import compute_features

OUT = Path.home() / "sign-data/landmarks/isl-csltr-named"
POINTING = {"i", "you", "he", "she", "we", "it"}
index = json.loads((HERE / "index.json").read_text())
extract = {row["clip_id"]: row for row in csv.DictReader(open(OUT / "extract.csv"))}
scorer = WordScorer()
labels = scorer.labels
number_of = {label: n for n, label in enumerate(labels)}

def word_number(word):
    word = word.lower().replace("-", "").replace(" ", "")
    return number_of.get(word)

whole = collections.Counter()
present = collections.defaultdict(lambda: collections.Counter())  # group -> counts
absent = collections.Counter()
best_rows = []
per_word = collections.defaultdict(lambda: [0, 0, 0])  # word -> occurrences, top1 somewhere, top5 somewhere
size_counts = collections.Counter()
for clip_id, item in sorted(index.items()):
    row = extract.get(clip_id)
    if row is None or not (OUT / f"{clip_id}.npy").exists() or not item["glosses"]:
        continue
    width, height = float(row["width"]), float(row["height"])
    clip = load_clip(OUT / f"{clip_id}.npy", row["fps"])
    size_counts[f"{int(width)}x{int(height)}"] += 1
    whole_probabilities, _ = scorer.score([whole_clip_features(clip, width, height)])
    keyword_number = word_number(item["keyword"]) if item["keyword"] else None
    if keyword_number is not None:
        order = np.argsort(-whole_probabilities[0])
        whole["clips"] += 1; whole["top1"] += order[0] == keyword_number; whole["top5"] += keyword_number in order[:5]
    spans = windows(clip)
    if not spans:
        continue
    probabilities, descriptions = scorer.score([compute_features(clip[start:start + length], width, height) for start, length in spans])
    ranks = (-probabilities).argsort(axis=1).argsort(axis=1) + 1  # rank of every word in every window
    best_rank = ranks.min(axis=0)
    sentence_numbers = {word_number(word) for word in item["glosses"]} - {None}
    for number in sentence_numbers:
        group = "pointing" if labels[number] in POINTING else "other"
        present[group]["words"] += 1; present[group]["top1"] += best_rank[number] == 1; present[group]["top5"] += best_rank[number] <= 5
        per_word[labels[number]][0] += 1; per_word[labels[number]][1] += best_rank[number] == 1; per_word[labels[number]][2] += best_rank[number] <= 5
        window = int(ranks[:, number].argmin())
        best_rows.append((clip_id, labels[number], int(best_rank[number]), spans[window][0], spans[window][1], descriptions[window]))
    for number in range(len(labels)):
        if number in sentence_numbers:
            continue
        group = "pointing" if labels[number] in POINTING else "other"
        absent[group + "_words"] += 1; absent[group + "_top1"] += best_rank[number] == 1; absent[group + "_top5"] += best_rank[number] <= 5
    absent["windows"] += len(spans); absent["clips"] += 1

def share(a, b): return f"{a / max(b, 1):.1%}"
print("clips scored:", absent["clips"], dict(size_counts), "windows:", absent["windows"])
print(f"whole clip vs key word (in INCLUDE's list): {whole['clips']} clips, top-1 {share(whole['top1'], whole['clips'])}, top-5 {share(whole['top5'], whole['clips'])}")
for group in ("other", "pointing"):
    p = present[group]
    print(f"{group} words in the sentence: {p['words']}, top-1 in some window {share(p['top1'], p['words'])}, top-5 {share(p['top5'], p['words'])}"
          f"  | words NOT in it: top-1 {share(absent[group + '_top1'], absent[group + '_words'])}, top-5 {share(absent[group + '_top5'], absent[group + '_words'])}")
print("per word (occurrences, top-1 somewhere, top-5 somewhere):")
for word, (count, top1, top5) in sorted(per_word.items(), key=lambda item: -item[1][0]):
    print(f"  {word:12s} {count:3d}  {top1:3d}  {top5:3d}")
np.savez(HERE / "windows.npz", clip_ids=np.array([r[0] for r in best_rows]), words=np.array([r[1] for r in best_rows]),
         ranks=np.array([r[2] for r in best_rows]), starts=np.array([r[3] for r in best_rows]), lengths=np.array([r[4] for r in best_rows]),
         descriptions=np.array([r[5] for r in best_rows]) if best_rows else np.zeros((0, 1)))
