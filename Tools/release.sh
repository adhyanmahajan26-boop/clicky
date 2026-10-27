#!/bin/zsh
# Builds a Release Clicky with a new build number, zips it, and publishes it
# as a GitHub release of the updates repo, which every installed Clicky picks
# up from Setup › Updates or the panel's "Update now".
#
# Usage: Tools/release.sh "What changed (one or two lines)"
# Env:   CLICKY_UPDATES_REPO (default adhyanmahajan26-boop/claudia-releases)
#        CLICKY_RELEASE_DRY_RUN=1 builds and zips without publishing.
set -euo pipefail
cd "$(dirname "$0")/.."
NOTES="${1:-New build}"
REPO="${CLICKY_UPDATES_REPO:-adhyanmahajan26-boop/claudia-releases}"
BUILD="$(date +%Y%m%d%H%M)"
OUT="${CLICKY_RELEASE_OUT:-$HOME/Documents/Claudia-install/releases}"
DERIVED="${CLICKY_RELEASE_DERIVED:-$TMPDIR/clicky-release-dd}"
mkdir -p "$OUT"

echo "Building Clicky build $BUILD…"
xcodebuild -project leanring-buddy.xcodeproj -scheme leanring-buddy -configuration Release \
  -derivedDataPath "$DERIVED" CURRENT_PROJECT_VERSION="$BUILD" build > "$OUT/build-$BUILD.log" 2>&1 \
  || { tail -20 "$OUT/build-$BUILD.log"; exit 1; }
APP="$DERIVED/Build/Products/Release/Clicky.app"
codesign --verify --deep --strict "$APP"
ZIP="$OUT/Clicky-$BUILD.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
SHA="$(shasum -a 256 "$ZIP" | cut -d' ' -f1)"
echo "Zip: $ZIP"
echo "sha256: $SHA"

if [[ "${CLICKY_RELEASE_DRY_RUN:-0}" == "1" ]]; then
  echo "Dry run: not published."
  exit 0
fi
gh release create "build-$BUILD" "$ZIP" --repo "$REPO" --title "Claudia build $BUILD" \
  --notes "$(printf '%s\n\nsha256: %s\n' "$NOTES" "$SHA")"
echo "Published build-$BUILD to $REPO"
