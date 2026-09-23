#!/usr/bin/env bash
# Build the Mac Catalyst variant and render every key screen to PNG from demo
# data — no simulator, no Firebase, no screen-recording permission needed.
#   ./scripts/shoot.sh [out-dir]
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="${1:-build/shots}"; mkdir -p "$OUT"
xcodegen -q
xcodebuild -project SNOF.xcodeproj -scheme SNOF -destination 'platform=macOS,variant=Mac Catalyst' \
  -derivedDataPath build CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual build -quiet 2>&1 | grep -E "error:" || true
APP="build/Build/Products/Debug-maccatalyst/SNOF.app/Contents/MacOS/SNOF"
shot() { local name="$1"; shift; "$APP" -demo -snapshot "$PWD/$OUT/$name.png" "$@" >/dev/null 2>&1 || true; echo "$OUT/$name.png"; }
shot 01-overview
shot 02-overview-real -demo-real
shot 03-areas -tab areas -demo-real
shot 04-area-detail -area packing_shed
shot 05-devices-real -tab devices -demo-real
shot 06-devices-offline -tab devices -status offline -demo-real
shot 07-irrigation -tab irrigation
shot 08-viewer -demo-viewer
shot 09-control-off -demo-controloff
shot 10-stale -demo-stale
shot 11-signin -demo-signedout
shot 12-denied -demo-denied
shot 13-light -AppleInterfaceStyle Light -appearance light
