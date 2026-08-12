from __future__ import annotations

import json
import os
import re
import subprocess
import tempfile
import unittest
from dataclasses import replace
from pathlib import Path

from editor_find_f2_evidence.errors import AuditError
from editor_find_f2_evidence.artifact_hash import hash_artifact, hash_source_archive_tree
from editor_find_f2_evidence.full_artifacts import EXPECTED_ARTIFACTS
from editor_find_f2_evidence.pack import validate_pack
from editor_find_f2_evidence.strict_io import sha256_file

from .fixture import (
    create_pack,
    digest_record,
    rewrite_inventory,
    write,
    write_source_archive,
)


class PackTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="f2-pack-tests.", dir="/private/tmp")
        root = Path(self.temporary.name)
        self.pack = root / "pack"
        self.artifacts = root / "artifacts"
        self.pack.mkdir(mode=0o700)
        self.artifacts.mkdir(mode=0o700)
        self.schema = create_pack(self.pack, self.artifacts)

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def reseal(self, path: Path) -> None:
        write(Path(str(path) + ".sha256"), digest_record(path))
        rewrite_inventory(self.pack)

    def reseal_full_artifact(self, name: str) -> None:
        provenance_path = self.pack / "runs/debug-1/full-artifact-provenance.json"
        value = json.loads(provenance_path.read_text(encoding="utf-8"))
        _, hash_mode = EXPECTED_ARTIFACTS[name]
        artifact_path = self.artifacts / value["artifacts"][name]["artifactRootPath"]
        digest = (
            sha256_file(artifact_path)
            if hash_mode == "file-sha256"
            else hash_artifact(
                artifact_path,
                hash_mode == "resolved-package-input-sha256",
            )
        )
        value["artifacts"][name]["sha256"] = digest
        write(provenance_path, json.dumps(value, sort_keys=True) + "\n")
        rewrite_inventory(self.pack)

    def rewrite_run_binding(
        self,
        build_replacements: dict[str, str],
        provenance_replacements: dict[str, tuple[str, str | None]],
    ) -> None:
        provenance_path = self.pack / "runs/debug-1/full-artifact-provenance.json"
        provenance = json.loads(provenance_path.read_text(encoding="utf-8"))
        build_path = self.artifacts / provenance["artifacts"]["buildManifest"]["artifactRootPath"]
        lines = []
        for line in build_path.read_text(encoding="utf-8").splitlines():
            key, value = line.split("=", 1)
            lines.append(f"{key}={build_replacements.get(key, value)}")
        write(build_path, "\n".join(lines) + "\n")
        build_digest = sha256_file(build_path)
        provenance["artifacts"]["buildManifest"]["sha256"] = build_digest
        for name, (digest, original_path) in provenance_replacements.items():
            provenance["artifacts"][name]["sha256"] = digest
            if original_path is not None:
                provenance["artifacts"][name]["originalPath"] = original_path
        write(provenance_path, json.dumps(provenance, sort_keys=True) + "\n")
        evidence_path = self.pack / "runs/debug-1/evidence-manifest.txt"
        evidence = re.sub(
            r"build_manifest_sha256=[0-9a-f]{64}",
            f"build_manifest_sha256={build_digest}",
            evidence_path.read_text(encoding="utf-8"),
        )
        write(evidence_path, evidence)
        rewrite_inventory(self.pack)

    def test_positive_compact_and_full_audits(self) -> None:
        self.assertEqual(len(validate_pack(self.pack, None, integrity_schema=self.schema)), 6)
        self.assertEqual(len(validate_pack(self.pack, self.artifacts, integrity_schema=self.schema)), 6)

    def test_external_pack_inventory_trust_root_is_enforced(self) -> None:
        expected = sha256_file(self.pack / "SHA256SUMS")
        self.assertEqual(len(validate_pack(self.pack, None, expected, self.schema)), 6)
        with self.assertRaisesRegex(AuditError, "inventory trust-root"):
            validate_pack(self.pack, None, "0" * 64, self.schema)

    def test_current_auditor_wrapper_is_complete(self) -> None:
        script = Path(__file__).resolve().parent.parent / "check-editor-find-f2-retained-evidence.py"
        result = subprocess.run(
            [str(script), "--help"],
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("--expected-inventory-sha256", result.stdout)

    def test_competition_sample_is_rejected_after_resealing(self) -> None:
        path = self.pack / "runs/debug-1/competition-monitor.log"
        write(path, "999 1 /usr/bin/xcodebuild\n")
        self.reseal(path)
        with self.assertRaisesRegex(AuditError, "competing process"):
            validate_pack(self.pack, None, integrity_schema=self.schema)

    def test_monitor_endpoint_tamper_is_rejected_after_resealing(self) -> None:
        path = self.pack / "runs/debug-1/competition-monitor.status.txt"
        text = path.read_text(encoding="utf-8").replace(
            "last_sample_started_utc=2026-08-08T00:00:01.400000Z",
            "last_sample_started_utc=2026-08-08T00:00:01.200000Z",
        )
        write(path, text)
        self.reseal(path)
        with self.assertRaisesRegex(AuditError, "last sample endpoint"):
            validate_pack(self.pack, None, integrity_schema=self.schema)

    def test_monitor_sampling_gap_is_rejected_after_resealing(self) -> None:
        path = self.pack / "runs/debug-1/competition-monitor.samples.txt"
        text = path.read_text(encoding="utf-8").replace(
            "started_utc=2026-08-08T00:00:01.200000Z finished_utc=2026-08-08T00:00:01.300000Z",
            "started_utc=2026-08-08T00:00:02.200000Z finished_utc=2026-08-08T00:00:02.300000Z",
        )
        write(path, text)
        self.reseal(path)
        with self.assertRaisesRegex(AuditError, "sampling gap"):
            validate_pack(self.pack, None, integrity_schema=self.schema)

    def test_provenance_path_escape_is_rejected_after_resealing(self) -> None:
        path = self.pack / "runs/debug-1/full-artifact-provenance.json"
        value = json.loads(path.read_text(encoding="utf-8"))
        value["artifacts"]["sourceArchive"]["artifactRootPath"] = "../escape"
        write(path, json.dumps(value, sort_keys=True) + "\n")
        rewrite_inventory(self.pack)
        with self.assertRaisesRegex(AuditError, "escapes"):
            validate_pack(self.pack, self.artifacts, integrity_schema=self.schema)

    def test_pack_symlink_and_case_collision_are_rejected(self) -> None:
        link = self.pack / "link"
        os.symlink(self.pack / "manifest.json", link)
        with self.assertRaisesRegex(AuditError, "symlink"):
            validate_pack(self.pack, None, integrity_schema=self.schema)
        link.unlink()
        inventory = self.pack / "SHA256SUMS"
        original = inventory.read_text(encoding="ascii")
        manifest_line = next(line for line in original.splitlines() if line.endswith("  manifest.json"))
        write(inventory, manifest_line.replace("manifest.json", "MANIFEST.JSON") + "\n" + original)
        with self.assertRaisesRegex(AuditError, "case-colliding"):
            validate_pack(self.pack, None, integrity_schema=self.schema)

    def test_full_artifact_hash_tamper_is_rejected(self) -> None:
        path = self.artifacts / "debug-1/sourceArchive"
        write(path, b"tampered")
        with self.assertRaisesRegex(AuditError, "hash differs"):
            validate_pack(self.pack, self.artifacts, integrity_schema=self.schema)

    def test_rewritten_unrelated_archive_fails_compact_and_full_external_anchor(self) -> None:
        archive = self.artifacts / "debug-1/sourceArchive"
        write_source_archive(archive, {"unrelated.txt": b"unrelated source\n"})
        archive_digest = sha256_file(archive)
        tree_digest = hash_source_archive_tree(archive)
        self.rewrite_run_binding(
            {
                "source_archive_sha256": archive_digest,
                "source_tree_sha256": tree_digest,
            },
            {"sourceArchive": (archive_digest, None)},
        )
        for artifact_root in (None, self.artifacts):
            with self.subTest(artifact_root=artifact_root):
                with self.assertRaisesRegex(AuditError, "external anchor"):
                    validate_pack(
                        self.pack,
                        artifact_root,
                        integrity_schema=self.schema,
                    )

    def test_full_audit_rejects_unsafe_archive_member_without_extracting(self) -> None:
        archive = self.artifacts / "debug-1/sourceArchive"
        write_source_archive(archive, {"../escape": b"escape\n"})
        archive_digest = sha256_file(archive)
        unsafe_schema = replace(
            self.schema,
            source_archive_sha256=archive_digest,
            source_tree_sha256="0" * 64,
        )
        self.rewrite_run_binding(
            {
                "source_archive_sha256": archive_digest,
                "source_tree_sha256": "0" * 64,
            },
            {"sourceArchive": (archive_digest, None)},
        )
        with self.assertRaisesRegex(AuditError, "unsafe source archive member"):
            validate_pack(self.pack, self.artifacts, integrity_schema=unsafe_schema)

    def test_full_audit_rejects_app_executable_as_xctestrun(self) -> None:
        provenance_path = self.pack / "runs/debug-1/full-artifact-provenance.json"
        provenance = json.loads(provenance_path.read_text(encoding="utf-8"))
        host = (
            self.artifacts
            / provenance["artifacts"]["hostBundle"]["artifactRootPath"]
            / "Contents/MacOS/Plainsong"
        )
        xctestrun = self.artifacts / provenance["artifacts"]["xctestrun"]["artifactRootPath"]
        write(xctestrun, host.read_bytes())
        digest = hash_artifact(xctestrun)
        original = "/private/tmp/f2/debug-1.products/Build/Products/Debug/Plainsong.app/Contents/MacOS/Plainsong"
        self.rewrite_run_binding(
            {
                "xctestrun_relative_path": "Build/Products/Debug/Plainsong.app/Contents/MacOS/Plainsong",
                "xctestrun_sha256": digest,
            },
            {"xctestrun": (digest, original)},
        )
        with self.assertRaisesRegex(AuditError, r"Build/Products/\*\.xctestrun"):
            validate_pack(self.pack, self.artifacts, integrity_schema=self.schema)

    def test_rehashed_build_manifest_must_bind_to_evidence(self) -> None:
        path = self.artifacts / "debug-1/buildManifest"
        write(path, path.read_bytes() + b"tampered=value\n")
        self.reseal_full_artifact("buildManifest")
        with self.assertRaisesRegex(AuditError, "build manifest evidence binding"):
            validate_pack(self.pack, self.artifacts, integrity_schema=self.schema)

    def test_rehashed_raw_log_must_bind_to_evidence(self) -> None:
        path = self.artifacts / "debug-1/rawLog"
        write(path, path.read_bytes() + b"tampered\n")
        self.reseal_full_artifact("rawLog")
        with self.assertRaisesRegex(AuditError, "rawLog retained-evidence binding"):
            validate_pack(self.pack, self.artifacts, integrity_schema=self.schema)

    def test_rehashed_xcresult_must_bind_to_evidence(self) -> None:
        write(self.artifacts / "debug-1/xcresult/tampered", b"tampered")
        self.reseal_full_artifact("xcresult")
        with self.assertRaisesRegex(AuditError, "xcresult retained-evidence binding"):
            validate_pack(self.pack, self.artifacts, integrity_schema=self.schema)

    def test_rehashed_source_snapshot_must_bind_to_build_manifest(self) -> None:
        write(self.artifacts / "debug-1/sourceSnapshot/tampered", b"tampered")
        self.reseal_full_artifact("sourceSnapshot")
        with self.assertRaisesRegex(
            AuditError,
            "source snapshot has non-generated addition|sourceSnapshot retained-evidence binding",
        ):
            validate_pack(self.pack, self.artifacts, integrity_schema=self.schema)

    def test_full_audit_rejects_replaced_snapshot_after_resealing_every_binding(self) -> None:
        snapshot = self.artifacts / "debug-1/sourceSnapshot"
        write(snapshot / "payload", b"replacement source\n")
        snapshot_digest = hash_artifact(snapshot)
        self.rewrite_run_binding(
            {"build_input_sha256": snapshot_digest},
            {"sourceSnapshot": (snapshot_digest, None)},
        )
        with self.assertRaisesRegex(AuditError, "source snapshot (bytes|size) differs"):
            validate_pack(self.pack, self.artifacts, integrity_schema=self.schema)

    def test_full_audit_rejects_casefolded_artifact_ancestry_alias(self) -> None:
        provenance_path = self.pack / "runs/debug-1/full-artifact-provenance.json"
        provenance = json.loads(provenance_path.read_text(encoding="utf-8"))
        host_relative = provenance["artifacts"]["hostBundle"]["artifactRootPath"]
        executable_alias = (
            host_relative.upper()
            + "/Contents/MacOS/Plainsong"
        )
        provenance["artifacts"]["xctestrun"]["artifactRootPath"] = executable_alias
        write(provenance_path, json.dumps(provenance, sort_keys=True) + "\n")
        rewrite_inventory(self.pack)
        with self.assertRaisesRegex(AuditError, "artifact paths overlap"):
            validate_pack(self.pack, self.artifacts, integrity_schema=self.schema)

    def test_full_audit_rejects_hard_linked_artifact_identity_alias(self) -> None:
        provenance_path = self.pack / "runs/debug-1/full-artifact-provenance.json"
        provenance = json.loads(provenance_path.read_text(encoding="utf-8"))
        source = self.artifacts / provenance["artifacts"]["rawLog"]["artifactRootPath"]
        alias = self.artifacts / "debug-1/rawLogAlias"
        os.link(source, alias)
        provenance["artifacts"]["xctestrun"]["artifactRootPath"] = "debug-1/rawLogAlias"
        provenance["artifacts"]["xctestrun"]["sha256"] = hash_artifact(alias)
        write(provenance_path, json.dumps(provenance, sort_keys=True) + "\n")
        rewrite_inventory(self.pack)
        with self.assertRaisesRegex(AuditError, "artifact filesystem paths overlap"):
            validate_pack(self.pack, self.artifacts, integrity_schema=self.schema)

    def test_pack_group_writable_file_is_rejected(self) -> None:
        path = self.pack / "manifest.json"
        path.chmod(0o664)
        with self.assertRaisesRegex(AuditError, "not owner-controlled"):
            validate_pack(self.pack, None, integrity_schema=self.schema)

    def test_retained_capture_helper_tamper_is_rejected_after_resealing(self) -> None:
        path = self.pack / "reference/editor-find-f2-capture/processes.sh"
        write(path, path.read_bytes() + b"# tampered\n")
        rewrite_inventory(self.pack)
        with self.assertRaisesRegex(AuditError, "tooling hash differs"):
            validate_pack(self.pack, None, integrity_schema=self.schema)

    def test_run_status_must_bind_the_retained_capture_tooling(self) -> None:
        path = self.pack / "runs/debug-1/competition-monitor.status.txt"
        text = re.sub(
            r"capture_tooling_sha256=[0-9a-f]{64}",
            "capture_tooling_sha256=" + "0" * 64,
            path.read_text(encoding="utf-8"),
        )
        write(path, text)
        self.reseal(path)
        with self.assertRaisesRegex(AuditError, "capture tooling hash differs"):
            validate_pack(self.pack, None, integrity_schema=self.schema)

    def test_cli_default_is_open_and_allow_partial_is_explicit(self) -> None:
        repository = Path(__file__).resolve().parents[2]
        script = repository / "Scripts/check-editor-find-f2-retained-evidence.py"
        pack = repository / "docs/evidence/editor-find-f2-c871ddf-retained-pack"
        default = subprocess.run([str(script), str(pack)], capture_output=True, text=True, check=False)
        self.assertEqual(default.returncode, 3)
        self.assertIn("PARTIAL", default.stdout)
        allowed = subprocess.run(
            [str(script), str(pack), "--allow-partial"], capture_output=True, text=True, check=False
        )
        self.assertEqual(allowed.returncode, 0, allowed.stderr)
        self.assertIn("F2 OPEN F8", allowed.stdout)
        self.assertIn("historical-uncorrelated-target-process", allowed.stdout)

    def test_versioned_format_two_pack_keeps_historical_process_boundary_open(self) -> None:
        repository = Path(__file__).resolve().parents[2]
        script = repository / "Scripts/check-editor-find-f2-retained-evidence.py"
        pack = repository / "docs/evidence/editor-find-f2-c871ddf-retained-pack"
        result = subprocess.run(
            [str(script), str(pack), "--allow-partial"],
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("F2 OPEN historical-uncorrelated-target-process", result.stdout)


if __name__ == "__main__":
    unittest.main()
