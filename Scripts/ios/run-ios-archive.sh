#!/bin/bash
# Build a unique device Release attempt; only successful, fingerprinted receipts
# may be consumed by ios-ipa. Failed attempts remain diagnostic evidence.
set -euo pipefail
cd "$(dirname "$0")/../.."
source Scripts/ios/ios-common.sh
ios_lock_or_exec "$0" "$@"
output_root="${1:-${IOS_OUTPUT_ROOT:-/private/tmp/plainsong-ios-release}}"
manifest="${IOS_RESOURCE_MANIFEST:-Scripts/ios/required-app-resources.txt}"
mkdir -p "$output_root"
output_root="$(cd "$output_root" && pwd -P)"
[ -f "$manifest" ] || ios_die "required-resources manifest missing: $manifest" 65
head="$(git rev-parse HEAD)"
run_root="$(mktemp -d "$output_root/archive-attempt-${head:0:12}.XXXXXX")"
archive="$run_root/PlainsongIOS.xcarchive"
evidence="$archive-meta"
mkdir -p "$evidence"
Scripts/ios/ios-preflight.sh --write-evidence "$evidence"
/usr/bin/python3 Scripts/ios/ios-provenance.py capture "$evidence/source.json"
xcodegen generate
start_ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
set +e
xcodebuild -project Plainsong.xcodeproj -scheme PlainsongIOS -configuration Release \
    -destination 'generic/platform=iOS' -archivePath "$archive" \
    -derivedDataPath "$run_root/DerivedData" \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO archive > "$evidence/archive.log" 2>&1
result=$?
set -e
app="$archive/Products/Applications/PlainsongIOS.app"
if [ "$result" = 0 ]; then
    /usr/bin/python3 Scripts/ios/ios-provenance.py verify-device "$app" || result=4
fi
if [ "$result" = 0 ]; then
    /usr/bin/python3 Scripts/ios/ios-resource-preflight.py \
        --manifest "$manifest" --parity 'App/Resources/preview:preview' \
        --root "$app" --report "$evidence/resources.json" || result=5
fi
if [ "$result" = 0 ]; then
    /usr/bin/python3 Scripts/ios/ios-provenance.py verify-source "$evidence/source.json" || result=65
fi
: > "$evidence/signing.txt"
if [ -d "$app" ]; then
    while IFS= read -r bundle; do
        state="$(ios_signing_state "$bundle")" || { result=4; state=unknown; }
        printf '%s\t%s\n' "$state" "${bundle#$archive/}" >> "$evidence/signing.txt"
    done < <(find "$app" \( -name '*.framework' -o -name '*.appex' -o -name '*.xctest' \) -type d | sort)
    state="$(ios_signing_state "$app")" || { result=4; state=unknown; }
    printf '%s\t%s\n' "$state" PlainsongIOS.app >> "$evidence/signing.txt"
fi
end_ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
/usr/bin/python3 Scripts/ios/ios-provenance.py record-archive "$archive" \
    --result "$result" --start "$start_ts" --end "$end_ts"
tail -5 "$evidence/archive.log" >&2 || true
echo "ios-archive: exit=$result archive=$archive"
exit "$result"
