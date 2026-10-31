#!/bin/bash
# Builds GroundingFixture.app into <repo>/build and ad-hoc signs it.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

BUNDLE="../../build/GroundingFixture.app"
EXECUTABLE_DIR="$BUNDLE/Contents/MacOS"

mkdir -p "$EXECUTABLE_DIR"

swiftc -O -parse-as-library GroundingFixture.swift -o "$EXECUTABLE_DIR/GroundingFixture"

cat > "$BUNDLE/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>com.personal.clicky.groundingfixture</string>
    <key>CFBundleExecutable</key>
    <string>GroundingFixture</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

codesign --force -s - "$BUNDLE"

echo "Built $(cd "$BUNDLE" && pwd)"
