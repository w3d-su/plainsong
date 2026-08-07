#!/usr/bin/python3

"""Capture an F2 evidence stream while binding and sealing its exact bytes."""

from __future__ import annotations

import hashlib
import os
import sys
from pathlib import Path


def fail(message: str) -> None:
    print(f"F2 CAPTURE FAIL: {message}", file=sys.stderr)
    raise SystemExit(1)


def write_digest(path: Path, digest: str, byte_count: int) -> None:
    descriptor = os.open(
        path,
        os.O_WRONLY | os.O_CREAT | os.O_EXCL,
        0o600,
    )
    try:
        payload = f"sha256={digest}\nbytes={byte_count}\n".encode("ascii")
        with os.fdopen(descriptor, "wb", closefd=False) as handle:
            handle.write(payload)
            handle.flush()
            os.fsync(handle.fileno())
        os.fchmod(descriptor, 0o444)
    finally:
        os.close(descriptor)


def main() -> None:
    if len(sys.argv) != 3:
        fail("usage: capture-editor-find-f2-log.py OUTPUT DIGEST_OUTPUT")

    output_path = Path(sys.argv[1])
    digest_path = Path(sys.argv[2])
    descriptor = os.open(
        output_path,
        os.O_WRONLY | os.O_CREAT | os.O_EXCL,
        0o600,
    )
    digest = hashlib.sha256()
    byte_count = 0

    try:
        with os.fdopen(descriptor, "wb", closefd=False) as output:
            while True:
                chunk = os.read(sys.stdin.fileno(), 64 * 1024)
                if not chunk:
                    break
                output.write(chunk)
                sys.stdout.buffer.write(chunk)
                sys.stdout.buffer.flush()
                digest.update(chunk)
                byte_count += len(chunk)
            output.flush()
            os.fsync(output.fileno())
        os.fchmod(descriptor, 0o444)
    except BaseException:
        try:
            os.fchmod(descriptor, 0o444)
        finally:
            os.close(descriptor)
        raise
    else:
        os.close(descriptor)

    try:
        write_digest(digest_path, digest.hexdigest(), byte_count)
    except OSError as error:
        fail(f"could not retain digest {digest_path}: {error}")


if __name__ == "__main__":
    try:
        main()
    except OSError as error:
        fail(f"could not capture evidence: {error}")
