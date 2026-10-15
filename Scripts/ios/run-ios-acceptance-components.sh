#!/bin/bash
# Mac IOSAcceptanceHarness package. Not `make test` and not `make ios-test`.
# The canonical lock is acquired by ios_lock_or_exec. Callers must not pass
# --locked or set IOS_RUNNER_LOCK_*. There is no simulator and no XCResult.
set -euo pipefail
cd "$(dirname "$0")/../.."
source Scripts/ios/ios-common.sh
ios_lock_or_exec "$0" "$@"

output_root="${1:-${IOS_OUTPUT_ROOT:-/private/tmp/plainsong-ios-release}}"
required="docs/ios/evidence/validation/required-component-tests.txt"
[ -s "$required" ] || ios_die "required component manifest is missing or empty: $required" 65
if ! grep -qE '^[^#[:space:]]' "$required"; then
    ios_die "required component manifest has no names: $required" 65
fi
command -v swift >/dev/null 2>&1 || ios_die "swift is not installed" 69

head="$(git rev-parse HEAD)"
head12="${head:0:12}"
stamp="$(date +%Y%m%d-%H%M%S)-$$"
build_path="$output_root/dd/$head12-components-$stamp"
evidence="$output_root/evidence/$head12-components-$stamp"
mkdir -p "$build_path" "$evidence"
/usr/bin/python3 Scripts/ios/ios-provenance.py capture "$evidence/source.json"

echo "ios-acceptance-components: build_path=$build_path"
set +e
swift test --package-path IOSAcceptanceTests \
    --build-path "$build_path" \
    --scratch-path "$build_path" \
    > "$evidence/swift-test.log" 2>&1
result=$?
set -e
tail -15 "$evidence/swift-test.log" >&2 || true

if ! /usr/bin/python3 Scripts/ios/ios-component-results.py "$evidence/swift-test.log" \
    --required "$required" \
    --report "$evidence/component-gate.json" \
    --names "$evidence/named-tests.txt"; then
    [ "$result" != 0 ] || result=65
fi
if ! /usr/bin/python3 Scripts/ios/ios-provenance.py verify-source "$evidence/source.json"; then
    [ "$result" != 0 ] || result=65
fi
[ -f "$evidence/named-tests.txt" ] || : > "$evidence/named-tests.txt"

ios_metadata "$evidence/components.json" \
    command="\"make ios-acceptance-components\"" \
    source_sha="\"$head\"" \
    source_dirty="$([ -n "$(git status --porcelain)" ] && echo true || echo false)" \
    contract_version="\"$IOS_CONTRACT_VERSION\"" \
    scheme="\"IOSAcceptanceHarness\"" \
    result_format="\"swift-test-xctest-log\"" \
    source_fingerprint="\"$(/usr/bin/python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["source_fingerprint"])' "$evidence/source.json")\"" \
    manifest="\"$required\"" \
    named_tests="$(wc -l < "$evidence/named-tests.txt" | tr -d ' ')" \
    exit_code="$result"

echo "ios-acceptance-components: exit=$result evidence=$evidence"
exit "$result"
