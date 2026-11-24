#!/usr/bin/env python3
"""Send one command to a test profile's debug inbox and print the reply. usage: debugcmd.py <profile> '<json>' [timeout]"""
import json, sys, time, uuid
from pathlib import Path
profile, payload = sys.argv[1], json.loads(sys.argv[2])
timeout = float(sys.argv[3]) if len(sys.argv) > 3 else 120
clicky = Path.home() / f"Library/Application Support/Theo-Test-{profile}/home/.clicky"
inbox, outbox = clicky / "debug-inbox", clicky / "debug-outbox"
ident = uuid.uuid4().hex
(inbox / f"{ident}.tmp").write_text(json.dumps(payload))
(inbox / f"{ident}.tmp").rename(inbox / f"{ident}.json")
deadline = time.time() + timeout
while time.time() < deadline:
    reply = outbox / f"{ident}.json"
    if reply.exists():
        print(reply.read_text()); reply.unlink(); sys.exit(0)
    time.sleep(0.1)
print(json.dumps({"error": "timeout"}))
