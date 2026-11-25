"""Fresh test profile, silent: auto-send off, nothing ever sent; the default language, then ISL and ASL clips fed
through Sign to text with signsFeed (answers with the tokens read)."""
import csv, json, os, random, subprocess, sys
from pathlib import Path
def hs(**kw):
    out = subprocess.run([sys.executable, str(Path.home() / "sign-data/tools/debugcmd.py"), "r9feed", json.dumps(dict(cmd="handSigns", **kw)), "180"], capture_output=True, text=True).stdout
    return json.loads(out)
def pick(folder, split, n, seed):
    rows = [r for r in csv.DictReader(open(Path(folder) / "manifest.csv")) if r["split"] == split]
    return random.Random(seed).sample(rows, n)
out = {"start": hs(action="state")["result"]["signs"]["language"]}
hs(action="on"); hs(action="mode", mode="signs")
def feed(folder, rows):
    results = []
    for r in rows:
        reply = hs(action="signsFeed", path=str(Path(folder) / f"{r['clip_id']}.npy"), fps=float(r["fps"]), width=float(r["width"]), height=float(r["height"]))
        read = [t["text"] for t in (reply.get("result") or {}).get("read", [])]
        results.append({"signed": r["label"], "read": read, "error": reply.get("error")})
        hs(action="signsState")  # the line stays unsent: auto-send is off and send is never called
    return results
out["isl"] = feed(Path.home() / "sign-data/landmarks/include", pick(Path.home() / "sign-data/landmarks/include", "test", 5, 11))
out["isl_models"] = hs(action="signsState")["result"]["models"]
hs(action="language", language="asl")
popsign = Path.home() / "sign-data/snapshots/words-asl-popsign-s1/asl-s1-popsign"
fsboard = Path.home() / "sign-data/snapshots/spell-asl-fsboard-s1/fsboard"
hs(action="signsState")
out["asl_popsign"] = feed(popsign, pick(popsign, "test", 10, 12))
out["asl_fsboard"] = feed(fsboard, pick(fsboard, "test", 5, 13))
state = hs(action="signsState")["result"]
out["asl_models"] = state["models"]; out["sent"] = state["sent"]; out["autoSendSeconds"] = state["autoSendSeconds"]
hs(action="off")
print(json.dumps(out, indent=1))
