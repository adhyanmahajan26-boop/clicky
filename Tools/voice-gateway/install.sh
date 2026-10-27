#!/bin/zsh
# Installs the Clicky voice gateway as a LaunchAgent on this Mac (the one with
# MLX Core), creates its key once, and prints the address and key to paste into
# Setup on the other Mac.
set -euo pipefail
GATEWAY_DIR="$HOME/.clicky/voice-gateway"
KEY_PATH="$HOME/.clicky/voice-gateway.key"
PLIST="$HOME/Library/LaunchAgents/com.personal.clicky.voice-gateway.plist"
mkdir -p "$GATEWAY_DIR" "$HOME/Library/Logs/Clicky" "$HOME/Library/LaunchAgents"
cp "$(dirname "$0")/voice_gateway.py" "$GATEWAY_DIR/voice_gateway.py"
if [[ ! -s "$KEY_PATH" ]]; then
  ( umask 077; openssl rand -hex 24 | sed 's/^/clk-voice-/' > "$KEY_PATH" )
fi
chmod 600 "$KEY_PATH"
cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.personal.clicky.voice-gateway</string>
  <key>ProgramArguments</key>
  <array><string>/usr/bin/python3</string><string>$GATEWAY_DIR/voice_gateway.py</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>$HOME/Library/Logs/Clicky/voice-gateway.log</string>
  <key>StandardErrorPath</key><string>$HOME/Library/Logs/Clicky/voice-gateway.log</string>
</dict>
</plist>
PLIST
launchctl bootout "gui/$(id -u)" "$PLIST" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
echo "Address: http://$(scutil --get LocalHostName | tr '[:upper:]' '[:lower:]').local:11240"
echo "Key:     $(cat "$KEY_PATH")"
