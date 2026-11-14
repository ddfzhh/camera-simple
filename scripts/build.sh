#!/bin/bash
# Builds a universal (arm64 + x86_64) dist/Camera Simple.app, ad-hoc signed with the hardened runtime.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="dist/Camera Simple.app"
ICONSET=".build/AppIcon.iconset"

# Build each architecture separately and keep a copy of each slice; the two
# builds can share one output path depending on the SwiftPM build system.
SLICES=".build/slices"
rm -rf "$SLICES"
mkdir -p "$SLICES"
for ARCH in arm64 x86_64; do
  swift build -c release --arch "$ARCH"
  cp "$(swift build -c release --arch "$ARCH" --show-bin-path)/CameraSimple" "$SLICES/CameraSimple-$ARCH"
done

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

lipo -create \
  "$SLICES/CameraSimple-arm64" "$SLICES/CameraSimple-x86_64" \
  -output "$APP/Contents/MacOS/CameraSimple"

cp Support/Info.plist "$APP/Contents/Info.plist"

rm -rf "$ICONSET"
swift scripts/make-icon.swift "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

# Ad-hoc signature ("-"): no Developer ID, so the app is not notarized.
codesign --force --sign - --options runtime --timestamp=none \
  --entitlements Support/CameraSimple.entitlements "$APP"

codesign --verify --deep --strict "$APP"
echo "Built $APP ($(lipo -archs "$APP/Contents/MacOS/CameraSimple"))"
