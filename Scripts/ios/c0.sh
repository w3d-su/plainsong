#!/bin/bash
# C0 bootstrap only. Public invocation holds the same lock as every other lane.
set -euo pipefail

required_lock=/private/tmp/plainsong-xcodebuild-test.lock
requested_lock=${PLAINSONG_XCODEBUILD_LOCK:-$required_lock}
if [[ "$requested_lock" != "$required_lock" ]]; then
    echo "C0 requires the shared Plainsong Xcode lock: $required_lock" >&2
    exit 64
fi

if [[ "${1:-}" != --locked ]]; then
    exec /usr/bin/lockf -k "$required_lock" /bin/bash "$0" --locked "$@"
fi
shift
if [[ $# != 1 || ( "$1" != build && "$1" != test ) ]]; then
    echo "Usage: Scripts/ios/c0.sh build|test" >&2
    exit 64
fi

mode=$1
root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$root"
head=$(git rev-parse HEAD)
output_root=${IOS_C0_OUTPUT_ROOT:-/private/tmp/plainsong-ios-c0}
mkdir -p "$output_root"
run_root=$(mktemp -d "$output_root/$head-$mode.XXXXXX")
echo "C0 evidence: $run_root"
/usr/bin/python3 - "$run_root/source.json" "$head" "$mode" <<'PYMETA'
import json, subprocess, sys
json.dump({
    'sourceSHA': sys.argv[2],
    'dirty': bool(subprocess.check_output(['git', 'status', '--porcelain'])),
    'contractVersion': 'IOS-C0-v1',
    'mode': sys.argv[3],
    'scope': 'C0 declarations and unavailable scaffold; no device acceptance',
}, open(sys.argv[1], 'w'), indent=2)
PYMETA
xcodebuild -version > "$run_root/toolchain.txt"
xcodebuild -showsdks >> "$run_root/toolchain.txt"
if ! xcrun --sdk iphonesimulator --show-sdk-version > "$run_root/sdk.txt"; then
    echo "An iOS 26+ simulator SDK is required" >&2
    exit 69
fi
sdk_version=$(cat "$run_root/sdk.txt")
if [[ "${sdk_version%%.*}" -lt 26 ]]; then
    echo "An iOS 26+ simulator SDK is required, found $sdk_version" >&2
    exit 69
fi

destination='generic/platform=iOS Simulator'
if [[ "$mode" == test ]]; then
    # An explicit installed UUID is mandatory; never invent a simulator name.
    if [[ ! "${IOS_DESTINATION:-}" =~ ^platform=iOS\ Simulator,id=([A-Fa-f0-9-]{36})$ ]]; then
        echo "IOS_DESTINATION must be platform=iOS Simulator,id=<installed-uuid>" >&2
        exit 64
    fi
    destination=$IOS_DESTINATION
    xcrun simctl list devices available --json > "$run_root/devices.json"
    /usr/bin/python3 - "$run_root/devices.json" "${BASH_REMATCH[1]}" <<'PY'
import json, sys
devices = json.load(open(sys.argv[1]))['devices']
for runtime, entries in devices.items():
    if 'iOS-' not in runtime:
        continue
    major = int(runtime.split('iOS-')[1].split('-')[0])
    if major >= 26 and any(d['udid'].lower() == sys.argv[2].lower() and d.get('isAvailable') for d in entries):
        sys.exit(0)
sys.exit('Requested iOS 26+ simulator UUID is not installed/available')
PY
fi

make generate > "$run_root/generate.log" 2>&1
arguments=(
    -project Plainsong.xcodeproj -scheme PlainsongIOS -configuration Debug
    -sdk iphonesimulator -destination "$destination"
    -derivedDataPath "$run_root/DerivedData"
    -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO
)
xcodebuild "${arguments[@]}" build-for-testing 2>&1 | tee "$run_root/build.log"
/usr/bin/python3 - "$run_root/DerivedData/Build/Products/Debug-iphonesimulator/PlainsongIOS.app/preview" "$run_root/preview-resources.json" <<'PYRESOURCES'
import hashlib, json, pathlib, sys
preview = pathlib.Path(sys.argv[1])
source = pathlib.Path('App/Resources/preview')
records = {}
for file in source.rglob('*'):
    if not file.is_file():
        continue
    relative = file.relative_to(source)
    bundled = preview / relative
    original = hashlib.sha256(file.read_bytes()).hexdigest()
    actual = hashlib.sha256(bundled.read_bytes()).hexdigest()
    if actual != original:
        sys.exit('Bundled preview differs: ' + str(relative))
    records[str(relative)] = actual
if not records or not all(name in records for name in ['index.html', 'bundle.js', 'bundle.css']):
    sys.exit('Missing required preview resources')
json.dump(records, open(sys.argv[2], 'w'), indent=2, sort_keys=True)
PYRESOURCES

if [[ "$mode" == test ]]; then
    xcodebuild "${arguments[@]}" -resultBundlePath "$run_root/Results.xcresult" \
        test-without-building 2>&1 | tee "$run_root/test.log"
fi

