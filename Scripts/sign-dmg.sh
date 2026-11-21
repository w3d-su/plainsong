#!/bin/bash
# Signs the release DMG and, unless PLAINSONG_SKIP_NOTARIZE=1, notarizes, staples
# and assesses it.
#
# The app inside is already signed and stapled, but the DMG is the file a user
# downloads: unsigned, Gatekeeper has no ticket for the quarantined image itself and
# `spctl --assess --type open` rejects it. A step that fails stops the release;
# the checksum and the appcast are made from the DMG only after this returns.
#
# Usage: sign-dmg.sh <Plainsong.dmg>
# Needs PLAINSONG_SIGNING_IDENTITY, and for notarization PLAINSONG_NOTARY_KEY_PATH,
# PLAINSONG_NOTARY_KEY_ID and PLAINSONG_NOTARY_ISSUER (Scripts/release.sh).
set -euo pipefail

dmg="${1:?usage: sign-dmg.sh <Plainsong.dmg>}"
[[ -f "$dmg" ]] || { echo "error: $dmg does not exist" >&2; exit 1; }
: "${PLAINSONG_SIGNING_IDENTITY:?set PLAINSONG_SIGNING_IDENTITY to your Developer ID Application identity}"

echo "==> Sign DMG"
codesign --force --sign "$PLAINSONG_SIGNING_IDENTITY" --timestamp "$dmg"
codesign --verify --strict --verbose=2 "$dmg"

if [[ "${PLAINSONG_SKIP_NOTARIZE:-0}" == "1" ]]; then
    echo "==> Skipping DMG notarization (PLAINSONG_SKIP_NOTARIZE=1); artifact is NOT distributable"
    exit 0
fi
: "${PLAINSONG_NOTARY_KEY_PATH:?set PLAINSONG_NOTARY_KEY_PATH to your App Store Connect API key (.p8)}"
: "${PLAINSONG_NOTARY_KEY_ID:?set PLAINSONG_NOTARY_KEY_ID}"
: "${PLAINSONG_NOTARY_ISSUER:?set PLAINSONG_NOTARY_ISSUER}"

echo "==> Notarize DMG"
xcrun notarytool submit "$dmg" \
    --key "$PLAINSONG_NOTARY_KEY_PATH" \
    --key-id "$PLAINSONG_NOTARY_KEY_ID" \
    --issuer "$PLAINSONG_NOTARY_ISSUER" \
    --wait

echo "==> Staple and assess DMG"
xcrun stapler staple "$dmg"
xcrun stapler validate "$dmg"
spctl --assess --type open --context context:primary-signature --verbose=2 "$dmg"
