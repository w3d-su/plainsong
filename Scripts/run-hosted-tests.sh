#!/bin/bash
# Preserve the local combined test action; CI exposes bundle resources before execution.
# XCODE_TEST_TARGETS (space-separated test bundle names) runs only those bundles so CI
# can split them across parallel jobs; unset keeps the scheme's full test set. Xcode
# still builds every bundle in the scheme: -only-testing only narrows execution.
set -euo pipefail
cd "$(dirname "$0")/.."
args=(-project Plainsong.xcodeproj -scheme Plainsong -configuration Debug)
if [ -n "${XCODE_DERIVED_DATA:-}" ]; then
    args+=(-derivedDataPath "$XCODE_DERIVED_DATA")
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
test_action=test
if [ -n "${XCODE_ARTIFACT_DIR:-}" ]; then
    : "${XCODE_DERIVED_DATA:?CI preflight requires isolated DerivedData}"
    run_xcode build-for-testing build-for-testing
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
