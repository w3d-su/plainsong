#!/bin/bash
# run-ios-ipa.sh — `make ios-ipa` backend.
# Packages the head-matched Release archive into an unsigned IPA:
# Products/Applications/PlainsongIOS.app → isolated staging Payload/ → strip and
# verify every nested signature → zip → .ipa + .ipa.sha256 + ipa-meta JSON.
# Never touches DerivedData, keychains, provisioning profiles or credentials,
# and never repackages an archive built for a different head.
set -euo pipefail
cd "$(dirname "$0")/../.."
source Scripts/ios/ios-common.sh
ios_lock_or_exec "$0" "$@"
if [ "${1:-}" = "--locked" ]; then shift; fi

output_root="${1:-${IOS_OUTPUT_ROOT:-/private/tmp/plainsong-ios-release}}"
head="$(git rev-parse HEAD)"
head12="${head:0:12}"

# Locate the archive for THIS head. IOS_ARCHIVE_PATH may pin one explicitly;
# a stale or foreign-head archive is an error — never repackage a previous round.
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
[ -n "$archive" ] || ios_die "no head-matched archive under $output_root" 3
[ "$(cat "$archive-meta/head" 2>/dev/null)" = "$head" ] \
    || ios_die "archive $archive was built for a different head — rerun make ios-archive (never repackage a previous round)" 3

app="$archive/Products/Applications/PlainsongIOS.app"
[ -d "$app" ] || ios_die "archive lacks Products/Applications/PlainsongIOS.app" 3

staging="$output_root/ipa-staging-$head12-$$"
payload="$staging/Payload"
ipa="$output_root/PlainsongIOS-$head12.ipa"
evidence="$output_root/ipa-meta-$head12"
mkdir -p "$payload" "$evidence"

ditto "$app" "$payload/PlainsongIOS.app"

# Strip signatures innermost-first: nested code, then the app. Any signature
# that survives removal fails the delivery — "unsigned" must match the artifact.
: > "$evidence/signing.txt"
strip_failed=0
while IFS= read -r bundle; do
    { ios_strip_signature "$bundle" || strip_failed=1; } >> "$evidence/signing.txt"
done < <(find "$payload/PlainsongIOS.app" \( -name '*.framework' -o -name '*.appex' -o -name '*.xctest' \) -type d | sort)
{ ios_strip_signature "$payload/PlainsongIOS.app" || strip_failed=1; } >> "$evidence/signing.txt"
find "$payload" \( -name '*.mobileprovision' -o -name '*.p12' -o -name '*.keychain' \) -print >> "$evidence/signing.txt"
[ "$strip_failed" = 0 ] || ios_die "could not remove all signatures in staging — see $evidence/signing.txt" 4

# Payload must contain only the app bundle; no signing material may remain.
strays="$(find "$payload" -mindepth 1 -maxdepth 1 ! -name 'PlainsongIOS.app' | wc -l | tr -d ' ')"
[ "$strays" = 0 ] || ios_die "unexpected files in Payload — refusing to zip" 4
leaks="$(find "$payload/PlainsongIOS.app" \( -name '*.mobileprovision' -o -name '*.p12' \) | wc -l | tr -d ' ')"
[ "$leaks" = 0 ] || ios_die "signing material still present inside the app bundle" 4

start_ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
(cd "$staging" && zip -qry "$ipa" Payload)
end_ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
ipa_sha="$(shasum -a 256 "$ipa" | cut -d' ' -f1)"
printf '%s  %s\n' "$ipa_sha" "$(basename "$ipa")" > "$ipa.sha256"
app_sha="$(shasum -a 256 "$payload/PlainsongIOS.app/PlainsongIOS" | cut -d' ' -f1)"
# Deterministic content digest for the archive: hash every member file with a
# path relative to the bundle, sort the manifest, hash the manifest.
archive_sha="$(cd "$archive" && find . -type f -exec shasum -a 256 {} + | LC_ALL=C sort -k2 | shasum -a 256 | cut -d' ' -f1)"
printf '%s  %s\n' "$archive_sha" "$(basename "$archive")" > "$archive.sha256"

ios_metadata "$evidence/ipa.json" \
    command="\"make ios-ipa\"" \
    source_sha="\"$head\"" \
    source_dirty="$([ -n "$(git status --porcelain)" ] && echo true || echo false)" \
    contract_version="\"$IOS_CONTRACT_VERSION\"" \
    ios_base_sha="\"$(git rev-parse ios-c0-v1 2>/dev/null || echo unknown)\"" \
    archive="\"$archive\"" archive_sha256="\"$archive_sha\"" \
    archive_app_executable_sha256="\"$app_sha\"" \
    ipa="\"$ipa\"" ipa_sha256="\"$ipa_sha\"" \
    ipa_bytes="$(stat -f %z "$ipa")" \
    signing_report="\"$evidence/signing.txt\"" \
    start="\"$start_ts\"" end="\"$end_ts\"" exit_code="0"

rm -rf "$staging"
echo "ios-ipa: $ipa"
echo "ios-ipa: sha256=$ipa_sha (unsigned; owner re-sign/install is a separate OPEN gate)"
