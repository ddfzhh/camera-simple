#!/bin/bash
# Packs dist/Camera Simple.app into dist/Camera-Simple-<version>.dmg with an Applications shortcut.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="dist/Camera Simple.app"
[ -d "$APP" ] || { echo "Run scripts/build.sh first." >&2; exit 1; }

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
DMG="dist/Camera-Simple-$VERSION.dmg"
STAGE=".build/dmg"

rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/Camera Simple.app"
ln -s /Applications "$STAGE/Applications"

hdiutil create -volname "Camera Simple" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
rm -rf "$STAGE"
echo "Created $DMG"
