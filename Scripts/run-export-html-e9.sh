#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [ "${1:-}" != "--locked" ]; then
    exec lockf -k \
        /private/tmp/claude-501/-Users-davis---su-Documents-blogeditor/50f4130b-7177-4f95-827c-f97a63ad8e24/scratchpad/plainsong-xcodebuild-test.lock \
        "$PWD/Scripts/run-export-html-e9.sh" --locked "${1:-Debug}"
fi
configuration="${2:-Debug}"
case "$configuration" in Debug|Release) ;; *) echo "Usage: $0 Debug|Release" >&2; exit 2 ;; esac
load_average="$(sysctl -n vm.loadavg)"
if ! /usr/bin/python3 - "$load_average" <<'CHECK'
import re,sys
load=float(re.findall(r"[0-9.]+",sys.argv[1])[0])
print(f"Export E9 idle check: 1-minute load {load:.2f}; require <= 1.0")
sys.exit(0 if load <= 1.0 else 1)
CHECK
then
    echo "pending idle-machine run; no performance samples recorded" >&2
    exit 75
fi
make generate
stamp="$(date +%Y%m%d-%H%M%S)"
evidence_root="/private/tmp/plainsong-export-f-e9-$configuration-$stamp"
mkdir -p "$evidence_root"
TEST_RUNNER_PLAINSONG_RUN_EXPORT_E9=1 xcodebuild -project Plainsong.xcodeproj -scheme Plainsong -configuration "$configuration" \
    -destination 'platform=macOS' -resultBundlePath "$evidence_root/Results.xcresult" test \
    -only-testing:PerformanceTests/ExportHTMLPerformanceTests \
    -only-testing:PerformanceTests/AppBackedEditorPerformanceTests/testTypingDuringActiveHTMLExportStaysWithinTheExistingFrameBudget \
    > "$evidence_root/run.log" 2>&1
printf 'Evidence: %s\n' "$evidence_root"
