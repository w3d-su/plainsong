from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

from editor_find_f2_evidence.errors import AuditError
from editor_find_f2_evidence.logs import validate_timings, validate_warning_negative_control, validate_warning_phase
from editor_find_f2_evidence.monitor import validate_outer
from editor_find_f2_evidence.schema import load_schema

from .fixture import outer_status, raw_log


class ValidationControlTests(unittest.TestCase):
    def test_warning_position_and_timing_positive_controls(self) -> None:
        text = raw_log()
        validate_warning_phase(text)
        validate_warning_negative_control(text)
        self.assertEqual(set(validate_timings(text, "fixture")), {"zero", "sparse", "dense-truncated"})

    def test_warning_moved_inside_interval_is_rejected_semantically(self) -> None:
        lines = raw_log().splitlines(keepends=True)
        moved = lines.pop(0)
        begin = next(index for index, line in enumerate(lines) if "PHASE_BEGIN" in line)
        lines.insert(begin + 1, moved)
        with self.assertRaisesRegex(AuditError, "during the measured edits"):
            validate_warning_phase("".join(lines))

    def test_outer_timeout_is_rejected(self) -> None:
        schema = load_schema()
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "outer.status.txt"
            path.write_text(outer_status(schema).replace("timed_out=0", "timed_out=1"), encoding="utf-8")
            with self.assertRaisesRegex(AuditError, "timed_out"):
                validate_outer(path, schema, "fixture")


if __name__ == "__main__":
    unittest.main()
