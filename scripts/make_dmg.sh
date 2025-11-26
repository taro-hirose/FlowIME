#!/usr/bin/env bash
set -euo pipefail

# Simple DMG packager for FlowIME (non-App Store distribution)
# Usage: bash scripts/make_dmg.sh [SCHEME]

SCHEME=${1:-FlowIME}
CONFIG=${CONFIG:-Release}
OUTDIR=${OUTDIR:-build}
STAGE=${STAGE:-dist/FlowIME-DMG}
DMG=${DMG:-FlowIME.dmg}

echo "[1/4] Building Xcode scheme: $SCHEME ($CONFIG)"
xcodebuild -scheme "$SCHEME" -configuration "$CONFIG" -derivedDataPath "$OUTDIR"

APP_PATH="$OUTDIR/Build/Products/$CONFIG/FlowIME.app"
if [[ ! -d "$APP_PATH" ]]; then
  echo "Error: Built app not found at $APP_PATH" >&2
  exit 1
fi

echo "[2/4] Staging payload"
rm -rf "$STAGE"
mkdir -p "$STAGE"
cp -R "$APP_PATH" "$STAGE/"
ln -s /Applications "$STAGE/Applications" 2>/dev/null || true

echo "[3/4] Creating DMG: $DMG"
rm -f "$DMG"
hdiutil create -volname "FlowIME" -srcfolder "$STAGE" -ov -format UDZO "$DMG"

echo "[4/4] Done -> $DMG"
