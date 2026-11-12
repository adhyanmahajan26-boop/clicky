#!/usr/bin/env bash
# Theo for Linux: install, update or remove, from a GitHub release.
#
#   curl -fsSL https://github.com/<owner>/<repo>/releases/latest/download/install-linux.sh | bash
#
# Installs the AppImage to ~/.local/opt/theo, links ~/.local/bin/theo, and adds Theo to the app menu. No root needed.
# The whole script runs from main() at the very end, so a download cut short runs nothing.

set -euo pipefail

REPO="${THEO_RELEASES_REPO:-adhyanmahajan26-boop/claudia-releases}"
API="${THEO_GITHUB_API:-https://api.github.com}"
INSTALL_DIR="${THEO_INSTALL_DIR:-$HOME/.local/opt/theo}"
BIN_DIR="$HOME/.local/bin"
APPS_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
DATA_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/theo-desktop"

usage() {
  cat <<'USAGE'
Theo for Linux installer

  install-linux.sh [options]

  --version <build>    install this build (build-202611130300 or 202611130300); default: the latest release
  --dir <folder>       install here instead of ~/.local/opt/theo (also THEO_INSTALL_DIR)
  --from <file|url>    install this AppImage instead of downloading from the release; needs --sha256
  --sha256 <hex>       the checksum --from must match
  --no-launch          don't open Theo afterwards
  --force              reinstall even if this build is already installed
  --uninstall          remove Theo, keep its data (chats, bots, memory)
  --purge              remove Theo and its data (asks first; --yes to skip the question)
  --yes                answer yes to --purge's question
  --help               this text

Environment: THEO_RELEASES_REPO (owner/repo), THEO_INSTALL_DIR, THEO_GITHUB_TOKEN (for a private releases repo; falls back to
GH_TOKEN, GITHUB_TOKEN, then `gh auth token`; sent in a header file, never on the command line), THEO_GITHUB_API.
USAGE
}

say() { printf '%s\n' "$*"; }
die() { printf 'theo install: %s\n' "$*" >&2; exit 1; }

TMP=""
cleanup() { [ -n "$TMP" ] && rm -rf "$TMP"; }

token() {
  local t="${THEO_GITHUB_TOKEN:-${GH_TOKEN:-${GITHUB_TOKEN:-}}}"
  if [ -z "$t" ] && command -v gh >/dev/null 2>&1; then t="$(gh auth token 2>/dev/null || true)"; fi
  printf '%s' "$t"
}

# curl with the token in a header file (never in argv, where other users could see it with ps).
gh_curl() {
  local headers="$TMP/headers"
  : > "$headers"; chmod 600 "$headers"
  local t; t="$(token)"
  [ -n "$t" ] && printf 'Authorization: Bearer %s\n' "$t" >> "$headers"
  curl -fsSL --retry 3 -H @"$headers" "$@"
}

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

json_get() { python3 -c "$1" 2>/dev/null; }

arch_name() {
  case "$(uname -m)" in
    x86_64|amd64) echo "x86_64" ;;
    aarch64|arm64) echo "aarch64" ;;
    *) die "this computer's processor ($(uname -m)) has no Theo build yet" ;;
  esac
}

installed_build() { cat "$INSTALL_DIR/BUILD" 2>/dev/null || true; }

uninstall() {
  # Only what install_file put there: a --dir or THEO_INSTALL_DIR that also holds other things (say --dir ~/Apps) keeps them,
  # and a `theo` command or menu entry that isn't this install's is left alone.
  if [ -L "$BIN_DIR/theo" ] && [ "$(readlink "$BIN_DIR/theo")" = "$INSTALL_DIR/Theo.AppImage" ]; then rm -f "$BIN_DIR/theo"; fi
  if [ -f "$APPS_DIR/theo.desktop" ] && grep -qxF "Exec=$INSTALL_DIR/Theo.AppImage" "$APPS_DIR/theo.desktop"; then rm -f "$APPS_DIR/theo.desktop"; fi
  rm -f "$INSTALL_DIR/Theo.AppImage" "$INSTALL_DIR/Theo.AppImage.new" "$INSTALL_DIR/BUILD"
  rmdir "$INSTALL_DIR" 2>/dev/null || true
  say "Theo is removed. Its data is still in $DATA_DIR."
}

purge() {
  local yes="$1"
  if [ "$yes" != 1 ]; then
    if [ -t 0 ] || [ -e /dev/tty ]; then
      printf 'This deletes Theo and all its data in %s (bots, chats, memory). Type yes to go on: ' "$DATA_DIR"
      local answer=""; read -r answer < /dev/tty || true
      [ "$answer" = "yes" ] || die "nothing was deleted"
    else
      die "--purge needs --yes when there's nobody to ask"
    fi
  fi
  uninstall
  rm -rf "$DATA_DIR"
  say "Theo's data is deleted too."
}

install_file() {
  local file="$1" build="$2"
  mkdir -p "$INSTALL_DIR" "$BIN_DIR" "$APPS_DIR"
  install -m 755 "$file" "$INSTALL_DIR/Theo.AppImage.new"
  mv -f "$INSTALL_DIR/Theo.AppImage.new" "$INSTALL_DIR/Theo.AppImage"
  printf '%s\n' "$build" > "$INSTALL_DIR/BUILD"
  ln -sf "$INSTALL_DIR/Theo.AppImage" "$BIN_DIR/theo"
  cat > "$APPS_DIR/theo.desktop" <<DESKTOP
[Desktop Entry]
Type=Application
Name=Theo
Comment=Your team of bots
Exec=$INSTALL_DIR/Theo.AppImage
Terminal=false
Categories=Office;Utility;
DESKTOP
  say "Theo $build is installed in $INSTALL_DIR (run it with: theo)."
  case ":$PATH:" in *":$BIN_DIR:"*) ;; *) say "Add $BIN_DIR to your PATH to run 'theo' from a terminal." ;; esac
  if ! ldconfig -p 2>/dev/null | grep -q libfuse.so.2; then
    say "Note: AppImages need FUSE 2 (Ubuntu: sudo apt install libfuse2t64, or libfuse2 on older releases)."
  fi
}

main() {
  local version="" from="" sha="" launch=1 force=0 action=install yes=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --version) version="${2:-}"; shift 2 ;;
      --dir) INSTALL_DIR="${2:-}"; shift 2 ;;
      --from) from="${2:-}"; shift 2 ;;
      --sha256) sha="${2:-}"; shift 2 ;;
      --no-launch) launch=0; shift ;;
      --force) force=1; shift ;;
      --uninstall) action=uninstall; shift ;;
      --purge) action=purge; shift ;;
      --yes|-y) yes=1; shift ;;
      --help|-h) usage; exit 0 ;;
      *) die "unknown option $1 (see --help)" ;;
    esac
  done
  [ "$(uname -s)" = "Linux" ] || [ "${THEO_INSTALL_ANY_OS:-}" = 1 ] || die "this installer is for Linux; on a Mac use install.sh, on Windows install.ps1"
  case "$action" in
    uninstall) uninstall; exit 0 ;;
    purge) purge "$yes"; exit 0 ;;
  esac
  command -v curl >/dev/null || die "needs curl"
  TMP="$(mktemp -d)"; trap cleanup EXIT

  if [ -n "$from" ]; then
    [ -n "$sha" ] || die "--from needs --sha256"
    local file="$TMP/Theo.AppImage"
    case "$from" in
      http://*|https://*) curl -fsSL --retry 3 -o "$file" "$from" ;;
      *) cp "$from" "$file" ;;
    esac
    [ "$(sha256_of "$file")" = "$sha" ] || die "checksum mismatch: refusing to install $from"
    install_file "$file" "local"
  else
    command -v python3 >/dev/null || die "needs python3 to read the release list"
    local arch; arch="$(arch_name)"
    local url="$API/repos/$REPO/releases/latest"
    if [ -n "$version" ]; then url="$API/repos/$REPO/releases/tags/build-${version#build-}"; fi
    gh_curl -H "Accept: application/vnd.github+json" -o "$TMP/release.json" "$url" || die "couldn't read the release (is $REPO reachable, and is THEO_GITHUB_TOKEN set for a private repo?)"
    local build; build="$(json_get "import json;print(json.load(open('$TMP/release.json'))['tag_name'].replace('build-',''))")"
    [ -n "$build" ] || die "the release has no build number"
    if [ "$force" != 1 ] && [ "$(installed_build)" = "$build" ]; then say "Theo $build is already installed (--force reinstalls)."; exit 0; fi
    local pick="import json,sys
r=json.load(open('$TMP/release.json'))
want=sys.argv[1]
for a in r.get('assets',[]):
    if a['name']==want or (want=='*' and a['name'].endswith('-linux-$arch.AppImage')): print(a['name']+' '+a['url']); break"
    local app sums
    app="$(python3 -c "$pick" '*')"; [ -n "$app" ] || die "build $build has no Linux $arch AppImage"
    sums="$(python3 -c "$pick" SHA256SUMS)"; [ -n "$sums" ] || die "build $build has no SHA256SUMS: refusing to install"
    gh_curl -H "Accept: application/octet-stream" -o "$TMP/Theo.AppImage" "${app#* }"
    gh_curl -H "Accept: application/octet-stream" -o "$TMP/SHA256SUMS" "${sums#* }"
    local expected; expected="$(awk -v n="${app%% *}" '$2==n {print $1}' "$TMP/SHA256SUMS")"
    [ -n "$expected" ] || die "SHA256SUMS doesn't list ${app%% *}: refusing to install"
    [ "$(sha256_of "$TMP/Theo.AppImage")" = "$expected" ] || die "checksum mismatch for ${app%% *}: refusing to install"
    install_file "$TMP/Theo.AppImage" "$build"
  fi
  if [ "$launch" = 1 ] && [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]; then
    (nohup "$INSTALL_DIR/Theo.AppImage" >/dev/null 2>&1 &) || true
  fi
}

main "$@"
