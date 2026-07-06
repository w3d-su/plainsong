#!/bin/bash
# Plainsong release pipeline (docs/release-engineering-plan.md P1–P3):
# clean Release build → sign → notarize → staple → DMG → SHA-256 checksum.
# Artifacts land in build/release/.
#
# Two modes:
#
# UNSIGNED alpha (P0 decision 2026-07-02: no Apple Developer Program yet):
#   PLAINSONG_UNSIGNED=1 make release
#   Ad-hoc signed only; Gatekeeper blocks first launch on other Macs (README
#   "Installing" documents the bypass). DMG is suffixed "-unsigned".
#
# Signed + notarized (once P1/P2 credentials exist):
#   PLAINSONG_SIGNING_IDENTITY   e.g. "Developer ID Application: Name (TEAMID)"
#   PLAINSONG_NOTARY_KEY_PATH    App Store Connect API key (.p8) path
#   PLAINSONG_NOTARY_KEY_ID      API key ID
#   PLAINSONG_NOTARY_ISSUER     API key issuer ID
#   PLAINSONG_SKIP_NOTARIZE=1    signed-but-unnotarized smoke run (NOT distributable)
#
# Optional (both modes):
#   PLAINSONG_MARKETING_VERSION  default: 0.1.0 (matches project.yml)
#   PLAINSONG_BUILD_NUMBER       default: git commit count on HEAD (monotonic, P0.5)
set -euo pipefail

cd "$(dirname "$0")/.."

if [[ "$(uname)" != "Darwin" ]]; then
    echo "error: release.sh needs macOS (xcodebuild, notarytool, hdiutil)" >&2
    exit 1
fi

UNSIGNED="${PLAINSONG_UNSIGNED:-0}"
if [[ "$UNSIGNED" != "1" ]]; then
    : "${PLAINSONG_SIGNING_IDENTITY:?set PLAINSONG_SIGNING_IDENTITY to your Developer ID Application identity, or use PLAINSONG_UNSIGNED=1 for the unsigned alpha path (docs/release-engineering-plan.md P1)}"
fi

MARKETING_VERSION="${PLAINSONG_MARKETING_VERSION:-0.1.0}"
BUILD_NUMBER="${PLAINSONG_BUILD_NUMBER:-$(git rev-list --count HEAD)}"
OUT_DIR="build/release"
DERIVED_DATA="$OUT_DIR/DerivedData"
APP_PATH="$DERIVED_DATA/Build/Products/Release/Plainsong.app"
if [[ "$UNSIGNED" == "1" ]]; then
    DMG_PATH="$OUT_DIR/Plainsong-$MARKETING_VERSION-$BUILD_NUMBER-unsigned.dmg"
else
    DMG_PATH="$OUT_DIR/Plainsong-$MARKETING_VERSION-$BUILD_NUMBER.dmg"
fi

echo "==> Release $MARKETING_VERSION ($BUILD_NUMBER)"
mkdir -p "$OUT_DIR"

echo "==> Generate project"
xcodegen generate

if [[ "$UNSIGNED" == "1" ]]; then
    echo "==> Build Release (UNSIGNED alpha: ad-hoc signature, no notarization)"
    SIGN_SETTINGS=(
        CODE_SIGN_STYLE=Automatic
        CODE_SIGN_IDENTITY=-
    )
else
    echo "==> Build Release (hardened runtime, Developer ID)"
    SIGN_SETTINGS=(
        CODE_SIGN_STYLE=Manual
        CODE_SIGN_IDENTITY="$PLAINSONG_SIGNING_IDENTITY"
        ENABLE_HARDENED_RUNTIME=YES
        OTHER_CODE_SIGN_FLAGS=--timestamp
    )
fi
xcodebuild -project Plainsong.xcodeproj -scheme Plainsong -configuration Release \
    -derivedDataPath "$DERIVED_DATA" \
    MARKETING_VERSION="$MARKETING_VERSION" \
    CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
    "${SIGN_SETTINGS[@]}" \
    clean build

echo "==> Verify code signature"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"

if [[ "$UNSIGNED" == "1" ]]; then
    echo "==> Skipping notarization (unsigned alpha); Gatekeeper will block first launch on other Macs"
elif [[ "${PLAINSONG_SKIP_NOTARIZE:-0}" == "1" ]]; then
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
# Compute inside the output dir so the .sha256 records only the filename;
# downloaders then verify with `shasum -c` next to the downloaded DMG.
(cd "$(dirname "$DMG_PATH")" && shasum -a 256 "$(basename "$DMG_PATH")") | tee "$DMG_PATH.sha256"

echo "==> Done: $DMG_PATH"
if [[ "$UNSIGNED" == "1" ]]; then
    echo "    Unsigned alpha: recipients must allow the app once via"
    echo "    System Settings > Privacy & Security > Open Anyway, or run:"
    echo "    xattr -d com.apple.quarantine /Applications/Plainsong.app"
fi
