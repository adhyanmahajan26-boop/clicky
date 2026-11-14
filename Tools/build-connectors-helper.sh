#!/bin/bash
# Builds Theo's connector hub, `theo-connectors` (crossplatform/crates/theo-connectors, contract in
# crossplatform/docs/CONNECTORS.md), and puts it in Theo.app/Contents/Helpers, signed with the app's own identity.
#
# Called three ways:
#   - by the Xcode build phase "Connector helper" (no arguments: it reads Xcode's build settings). A Release build gets a
#     universal binary (Apple silicon and Intel); a Debug build only this Mac's kind, which is quicker.
#   - by hand: Tools/build-connectors-helper.sh <path to the .app> [universal]
#   - by Tools/release.sh: Tools/build-connectors-helper.sh --check <path to the .app>, which only checks that the built app
#     has a universal, signed helper and says so plainly if it doesn't.
#
# Without Rust the build still succeeds: Xcode shows a warning, and Theo says "connector helper missing" and reaches apps
# through Claude Code, as it did before the hub. Install Rust from https://rustup.rs to get the helper.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
CRATE_FOLDER="$REPO/crossplatform"
HELPER_NAME="theo-connectors"

warn() { echo "warning: Connector helper: $*"; }

# MARK: --check (release.sh)
if [[ "${1:-}" == "--check" ]]; then
  APP="${2:?--check needs the path to Theo.app}"
  HELPER="$APP/Contents/Helpers/$HELPER_NAME"
  if [[ ! -x "$HELPER" ]]; then
    echo "WARNING: $APP has no connector helper (Rust wasn't installed when it was built)."
    echo "         People on this build reach apps only through Claude Code. Install Rust (https://rustup.rs) and build again to include it."
    exit 0
  fi
  ARCHS_FOUND="$(lipo -archs "$HELPER" 2>/dev/null || true)"
  if [[ "$ARCHS_FOUND" != *arm64* || "$ARCHS_FOUND" != *x86_64* ]]; then
    echo "WARNING: the connector helper is only built for: ${ARCHS_FOUND:-unknown}. Macs of the other kind won't have Theo's own connectors."
  fi
  codesign --verify --strict "$HELPER"
  echo "Connector helper: $HELPER_NAME ($ARCHS_FOUND), signed."
  exit 0
fi

# MARK: Where it goes
if [[ $# -ge 1 ]]; then
  APP="$1"
  CONTENTS="$APP/Contents"
  WANT_UNIVERSAL="$([[ "${2:-}" == "universal" ]] && echo 1 || echo 0)"
  SIGNING_IDENTITY="${CONNECTORS_SIGNING_IDENTITY:-}"
  CARGO_TARGET="${CARGO_TARGET_DIR:-$CRATE_FOLDER/target}"
else
  : "${TARGET_BUILD_DIR:?run from Xcode, or pass the path to the .app}"
  CONTENTS="$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH"
  WANT_UNIVERSAL="$([[ "${CONFIGURATION:-Debug}" == "Release" ]] && echo 1 || echo 0)"
  SIGNING_IDENTITY=""
  if [[ "${CODE_SIGNING_ALLOWED:-YES}" != "NO" ]]; then SIGNING_IDENTITY="${EXPANDED_CODE_SIGN_IDENTITY:-}"; fi
  # Kept beside Xcode's own build files, so a second build only rebuilds what changed.
  CARGO_TARGET="${OBJROOT:-$CRATE_FOLDER/target}/theo-connectors-cargo"
fi
HELPERS="$CONTENTS/Helpers"

# MARK: Rust
# Xcode's scripts get a short PATH; rustup puts cargo in ~/.cargo/bin.
export PATH="$HOME/.cargo/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
if ! command -v cargo >/dev/null 2>&1; then
  warn "Rust isn't installed, so Theo is built without $HELPER_NAME. It reaches apps only through Claude Code. Install Rust from https://rustup.rs to include it."
  exit 0
fi

case "$(uname -m)" in
  arm64) THIS_MAC_TARGET="aarch64-apple-darwin" ;;
  *) THIS_MAC_TARGET="x86_64-apple-darwin" ;;
esac
TARGETS=("$THIS_MAC_TARGET")
PROFILE_FLAGS=()
PROFILE_FOLDER="debug"
if [[ "$WANT_UNIVERSAL" == "1" ]]; then
  TARGETS=("aarch64-apple-darwin" "x86_64-apple-darwin")
  PROFILE_FLAGS=("--release")
  PROFILE_FOLDER="release"
  if command -v rustup >/dev/null 2>&1; then
    for target in "${TARGETS[@]}"; do
      rustup target list --installed 2>/dev/null | grep -qx "$target" || rustup target add "$target" >/dev/null 2>&1 \
        || warn "couldn't add Rust's $target target."
    done
  fi
fi

# The Mac's own deployment target, so the helper runs everywhere Theo does.
export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-14.2}"
BUILT=()
for target in "${TARGETS[@]}"; do
  if (cd "$CRATE_FOLDER" && cargo build -p "$HELPER_NAME" --locked "${PROFILE_FLAGS[@]}" --target "$target" --target-dir "$CARGO_TARGET"); then
    BUILT+=("$CARGO_TARGET/$target/$PROFILE_FOLDER/$HELPER_NAME")
  else
    warn "building for $target failed. See the build log above."
  fi
done
if [[ ${#BUILT[@]} -eq 0 ]]; then
  warn "it couldn't be built, so Theo is built without it and reaches apps only through Claude Code."
  exit 0
fi

mkdir -p "$HELPERS"
if [[ ${#BUILT[@]} -gt 1 ]]; then
  lipo -create -output "$HELPERS/$HELPER_NAME" "${BUILT[@]}"
else
  [[ "$WANT_UNIVERSAL" == "1" ]] && warn "only ${TARGETS[0]} built; Macs of the other kind won't have Theo's own connectors."
  cp -f "${BUILT[0]}" "$HELPERS/$HELPER_NAME"
fi
chmod 755 "$HELPERS/$HELPER_NAME"

# MARK: Signing
# Signed before Xcode signs the app around it, with the same identity and the hardened runtime, so the app's own signature
# (and `codesign --verify --deep --strict` in release.sh) covers it. A build with signing off (the Mac CI) leaves it unsigned.
if [[ -n "$SIGNING_IDENTITY" ]]; then
  codesign --force --sign "$SIGNING_IDENTITY" --options runtime --timestamp=none \
    --identifier "com.personal.clicky.theo-connectors" "$HELPERS/$HELPER_NAME"
fi
echo "Connector helper: $HELPERS/$HELPER_NAME"
