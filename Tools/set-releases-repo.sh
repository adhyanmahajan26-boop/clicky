#!/bin/bash
# Changes where Theo's builds are published (and where installs and updates look), in the two
# places that hold it: Config/Theo.xcconfig (Mac app, release.sh, install.sh, the cask) and
# crossplatform/install/releases-repo (Windows and Linux installers). Takes effect for the Mac
# app's updater from the next build, and for the installers from the next release.
#
# Usage: Tools/set-releases-repo.sh <owner>/<repo>
set -euo pipefail
cd "$(dirname "$0")/.."
REPO="${1:?owner/name of the releases repo}"
[[ "$REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || { echo "must look like owner/name: $REPO" >&2; exit 1; }
sed -i.bak "s|^THEO_RELEASES_REPO = .*|THEO_RELEASES_REPO = $REPO|" Config/Theo.xcconfig && rm -f Config/Theo.xcconfig.bak
printf '%s\n' "$REPO" > crossplatform/install/releases-repo
python3 Tools/install/check-release-config.py
echo "Releases repo is now $REPO."
