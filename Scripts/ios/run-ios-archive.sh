#!/bin/bash
# run-ios-archive.sh — `make ios-archive` backend.
# generic iOS arm64 Release archive with signing disabled, then verifies the
# archive is a device (not simulator) product carrying the required resources.
# Writes <name>.xcarchive plus <name>.xcarchive-meta/{head,archive.json,
# signing.txt,archive.log,macho-platform.txt,archs.txt,resources.json}.
set -euo pipefail
cd "$(dirname "$0")/../.."
source Scripts/ios/ios-common.sh
ios_lock_or_exec "$0" "$@"
if [ "${1:-}" = "--locked" ]; then shift; fi

output_root="${1:-${IOS_OUTPUT_ROOT:-/private/tmp/plainsong-ios-release}}"
manifest="${IOS_RESOURCE_MANIFEST:-Scripts/ios/required-app-resources.txt}"

# Device archive needs the iphoneos SDK but no simulator runtime.
Scripts/ios/ios-preflight.sh
[ -f "$manifest" ] || ios_die "required-resources manifest missing: $manifest" 65

xcodegen generate

head="$(git rev-parse HEAD)"
head12="${head:0:12}"
archive="$output_root/PlainsongIOS-$head12.xcarchive"
derived_data="$output_root/dd/$head12-archive-$$"
evidence="$archive-meta"
mkdir -p "$derived_data" "$evidence"

if [ -d "$archive" ] && [ "$(cat "$evidence/head" 2>/dev/null)" != "$head" ]; then
    ios_die "archive exists for a different head at $archive — refusing to mix artifacts (clean $output_root or fix head)" 65
fi

start_ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
set +e
xcodebuild -project Plainsong.xcodeproj -scheme PlainsongIOS -configuration Release \
    -destination 'generic/platform=iOS' -archivePath "$archive" \
    -derivedDataPath "$derived_data" \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO archive \
    > "$evidence/archive.log" 2>&1
result=$?
set -e
end_ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
tail -5 "$evidence/archive.log" >&2 || true

app="$archive/Products/Applications/PlainsongIOS.app"
if [ "$result" = 0 ] && [ ! -d "$app" ]; then
    echo "ios: error: archive missing $app" >&2; result=3
fi

if [ "$result" = 0 ]; then
    exe="$app/PlainsongIOS"
    # Must be an arm64 iphoneos device executable — a simulator slice fails here.
    vtool -show-build "$exe" > "$evidence/macho-platform.txt" 2>&1
    grep -q "platform IOS" "$evidence/macho-platform.txt" \
        || { echo "ios: error: $exe is not a device (IOS) Mach-O" >&2; cat "$evidence/macho-platform.txt" >&2; result=4; }
    lipo -info "$exe" > "$evidence/archs.txt" 2>&1
    grep -q "arm64" "$evidence/archs.txt" \
        || { echo "ios: error: $exe lacks arm64" >&2; cat "$evidence/archs.txt" >&2; result=4; }
fi

if [ "$result" = 0 ]; then
    /usr/bin/python3 Scripts/ios/ios-resource-preflight.py \
        --manifest "$manifest" --parity "App/Resources/preview:preview" \
        --root "$app" --report "$evidence/resources.json" || result=5
fi

# Signing state of every nested code bundle, plus the app itself. Unsigned is
# the expected state; anything else is recorded, never silently accepted.
: > "$evidence/signing.txt"
if [ -d "$app" ]; then
    while IFS= read -r bundle; do
        printf '%s\t%s\n' "$(ios_signing_state "$bundle")" "${bundle#$archive/}" >> "$evidence/signing.txt"
    done < <(find "$app" \( -name '*.framework' -o -name '*.appex' -o -name '*.xctest' \) -type d | sort)
    printf '%s\t%s\n' "$(ios_signing_state "$app")" "PlainsongIOS.app" >> "$evidence/signing.txt"
fi

printf '%s\n' "$head" > "$evidence/head"
ios_metadata "$evidence/archive.json" \
    command="\"make ios-archive\"" \
    source_sha="\"$head\"" \
    source_dirty="$([ -n "$(git status --porcelain)" ] && echo true || echo false)" \
    contract_version="\"$IOS_CONTRACT_VERSION\"" \
    ios_base_sha="\"$(git rev-parse ios-c0-v1 2>/dev/null || echo unknown)\"" \
    scheme="\"PlainsongIOS\"" configuration="\"Release\"" \
    destination="\"generic/platform=iOS\"" arch="\"arm64\"" \
    archive="\"$archive\"" start="\"$start_ts\"" end="\"$end_ts\"" exit_code="$result"

echo "ios-archive: exit=$result archive=$archive"
exit "$result"
