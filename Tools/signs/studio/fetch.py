#!/usr/bin/env python3
"""Download one big file with many parallel HTTP range requests (Zenodo gives each connection only ~0.3 MB/s).

usage: fetch.py <url> <output file> [--connections 16] [--chunk-mb 16]

Resumable: finished chunks are listed in <output>.chunks-done; a rerun fetches only the rest.
The output appears under its final name only when every chunk is in.
"""
import os, sys, threading, time, urllib.request, urllib.error, argparse

def total_size(url):
    for attempt in range(20):
        try:
            request = urllib.request.Request(url, headers={"Range": "bytes=0-0", "User-Agent": "sign-data-fetch/1.0"})
            with urllib.request.urlopen(request, timeout=60) as response:
                content_range = response.headers.get("Content-Range")
                if content_range:
                    return int(content_range.split("/")[-1])
                return int(response.headers["Content-Length"])
        except Exception as error:
            print(f"size attempt {attempt + 1}: {error}", flush=True)
            time.sleep(min(60, 2 + attempt * 3))
    raise SystemExit("could not get the file size")

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("url"); parser.add_argument("output")
    parser.add_argument("--connections", type=int, default=4)
    parser.add_argument("--chunk-mb", type=int, default=4)
    arguments = parser.parse_args()
    if os.path.exists(arguments.output):
        print("already there:", arguments.output); return
    size = total_size(arguments.url)
    chunk_bytes = arguments.chunk_mb << 20
    partial_path = arguments.output + ".partial"
    done_path = arguments.output + ".chunks-done"
    if not os.path.exists(partial_path):
        with open(partial_path, "wb") as partial_file:
            partial_file.truncate(size)
    done_chunks = set()
    if os.path.exists(done_path):
        done_chunks = {int(line) for line in open(done_path) if line.strip()}
    chunk_count = (size + chunk_bytes - 1) // chunk_bytes
    pending = [index for index in range(chunk_count) if index not in done_chunks]
    lock = threading.Lock()
    progress = {"bytes": 0, "failed": 0}
    start = time.time()

    def fetch_chunk(index):
        first = index * chunk_bytes
        last = min(size, first + chunk_bytes) - 1
        for attempt in range(40):
            try:
                request = urllib.request.Request(arguments.url, headers={"Range": f"bytes={first}-{last}", "User-Agent": "sign-data-fetch/1.0"})
                with urllib.request.urlopen(request, timeout=240) as response:
                    if response.status != 206:
                        raise IOError(f"status {response.status}")
                    data = response.read()
                if len(data) != last - first + 1:
                    raise IOError(f"short chunk {len(data)}")
                with lock:
                    with open(partial_path, "r+b") as partial_file:
                        partial_file.seek(first); partial_file.write(data)
                    with open(done_path, "a") as done_file:
                        done_file.write(f"{index}\n")
                    progress["bytes"] += len(data)
                return
            except Exception as error:
                time.sleep(min(60, 2 + attempt * 2))
        with lock:
            progress["failed"] += 1

    def worker():
        while True:
            with lock:
                if not pending: return
                index = pending.pop(0)
            fetch_chunk(index)

    threads = [threading.Thread(target=worker, daemon=True) for _ in range(arguments.connections)]
    for thread in threads: thread.start()
    while any(thread.is_alive() for thread in threads):
        time.sleep(15)
        elapsed = time.time() - start
        print(f"  {os.path.basename(arguments.output)}: {progress['bytes'] / 1e6:.0f} MB this run, {progress['bytes'] / 1e6 / elapsed:.1f} MB/s", flush=True)
    if progress["failed"]:
        raise SystemExit(f"{progress['failed']} chunks failed; run again to finish")
    os.rename(partial_path, arguments.output)
    os.remove(done_path)
    print(f"done {arguments.output}: {size / 1e9:.2f} GB in {time.time() - start:.0f} s", flush=True)

main()
