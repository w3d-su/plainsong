#!/usr/bin/env python3
"""Verify every manifest-listed resource exists inside a built bundle.

Manifest format mirrors Scripts/performance-required-resources.txt: one
bundle-relative path per line, '#' comments and blank lines allowed.

Usage:
    ios-resource-preflight.py --manifest FILE --root DIR [--root DIR...]
                              --report OUT.json

Each manifest path must resolve inside at least one --root (e.g. the .app and
its hosted .xctest bundle). Missing entries fail with a nonzero exit and are
recorded in the report — a missing resource is never silently skipped.
"""
import argparse
import hashlib
import json
import os
import sys


def sha256_file(path):
    digest = hashlib.sha256()
    with open(path, "rb") as stream:
        for chunk in iter(lambda: stream.read(65536), b""):
            digest.update(chunk)
    return digest.hexdigest()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", required=True)
    parser.add_argument("--root", action="append", required=True)
    parser.add_argument("--report", required=True)
    args = parser.parse_args()

    roots = [os.path.realpath(root) for root in args.root]
    for root in roots:
        if not os.path.isdir(root):
            print(f"ios-resource-preflight: root is not a directory: {root}", file=sys.stderr)
            return 2

    with open(args.manifest, encoding="utf-8") as stream:
        wanted = [
            line.strip()
            for line in stream
            if line.strip() and not line.strip().startswith("#")
        ]
    if not wanted:
        print(f"ios-resource-preflight: manifest has no entries: {args.manifest}", file=sys.stderr)
        return 2

    found, missing = [], []
    for relative in wanted:
        hit = None
        for root in roots:
            candidate = os.path.realpath(os.path.join(root, relative))
            if not candidate.startswith(root + os.sep):
                continue  # traversal attempt — not a match, reported below
            if os.path.isfile(candidate) and os.path.getsize(candidate) > 0:
                hit = {
                    "path": relative,
                    "root": root,
                    "bytes": os.path.getsize(candidate),
                    "sha256": sha256_file(candidate),
                }
                break
        (found if hit else missing).append(hit or {"path": relative})

    report = {
        "manifest": args.manifest,
        "roots": roots,
        "declared": len(wanted),
        "found": len(found),
        "missing": [item["path"] for item in missing],
        "entries": found + missing,
    }
    os.makedirs(os.path.dirname(os.path.realpath(args.report)), exist_ok=True)
    with open(args.report, "w", encoding="utf-8") as stream:
        json.dump(report, stream, indent=2, sort_keys=True)
        stream.write("\n")

    if missing:
        print(
            f"ios-resource-preflight: {len(missing)}/{len(wanted)} manifest paths missing: "
            + ", ".join(item["path"] for item in missing),
            file=sys.stderr,
        )
        return 3
    print(f"ios-resource-preflight: {len(found)}/{len(wanted)} resources verified -> {args.report}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
