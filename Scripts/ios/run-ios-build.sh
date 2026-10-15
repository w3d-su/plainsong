#!/bin/bash
# run-ios-build.sh — `make ios-build` backend.
# preflight → generate → PlainsongIOS Debug simulator build, signing disabled,
# per-head/run isolated DerivedData. Holds the shared lock for the whole run.
#
#   IOS_DESTINATION='platform=iOS Simulator,id=<installed-uuid>' make ios-build
#
# IOS_DESTINATION may be omitted: the build then targets
# 'generic/platform=iOS Simulator', which compiles without an installed runtime.
set -euo pipefail
cd "$(dirname "$0")/../.."
source Scripts/ios/ios-common.sh
ios_lock_or_exec "$0" "$@"

output_root="${1:-${IOS_OUTPUT_ROOT:-/private/tmp/plainsong-ios-release}}"

# Tool/SDK checks first so a missing toolchain fails before generate.
Scripts/ios/ios-preflight.sh

if [ -n "${IOS_DESTINATION:-}" ]; then
    ios_validate_simulator_destination "$IOS_DESTINATION" || { ios_print_simulator_hint; exit 64; }
    destination="$IOS_DESTINATION"
else
    destination='generic/platform=iOS Simulator'
fi

xcodegen generate

head="$(git rev-parse HEAD)"
head12="${head:0:12}"
stamp="$(date +%Y%m%d-%H%M%S)-$$"
derived_data="$output_root/dd/$head12-build-$stamp"
evidence="$output_root/evidence/$head12-build-$stamp"
mkdir -p "$derived_data" "$evidence"
Scripts/ios/ios-preflight.sh --write-evidence "$evidence"
/usr/bin/python3 Scripts/ios/ios-provenance.py capture "$evidence/source.json"

echo "ios-build: destination=$destination"
start_ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
set +e
xcodebuild -project Plainsong.xcodeproj -scheme PlainsongIOS -configuration Debug \
    -sdk iphonesimulator -destination "$destination" -derivedDataPath "$derived_data" \
    -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
    build > "$evidence/build.log" 2>&1
result=$?
set -e
end_ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
tail -5 "$evidence/build.log" >&2 || true

app=""
if [ "$result" = 0 ]; then
    app="$(find "$derived_data/Build/Products" -maxdepth 2 -name 'PlainsongIOS.app' -path '*iphonesimulator*' -print -quit)"
    [ -n "$app" ] || { echo "ios: error: build succeeded but PlainsongIOS.app not found under $derived_data" >&2; result=3; }
fi
if [ -n "$app" ]; then
    vtool -show-build "$app/PlainsongIOS" > "$evidence/macho-platform.txt" 2>&1 || true
    lipo -info "$app/PlainsongIOS" > "$evidence/archs.txt" 2>&1 || true
    ios_signing_state "$app" > "$evidence/signing-state.txt"
fi

if ! /usr/bin/python3 Scripts/ios/ios-provenance.py verify-source "$evidence/source.json"; then
    [ "$result" != 0 ] || result=65
fi

ios_metadata "$evidence/build.json" \
    command="\"make ios-build\"" \
    source_sha="\"$head\"" \
    source_dirty="$([ -n "$(git status --porcelain)" ] && echo true || echo false)" \
    contract_version="\"$IOS_CONTRACT_VERSION\"" \
    ios_base_sha="\"$(git rev-parse ios-c0-v1 2>/dev/null || echo unknown)\"" \
    scheme="\"PlainsongIOS\"" configuration="\"Debug\"" destination="\"$destination\"" \
    derived_data="\"$derived_data\"" app="\"${app:-}\"" \
    start="\"$start_ts\"" end="\"$end_ts\"" exit_code="$result"

echo "ios-build: exit=$result evidence=$evidence"
exit "$result"
