#!/bin/bash
# ios-common.sh — lane 12 shared helpers (handoff docs/ios/handoffs/12-build-and-ipa.md).
# Sourced by Scripts/ios/run-*.sh; never executed directly.
#
# Lock discipline (docs/ios/README.md "同一台 Mac 的測試排程"):
#   only the outermost public runner acquires the shared lock. Inner helpers and
#   --locked re-entries never re-acquire it. The lock path is fixed so every lane
#   serializes on the same file; a caller-supplied different path is refused.

ios_canonical_lock=/private/tmp/plainsong-xcodebuild-test.lock

ios_die() { echo "ios: error: $*" >&2; exit "${IOS_DIE_CODE:-2}"; }

ios_require_canonical_lock() {
    if [ -n "${PLAINSONG_XCODEBUILD_LOCK:-}" ] && [ "$PLAINSONG_XCODEBUILD_LOCK" != "$ios_canonical_lock" ]; then
        ios_die "PLAINSONG_XCODEBUILD_LOCK must be '$ios_canonical_lock' for iOS runners" \
                "(got '$PLAINSONG_XCODEBUILD_LOCK'); lock-path changes are coordinated" \
                "across all lanes, not per-runner"
    fi
    echo "$ios_canonical_lock"
}

# Public-runner entry: `ios_lock_or_exec "$0" "$@"`.
# If already inside the lock (--locked), returns so the caller can shift and run.
# Otherwise re-executes the runner under `lockf -k` on the shared lock and never
# returns. Same admission shape as Scripts/run-export-html-e9.sh: non-blocking
# probe, bounded retry, exit 75 when still pending; we never kill another run.
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
            1|75) ;;            # lock busy / tempfail: report scheduling wait, retry
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
    [ "$missing" = 0 ] || exit 2
}

# Prints "sdkname version" for iphoneos / iphonesimulator SDKs, e.g. "iphoneos 27.0".
ios_sdk_versions() {
    xcodebuild -showsdks 2>/dev/null | /usr/bin/python3 -c '
import re, sys
for line in sys.stdin:
    m = re.search(r"-sdk\s+(iphoneos|iphonesimulator)([0-9.]+)", line)
    if m:
        print(m.group(1), m.group(2))
'
}

# ios_require_sdk <iphoneos|iphonesimulator> — fail early when missing or < 26.
ios_require_sdk() {
    local family="$1" version major
    # newest matching SDK; sort by major number (BSD sort has no -V)
    version="$(ios_sdk_versions | awk -v f="$family" '$1 == f {print $2}' \
        | /usr/bin/python3 -c 'import sys; print(max((v.strip() for v in sys.stdin), key=lambda v: int(v.split(".")[0])), end="")')"
    [ -n "$version" ] || ios_die "no $family SDK in active toolchain (xcodebuild -showsdks); need iOS SDK >= 26"
    major="${version%%.*}"
    [ "$major" -ge 26 ] || ios_die "$family SDK is $version; need >= 26.0"
    echo "$version"
}

ios_simulator_runtime_present() {
    xcrun simctl list runtimes 2>/dev/null | grep -q "iOS"
}

ios_first_available_simulator_id() {
    # Pick a real installed simulator: newest iOS runtime >= 26, first available
    # iPhone device. Never guess a device name (handoff: fail early, no guessing).
    xcrun simctl list -j devices available 2>/dev/null | /usr/bin/python3 -c '
import json, re, sys
data = json.load(sys.stdin)
runtimes = [r for r in data.get("devices", {})
            if re.search(r"iOS[- ](\d+)", r) and int(re.search(r"(\d+)", r.split("iOS")[-1]).group(1)) >= 26]
runtimes.sort(reverse=True)
for runtime in runtimes:
    for device in data["devices"][runtime]:
        if device.get("isAvailable") and "iPhone" in device.get("name", ""):
            print(device["udid"])
            sys.exit(0)
sys.exit(1)
'
}

# ios_resolve_destination → prints 'platform=iOS Simulator,id=<uuid>'.
# Honors IOS_DESTINATION verbatim after validating it resolves to a real
# installed destination; discovers one otherwise.
ios_resolve_destination() {
    local project_scheme_args=(-project Plainsong.xcodeproj -scheme PlainsongIOS)
    if [ -n "${IOS_DESTINATION:-}" ]; then
        local id
        id="$(printf '%s' "$IOS_DESTINATION" | sed -n 's/.*id=\([^,]*\).*/\1/p')"
        [ -n "$id" ] || ios_die "IOS_DESTINATION must include id=<uuid> (got '$IOS_DESTINATION')"
        if ! xcodebuild "${project_scheme_args[@]}" -showdestinations 2>/dev/null | grep -q "id:$id\b"; then
            echo "ios: error: IOS_DESTINATION id '$id' is not an installed destination" >&2
            echo "ios: available destinations:" >&2
            xcodebuild "${project_scheme_args[@]}" -showdestinations 2>&1 | grep -iE "iOS" >&2
            exit 2
        fi
        printf '%s\n' "$IOS_DESTINATION"
        return 0
    fi
    local udid
    udid="$(ios_first_available_simulator_id)" \
        || ios_die "no available iOS >= 26 simulator; install one (xcodebuild -downloadPlatform iOS) or pass IOS_DESTINATION='platform=iOS Simulator,id=<uuid>'"
    printf 'platform=iOS Simulator,id=%s\n' "$udid"
}

# Per-head/run isolated output dirs (handoff: 每 head/run 隔離 DerivedData).
# ios_output_dirs → prints "<root>" "<derived_data>" "<evidence>" one per line.
# Consume with the brace/read pattern (no mapfile on macOS bash 3.2):
#   { IFS= read -r root; IFS= read -r dd; IFS= read -r ev; } < <(ios_output_dirs)
ios_output_dirs() {
    local root="${IOS_OUTPUT_ROOT:?IOS_OUTPUT_ROOT required}" head stamp
    head="$(git rev-parse --short=12 HEAD)"
    stamp="$(date +%Y%m%d-%H%M%S)-$$"
    echo "$root"
    echo "$root/dd/$head-$stamp"
    echo "$root/evidence/$head-$stamp"
}

# Inspect signing state of a bundle: prints "signed" | "adhoc" | "unsigned".
ios_signing_state() {
    local out
    if out="$(codesign -dv --verbose=2 "$1" 2>&1)"; then
        if printf '%s' "$out" | grep -q "^Authority="; then echo "signed"
        elif printf '%s' "$out" | grep -q "Signature=adhoc"; then echo "adhoc"
        else echo "signed"   # verifiable but no Authority → still a signature
        fi
    else
        echo "unsigned"
    fi
}

# Remove a signature from one bundle; verify removal actually took effect.
# Returns nonzero when a signature survives — the IPA must not claim "unsigned".
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

# Write metadata JSON via python3 (same pattern as Scripts/run-export-html-e9.sh).
# ios_metadata <out.json> <key=value> ... — values must already be JSON literals
# or plain strings are auto-quoted.
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
