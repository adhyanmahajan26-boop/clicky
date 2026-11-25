"""The same 5 FSboard test phrases as r9_feed.py, through signsFeed in the silent test profile (auto-send 0, never sent)."""
import csv, json, random, subprocess, sys
from pathlib import Path
def hs(**kw):
    return json.loads(subprocess.run([sys.executable, str(Path.home() / "sign-data/tools/debugcmd.py"), "r9feed", json.dumps(dict(cmd="handSigns", **kw)), "180"], capture_output=True, text=True).stdout)
fsboard = Path.home() / "sign-data/snapshots/spell-asl-fsboard-s1/fsboard"
rows = random.Random(13).sample([r for r in csv.DictReader(open(fsboard / "manifest.csv")) if r["split"] == "test"], 5)
hs(action="on"); hs(action="mode", mode="signs"); hs(action="language", language="asl"); hs(action="signsState")
for r in rows:
    reply = hs(action="signsFeed", path=str(fsboard / f"{r['clip_id']}.npy"), fps=float(r["fps"]), width=float(r["width"]), height=float(r["height"]))
    print(f"signed: {r['label']} | read: {' '.join(t['text'] for t in (reply.get('result') or {}).get('read', []))}")
state = hs(action="signsState")["result"]; print("sent:", state["sent"], "| autoSendSeconds:", state["autoSendSeconds"])
hs(action="off")
