#!/usr/bin/env python3
"""Checks that the releases repo and the signing team each live in one place.

  python3 Tools/install/check-release-config.py

- Config/Theo.xcconfig (Mac side) and crossplatform/install/releases-repo (Windows and Linux) name the same releases repo
  (Tools/set-releases-repo.sh changes both).
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


mac_repository = xcconfig_repository()
other_repository = (ROOT / "crossplatform/install/releases-repo").read_text().strip()
if mac_repository != other_repository:
    problems.append("Config/Theo.xcconfig says %r but crossplatform/install/releases-repo says %r: run Tools/set-releases-repo.sh"
                    % (mac_repository, other_repository))

tracked = subprocess.run(["git", "ls-files"], cwd=ROOT, capture_output=True, text=True, check=True).stdout.splitlines()
for relative in tracked:
    path = ROOT / relative
    if path.suffix not in CODE_SUFFIXES or relative == "Tools/install/check-release-config.py" or not path.is_file():
        continue
    text = path.read_text(errors="replace")
    if relative not in REPOSITORY_HOMES and mac_repository and mac_repository in text:
        problems.append("%s names the releases repo %s itself; read it from Config/Theo.xcconfig or crossplatform/install/releases-repo"
                        % (relative, mac_repository))
    if relative != "Config/Signing.local.xcconfig.example" and TEAM_PATTERN.search(text):
        problems.append("%s sets an Apple team; teams belong in Config/Signing.local.xcconfig (not committed)" % relative)

markers = {
    "Tools/install/install.sh": ['PUBLISHED_RELEASES_REPO=""', "PUBLISHED_SIGNER_REQUIREMENT=''"],
    "crossplatform/install/install-linux.sh": ['PUBLISHED_RELEASES_REPO=""'],
    "crossplatform/install/install.ps1": ['$PublishedReleasesRepo = ""'],
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
print("OK    releases repo %s in one place per side; no Apple team in code; installer markers present" % mac_repository)
