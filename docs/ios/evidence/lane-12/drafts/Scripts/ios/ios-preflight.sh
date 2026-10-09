#!/bin/bash
# ios-preflight.sh — toolchain/environment gate for every public iOS runner.
# Fails early with explicit messages instead of guessing names or falling back.
# Usage: ios-preflight.sh [--need-simulator] [--write-evidence <dir>]
set -euo pipefail
cd "$(dirname "$0")/../.."
source Scripts/ios/ios-common.sh

need_simulator=0
evidence_dir=""
while [ $# -gt 0 ]; do
    case "$1" in
        --need-simulator) need_simulator=1 ;;
        --write-evidence) evidence_dir="${2:?--write-evidence needs a directory}"; shift ;;
        *) ios_die "unknown flag: $1" ;;
    esac
    shift
done

ios_require_tools xcodebuild xcodegen xcrun git plutil codesign vtool lipo ditto zip shasum /usr/bin/python3
ios_require_canonical_lock >/dev/null

xcode_version="$(xcodebuild -version | head -1)"
xcode_build="$(xcodebuild -version | sed -n 's/^Build version //p')"
iphoneos_sdk="$(ios_require_sdk iphoneos)"
iphonesimulator_sdk="$(ios_require_sdk iphonesimulator)"

runtime_count=0
if ios_simulator_runtime_present; then
    runtime_count="$(xcrun simctl list runtimes 2>/dev/null | grep -c "iOS" || true)"
fi

if [ "$need_simulator" = 1 ]; then
    [ "$runtime_count" -gt 0 ] || ios_die "no iOS simulator runtime installed — run 'xcodebuild -downloadPlatform iOS' (owner action; not performed by this script)"
    ios_first_available_simulator_id >/dev/null \
        || ios_die "iOS runtime present but no available iPhone device — create one or pass IOS_DESTINATION explicitly"
fi

head_sha="$(git rev-parse HEAD)"
dirty=no
[ -n "$(git status --porcelain)" ] && dirty=yes

echo "ios preflight: $xcode_version ($xcode_build)"
echo "  iphoneos SDK $iphoneos_sdk / iphonesimulator SDK $iphonesimulator_sdk (need >= 26.0)"
echo "  iOS simulator runtimes: $runtime_count; head: $head_sha (dirty=$dirty)"

if [ -n "$evidence_dir" ]; then
    ios_metadata "$evidence_dir/preflight.json" \
        xcode_version="\"$xcode_version\"" \
        xcode_build="\"$xcode_build\"" \
        iphoneos_sdk="\"$iphoneos_sdk\"" \
        iphonesimulator_sdk="\"$iphonesimulator_sdk\"" \
        simulator_runtimes="$runtime_count" \
        xcodegen="\"$(xcodegen --version 2>/dev/null || echo missing)\"" \
        source_sha="\"$head_sha\"" \
        source_dirty="$([ "$dirty" = yes ] && echo true || echo false)" \
        canonical_lock="\"$ios_canonical_lock\""
fi
