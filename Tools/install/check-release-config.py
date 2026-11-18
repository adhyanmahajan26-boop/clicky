#!/usr/bin/env python3
"""Checks that the releases repo and the signing team each live in one place.

  python3 Tools/install/check-release-config.py

- Config/Theo.xcconfig (Mac side) and crossplatform/install/releases-repo (Windows and Linux) each name a releases repo.
  They may differ: Mac builds go to the Mac's repo with Tools/release.sh, and Windows builds are published by
  .github/workflows/windows-release.yml to the repo in releases-repo (Tools/set-releases-repo.sh changes either or both).
- No code, script or project file names a releases repo or an Apple team itself: they read those two files, or have it
  written into the copy a release publishes (Tools/install/stamp-installer.py). Docs may explain them.
- The installers in the repo carry their published-repo and signer markers, empty.
Runs anywhere Python 3 and git run (CI: .github/workflows/installers.yml).
"""
import pathlib, re, subprocess, sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
CODE_SUFFIXES = {".swift", ".sh", ".ps1", ".py", ".rs", ".js", ".ts", ".rb", ".template", ".plist", ".yml", ".yaml", ".pbxproj",
                 ".xcconfig", ".json", ".toml", ".entitlements"}
# The releases repo name may appear only here (as data); the signing team nowhere in code.
REPOSITORY_HOMES = {"Config/Theo.xcconfig", "crossplatform/install/releases-repo"}
TEAM_PATTERN = re.compile(r"DEVELOPMENT_TEAM\s*=\s*[A-Z0-9]{10}\b")
problems = []


def xcconfig_repository():
    text = (ROOT / "Config/Theo.xcconfig").read_text()
    found = re.findall(r"^\s*THEO_RELEASES_REPO\s*=\s*(\S+)", text, flags=re.M)
    if len(found) != 1:
        problems.append("Config/Theo.xcconfig must set THEO_RELEASES_REPO exactly once (found %d)" % len(found))
        return ""
    return found[0]


REPOSITORY_PATTERN = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")
mac_repository = xcconfig_repository()
other_repository = (ROOT / "crossplatform/install/releases-repo").read_text().strip()
for where, repository in (("Config/Theo.xcconfig", mac_repository), ("crossplatform/install/releases-repo", other_repository)):
    if repository and not REPOSITORY_PATTERN.match(repository):
        problems.append("%s names %r, which isn't owner/name: run Tools/set-releases-repo.sh" % (where, repository))
if not other_repository:
    problems.append("crossplatform/install/releases-repo is empty: run Tools/set-releases-repo.sh --windows-linux <owner>/<repo>")

tracked = subprocess.run(["git", "ls-files"], cwd=ROOT, capture_output=True, text=True, check=True).stdout.splitlines()
for relative in tracked:
    path = ROOT / relative
    if path.suffix not in CODE_SUFFIXES or relative == "Tools/install/check-release-config.py" or not path.is_file():
        continue
    text = path.read_text(errors="replace")
    for repository in {mac_repository, other_repository}:
        if relative not in REPOSITORY_HOMES and repository and repository in text:
            problems.append("%s names the releases repo %s itself; read it from Config/Theo.xcconfig or crossplatform/install/releases-repo"
                            % (relative, repository))
    if relative != "Config/Signing.local.xcconfig.example" and TEAM_PATTERN.search(text):
        problems.append("%s sets an Apple team; teams belong in Config/Signing.local.xcconfig (not committed)" % relative)

markers = {
    "Tools/install/install.sh": ['PUBLISHED_RELEASES_REPO=""', "PUBLISHED_SIGNER_REQUIREMENT=''"],
    "crossplatform/install/install-linux.sh": ['PUBLISHED_RELEASES_REPO=""'],
    "crossplatform/install/install.ps1": ['$PublishedReleasesRepo = ""'],
    "crossplatform/tester/Theo-Test.ps1": ['$PublishedReleasesRepo = ""'],
    "crossplatform/tester/RUN-TEST.cmd": ['set "PUBLISHED_RELEASES_REPO="'],
}
for relative, lines in markers.items():
    text_lines = (ROOT / relative).read_text().splitlines()
    for line in lines:
        if text_lines.count(line) != 1:
            problems.append("%s must have the line %s exactly once (release copies are stamped from it)" % (relative, line))

for problem in problems:
    print("FAIL  " + problem)
if problems:
    sys.exit(1)
print("OK    releases repos: Mac %s, Windows and Linux %s, each in one place; no Apple team in code; installer markers present"
      % (mac_repository, other_repository))
