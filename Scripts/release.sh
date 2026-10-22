#!/bin/bash
# Plainsong release pipeline (docs/release-engineering-plan.md P1–P3):
# clean Release build (stripped, then signed) → notarize → staple → DMG →
# SHA-256 checksum, plus a zipped dSYM for symbolication.
# Artifacts land in build/release/. The dSYM zip is for crash symbolication
# only: CI keeps it as a workflow artifact, never as a public release asset.
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
EXECUTABLE_PATH="$APP_PATH/Contents/MacOS/Plainsong"
DSYM_PATH="$APP_PATH.dSYM"
if [[ "$UNSIGNED" == "1" ]]; then
    DMG_PATH="$OUT_DIR/Plainsong-$MARKETING_VERSION-$BUILD_NUMBER-unsigned.dmg"
else
    DMG_PATH="$OUT_DIR/Plainsong-$MARKETING_VERSION-$BUILD_NUMBER.dmg"
fi
# Named after the DMG so a crash report's build maps to one dSYM; no .sha256,
# so release.yml's checksum glob still matches only the DMG's.
DSYM_ZIP_PATH="${DMG_PATH%.dmg}.dSYM.zip"

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
# Strip the shipped executable (docs/decisions/2026-10-22-release-strips-symbols-keeps-dsym.md):
# the unstripped universal binary was 32.2 MiB, 14 MiB of it symbol tables.
# project.yml turns this switch into DEPLOYMENT_POSTPROCESSING=YES,
# STRIP_INSTALLED_PRODUCT=YES and STRIP_STYLE=all on the app target alone, so
# the build itself strips the way an archive does: Xcode writes the dSYM from
# the linked binary first, strips second and signs last, so the signature
# covers the stripped bytes. (Passing those STRIP_* settings here would apply
# them to every SwiftPM target too, and stripping their object files fails.)
STRIP_SETTINGS=(
    PLAINSONG_STRIP_SHIPPED_BINARY=YES
)
xcodebuild -project Plainsong.xcodeproj -scheme Plainsong -configuration Release \
    -derivedDataPath "$DERIVED_DATA" \
    MARKETING_VERSION="$MARKETING_VERSION" \
    CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
    "${SIGN_SETTINGS[@]}" \
    "${STRIP_SETTINGS[@]}" \
    clean build

echo "==> Verify code signature"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"

echo "==> Verify the dSYM matches the stripped executable"
if [[ ! -d "$DSYM_PATH" ]]; then
    echo "error: no dSYM at $DSYM_PATH; crash reports from this build could not be symbolicated" >&2
    exit 1
fi
# One "UUID: <uuid> (<arch>)" line per slice; compare the uuid/arch pairs only.
app_uuids="$(dwarfdump --uuid "$EXECUTABLE_PATH" | awk '{print $2, $3}' | sort)"
dsym_uuids="$(dwarfdump --uuid "$DSYM_PATH" | awk '{print $2, $3}' | sort)"
if [[ -z "$app_uuids" || "$app_uuids" != "$dsym_uuids" ]]; then
    echo "error: dSYM UUIDs do not match the executable" >&2
    echo "  executable: $app_uuids" >&2
    echo "  dSYM:       $dsym_uuids" >&2
    exit 1
fi
echo "$app_uuids" | sed 's/^/    /'
echo "    executable: $(stat -f%z "$EXECUTABLE_PATH") bytes"

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

echo "==> Archive dSYM (keep privately; not a release asset)"
rm -f "$DSYM_ZIP_PATH"
ditto -c -k --keepParent "$DSYM_PATH" "$DSYM_ZIP_PATH"

echo "==> Done: $DMG_PATH"
echo "    dSYM: $DSYM_ZIP_PATH (symbolication only; docs/release-engineering-plan.md P3)"
if [[ "$UNSIGNED" == "1" ]]; then
    echo "    Unsigned alpha: recipients must allow the app once via"
    echo "    System Settings > Privacy & Security > Open Anyway, or run:"
    echo "    xattr -d com.apple.quarantine /Applications/Plainsong.app"
fi
