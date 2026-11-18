#!/bin/bash
# Changes where Theo's builds are published (and where installs and updates look). Two places hold it:
#   Config/Theo.xcconfig                 the Mac app, release.sh, install.sh, the cask
#   crossplatform/install/releases-repo  Windows and Linux: the in-app updater, install.ps1, install-linux.sh, the tester
#                                        kit, and .github/workflows/windows-release.yml, which publishes Windows builds
#                                        only when this names the repo the workflow runs in
# They may name different repos. Takes effect for the Mac app's updater from the next build, and for Windows and Linux
# from the next build published.
#
# Usage: Tools/set-releases-repo.sh <owner>/<repo>                   both
#        Tools/set-releases-repo.sh --mac <owner>/<repo>             the Mac only
#        Tools/set-releases-repo.sh --windows-linux <owner>/<repo>   Windows and Linux only
set -euo pipefail
cd "$(dirname "$0")/.."
WHICH="both"
case "${1:-}" in
  --mac) WHICH="mac"; shift ;;
  --windows-linux) WHICH="windows-linux"; shift ;;
esac
REPO="${1:?owner/name of the releases repo}"
[[ "$REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || { echo "must look like owner/name: $REPO" >&2; exit 1; }
if [[ "$WHICH" != "windows-linux" ]]; then
  sed -i.bak "s|^THEO_RELEASES_REPO = .*|THEO_RELEASES_REPO = $REPO|" Config/Theo.xcconfig && rm -f Config/Theo.xcconfig.bak
fi
if [[ "$WHICH" != "mac" ]]; then
  printf '%s\n' "$REPO" > crossplatform/install/releases-repo
fi
python3 Tools/install/check-release-config.py
case "$WHICH" in
  mac) echo "The Mac's releases repo is now $REPO." ;;
  windows-linux) echo "The Windows and Linux releases repo is now $REPO." ;;
  *) echo "Releases repo is now $REPO." ;;
esac
