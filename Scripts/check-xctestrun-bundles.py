#!/usr/bin/env python3
"""Fail when an .xctestrun holds a test bundle that no CI shard runs.

The hosted shards select bundles by name (`targets:` in ci.yml). A bundle added to the
Plainsong scheme would be built into the .xctestrun but executed by no shard, and the
aggregate gate would stay green. Usage:

    check-xctestrun-bundles.py <file.xctestrun> <ExpectedBundle>...

Reads FormatVersion 1 (one top-level dictionary per bundle) and FormatVersion 2
(`TestConfigurations[].TestTargets[]`), the layouts Xcode 15-27 write.
"""

import plistlib
import sys


def bundle_names(xctestrun):
    metadata = xctestrun.get("__xctestrun_metadata__", {})
    version = metadata.get("FormatVersion")
    if version == 1:
        return {
            value.get("BlueprintName", key)
            for key, value in xctestrun.items()
            if key != "__xctestrun_metadata__" and isinstance(value, dict)
        }
    if version == 2:
        return {
            target["BlueprintName"]
            for configuration in xctestrun.get("TestConfigurations", [])
            for target in configuration.get("TestTargets", [])
        }
    raise SystemExit(f"unsupported .xctestrun FormatVersion: {version!r}")


def main(argv):
    if len(argv) < 3:
        raise SystemExit(__doc__)
    path, expected = argv[1], set(argv[2:])
    with open(path, "rb") as handle:
        actual = bundle_names(plistlib.load(handle))
    if actual != expected:
        unsharded = sorted(actual - expected)
        missing = sorted(expected - actual)
        print(f"{path}: test bundles {sorted(actual)} do not match the shards' {sorted(expected)}", file=sys.stderr)
        if unsharded:
            print(f"  built but run by no shard: {unsharded} (add them to a shard's targets in ci.yml)", file=sys.stderr)
        if missing:
            print(f"  run by a shard but not built: {missing}", file=sys.stderr)
        return 1
    print(f"test bundles match the shards: {' '.join(sorted(actual))}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
