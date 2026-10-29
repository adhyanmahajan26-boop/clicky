#!/bin/zsh
# Rebuilds the Debug app, then runs Tools/eval/hard_asks.py with Claude as the brain and again with
# ChatGPT (Codex), muted (the testMute command), and leaves the owner's brain and voice settings as they were.
# Usage: Tools/eval/run_both_brains.sh <output-dir>
set -u
cd "$(dirname "$0")/../.."
OUT="${1:-/tmp}"
APP="$(ls -d ~/Library/Developer/Xcode/DerivedData/leanring-buddy-*/Build/Products/Debug/Clicky.app | head -1)"
MAIN_BEFORE="$(defaults read com.personal.clicky selectedClaudeCodeModelAlias 2>/dev/null || echo claude-sonnet-5-5)"
HELPER_BEFORE="$(defaults read com.personal.clicky v2.models.helper 2>/dev/null || echo claude-haiku-5-5)"

restart() {
  osascript -e 'tell application id "com.personal.clicky" to quit' >/dev/null 2>&1
  sleep 3
  open --env NSUnbufferedIO=YES --stdout "$OUT/app-$1.log" --stderr "$OUT/app-$1.log" "$APP"
  sleep 12
}

xcodebuild -project leanring-buddy.xcodeproj -scheme leanring-buddy -configuration Debug build > "$OUT/build.log" 2>&1 || { echo "build failed"; exit 1; }
for brain in "claude-sonnet-5-5 claude-haiku-5-5 claude" "codex:gpt-6-luna codex:gpt-6-luna codex"; do
  set -- ${=brain}
  defaults write com.personal.clicky selectedClaudeCodeModelAlias "$1"
  defaults write com.personal.clicky v2.models.helper "$2"
  restart "$3"
  python3 Tools/eval/hard_asks.py > "$OUT/hard-$3.txt" 2>&1
done
defaults write com.personal.clicky selectedClaudeCodeModelAlias "$MAIN_BEFORE"
defaults write com.personal.clicky v2.models.helper "$HELPER_BEFORE"
restart owner
echo "claude: $(tail -1 "$OUT/hard-claude.txt")  codex: $(tail -1 "$OUT/hard-codex.txt")"
