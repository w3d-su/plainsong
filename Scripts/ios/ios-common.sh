#!/bin/bash
# ios-common.sh — shared helpers for the lane-12 iOS runners (Scripts/ios/run-*.sh).
# Sourced, never executed directly. Exit codes follow the C0 bootstrap convention
# (Scripts/ios/c0.sh): 64 usage/config, 65 data error, 69 unavailable tool/SDK,
# 75 still pending on the shared lock. Codes >= 3 are step-specific failures.
#
# Lock discipline (docs/ios/README.md "同一台 Mac 的測試排程"): only the outermost
# public runner acquires the shared lock; inner helpers and --locked re-entries
# never re-acquire it. The path is fixed so every lane serializes on one file —
# a caller-supplied different lock path is refused, not silently unshared.

IOS_CANONICAL_LOCK=/private/tmp/plainsong-xcodebuild-test.lock
IOS_CONTRACT_VERSION=IOS-C0-v1

ios_die() { echo "ios: error: $1" >&2; exit "${2:-64}"; }

ios_require_canonical_lock() {
    if [ -n "${PLAINSONG_XCODEBUILD_LOCK:-}" ] && [ "$PLAINSONG_XCODEBUILD_LOCK" != "$IOS_CANONICAL_LOCK" ]; then
        ios_die "PLAINSONG_XCODEBUILD_LOCK must be '$IOS_CANONICAL_LOCK' for iOS runners (got '$PLAINSONG_XCODEBUILD_LOCK'); lock-path changes are coordinated across all lanes" 64
    fi
    echo "$IOS_CANONICAL_LOCK"
}

# Public-runner entry point: `ios_lock_or_exec "$0" "$@"`.
# With a leading --locked arg the runner is already inside the lock and this
# returns 0 (caller then shifts the flag). Otherwise the runner re-executes
# itself under `lockf -k -t 0` on the shared lock and never returns — same
# admission shape as Scripts/run-export-html-e9.sh: non-blocking probe, bounded
# retry, exit 75 while still pending; other runs are never killed.
ios_lock_or_exec() {
    local script="$1" lock_path
    shift
    lock_path="$(ios_require_canonical_lock)" || exit $?
    if [ "${1:-}" = "--locked" ]; then return 0; fi
    mkdir -p "$(dirname "$lock_path")"
    local deadline=$((SECONDS + 300))
    while true; do
        set +e
        lockf -k -t 0 "$lock_path" /bin/bash -c '
            "$@"; child=$?
            if [ "$child" = 1 ]; then exit 2; fi
            exit "$child"
        ' ios-runner "$script" --locked "$@"
        local result=$?
        set -e
        case "$result" in
            0|65) exit "$result" ;;
            1|75) ;;            # lock busy / tempfail: scheduling wait, retry
            *) exit "$result" ;;
        esac
        if [ "$SECONDS" -ge "$deadline" ]; then
            echo "ios: still pending; shared xcodebuild lock admission timeout" >&2
            exit 75
        fi
        sleep 30
    done
}

ios_require_tools() {
    local tool missing=0
    for tool in "$@"; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            echo "ios: error: required tool missing: $tool" >&2
            missing=1
        fi
    done
    [ "$missing" = 0 ] || exit 69
}

# Prints "<family> <version>" lines, e.g. "iphoneos 27.0".
ios_sdk_versions() {
    xcodebuild -showsdks 2>/dev/null | /usr/bin/python3 -c '
import re, sys
for line in sys.stdin:
    m = re.search(r"-sdk\s+(iphoneos|iphonesimulator)([0-9.]+)", line)
    if m:
        print(m.group(1), m.group(2))
'
}

# ios_require_sdk <iphoneos|iphonesimulator> → newest installed version, fail < 26.
ios_require_sdk() {
    local family="$1" version major
    version="$(ios_sdk_versions | awk -v f="$family" '$1 == f {print $2}' \
        | /usr/bin/python3 -c 'import sys; v=[s.strip() for s in sys.stdin if s.strip()]; print(max(v, key=lambda s: int(s.split(".")[0])) if v else "", end="")')"
    [ -n "$version" ] || ios_die "no $family SDK in the active toolchain (xcodebuild -showsdks); need iOS SDK >= 26" 69
    major="${version%%.*}"
    [ "$major" -ge 26 ] || ios_die "$family SDK is $version; need >= 26.0" 69
    echo "$version"
}

ios_available_ios_devices_json() {
    xcrun simctl list devices available --json 2>/dev/null
}

# Validate IOS_DESTINATION as a real installed iOS >= 26 simulator UUID.
# Mirrors the C0 check (Scripts/ios/c0.sh): exact format, runtime major >= 26,
# device marked available. Never guesses a name.
ios_validate_simulator_destination() {
    local dest="$1" udid
    case "$dest" in
        platform=iOS\ Simulator,id=*)
            udid="${dest##*,id=}"
            ;;
        *) ios_die "IOS_DESTINATION must be 'platform=iOS Simulator,id=<installed-uuid>' (got '$dest')" 64 ;;
    esac
    printf '%s' "$udid" | grep -qE '^[A-Fa-f0-9-]{36}$' \
        || ios_die "IOS_DESTINATION id is not a UUID: '$udid'" 64
    ios_available_ios_devices_json | /usr/bin/python3 -c '
import json, sys
udid = sys.argv[1].lower()
try:
    devices = json.load(sys.stdin)["devices"]
except Exception:
    sys.exit("ios: error: could not read simulator device list")
for runtime, entries in devices.items():
    if "iOS-" not in runtime:
        continue
    major = int(runtime.split("iOS-")[1].split("-")[0])
    if major >= 26 and any(d["udid"].lower() == udid and d.get("isAvailable") for d in entries):
        sys.exit(0)
sys.exit("ios: error: requested iOS >= 26 simulator UUID is not installed/available: " + udid)
' "$udid"
}

ios_print_simulator_hint() {
    echo "ios: available iOS >= 26 simulators:" >&2
    ios_available_ios_devices_json | /usr/bin/python3 -c '
import json, sys
try:
    devices = json.load(sys.stdin)["devices"]
except Exception:
    sys.exit(0)
for runtime, entries in sorted(devices.items(), reverse=True):
    if "iOS-" not in runtime:
        continue
    major = int(runtime.split("iOS-")[1].split("-")[0])
    if major < 26:
        continue
    for d in entries:
        if d.get("isAvailable"):
            print("  {}  id={}  ({})".format(d["name"], d["udid"], runtime), file=sys.stderr)
' >&2 || true
}

ios_signing_state() {
    local out
    if out="$(codesign -dv --verbose=2 "$1" 2>&1)"; then
        if printf '%s' "$out" | grep -q "^Authority="; then echo "signed"
        elif printf '%s' "$out" | grep -q "Signature=adhoc"; then echo "adhoc"
        else echo "signed"
        fi
    else
        echo "unsigned"
    fi
}

# Remove a signature from one bundle and verify removal took effect; also drop
# provisioning material. Prints "<bundle>\t<state-before>". Nonzero = the
# signature survived, which must fail an "unsigned" delivery.
ios_strip_signature() {
    local bundle="$1" before
    before="$(ios_signing_state "$bundle")"
    if [ "$before" != "unsigned" ]; then
        codesign --remove-signature "$bundle" 2>/dev/null || return 1
        rm -rf "$bundle/_CodeSignature" "$bundle/Contents/_CodeSignature" 2>/dev/null || true
        [ "$(ios_signing_state "$bundle")" = "unsigned" ] || return 1
    fi
    rm -f "$bundle/embedded.mobileprovision" "$bundle/Contents/embedded.mobileprovision" 2>/dev/null || true
    printf '%s\t%s\n' "$bundle" "$before"
}

# ios_metadata <out.json> <key=value> ... — JSON via python3 (values that are not
# JSON literals are stored as strings).
ios_metadata() {
    local out="$1"; shift
    mkdir -p "$(dirname "$out")"
    /usr/bin/python3 - "$out" "$@" <<'PY'
import json, sys
doc = {}
for pair in sys.argv[2:]:
    key, _, value = pair.partition("=")
    try:
        doc[key] = json.loads(value)
    except json.JSONDecodeError:
        doc[key] = value
with open(sys.argv[1], "w") as stream:
    json.dump(doc, stream, indent=2, sort_keys=True)
    stream.write("\n")
PY
}
