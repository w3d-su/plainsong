#!/bin/bash
# Preserve the local combined test action; CI exposes bundle resources before execution.
# XCODE_TEST_TARGETS (space-separated test bundle names) runs only those bundles so CI
# can split them across parallel jobs; unset keeps the scheme's full test set. Xcode
# still builds every bundle in the scheme: -only-testing only narrows execution.
# XCODE_SKIP_TESTS (space-separated bundles or Bundle/Class names) subtracts from that set.
# XCODE_TEST_PHASE lets CI build once and test on other machines: `build` stops after
# build-for-testing, and `test` runs the products already in XCODE_DERIVED_DATA, without
# the project. Unset does both here.
set -euo pipefail
cd "$(dirname "$0")/.."
# The package graph is the committed Package.resolved (Scripts/generate-project.sh):
# a build that would resolve anything else fails here instead of in a release.
args=(-project Plainsong.xcodeproj -scheme Plainsong -configuration Debug -onlyUsePackageVersionsFromResolvedFile)
if [ -n "${XCODE_DERIVED_DATA:-}" ]; then
    args+=(-derivedDataPath "$XCODE_DERIVED_DATA")
fi
phase="${XCODE_TEST_PHASE:-}"
if [ -n "$phase" ]; then
    : "${XCODE_ARTIFACT_DIR:?XCODE_TEST_PHASE requires an evidence directory}"
    : "${XCODE_DERIVED_DATA:?XCODE_TEST_PHASE requires isolated DerivedData}"
fi
if [ "$phase" = test ]; then
    xctestruns=("$XCODE_DERIVED_DATA"/Build/Products/*.xctestrun)
    if [ "${#xctestruns[@]}" -ne 1 ] || [ ! -f "${xctestruns[0]}" ]; then
        echo "Expected one .xctestrun in $XCODE_DERIVED_DATA/Build/Products, found: ${xctestruns[*]}" >&2
        exit 1
    fi
    args=(-xctestrun "${xctestruns[0]}" -destination "platform=macOS,arch=$(uname -m)" -derivedDataPath "$XCODE_DERIVED_DATA")
fi
test_args=()
runs_performance_tests=true
if [ -n "${XCODE_TEST_TARGETS:-}" ]; then
    runs_performance_tests=false
    for target in $XCODE_TEST_TARGETS; do
        test_args+=("-only-testing:$target")
        if [ "$target" = PerformanceTests ]; then
            runs_performance_tests=true
        fi
    done
fi
for target in ${XCODE_SKIP_TESTS:-}; do
    test_args+=("-skip-testing:$target")
done
run_xcode() {
    local log_name="$1"
    shift
    if [ -n "${XCODE_ARTIFACT_DIR:-}" ]; then
        mkdir -p "$XCODE_ARTIFACT_DIR"
        xcodebuild "${args[@]}" "$@" 2>&1 | tee "$XCODE_ARTIFACT_DIR/$log_name.log"
    else
        xcodebuild "${args[@]}" "$@"
    fi
}
# ExportHTMLOfflineTests reads the loopback request recorder's port and skips
# without it, so a run that did not start the recorder never checked that an
# export makes no network request. Start it for every run that executes tests.
if [ "$phase" != build ] && [ -z "${TEST_RUNNER_PLAINSONG_EXPORT_TEST_PROXY_PORT:-}" ]; then
    proxy_root="$(mktemp -d /private/tmp/plainsong-export-f-proxy.XXXXXX)"
    /usr/bin/python3 Scripts/export_html_network_proxy.py --port-file "$proxy_root/port" > "$proxy_root/proxy.log" 2>&1 &
    proxy_pid=$!
    trap 'kill "$proxy_pid" 2>/dev/null || true' EXIT
    for _ in {1..100}; do
        if [ -s "$proxy_root/port" ]; then break; fi
        sleep 0.05
    done
    if [ ! -s "$proxy_root/port" ]; then cat "$proxy_root/proxy.log" >&2; exit 1; fi
    TEST_RUNNER_PLAINSONG_EXPORT_TEST_PROXY_PORT="$(cat "$proxy_root/port")"
    export TEST_RUNNER_PLAINSONG_EXPORT_TEST_PROXY_PORT
fi
test_action=test
if [ -n "${XCODE_ARTIFACT_DIR:-}" ]; then
    : "${XCODE_DERIVED_DATA:?CI preflight requires isolated DerivedData}"
    if [ "$phase" != test ]; then
        run_xcode build-for-testing build-for-testing
    fi
    if [ "$phase" = build ]; then
        exit 0
    fi
    if [ "$runs_performance_tests" = true ]; then
        bundle="$XCODE_DERIVED_DATA/Build/Products/Debug/Plainsong.app/Contents/PlugIns/PerformanceTests.xctest"
        /usr/bin/python3 Scripts/preflight-performance-resources.py \
            "$bundle" "$XCODE_ARTIFACT_DIR/performance-resources.json" \
            2>&1 | tee "$XCODE_ARTIFACT_DIR/preflight.log"
    fi
    test_action=test-without-building
fi
test_args+=("$test_action")
if [ -n "${XCODE_RESULT_BUNDLE:-}" ]; then
    mkdir -p "$(dirname "$XCODE_RESULT_BUNDLE")"
    run_xcode test -resultBundlePath "$XCODE_RESULT_BUNDLE" "${test_args[@]}"
else
    run_xcode test "${test_args[@]}"
fi
