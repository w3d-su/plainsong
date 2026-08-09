#!/usr/bin/python3 -I

"""Own the F2 runner session and publish its exit status atomically."""

from __future__ import annotations

import os
import signal
import sys
import time
from collections.abc import Callable
from pathlib import Path


def _write_all(descriptor: int, data: bytes) -> None:
    offset = 0
    while offset < len(data):
        written = os.write(descriptor, data[offset:])
        if written <= 0:
            raise OSError("short write while publishing session status")
        offset += written


def publish_status_atomically(
    status_path: Path,
    exit_code: int,
    before_publish: Callable[[Path], None] | None = None,
) -> None:
    """Fsync private bytes before making the final status name visible."""

    temporary = status_path.with_name(f".{status_path.name}.tmp")
    descriptor = os.open(
        temporary,
        os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0),
        0o400,
    )
    try:
        _write_all(descriptor, f"{exit_code}\n".encode("ascii"))
        os.fsync(descriptor)
    finally:
        os.close(descriptor)
    if before_publish is not None:
        before_publish(temporary)
    os.replace(temporary, status_path)
    directory_descriptor = os.open(status_path.parent, os.O_RDONLY)
    try:
        os.fsync(directory_descriptor)
    finally:
        os.close(directory_descriptor)


def main() -> None:
    if len(sys.argv) < 7:
        raise SystemExit(
            "usage: session_status.py READY GO STATUS DRAIN RUNNER [RUNNER_ARGUMENT ...]"
        )
    ready, go, status_path, drain = map(Path, sys.argv[1:5])
    runner_arguments = sys.argv[5:]
    os.setsid()
    ready_descriptor = os.open(
        ready,
        os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0),
        0o400,
    )
    try:
        _write_all(ready_descriptor, b"ready\n")
        os.fsync(ready_descriptor)
    finally:
        os.close(ready_descriptor)
    while not go.exists():
        time.sleep(0.005)
    child = os.fork()
    if child == 0:
        os.execv(runner_arguments[0], runner_arguments)
    for signum in (signal.SIGHUP, signal.SIGINT, signal.SIGTERM):
        signal.signal(signum, signal.SIG_IGN)
    _, status = os.waitpid(child, 0)
    code = os.waitstatus_to_exitcode(status)
    if code < 0:
        code = 128 - code
    publish_status_atomically(status_path, code)
    while not drain.exists():
        time.sleep(0.005)
    raise SystemExit(code)


if __name__ == "__main__":
    main()
