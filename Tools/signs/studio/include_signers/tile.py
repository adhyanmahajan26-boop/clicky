import json, sys, glob, matplotlib; matplotlib.use("Agg"); import matplotlib.pyplot as plt, matplotlib.image as mpimg
from pathlib import Path
H = Path(__file__).parent; sessions = json.load(open(H / "sessions.json"))
files = sorted(glob.glob(str(H / "peek/s*.jpg")))
cols = 8; rows = (len(files) + cols - 1) // cols
fig, axes = plt.subplots(rows, cols, figsize=(cols * 2.2, rows * 3.1))
for ax in axes.flat: ax.axis("off")
for ax, f in zip(axes.flat, files):
    n = int(Path(f).stem[1:]); s = sessions[n]
    ax.imshow(mpimg.imread(f)); ax.set_title(f"s{n} ({len(s['clips'])}) mvi {s['mvi'][0]}", fontsize=8)
fig.tight_layout(); fig.savefig(H / "peek/tile.png", dpi=75)
