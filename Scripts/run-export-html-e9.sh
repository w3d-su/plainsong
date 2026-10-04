#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
lock_path="${PLAINSONG_XCODEBUILD_LOCK:-${TMPDIR:-/tmp}/plainsong-xcodebuild-test.lock}"
mkdir -p "$(dirname "$lock_path")"
if [ "${1:-}" != "--locked" ]; then
    deadline=$((SECONDS + 300))
    while true; do
        set +e
        lockf -k -t 0 "$lock_path" "$PWD/Scripts/run-export-html-e9.sh" --locked "$@"
        result=$?
        set -e
        case "$result" in
            0|65) exit "$result" ;;
            1|75) ;;
            *) exit "$result" ;;
        esac
        if [ "$SECONDS" -ge "$deadline" ]; then
            echo "still pending; quiet-machine admission timeout" >&2
            exit 75
        fi
        sleep 30
    done
fi
shift
smoke=0
mode=export
if [ "${1:-}" = "--smoke" ]; then smoke=1; shift; fi
case "${1:-}" in --plain) mode=plain; shift ;; --build-only) mode=build; shift ;; esac
configuration="${1:-Debug}"
case "$configuration" in Debug|Release) ;; *) echo "Usage: $0 [--smoke] [--plain|--build-only] Debug|Release" >&2; exit 2 ;; esac
stamp="$(date +%Y%m%d-%H%M%S)-$$"
evidence_root="${PLAINSONG_E9_EVIDENCE_ROOT:-/private/tmp/plainsong-export-f-e9}/$configuration-$mode-$stamp"
mkdir -p "$evidence_root"
set +e
/usr/bin/python3 - "$evidence_root/start.json" "$smoke" "$configuration" <<'CHECK'
import json,math,os,subprocess,sys
limit=float(os.environ.get('PLAINSONG_MAX_LOAD','6'))
if not math.isfinite(limit) or limit<=0: raise SystemExit('Invalid PLAINSONG_MAX_LOAD')
builds={}
for name in ('xcodebuild','swift-build','swift-frontend','clang','ld'):
    result=subprocess.run(['pgrep','-x',name],capture_output=True,text=True)
    if result.returncode not in (0,1): raise SystemExit(result.stderr)
    if result.returncode==0: builds[name]=result.stdout.splitlines()
data={'load':list(os.getloadavg()),'max_load':limit,'top_cpu':subprocess.check_output(['ps','-Ao','%cpu,comm','-r'],text=True).splitlines()[:6],'build_processes':builds,'product_sha':subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip(),'smoke':sys.argv[2]=='1','configuration':sys.argv[3],'release_testability_override':sys.argv[3]=='Release','scheme':'PerformanceTests'}
with open(sys.argv[1],'w') as stream: json.dump(data,stream,indent=2)
print(f"Export E9 quiet check: load {data['load'][0]:.2f}; ceiling {limit}; builds={builds}; evidence={os.path.dirname(sys.argv[1])}",flush=True)
# Smoke remains correctness-only and bypasses load, but never concurrent builds.
sys.exit(75 if builds or (sys.argv[2]!='1' and data['load'][0]>limit) else 0)
CHECK
admission=$?
set -e
if [ "$admission" != 0 ]; then
    echo "still pending; no performance samples recorded" >&2
    exit "$admission"
fi
product_sha="$(git rev-parse HEAD)"
build_root="${PLAINSONG_E9_BUILD_ROOT:-/private/tmp/plainsong-e9-build-$product_sha}"
derived_data="$build_root/$configuration"
mkdir -p "$derived_data"
test_settings=()
if [ "$configuration" = Release ]; then test_settings+=(ENABLE_TESTABILITY=YES); fi
build_marker="$derived_data/build-complete-PerformanceTests"
if [ ! -f "$build_marker" ]; then
    make generate
    set +e
    xcodebuild -project Plainsong.xcodeproj -scheme PerformanceTests -configuration "$configuration" \
        -destination 'platform=macOS' -parallel-testing-enabled NO -derivedDataPath "$derived_data" \
        "${test_settings[@]}" build-for-testing > "$evidence_root/build.log" 2>&1
    build_result=$?
    set -e
    /usr/bin/python3 - "$evidence_root/end.json" "$build_result" <<'BUILD_END'
import json,os,subprocess,sys
with open(sys.argv[1],'w') as stream:
    json.dump({'load':list(os.getloadavg()),'top_cpu':subprocess.check_output(['ps','-Ao','%cpu,comm','-r'],text=True).splitlines()[:6],'exit_code':int(sys.argv[2])},stream,indent=2)
BUILD_END
    if [ "$build_result" != 0 ]; then exit "$build_result"; fi
    touch "$build_marker"
    # Compilation changes load: re-enter through the same quiet checks before measuring.
    if [ "$mode" != build ]; then
        options=(--locked)
        if [ "$smoke" = 1 ]; then options+=(--smoke); fi
        if [ "$mode" = plain ]; then options+=(--plain); fi
        exec "$PWD/Scripts/run-export-html-e9.sh" "${options[@]}" "$configuration"
    fi
fi
if [ "$mode" = build ]; then
    if [ ! -f "$evidence_root/end.json" ]; then
        /usr/bin/python3 - "$evidence_root/end.json" <<'CACHE_END'
import json,os,subprocess,sys
with open(sys.argv[1],'w') as stream:
    json.dump({'load':list(os.getloadavg()),'top_cpu':subprocess.check_output(['ps','-Ao','%cpu,comm','-r'],text=True).splitlines()[:6],'exit_code':0,'reused_build':True},stream,indent=2)
CACHE_END
    fi
    echo "Build evidence: $evidence_root"
    exit 0
fi
filters=(-only-testing:PerformanceTests/ExportHTMLPerformanceTests -only-testing:PerformanceTests/AppBackedEditorPerformanceTests/testTypingDuringActiveHTMLExportStaysWithinTheExistingFrameBudget)
if [ "$mode" = plain ]; then
    filters=(-only-testing:PerformanceTests/AppBackedEditorPerformanceTests/testTypingWithoutHTMLExportForRecordedLoadComparison)
fi
set +e
TEST_RUNNER_PLAINSONG_EXPORT_E9_SMOKE="$smoke" TEST_RUNNER_PLAINSONG_RUN_EXPORT_E9=1 \
    xcodebuild -project Plainsong.xcodeproj -scheme PerformanceTests -configuration "$configuration" \
    -destination 'platform=macOS' -parallel-testing-enabled NO -derivedDataPath "$derived_data" \
    -resultBundlePath "$evidence_root/Results.xcresult" "${test_settings[@]}" test-without-building "${filters[@]}" \
    > "$evidence_root/run.log" 2>&1
result=$?
set -e
/usr/bin/python3 - "$evidence_root/end.json" "$result" <<'RECORD'
import json,os,subprocess,sys
with open(sys.argv[1],'w') as stream:
    json.dump({'load':list(os.getloadavg()),'top_cpu':subprocess.check_output(['ps','-Ao','%cpu,comm','-r'],text=True).splitlines()[:6],'exit_code':int(sys.argv[2])},stream,indent=2)
RECORD
printf 'Evidence: %s\n' "$evidence_root"
exit "$result"
