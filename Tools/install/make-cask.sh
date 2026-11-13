#!/bin/bash
# Prints the Homebrew cask for one Theo build.
# Usage: Tools/install/make-cask.sh <build> <sha256> [releases repo owner/name]
# The repo defaults to THEO_RELEASES_REPO in Config/Theo.xcconfig.
# Put the output in the tap repo as Casks/theo.rb (tap repo: <owner>/homebrew-theo, public).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
BUILD="${1:?build number}"
SHA="${2:?sha256}"
REPO="${3:-$(sed -n 's/^[[:space:]]*THEO_RELEASES_REPO[[:space:]]*=[[:space:]]*\([^[:space:]]*\).*/\1/p' "$HERE/../../Config/Theo.xcconfig" | head -n 1)}"
[ -n "$REPO" ] || { echo "no releases repo: pass one, or set THEO_RELEASES_REPO in Config/Theo.xcconfig" >&2; exit 1; }
TEMPLATE="$HERE/homebrew/theo.rb.template"
sed -e "s|@BUILD@|$BUILD|g" -e "s|@SHA256@|$SHA|g" -e "s|@REPO@|$REPO|g" "$TEMPLATE"
