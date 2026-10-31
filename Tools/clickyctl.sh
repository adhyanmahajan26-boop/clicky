#!/usr/bin/env bash
# clickyctl.sh - bash client for the Clicky file-based debug inbox.
#
# Usage: Tools/clickyctl.sh '<json>' [timeout_seconds=120]
#   <json> is one JSON object, e.g. {"cmd":"ping"}.
#
# The request is written to ~/.clicky/debug-inbox/<id>.json (via a .tmp file and
# an atomic mv). The script then polls ~/.clicky/debug-outbox/<id>.json every
# 0.1s. When the reply appears it is printed to stdout, removed, and the script
# exits 0. On timeout it prints {"ok":false,"error":"timeout"} and exits 1.
# Exit code 2 means no JSON argument was given (usage goes to stderr).

set -euo pipefail

if [ "$#" -lt 1 ] || [ -z "$1" ]; then
  echo "usage: $(basename "$0") '<json>' [timeout_seconds=120]" >&2
  exit 2
fi

REQUEST="$1"
TIMEOUT="${2:-120}"

case "$TIMEOUT" in
  ''|*[!0-9]*)
    echo "error: timeout_seconds must be a non-negative integer" >&2
    exit 2
    ;;
esac

INBOX="$HOME/.clicky/debug-inbox"
OUTBOX="$HOME/.clicky/debug-outbox"
mkdir -p "$INBOX" "$OUTBOX"
chmod 700 "$INBOX" "$OUTBOX"

ID="$(uuidgen)"
TMP="$INBOX/$ID.json.tmp"
REQ="$INBOX/$ID.json"
REPLY="$OUTBOX/$ID.json"

printf '%s\n' "$REQUEST" > "$TMP"
mv "$TMP" "$REQ"

MAX_TICKS=$(( TIMEOUT * 10 ))
ticks=0
while [ "$ticks" -lt "$MAX_TICKS" ]; do
  if [ -f "$REPLY" ]; then
    cat "$REPLY"
    rm -f "$REPLY"
    exit 0
  fi
  sleep 0.1
  ticks=$(( ticks + 1 ))
done

rm -f "$REQ"
echo '{"ok":false,"error":"timeout"}'
exit 1
