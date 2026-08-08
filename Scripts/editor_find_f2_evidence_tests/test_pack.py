from __future__ import annotations

import json
import os
import re
import subprocess
import tempfile
import unittest
from pathlib import Path

from editor_find_f2_evidence.errors import AuditError
from editor_find_f2_evidence.artifact_hash import hash_artifact
from editor_find_f2_evidence.pack import EXPECTED_ARTIFACTS, validate_pack
from editor_find_f2_evidence.strict_io import sha256_file

from .fixture import create_pack, digest_record, rewrite_inventory, write


class PackTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="f2-pack-tests.", dir="/private/tmp")
        root = Path(self.temporary.name)
        self.pack = root / "pack"
        self.artifacts = root / "artifacts"
        self.pack.mkdir(mode=0o700)
        self.artifacts.mkdir(mode=0o700)
        create_pack(self.pack, self.artifacts)

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

    def test_positive_compact_and_full_audits(self) -> None:
        self.assertEqual(len(validate_pack(self.pack, None)), 6)
        self.assertEqual(len(validate_pack(self.pack, self.artifacts)), 6)

    def test_external_pack_inventory_trust_root_is_enforced(self) -> None:
        expected = sha256_file(self.pack / "SHA256SUMS")
        self.assertEqual(len(validate_pack(self.pack, None, expected)), 6)
        with self.assertRaisesRegex(AuditError, "inventory trust-root"):
            validate_pack(self.pack, None, "0" * 64)

    def test_retained_current_auditor_wrapper_is_complete(self) -> None:
        script = self.pack / "reference/check-editor-find-f2-retained-evidence.py"
        result = subprocess.run(
            [str(script), str(self.pack), "--allow-partial"],
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("F2 RETAINED EVIDENCE PARTIAL runs=6", result.stdout)

    def test_competition_sample_is_rejected_after_resealing(self) -> None:
        path = self.pack / "runs/debug-1/competition-monitor.log"
        write(path, "999 1 /usr/bin/xcodebuild\n")
        self.reseal(path)
        with self.assertRaisesRegex(AuditError, "competing process"):
            validate_pack(self.pack, None)

    def test_monitor_endpoint_tamper_is_rejected_after_resealing(self) -> None:
        path = self.pack / "runs/debug-1/competition-monitor.status.txt"
        text = path.read_text(encoding="utf-8").replace(
            "last_sample_started_utc=2026-08-08T00:00:01.400000Z",
            "last_sample_started_utc=2026-08-08T00:00:01.200000Z",
        )
        write(path, text)
        self.reseal(path)
        with self.assertRaisesRegex(AuditError, "last sample endpoint"):
            validate_pack(self.pack, None)

    def test_monitor_sampling_gap_is_rejected_after_resealing(self) -> None:
        path = self.pack / "runs/debug-1/competition-monitor.samples.txt"
        text = path.read_text(encoding="utf-8").replace(
            "started_utc=2026-08-08T00:00:01.200000Z finished_utc=2026-08-08T00:00:01.300000Z",
            "started_utc=2026-08-08T00:00:02.200000Z finished_utc=2026-08-08T00:00:02.300000Z",
        )
        write(path, text)
        self.reseal(path)
        with self.assertRaisesRegex(AuditError, "sampling gap"):
            validate_pack(self.pack, None)

    def test_provenance_path_escape_is_rejected_after_resealing(self) -> None:
        path = self.pack / "runs/debug-1/full-artifact-provenance.json"
        value = json.loads(path.read_text(encoding="utf-8"))
        value["artifacts"]["sourceArchive"]["artifactRootPath"] = "../escape"
        write(path, json.dumps(value, sort_keys=True) + "\n")
        rewrite_inventory(self.pack)
        with self.assertRaisesRegex(AuditError, "escapes"):
            validate_pack(self.pack, self.artifacts)

    def test_pack_symlink_and_case_collision_are_rejected(self) -> None:
        link = self.pack / "link"
        os.symlink(self.pack / "manifest.json", link)
        with self.assertRaisesRegex(AuditError, "symlink"):
            validate_pack(self.pack, None)
        link.unlink()
        inventory = self.pack / "SHA256SUMS"
        original = inventory.read_text(encoding="ascii")
        manifest_line = next(line for line in original.splitlines() if line.endswith("  manifest.json"))
        write(inventory, manifest_line.replace("manifest.json", "MANIFEST.JSON") + "\n" + original)
        with self.assertRaisesRegex(AuditError, "case-colliding"):
            validate_pack(self.pack, None)

    def test_full_artifact_hash_tamper_is_rejected(self) -> None:
        path = self.artifacts / "debug-1/sourceArchive"
        write(path, b"tampered")
        with self.assertRaisesRegex(AuditError, "hash differs"):
            validate_pack(self.pack, self.artifacts)

    def test_rehashed_build_manifest_must_bind_to_evidence(self) -> None:
        path = self.artifacts / "debug-1/buildManifest"
        write(path, path.read_bytes() + b"tampered=value\n")
        self.reseal_full_artifact("buildManifest")
        with self.assertRaisesRegex(AuditError, "build manifest evidence binding"):
            validate_pack(self.pack, self.artifacts)

    def test_rehashed_raw_log_must_bind_to_evidence(self) -> None:
        path = self.artifacts / "debug-1/rawLog"
        write(path, path.read_bytes() + b"tampered\n")
        self.reseal_full_artifact("rawLog")
        with self.assertRaisesRegex(AuditError, "rawLog retained-evidence binding"):
            validate_pack(self.pack, self.artifacts)

    def test_rehashed_xcresult_must_bind_to_evidence(self) -> None:
        write(self.artifacts / "debug-1/xcresult/tampered", b"tampered")
        self.reseal_full_artifact("xcresult")
        with self.assertRaisesRegex(AuditError, "xcresult retained-evidence binding"):
            validate_pack(self.pack, self.artifacts)

    def test_rehashed_source_snapshot_must_bind_to_build_manifest(self) -> None:
        write(self.artifacts / "debug-1/sourceSnapshot/tampered", b"tampered")
        self.reseal_full_artifact("sourceSnapshot")
        with self.assertRaisesRegex(AuditError, "sourceSnapshot retained-evidence binding"):
            validate_pack(self.pack, self.artifacts)

    def test_pack_group_writable_file_is_rejected(self) -> None:
        path = self.pack / "manifest.json"
        path.chmod(0o664)
        with self.assertRaisesRegex(AuditError, "not owner-controlled"):
            validate_pack(self.pack, None)

    def test_retained_capture_helper_tamper_is_rejected_after_resealing(self) -> None:
        path = self.pack / "reference/editor-find-f2-capture/processes.sh"
        write(path, path.read_bytes() + b"# tampered\n")
        rewrite_inventory(self.pack)
        with self.assertRaisesRegex(AuditError, "tooling hash differs"):
            validate_pack(self.pack, None)

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
            validate_pack(self.pack, None)

    def test_cli_default_is_open_and_allow_partial_is_explicit(self) -> None:
        script = Path(__file__).resolve().parent.parent / "check-editor-find-f2-retained-evidence.py"
        default = subprocess.run([str(script), str(self.pack)], capture_output=True, text=True, check=False)
        self.assertEqual(default.returncode, 3)
        self.assertIn("PARTIAL", default.stdout)
        allowed = subprocess.run(
            [str(script), str(self.pack), "--allow-partial"], capture_output=True, text=True, check=False
        )
        self.assertEqual(allowed.returncode, 0, allowed.stderr)
        self.assertIn("F2 OPEN F8", allowed.stdout)
        self.assertNotIn("historical-uncorrelated-target-process", allowed.stdout)

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
