#!/usr/bin/env python3
"""Fail closed on a Mac acceptance-component log that is empty, skipped, or incomplete.

This parses XCTest lines from `swift test`. It is not an XCResult and must not
be recorded as one. Build success alone is not a passing case.
"""
import argparse
import importlib.util
import json
import re
import sys
from pathlib import Path


CASE = re.compile(
    r"Test Case '-\[(?P<module>[^\s.]+)\.(?P<klass>[^\s]+) (?P<method>[^\s\]]+)\]' "
    r"(?P<status>passed|failed|skipped)\b",
    re.IGNORECASE,
)


def load_results():
    path = Path(__file__).resolve().parent / "ios-test-results.py"
    spec = importlib.util.spec_from_file_location("ios_test_results", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def cases_from_log(text):
    found = {}
    for match in CASE.finditer(text):
        identifier = match.group("klass") + "/" + match.group("method")
        if identifier in found:
            raise ValueError("duplicate case identifier: " + identifier)
        found[identifier] = {"passed": "Passed", "failed": "Failed", "skipped": "Skipped"}[
            match.group("status").lower()]
    nodes = [{"nodeType": "Test Case", "nodeIdentifier": name + "()", "result": status}
             for name, status in sorted(found.items())]
    return {"testNodes": nodes}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("log")
    parser.add_argument("--required", required=True)
    parser.add_argument("--report", required=True)
    parser.add_argument("--names", required=True)
    args = parser.parse_args()
    results = load_results()
    try:
        required = {line.strip() for line in Path(args.required).read_text().splitlines()
                    if line.strip() and not line.lstrip().startswith("#")}
        report = results.validate_results(cases_from_log(Path(args.log).read_text()), required)
        report["result_format"] = "swift-test-xctest-log"
        Path(args.names).write_text("\n".join(sorted(report["cases"])) + "\n")
        Path(args.report).write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
    except (ValueError, OSError, KeyError) as error:
        Path(args.report).write_text(json.dumps(
            {"status": "FAILED", "result_format": "swift-test-xctest-log", "reason": str(error)},
            indent=2) + "\n")
        parser.exit(65, "ios component gate: " + str(error) + "\n")
    print("ios component gate: executed={executed} passed={passed} skipped={skipped}".format(**report))


if __name__ == "__main__":
    main()
