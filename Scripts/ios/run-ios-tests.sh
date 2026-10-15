#!/bin/bash
# run-ios-tests.sh — `make ios-test` backend.
# preflight → generate → simulator build-for-testing → enabled-plan and
# Mach-O xctest admission → non-empty resource manifest and byte parity →
# test-without-building (-parallel-testing-enabled NO). Logs, xcresult and the
# actual named tests land in the evidence dir; the xcodebuild exit code is
# preserved as this runner's exit code.
#
#   make ios-test IOS_DESTINATION='platform=iOS Simulator,id=<installed-uuid>'
#   make ios-acceptance IOS_DESTINATION='platform=iOS Simulator,id=<installed-uuid>'
#
# IOS_DESTINATION is required: a real installed iOS >= 26 simulator UUID —
# the suite is never run against an invented or generic destination.
# IOS_SCHEME selects PlainsongIOS (module suite) or IOSAcceptance (hosted
# scaffold smoke). The two required-name manifests are not interchangeable.
set -euo pipefail
cd "$(dirname "$0")/../.."
source Scripts/ios/ios-common.sh

scheme="${IOS_SCHEME:-PlainsongIOS}"
case "$scheme" in
    PlainsongIOS)
        required_tests="Scripts/ios/required-named-tests.txt"
        command_label="make ios-test"
        evidence_label="test"
        ;;
    IOSAcceptance)
        required_tests="docs/ios/evidence/validation/required-hosted-smoke.txt"
        command_label="make ios-acceptance"
        evidence_label="acceptance"
        ;;
    *)
        ios_die "unsupported IOS_SCHEME '$scheme'. A preview entry must use the PreviewKit-Package scheme and lane 07's required cases; this runner does not select a subset" 64
        ;;
esac
ios_lock_or_exec "$0" "$@"

output_root="${1:-${IOS_OUTPUT_ROOT:-/private/tmp/plainsong-ios-release}}"
manifest="${IOS_RESOURCE_MANIFEST:-Scripts/ios/required-test-resources.txt}"

Scripts/ios/ios-preflight.sh --need-simulator

[ -n "${IOS_DESTINATION:-}" ] \
    || { echo "ios: error: ios-test requires IOS_DESTINATION='platform=iOS Simulator,id=<installed-uuid>'" >&2; ios_print_simulator_hint; exit 64; }
ios_validate_simulator_destination "$IOS_DESTINATION" || { ios_print_simulator_hint; exit 64; }
destination="$IOS_DESTINATION"

[ -f "$manifest" ] || ios_die "required-resources manifest missing: $manifest" 65
if ! grep -qE '^[^#[:space:]]' "$manifest"; then
    ios_die "required-resources manifest is empty: $manifest" 65
fi
[ -s "$required_tests" ] || ios_die "required named-test manifest is missing or empty: $required_tests" 65

xcodegen generate

head="$(git rev-parse HEAD)"
head12="${head:0:12}"
stamp="$(date +%Y%m%d-%H%M%S)-$$"
derived_data="$output_root/dd/$head12-$evidence_label-$stamp"
evidence="$output_root/evidence/$head12-$evidence_label-$stamp"
mkdir -p "$derived_data" "$evidence"
Scripts/ios/ios-preflight.sh --need-simulator --write-evidence "$evidence"
/usr/bin/python3 Scripts/ios/ios-provenance.py capture "$evidence/source.json"

echo "$command_label: destination=$destination scheme=$scheme"
set +e
xcodebuild -project Plainsong.xcodeproj -scheme "$scheme" -configuration Debug \
    -sdk iphonesimulator -destination "$destination" -derivedDataPath "$derived_data" \
    -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
    build-for-testing > "$evidence/build-for-testing.log" 2>&1
result=$?
set -e
[ "$result" = 0 ] || { tail -10 "$evidence/build-for-testing.log" >&2; echo "$command_label: build-for-testing failed ($result)" >&2; exit "$result"; }

# Admission is before any test run. An empty plan or a library product is not
# tests compiled, even when xcodebuild returned zero.
if ! /usr/bin/python3 Scripts/ios/ios-test-admission.py \
    --derived-data "$derived_data" --scheme "$scheme" \
    --report "$evidence/admission.json"; then
    echo "$command_label: admission failed; not tests compiled" >&2
    exit 65
fi

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
xcodebuild -project Plainsong.xcodeproj -scheme "$scheme" -configuration Debug \
    -sdk iphonesimulator -destination "$destination" -derivedDataPath "$derived_data" \
    -parallel-testing-enabled NO -resultBundlePath "$evidence/Results.xcresult" \
    -collect-test-diagnostics on-failure -test-timeouts-enabled YES \
    -default-test-execution-time-allowance 120 -maximum-test-execution-time-allowance 180 \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
    test-without-building > "$evidence/test.log" 2>&1
result=$?
set -e
tail -10 "$evidence/test.log" >&2 || true

# Keep extraction failure and complete case statuses; a zero-test or all-skip
# action cannot become PASS simply because xcodebuild returned zero.
set +e
xcrun xcresulttool get test-results tests --path "$evidence/Results.xcresult" --format json \
    > "$evidence/test-results.json" 2> "$evidence/xcresulttool.err"
extraction_result=$?
set -e
if [ "$extraction_result" != 0 ]; then
    [ "$result" != 0 ] || result=65
else
    if ! /usr/bin/python3 Scripts/ios/ios-test-results.py "$evidence/test-results.json" \
        --required "$required_tests" \
        --report "$evidence/test-gate.json" --names "$evidence/named-tests.txt"; then
        [ "$result" != 0 ] || result=65
    fi
fi
if ! /usr/bin/python3 Scripts/ios/ios-provenance.py verify-source "$evidence/source.json"; then
    [ "$result" != 0 ] || result=65
fi
[ -f "$evidence/named-tests.txt" ] || : > "$evidence/named-tests.txt"

ios_metadata "$evidence/test.json" \
    command="\"$command_label\"" \
    source_sha="\"$head\"" \
    source_dirty="$([ -n "$(git status --porcelain)" ] && echo true || echo false)" \
    contract_version="\"$IOS_CONTRACT_VERSION\"" \
    ios_base_sha="\"$(git rev-parse ios-c0-v1 2>/dev/null || echo unknown)\"" \
    scheme="\"$scheme\"" configuration="\"Debug\"" destination="\"$destination\"" \
    source_fingerprint="\"$(/usr/bin/python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["source_fingerprint"])' "$evidence/source.json")\"" \
    collect_test_diagnostics="\"on-failure\"" test_timeouts_enabled=true \
    default_test_execution_time_allowance=120 maximum_test_execution_time_allowance=180 \
    manifest="\"$manifest\"" named_tests="$(wc -l < "$evidence/named-tests.txt" | tr -d ' ')" \
    exit_code="$result"

echo "$command_label: exit=$result evidence=$evidence"
exit "$result"
