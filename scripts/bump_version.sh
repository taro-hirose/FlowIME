#!/usr/bin/env bash
set -euo pipefail

# Bump MARKETING_VERSION (CFBundleShortVersionString) in Xcode project.
# Defaults to bumping the minor component: X.Y -> X.(Y+1)
# Also bumps CURRENT_PROJECT_VERSION (build) by +1.
#
# Usage:
#   bash scripts/bump_version.sh            # bump minor (1.0 -> 1.1)
#   bash scripts/bump_version.sh --patch    # bump patch (1.0.3 -> 1.0.4)
#   bash scripts/bump_version.sh --major    # bump major (1.2 -> 2.0)
#   bash scripts/bump_version.sh 1.4.0      # set explicit version

PROJECT_FILE="FlowIME.xcodeproj/project.pbxproj"
MODE="minor"
TARGET_VER=""

for arg in "$@"; do
  case "$arg" in
    --major|--minor|--patch) MODE="${arg#--}" ;;
    *) TARGET_VER="$arg" ;;
  esac
done

if [[ ! -f "$PROJECT_FILE" ]]; then
  echo "Project file not found: $PROJECT_FILE" >&2
  exit 1
fi

# Extract first MARKETING_VERSION
CUR_VER=$(grep -E "\bMARKETING_VERSION\b" "$PROJECT_FILE" | head -n1 | sed -E 's/.*MARKETING_VERSION *= *"?([0-9]+(\.[0-9]+){0,2})"?;.*/\1/')
if [[ -z "$CUR_VER" ]]; then
  echo "Could not read MARKETING_VERSION from project" >&2
  exit 1
fi

bump() {
  local v="$1" mode="$2"
  IFS='.' read -r a b c <<<"$v"
  a=${a:-1}; b=${b:-0}; c=${c:-0}
  case "$mode" in
    major) a=$((a+1)); b=0; c=0 ;;
    minor) b=$((b+1)); c=0 ;;
    patch) c=$((c+1)) ;;
  esac
  if [[ -z "$c" || "$c" == "0" ]]; then
    echo "$a.$b"
  else
    echo "$a.$b.$c"
  fi
}

NEW_VER="$CUR_VER"
if [[ -n "$TARGET_VER" ]]; then
  NEW_VER="$TARGET_VER"
else
  NEW_VER=$(bump "$CUR_VER" "$MODE")
fi

if [[ "$NEW_VER" == "$CUR_VER" ]]; then
  echo "Version unchanged ($CUR_VER)"
else
  echo "MARKETING_VERSION: $CUR_VER -> $NEW_VER"
  # Replace all occurrences of MARKETING_VERSION
  # Quote version to be safe with Xcode's expectations
  sed -i.bak -E "s/(MARKETING_VERSION *= *)\"?[0-9]+(\.[0-9]+){0,2}\"?;/\\1\"$NEW_VER\";/g" "$PROJECT_FILE"
fi

# Bump build number (CURRENT_PROJECT_VERSION) by +1 everywhere
CUR_BUILD=$(grep -E "\bCURRENT_PROJECT_VERSION\b" "$PROJECT_FILE" | head -n1 | sed -E 's/.*CURRENT_PROJECT_VERSION *= *([0-9]+).*/\1/')
CUR_BUILD=${CUR_BUILD:-0}
NEW_BUILD=$((CUR_BUILD+1))
echo "CURRENT_PROJECT_VERSION: $CUR_BUILD -> $NEW_BUILD"
sed -i.bak -E "s/(CURRENT_PROJECT_VERSION *= *)[0-9]+/\\1$NEW_BUILD/g" "$PROJECT_FILE"

echo "Done. Commit the changes:"
echo "  git add $PROJECT_FILE && git commit -m \"chore: bump version to $NEW_VER ($NEW_BUILD)\""

