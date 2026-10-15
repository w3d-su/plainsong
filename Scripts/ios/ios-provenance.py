#!/usr/bin/env python3
"""Bind build receipts to exact source inputs and immutable archive contents."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import stat
import subprocess
import tempfile

CONTRACT = "IOS-C0-v1"
INPUT_ROOTS = ("AppIOS/", "AppIOSTests/", "App/Resources/preview/", "Packages/", "Scripts/ios/")
INPUT_FILES = {"project.yml", "Makefile"}


def write_json(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(mode="w", dir=path.parent, delete=False) as stream:
        temporary = Path(stream.name)
        json.dump(value, stream, indent=2, sort_keys=True)
        stream.write("\n")
    os.replace(temporary, path)


def encoded_digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(",", ":")).encode()).hexdigest()


def file_record(path):
    metadata = path.lstat()
    mode = stat.S_IMODE(metadata.st_mode)
    if path.is_symlink():
        return {"kind": "symlink", "target": os.readlink(path), "mode": mode}
    if path.is_dir():
        return {"kind": "directory", "mode": mode}
    if not stat.S_ISREG(metadata.st_mode):
        raise ValueError("unsupported artifact member: " + str(path))
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(65536), b""):
            digest.update(chunk)
    return {"kind": "file", "sha256": digest.hexdigest(), "mode": mode}


def source_snapshot(repository):
    repository = Path(repository).resolve()
    def git(*arguments):
        return subprocess.check_output(["git", "-C", str(repository), *arguments])
    names = set(git("ls-files", "-z", "--cached", "--others", "--exclude-standard").split(b"\0"))
    files = {}
    for raw in sorted(names):
        name = os.fsdecode(raw)
        if "__pycache__" in Path(name).parts or name.endswith(".pyc"):
            continue
        if name in INPUT_FILES or name.startswith(INPUT_ROOTS):
            path = repository / name
            files[name] = file_record(path) if path.exists() or path.is_symlink() else {"kind": "deleted"}
    if not files or "project.yml" not in files:
        raise ValueError("source fingerprint lacks project.yml or build inputs")
    return {"schema": "IOS-SOURCE-v1", "contract_version": CONTRACT,
            "source_sha": git("rev-parse", "HEAD").decode().strip(),
            "source_dirty": bool(git("status", "--porcelain")),
            "source_fingerprint": encoded_digest(files), "files": files}


def verify_source(receipt, repository):
    recorded = json.loads(Path(receipt).read_text())
    current = source_snapshot(repository)
    if (recorded.get("schema") != "IOS-SOURCE-v1" or recorded.get("contract_version") != CONTRACT
            or encoded_digest(recorded.get("files")) != recorded.get("source_fingerprint")
            or recorded.get("source_sha") != current["source_sha"]
            or recorded.get("source_fingerprint") != current["source_fingerprint"]):
        raise ValueError("source head or input fingerprint changed; build a new archive")
    return recorded


def tree_digest(directory):
    directory = Path(directory)
    if not directory.is_dir() or directory.is_symlink():
        raise ValueError("artifact root is not a real directory")
    records = {}
    for parent, directories, files in os.walk(directory, followlinks=False):
        for name in directories + files:
            path = Path(parent) / name
            if path.is_symlink() and not path.resolve().is_relative_to(directory.resolve()):
                raise ValueError("artifact symlink escapes its root: " + str(path))
            records[str(path.relative_to(directory))] = file_record(path)
    if not records:
        raise ValueError("empty archive")
    return encoded_digest(records)


def require_device_platform(build_text, architectures):
    platforms = re.findall(r"(?m)^\s*platform\s+(\S+)\s*$", build_text)
    if not platforms or set(platforms) != {"IOS"} or set(architectures.split()) != {"arm64"}:
        raise ValueError("device archive must contain only IOS/arm64, never IOSSIMULATOR")


def verify_device_app(app):
    app = Path(app)
    info = plistlib.loads((app / "Info.plist").read_bytes())
    if not str(info.get("MinimumOSVersion", "")).startswith("26."):
        raise ValueError("device app must retain deployment target iOS 26")
    bundles = [app] + sorted(p for p in app.rglob("*") if p.is_dir() and p.suffix in {".framework", ".appex"})
    for bundle in bundles:
        metadata = plistlib.loads((bundle / "Info.plist").read_bytes())
        executable = bundle / metadata["CFBundleExecutable"]
        text = subprocess.check_output(["vtool", "-show-build", str(executable)], text=True)
        architectures = subprocess.check_output(["lipo", "-archs", str(executable)], text=True)
        require_device_platform(text, architectures)


def verify_archive(archive, repository):
    archive = Path(archive).resolve()
    metadata = Path(str(archive) + "-meta")
    receipt = json.loads((metadata / "archive.json").read_text())
    if (receipt.get("schema") != "IOS-ARCHIVE-v1" or receipt.get("contract_version") != CONTRACT
            or type(receipt.get("exit_code")) is not int
            or receipt["exit_code"] != 0 or receipt.get("configuration") != "Release"):
        raise ValueError("archive has no successful Release receipt")
    source_path = metadata / "source.json"
    source = verify_source(source_path, repository)
    if (receipt.get("source_manifest_sha256") != hashlib.sha256(source_path.read_bytes()).hexdigest()
            or receipt.get("source_sha") != source["source_sha"]
            or receipt.get("source_fingerprint") != source["source_fingerprint"]
            or receipt.get("archive_sha256") != tree_digest(archive)):
        raise ValueError("archive/source digest does not match its successful receipt")
    verify_device_app(archive / "Products/Applications/PlainsongIOS.app")
    return receipt


def record_archive(archive, repository, result, start, end):
    archive = Path(archive).resolve()
    metadata = Path(str(archive) + "-meta")
    source = json.loads((metadata / "source.json").read_text())
    if result == 0:
        verify_source(metadata / "source.json", repository)
        verify_device_app(archive / "Products/Applications/PlainsongIOS.app")
    receipt = {"schema": "IOS-ARCHIVE-v1", "command": "make ios-archive",
               "configuration": "Release", "contract_version": CONTRACT,
               "source_sha": source["source_sha"], "source_dirty": source["source_dirty"],
               "source_fingerprint": source["source_fingerprint"],
               "source_manifest_sha256": hashlib.sha256((metadata / "source.json").read_bytes()).hexdigest(),
               "archive": str(archive), "archive_sha256": tree_digest(archive) if result == 0 else None,
               "start": start, "end": end, "exit_code": result}
    write_json(metadata / "archive.json", receipt)


def select_archive(output_root, repository):
    head = source_snapshot(repository)["source_sha"]
    candidates = []
    for archive in Path(output_root).rglob("*.xcarchive"):
        receipt_path = Path(str(archive) + "-meta") / "archive.json"
        if not receipt_path.is_file():
            continue
        receipt = json.loads(receipt_path.read_text())
        if receipt.get("source_sha") == head:
            candidates.append(archive)
    if not candidates:
        return ""
    candidate = max(candidates, key=lambda path: path.stat().st_mtime_ns)
    verify_archive(candidate, repository)
    return str(candidate.resolve())


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("action", choices=["capture", "verify-source", "tree-digest", "verify-device", "verify-archive", "select-archive", "record-archive"])
    parser.add_argument("path")
    parser.add_argument("--repository", default=".")
    parser.add_argument("--result", type=int)
    parser.add_argument("--start", default="")
    parser.add_argument("--end", default="")
    args = parser.parse_args()
    try:
        if args.action == "capture":
            write_json(args.path, source_snapshot(args.repository))
        elif args.action == "verify-source":
            verify_source(args.path, args.repository)
        elif args.action == "tree-digest":
            print(tree_digest(args.path))
        elif args.action == "verify-device":
            verify_device_app(args.path)
        elif args.action == "verify-archive":
            verify_archive(args.path, args.repository)
        elif args.action == "select-archive":
            print(select_archive(args.path, args.repository))
        elif args.action == "record-archive":
            if args.result is None:
                raise ValueError("record-archive requires --result")
            record_archive(args.path, args.repository, args.result, args.start, args.end)
    except (ValueError, OSError, KeyError, subprocess.CalledProcessError) as error:
        parser.exit(65, "ios evidence: " + str(error) + "\n")


if __name__ == "__main__":
    main()
