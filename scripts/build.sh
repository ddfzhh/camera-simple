#!/bin/bash
# Builds a universal (arm64 + x86_64) dist.noindex/Camera Simple.app, signed with the hardened runtime
# (Developer ID if available, else ad-hoc).
set -euo pipefail
cd "$(dirname "$0")/.."

# ".noindex" keeps Spotlight from listing this build copy next to the installed app.
APP="dist.noindex/Camera Simple.app"
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

# Sign with a Developer ID Application certificate when one is in the keychain (release
# builds; notarized by scripts/make-dmg.sh). Its designated requirement is tied to the
# team and bundle ID, so camera permission survives rebuilds and updates.
# Without one (e.g. someone else building from source), fall back to an ad-hoc
# signature, naming the bundle identifier as the designated requirement for the same
# reason: an ad-hoc signature's default requirement is the binary's hash, which changes
# every build and would make macOS ask for camera access again.
SIGN_ID="${SIGN_ID:-$(security find-identity -v -p codesigning | grep -o '"Developer ID Application: [^"]*"' | head -1 | tr -d '"')}"
if [ -n "$SIGN_ID" ]; then
  codesign --force --sign "$SIGN_ID" --options runtime --timestamp \
    --entitlements Support/CameraSimple.entitlements "$APP"
else
  echo "No Developer ID Application certificate found: signing ad-hoc (not notarizable)." >&2
  BUNDLE_ID=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" Support/Info.plist)
  codesign --force --sign - --options runtime --timestamp=none \
    --entitlements Support/CameraSimple.entitlements \
    --requirements "=designated => identifier \"$BUNDLE_ID\"" "$APP"
fi

codesign --verify --deep --strict "$APP"
echo "Built $APP ($(lipo -archs "$APP/Contents/MacOS/CameraSimple"))"
