#!/bin/bash
# run-ios-build.sh — `make ios-build` backend.
# generate → preflight → PlainsongIOS Debug simulator build, signing disabled,
# per-head/run isolated DerivedData. Acquires the shared lock for the whole run.
set -euo pipefail
cd "$(dirname "$0")/../.."
source Scripts/ios/ios-common.sh
ios_lock_or_exec "$0" "$@"
if [ "${1:-}" = "--locked" ]; then shift; fi

: "${IOS_OUTPUT_ROOT:=/private/tmp/plainsong-ios-release}"
export IOS_OUTPUT_ROOT

# Tool/env checks first so a missing SDK or lock misconfig fails before generate.
Scripts/ios/ios-preflight.sh --need-simulator ${IOS_EVIDENCE_DIR:+--write-evidence "$IOS_EVIDENCE_DIR"}

xcodegen generate

{ IFS= read -r output_root; IFS= read -r derived_data; IFS= read -r evidence; } < <(ios_output_dirs)
mkdir -p "$derived_data" "$evidence"

destination="$(ios_resolve_destination)" || exit $?
echo "ios-build: destination=$destination"

start_ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
set +e
xcodebuild -project Plainsong.xcodeproj -scheme PlainsongIOS -configuration Debug \
    -destination "$destination" -derivedDataPath "$derived_data" \
    CODE_SIGNING_ALLOWED=NO build > "$evidence/build.log" 2>&1
result=$?
set -e
end_ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

app=""
if [ "$result" = 0 ]; then
    app="$(find "$derived_data/Build/Products" -maxdepth 2 -name 'PlainsongIOS.app' -path '*iphonesimulator*' | head -1)"
    [ -n "$app" ] || { echo "ios: error: build succeeded but PlainsongIOS.app not found under $derived_data" >&2; result=3; }
fi
if [ -n "$app" ]; then
    exe="$app/PlainsongIOS"
    vtool -show-build "$exe" > "$evidence/macho-platform.txt" 2>&1 || true
    lipo -info "$exe" > "$evidence/archs.txt" 2>&1 || true
    ios_signing_state "$app" > "$evidence/signing-state.txt"
fi

ios_metadata "$evidence/build.json" \
    command="\"make ios-build\"" \
    source_sha="\"$(git rev-parse HEAD)\"" \
    source_dirty="$([ -n "$(git status --porcelain)" ] && echo true || echo false)" \
    scheme="\"PlainsongIOS\"" configuration="\"Debug\"" destination="\"$destination\"" \
    derived_data="\"$derived_data\"" app="\"${app:-}\"" \
    start="$start_ts" end="\"$end_ts\"" exit_code="$result"

echo "ios-build: exit=$result evidence=$evidence"
exit "$result"
