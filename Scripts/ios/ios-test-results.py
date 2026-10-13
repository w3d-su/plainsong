#!/usr/bin/env python3
"""Fail closed on malformed, empty, skipped or incomplete required XCTest results."""
import argparse
import json
from pathlib import Path
import sys


def executed_tests(document):
    if not isinstance(document, dict) or not isinstance(document.get("testNodes"), list):
        raise ValueError("xcresult tests JSON lacks testNodes")
    results = {}
    def walk(nodes):
        for node in nodes:
            if not isinstance(node, dict):
                raise ValueError("malformed test node")
            if node.get("nodeType") == "Test Case":
                identifier, result = node.get("nodeIdentifier"), node.get("result")
                if (not isinstance(identifier, str) or "/" not in identifier
                        or result not in {"Passed", "Failed", "Skipped"}):
                    raise ValueError("malformed or unknown Test Case result")
                identifier = identifier.removesuffix("()")
                if identifier in results:
                    raise ValueError("duplicate case identifier: " + identifier)
                results[identifier] = result
            children = node.get("children", [])
            if not isinstance(children, list):
                raise ValueError("malformed test children")
            walk(children)
    walk(document["testNodes"])
    return results


def validate_results(document, required):
    results = executed_tests(document)
    if not required:
        raise ValueError("required named-test manifest is empty")
    if not results or "Passed" not in results.values():
        raise ValueError("zero executed cases or all cases skipped")
    failed = sorted(name for name, result in results.items() if result == "Failed")
    missing = sorted(name for name in required if results.get(name) != "Passed")
    if failed or missing:
        raise ValueError("failed cases=" + repr(failed) + "; missing/not-passed required=" + repr(missing))
    return {"passed": sum(value == "Passed" for value in results.values()),
            "skipped": sum(value == "Skipped" for value in results.values()),
            "failed": len(failed), "executed": sum(value != "Skipped" for value in results.values()),
            "required": sorted(required), "cases": results}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("results")
    parser.add_argument("--required", required=True)
    parser.add_argument("--report", required=True)
    parser.add_argument("--names", required=True)
    args = parser.parse_args()
    try:
        required = {line.strip() for line in Path(args.required).read_text().splitlines()
                    if line.strip() and not line.lstrip().startswith("#")}
        report = validate_results(json.loads(Path(args.results).read_text()), required)
        Path(args.names).write_text("\n".join(sorted(report["cases"])) + "\n")
        Path(args.report).write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
    except (ValueError, OSError, KeyError) as error:
        Path(args.report).write_text(json.dumps({"status": "FAILED", "reason": str(error)}, indent=2) + "\n")
        parser.exit(65, "ios test gate: " + str(error) + "\n")
    print("ios test gate: executed={executed} passed={passed} skipped={skipped}".format(**report))


if __name__ == "__main__":
    main()
