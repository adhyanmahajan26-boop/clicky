#!/bin/bash
# Prints the Homebrew cask for one Theo build.
# Usage: Tools/install/make-cask.sh <build> <sha256> [releases repo owner/name]
# Put the output in the tap repo as Casks/theo.rb (tap repo: <owner>/homebrew-theo, public).
set -euo pipefail
BUILD="${1:?build number}"
SHA="${2:?sha256}"
REPO="${3:-adhyanmahajan26-boop/claudia-releases}"
TEMPLATE="$(dirname "$0")/homebrew/theo.rb.template"
sed -e "s|@BUILD@|$BUILD|g" -e "s|@SHA256@|$SHA|g" -e "s|@REPO@|$REPO|g" "$TEMPLATE"
