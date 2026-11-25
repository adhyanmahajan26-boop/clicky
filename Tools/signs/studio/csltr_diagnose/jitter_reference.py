"""analyze_1c's measures over many clips of a landmarks folder. usage: jitter_reference.py <folder> [n]"""
import csv, sys, numpy as np, importlib.util
from pathlib import Path
spec = importlib.util.spec_from_file_location("a1c", Path(__file__).parent / "analyze_1c.py")
source = open(spec.origin).read().split("folders = {")[0]  # just the measure function
namespace = {}; exec(source, namespace)
folder = Path(sys.argv[1]); count = int(sys.argv[2]) if len(sys.argv) > 2 else 200
path = folder / "manifest.csv" if (folder / "manifest.csv").exists() else folder / "extract.csv"
rows = [r for r in csv.DictReader(open(path)) if (folder / f"{r['clip_id']}.npy").exists()]
rows = rows[:: max(1, len(rows) // count)][:count]
by_size = {}
for row in rows:
    by_size.setdefault(f"{row['width']}x{row['height']}", []).append(namespace["measure"](folder / f"{row['clip_id']}.npy", float(row["width"]), float(row["height"])))
for size, results in by_size.items():
    raised = sum(r["raised"] for r in results)
    print(f"{folder.name} {size} clips {len(results)}: hand found {sum(r['found'] * r['raised'] for r in results) / max(raised, 1):.1%}, median jitter "
          f"{np.nanmedian([r['jitter'] for r in results]):.3f}, confidence {np.nanmean([r['confidence'] for r in results]):.2f}, shoulder width {np.nanmedian([r['shoulder_width'] for r in results]):.3f} picture heights")
