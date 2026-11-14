#!/usr/bin/env python3
"""Writes the copy of an install script that goes into a release, with the release's own facts filled in.

  python3 Tools/install/stamp-installer.py <script in the repo> <copy to write> --repo <owner/name> [--signer <rule>]

The scripts in the repo leave these empty, so nobody's repo or Apple team is written in them:
  install.sh, install-linux.sh   PUBLISHED_RELEASES_REPO=""   and (install.sh) PUBLISHED_SIGNER_REQUIREMENT=''
  install.ps1                    $PublishedReleasesRepo = ""
Each marker must be there exactly once, so a renamed line fails the release instead of shipping a blank.
"""
import argparse, pathlib, re, sys

REPOSITORY_PATTERN = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")


def replace_once(text, pattern, replacement, what, script):
    found = re.findall(pattern, text, flags=re.M)
    if len(found) != 1:
        sys.exit("%s: expected one %s line, found %d" % (script, what, len(found)))
    return re.sub(pattern, lambda match: match.group(1) + replacement, text, count=1, flags=re.M)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("script")
    parser.add_argument("output")
    parser.add_argument("--repo", required=True)
    parser.add_argument("--signer", default="")
    arguments = parser.parse_args()
    if not REPOSITORY_PATTERN.match(arguments.repo):
        sys.exit("--repo must look like owner/name, got %r" % arguments.repo)
    script_path = pathlib.Path(arguments.script)
    text = script_path.read_text(encoding="utf-8")
    if script_path.suffix == ".ps1":
        text = replace_once(text, r'^(\$PublishedReleasesRepo = )""', '"%s"' % arguments.repo, "$PublishedReleasesRepo", script_path)
    else:
        text = replace_once(text, r'^(PUBLISHED_RELEASES_REPO=)""', '"%s"' % arguments.repo, "PUBLISHED_RELEASES_REPO", script_path)
        if arguments.signer:
            if "'" in arguments.signer or "\n" in arguments.signer:
                sys.exit("--signer can't hold a single quote or a line break")
            text = replace_once(text, r"^(PUBLISHED_SIGNER_REQUIREMENT=)''", "'%s'" % arguments.signer, "PUBLISHED_SIGNER_REQUIREMENT", script_path)
    output_path = pathlib.Path(arguments.output)
    with open(output_path, "w", encoding="utf-8", newline="") as output_file:   # open(): Python 3.9 on macOS has no write_text(newline=)
        output_file.write(text)
    output_path.chmod(0o755)


main()
