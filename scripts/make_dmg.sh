#!/usr/bin/env bash
set -euo pipefail

# FlowIME DMG builder (Developer ID signing + optional notarization)
# Usage:
#   # minimal (unsigned, for local testing)
#   bash scripts/make_dmg.sh
#
#   # signed universal binary
#   IDENTITY="Developer ID Application: Your Name (TEAMID)" \
#   bash scripts/make_dmg.sh
#
#   # notarize + staple DMG (requires Xcode 13+ and app-specific password)
#   IDENTITY="Developer ID Application: Your Name (TEAMID)" \
#   TEAM_ID="TEAMID" APPLE_ID="you@example.com" APP_PASSWORD="app-specific-password" \
#   NOTARIZE=1 bash scripts/make_dmg.sh

SCHEME=${1:-FlowIME}
CONFIG=${CONFIG:-Release}
OUTDIR=${OUTDIR:-build}
STAGE=${STAGE:-dist/FlowIME-DMG}
DMG=${DMG:-FlowIME.dmg}
IDENTITY=${IDENTITY:-}
TEAM_ID=${TEAM_ID:-}
APPLE_ID=${APPLE_ID:-}
APP_PASSWORD=${APP_PASSWORD:-}
NOTARIZE=${NOTARIZE:-0}

echo "[1/6] Building Xcode scheme: $SCHEME ($CONFIG, universal)"
xcodebuild -scheme "$SCHEME" -configuration "$CONFIG" -derivedDataPath "$OUTDIR" -arch arm64 -arch x86_64

APP_PATH="$OUTDIR/Build/Products/$CONFIG/FlowIME.app"
if [[ ! -d "$APP_PATH" ]]; then
  echo "Error: Built app not found at $APP_PATH" >&2
  exit 1
fi

HELPER_PATH="$APP_PATH/Contents/Library/LoginItems/FlowIMEHelper.app"

if [[ -n "${IDENTITY}" ]]; then
  echo "[2/6] Code signing (Developer ID)"
  if [[ -d "$HELPER_PATH" ]]; then
    echo "  - Signing helper"
    codesign --force --options runtime --timestamp --sign "$IDENTITY" "$HELPER_PATH"
  fi
  echo "  - Signing main app"
  codesign --force --deep --options runtime --timestamp --sign "$IDENTITY" "$APP_PATH"
  echo "  - Verifying signature"
  codesign --verify --deep --strict --verbose=2 "$APP_PATH"
else
  echo "[2/6] Skipping code signing (IDENTITY not set)"
fi

echo "[3/6] Staging payload"
rm -rf "$STAGE"
mkdir -p "$STAGE"
cp -R "$APP_PATH" "$STAGE/"
ln -s /Applications "$STAGE/Applications" 2>/dev/null || true

echo "[4/6] Creating DMG: $DMG"
rm -f "$DMG"
hdiutil create -volname "FlowIME" -srcfolder "$STAGE" -ov -format UDZO "$DMG"

if [[ "${NOTARIZE}" == "1" ]]; then
  if [[ -z "${APPLE_ID}" || -z "${APP_PASSWORD}" || -z "${TEAM_ID}" ]]; then
    echo "[5/6] Skipping notarization: APPLE_ID/APP_PASSWORD/TEAM_ID required" >&2
  else
    echo "[5/6] Submitting DMG for notarization (notarytool)"
    xcrun notarytool submit "$DMG" --apple-id "$APPLE_ID" --team-id "$TEAM_ID" --password "$APP_PASSWORD" --wait
    echo "[6/6] Stapling notarization ticket"
    xcrun stapler staple "$DMG"
    echo "✅ Notarization complete"
  fi
else
  echo "[5/6] Notarization disabled (set NOTARIZE=1 to enable)"
fi

echo "Done -> $DMG"
echo
echo "Tips:"
echo "- If another Mac says '開けません/破損している', sign with Developer ID and notarize the DMG."
echo "- To verify locally: spctl -a -vvv \"$APP_PATH\" and codesign --verify --deep --strict --verbose=2 \"$APP_PATH\""
