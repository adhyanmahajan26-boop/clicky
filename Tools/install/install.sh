#!/bin/bash
# Theo installer for macOS: install, upgrade or uninstall Theo from Terminal.
#
#   curl -fsSL https://github.com/<releases repo>/releases/latest/download/install.sh | bash
#   curl -fsSL .../install.sh | bash -s -- --uninstall
#
# A download made by curl never gets macOS's quarantine flag, so Theo opens without the
# "Apple could not verify" dialog and no paid Apple Developer account is needed. In return,
# this script checks what it downloads instead: the zip's SHA-256 must match the release's
# checksum, and the app inside must have a valid signature from Theo's signing team with
# Theo's bundle id. Anything else is refused and nothing is changed.
#
# Options
#   --version <build>   install that build (202611121716 or build-202611121716); default: latest
#   --dir <folder>      install into this folder (default: /Applications, or ~/Applications
#                       when /Applications isn't writable without a password)
#   --from <zip|url>    install this zip instead of a release (needs --sha256)
#   --sha256 <hex>      the checksum the --from zip must have
#   --no-launch         don't open Theo afterwards
#   --force             reinstall the same build, allow an older build, or quit a Theo that won't quit
#   --uninstall         remove Theo (your chats, bots and settings are kept)
#   --purge             with --uninstall, also move Theo's data to the Trash and remove its
#                       settings, saved keys and macOS permissions
#   --yes               don't ask before --purge
#   -h, --help          show this help
#
# Environment
#   THEO_RELEASES_REPO  GitHub repo with the releases (owner/name)
#   THEO_INSTALL_DIR    same as --dir
#   THEO_GITHUB_TOKEN   token for a private releases repo (GH_TOKEN, GITHUB_TOKEN or a
#                       signed-in `gh` work too)
#
# The release layout this expects (Tools/release.sh makes it): tag build-<yyyyMMddHHmm>, one
# asset Theo-<build>.zip, and the checksum in a SHA256SUMS asset ("<hex>  Theo-<build>.zip")
# or, for older releases, a "sha256: <hex>" line in the release notes.
#
# Everything runs from main() at the very end, so a download cut off halfway runs nothing.

set -euo pipefail

RELEASES_REPO="${THEO_RELEASES_REPO:-adhyanmahajan26-boop/claudia-releases}"
GITHUB_API="${THEO_GITHUB_API:-https://api.github.com}"   # tests point this at a local fake
BUNDLE_ID="com.personal.clicky"
# Who must have signed Theo, as a code requirement (the language macOS uses for permissions).
# A zip whose app doesn't satisfy it is refused. Today: the Apple Development certificate of
# team 9JAQUUW553. With a self-signed certificate it would be
#   identifier "com.personal.clicky" and certificate leaf = H"<SHA-1 of the certificate>"
# (docs/INSTALL.md, "Signing options").
SIGNER_REQUIREMENT='identifier "com.personal.clicky" and anchor apple generic and certificate leaf[subject.OU] = "9JAQUUW553"'
SIGNER_REQUIREMENT="${THEO_SIGNER_REQUIREMENT:-$SIGNER_REQUIREMENT}"
APP_NAME="Theo.app"
EXECUTABLE="Clicky"
MIN_MACOS="14.2"

VERSION="latest"
INSTALL_DIR="${THEO_INSTALL_DIR:-}"
FROM=""
FROM_SHA=""
LAUNCH=1
FORCE=0
MODE="install"
PURGE=0
ASSUME_YES=0
WORK=""
AUTH_HEADER_FILE=""

say()  { printf '%s\n' "$*"; }
step() { printf '==> %s\n' "$*"; }
warn() { printf 'Warning: %s\n' "$*" >&2; }
die()  { printf 'Error: %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'HELP'
Theo installer for macOS.

  curl -fsSL <url>/install.sh | bash                      install or upgrade to the latest build
  curl -fsSL <url>/install.sh | bash -s -- --uninstall    remove Theo, keep its data

Options
  --version <build>   install that build (202611121716 or build-202611121716); default: latest
  --dir <folder>      install folder (default /Applications, or ~/Applications if that needs a password)
  --from <zip|url>    install this zip instead of a release (needs --sha256)
  --sha256 <hex>      the checksum the --from zip must have
  --no-launch         don't open Theo afterwards
  --force             reinstall the same build, allow an older one, or quit a Theo that won't quit
  --uninstall         remove Theo (chats, bots and settings are kept)
  --purge             with --uninstall: also remove Theo's data, saved keys and macOS permissions
  --yes               don't ask before --purge

Environment: THEO_RELEASES_REPO (owner/name), THEO_INSTALL_DIR, THEO_GITHUB_TOKEN (private repo).
HELP
}

cleanup() { [ -n "$WORK" ] && rm -rf "$WORK"; return 0; }

parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --version) [ $# -ge 2 ] || die "--version needs a build number"; VERSION="$2"; shift ;;
      --dir) [ $# -ge 2 ] || die "--dir needs a folder"; INSTALL_DIR="$2"; shift ;;
      --from) [ $# -ge 2 ] || die "--from needs a zip path or URL"; FROM="$2"; shift ;;
      --sha256) [ $# -ge 2 ] || die "--sha256 needs a checksum"; FROM_SHA="$2"; shift ;;
      --no-launch) LAUNCH=0 ;;
      --force) FORCE=1 ;;
      --uninstall) MODE="uninstall" ;;
      --purge) PURGE=1 ;;
      --yes|-y) ASSUME_YES=1 ;;
      -h|--help) usage; exit 0 ;;
      --print-signer-requirement) printf '%s\n' "$SIGNER_REQUIREMENT"; exit 0 ;;   # for release.sh
      *) die "unknown option: $1 (try --help)" ;;
    esac
    shift
  done
  if [ "$PURGE" = 1 ] && [ "$MODE" != "uninstall" ]; then die "--purge only goes with --uninstall"; fi
  if [ -n "$FROM" ] && [ -z "$FROM_SHA" ]; then die "--from needs --sha256, so the zip can be checked"; fi
  return 0
}

# ---------- checks ----------

version_at_least() { # $1 >= $2, dotted numbers
  local IFS=.
  local -a a=($1) b=($2)
  local i
  for i in 0 1 2; do
    local x="${a[$i]:-0}" y="${b[$i]:-0}"
    if [ "$x" -gt "$y" ]; then return 0; fi
    if [ "$x" -lt "$y" ]; then return 1; fi
  done
  return 0
}

check_system() {
  if [ "$(uname -s)" != "Darwin" ]; then
    die "this installer is for macOS. Theo for Windows and Linux has its own installer."
  fi
  local os; os="$(sw_vers -productVersion)"
  version_at_least "$os" "$MIN_MACOS" || die "Theo needs macOS $MIN_MACOS or newer (this Mac has $os)."
  local tool
  for tool in curl shasum ditto codesign xattr osascript; do
    command -v "$tool" >/dev/null 2>&1 || die "missing $tool"
  done
}

# ---------- GitHub ----------

github_token() {
  if [ -n "${THEO_GITHUB_TOKEN:-}" ]; then printf '%s' "$THEO_GITHUB_TOKEN"; return; fi
  if [ -n "${GH_TOKEN:-}" ]; then printf '%s' "$GH_TOKEN"; return; fi
  if [ -n "${GITHUB_TOKEN:-}" ]; then printf '%s' "$GITHUB_TOKEN"; return; fi
  if command -v gh >/dev/null 2>&1; then gh auth token --hostname github.com 2>/dev/null || true; fi
}

# The token goes in a header file (mode 600), never on curl's command line where `ps` shows it.
prepare_auth() {
  local token; token="$(github_token)"
  [ -n "$token" ] || return 0
  AUTH_HEADER_FILE="$WORK/auth-header"
  (umask 077; printf 'Authorization: Bearer %s\n' "$token" > "$AUTH_HEADER_FILE")
}

curl_github() { # url out-file [accept]
  local url="$1" out="$2" accept="${3:-application/vnd.github+json}"
  local -a args=(-fsSL --retry 3 --retry-delay 2 --connect-timeout 20 -H "Accept: $accept" -o "$out")
  if [ -n "$AUTH_HEADER_FILE" ]; then args+=(-H "@$AUTH_HEADER_FILE"); fi
  curl "${args[@]}" "$url"
}

# Reads the release JSON with JavaScript for Automation (built into every Mac, no jq or Python needed)
# and prints: tag, zip name, zip download URL, zip API URL, SHA256SUMS download URL, SHA256SUMS API URL,
# and the "sha256:" line from the notes, one per line ("-" when missing).
release_fields() {
  osascript -l JavaScript - "$1" <<'JXA'
ObjC.import('Foundation');
function run(argv) {
  var text = $.NSString.stringWithContentsOfFileEncodingError(argv[0], $.NSUTF8StringEncoding, null).js;
  var r = JSON.parse(text);
  var assets = r.assets || [];
  var zip = assets.filter(function (a) { return /^Theo-.*\.zip$/i.test(a.name) && !/(windows|linux)/i.test(a.name); })[0]
         || assets.filter(function (a) { return /\.zip$/i.test(a.name); })[0];
  var sums = assets.filter(function (a) { return a.name === 'SHA256SUMS'; })[0];
  var line = ((r.body || '').split(/\r?\n/).filter(function (l) { return /^\s*sha256:/i.test(l); })[0] || '');
  var noteSha = line.replace(/^\s*sha256:\s*/i, '').trim();
  return [r.tag_name || '-', zip ? zip.name : '-', zip ? zip.browser_download_url : '-', zip ? zip.url : '-',
          sums ? sums.browser_download_url : '-', sums ? sums.url : '-', noteSha || '-'].join('\n');
}
JXA
}

# Downloads a release asset: the API URL with a token (private repo), the public URL without one.
download_asset() { # public-url api-url out
  if [ -n "$AUTH_HEADER_FILE" ] && [ "$2" != "-" ]; then
    curl_github "$2" "$3" "application/octet-stream"
  else
    curl -fL --retry 3 --retry-delay 2 --connect-timeout 20 --progress-bar -o "$3" "$1"
  fi
}

# Sets ZIP and EXPECTED_SHA.
fetch_release() {
  prepare_auth
  local api="$GITHUB_API/repos/$RELEASES_REPO/releases"
  local url
  if [ "$VERSION" = "latest" ]; then url="$api/latest"
  else
    local tag="$VERSION"; case "$tag" in build-*) ;; *) tag="build-$tag" ;; esac
    url="$api/tags/$tag"
  fi
  step "Finding Theo ($VERSION) in $RELEASES_REPO"
  if ! curl_github "$url" "$WORK/release.json"; then
    if [ -z "$AUTH_HEADER_FILE" ]; then
      die "couldn't read $RELEASES_REPO. If it's private, sign in with \`gh auth login\` or set THEO_GITHUB_TOKEN."
    fi
    die "couldn't read $url (no such release, or the token can't see the repo)."
  fi
  local fields; fields="$(release_fields "$WORK/release.json")" || die "couldn't read the release details"
  local tag zip_name zip_url zip_api sums_url sums_api note_sha
  { read -r tag; read -r zip_name; read -r zip_url; read -r zip_api; read -r sums_url; read -r sums_api; read -r note_sha; } <<EOF
$fields
EOF
  [ "$zip_name" != "-" ] || die "release $tag has no Theo zip"
  if [ "$sums_url" != "-" ]; then
    download_asset "$sums_url" "$sums_api" "$WORK/SHA256SUMS" || die "couldn't download SHA256SUMS"
    EXPECTED_SHA="$(awk -v n="$zip_name" '{ f=$2; sub(/^\*/, "", f); if (f == n) { print $1; exit } }' "$WORK/SHA256SUMS")"
  else
    EXPECTED_SHA="$note_sha"
  fi
  [ -n "$EXPECTED_SHA" ] && [ "$EXPECTED_SHA" != "-" ] || die "release $tag has no checksum for $zip_name, so it can't be checked"
  step "Downloading $zip_name ($tag)"
  ZIP="$WORK/$zip_name"
  download_asset "$zip_url" "$zip_api" "$ZIP" || die "the download failed"
}

fetch_from() {
  EXPECTED_SHA="$FROM_SHA"
  ZIP="$WORK/Theo.zip"
  case "$FROM" in
    http://*|https://*) step "Downloading $FROM"; curl -fL --retry 3 --progress-bar -o "$ZIP" "$FROM" || die "the download failed" ;;
    *) [ -f "$FROM" ] || die "no such file: $FROM"; cp "$FROM" "$ZIP" ;;
  esac
}

verify_checksum() {
  local actual expected
  actual="$(shasum -a 256 "$ZIP" | awk '{print $1}')"
  expected="$(printf '%s' "$EXPECTED_SHA" | tr 'A-F' 'a-f')"
  [ "$actual" = "$expected" ] || die "the download doesn't match its checksum (expected $expected, got $actual). Nothing was installed."
  step "Checksum OK ($actual)"
}

signer_of() { # "team X", "certificate <sha1>" or "ad hoc"
  local info; info="$(codesign -dvv "$1" 2>&1)"
  case "$info" in *"Signature=adhoc"*) echo "ad hoc"; return ;; esac
  local team; team="$(printf '%s\n' "$info" | sed -n 's/^TeamIdentifier=//p')"
  if [ -n "$team" ] && [ "$team" != "not set" ]; then echo "team $team"; return; fi
  codesign -d -r- "$1" 2>&1 | sed -n 's/.*certificate leaf = H"\([0-9a-f]*\)".*/certificate \1/p' | grep . || echo "unknown signer"
}
bundle_id_of() { /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$1/Contents/Info.plist" 2>/dev/null || true; }
build_of() { /usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$1/Contents/Info.plist" 2>/dev/null || echo 0; }

# Unzips into the work folder and checks the app is Theo, signed by Theo's team. Sets NEW_APP.
unpack_and_verify() {
  mkdir -p "$WORK/unpacked"
  ditto -x -k "$ZIP" "$WORK/unpacked" || die "couldn't unzip the download"
  NEW_APP="$(find "$WORK/unpacked" -maxdepth 2 -name '*.app' -type d | head -n 1)"
  [ -n "$NEW_APP" ] || die "the zip has no app in it"
  # curl never adds quarantine; a zip given with --from may have been downloaded by a browser.
  xattr -dr com.apple.quarantine "$NEW_APP" 2>/dev/null || true
  codesign --verify --deep --strict "$NEW_APP" 2>/dev/null || die "the app's signature isn't valid. Nothing was installed."
  [ "$(bundle_id_of "$NEW_APP")" = "$BUNDLE_ID" ] || die "the zip doesn't contain Theo. Nothing was installed."
  if ! codesign --verify -R "=$SIGNER_REQUIREMENT" "$NEW_APP" 2>/dev/null; then
    die "the app is signed by '$(signer_of "$NEW_APP")', not Theo's signing identity. Nothing was installed."
  fi
  step "Signature OK ($(signer_of "$NEW_APP"), build $(build_of "$NEW_APP"))"
}

# ---------- install ----------

choose_dir() {
  if [ -n "$INSTALL_DIR" ]; then mkdir -p "$INSTALL_DIR" || die "can't create $INSTALL_DIR"; return; fi
  if [ -w /Applications ]; then INSTALL_DIR="/Applications"
  else
    INSTALL_DIR="$HOME/Applications"; mkdir -p "$INSTALL_DIR"
    say "    /Applications needs an administrator password here, so Theo goes in ~/Applications."
  fi
}

# Process ids of Theo running from this exact app (any profile).
running_pids() { # app path; the app's own processes, never a `Clicky --mcp` helper
  local exe="$1/Contents/MacOS/$EXECUTABLE" pid
  # Claude Code (Theo's plugin), T3 Code and OpenCode run `Clicky --mcp` from the installed app as their MCP server.
  # Quitting one would cut another session's tools; it keeps running from the old copy and starts the new one next time.
  ps -axo pid=,comm= | awk -v exe="$exe" '{ pid=$1; $1=""; sub(/^ /, ""); if ($0 == exe) print pid }' | while read -r pid; do
    case " $(ps -o args= -p "$pid" 2>/dev/null) " in
      *" --mcp "*) ;;
      *) echo "$pid" ;;
    esac
  done
}

quit_running() { # app path; returns 0 if Theo was running
  local pids; pids="$(running_pids "$1")"
  [ -n "$pids" ] || return 1
  step "Quitting the running Theo"
  # SIGTERM lets Theo save and end its engines; it resumes unanswered messages on the next launch.
  kill -TERM $pids 2>/dev/null || true
  local i
  for i in $(seq 1 60); do
    [ -z "$(running_pids "$1")" ] && return 0
    sleep 0.25
  done
  if [ "$FORCE" = 1 ]; then kill -KILL $(running_pids "$1") 2>/dev/null || true; sleep 1; return 0; fi
  die "Theo didn't quit within 15 seconds. Quit it from the menu bar and run this again (or add --force)."
}

do_install() {
  WORK="$(mktemp -d -t theo-install)"
  trap cleanup EXIT
  if [ -n "$FROM" ]; then fetch_from; else fetch_release; fi
  verify_checksum
  unpack_and_verify

  choose_dir
  local dest="$INSTALL_DIR/$APP_NAME"
  local new_build; new_build="$(build_of "$NEW_APP")"
  local was_running=0 upgrading=0
  if [ -e "$dest" ]; then
    [ "$(bundle_id_of "$dest")" = "$BUNDLE_ID" ] || die "$dest exists and isn't Theo; move it away first."
    local old_build; old_build="$(build_of "$dest")"
    if [ "$old_build" = "$new_build" ] && [ "$FORCE" = 0 ]; then
      say "Theo build $new_build is already installed at $dest."
      exit 0
    fi
    if [ "$new_build" -lt "$old_build" ] 2>/dev/null && [ "$FORCE" = 0 ]; then
      die "$dest has build $old_build, newer than $new_build. Add --force to go back."
    fi
    upgrading=1
    step "Upgrading Theo $old_build -> $new_build in $INSTALL_DIR"
    if quit_running "$dest"; then was_running=1; fi
  else
    step "Installing Theo $new_build in $INSTALL_DIR"
  fi

  # Copy beside the destination first, then two renames, so a failure never leaves Theo half-replaced.
  local staging="$INSTALL_DIR/.Theo.app.installing-$$" old="$INSTALL_DIR/.Theo.app.previous-$$"
  rm -rf "$staging" "$old"
  ditto "$NEW_APP" "$staging" || { rm -rf "$staging"; die "couldn't copy Theo into $INSTALL_DIR"; }
  if [ -e "$dest" ]; then mv "$dest" "$old" || { rm -rf "$staging"; die "couldn't move the old Theo aside"; }; fi
  if ! mv "$staging" "$dest"; then
    [ -e "$old" ] && mv "$old" "$dest"
    rm -rf "$staging"
    die "couldn't put Theo in place; the previous version was restored."
  fi
  rm -rf "$old"
  codesign --verify --deep --strict "$dest" 2>/dev/null || die "the installed copy failed its signature check: $dest"
  xattr -dr com.apple.quarantine "$dest" 2>/dev/null || true

  say ""
  say "Theo build $new_build is installed: $dest"
  if [ "$upgrading" = 1 ]; then
    say "Your chats, bots, settings and macOS permissions carry over (same signature as before)."
  else
    say ""
    say "First launch: Theo's Setup guide walks you through the brain, the voice and permissions."
    say "macOS asks for three permissions. They may be listed under the name \"Clicky\":"
    say "  - Microphone: a normal Allow box."
    say "  - Accessibility and Screen & System Audio Recording: macOS opens System Settings >"
    say "    Privacy & Security; switch Theo on there. Screen recording takes effect after Theo restarts."
    say "Updates keep these permissions, whether from Theo's own Update button or this script."
  fi
  say "To update later, run the same command again. To remove: add --uninstall (or --uninstall --purge)."

  if [ "$LAUNCH" = 1 ] && { [ "$upgrading" = 0 ] || [ "$was_running" = 1 ]; }; then
    open "$dest" || warn "couldn't open $dest"
  fi
}

# ---------- uninstall ----------

confirm() { # prompt
  [ "$ASSUME_YES" = 1 ] && return 0
  local answer=""
  # With `curl ... | bash`, stdin is the script itself, so ask on the terminal.
  if [ -r /dev/tty ]; then printf '%s [y/N] ' "$1" > /dev/tty; read -r answer < /dev/tty || true
  else die "can't ask for confirmation here; add --yes"; fi
  case "$answer" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}

move_to_trash() { # path label
  local trash="$HOME/.Trash/$2"
  mkdir -p "$HOME/.Trash"
  [ -e "$trash" ] && trash="$trash-$$"
  mv "$1" "$trash"
  say "    moved to the Trash: $1"
}

do_uninstall() {
  local -a found=()
  local candidate
  if [ -n "$INSTALL_DIR" ]; then set -- "$INSTALL_DIR/$APP_NAME"; else set -- "/Applications/$APP_NAME" "$HOME/Applications/$APP_NAME"; fi
  for candidate in "$@"; do
    if [ -d "$candidate" ] && [ "$(bundle_id_of "$candidate")" = "$BUNDLE_ID" ]; then found+=("$candidate"); fi
  done

  if [ "$PURGE" = 1 ]; then
    say "This removes Theo and moves its chats, bots, notes and settings to the Trash, and deletes its saved"
    say "keys (Keychain) and its macOS permissions. Screenshots in ~/Pictures/Clicky are kept."
    confirm "Remove Theo and all of its data?" || die "nothing was removed"
  fi

  local stamp; stamp="$(date +%Y%m%d-%H%M%S)"
  if [ ${#found[@]} -eq 0 ]; then
    say "Theo isn't installed${INSTALL_DIR:+ in $INSTALL_DIR}."
  else
    for candidate in "${found[@]}"; do
      quit_running "$candidate" || true
      step "Removing $candidate"
      move_to_trash "$candidate" "Theo-$stamp.app"
    done
  fi

  if [ "$PURGE" = 1 ]; then
    step "Removing Theo's data"
    local path
    for path in "$HOME/Library/Application Support/Theo" "$HOME/Library/Application Support/Clicky" \
                "$HOME/.clicky" "$HOME/Library/Logs/Clicky" "$HOME/Library/Caches/$BUNDLE_ID" \
                "$HOME/Library/HTTPStorages/$BUNDLE_ID"; do
      if [ -e "$path" ]; then mkdir -p "$HOME/.Trash/Theo-data-$stamp"; move_to_trash "$path" "Theo-data-$stamp/$(basename "$path")"; fi
    done
    # Test runs set THEO_UNINSTALL_SKIP_SYSTEM=1: these three act on the real user account, whatever $HOME is.
    if [ "${THEO_UNINSTALL_SKIP_SYSTEM:-0}" != 1 ]; then
      defaults delete "$BUNDLE_ID" >/dev/null 2>&1 && say "    removed its settings" || true
      local service
      for service in "$BUNDLE_ID.secrets" com.theo.providers com.theo.gateway; do
        while security delete-generic-password -s "$service" >/dev/null 2>&1; do :; done
      done
      say "    removed its saved keys"
      tccutil reset All "$BUNDLE_ID" >/dev/null 2>&1 && say "    reset its macOS permissions" || true
    fi
  elif [ ${#found[@]} -gt 0 ]; then
    say "Your chats, bots and settings are kept in ~/Library/Application Support/Theo."
    say "Reinstalling brings everything back. To remove them too: --uninstall --purge"
  fi
  say "Done."
}

main() {
  parse_args "$@"
  check_system
  if [ "$MODE" = "uninstall" ]; then do_uninstall; else do_install; fi
}

main "$@"
