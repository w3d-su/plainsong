#!/bin/bash
# ios-print-simulator-udid.sh — print the UDID of the first available
# iOS >= 26 iPhone simulator (newest runtime first). Exits 1 with a message when
# none exists. Used by ios.yml to fill IOS_DESTINATION; never invents a name.
set -euo pipefail
cd "$(dirname "$0")/../.."
source Scripts/ios/ios-common.sh

xcrun simctl list devices available --json 2>/dev/null | /usr/bin/python3 -c '
import json, sys
try:
    devices = json.load(sys.stdin)["devices"]
except Exception:
    sys.exit("ios: error: could not read simulator device list")
def runtime_major(name):
    if "iOS-" not in name:
        return -1
    try:
        return int(name.split("iOS-")[1].split("-")[0])
    except ValueError:
        return -1
for runtime in sorted(devices, key=runtime_major, reverse=True):
    if runtime_major(runtime) < 26:
        continue
    for d in devices[runtime]:
        if d.get("isAvailable") and "iPhone" in d.get("deviceTypeIdentifier", d.get("name", "")):
            print(d["udid"])
            sys.exit(0)
sys.exit("ios: error: no available iOS >= 26 iPhone simulator installed")
'
