#!/bin/bash
# build_cardcopy.sh — Compile, link, sign, and install cardcopy
#
# Run this any time cardcopy.c changes. The resulting universal binary is
# placed in CardRunner/ where Xcode auto-bundles it as a resource.
#
# Usage: ./build_cardcopy.sh

set -euo pipefail

TEAM_ID="XR77568XGP"
SRC="cardcopy/cardcopy.c"
OUT_DIR="CardRunner"
BINARY="$OUT_DIR/cardcopy"

COMMON_FLAGS=(
    -O2
    -Wall
    -Wextra
    -framework CoreFoundation
    -framework Security
    -lresolv
    # CommonCrypto is part of libSystem on macOS — no explicit link needed
)

echo "🔨  Compiling cardcopy for arm64…"
clang -arch arm64 \
    -mmacosx-version-min=14.0 \
    "${COMMON_FLAGS[@]}" \
    "$SRC" -o /tmp/cardcopy_arm64

echo "🔨  Compiling cardcopy for x86_64…"
clang -arch x86_64 \
    -mmacosx-version-min=14.0 \
    "${COMMON_FLAGS[@]}" \
    "$SRC" -o /tmp/cardcopy_x86_64

echo "🔗  Creating universal binary…"
lipo -create /tmp/cardcopy_arm64 /tmp/cardcopy_x86_64 -output "$BINARY"

rm /tmp/cardcopy_arm64 /tmp/cardcopy_x86_64

echo "✍️   Signing with Developer ID ($TEAM_ID)…"
codesign \
    --force \
    --sign "Developer ID Application: Xavier Gallo ($TEAM_ID)" \
    --options runtime \
    --timestamp \
    "$BINARY"

echo ""
echo "✅  cardcopy installed → $BINARY"
lipo -info "$BINARY"
codesign -dv "$BINARY" 2>&1 | grep -E "Authority|TeamIdentifier|flags"
echo ""
echo "   Xcode will auto-bundle it on next build (PBXFileSystemSynchronizedRootGroup)."
echo "   Run ./release.sh to ship it to users via Sparkle."
