#!/bin/bash
# run-ios-tests.sh — `make ios-test` backend.
# preflight → generate → simulator build-for-testing → resource preflight →
# test-without-building (-parallel-testing-enabled NO). Logs, xcresult and the
# actual named tests land in the evidence dir; the xcodebuild exit code is
# preserved as this runner's exit code.
#
#   make ios-test IOS_DESTINATION='platform=iOS Simulator,id=<installed-uuid>'
#
# IOS_DESTINATION is required: a real installed iOS >= 26 simulator UUID —
# the suite is never run against an invented or generic destination.
set -euo pipefail
cd "$(dirname "$0")/../.."
source Scripts/ios/ios-common.sh
ios_lock_or_exec "$0" "$@"
if [ "${1:-}" = "--locked" ]; then shift; fi

output_root="${1:-${IOS_OUTPUT_ROOT:-/private/tmp/plainsong-ios-release}}"
manifest="${IOS_RESOURCE_MANIFEST:-Scripts/ios/required-test-resources.txt}"

Scripts/ios/ios-preflight.sh --need-simulator

[ -n "${IOS_DESTINATION:-}" ] \
    || { echo "ios: error: ios-test requires IOS_DESTINATION='platform=iOS Simulator,id=<installed-uuid>'" >&2; ios_print_simulator_hint; exit 64; }
ios_validate_simulator_destination "$IOS_DESTINATION" || { ios_print_simulator_hint; exit 64; }
destination="$IOS_DESTINATION"

[ -f "$manifest" ] || ios_die "required-resources manifest missing: $manifest" 65

xcodegen generate

head="$(git rev-parse HEAD)"
head12="${head:0:12}"
stamp="$(date +%Y%m%d-%H%M%S)-$$"
derived_data="$output_root/dd/$head12-test-$stamp"
evidence="$output_root/evidence/$head12-test-$stamp"
mkdir -p "$derived_data" "$evidence"

echo "ios-test: destination=$destination"
set +e
xcodebuild -project Plainsong.xcodeproj -scheme PlainsongIOS -configuration Debug \
    -sdk iphonesimulator -destination "$destination" -derivedDataPath "$derived_data" \
    -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
    build-for-testing > "$evidence/build-for-testing.log" 2>&1
result=$?
set -e
[ "$result" = 0 ] || { tail -10 "$evidence/build-for-testing.log" >&2; echo "ios-test: build-for-testing failed ($result)" >&2; exit "$result"; }

# Resource preflight: every manifest path + full preview-dir parity inside the
# built products. Roots: the host app plus every built .xctest bundle.
roots=()
while IFS= read -r found; do roots+=("$found"); done \
    < <(find "$derived_data/Build/Products" -maxdepth 3 \( -name '*.app' -o -name '*.xctest' \) -type d | sort)
# bash 3.2: expanding an empty array under set -u is an error, so test size first.
[ "${#roots[@]}" -gt 0 ] || ios_die "no .app/.xctest products under $derived_data/Build/Products" 3
root_args=(); for r in "${roots[@]}"; do root_args+=(--root "$r"); done
/usr/bin/python3 Scripts/ios/ios-resource-preflight.py \
    --manifest "$manifest" --parity "App/Resources/preview:preview" \
    "${root_args[@]}" --report "$evidence/resources.json" || exit $?

set +e
xcodebuild -project Plainsong.xcodeproj -scheme PlainsongIOS -configuration Debug \
    -sdk iphonesimulator -destination "$destination" -derivedDataPath "$derived_data" \
    -parallel-testing-enabled NO -resultBundlePath "$evidence/Results.xcresult" \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
    test-without-building > "$evidence/test.log" 2>&1
result=$?
set -e
tail -10 "$evidence/test.log" >&2 || true

# Named tests actually executed; an empty file is itself evidence of zero tests.
set +e
xcrun xcresulttool get test-results tests --path "$evidence/Results.xcresult" --format json \
    2>"$evidence/xcresulttool.err" | /usr/bin/python3 -c '
import json, sys
try:
    doc = json.load(sys.stdin)
except Exception:
    sys.exit(0)
def walk(node):
    if isinstance(node, dict):
        name = node.get("testName") or node.get("name")
        if "testStatus" in node or node.get("nodeType") == "Test Case":
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
    source_sha="\"$head\"" \
    source_dirty="$([ -n "$(git status --porcelain)" ] && echo true || echo false)" \
    contract_version="\"$IOS_CONTRACT_VERSION\"" \
    ios_base_sha="\"$(git rev-parse ios-c0-v1 2>/dev/null || echo unknown)\"" \
    scheme="\"PlainsongIOS\"" configuration="\"Debug\"" destination="\"$destination\"" \
    manifest="\"$manifest\"" named_tests="$(wc -l < "$evidence/named-tests.txt" | tr -d ' ')" \
    exit_code="$result"

echo "ios-test: exit=$result evidence=$evidence"
exit "$result"
