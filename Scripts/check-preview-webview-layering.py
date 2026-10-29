#!/usr/bin/env python3
"""Keep production WebKit construction behind PreviewController's network policy."""

from pathlib import Path
import re
import sys


ALLOWED_CONSTRUCTORS = {
    "Packages/PreviewKit/Sources/PreviewKit/PreviewController.swift": {"WKWebView"},
    "Packages/PreviewKit/Sources/PreviewKit/PreviewController+Configuration.swift": {
        "WKWebViewConfiguration"
    },
}
CONSTRUCTOR = re.compile(r"\b(WKWebView(?:Configuration)?)\s*(?:\.\s*init\s*)?\(")


def find_violations(root: Path) -> list[str]:
    source_roots = [root / "App", root / "AppIOS"]
    source_roots.extend(sorted((root / "Packages").glob("*/Sources")))
    violations = []
    for source_root in source_roots:
        for path in sorted(source_root.rglob("*.swift")):
            relative = path.relative_to(root).as_posix()
            source = path.read_text()
            allowed = ALLOWED_CONSTRUCTORS.get(relative, set())
            for match in CONSTRUCTOR.finditer(source):
                name = match.group(1)
                if name not in allowed:
                    line = source.count("\n", 0, match.start()) + 1
                    violations.append(f"{relative}:{line}: {name} must be created by PreviewController")
    return violations


def main() -> int:
    violations = find_violations(Path(__file__).resolve().parent.parent)
    if violations:
        print("\n".join(violations), file=sys.stderr)
        print("error: install the preview network policy before loading a page (agent.md section 7.1)",
              file=sys.stderr)
    return int(bool(violations))


if __name__ == "__main__":
    sys.exit(main())
