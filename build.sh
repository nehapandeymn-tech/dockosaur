#!/bin/bash
# Builds build/Dockosaur.app (no Xcode project). ./build.sh --install also copies it to /Applications.
set -euo pipefail
cd "$(dirname "$0")"

APP=build/Dockosaur.app
TARGET="$(uname -m)-apple-macos14.0"   # pin: this Mac's CLT defaults to a newer macOS than it runs

if [[ ! -f Resources/AppIcon.icns || Tools/icon.swift -nt Resources/AppIcon.icns ]]; then
  mkdir -p build/AppIcon.iconset
  swift Tools/icon.swift build/icon1024.png
  for s in 16 32 128 256 512; do
    sips -z $s $s build/icon1024.png --out build/AppIcon.iconset/icon_${s}x${s}.png >/dev/null
    sips -z $((s*2)) $((s*2)) build/icon1024.png --out build/AppIcon.iconset/icon_${s}x${s}@2x.png >/dev/null
  done
  iconutil -c icns build/AppIcon.iconset -o Resources/AppIcon.icns
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -swift-version 5 -target "$TARGET" Sources/*.swift -o "$APP/Contents/MacOS/Dockosaur"
cp Resources/Info.plist "$APP/Contents/"
cp -R Resources/Art Resources/AppIcon.icns "$APP/Contents/Resources/"

"$APP/Contents/MacOS/Dockosaur" --selftest

# A stable signing identity keeps the Input Monitoring grant across rebuilds; ad-hoc resets it every build.
IDENTITY="${DOCKOSAUR_SIGN_IDENTITY:-Pratik Dev Signing}"
security find-identity -v -p codesigning | grep -q "\"$IDENTITY\"" || IDENTITY=-
codesign --force --sign "$IDENTITY" "$APP"
echo "built $APP (signed: $IDENTITY)"

if [[ "${1:-}" == "--install" ]]; then
  pkill -x Dockosaur || true
  rm -rf /Applications/Dockosaur.app
  cp -R "$APP" /Applications/
  echo "installed /Applications/Dockosaur.app"
fi
