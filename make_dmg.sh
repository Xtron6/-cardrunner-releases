#!/bin/bash
# make_dmg.sh — Build a distribution DMG for CardRunner
#
# Prerequisites:
#   brew install create-dmg
#
# Usage (after exporting a notarized .app from Xcode Organizer):
#   ./make_dmg.sh                        # looks for CardRunner.app in this folder
#   ./make_dmg.sh /path/to/CardRunner.app
#
# Output: CardRunner-<version>.dmg in this directory

set -euo pipefail

APP_NAME="CardRunner"
APP_PATH="${1:-${APP_NAME}.app}"

# ── Validate input ────────────────────────────────────────────────────────────
if [[ ! -d "$APP_PATH" ]]; then
  echo "❌  $APP_PATH not found."
  echo "    Export the notarized app from Xcode Organizer first, then re-run."
  echo "    (Product → Archive → Distribute App → Developer ID → Export)"
  exit 1
fi

if ! command -v create-dmg &>/dev/null; then
  echo "❌  create-dmg not installed. Run:"
  echo "    brew install create-dmg"
  exit 1
fi

# ── Auto-detect version from the app bundle ───────────────────────────────────
PLIST="$APP_PATH/Contents/Info.plist"
VERSION=$(defaults read "$(pwd)/$PLIST" CFBundleShortVersionString 2>/dev/null \
          || /usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$PLIST" 2>/dev/null \
          || echo "1.0")
BUILD=$(defaults read "$(pwd)/$PLIST" CFBundleVersion 2>/dev/null \
        || /usr/libexec/PlistBuddy -c "Print CFBundleVersion" "$PLIST" 2>/dev/null \
        || echo "1")

DMG_NAME="${APP_NAME}-${VERSION}.dmg"
echo "📦  Building ${DMG_NAME}  (version ${VERSION}, build ${BUILD}) …"

# ── Generate background image if it doesn't exist ────────────────────────────
BG_IMAGE="dmg_background.png"
if [[ ! -f "$BG_IMAGE" ]]; then
  echo "🎨  Background image not found — generating one …"
  if [[ -f "generate_dmg_bg.swift" ]]; then
    swift generate_dmg_bg.swift "$BG_IMAGE"
  else
    echo "    (generate_dmg_bg.swift not found — DMG will use default white background)"
    BG_IMAGE=""
  fi
fi

# ── Stage the app in a temp folder (create-dmg needs a source directory) ─────
STAGING=$(mktemp -d /tmp/cardrunner_dmg_staging.XXXXXX)
trap 'rm -rf "$STAGING"' EXIT

cp -R "$APP_PATH" "$STAGING/"

# ── Build the DMG ─────────────────────────────────────────────────────────────
DMG_ARGS=(
  --volname        "$APP_NAME"
  --volicon        "$APP_PATH/Contents/Resources/AppIcon.icns"
  --window-pos     200 120
  --window-size    660 400
  --icon-size      128
  --icon           "${APP_NAME}.app" 165 185
  --hide-extension "${APP_NAME}.app"
  --app-drop-link  495 185
  --no-internet-enable
)

if [[ -n "$BG_IMAGE" && -f "$BG_IMAGE" ]]; then
  DMG_ARGS+=(--background "$BG_IMAGE")
fi

# Remove stale output so create-dmg doesn't prompt to overwrite
[[ -f "$DMG_NAME" ]] && rm "$DMG_NAME"

create-dmg "${DMG_ARGS[@]}" "$DMG_NAME" "$STAGING"

echo ""
echo "✅  Done → $(pwd)/${DMG_NAME}"
echo "    Double-click it to verify the drag-to-Applications layout before distributing."
