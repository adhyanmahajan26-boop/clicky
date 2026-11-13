#!/bin/bash
# Sets the Apple team that signs your builds of Theo, in Config/Signing.local.xcconfig (not committed;
# Config/Theo.xcconfig includes it). With a team, macOS keeps Theo's permissions across rebuilds and
# updates. Without one, Xcode signs to run locally and macOS asks again after each rebuild.
#
#   Tools/setup-signing.sh               use the team of the Apple Development certificate in your keychain
#   Tools/setup-signing.sh ABCDE12345    use this team
#   Tools/setup-signing.sh --show        print the team set now
#
# A free Apple ID works (Xcode › Settings › Accounts › Manage Certificates › + Apple Development).
# Changing the team of a Theo you already use makes macOS ask for its permissions once more, and
# Tools/release.sh refuses such a build until you say so (CLICKY_ALLOW_NEW_SIGNER=1).
set -euo pipefail
cd "$(dirname "$0")/.."
LOCAL="Config/Signing.local.xcconfig"

current_team() { [ -f "$LOCAL" ] && sed -n 's/^[[:space:]]*DEVELOPMENT_TEAM[[:space:]]*=[[:space:]]*\([A-Z0-9]*\).*/\1/p' "$LOCAL" | head -n 1; true; }

if [ "${1:-}" = "--show" ]; then
  team="$(current_team)"; [ -n "$team" ] && echo "$team" || echo "no team set ($LOCAL is missing or empty)"
  exit 0
fi

TEAM="${1:-}"
if [ -z "$TEAM" ]; then
  # Every Apple Development certificate in the keychain, by the team in its subject (OU).
  work="$(mktemp -d "${TMPDIR:-/tmp}/theo-signing.XXXXXX")"; trap 'rm -rf "$work"' EXIT
  security find-certificate -a -c "Apple Development" -p > "$work/all.pem" 2>/dev/null || true
  awk -v dir="$work" '/-----BEGIN CERTIFICATE-----/ { count++ } count { print > (dir "/certificate-" count ".pem") }' "$work/all.pem"
  TEAMS="$(for certificate in "$work"/certificate-*.pem; do
             [ -f "$certificate" ] && openssl x509 -noout -subject -in "$certificate" 2>/dev/null
           done | sed -n 's/.*OU *= *\([A-Z0-9]\{10\}\).*/\1/p' | sort -u)"
  count="$(printf '%s' "$TEAMS" | grep -c . || true)"
  if [ "$count" = 0 ]; then
    echo "No Apple Development certificate in your keychain. In Xcode: Settings › Accounts, add your Apple ID (free), then" >&2
    echo "Manage Certificates › + › Apple Development. Or pass your team id: Tools/setup-signing.sh ABCDE12345" >&2
    exit 1
  fi
  if [ "$count" != 1 ]; then
    echo "More than one team has an Apple Development certificate here; pass the one to use:" >&2
    printf '  %s\n' $TEAMS >&2
    exit 1
  fi
  TEAM="$TEAMS"
fi
[[ "$TEAM" =~ ^[A-Z0-9]{10}$ ]] || { echo "a team id is 10 letters and digits, got '$TEAM'" >&2; exit 1; }
previous="$(current_team)"
cat > "$LOCAL" <<XCCONFIG
// Written by Tools/setup-signing.sh. Not committed (.gitignore). See Config/Theo.xcconfig.
DEVELOPMENT_TEAM = $TEAM
XCCONFIG
if [ -n "$previous" ] && [ "$previous" != "$TEAM" ]; then
  echo "Signing team changed from $previous to $TEAM in $LOCAL. macOS will ask for Theo's permissions again after the next build."
else
  echo "Signing team $TEAM is set in $LOCAL."
fi
