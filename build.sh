#!/bin/bash
# Builds Murmur.app. Pass --install to replace the copy in /Applications.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT/dist/Murmur.app"
SUPPORT="$HOME/Library/Application Support/Murmur"

cd "$ROOT"
swift build -c release --arch arm64
BIN="$(swift build -c release --arch arm64 --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/Murmur" "$APP/Contents/MacOS/Murmur"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# the python worker lives in Application Support so the venv can find it
mkdir -p "$SUPPORT"
cp Resources/parakeetd.py "$SUPPORT/parakeetd.py"

# A stable identity keeps the same designated requirement across rebuilds, so the
# Accessibility grant survives. Ad-hoc signing gets a fresh hash every build and
# silently invalidates the grant while System Settings still shows it enabled.
IDENTITY="Murmur Local Signing"
if security find-identity -v -p codesigning | grep -q "$IDENTITY"; then
    codesign --force --sign "$IDENTITY" --identifier com.ramy.murmur "$APP"
else
    codesign --force --sign - --identifier com.ramy.murmur "$APP"
    echo "warning: signed ad-hoc — Accessibility must be re-granted after every build"
fi
echo "built  $APP"

if [[ "${1:-}" == "--install" ]]; then
    pkill -x Murmur 2>/dev/null || true
    sleep 1
    rm -rf /Applications/Murmur.app
    cp -R "$APP" /Applications/Murmur.app
    echo "installed  /Applications/Murmur.app"
fi
