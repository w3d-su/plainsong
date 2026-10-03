#!/bin/bash
# Preserve the local combined test action; CI exposes bundle resources before execution.
set -euo pipefail
cd "$(dirname "$0")/.."
args=(-project Plainsong.xcodeproj -scheme Plainsong -configuration Debug)
if [ -n "${XCODE_DERIVED_DATA:-}" ]; then
    args+=(-derivedDataPath "$XCODE_DERIVED_DATA")
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
    bundle="$XCODE_DERIVED_DATA/Build/Products/Debug/Plainsong.app/Contents/PlugIns/PerformanceTests.xctest"
    /usr/bin/python3 Scripts/preflight-performance-resources.py \
        "$bundle" "$XCODE_ARTIFACT_DIR/performance-resources.json" \
        2>&1 | tee "$XCODE_ARTIFACT_DIR/preflight.log"
    test_action=test-without-building
fi
if [ -n "${XCODE_RESULT_BUNDLE:-}" ]; then
    mkdir -p "$(dirname "$XCODE_RESULT_BUNDLE")"
    run_xcode test -resultBundlePath "$XCODE_RESULT_BUNDLE" "$test_action"
else
    run_xcode test "$test_action"
fi
