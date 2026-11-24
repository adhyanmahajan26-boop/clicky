"""Sessions: clips linked when close in MVI number (<= 25), shoulder height (< 0.008 picture heights) and shoulder width
(< 0.012); connected groups are sessions (one camera set-up, so one signer). Writes sessions.json."""
import json, numpy as np, collections
r = json.load(open("placement.json"))
order = sorted(range(len(r)), key=lambda i: r[i][1])
parent = list(range(len(r)))
def find(i):
    while parent[i] != i: parent[i] = parent[parent[i]]; i = parent[i]
    return i
for a_pos, a in enumerate(order):
    for b in order[a_pos + 1:]:
        if r[b][1] - r[a][1] > 25: break
        fa, fb = r[a][4], r[b][4]
        if abs(fa[1] - fb[1]) < 0.008 and abs(fa[2] - fb[2]) < 0.012:
            parent[find(a)] = find(b)
groups = collections.defaultdict(list)
for i in range(len(r)): groups[find(i)].append(i)
sessions = sorted(groups.values(), key=lambda g: min(r[i][1] for i in g))
sizes = [len(g) for g in sessions]
print(len(sessions), "sessions; sizes", sorted(sizes, reverse=True)[:40], "; of 1-4 clips:", sum(1 for s in sizes if s < 5), "holding", sum(s for s in sizes if s < 5), "clips")
json.dump([{"clips": [r[i][0] for i in g], "mvi": [min(r[i][1] for i in g), max(r[i][1] for i in g)],
            "cy": float(np.median([r[i][4][1] for i in g])), "width": float(np.median([r[i][4][2] for i in g])),
            "words": len({r[i][2] for i in g})} for g in sessions], open("sessions.json", "w"), indent=0)
