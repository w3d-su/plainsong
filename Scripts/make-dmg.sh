#!/bin/bash
# Build the distribution DMG: Plainsong.app + /Applications symlink, UDZO
# compressed (docs/release-engineering-plan.md P3). Plain hdiutil on purpose —
# adding create-dmg or similar needs a Decision Log entry.
set -euo pipefail

APP_PATH="${1:?usage: make-dmg.sh <path/to/Plainsong.app> <output.dmg>}"
DMG_PATH="${2:?usage: make-dmg.sh <path/to/Plainsong.app> <output.dmg>}"

if [[ ! -d "$APP_PATH" ]]; then
    echo "error: app bundle not found at $APP_PATH" >&2
    exit 1
fi

STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT

cp -R "$APP_PATH" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

rm -f "$DMG_PATH"
hdiutil create -volname "Plainsong" -srcfolder "$STAGING" -ov -format UDZO "$DMG_PATH"
