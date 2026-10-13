#!/usr/bin/env python3
"""Publish a fresh, validated IPA without retaining entries from older ZIPs."""
import argparse
import hashlib
import importlib.util
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import zipfile

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("ios_provenance", Path(__file__).with_name("ios-provenance.py"))
provenance = importlib.util.module_from_spec(spec)
spec.loader.exec_module(provenance)


def fresh_zip(staging, output, before_publish=lambda: None):
    staging, output = Path(staging).resolve(), Path(output).resolve()
    payload = staging / "Payload"
    if not payload.is_dir() or sorted(p.name for p in payload.iterdir()) != ["PlainsongIOS.app"]:
        raise ValueError("Payload must contain only PlainsongIOS.app")
    provenance.tree_digest(payload)
    members = list(payload.rglob("*"))
    if any(p.name == "_CodeSignature" or p.suffix in {".mobileprovision", ".p12", ".keychain"} for p in members):
        raise ValueError("Payload contains signing material")
    expected = {"Payload/"}
    for path in members:
        name = "Payload/" + path.relative_to(payload).as_posix()
        expected.add(name + "/" if path.is_dir() and not path.is_symlink() else name)
    output.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(prefix=".ios-ipa-", suffix=".ipa", dir=output.parent)
    os.close(descriptor)
    temporary = Path(temporary)
    temporary.unlink()  # zip must create a new archive, never update even an empty file.
    try:
        subprocess.run(["zip", "-qry", str(temporary), "Payload"], cwd=staging, check=True)
        with zipfile.ZipFile(temporary) as zipped:
            names = zipped.namelist()
            if set(names) != expected or len(names) != len(expected) or zipped.testzip() is not None:
                raise ValueError("fresh IPA contents do not match the isolated Payload")
        before_publish()
        digest = hashlib.sha256(temporary.read_bytes()).hexdigest()
        os.replace(temporary, output)
        return digest
    finally:
        temporary.unlink(missing_ok=True)


def package(staging, output, archive, repository, report):
    receipt = provenance.verify_archive(archive, repository)
    source_path = Path(str(Path(archive).resolve()) + "-meta") / "source.json"
    def revalidate():
        current = provenance.verify_archive(archive, repository)
        if current != receipt:
            raise ValueError("archive receipt changed while packaging")
        provenance.verify_source(source_path, repository)
    digest = fresh_zip(staging, output, before_publish=revalidate)
    output = Path(output).resolve()
    sidecar = output.with_name(output.name + ".sha256")
    with tempfile.NamedTemporaryFile(mode="w", dir=output.parent, delete=False) as stream:
        temporary = Path(stream.name)
        stream.write(digest + "  " + output.name + "\n")
    os.replace(temporary, sidecar)
    provenance.write_json(report, {
        "schema": "IOS-IPA-v1", "command": "make ios-ipa", "contract_version": provenance.CONTRACT,
        "source_sha": receipt["source_sha"], "source_fingerprint": receipt["source_fingerprint"],
        "source_dirty": receipt["source_dirty"], "archive": str(Path(archive).resolve()),
        "archive_sha256": receipt["archive_sha256"], "ipa": str(output),
        "ipa_sha256": digest, "ipa_bytes": output.stat().st_size,
        "payload_sha256": provenance.tree_digest(Path(staging) / "Payload"),
        "installation": "OPEN", "exit_code": 0,
    })
    return digest


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("staging")
    parser.add_argument("output")
    parser.add_argument("--archive", required=True)
    parser.add_argument("--repository", default=".")
    parser.add_argument("--report", required=True)
    args = parser.parse_args()
    try:
        print(package(args.staging, args.output, args.archive, args.repository, args.report))
    except (ValueError, OSError, KeyError, subprocess.CalledProcessError, zipfile.BadZipFile) as error:
        parser.exit(65, "ios packaging: " + str(error) + "\n")


if __name__ == "__main__":
    main()
