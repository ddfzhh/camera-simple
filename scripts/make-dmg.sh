#!/bin/bash
# Packs dist/Pinhole.app into dist/Pinhole-<version>.dmg with an Applications shortcut.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="dist/Pinhole.app"
[ -d "$APP" ] || { echo "Run scripts/build.sh first." >&2; exit 1; }

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
DMG="dist/Pinhole-$VERSION.dmg"
STAGE=".build/dmg"

rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/Pinhole.app"
ln -s /Applications "$STAGE/Applications"

hdiutil create -volname "Pinhole" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
rm -rf "$STAGE"
echo "Created $DMG"
