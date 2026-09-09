#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

CONFIG="${1:-debug}"
swift build -c "$CONFIG"

APP="InterviewAssist.app"
BIN=".build/$CONFIG/InterviewAssist"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/InterviewAssist"
cp Resources/Info.plist "$APP/Contents/Info.plist"

SIGN_ID="InterviewAssistLocalSign"
codesign --force --deep --sign "$SIGN_ID" --entitlements Resources/entitlements.plist "$APP"

echo "Built $APP (config=$CONFIG)"
