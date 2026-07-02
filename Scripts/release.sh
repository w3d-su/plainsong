#!/bin/bash
# Plainsong release pipeline (docs/release-engineering-plan.md P1–P3):
# clean Release build → sign (Developer ID, hardened runtime) → notarize →
# staple → DMG → SHA-256 checksum. Artifacts land in build/release/.
#
# Required environment:
#   PLAINSONG_SIGNING_IDENTITY   e.g. "Developer ID Application: Name (TEAMID)"
#
# Notarization (required unless PLAINSONG_SKIP_NOTARIZE=1):
#   PLAINSONG_NOTARY_KEY_PATH    App Store Connect API key (.p8) path
#   PLAINSONG_NOTARY_KEY_ID      API key ID
#   PLAINSONG_NOTARY_ISSUER     API key issuer ID
#
# Optional:
#   PLAINSONG_MARKETING_VERSION  default: 0.1.0 (matches project.yml)
#   PLAINSONG_BUILD_NUMBER       default: git commit count on HEAD (monotonic, P0.5)
#   PLAINSONG_SKIP_NOTARIZE=1    local smoke run before P2 credentials exist;
#                                the resulting DMG is NOT distributable
set -euo pipefail

cd "$(dirname "$0")/.."

if [[ "$(uname)" != "Darwin" ]]; then
    echo "error: release.sh needs macOS (xcodebuild, notarytool, hdiutil)" >&2
    exit 1
fi

: "${PLAINSONG_SIGNING_IDENTITY:?set PLAINSONG_SIGNING_IDENTITY to your Developer ID Application identity (see docs/release-engineering-plan.md P1)}"

MARKETING_VERSION="${PLAINSONG_MARKETING_VERSION:-0.1.0}"
BUILD_NUMBER="${PLAINSONG_BUILD_NUMBER:-$(git rev-list --count HEAD)}"
OUT_DIR="build/release"
DERIVED_DATA="$OUT_DIR/DerivedData"
APP_PATH="$DERIVED_DATA/Build/Products/Release/Plainsong.app"
DMG_PATH="$OUT_DIR/Plainsong-$MARKETING_VERSION-$BUILD_NUMBER.dmg"

echo "==> Release $MARKETING_VERSION ($BUILD_NUMBER)"
mkdir -p "$OUT_DIR"

echo "==> Generate project"
xcodegen generate

echo "==> Build Release (hardened runtime, Developer ID)"
xcodebuild -project Plainsong.xcodeproj -scheme Plainsong -configuration Release \
    -derivedDataPath "$DERIVED_DATA" \
    MARKETING_VERSION="$MARKETING_VERSION" \
    CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="$PLAINSONG_SIGNING_IDENTITY" \
    ENABLE_HARDENED_RUNTIME=YES \
    OTHER_CODE_SIGN_FLAGS=--timestamp \
    clean build

echo "==> Verify code signature"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"

if [[ "${PLAINSONG_SKIP_NOTARIZE:-0}" == "1" ]]; then
    echo "==> Skipping notarization (PLAINSONG_SKIP_NOTARIZE=1); artifact is NOT distributable"
else
    : "${PLAINSONG_NOTARY_KEY_PATH:?set PLAINSONG_NOTARY_KEY_PATH to your App Store Connect API key (.p8)}"
    : "${PLAINSONG_NOTARY_KEY_ID:?set PLAINSONG_NOTARY_KEY_ID}"
    : "${PLAINSONG_NOTARY_ISSUER:?set PLAINSONG_NOTARY_ISSUER}"

    echo "==> Notarize"
    NOTARIZE_ZIP="$OUT_DIR/Plainsong-notarize.zip"
    rm -f "$NOTARIZE_ZIP"
    ditto -c -k --keepParent "$APP_PATH" "$NOTARIZE_ZIP"
    xcrun notarytool submit "$NOTARIZE_ZIP" \
        --key "$PLAINSONG_NOTARY_KEY_PATH" \
        --key-id "$PLAINSONG_NOTARY_KEY_ID" \
        --issuer "$PLAINSONG_NOTARY_ISSUER" \
        --wait

    echo "==> Staple and assess"
    xcrun stapler staple "$APP_PATH"
    spctl --assess --type execute --verbose=2 "$APP_PATH"
fi

echo "==> Package DMG"
Scripts/make-dmg.sh "$APP_PATH" "$DMG_PATH"

echo "==> Checksum"
shasum -a 256 "$DMG_PATH" | tee "$DMG_PATH.sha256"

echo "==> Done: $DMG_PATH"
