#!/bin/bash
# A receipt/head stamp is insufficient: verify source inputs, success and the
# complete artifact digest before staging, and again before atomic publication.
set -euo pipefail
cd "$(dirname "$0")/../.."
source Scripts/ios/ios-common.sh
ios_lock_or_exec "$0" "$@"
output_root="${1:-${IOS_OUTPUT_ROOT:-/private/tmp/plainsong-ios-release}}"
mkdir -p "$output_root"
output_root="$(cd "$output_root" && pwd -P)"
head="$(git rev-parse HEAD)"
head12="${head:0:12}"
archive="${IOS_ARCHIVE_PATH:-}"
if [ -z "$archive" ]; then
    archive="$(/usr/bin/python3 Scripts/ios/ios-provenance.py select-archive "$output_root")"
    if [ -z "$archive" ]; then
        # Legitimate nested operation inherits the verified lockf ancestry.
        Scripts/ios/run-ios-archive.sh "$output_root"
        archive="$(/usr/bin/python3 Scripts/ios/ios-provenance.py select-archive "$output_root")"
    fi
fi
[ -n "$archive" ] || ios_die "no successful current-source archive" 3
/usr/bin/python3 Scripts/ios/ios-provenance.py verify-archive "$archive"
app="$archive/Products/Applications/PlainsongIOS.app"
manifest="${IOS_RESOURCE_MANIFEST:-Scripts/ios/required-app-resources.txt}"
mkdir -p "$output_root/evidence"
evidence="$(mktemp -d "$output_root/evidence/ipa-$head12.XXXXXX")"
/usr/bin/python3 Scripts/ios/ios-resource-preflight.py \
    --manifest "$manifest" --parity 'App/Resources/preview:preview' \
    --root "$app" --report "$evidence/resources.json"
staging="$(mktemp -d "$output_root/ipa-staging-$head12.XXXXXX")"
trap 'rm -rf "$staging"' EXIT
mkdir -p "$staging/Payload"
ditto "$app" "$staging/Payload/PlainsongIOS.app"
: > "$evidence/signing.txt"
strip_failed=0
while IFS= read -r bundle; do
    { ios_strip_signature "$bundle" || strip_failed=1; } >> "$evidence/signing.txt"
done < <(find "$staging/Payload/PlainsongIOS.app" \( \( -name '*.framework' -o -name '*.appex' -o -name '*.xctest' \) -type d -o -name '*.dylib' -type f \) | sort -r)
{ ios_strip_signature "$staging/Payload/PlainsongIOS.app" || strip_failed=1; } >> "$evidence/signing.txt"
[ "$strip_failed" = 0 ] || ios_die "could not remove all signatures from this staging attempt" 4
ipa="$output_root/PlainsongIOS-$head12.ipa"
/usr/bin/python3 Scripts/ios/ios-packaging.py "$staging" "$ipa" \
    --archive "$archive" --report "$evidence/ipa.json"
echo "ios-ipa: $ipa (unsigned; device installation remains OPEN); evidence=$evidence"
