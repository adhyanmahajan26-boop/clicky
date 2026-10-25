#!/bin/sh
# fakecli.sh - TEST-ONLY fake command-line program.
#
# Used by the Swift unit tests of the process runner to simulate a CLI that
# ignores signals, leaves orphaned children, floods output, prints odd line
# separators, runs slowly, or speaks Claude Code's stream-json. It is never
# shipped with the app and never run by hand as a real tool.
#
# Usage: fakecli.sh <mode> [arg]
#   ignore-int        ignore INT/TERM, start a child that ignores them too,
#                     print "child <pid>", then sleep 300 (only SIGKILL stops it)
#   orphan            start a background sleep 300, print "child <pid>", exit 0
#   flood <bytes>     write <bytes> bytes to stdout and the same to stderr, exit 0
#   lines             print "one", "a<U+2028>b", "three"
#   idle <seconds>    print "start", sleep <seconds>, print "end"
#   stream-json       print three lines imitating Claude Code stream-json
set -eu

mode=${1:-}

case "$mode" in
  ignore-int)
    trap '' INT TERM
    sh -c "trap '' INT TERM; sleep 300" &
    echo "child $!"
    sleep 300
    ;;

  orphan)
    sleep 300 &
    echo "child $!"
    exit 0
    ;;

  flood)
    bytes=${2:?flood needs a byte count}
    head -c "$bytes" /dev/zero | tr '\0' 'x'
    head -c "$bytes" /dev/zero | tr '\0' 'x' >&2
    exit 0
    ;;

  lines)
    printf 'one\n'
    # U+2028 LINE SEPARATOR is UTF-8 E2 80 A8.
    printf 'a\342\200\250b\n'
    printf 'three\n'
    ;;

  idle)
    echo start
    sleep "${2:?idle needs a number of seconds}"
    echo end
    ;;

  stream-json)
    cwd_json=$(pwd | sed 's/\\/\\\\/g; s/"/\\"/g')
    printf '{"type":"system","subtype":"init","permissionMode":"acceptEdits","tools":["Read","Edit"],"mcp_servers":[],"cwd":"%s","apiKeySource":"none"}\n' "$cwd_json"
    printf '%s\n' '{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"hi"}}}'
    printf '%s\n' '{"type":"result","subtype":"success","is_error":false,"result":"hi"}'
    ;;

  *)
    echo "fakecli: unknown mode '$mode'" >&2
    exit 64
    ;;
esac
