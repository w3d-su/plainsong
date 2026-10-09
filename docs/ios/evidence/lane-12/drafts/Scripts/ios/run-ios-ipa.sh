#!/bin/bash
# run-ios-ipa.sh — `make ios-ipa` backend.
# Packages the head-matched Release archive into an unsigned IPA:
#   Payload/PlainsongIOS.app copied to an isolated staging dir, nested signatures
#   and provisioning material removed-and-verified, zip → .ipa + .sha256 +
#   metadata JSON. Never touches DerivedData, keychains, or credentials.
set -euo pipefail
cd "$(dirname "$0")/../.."
source Scripts/ios/ios-common.sh
ios_lock_or_exec "$0" "$@"
if [ "${1:-}" = "--locked" ]; then shift; fi

output_root="${1:-${IOS_OUTPUT_ROOT:-/private/tmp/plainsong-ios-release}}"
head="$(git rev-parse HEAD)"
head12="$(git rev-parse --short=12 HEAD)"

# Locate the archive for THIS head. A pinned override may name the archive
# explicitly; a stale or foreign-head archive is an error, never repackaged.
archive="${IOS_ARCHIVE_PATH:-}"
if [ -z "$archive" ]; then
    for candidate in "$output_root"/PlainsongIOS-*.xcarchive; do
        [ -d "$candidate" ] || continue
        [ "$(cat "$candidate-meta/head" 2>/dev/null)" = "$head" ] && archive="$candidate"
    done
fi
if [ -z "$archive" ]; then
    echo "ios-ipa: no archive for head $head12; building one under the same lock" >&2
    Scripts/ios/run-ios-archive.sh --locked "$output_root"
    for candidate in "$output_root"/PlainsongIOS-*.xcarchive; do
        [ -d "$candidate" ] || continue
        [ "$(cat "$candidate-meta/head" 2>/dev/null)" = "$head" ] && archive="$candidate"
    done
fi
[ -n "$archive" ] || ios_die "still no head-matched archive under $output_root"
[ "$(cat "$archive-meta/head" 2>/dev/null)" = "$head" ] \
    || ios_die "archive $archive was built for a different head — rerun make ios-archive (never repackage a previous round)"

app="$archive/Products/Applications/PlainsongIOS.app"
[ -d "$app" ] || ios_die "archive lacks Products/Applications/PlainsongIOS.app"

staging="$output_root/ipa-staging-$head12-$$"
payload="$staging/Payload"
ipa="$output_root/PlainsongIOS-$head12.ipa"
evidence="$output_root/ipa-meta-$head12"
mkdir -p "$payload" "$evidence"

ditto "$app" "$payload/PlainsongIOS.app"

# Strip signatures bottom-up: nested code first, app last. Any signature that
# survives removal fails the delivery — "unsigned" must match the artifact.
: > "$evidence/signing.txt"
strip_failed=0
while IFS= read -r bundle; do
    { ios_strip_signature "$bundle" || strip_failed=1; } >> "$evidence/signing.txt"
done < <(find "$payload/PlainsongIOS.app" \( -name '*.framework' -o -name '*.appex' -o -name '*.xctest' \) -type d | sort)
{ ios_strip_signature "$payload/PlainsongIOS.app" || strip_failed=1; } >> "$evidence/signing.txt"
find "$payload" \( -name '*.mobileprovision' -o -name '*.p12' -o -name '*.keychain' \) -print >> "$evidence/signing.txt"
[ "$strip_failed" = 0 ] || ios_die "could not remove all signatures in staging — see $evidence/signing.txt"

# Payload must contain only the app bundle — no DerivedData, profiles, keys.
strays="$(find "$payload" -mindepth 1 -maxdepth 1 ! -name 'PlainsongIOS.app' | wc -l | tr -d ' ')"
[ "$strays" = 0 ] || ios_die "unexpected files in Payload — refusing to zip"
leaks="$(find "$payload/PlainsongIOS.app" \( -name '*.mobileprovision' -o -name '*.p12' \) | wc -l | tr -d ' ')"
[ "$leaks" = 0 ] || ios_die "signing material still present inside the app bundle"

start_ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
(cd "$staging" && zip -qry "$ipa" Payload)
end_ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
shasum -a 256 "$ipa" | awk '{print $1"  "basename("'"$ipa"'")}' > "$ipa.sha256"
ipa_sha="$(cut -d' ' -f1 "$ipa.sha256")"

ios_metadata "$evidence/ipa.json" \
    command="\"make ios-ipa\"" \
    source_sha="\"$head\"" \
    source_dirty="$([ -n "$(git status --porcelain)" ] && echo true || echo false)" \
    contract_version="\"IOS-C0-v1\"" \
    archive="\"$archive\"" ipa="\"$ipa\"" ipa_sha256="\"$ipa_sha\"" \
    ipa_bytes="$(stat -f %z "$ipa")" \
    signing_report="\"$evidence/signing.txt\"" \
    start="\"$start_ts\"" end="\"$end_ts\"" exit_code="0"

rm -rf "$staging"
echo "ios-ipa: $ipa"
echo "ios-ipa: sha256=$ipa_sha256 (unsigned; owner re-sign/install is a separate OPEN gate)"
