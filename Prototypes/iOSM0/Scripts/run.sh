#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
lock_path="${PLAINSONG_XCODEBUILD_LOCK:-/private/tmp/plainsong-xcodebuild-test.lock}"
# Acquire before project generation, builds, simulator inventory, install or run.
# No nesting with another lock wrapper. A busy lock yields scheduling exit 75.
if [[ "${M0_LOCK_HELD:-0}" != 1 ]]; then
    if ! lockf -t 0 -k "$lock_path" true; then
        echo 'WAITING: shared Xcode lock is busy. Retry after the other lane finishes.' >&2
        exit 75
    fi
    exec lockf -t 0 -k "$lock_path" env M0_LOCK_HELD=1 "$0" "$@"
fi
cd "$root"
mode="${1:-help}"
shift || true
case "$mode" in
    help)
        echo 'run.sh inventory | core | mutation | build-tests | test <simulator-UDID> | ipa | launch <simulator-UDID> <built-app-path>'
        exit 0 ;;
    inventory|core|mutation|build-tests|test|ipa|launch) ;;
    *) echo "Unknown mode: $mode" >&2; exit 64 ;;
esac
attempt="$root/Artifacts/$(date -u +%Y%m%dT%H%M%SZ)-${mode}-$(uuidgen | cut -c1-8)"
mkdir -p "$attempt"
exec > >(tee "$attempt/run.log") 2>&1
python3 - "$root" "$attempt" "$mode" <<'PY'
import datetime, hashlib, json, pathlib, subprocess, sys
root, output, mode = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]), sys.argv[3]
files = sorted(p for p in root.rglob('*') if p.is_file() and not any(
    c in ('Artifacts', 'Generated') or c.endswith('.xcodeproj') for c in p.relative_to(root).parts))
hashes = {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest() for p in files}
manifest = dict(mode=mode, started_utc=datetime.datetime.now(datetime.timezone.utc).isoformat(),
    source_sha=subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip(),
    dirty=bool(subprocess.check_output(['git', 'status', '--porcelain'], text=True).strip()),
    prototype_files_sha256=hashes,
    fixture_sha256=hashes['Fixtures/m0.md'],
    xcode=subprocess.check_output(['xcodebuild', '-version'], text=True).strip())
(output/'manifest.json').write_text(json.dumps(manifest, indent=2)+'\n')
PY
trap 'result=$?; python3 - "$attempt" "$result" <<'"'"'PY'"'"'
import datetime, json, pathlib, sys
path = pathlib.Path(sys.argv[1])/"manifest.json"
manifest = json.loads(path.read_text())
manifest.update(exit_code=int(sys.argv[2]), ended_utc=datetime.datetime.now(datetime.timezone.utc).isoformat())
path.write_text(json.dumps(manifest, indent=2)+"\n")
PY
' EXIT
echo "Attempt artifacts: $attempt"
case "$mode" in
    inventory)
        xcodebuild -showsdks
        xcrun simctl list runtimes -j > "$attempt/runtimes-private.json"
        xcrun simctl list devices available -j > "$attempt/devices-private.json"
        python3 - "$attempt" <<'PY'
import json, pathlib, sys
path = pathlib.Path(sys.argv[1])
runtimes = json.loads((path/'runtimes-private.json').read_text()).get('runtimes', [])
devices = json.loads((path/'devices-private.json').read_text()).get('devices', {})
summary = dict(runtimes=[dict(name=r.get('name'), version=r.get('version'), available=r.get('isAvailable')) for r in runtimes],
    devices=[dict(runtime=runtime, name=d['name'], state=d['state']) for runtime, ds in devices.items() for d in ds])
(path/'inventory-redacted.json').write_text(json.dumps(summary, indent=2)+'\n')
print(json.dumps(summary, indent=2))
PY
        ;;
    core|mutation)
        source_path="$root/Sources/SaveLedger.swift"
        if [[ "$mode" == mutation ]]; then
            python3 - "$source_path" "$attempt/MutatedSaveLedger.swift" <<'PY'
import pathlib, sys
source = pathlib.Path(sys.argv[1]).read_text()
needle = 'savedSource = capture.source'
assert source.count(needle) == 1
pathlib.Path(sys.argv[2]).write_text(source.replace(needle, 'savedSource = source'))
PY
            source_path="$attempt/MutatedSaveLedger.swift"
        fi
        xcrun swiftc -swift-version 5 "$source_path" Scripts/CoreChecks.swift -o "$attempt/core-checks"
        if [[ "$mode" == core ]]; then
            "$attempt/core-checks"
        else
            if "$attempt/core-checks" > "$attempt/mutation.log" 2>&1; then
                echo 'FAIL: old-save baseline mutation escaped the checks'; exit 1
            fi
            cat "$attempt/mutation.log"
            if ! rg -q 'FAIL oldSaveLeavesNewRevisionDirty' "$attempt/mutation.log"; then
                echo 'FAIL: mutation did not fail at the expected invariant'; exit 1
            fi
            echo 'PASS: negative mutation detected at oldSaveLeavesNewRevisionDirty'
            python3 - "$root/Sources/SaveLedger.swift" "$attempt/MutatedUnicodeLedger.swift" <<'PY'
import pathlib, sys
source = pathlib.Path(sys.argv[1]).read_text()
needle = 'lhs.utf8.elementsEqual(rhs.utf8)'
assert source.count(needle) == 1
pathlib.Path(sys.argv[2]).write_text(source.replace(needle, 'lhs == rhs'))
PY
            xcrun swiftc -swift-version 5 "$attempt/MutatedUnicodeLedger.swift" Scripts/CoreChecks.swift -o "$attempt/unicode-mutation"
            if "$attempt/unicode-mutation" > "$attempt/unicode-mutation.log" 2>&1; then
                echo 'FAIL: canonical-equivalence mutation escaped the checks'; exit 1
            fi
            cat "$attempt/unicode-mutation.log"
            if ! rg -q 'FAIL unicodeBytesDefineDirty' "$attempt/unicode-mutation.log"; then
                echo 'FAIL: Unicode mutation did not fail at the expected invariant'; exit 1
            fi
            echo 'PASS: negative mutation detected at unicodeBytesDefineDirty'
        fi
        ;;
    build-tests|test|ipa)
        xcodegen generate --spec project.yml
        common=(-project PlainsongIOSM0.xcodeproj -scheme PlainsongIOSM0
            -derivedDataPath "$attempt/DerivedData" CODE_SIGNING_ALLOWED=NO)
        if [[ "$mode" == ipa ]]; then
            xcodebuild "${common[@]}" -configuration Release -destination 'generic/platform=iOS' build
            app="$attempt/DerivedData/Build/Products/Release-iphoneos/PlainsongIOSM0.app"
            python3 Scripts/package-ipa.py "$app" "$attempt/PlainsongIOSM0-unsigned.ipa"
        elif [[ "$mode" == build-tests ]]; then
            xcodebuild "${common[@]}" -configuration Debug -destination 'generic/platform=iOS Simulator' build-for-testing
            echo 'COMPILED ONLY: hosted simulator tests not executed.'
        else
            [[ $# == 1 ]] || { echo 'test requires an explicit simulator UDID' >&2; exit 64; }
            xcodebuild "${common[@]}" -configuration Debug -destination "platform=iOS Simulator,id=$1" \
                -parallel-testing-enabled NO -resultBundlePath "$attempt/Tests.xcresult" test
        fi
        ;;
    launch)
        [[ $# == 2 ]] || { echo 'launch requires simulator UDID and built app path' >&2; exit 64; }
        xcrun simctl install "$1" "$2"
        xcrun simctl launch "$1" dev.plainsong.ios-m0
        ;;
esac
echo "Complete: $attempt"
