#!/bin/bash
# U-G1: Sparkle stays on the App target. Packages must not name it.
set -euo pipefail
cd "$(dirname "$0")/.."
if git grep -n -w Sparkle -- Packages; then
    echo "error: Packages must not reference Sparkle (agent.md §17.3)" >&2
    exit 1
fi

python3 -c '
from pathlib import Path
import sys

lines = Path("project.yml").read_text().splitlines()
package_block = []
in_package = False
section = None
target = None
linked_from = []
for line in lines:
    if line and not line.startswith(" ") and not line.startswith("#"):
        section = line[:-1] if line.endswith(":") else None
        target = None
        in_package = False
        continue
    if line.startswith("  ") and not line.startswith("   ") and line.rstrip().endswith(":"):
        key = line.strip()[:-1]
        if section == "packages":
            in_package = key == "Sparkle"
            if in_package:
                package_block = []
        elif section == "targets":
            target = key
            in_package = False
        continue
    if in_package:
        package_block.append(line.strip())
    if line.strip() == "- package: Sparkle":
        linked_from.append(target)

if "exactVersion: 2.10.0" not in package_block:
    print("error: Sparkle must be pinned to exactVersion 2.10.0", file=sys.stderr)
    sys.exit(1)
if linked_from != ["Plainsong"]:
    print(f"error: Sparkle must be linked only by Plainsong, found {linked_from}", file=sys.stderr)
    sys.exit(1)
'
