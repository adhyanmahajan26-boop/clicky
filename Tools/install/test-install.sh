#!/bin/bash
# End-to-end tests for install.sh that never touch the installed Theo or its data:
# everything goes into a scratch folder (apps, a fake $HOME for uninstall, a local fake GitHub),
# and the one launch uses the isolated `--profile test-install`.
#
# Usage: Tools/install/test-install.sh <scratch folder> <newer Theo zip> [--no-github]
#   The newer zip must be a Theo build newer than the latest published release (e.g. from
#   CLICKY_RELEASE_DRY_RUN=1 Tools/release.sh). --no-github skips the test against the real releases repo.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
INSTALLER="$HERE/install.sh"
ROOT="${1:?scratch folder}"; NEWZIP="${2:?newer Theo zip}"; GITHUB=1
[ "${3:-}" = "--no-github" ] && GITHUB=0
mkdir -p "$ROOT"; ROOT="$(cd "$ROOT" && pwd)"
rm -rf "$ROOT/apps" "$ROOT/home" "$ROOT/fake" "$ROOT/zips" "$ROOT/logs"
mkdir -p "$ROOT/apps" "$ROOT/home/.Trash" "$ROOT/fake" "$ROOT/zips" "$ROOT/logs"
APP="$ROOT/apps/Theo.app"
NEWSHA="$(shasum -a 256 "$NEWZIP" | awk '{print $1}')"
NEWBUILD="$(unzip -p "$NEWZIP" 'Theo.app/Contents/Info.plist' | plutil -extract CFBundleVersion raw -)"
PASS=0; FAIL=0; N=0

ok()   { PASS=$((PASS+1)); printf 'PASS  %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf 'FAIL  %s\n' "$1"; [ -n "${2:-}" ] && sed 's/^/      | /' "$2" | tail -6; }
run()  { N=$((N+1)); LOG="$ROOT/logs/$N.log"; bash "$INSTALLER" "$@" > "$LOG" 2>&1; RC=$?; }
build() { /usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$1/Contents/Info.plist" 2>/dev/null || echo none; }
has()  { grep -q "$1" "$LOG"; }
leftovers() { ls -a "$ROOT/apps" | grep -c '^\.Theo\.app\.' ; }

# ---- 1. the real releases repo (latest build, checksum from the release notes, private repo via gh)
if [ "$GITHUB" = 1 ]; then
  run --dir "$ROOT/apps" --no-launch
  [ $RC = 0 ] && [ -d "$APP" ] && has "Checksum OK" && has "Signature OK" && ! xattr "$APP" | grep -q quarantine \
    && ok "fresh install of the latest release from GitHub (build $(build "$APP"))" || bad "fresh install from GitHub" "$LOG"
  OLDBUILD="$(build "$APP")"
  run --dir "$ROOT/apps" --version build-1 --no-launch
  [ $RC != 0 ] && has "no such release" && [ "$(build "$APP")" = "$OLDBUILD" ] \
    && ok "a release that doesn't exist fails cleanly" || bad "missing release" "$LOG"
else
  run --dir "$ROOT/apps" --from "$NEWZIP" --sha256 "$NEWSHA" --no-launch --force
fi

# ---- 2. upgrade to the newer zip
run --dir "$ROOT/apps" --from "$NEWZIP" --sha256 "$NEWSHA" --no-launch
[ $RC = 0 ] && [ "$(build "$APP")" = "$NEWBUILD" ] && [ "$(leftovers)" = 0 ] && has "carry over" \
  && ok "upgrade to build $NEWBUILD, no leftovers" || bad "upgrade" "$LOG"

# ---- 3. same build again
run --dir "$ROOT/apps" --from "$NEWZIP" --sha256 "$NEWSHA" --no-launch
[ $RC = 0 ] && has "already installed" && ok "same build again is a no-op" || bad "same build again" "$LOG"

# ---- 4. downgrade refused (the latest release is older than the dry-run build)
if [ "$GITHUB" = 1 ]; then
  run --dir "$ROOT/apps" --no-launch
  [ $RC != 0 ] && has "newer than" && [ "$(build "$APP")" = "$NEWBUILD" ] \
    && ok "an older build is refused without --force" || bad "downgrade" "$LOG"
fi

# ---- 5. wrong checksum: refused, installed app untouched
BEFORE="$(find "$APP" -type f -exec stat -f '%m' {} + | shasum | cut -c1-12)"
run --dir "$ROOT/apps" --from "$NEWZIP" --sha256 "$(printf '0%.0s' $(seq 64))" --no-launch --force
AFTER="$(find "$APP" -type f -exec stat -f '%m' {} + | shasum | cut -c1-12)"
[ $RC != 0 ] && has "doesn't match its checksum" && [ "$BEFORE" = "$AFTER" ] \
  && ok "a wrong checksum is refused and nothing changes" || bad "wrong checksum" "$LOG"

# ---- 6. same checksum but re-signed by someone else (ad hoc): refused
W="$ROOT/zips/adhoc"; mkdir -p "$W"; ditto -x -k "$NEWZIP" "$W"
codesign --force --deep --sign - "$W/Theo.app" 2>/dev/null
ditto -c -k --keepParent "$W/Theo.app" "$ROOT/zips/adhoc.zip"
run --dir "$ROOT/apps" --from "$ROOT/zips/adhoc.zip" --sha256 "$(shasum -a 256 "$ROOT/zips/adhoc.zip" | awk '{print $1}')" --no-launch --force
[ $RC != 0 ] && has "not Theo's" && ok "an app signed by another identity is refused" || bad "ad-hoc signed" "$LOG"

# ---- 7. a different app signed by Theo's own team: refused (bundle id)
W="$ROOT/zips/other"; mkdir -p "$W"; ditto -x -k "$NEWZIP" "$W"
plutil -replace CFBundleIdentifier -string com.example.notheo "$W/Theo.app/Contents/Info.plist"
IDENTITY="$(security find-identity -v -p codesigning | sed -n 's/.*"\(Apple Development:[^"]*\)".*/\1/p' | head -1)"
if [ -n "$IDENTITY" ] && codesign --force --deep --sign "$IDENTITY" "$W/Theo.app" 2>/dev/null; then
  ditto -c -k --keepParent "$W/Theo.app" "$ROOT/zips/other.zip"
  run --dir "$ROOT/apps" --from "$ROOT/zips/other.zip" --sha256 "$(shasum -a 256 "$ROOT/zips/other.zip" | awk '{print $1}')" --no-launch --force
  [ $RC != 0 ] && has "doesn't contain Theo" && ok "another app from the same team is refused" || bad "other bundle id" "$LOG"
else
  printf 'SKIP  another app from the same team (no signing identity here)\n'
fi

# ---- 8. a browser-downloaded (quarantined) zip: the installed app has no quarantine flag
cp "$NEWZIP" "$ROOT/zips/browser.zip"
xattr -w com.apple.quarantine "0083;$(printf '%x' "$(date +%s)");Safari;" "$ROOT/zips/browser.zip"
run --dir "$ROOT/apps" --from "$ROOT/zips/browser.zip" --sha256 "$NEWSHA" --no-launch --force
[ $RC = 0 ] && ! xattr -r "$APP" 2>/dev/null | grep -q com.apple.quarantine \
  && ok "quarantine is stripped from a browser-downloaded zip" || bad "quarantine" "$LOG"

# ---- 9-11. a fake GitHub (latest release with a SHA256SUMS asset), with and without a token, and via curl | bash
PORT=$((47900 + RANDOM % 80))
FAKE="$ROOT/fake"; NAME="Theo-$NEWBUILD.zip"; BASE="http://127.0.0.1:$PORT"
mkdir -p "$FAKE/repos/test/theo/releases" "$FAKE/dl" "$FAKE/api-assets"
cp "$NEWZIP" "$FAKE/dl/$NAME"; cp "$NEWZIP" "$FAKE/api-assets/1"
printf '%s  %s\n' "$NEWSHA" "$NAME" > "$FAKE/dl/SHA256SUMS"; cp "$FAKE/dl/SHA256SUMS" "$FAKE/api-assets/2"
cp "$INSTALLER" "$FAKE/dl/install.sh"
cat > "$FAKE/repos/test/theo/releases/latest" <<JSON
{"tag_name":"build-$NEWBUILD","body":"Fake release for installer tests (no sha256 line: the SUMS file must be used).",
 "assets":[{"name":"$NAME","browser_download_url":"$BASE/dl/$NAME","url":"$BASE/api-assets/1"},
           {"name":"SHA256SUMS","browser_download_url":"$BASE/dl/SHA256SUMS","url":"$BASE/api-assets/2"},
           {"name":"install.sh","browser_download_url":"$BASE/dl/install.sh","url":"$BASE/api-assets/3"}]}
JSON
# A static file server that also logs the Authorization header it receives.
( cd "$FAKE" && exec python3 -c '
import http.server, sys
class H(http.server.SimpleHTTPRequestHandler):
    def log_message(self, fmt, *args):
        sys.stderr.write("%s auth=%s\n" % (fmt % args, self.headers.get("Authorization", "-")))
http.server.ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
' "$PORT" ) > "$ROOT/logs/fake-github.log" 2>&1 &
SERVER=$!
trap 'kill $SERVER 2>/dev/null' EXIT
for _ in $(seq 1 50); do curl -fs "$BASE/dl/SHA256SUMS" >/dev/null 2>&1 && break; sleep 0.1; done

rm -rf "$APP"
N=$((N+1)); LOG="$ROOT/logs/$N.log"
env -i HOME="$HOME" PATH=/usr/bin:/bin:/usr/sbin:/sbin THEO_GITHUB_API="$BASE" THEO_RELEASES_REPO=test/theo \
  bash "$INSTALLER" --dir "$ROOT/apps" --no-launch > "$LOG" 2>&1; RC=$?
[ $RC = 0 ] && [ "$(build "$APP")" = "$NEWBUILD" ] && grep -q "GET /dl/$NAME" "$ROOT/logs/fake-github.log" \
  && ok "public repo: latest release, checksum from SHA256SUMS" || bad "fake GitHub, no token" "$LOG"

rm -rf "$APP"
N=$((N+1)); LOG="$ROOT/logs/$N.log"
env -i HOME="$HOME" PATH=/usr/bin:/bin:/usr/sbin:/sbin THEO_GITHUB_API="$BASE" THEO_RELEASES_REPO=test/theo \
  THEO_GITHUB_TOKEN=not-a-real-token bash "$INSTALLER" --dir "$ROOT/apps" --no-launch > "$LOG" 2>&1; RC=$?
[ $RC = 0 ] && [ "$(build "$APP")" = "$NEWBUILD" ] && grep "GET /api-assets/1" "$ROOT/logs/fake-github.log" | grep -q "auth=Bearer not-a-real-token" \
  && ok "private repo: download through the API with the token" || bad "fake GitHub, token" "$LOG"

rm -rf "$APP"
N=$((N+1)); LOG="$ROOT/logs/$N.log"
env -i HOME="$HOME" PATH=/usr/bin:/bin:/usr/sbin:/sbin THEO_GITHUB_API="$BASE" THEO_RELEASES_REPO=test/theo \
  bash -c "curl -fsSL '$BASE/dl/install.sh' | bash -s -- --dir '$ROOT/apps' --no-launch" > "$LOG" 2>&1; RC=$?
[ $RC = 0 ] && [ "$(build "$APP")" = "$NEWBUILD" ] && ok "curl ... | bash one-liner" || bad "curl | bash" "$LOG"

# ---- 12. launch the installed app (isolated test profile), then upgrade over it while it runs
PROFILE=test-install
for key in v2.screen.claudia v2.screen.claudia.side v2.screen.claudia.sideFor; do
  value="$(defaults read com.personal.clicky "$key" 2>/dev/null || true)"
  [ -n "$value" ] && defaults write "com.personal.clicky.$PROFILE" "$key" -string "$value"
done
defaults write "com.personal.clicky.$PROFILE" v2.setup.completed -bool true
( exec "$APP/Contents/MacOS/Clicky" --profile "$PROFILE" > "$ROOT/logs/launch.log" 2>&1 < /dev/null ) &
disown 2>/dev/null || true
sleep 8
PIDS="$(ps -axo pid=,comm= | awk -v e="$APP/Contents/MacOS/Clicky" '{p=$1;$1="";sub(/^ /,"");if($0==e)print p}')"
[ -n "$PIDS" ] && ok "the installed app launches and stays up (pid $PIDS, profile $PROFILE)" || bad "launch" "$ROOT/logs/launch.log"
run --dir "$ROOT/apps" --from "$NEWZIP" --sha256 "$NEWSHA" --no-launch --force
STILL="$(ps -axo pid=,comm= | awk -v e="$APP/Contents/MacOS/Clicky" '{p=$1;$1="";sub(/^ /,"");if($0==e)print p}')"
[ $RC = 0 ] && has "Quitting the running Theo" && [ -z "$STILL" ] && [ "$(build "$APP")" = "$NEWBUILD" ] \
  && ok "upgrading quits the running copy first" || { bad "upgrade while running" "$LOG"; [ -n "$STILL" ] && kill $STILL; }

# ---- 13. uninstall keeps data (fake $HOME)
mkdir -p "$ROOT/home/Library/Application Support/Theo/Bots" "$ROOT/home/.clicky"
echo '{}' > "$ROOT/home/Library/Application Support/Theo/Bots/bots.json"
N=$((N+1)); LOG="$ROOT/logs/$N.log"
HOME="$ROOT/home" bash "$INSTALLER" --uninstall --dir "$ROOT/apps" > "$LOG" 2>&1; RC=$?
[ $RC = 0 ] && [ ! -e "$APP" ] && ls "$ROOT/home/.Trash" | grep -q '^Theo-.*\.app$' \
  && [ -f "$ROOT/home/Library/Application Support/Theo/Bots/bots.json" ] \
  && ok "uninstall moves the app to the Trash and keeps the data" || bad "uninstall" "$LOG"

# ---- 14. uninstall --purge (system-wide steps skipped: they'd act on the real account)
bash "$INSTALLER" --dir "$ROOT/apps" --from "$NEWZIP" --sha256 "$NEWSHA" --no-launch > /dev/null 2>&1
N=$((N+1)); LOG="$ROOT/logs/$N.log"
HOME="$ROOT/home" THEO_UNINSTALL_SKIP_SYSTEM=1 bash "$INSTALLER" --uninstall --purge --yes --dir "$ROOT/apps" > "$LOG" 2>&1; RC=$?
[ $RC = 0 ] && [ ! -e "$APP" ] && [ ! -e "$ROOT/home/Library/Application Support/Theo" ] && [ ! -e "$ROOT/home/.clicky" ] \
  && ls "$ROOT/home/.Trash"/Theo-data-*/Theo/Bots/bots.json >/dev/null 2>&1 \
  && ok "uninstall --purge moves the data to the Trash" || bad "purge" "$LOG"

# ---- 15. uninstall when nothing is installed
run --uninstall --dir "$ROOT/apps"
[ $RC = 0 ] && has "isn't installed" && ok "uninstall with nothing installed is harmless" || bad "uninstall nothing" "$LOG"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
