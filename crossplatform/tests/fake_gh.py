#!/usr/bin/env python3
"""Stand-in for `gh pr create` in the coding tests: records each PR it's asked to open and prints its URL."""
import json, os, sys

D = os.environ.get("THEO_FAKE_DIR") or os.path.dirname(os.path.abspath(__file__))
args = sys.argv[1:]
path = os.path.join(D, "prs.json")
prs = json.load(open(path)) if os.path.exists(path) else []
if args[:2] == ["pr", "create"]:
    head = args[args.index("--head") + 1] if "--head" in args else ""
    title = args[args.index("--title") + 1] if "--title" in args else ""
    if any(p["head"] == head for p in prs):
        sys.stderr.write("a pull request for branch %s already exists\n" % head)
        sys.exit(1)
    url = "https://example.invalid/pr/%d" % (len(prs) + 1)
    prs.append({"head": head, "title": title, "url": url, "draft": "--draft" in args, "cwd": os.getcwd()})
    json.dump(prs, open(path, "w"))
    print(url)
else:
    sys.stderr.write("fake gh: unsupported %s\n" % args)
    sys.exit(2)
