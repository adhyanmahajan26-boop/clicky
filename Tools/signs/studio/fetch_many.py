#!/usr/bin/env python3
"""Download many small files at once. usage: fetch_many.py <base url ending in /> <folder> <file with one name a line> [parallel]
A file already in the folder is skipped; each is written as .part and renamed when complete."""
import os, sys, time, urllib.parse, urllib.request, concurrent.futures as cf
base, folder, names_path = sys.argv[1:4]
parallel = int(sys.argv[4]) if len(sys.argv) > 4 else 8
names = [line.strip() for line in open(names_path) if line.strip()]
os.makedirs(folder, exist_ok=True)
def fetch(name):
    # a name may hold folders ("train/hello/x.mp4"): they are made under the folder, and quoted in the URL piece by piece
    target = os.path.join(folder, name)
    if os.path.exists(target): return 0
    os.makedirs(os.path.dirname(target), exist_ok=True)
    for attempt in range(6):
        try:
            request = urllib.request.Request(base + "/".join(urllib.parse.quote(piece) for piece in name.split("/")), headers={"User-Agent": "sign-data-fetch/1.0"})
            with urllib.request.urlopen(request, timeout=300) as response, open(target + ".part", "wb") as part:
                while True:
                    block = response.read(1 << 20)
                    if not block: break
                    part.write(block)
            os.rename(target + ".part", target)
            return 0
        except Exception as error:
            time.sleep(3 + attempt * 5)
    print("failed:", name, flush=True)
    return 1
with cf.ThreadPoolExecutor(parallel) as pool:
    failures = sum(pool.map(fetch, names))
print(f"{len(names) - failures} of {len(names)} downloaded", flush=True)
