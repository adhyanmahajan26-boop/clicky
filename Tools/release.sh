#!/bin/zsh
# Builds a Release Theo with a new build number, zips it, and publishes it as a GitHub release of
# the releases repo, which every installed Theo picks up from Settings › Updates or "Update now".
#
# The release also carries SHA256SUMS, SIGNER (who signed this build, as a code requirement) and
# install.sh with this repo and signer written in, so a new Mac can install from Terminal with
#   curl -fsSL https://github.com/<repo>/releases/latest/download/install.sh | bash
# (no Apple Developer account or notarization needed; see docs/INSTALL.md), and the run writes a
# Homebrew cask for this build next to the zip.
#
# Usage: Tools/release.sh "What changed (one or two lines)"
# Needs: a signing team (Tools/setup-signing.sh; this script runs it once if none is set).
#        An unsigned or ad hoc signed build is never released.
# Env:   CLICKY_UPDATES_REPO   publish here instead of THEO_RELEASES_REPO in Config/Theo.xcconfig
#        CLICKY_RELEASE_OUT    output folder (default build/releases in this repo, which git ignores)
#        CLICKY_RELEASE_DRY_RUN=1 builds and zips without publishing.
set -euo pipefail
cd "$(dirname "$0")/.."
NOTES="${1:-New build}"
CONFIG_REPO="$(sed -n 's/^[[:space:]]*THEO_RELEASES_REPO[[:space:]]*=[[:space:]]*\([^[:space:]]*\).*/\1/p' Config/Theo.xcconfig | head -n 1)"
REPO="${CLICKY_UPDATES_REPO:-$CONFIG_REPO}"
[[ -n "$REPO" ]] || { echo "No releases repo: set THEO_RELEASES_REPO in Config/Theo.xcconfig (Tools/set-releases-repo.sh)."; exit 1; }
BUILD="$(date +%Y%m%d%H%M)"
OUT="${CLICKY_RELEASE_OUT:-$PWD/build/releases}"
DERIVED="${CLICKY_RELEASE_DERIVED:-$TMPDIR/clicky-release-dd}"
mkdir -p "$OUT"

# The team lives in Config/Signing.local.xcconfig, never in the project. Set it once if this Mac has none,
# from the Apple Development certificate in the keychain (it stops and says what to do if that's unclear).
if [[ "$(Tools/setup-signing.sh --show)" == "no team set"* ]]; then
  echo "No signing team set for this Mac yet; looking for one."
  Tools/setup-signing.sh
fi

echo "Building Theo build $BUILD for $REPO…"
xcodebuild -project leanring-buddy.xcodeproj -scheme leanring-buddy -configuration Release \
  -derivedDataPath "$DERIVED" CURRENT_PROJECT_VERSION="$BUILD" build > "$OUT/build-$BUILD.log" 2>&1 \
  || { tail -20 "$OUT/build-$BUILD.log"; exit 1; }
BUILT="$DERIVED/Build/Products/Release/Clicky.app"
# Shipped as Theo.app (the display name is Theo; the folder name is what Finder shows).
STAGE="$OUT/stage-$BUILD"; rm -rf "$STAGE"; mkdir -p "$STAGE"
APP="$STAGE/Theo.app"
ditto "$BUILT" "$APP"
codesign --verify --deep --strict "$APP"
# The connector hub helper is built into Contents/Helpers by the Xcode build phase; this says plainly if it is missing.
bash Tools/build-connectors-helper.sh --check "$APP"
# Signed with the Apple Development identity (never ad hoc), so macOS keeps Theo's permissions across updates.
SIGNING="$(codesign -dv --verbose=2 "$APP" 2>&1)"   # Not piped: with pipefail, grep -q closing early fails the check.
[[ "$SIGNING" == *"Authority=Apple Development"* ]] || {
  echo "Theo.app isn't signed with an Apple Development identity, so it can't be released (macOS would reset every"
  echo "user's permissions with each update). Set your team with Tools/setup-signing.sh and run this again."
  exit 1
}
# macOS keeps a permission (Accessibility, Screen Recording, Microphone) against the app's designated
# requirement. If this build doesn't satisfy the installed Theo's (a new certificate, a changed name or
# Apple ID), every user would be asked for every permission again, so stop here. (Compared with the
# installed copy rather than a file in the repo, so the certificate's name and email aren't committed.)
PREVIOUS_APP="${CLICKY_RELEASE_PREVIOUS_APP:-/Applications/Theo.app}"
if [[ -d "$PREVIOUS_APP" && "${CLICKY_ALLOW_NEW_SIGNER:-0}" != "1" ]]; then
  PREVIOUS_DR="$(codesign -d -r- "$PREVIOUS_APP" 2>&1 | sed -n 's/^designated => //p')"
  if ! codesign --verify -R "=$PREVIOUS_DR" "$APP" 2>/dev/null; then
    echo "This build doesn't satisfy $PREVIOUS_APP's designated requirement, so every user's permissions would reset:"
    echo "  installed: $PREVIOUS_DR"
    echo "  new:       $(codesign -d -r- "$APP" 2>&1 | sed -n 's/^designated => //p')"
    echo "If that's intended, rerun with CLICKY_ALLOW_NEW_SIGNER=1 (installs then need install.sh --allow-new-signer once)."
    exit 1
  fi
fi
# Who signed this build, in the strict form install.sh accepts. It goes into the SIGNER file and the published
# install.sh, so the installer checks downloads against this build's own signer without any team in the repo.
SIGNER_RULE="$(Tools/install/signer-requirement.sh "$APP")"
codesign --verify -R "=$SIGNER_RULE" "$APP" || { echo "the build doesn't satisfy its own signer rule: $SIGNER_RULE"; exit 1; }
ZIP="$OUT/Theo-$BUILD.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
SHA="$(shasum -a 256 "$ZIP" | cut -d' ' -f1)"
SIGNER="$STAGE/SIGNER"
printf '%s\n' "$SIGNER_RULE" > "$SIGNER"
INSTALLER="$STAGE/install.sh"
python3 Tools/install/stamp-installer.py Tools/install/install.sh "$INSTALLER" --repo "$REPO" --signer "$SIGNER_RULE"
bash -n "$INSTALLER"
# Same format as `shasum -a 256`, which install.sh (and the Windows/Linux installers) read.
SUMS="$STAGE/SHA256SUMS"
(cd "$STAGE" && shasum -a 256 SIGNER install.sh) > "$SUMS.parts"
{ printf '%s  %s\n' "$SHA" "$(basename "$ZIP")"; cat "$SUMS.parts"; } > "$SUMS"
rm -f "$SUMS.parts"
CASK="$OUT/theo-$BUILD.rb"
Tools/install/make-cask.sh "$BUILD" "$SHA" "$REPO" > "$CASK"
echo "Zip: $ZIP"
echo "sha256: $SHA"
echo "Signer: $SIGNER_RULE"
echo "Cask: $CASK"

if [[ "${CLICKY_RELEASE_DRY_RUN:-0}" == "1" ]]; then
  echo "Dry run: not published. Release files are in $STAGE."
  exit 0
fi
gh release create "build-$BUILD" "$ZIP" "$SUMS" "$SIGNER" "$INSTALLER" --repo "$REPO" --title "Theo build $BUILD" \
  --notes "$(printf '%s\n\nsha256: %s\n' "$NOTES" "$SHA")"
echo "Published build-$BUILD to $REPO"
