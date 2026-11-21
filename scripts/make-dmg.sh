#!/bin/bash
# Packs dist.noindex/Camera Simple.app into dist.noindex/Camera-Simple-<version>.dmg with an Applications shortcut.
# If the app is signed with a Developer ID, the app and the DMG are notarized by Apple and
# the tickets stapled, so the download opens without the "Apple could not verify" warning.
# Notarization uses credentials saved once with:
#   xcrun notarytool store-credentials "camera-simple-notary" --apple-id <apple id> --team-id <team id>
# (override the profile name with NOTARY_PROFILE=...).
set -euo pipefail
cd "$(dirname "$0")/.."

APP="dist.noindex/Camera Simple.app"
[ -d "$APP" ] || { echo "Run scripts/build.sh first." >&2; exit 1; }

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
DMG="dist.noindex/Camera-Simple-$VERSION.dmg"
STAGE=".build/dmg"
PROFILE="${NOTARY_PROFILE:-camera-simple-notary}"

# The Developer ID the app was signed with, if any.
SIGN_ID=$(codesign -dvv "$APP" 2>&1 | sed -n 's/^Authority=\(Developer ID Application: .*\)$/\1/p' | head -1)

notarize() {  # notarize <file>: submit to Apple, wait for the verdict, fail loudly if rejected
  echo "Notarizing $(basename "$1")..."
  local out id status try
  out=$(xcrun notarytool submit "$1" --keychain-profile "$PROFILE" --wait 2>&1) || true
  echo "$out"
  id=$(sed -n 's/^ *id: //p' <<<"$out" | head -1)
  # The wait can break off (network drop, Mac asleep) while Apple keeps working on the
  # upload: keep waiting on the same submission instead of uploading again.
  try=0
  while ! grep -q "status: Accepted\|status: Invalid\|status: Rejected" <<<"$out" && [ -n "$id" ] && [ $try -lt 20 ]; do
    try=$((try + 1))
    echo "Lost track of submission $id; waiting on it again ($try)..."
    sleep 30
    out=$(xcrun notarytool wait "$id" --keychain-profile "$PROFILE" 2>&1) || true
    echo "$out"
  done
  if ! grep -q "status: Accepted" <<<"$out"; then
    [ -n "$id" ] && xcrun notarytool log "$id" --keychain-profile "$PROFILE" >&2 || true
    echo "Notarization failed for $1" >&2
    exit 1
  fi
}

if [ -n "$SIGN_ID" ] && { xcrun stapler validate "$APP" >/dev/null 2>&1 || xcrun stapler staple "$APP" >/dev/null 2>&1; }; then
  # Already stapled, or Apple already has a ticket for this exact build (an earlier run
  # was interrupted after the upload): no need to upload it again.
  echo "App already notarized; ticket stapled."
elif [ -n "$SIGN_ID" ]; then
  # 1. Notarize the app itself and staple its ticket, so it also opens cleanly once it
  #    has been copied out of the DMG, even offline.
  ZIP=".build/notarize-app.zip"
  rm -f "$ZIP"
  ditto -c -k --keepParent "$APP" "$ZIP"
  notarize "$ZIP"
  rm -f "$ZIP"
  xcrun stapler staple "$APP"
else
  echo "App is not signed with a Developer ID: making an un-notarized DMG." >&2
fi

rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/Camera Simple.app"
ln -s /Applications "$STAGE/Applications"

hdiutil create -volname "Camera Simple" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
rm -rf "$STAGE"

if [ -n "$SIGN_ID" ]; then
  # 2. Sign, notarize and staple the DMG that people download.
  codesign --force --sign "$SIGN_ID" --timestamp "$DMG"
  notarize "$DMG"
  xcrun stapler staple "$DMG"
  spctl -a -t open --context context:primary-signature -v "$DMG"
fi
echo "Created $DMG"
