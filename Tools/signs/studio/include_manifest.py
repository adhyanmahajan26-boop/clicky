#!/usr/bin/env python3
"""Append SPEC manifest rows for INCLUDE clips whose landmarks exist and aren't in manifest.csv yet.

usage: include_manifest.py <landmarks folder> <clip list tsv> <official lists folder>
"""
import csv, os, re, sys
landmarks_folder, clip_list_path, official_lists_folder = sys.argv[1:4]
split_by_path = {}
for split, file_name in (("train", "include_train.txt"), ("val", "include_val.txt"), ("test", "include_test.txt")):
    for line in open(os.path.join(official_lists_folder, file_name)):
        if line.strip():
            # the lists say .MOV where some zips hold .MP4, so paths are matched without their extension
            split_by_path[os.path.splitext(line.strip())[0].lower()] = split
import json
official_labels = set(json.load(open(os.path.join(official_lists_folder, "label_map_include.json"))))
path_by_clip = {}
for line in open(clip_list_path):
    clip_id, absolute_path, relative_path = line.rstrip("\n").split("\t")
    path_by_clip[clip_id] = relative_path
extract_rows = {}
extract_path = os.path.join(landmarks_folder, "extract.csv")
if os.path.exists(extract_path):
    for row in csv.DictReader(open(extract_path)):
        extract_rows[row["clip_id"]] = row
manifest_path = os.path.join(landmarks_folder, "manifest.csv")
already = set()
if os.path.exists(manifest_path):
    already = {row["clip_id"] for row in csv.DictReader(open(manifest_path))}
columns = ["clip_id", "dataset", "language", "label", "signer", "split", "fps", "width", "height", "frames", "source"]
new_file = not os.path.exists(manifest_path)
added = 0
with open(manifest_path, "a", newline="") as manifest_file:
    writer = csv.DictWriter(manifest_file, fieldnames=columns)
    if new_file:
        writer.writeheader()
    for clip_id, relative_path in path_by_clip.items():
        if clip_id in already or clip_id not in extract_rows:
            continue
        if not os.path.exists(os.path.join(landmarks_folder, clip_id + ".npy")):
            continue
        # "Seasons/61. Summer/MVI_4565.MOV" -> the word folder "61. Summer" -> "summer"
        word_folder = relative_path.split("/")[-2]
        # "61. Summer" -> "summer"; "Ex. Monsoon" -> "monsoon"; the official label map writes words without spaces
        # or punctuation ("Big large" -> "biglarge"), and that spelling is used when it matches
        label = re.sub(r"^\s*(\d+|ex)\s*\.\s*", "", word_folder, flags=re.IGNORECASE).strip().lower()
        squashed_label = re.sub(r"[^a-z]", "", label)
        if squashed_label in official_labels:
            label = squashed_label
        extract_row = extract_rows[clip_id]
        writer.writerow({
            "clip_id": clip_id, "dataset": "include", "language": "isl", "label": label, "signer": "",
            "split": split_by_path.get(os.path.splitext(relative_path)[0].lower(), ""), "fps": extract_row["fps"], "width": extract_row["width"],
            "height": extract_row["height"], "frames": extract_row["frames"], "source": "apple",
        })
        added += 1
print(f"manifest: {added} rows added")
