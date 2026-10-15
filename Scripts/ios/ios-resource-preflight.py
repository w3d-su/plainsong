#!/usr/bin/env python3
"""Verify required resources inside a built bundle.

Two checks, either or both:

  --manifest FILE     newline list of bundle-relative paths ('#' comments ok);
                      each path must exist as a non-empty regular file inside at
                      least one --root. Missing entries fail with exit 3.

  --parity SRC:BUNDLED-REL
                      full recursive SHA-256 equality between a source directory
                      (e.g. App/Resources/preview) and the same relative path
                      inside the bundle — absorbs the C0 preview-resource check.

Usage:
    ios-resource-preflight.py --manifest FILE --root DIR [--root DIR...] \\
        [--parity App/Resources/preview:preview] --report OUT.json
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


def realpath_inside(root, relative):
    candidate = os.path.realpath(os.path.join(root, relative))
    return candidate if candidate == root or candidate.startswith(root + os.sep) else None


def manifest_entries(manifest):
    with open(manifest, encoding="utf-8") as stream:
        return [line.strip() for line in stream if line.strip() and not line.strip().startswith("#")]


def check_manifest(manifest, roots):
    wanted = manifest_entries(manifest)
    if not wanted:
        print(f"ios-resource-preflight: manifest has no entries: {manifest}", file=sys.stderr)
        raise SystemExit(65)
    found, missing = [], []
    for relative in wanted:
        hit = None
        for root in roots:
            candidate = realpath_inside(root, relative)
            if candidate and os.path.isfile(candidate) and os.path.getsize(candidate) > 0:
                hit = {"path": relative, "root": root,
                       "bytes": os.path.getsize(candidate), "sha256": sha256_file(candidate)}
                break
        (found if hit else missing).append(hit or {"path": relative})
    return found, [item["path"] for item in missing], found + missing


def check_parity(source, bundle_relative, roots):
    mismatched, compared = [], 0
    for dirpath, _dirs, files in os.walk(source):
        for name in files:
            src = os.path.join(dirpath, name)
            rel = os.path.relpath(src, source)
            bundle_rel = os.path.join(bundle_relative, rel)
            expected = sha256_file(src)
            hit = None
            for root in roots:
                candidate = realpath_inside(root, bundle_rel)
                if candidate and os.path.isfile(candidate):
                    actual = sha256_file(candidate)
                    hit = candidate
                    if actual != expected:
                        mismatched.append({"path": bundle_rel, "reason": "sha256 differs",
                                           "expected": expected, "actual": actual})
                    break
            if hit is None:
                mismatched.append({"path": bundle_rel, "reason": "missing from bundle"})
            compared += 1
    return compared, mismatched


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest")
    parser.add_argument("--root", action="append", required=True)
    parser.add_argument("--parity", action="append", default=[],
                        metavar="SRC:BUNDLED-REL")
    parser.add_argument("--report", required=True)
    args = parser.parse_args()

    if not args.manifest and not args.parity:
        print("ios-resource-preflight: nothing to check (need --manifest or --parity)",
              file=sys.stderr)
        return 2

    roots = [os.path.realpath(root) for root in args.root]
    for root in roots:
        if not os.path.isdir(root):
            print(f"ios-resource-preflight: root is not a directory: {root}", file=sys.stderr)
            return 2

    report = {"roots": roots, "manifest": args.manifest,
              "entries": [], "missing": [], "parity": []}
    status = 0

    if args.manifest:
        found, missing, entries = check_manifest(args.manifest, roots)
        report.update({"declared": len(entries), "found": len(found),
                       "missing": missing, "entries": entries})
        if missing:
            status = 3

    for spec in args.parity:
        source, _, bundle_rel = spec.partition(":")
        compared, mismatched = check_parity(source, bundle_rel, roots)
        report["parity"].append({"source": source, "bundle_relative": bundle_rel,
                                 "compared": compared, "mismatched": mismatched})
        if compared == 0 or mismatched:
            status = 3

    os.makedirs(os.path.dirname(os.path.realpath(args.report)), exist_ok=True)
    with open(args.report, "w", encoding="utf-8") as stream:
        json.dump(report, stream, indent=2, sort_keys=True)
        stream.write("\n")

    if status:
        print(f"ios-resource-preflight: FAILED — {report['missing']} missing; "
              f"parity mismatches in {len(report['parity'])} check(s); report: {args.report}",
              file=sys.stderr)
        return status
    print(f"ios-resource-preflight: OK — manifest {len(report['entries'])} path(s), "
          f"parity {len(report['parity'])} dir(s) -> {args.report}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
