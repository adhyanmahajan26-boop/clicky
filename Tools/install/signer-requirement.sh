#!/bin/bash
# Prints the signer rule for a signed Theo.app: the code requirement install.sh checks a download
# against, in one of the two strict forms it accepts (install.sh, signer_rule_is_strict):
#   signed with an Apple certificate (a free Personal Team works):
#     identifier "com.personal.clicky" and anchor apple generic and certificate leaf[subject.OU] = "<team>"
#   signed with a self-signed certificate (no team):
#     identifier "com.personal.clicky" and certificate leaf = H"<SHA-1 of the certificate>"
# Tools/release.sh writes it into the install.sh and the SIGNER file it publishes.
# Refuses an app that is ad hoc signed or not signed, so an unsigned build can't be released.
#
# Usage: Tools/install/signer-requirement.sh <path to Theo.app>
set -euo pipefail
APP="${1:?path to Theo.app}"
BUNDLE_ID="com.personal.clicky"

die() { printf 'signer-requirement: %s\n' "$*" >&2; exit 1; }

[ -d "$APP" ] || die "no such app: $APP"
codesign --verify --deep --strict "$APP" 2>/dev/null || die "$APP has no valid signature"
bundle_id="$(plutil -extract CFBundleIdentifier raw -o - "$APP/Contents/Info.plist" 2>/dev/null || true)"
[ "$bundle_id" = "$BUNDLE_ID" ] || die "$APP isn't Theo (bundle id '$bundle_id')"
info="$(codesign -dvv "$APP" 2>&1)"
case "$info" in *"Signature=adhoc"*) die "$APP is ad hoc signed (no team or certificate): set up signing first (Tools/setup-signing.sh)" ;; esac
team="$(printf '%s\n' "$info" | sed -n 's/^TeamIdentifier=//p')"
if [ -n "$team" ] && [ "$team" != "not set" ]; then
  printf 'identifier "%s" and anchor apple generic and certificate leaf[subject.OU] = "%s"\n' "$BUNDLE_ID" "$team"
  exit 0
fi
leaf="$(codesign -d -r- "$APP" 2>&1 | sed -n 's/.*certificate leaf = H"\([0-9a-fA-F]\{40\}\)".*/\1/p' | head -n 1)"
[ -n "$leaf" ] || die "can't tell who signed $APP (no team and no certificate hash in its designated requirement)"
printf 'identifier "%s" and certificate leaf = H"%s"\n' "$BUNDLE_ID" "$leaf"
