#!/bin/bash
# ios-preflight.sh — toolchain/environment gate for the public iOS runners.
# Fails early with explicit messages instead of guessing names or falling back.
#
#   ios-preflight.sh [--need-simulator] [--write-evidence <dir>]
#
# --need-simulator additionally requires an installed iOS >= 26 runtime and at
# least one available device (ios-test). Not invoked under the shared lock by
# itself; callers run inside run-*.sh which already holds it.
set -euo pipefail
cd "$(dirname "$0")/../.."
source Scripts/ios/ios-common.sh

need_simulator=0
evidence_dir=""
while [ $# -gt 0 ]; do
    case "$1" in
        --need-simulator) need_simulator=1 ;;
        --write-evidence) evidence_dir="${2:?--write-evidence needs a directory}"; shift ;;
        *) ios_die "unknown flag: $1" 64 ;;
    esac
    shift
done

ios_require_tools xcodebuild xcodegen xcrun git plutil codesign vtool lipo ditto zip shasum /usr/bin/python3
ios_require_canonical_lock >/dev/null

xcode_version="$(xcodebuild -version)"; xcode_version="${xcode_version%%$'\n'*}"
xcode_build="$(xcodebuild -version | sed -n 's/^Build version //p')"
iphoneos_sdk="$(ios_require_sdk iphoneos)" || exit $?
iphonesimulator_sdk="$(ios_require_sdk iphonesimulator)" || exit $?

runtime_count="$(ios_available_ios_devices_json | /usr/bin/python3 -c '
import json, sys
try:
    devices = json.load(sys.stdin)["devices"]
except Exception:
    print(0)
    sys.exit(0)
n = 0
for runtime, entries in devices.items():
    if "iOS-" not in runtime:
        continue
    if int(runtime.split("iOS-")[1].split("-")[0]) >= 26:
        n += sum(1 for d in entries if d.get("isAvailable"))
print(n)
')"

if [ "$need_simulator" = 1 ] && [ "$runtime_count" = 0 ]; then
    ios_die "no available iOS >= 26 simulator — install a runtime with 'xcodebuild -downloadPlatform iOS' (owner/environment action; this script never downloads) then pass IOS_DESTINATION='platform=iOS Simulator,id=<installed-uuid>'" 69
fi

head_sha="$(git rev-parse HEAD)"
dirty=no
[ -n "$(git status --porcelain)" ] && dirty=yes

echo "ios preflight: $xcode_version ($xcode_build)"
echo "  iphoneos SDK $iphoneos_sdk / iphonesimulator SDK $iphonesimulator_sdk (need >= 26.0)"
echo "  available iOS>=26 simulator devices: $runtime_count; head: ${head_sha:0:12} (dirty=$dirty)"

if [ -n "$evidence_dir" ]; then
    ios_metadata "$evidence_dir/preflight.json" \
        xcode_version="\"$xcode_version\"" \
        xcode_build="\"$xcode_build\"" \
        iphoneos_sdk="\"$iphoneos_sdk\"" \
        iphonesimulator_sdk="\"$iphonesimulator_sdk\"" \
        available_simulators="$runtime_count" \
        xcodegen="\"$(xcodegen --version 2>/dev/null || echo missing)\"" \
        source_sha="\"$head_sha\"" \
        source_dirty="$([ "$dirty" = yes ] && echo true || echo false)" \
        contract_version="\"$IOS_CONTRACT_VERSION\"" \
        canonical_lock="\"$IOS_CANONICAL_LOCK\""
fi
