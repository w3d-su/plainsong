#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
proxy_root="$(mktemp -d /private/tmp/plainsong-export-f-proxy.XXXXXX)"
/usr/bin/python3 Scripts/export_html_network_proxy.py --port-file "$proxy_root/port" > "$proxy_root/proxy.log" 2>&1 &
proxy_pid=$!
trap 'kill "$proxy_pid" 2>/dev/null || true' EXIT
for attempt in {1..100}; do
    if [ -s "$proxy_root/port" ]; then break; fi
    sleep 0.05
done
if [ ! -s "$proxy_root/port" ]; then cat "$proxy_root/proxy.log" >&2; exit 1; fi
make generate
TEST_RUNNER_PLAINSONG_EXPORT_TEST_PROXY_PORT="$(cat "$proxy_root/port")" lockf -k \
    /private/tmp/claude-501/-Users-davis---su-Documents-blogeditor/50f4130b-7177-4f95-827c-f97a63ad8e24/scratchpad/plainsong-xcodebuild-test.lock \
    xcodebuild -project Plainsong.xcodeproj -scheme Plainsong -configuration Debug test \
    -only-testing:PlainsongTests/ExportHTMLCommandAppTests \
    -only-testing:PlainsongTests/ExportHTMLFeedbackAppTests \
    -only-testing:PlainsongTests/ExportHTMLOfflineTests \
    -only-testing:PlainsongTests/ExportDestinationOwnershipAppTests \
    "$@"
