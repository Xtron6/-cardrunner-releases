#!/bin/bash
# release.sh — Build, sign, and publish a new CardRunner release
#
# What this does (in order):
#   1. Builds CardRunner.app via Xcode (Release config)
#   2. Wraps it into a DMG  (calls make_dmg.sh)
#   3. Signs the DMG with your Sparkle EdDSA key
#   4. Adds a new <item> to appcast.xml
#   5. Pushes appcast.xml to GitHub  (users' apps check this URL for updates)
#   6. Uploads the DMG as a GitHub Release asset
#
# Prerequisites (one-time):
#   brew install create-dmg gh
#   gh auth login
#
# Usage:
#   ./release.sh 1.1 "Fixed auto-ingest on Sonoma; improved transfer speeds"
#   ./release.sh 1.2 "Added Pro Tools dual-destination support"

set -euo pipefail

# ── Args ──────────────────────────────────────────────────────────────────────
VERSION="${1:-}"
RELEASE_NOTES="${2:-}"

if [[ -z "$VERSION" || -z "$RELEASE_NOTES" ]]; then
  echo "Usage: ./release.sh <version> \"<release notes>\""
  echo "  e.g. ./release.sh 1.1 \"Bug fixes and performance improvements\""
  exit 1
fi

# ── Pre-flight: prove the ingest path actually works before shipping ──────────
# Runs the real shell + cardcopy engine against synthetic cards and asserts files
# land and success/failure is reported correctly. This is the gate that would have
# caught the zsh int() bug that silently broke every transfer in a shipped build.
# Set SKIP_SMOKE=1 to bypass in an emergency (don't).
SCRIPT_ROOT="$(cd "$(dirname "$0")" && pwd)"
if [[ "${SKIP_SMOKE:-0}" != "1" ]]; then
  echo "🔬 Running smoke test before release…"
  if ! /bin/zsh "$SCRIPT_ROOT/smoke_test.sh"; then
    echo "❌ Smoke test FAILED — aborting release. The ingest path is broken."
    echo "   Fix it, or re-run with SKIP_SMOKE=1 to override (strongly discouraged)."
    exit 1
  fi
  echo ""
fi

# Unit tests — locks the success/failure gate + persisted-data decoders. Set
# SKIP_TESTS=1 to bypass in an emergency (don't).
if [[ "${SKIP_TESTS:-0}" != "1" ]]; then
  echo "🧪 Running unit tests before release…"
  if ! xcodebuild test -project "$SCRIPT_ROOT/CardRunner.xcodeproj" -scheme "CardRunner" \
        -destination 'platform=macOS' -only-testing:CardRunnerTests \
        CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
        >/tmp/cr_release_tests.log 2>&1; then
    echo "❌ Unit tests FAILED — aborting release. See /tmp/cr_release_tests.log"
    echo "   Fix them, or re-run with SKIP_TESTS=1 to override (strongly discouraged)."
    exit 1
  fi
  echo ""
fi

APP_NAME="CardRunner"
DMG_NAME="${APP_NAME}-${VERSION}.dmg"
SCHEME="CardRunner"
PROJECT="CardRunner.xcodeproj"
GITHUB_REPO="Xtron6/-cardrunner-releases"
APPCAST_FILE="appcast.xml"
DOWNLOAD_BASE="https://github.com/${GITHUB_REPO}/releases/download/v${VERSION}"

# Build number (CFBundleVersion) — must match sparkle:version in the appcast.
# Sparkle compares the *installed* app's CFBundleVersion against sparkle:version,
# NOT against sparkle:shortVersionString. Using the marketing version here was the
# root cause of silent update failures in 1.2 and 1.3.
# Read the value from the APP target specifically via -showBuildSettings. The old
# `grep ... | sort -n | tail -1` took the numeric max across ALL targets (app + both
# test targets), so a test target bumped above the app — or forgetting to bump the app —
# would silently ship a wrong sparkle:version. The scheme resolves the app target.
BUILD_NUMBER=$(xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Release \
  -showBuildSettings 2>/dev/null \
  | awk -F' = ' '/ CURRENT_PROJECT_VERSION =/ {print $2; exit}' | tr -d '[:space:]')
# Fallback to the legacy heuristic if showBuildSettings is unavailable.
if [[ -z "$BUILD_NUMBER" ]]; then
  BUILD_NUMBER=$(grep 'CURRENT_PROJECT_VERSION' "${PROJECT}/project.pbxproj" \
    | grep -o '[0-9]*' | sort -n | tail -1)
fi
if [[ -z "$BUILD_NUMBER" ]]; then
  echo "❌  Could not read CURRENT_PROJECT_VERSION for the ${SCHEME} target"
  exit 1
fi

# Guard: the new build number MUST exceed every integer sparkle:version already in the
# appcast, or Sparkle can mis-rank the update (the silent-failure class from 1.2/1.3).
# sparkle:version is an ELEMENT (<sparkle:version>20</sparkle:version>); match only
# pure-integer values (legacy "1.1"/"1.2" entries have a dot and are intentionally ignored).
HIGHEST_PUBLISHED=$(grep -oE '<sparkle:version>[0-9]+</sparkle:version>' "$APPCAST_FILE" 2>/dev/null \
  | grep -oE '[0-9]+' | sort -n | tail -1)
if [[ -n "${HIGHEST_PUBLISHED:-}" && "$BUILD_NUMBER" -le "$HIGHEST_PUBLISHED" ]]; then
  echo "❌  Build number $BUILD_NUMBER is not greater than the highest published"
  echo "    sparkle:version ($HIGHEST_PUBLISHED). Bump CURRENT_PROJECT_VERSION for the"
  echo "    ${SCHEME} target before releasing, or this update may not be offered."
  exit 1
fi
echo "    Build number : ${BUILD_NUMBER}  (sparkle:version — must be unique per release)"

# ── Locate Sparkle tools (pulled in by SPM — path includes a hash) ────────────
SPARKLE_BIN=$(find ~/Library/Developer/Xcode/DerivedData \
  -path "*/artifacts/sparkle/Sparkle/bin" -type d 2>/dev/null | head -1)
if [[ -z "$SPARKLE_BIN" ]]; then
  echo "❌  Sparkle tools not found. Open the project in Xcode once to resolve SPM packages."
  exit 1
fi

# ── Check dependencies ────────────────────────────────────────────────────────
for cmd in create-dmg gh xcodebuild; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "❌  '$cmd' not found."
    [[ "$cmd" == "create-dmg" || "$cmd" == "gh" ]] && echo "    Run: brew install $cmd"
    [[ "$cmd" == "gh" ]] && echo "    Then: gh auth login"
    exit 1
  fi
done

echo "🚀  Releasing CardRunner ${VERSION}"
echo "    Notes: ${RELEASE_NOTES}"
echo ""

# ── Step 1: Build ─────────────────────────────────────────────────────────────
echo "📐  Building ${APP_NAME}.app …"
BUILD_DIR="$(mktemp -d /tmp/cardrunner_build.XXXXXX)"
trap 'rm -rf "$BUILD_DIR"' EXIT

xcodebuild \
  -project "$PROJECT" \
  -scheme  "$SCHEME" \
  -configuration Release \
  -archivePath "$BUILD_DIR/${APP_NAME}.xcarchive" \
  archive \
  MARKETING_VERSION="$VERSION" \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  -quiet

# Write export options to a real temp file (xcodebuild can't read process substitutions)
EXPORT_PLIST="$BUILD_DIR/ExportOptions.plist"
cat > "$EXPORT_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>developer-id</string>
    <key>teamID</key>
    <string>XR77568XGP</string>
</dict>
</plist>
PLIST

# Export the .app from the archive
xcodebuild \
  -exportArchive \
  -archivePath "$BUILD_DIR/${APP_NAME}.xcarchive" \
  -exportPath  "$BUILD_DIR/export" \
  -exportOptionsPlist "$EXPORT_PLIST" \
  -quiet

APP_PATH="$BUILD_DIR/export/${APP_NAME}.app"
echo "✅  Built → $APP_PATH"

# ── Step 2: Make DMG ──────────────────────────────────────────────────────────
echo ""
echo "📦  Building ${DMG_NAME} …"
./make_dmg.sh "$APP_PATH"
echo "✅  DMG ready"

# ── Step 2b: Notarize the DMG ─────────────────────────────────────────────────
# Without notarization macOS Ventura/Sequoia blocks the app with a hard error
# ("Apple cannot verify…") and users cannot open it without a workaround.
#
# One-time setup — run this once, then release.sh handles it automatically:
#   xcrun notarytool store-credentials "CardRunner-Notary" \
#     --apple-id "you@example.com" \
#     --team-id "XR77568XGP" \
#     --password "xxxx-xxxx-xxxx-xxxx"   ← app-specific password from appleid.apple.com
echo ""
echo "📋  Notarizing ${DMG_NAME}  (takes 1–3 min) …"

if ! xcrun notarytool submit "$DMG_NAME" \
       --keychain-profile "CardRunner-Notary" \
       --wait 2>&1; then
  echo "❌  Notarization failed."
  echo "    Run the one-time setup above, then try again."
  exit 1
fi

xcrun stapler staple "$DMG_NAME"
echo "✅  Notarized + stapled"

# ── Step 3: Sign DMG with Sparkle EdDSA key ───────────────────────────────────
echo ""
echo "🔑  Signing DMG …"
SIGNATURE=$("$SPARKLE_BIN/sign_update" "$DMG_NAME" 2>/dev/null \
  | grep -o 'sparkle:edSignature="[^"]*"' \
  | sed 's/sparkle:edSignature="//;s/"//')

if [[ -z "$SIGNATURE" ]]; then
  # sign_update on some versions prints the signature directly
  SIGNATURE=$("$SPARKLE_BIN/sign_update" "$DMG_NAME" 2>/dev/null || true)
fi

if [[ -z "$SIGNATURE" ]]; then
  echo "❌  Signing failed. Make sure your EdDSA private key is in the keychain."
  echo "    Run: ${SPARKLE_BIN}/generate_keys  (to check / recreate)"
  exit 1
fi

FILE_SIZE=$(stat -f%z "$DMG_NAME")
PUB_DATE=$(date -u "+%a, %d %b %Y %H:%M:%S +0000")
echo "✅  Signed  (sig: ${SIGNATURE:0:20}…)"

# ── Step 4: Update appcast.xml ────────────────────────────────────────────────
echo ""
echo "📝  Updating ${APPCAST_FILE} …"

# Convert pipe-separated notes into clean HTML bullet list.
# No sparkle:releaseNotesLink — inline HTML renders directly in Sparkle's
# update sheet without loading any external URL (no GitHub chrome, no webview).
python3 - <<PYEOF
import sys

version      = "${VERSION}"
build_number = "${BUILD_NUMBER}"
pub_date     = "${PUB_DATE}"
notes_raw    = """${RELEASE_NOTES}"""
download_url = "${DOWNLOAD_BASE}/${DMG_NAME}"
signature    = "${SIGNATURE}"
file_size    = "${FILE_SIZE}"
appcast_file = "${APPCAST_FILE}"
github_repo  = "${GITHUB_REPO}"

# Build HTML bullet list from "|"-separated note items
items_html = "".join(
    f"<li>{item.strip()}</li>"
    for item in notes_raw.split("|")
    if item.strip()
)
html = (
    "<html><head><style>"
    "body{font-family:-apple-system,BlinkMacSystemFont,'SF Pro Text',sans-serif;"
    "font-size:13px;color:#1c1c1e;background:#fff;margin:0;padding:14px 18px 10px;line-height:1.6}"
    "ul{margin:0;padding-left:18px}li{margin-bottom:6px}b{color:#6d28d9}"
    "</style></head><body>"
    f"<ul>{items_html}</ul>"
    "</body></html>"
)

new_item = f"""        <item>
            <title>Version {version}</title>
            <pubDate>{pub_date}</pubDate>
            <sparkle:version>{build_number}</sparkle:version>
            <sparkle:shortVersionString>{version}</sparkle:shortVersionString>
            <description><![CDATA[{html}]]></description>
            <enclosure
                url="{download_url}"
                sparkle:edSignature="{signature}"
                length="{file_size}"
                type="application/octet-stream" />
        </item>"""

with open(appcast_file, "r") as f:
    content = f.read()

marker = "        <!-- ── Each new release"
if marker in content:
    content = content.replace(marker, new_item + "\n\n" + marker)
else:
    content = content.replace("    </channel>", new_item + "\n    </channel>")

with open(appcast_file, "w") as f:
    f.write(content)

print(f"  Added item for v{version}")
PYEOF

echo "✅  appcast.xml updated"

# ── Step 5: Push appcast.xml to GitHub ───────────────────────────────────────
echo ""
echo "⬆️   Pushing appcast.xml to GitHub …"

# Make sure we're in the right git context for the releases repo
# (We push just the appcast.xml file to the releases repo)
RELEASES_DIR="$(mktemp -d /tmp/cardrunner_releases.XXXXXX)"
trap 'rm -rf "$BUILD_DIR" "$RELEASES_DIR"' EXIT

gh repo clone "$GITHUB_REPO" "$RELEASES_DIR" -- --quiet
cp "$APPCAST_FILE" "$RELEASES_DIR/appcast.xml"

cd "$RELEASES_DIR"
git add appcast.xml
git commit -m "Release v${VERSION}" --quiet
git push --quiet
cd - > /dev/null

echo "✅  appcast.xml live at:"
echo "    https://raw.githubusercontent.com/${GITHUB_REPO}/refs/heads/main/appcast.xml"

# ── Step 6: Create GitHub Release + upload DMG ───────────────────────────────
echo ""
echo "🚀  Creating GitHub Release v${VERSION} …"
cd "$(dirname "$0")"

gh release create "v${VERSION}" \
  --repo "$GITHUB_REPO" \
  --title "CardRunner ${VERSION}" \
  --notes "$RELEASE_NOTES" \
  "$DMG_NAME"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✅  CardRunner ${VERSION} shipped!"
echo ""
echo "   DMG download : https://github.com/${GITHUB_REPO}/releases/download/v${VERSION}/${DMG_NAME}"
echo "   Appcast      : https://raw.githubusercontent.com/${GITHUB_REPO}/refs/heads/main/appcast.xml"
echo ""
echo "   Existing users will see the update prompt on next app launch."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
