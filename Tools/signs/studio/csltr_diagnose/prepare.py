"""index.json for the CSLTR sentence videos named by a key word (single.txt), by MVI number (mvi.txt) and the
paired-size ones (pair_videos.txt), and list.tsv of those downloaded but not yet extracted."""
import csv, json, re
from pathlib import Path
DOWN = Path.home() / "sign-data/downloads/isl-csltr"
OUT = Path.home() / "sign-data/landmarks/isl-csltr-named"
HERE = Path(__file__).parent
OUT.mkdir(parents=True, exist_ok=True)
glosses = {row["Sentence"].strip().lower(): row["SIGN GLOSSES"].split() for row in csv.DictReader(open(DOWN / "glosses.csv"))}
names = []
for list_name in ("single.txt", "mvi.txt", "pair_videos.txt"):
    for line in open(DOWN / list_name):
        if line.strip() and line.strip() not in names:
            names.append(line.strip())
index = {}
for number, name in enumerate(names):
    sentence = name.split("/")[2].strip().lower()
    stem = re.sub(r"\s*\(\d+\)$", "", name.split("/")[-1].rsplit(".", 1)[0]).strip().lower()
    index[f"csltr-named-{number:04d}"] = {"zip_path": name, "sentence": sentence, "keyword": None if stem.startswith("mvi") or stem == sentence else stem,
                                         "glosses": glosses.get(sentence), "lists": [l for l in ("single.txt", "mvi.txt", "pair_videos.txt") if name in open(DOWN / l).read()]}
(HERE / "index.json").write_text(json.dumps(index, indent=1))
todo = [(clip_id, DOWN / "members" / item["zip_path"]) for clip_id, item in index.items()
        if (DOWN / "members" / item["zip_path"]).exists() and not (OUT / f"{clip_id}.npy").exists()]
(HERE / "list.tsv").write_text("".join(f"{clip_id}\t{path}\n" for clip_id, path in todo))
print(len(index), "videos;", len(todo), "ready to extract")
