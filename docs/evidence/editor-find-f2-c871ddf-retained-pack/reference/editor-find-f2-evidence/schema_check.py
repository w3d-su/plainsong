#!/usr/bin/python3

"""Fail closed when the shell capture constants drift from schema.json."""

from __future__ import annotations

import json
import hashlib
import sys
from pathlib import Path


def unique_object(pairs: list[tuple[str, object]]) -> dict[str, object]:
    result: dict[str, object] = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"duplicate schema key: {key}")
        result[key] = value
    return result


def main() -> None:
    if len(sys.argv) == 5 and sys.argv[1] == "--digest":
        schema_path = Path(sys.argv[2])
        group = sys.argv[3]
        root = Path(sys.argv[4])
        schema = json.loads(
            schema_path.read_text(encoding="utf-8"),
            object_pairs_hook=unique_object,
        )
        key = {"capture": "captureToolingPaths", "auditor": "auditorToolingPaths"}.get(group)
        if key is None:
            raise SystemExit(f"unknown tooling group: {group}")
        digest = hashlib.sha256()
        for relative in schema[key]:
            encoded = relative.encode("utf-8")
            data = (root / relative).read_bytes()
            digest.update(len(encoded).to_bytes(8, "big"))
            digest.update(encoded)
            digest.update(len(data).to_bytes(8, "big"))
            digest.update(data)
        print(digest.hexdigest())
        return
    if len(sys.argv) != 11:
        raise SystemExit("schema_check.py received the wrong argument count")
    schema = json.loads(
        Path(sys.argv[1]).read_text(encoding="utf-8"),
        object_pairs_hook=unique_object,
    )
    actual = (
        schema["sourceCommit"],
        schema["processFilter"],
        schema["processOwnershipRule"],
        str(schema["monitor"]["format"]),
        str(schema["monitor"]["sampleIntervalMilliseconds"]),
        str(schema["monitor"]["maximumSampleGapMilliseconds"]),
        str(schema["outer"]["format"]),
        str(schema["outer"]["runTimeoutSeconds"]),
        schema["runnerEnvironmentPolicy"],
    )
    expected = tuple(sys.argv[2:])
    if actual != expected:
        raise SystemExit(f"capture constants differ from schema.json: {actual!r} != {expected!r}")


if __name__ == "__main__":
    main()
