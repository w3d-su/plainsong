#!/bin/bash
# run-ios-tests.sh — `make ios-test` backend.
# generate → preflight → build-for-testing → resource preflight →
# test-without-building (-parallel-testing-enabled NO). Logs, xcresult and the
# actual named tests are written under the evidence dir; the xcodebuild exit
# code is preserved as this runner's exit code.
set -euo pipefail
cd "$(dirname "$0")/../.."
source Scripts/ios/ios-common.sh
ios_lock_or_exec "$0" "$@"
if [ "${1:-}" = "--locked" ]; then shift; fi

: "${IOS_OUTPUT_ROOT:=/private/tmp/plainsong-ios-release}"
export IOS_OUTPUT_ROOT
manifest="${IOS_RESOURCE_MANIFEST:-Scripts/ios/required-test-resources.txt}"

Scripts/ios/ios-preflight.sh --need-simulator
[ -f "$manifest" ] || ios_die "required-resources manifest missing: $manifest (expected from lane 11 / lane-12 wiring)"

xcodegen generate

{ IFS= read -r output_root; IFS= read -r derived_data; IFS= read -r evidence; } < <(ios_output_dirs)
mkdir -p "$derived_data" "$evidence"

destination="$(ios_resolve_destination)" || exit $?
echo "ios-test: destination=$destination"

set +e
xcodebuild -project Plainsong.xcodeproj -scheme PlainsongIOS -configuration Debug \
    -destination "$destination" -derivedDataPath "$derived_data" \
    CODE_SIGNING_ALLOWED=NO build-for-testing > "$evidence/build-for-testing.log" 2>&1
result=$?
set -e
[ "$result" = 0 ] || { echo "ios-test: build-for-testing failed ($result); see $evidence/build-for-testing.log" >&2; exit "$result"; }

# Resource preflight: every manifest path must exist inside the built test host.
host_app="$(find "$derived_data/Build/Products" -name 'PlainsongIOS.app' -path '*iphonesimulator*' | head -1)"
[ -n "$host_app" ] || ios_die "test host PlainsongIOS.app not found under $derived_data/Build/Products"
xctest_bundle="$(find "$host_app" -maxdepth 3 -name '*.xctest' | head -1)"
/usr/bin/python3 Scripts/ios/ios-resource-preflight.py \
    --manifest "$manifest" --root "$host_app" ${xctest_bundle:+--root "$xctest_bundle"} \
    --report "$evidence/resources.json" || exit $?

set +e
xcodebuild -project Plainsong.xcodeproj -scheme PlainsongIOS -configuration Debug \
    -destination "$destination" -derivedDataPath "$derived_data" \
    -parallel-testing-enabled NO -resultBundlePath "$evidence/Results.xcresult" \
    CODE_SIGNING_ALLOWED=NO test-without-building > "$evidence/test.log" 2>&1
result=$?
set -e

# Named tests actually executed (empty file is itself evidence of zero tests).
# xcresulttool verb list differs across Xcode releases; verify `get test-results`
# against the pinned toolchain at implementation time (ctx7/xcresulttool --help)
# and fall back to `get object --legacy` if the subcommand is absent.
set +e
xcrun xcresulttool get test-results tests --path "$evidence/Results.xcresult" --format json \
    2>/dev/null | /usr/bin/python3 -c '
import json, sys
try:
    doc = json.load(sys.stdin)
except Exception:
    sys.exit(0)
def walk(node):
    if isinstance(node, dict):
        name = node.get("testName") or node.get("name")
        if node.get("nodeType") == "Test Case" or "testStatus" in node:
            print(name or "?")
        for v in node.values():
            walk(v)
    elif isinstance(node, list):
        for v in node:
            walk(v)
walk(doc)
' | sort -u > "$evidence/named-tests.txt"
set -e

ios_metadata "$evidence/test.json" \
    command="\"make ios-test\"" \
    source_sha="\"$(git rev-parse HEAD)\"" \
    source_dirty="$([ -n "$(git status --porcelain)" ] && echo true || echo false)" \
    scheme="\"PlainsongIOS\"" configuration="\"Debug\"" destination="\"$destination\"" \
    manifest="\"$manifest\"" named_tests="$(wc -l < "$evidence/named-tests.txt" | tr -d ' ')" \
    exit_code="$result"

echo "ios-test: exit=$result evidence=$evidence"
exit "$result"
