from __future__ import annotations

import json
import os
import re
import subprocess
import tempfile
import unittest
from pathlib import Path

from editor_find_f2_evidence.artifact_hash import (
    hash_artifact,
    hash_source_archive_tree,
    hash_source_tree,
)
from editor_find_f2_evidence.builder import build_pack
from editor_find_f2_evidence.builder_io import DestinationRegistry
from editor_find_f2_evidence.errors import AuditError
from editor_find_f2_evidence.pack import validate_pack
from editor_find_f2_evidence.schema import load_schema
from editor_find_f2_evidence.strict_io import sha256_file

from .builder_fixture import create_builder_inputs
from .fixture import write, write_source_archive


class BuilderTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="f2-builder-tests.", dir="/private/tmp")
        self.root = Path(self.temporary.name)
        self.prefixes, self.summary, self.schema = create_builder_inputs(self.root / "inputs")
        self.pack = self.root / "pack"
        self.artifacts = self.root / "artifacts"

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def build(self) -> None:
        build_pack(
            self.pack,
            self.artifacts,
            self.prefixes,
            lambda _path: self.summary,
            self.schema,
        )

    def rewrite_build_manifest(self, configuration: str, replacements: dict[str, str]) -> None:
        manifest = self.root / "inputs" / "builds" / configuration.lower() / "f2-editor-find-build-manifest.txt"
        lines = []
        for line in manifest.read_text(encoding="utf-8").splitlines():
            key, _ = line.split("=", 1)
            lines.append(f"{key}={replacements.get(key, line.split('=', 1)[1])}")
        write(manifest, "\n".join(lines) + "\n")
        digest = sha256_file(manifest)
        prefix = configuration.lower()
        for run_id in (f"{prefix}-1", f"{prefix}-2", f"{prefix}-3"):
            evidence = Path(f"{self.prefixes[run_id]}.evidence-manifest.txt")
            text = re.sub(
                r"build_manifest_sha256=[0-9a-f]{64}",
                f"build_manifest_sha256={digest}",
                evidence.read_text(encoding="utf-8"),
            )
            write(evidence, text)

    def test_builder_round_trips_compact_and_full_with_deduplication(self) -> None:
        self.build()
        self.assertEqual(len(validate_pack(self.pack, None, integrity_schema=self.schema)), 6)
        self.assertEqual(len(validate_pack(self.pack, self.artifacts, integrity_schema=self.schema)), 6)
        provenances = []
        for run_id in load_schema().run_ids:
            path = self.pack / "runs" / run_id / "full-artifact-provenance.json"
            provenances.append(json.loads(path.read_text(encoding="utf-8")))
        debug_archives = {
            item["artifacts"]["sourceArchive"]["artifactRootPath"]
            for item in provenances[:3]
        }
        self.assertEqual(len(debug_archives), 1)
        self.assertFalse(any(path.name == "repositories" for path in self.artifacts.rglob("repositories")))
        self.assertEqual(oct(self.pack.stat().st_mode & 0o777), "0o700")
        self.assertEqual(oct(self.artifacts.stat().st_mode & 0o777), "0o700")

    def test_builder_rejects_existing_output_without_overwrite(self) -> None:
        self.pack.mkdir(mode=0o700)
        marker = self.pack / "keep"
        marker.write_text("owner data\n", encoding="utf-8")
        with self.assertRaisesRegex(AuditError, "already exists"):
            self.build()
        self.assertEqual(marker.read_text(encoding="utf-8"), "owner data\n")
        self.assertFalse(self.artifacts.exists())

    def test_builder_rejects_capture_symlink(self) -> None:
        path = Path(f"{self.prefixes['debug-1']}.log")
        target = self.root / "target.log"
        target.write_bytes(path.read_bytes())
        path.unlink()
        os.symlink(target, path)
        with self.assertRaisesRegex(AuditError, "not canonical"):
            self.build()
        self.assertFalse(self.pack.exists())

    def test_builder_rejects_build_manifest_path_escape(self) -> None:
        evidence_paths = [
            Path(f"{self.prefixes[run_id]}.evidence-manifest.txt")
            for run_id in ("debug-1", "debug-2", "debug-3")
        ]
        manifest_line = next(
            line for line in evidence_paths[0].read_text(encoding="utf-8").splitlines()
            if line.startswith("build_manifest_path=")
        )
        manifest = Path(manifest_line.split("=", 1)[1])
        text = manifest.read_text(encoding="utf-8").replace(
            "xctestrun_relative_path=Build/Products/",
            "xctestrun_relative_path=../Build/Products/",
        )
        write(manifest, text)
        digest = sha256_file(manifest)
        for path in evidence_paths:
            text = path.read_text(encoding="utf-8")
            text = re.sub(
                r"build_manifest_sha256=[0-9a-f]{64}",
                f"build_manifest_sha256={digest}",
                text,
            )
            write(path, text)
        with self.assertRaisesRegex(AuditError, "escapes"):
            self.build()
        self.assertFalse(self.pack.exists())

    def test_builder_rejects_rewritten_unrelated_source_archive(self) -> None:
        archive = self.root / "inputs" / "builds" / "debug.source.tar"
        write_source_archive(archive, {"unrelated.txt": b"unrelated source\n"})
        self.rewrite_build_manifest(
            "Debug",
            {
                "source_archive_sha256": sha256_file(archive),
                "source_tree_sha256": hash_source_archive_tree(archive),
            },
        )
        with self.assertRaisesRegex(AuditError, "external anchor"):
            self.build()
        self.assertFalse(self.pack.exists())

    def test_builder_rejects_replaced_snapshot_after_resealing_build_hash(self) -> None:
        snapshot = self.root / "inputs" / "builds" / "debug.source"
        write(snapshot / "project.yml", b"replacement source\n")
        self.rewrite_build_manifest(
            "Debug",
            {"build_input_sha256": hash_artifact(snapshot)},
        )
        with self.assertRaisesRegex(AuditError, "source snapshot (bytes|size) differs"):
            self.build()
        self.assertFalse(self.pack.exists())

    def test_builder_allows_only_documented_generated_project_addition(self) -> None:
        snapshot = self.root / "inputs" / "builds" / "debug.source"
        write(snapshot / "Plainsong.xcodeproj" / "project.pbxproj", b"generated\n")
        self.rewrite_build_manifest(
            "Debug",
            {"build_input_sha256": hash_artifact(snapshot)},
        )
        self.build()
        self.assertEqual(
            len(validate_pack(self.pack, self.artifacts, integrity_schema=self.schema)),
            6,
        )

    def test_source_tree_hash_contract_normalizes_umask_private_root(self) -> None:
        archive = self.root / "source.tar"
        snapshot = self.root / "snapshot"
        source = b"exact source\n"
        write_source_archive(archive, {"project.yml": source})
        snapshot.mkdir(mode=0o700)
        snapshot.chmod(0o700)
        subprocess.run(
            ["/usr/bin/tar", "-xf", str(archive), "-C", str(snapshot)],
            check=True,
        )
        self.assertEqual(snapshot.stat().st_mode & 0o777, 0o700)
        self.assertEqual(
            hash_source_tree(snapshot),
            hash_source_archive_tree(archive),
        )
        script = Path(__file__).resolve().parent.parent / "hash-editor-find-f2-artifact.py"
        completed = subprocess.run(
            ["/usr/bin/python3", "-I", str(script), "--source-tree", str(snapshot)],
            capture_output=True,
            text=True,
            check=True,
        )
        self.assertEqual(completed.stdout.strip(), hash_source_archive_tree(archive))

    def test_builder_rejects_app_executable_as_xctestrun(self) -> None:
        executable = (
            Path(f"{self.prefixes['debug-1']}.products")
            / "Build/Products/Debug/Plainsong.app/Contents/MacOS/Plainsong"
        )
        self.rewrite_build_manifest(
            "Debug",
            {
                "xctestrun_relative_path": "Build/Products/Debug/Plainsong.app/Contents/MacOS/Plainsong",
                "xctestrun_sha256": hash_artifact(executable),
            },
        )
        with self.assertRaisesRegex(AuditError, r"Build/Products/\*\.xctestrun"):
            self.build()
        self.assertFalse(self.pack.exists())

    def test_builder_rejects_capture_digest_tamper(self) -> None:
        path = Path(f"{self.prefixes['debug-1']}.log")
        path.write_bytes(path.read_bytes() + b"tamper\n")
        with self.assertRaisesRegex(AuditError, "digest differs"):
            self.build()
        self.assertFalse(self.pack.exists())

    def test_builder_rejects_existing_artifact_root_and_cleans_new_pack(self) -> None:
        self.artifacts.mkdir(mode=0o700)
        marker = self.artifacts / "keep"
        marker.write_text("owner artifact\n", encoding="utf-8")
        with self.assertRaisesRegex(AuditError, "already exists"):
            self.build()
        self.assertFalse(self.pack.exists())
        self.assertEqual(marker.read_text(encoding="utf-8"), "owner artifact\n")

    def test_builder_rejects_nested_artifact_symlink(self) -> None:
        snapshot = self.root / "inputs" / "builds" / "debug.source"
        os.symlink(snapshot / "project.yml", snapshot / "linked-project")
        with self.assertRaisesRegex(AuditError, "contains symlink"):
            self.build()
        self.assertFalse(self.pack.exists())

    def test_builder_cleans_fresh_roots_after_summary_failure(self) -> None:
        def fail(_path: Path) -> bytes:
            raise AuditError("injected summary failure")

        with self.assertRaisesRegex(AuditError, "injected summary"):
            build_pack(self.pack, self.artifacts, self.prefixes, fail, self.schema)
        self.assertFalse(self.pack.exists())
        self.assertFalse(self.artifacts.exists())

    def test_destination_registry_rejects_case_collision(self) -> None:
        registry = DestinationRegistry(self.root)
        registry.reserve(self.root / "Runs" / "one")
        with self.assertRaisesRegex(AuditError, "case-colliding"):
            registry.reserve(self.root / "runs" / "two")

    def test_builder_cli_help_is_available(self) -> None:
        script = Path(__file__).resolve().parent.parent / "build-editor-find-f2-retained-pack.py"
        result = subprocess.run([str(script), "--help"], capture_output=True, text=True, check=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("RUN_ID=ABSOLUTE_PREFIX", result.stdout)


if __name__ == "__main__":
    unittest.main()
