#!/bin/zsh
# Builds a universal (Apple silicon + Intel) SpeedMerge.app in this folder.
#   ./build.sh          build SpeedMerge.app
#   ./build.sh --dmg    also package dist/SpeedMerge-<version>.dmg and .zip
set -euo pipefail
cd "$(dirname "$0")"

ARCHS=(--arch arm64 --arch x86_64)
swift build -c release $ARCHS
BIN="$(swift build -c release $ARCHS --show-bin-path)/SpeedMerge"

APP="SpeedMerge.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/SpeedMerge"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# App icon
ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"
swift scripts/make-icon.swift "$ICONSET/icon_512x512@2x.png"
for s in 16 32 128 256 512; do
  sips -z $s $s "$ICONSET/icon_512x512@2x.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) "$ICONSET/icon_512x512@2x.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

codesign --force --sign - "$APP"
echo "Built $(pwd)/$APP"

if [[ "${1:-}" == "--dmg" ]]; then
  VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
  mkdir -p dist
  STAGE="$(mktemp -d)/SpeedMerge"
  mkdir -p "$STAGE"
  ditto "$APP" "$STAGE/$APP"
  ln -s /Applications "$STAGE/Applications"
  rm -f "dist/SpeedMerge-$VERSION.dmg" "dist/SpeedMerge-$VERSION.zip"
  hdiutil create -quiet -volname "SpeedMerge $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO "dist/SpeedMerge-$VERSION.dmg"
  ditto -c -k --keepParent "$APP" "dist/SpeedMerge-$VERSION.zip"
  echo "Packaged $(pwd)/dist/SpeedMerge-$VERSION.dmg and .zip"
fi
