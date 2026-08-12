#!/usr/bin/python3

"""Thin entrypoint for the modular F2 retained-evidence auditor."""

from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from editor_find_f2_evidence.cli import main


if __name__ == "__main__":
    main()
