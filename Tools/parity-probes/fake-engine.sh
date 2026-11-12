#!/bin/zsh
# Stand-in for `claude -p` (test profile only, test.engine.claude). Behaviour from the mode file; every call's args go to calls.jsonl.
D=${0:A:h}
MODE=$(cat $D/fake-mode 2>/dev/null || echo ok)
python3 -c 'import json,sys,time; open(sys.argv[1],"a").write(json.dumps({"t":time.time(),"mode":sys.argv[2],"args":sys.argv[3:]})+"\n")' $D/calls.jsonl "$MODE" "$@"
resume=0; model=""; prev=""; for a in "$@"; do [[ "$a" == "--resume" ]] && resume=1; [[ "$prev" == "--model" ]] && model="$a"; prev="$a"; done
say() { python3 -c 'import json,sys; print(json.dumps({"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":sys.argv[1]}}}))' "$1"; }
init() { printf '{"type":"system","subtype":"init","session_id":"fake-%s"}\n' $$; }
case "$MODE" in
  ok) init; say "fake engine ok"; printf '{"type":"result","is_error":false,"result":"fake engine ok"}\n';;
  reply) init; say "$(cat $D/fake-reply)"; printf '{"type":"result","is_error":false}\n';;
  overloaded) printf '{"type":"result","is_error":true,"result":"API Error: 529 {\\"type\\":\\"error\\",\\"error\\":{\\"type\\":\\"overloaded_error\\",\\"message\\":\\"Overloaded\\"}}"}\n'; exit 1;;
  ratelimit) printf '{"type":"result","is_error":true,"result":"API Error: 429 rate_limit_error: This request would exceed the rate limit"}\n'; exit 1;;
  # Fails on the main model, answers on any other: a fallback chain test.
  model-down) if [[ "$model" == "$(cat $D/fake-down-model)" ]]; then printf '{"type":"result","is_error":true,"result":"API Error: 529 Overloaded"}\n'; exit 1; else init; say "answered on $model"; printf '{"type":"result","is_error":false}\n'; fi;;
  # Fails the first N calls (counter file), then answers: same-model retry test.
  flaky) n=$(cat $D/fake-flaky 2>/dev/null || echo 0); if (( n > 0 )); then echo $((n-1)) > $D/fake-flaky; printf '{"type":"result","is_error":true,"result":"API Error: 529 Overloaded"}\n'; exit 1; else init; say "answered after retry on $model"; printf '{"type":"result","is_error":false}\n'; fi;;
  autherr) printf '{"type":"result","is_error":true,"result":"Invalid API key · Please run /login"}\n'; exit 1;;
  slow) init; for i in {1..10}; do say "w$i "; sleep 1; done; printf '{"type":"result","is_error":false}\n';;
  *) echo "unknown mode" >&2; exit 64;;
esac
