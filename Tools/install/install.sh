#!/bin/bash
# Theo installer for macOS: install, upgrade or uninstall Theo from Terminal.
#
#   curl -fsSL https://github.com/<releases repo>/releases/latest/download/install.sh | bash
#   curl -fsSL .../install.sh | bash -s -- --uninstall
#
# A download made by curl never gets macOS's quarantine flag, so Theo opens without the
# "Apple could not verify" dialog and no paid Apple Developer account is needed. In return,
# this script checks what it downloads instead: the zip's SHA-256 must match the release's
# checksum, and the app inside must have a valid signature from Theo's signer with Theo's
# bundle id. When Theo is already installed, the new app must also satisfy the installed app's
# own signature rule, so an upgrade can never swap in someone else's build and macOS keeps
# Theo's permissions. Anything else is refused and nothing is changed.
#
# Who Theo's signer is (the "signer rule", a code requirement), first one found:
#   1. THEO_SIGNER_REQUIREMENT, if you set it;
#   2. the rule Tools/release.sh wrote into this copy of the script when it published it;
#   3. the release's SIGNER file, only when the release's SHA256SUMS lists it and it matches;
#   4. when upgrading, the installed Theo's own rule.
# A rule must pin Theo's bundle id and one Apple team or one certificate (the two forms in
# docs/INSTALL.md, "Signing"); anything looser is refused. Nobody's team is written in the
# script in the repo: a copy run from a checkout reads the release's SIGNER file.
#
# Options
#   --version <build>   install that build (202611121716 or build-202611121716); default: latest
#   --dir <folder>      install into this folder (default: /Applications, or ~/Applications
#                       when /Applications isn't writable without a password)
#   --from <zip|url>    install this zip instead of a release (needs --sha256)
#   --sha256 <hex>      the checksum the --from zip must have
#   --no-launch         don't open Theo afterwards
#   --force             reinstall the same build, allow an older build, or quit a Theo that won't quit
#   --allow-new-signer  upgrade even though the new build has another signer than the installed
#                       Theo (macOS then asks for every permission again)
#   --uninstall         remove Theo (your chats, bots and settings are kept)
#   --purge             with --uninstall, also move Theo's data to the Trash and remove its
#                       settings, saved keys and macOS permissions
#   --yes               don't ask before --purge
#   -h, --help          show this help
#
# Environment
#   THEO_RELEASES_REPO  GitHub repo with the releases (owner/name). Default: the repo this copy
#                       was published to, or THEO_RELEASES_REPO in Config/Theo.xcconfig when the
#                       script runs from a checkout of Theo's source
#   THEO_INSTALL_DIR    same as --dir
#   THEO_GITHUB_TOKEN   only for a private releases repo: a token that can read it (GH_TOKEN,
#                       GITHUB_TOKEN or a signed-in `gh` work too). A public repo needs nothing.
#   THEO_SIGNER_REQUIREMENT  the signer rule to use (see above)
#
# The release layout this expects (Tools/release.sh makes it): tag build-<yyyyMMddHHmm>, one
# asset Theo-<build>.zip, the checksum in a SHA256SUMS asset ("<hex>  Theo-<build>.zip") or,
# for older releases, a "sha256: <hex>" line in the release notes, and a SIGNER asset with the
# signer rule (listed in SHA256SUMS).
#
# Everything runs from main() at the very end, so a download cut off halfway runs nothing.

set -euo pipefail

# Tools/release.sh fills these two in, in the copy of this script it publishes with a release
# (Tools/install/stamp-installer.py). They stay empty in the repo.
PUBLISHED_RELEASES_REPO=""
PUBLISHED_SIGNER_REQUIREMENT=''

RELEASES_REPO="${THEO_RELEASES_REPO:-}"
GITHUB_API="${THEO_GITHUB_API:-https://api.github.com}"   # tests point this at a local fake
BUNDLE_ID="com.personal.clicky"
# Who must have signed Theo, as a code requirement (the language macOS uses for permissions).
# Chosen in choose_signer_rule (see the top of this file); a zip whose app doesn't satisfy it is refused.
SIGNER_REQUIREMENT=""
SIGNER_SOURCE=""
RELEASE_SIGNER_FILE=""
APP_NAME="Theo.app"
EXECUTABLE="Clicky"
MIN_MACOS="14.2"

VERSION="latest"
INSTALL_DIR="${THEO_INSTALL_DIR:-}"
FROM=""
FROM_SHA=""
LAUNCH=1
FORCE=0
ALLOW_NEW_SIGNER=0
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
  --allow-new-signer  upgrade to a build from another signer (macOS asks for permissions again)
  --uninstall         remove Theo (chats, bots and settings are kept)
  --purge             with --uninstall: also remove Theo's data, saved keys and macOS permissions
  --yes               don't ask before --purge

Environment: THEO_RELEASES_REPO (owner/name), THEO_INSTALL_DIR, THEO_GITHUB_TOKEN (only for a private
repo), THEO_SIGNER_REQUIREMENT.
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
      --allow-new-signer) ALLOW_NEW_SIGNER=1 ;;
      --uninstall) MODE="uninstall" ;;
      --purge) PURGE=1 ;;
      --yes|-y) ASSUME_YES=1 ;;
      -h|--help) usage; exit 0 ;;
      *) die "unknown option: $1 (try --help)" ;;
    esac
    shift
  done
  if [ "$PURGE" = 1 ] && [ "$MODE" != "uninstall" ]; then die "--purge only goes with --uninstall"; fi
  if [ -n "$FROM" ] && [ -z "$FROM_SHA" ]; then die "--from needs --sha256, so the zip can be checked"; fi
  return 0
}

# THEO_RELEASES_REPO in Config/Theo.xcconfig, when this script runs from a checkout of Theo's source
# (Tools/install/install.sh). Nothing when it was piped from curl.
checkout_releases_repo() {
  local script_path="${BASH_SOURCE[0]:-}"
  [ -n "$script_path" ] && [ -f "$script_path" ] || return 0
  local config; config="$(cd "$(dirname "$script_path")/../.." 2>/dev/null && pwd)/Config/Theo.xcconfig"
  [ -f "$config" ] || return 0
  sed -n 's/^[[:space:]]*THEO_RELEASES_REPO[[:space:]]*=[[:space:]]*\([^[:space:]]*\).*/\1/p' "$config" | head -n 1
}

choose_releases_repo() {
  [ -n "$RELEASES_REPO" ] || RELEASES_REPO="$PUBLISHED_RELEASES_REPO"
  [ -n "$RELEASES_REPO" ] || RELEASES_REPO="$(checkout_releases_repo)"
  [ -n "$RELEASES_REPO" ] || die "this copy of the installer doesn't say where Theo's releases are. Set THEO_RELEASES_REPO=<owner>/<repo>, or use the install.sh attached to a release."
  case "$RELEASES_REPO" in
    */*/*|/*|*/) die "THEO_RELEASES_REPO must look like owner/name (got '$RELEASES_REPO')" ;;
    */*) ;;
    *) die "THEO_RELEASES_REPO must look like owner/name (got '$RELEASES_REPO')" ;;
  esac
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

# Reads one GitHub API URL into a file and prints the HTTP status (000 when GitHub couldn't be reached).
github_status() { # url out-file
  local -a args=(-sSL --retry 3 --retry-delay 2 --connect-timeout 20 -H "Accept: application/vnd.github+json" -o "$2" -w '%{http_code}')
  if [ -n "$AUTH_HEADER_FILE" ]; then args+=(-H "@$AUTH_HEADER_FILE"); fi
  curl "${args[@]}" "$1" 2>/dev/null || true
}

# Says plainly why the release couldn't be read. GitHub answers 404 for a private repo it won't show,
# so without a token that is what the person is told, not a sign-in step they may have no way to do.
explain_release_failure() { # http status, url
  case "$1" in
    404)
      if [ -z "$AUTH_HEADER_FILE" ]; then
        die "this build's updates are private: $RELEASES_REPO can't be read without access. Ask whoever gave you Theo for a new installer. (If you do have access to that repo, set THEO_GITHUB_TOKEN to a token that can read it.)"
      fi
      die "couldn't read $2: no such release in $RELEASES_REPO, or the GitHub token can't read that repo." ;;
    401) die "GitHub refused the token (THEO_GITHUB_TOKEN, GH_TOKEN, GITHUB_TOKEN or gh's). A public releases repo needs no token: unset it and try again." ;;
    403|429) die "GitHub is limiting requests from this network right now. Try again in a while." ;;
    000|"") die "couldn't reach GitHub ($GITHUB_API). Check the internet connection and try again." ;;
    *) die "GitHub answered $1 for $2." ;;
  esac
}

# Reads the release JSON with JavaScript for Automation (built into every Mac, no jq or Python needed)
# and prints: tag, zip name, zip download URL, zip API URL, SHA256SUMS download URL, SHA256SUMS API URL,
# the "sha256:" line from the notes, SIGNER download URL and SIGNER API URL, one per line ("-" when missing).
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
  var signer = assets.filter(function (a) { return a.name === 'SIGNER'; })[0];
  var line = ((r.body || '').split(/\r?\n/).filter(function (l) { return /^\s*sha256:/i.test(l); })[0] || '');
  var noteSha = line.replace(/^\s*sha256:\s*/i, '').trim();
  return [r.tag_name || '-', zip ? zip.name : '-', zip ? zip.browser_download_url : '-', zip ? zip.url : '-',
          sums ? sums.browser_download_url : '-', sums ? sums.url : '-', noteSha || '-',
          signer ? signer.browser_download_url : '-', signer ? signer.url : '-'].join('\n');
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
  local status; status="$(github_status "$url" "$WORK/release.json")"
  [ "$status" = 200 ] || explain_release_failure "$status" "$url"
  local fields; fields="$(release_fields "$WORK/release.json")" || die "couldn't read the release details"
  local tag zip_name zip_url zip_api sums_url sums_api note_sha signer_url signer_api
  { read -r tag; read -r zip_name; read -r zip_url; read -r zip_api; read -r sums_url; read -r sums_api; read -r note_sha
    read -r signer_url; read -r signer_api; } <<EOF
$fields
EOF
  [ "$zip_name" != "-" ] || die "release $tag has no Theo zip"
  if [ "$sums_url" != "-" ]; then
    download_asset "$sums_url" "$sums_api" "$WORK/SHA256SUMS" || die "couldn't download SHA256SUMS"
    EXPECTED_SHA="$(sum_for "SHA256SUMS" "$zip_name")"
    # The SIGNER file counts only when SHA256SUMS lists it and it matches: the same sign-off as the zip.
    local signer_sha; signer_sha="$(sum_for "SHA256SUMS" "SIGNER")"
    if [ "$signer_url" != "-" ] && [ -n "$signer_sha" ]; then
      download_asset "$signer_url" "$signer_api" "$WORK/SIGNER" || die "couldn't download the release's SIGNER file"
      [ "$(sha256_of "$WORK/SIGNER")" = "$(lowercase "$signer_sha")" ] || die "the release's SIGNER file doesn't match SHA256SUMS. Nothing was installed."
      RELEASE_SIGNER_FILE="$WORK/SIGNER"
    fi
  else
    EXPECTED_SHA="$note_sha"
  fi
  [ -n "$EXPECTED_SHA" ] && [ "$EXPECTED_SHA" != "-" ] || die "release $tag has no checksum for $zip_name, so it can't be checked"
  step "Downloading $zip_name ($tag)"
  ZIP="$WORK/$zip_name"
  download_asset "$zip_url" "$zip_api" "$ZIP" || die "the download failed"
}

sum_for() { # SHA256SUMS file (in $WORK), asset name: prints its checksum, or nothing
  awk -v n="$2" '{ f=$2; sub(/^\*/, "", f); if (f == n) { print $1; exit } }' "$WORK/$1"
}
sha256_of() { shasum -a 256 "$1" | awk '{print $1}'; }
lowercase() { printf '%s' "$1" | tr 'A-F' 'a-f'; }

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
  actual="$(sha256_of "$ZIP")"
  expected="$(lowercase "$EXPECTED_SHA")"
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
bundle_id_of() { plutil -extract CFBundleIdentifier raw -o - "$1/Contents/Info.plist" 2>/dev/null || true; }
build_of() { plutil -extract CFBundleVersion raw -o - "$1/Contents/Info.plist" 2>/dev/null || echo 0; }
designated_requirement_of() { codesign -d -r- "$1" 2>&1 | sed -n 's/^designated => //p'; }

# A signer rule is accepted only in one of the two forms Tools/install/signer-requirement.sh writes:
# Theo's bundle id plus one Apple team, or Theo's bundle id plus one certificate. Anything looser
# ("any Apple-issued certificate", an "or", a different bundle id) would let someone else's build in.
signer_rule_is_strict() {
  local id_pattern='identifier "com\.personal\.clicky"'
  printf '%s\n' "$1" | grep -Eqx "$id_pattern and anchor apple generic and certificate leaf\[subject\.OU\] = \"?[A-Z0-9]{10}\"?" && return 0
  printf '%s\n' "$1" | grep -Eqx "$id_pattern and certificate leaf = H\"[0-9a-fA-F]{40}\"" && return 0
  return 1
}

# Sets SIGNER_REQUIREMENT and SIGNER_SOURCE (see the top of this file). Empty when nothing names a signer;
# the installed Theo's own rule is checked separately when upgrading.
choose_signer_rule() {
  local rule="" source=""
  if [ -n "${THEO_SIGNER_REQUIREMENT:-}" ]; then rule="$THEO_SIGNER_REQUIREMENT"; source="THEO_SIGNER_REQUIREMENT"
  elif [ -n "$PUBLISHED_SIGNER_REQUIREMENT" ]; then rule="$PUBLISHED_SIGNER_REQUIREMENT"; source="this installer"
  elif [ -n "$RELEASE_SIGNER_FILE" ]; then rule="$(head -n 1 "$RELEASE_SIGNER_FILE" | tr -d '\r')"; source="the release's SIGNER file"
  fi
  if [ -n "$rule" ] && ! signer_rule_is_strict "$rule"; then
    die "the signer rule from $source is too loose to trust: $rule. Nothing was installed."
  fi
  SIGNER_REQUIREMENT="$rule"
  SIGNER_SOURCE="$source"
}

# Unzips into the work folder and checks the app is Theo, signed by Theo's signer. Sets NEW_APP.
unpack_and_verify() {
  mkdir -p "$WORK/unpacked"
  ditto -x -k "$ZIP" "$WORK/unpacked" || die "couldn't unzip the download"
  NEW_APP="$(find "$WORK/unpacked" -maxdepth 2 -name '*.app' -type d | head -n 1)"
  [ -n "$NEW_APP" ] || die "the zip has no app in it"
  # curl never adds quarantine; a zip given with --from may have been downloaded by a browser.
  xattr -dr com.apple.quarantine "$NEW_APP" 2>/dev/null || true
  codesign --verify --deep --strict "$NEW_APP" 2>/dev/null || die "the app's signature isn't valid. Nothing was installed."
  [ "$(bundle_id_of "$NEW_APP")" = "$BUNDLE_ID" ] || die "the zip doesn't contain Theo. Nothing was installed."
  if [ -n "$SIGNER_REQUIREMENT" ] && ! codesign --verify -R "=$SIGNER_REQUIREMENT" "$NEW_APP" 2>/dev/null; then
    die "the app is signed by '$(signer_of "$NEW_APP")', not Theo's signing identity (from $SIGNER_SOURCE). Nothing was installed."
  fi
}

# When Theo is already installed, the new app must satisfy the installed app's designated requirement: the rule
# macOS keeps Theo's permissions against, and the same check Theo's own Update button makes.
verify_same_signer_as_installed() { # installed app
  local installed_rule; installed_rule="$(designated_requirement_of "$1")"
  if [ -n "$installed_rule" ] && codesign --verify -R "=$installed_rule" "$NEW_APP" 2>/dev/null; then return 0; fi
  if [ "$ALLOW_NEW_SIGNER" = 1 ]; then
    warn "the new build is signed by '$(signer_of "$NEW_APP")', the installed Theo by '$(signer_of "$1")'. Going ahead (--allow-new-signer): macOS will ask for Theo's permissions again."
    return 0
  fi
  die "the new build is signed by '$(signer_of "$NEW_APP")', not by the same signer as the Theo in $1 ('$(signer_of "$1")'), so macOS would ask for every permission again. Nothing was installed. If you expected a new signer, run again with --allow-new-signer."
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
  WORK="$(mktemp -d "${TMPDIR:-/tmp}/theo-install.XXXXXX")"
  trap cleanup EXIT
  if [ -n "$FROM" ]; then fetch_from; else choose_releases_repo; fetch_release; fi
  verify_checksum
  choose_signer_rule
  unpack_and_verify

  choose_dir
  local dest="$INSTALL_DIR/$APP_NAME"
  local installed_theo=""
  if [ -e "$dest" ] && [ "$(bundle_id_of "$dest")" = "$BUNDLE_ID" ]; then installed_theo="$dest"; fi
  if [ -n "$installed_theo" ]; then
    verify_same_signer_as_installed "$installed_theo"
  elif [ -z "$SIGNER_REQUIREMENT" ]; then
    die "can't tell who should have signed this build: nothing names Theo's signer (no SIGNER file in the release, and Theo isn't installed here yet). Set THEO_SIGNER_REQUIREMENT (docs/INSTALL.md, \"Signing\"), or use the install.sh attached to the release. Nothing was installed."
  fi
  step "Signature OK ($(signer_of "$NEW_APP"), build $(build_of "$NEW_APP"))"
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
