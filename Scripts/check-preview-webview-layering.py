#!/usr/bin/env python3
"""Keep production WebKit construction behind PreviewController's network policy.

This is a textual guard, not a Swift parser. It rejects WebKit imports outside
PreviewKit and the two export files that only name WebKit types, SwiftUI
WebView and WebPage calls anywhere in production sources, and, inside the
import allowlist, direct constructors other than PreviewController's two
factories. Aliases, subclasses, metatype references, inferred `.init`,
`type(of:).init`, and dynamic lookup of a WK class are rejected too.
Source roots include every non-test target in the resolved XcodeGen spec and
package Sources. Objective-C `.m` and `.mm` are scanned; vendored C headers are not.

Comments and string literals are ignored, except that a string passed to
`NSClassFromString` or `objc_getClass` is still inspected. Concatenated class
names and `removeAllContentRuleLists()` are outside this check.
"""

from pathlib import Path
import json
import re
import subprocess
import sys


ALLOWED_IMPORTS = {
    "App/AppState+ExportHTML.swift",
    "App/ExportHTMLOperation.swift",
}
ALLOWED_CONSTRUCTORS = {
    "Packages/PreviewKit/Sources/PreviewKit/PreviewController.swift": {"WKWebView"},
    "Packages/PreviewKit/Sources/PreviewKit/PreviewController+Configuration.swift": {
        "WKWebViewConfiguration"
    },
}
SOURCE_SUFFIXES = {".swift", ".m", ".mm"}
WEBKIT_TYPE = r"(?:WebKit\s*\.\s*)?WKWebView(?:Configuration)?"
CONSTRUCTOR = re.compile(rf"\b(WKWebView(?:Configuration)?)\s*(?:\.\s*init\s*)?\(")
METATYPE = re.compile(rf"\b({WEBKIT_TYPE})\s*\.\s*(self|init)\b")
TYPEALIAS = re.compile(rf"\btypealias\s+[A-Za-z_][A-Za-z0-9_]*\s*=\s*({WEBKIT_TYPE})\b")
INFERRED_INIT = re.compile(
    rf":\s*({WEBKIT_TYPE})\b(?:[ \t]*[?!])?"
    rf"(?:[ \t]*=[ \t]*\.init\b"
    rf"|[ \t]*\n[ \t]*=[ \t]*\.init\b"
    rf"|[ \t]*=[ \t]*\n[ \t]*\.init\b)"
)
CLASS_DECL = re.compile(
    r"\b(?:(?:public|open|internal|fileprivate|private|package|final|nonisolated|override)\s+)*"
    r"(?:class|actor)\s+[A-Za-z_][A-Za-z0-9_]*"
    r"(?:\s*<[^>\n]*>)?\s*:\s*([^{\n]+)"
)
OBJC_INTERFACE = re.compile(rf"@interface\s+[A-Za-z_][A-Za-z0-9_]*\s*:\s*({WEBKIT_TYPE})\b")
OBJC_ALLOC = re.compile(r"\[\s*(WKWebView(?:Configuration)?)\s+(?:alloc|new)\b")
WEBKIT_TOKEN = re.compile(r"\bWKWebView(?:Configuration)?\b")
SWIFTUI_WEB = re.compile(r"\b(WebView|WebPage)\s*\(")
TYPEOF_INIT = re.compile(r"\btype\s*\(\s*of\s*:\s*[^()\n]{0,180}\)\s*\.\s*init\b")
IMPORT_WEBKIT = re.compile(
    r"(?m)(?:^|;)[ \t]*(?:@[A-Za-z_][A-Za-z0-9_]*(?:\([^)\n]*\))?[ \t]+)*"
    r"(?:(?:public|package|internal|fileprivate|private)[ \t]+)?"
    r"import[ \t]+(?:(?:struct|class|enum|func|var|typealias|let)[ \t]+)?WebKit\b"
)
IMPORT_WEBKIT_OBJC = re.compile(
    r'(?m)^[ \t]*#\s*(?:import|include)[ \t]+(?:<WebKit/|"WebKit/)|'
    r"^[ \t]*@import[ \t]+WebKit\b"
)
DYNAMIC_LOOKUP = re.compile(r"\b(NSClassFromString|objc_getClass)\s*\(")


class ScannedSource:
    def __init__(self, text):
        self.text = text
        self.is_code = [True] * len(text)
        self.literals = {}
        self._scan_code(0, False)

    def code_text(self):
        chars = []
        for index, char in enumerate(self.text):
            chars.append(char if char == "\n" or self.is_code[index] else " ")
        return "".join(chars)

    def _blank(self, start, end):
        for index in range(start, end):
            self.is_code[index] = False

    def _scan_code(self, index, close_on_paren):
        text = self.text
        depth = 0
        while index < len(text):
            if close_on_paren and text[index] == ")":
                if depth == 0:
                    return index
                depth -= 1
                index += 1
                continue
            if close_on_paren and text[index] == "(":
                depth += 1
                index += 1
                continue
            if text.startswith("//", index):
                end = text.find("\n", index)
                self._blank(index, len(text) if end < 0 else end)
                if end < 0:
                    return len(text)
                index = end
                continue
            if text.startswith("/*", index):
                index = self._scan_block(index)
                continue
            opened = self._string_open(index)
            if opened is not None:
                index = self._scan_string(index, *opened)
                continue
            index += 1
        return index

    def _scan_block(self, index):
        text = self.text
        depth = 0
        while index < len(text):
            if text.startswith("/*", index):
                depth += 1
                self._blank(index, index + 2)
                index += 2
                continue
            if text.startswith("*/", index):
                depth -= 1
                self._blank(index, index + 2)
                index += 2
                if depth == 0:
                    return index
                continue
            self.is_code[index] = False
            index += 1
        return index

    def _string_open(self, index):
        text = self.text
        if index > 0 and text[index - 1] == "#":
            return None
        cursor = index
        while cursor < len(text) and text[cursor] == "#":
            cursor += 1
        if cursor >= len(text) or text[cursor] != '"':
            return None
        multiline = text.startswith('"""', cursor)
        hashes = cursor - index
        return hashes, multiline, hashes + (3 if multiline else 1)

    def _scan_string(self, index, hashes, multiline, open_len):
        text = self.text
        quote = index + hashes
        self._blank(index, index + open_len)
        content_start = index + open_len
        index += open_len
        line_is_blank = False
        while index < len(text):
            if not multiline and text[index] in "\r\n":
                self.literals[quote - hashes] = text[content_start:index]
                return index
            if self._interpolation_at(index, hashes):
                marker = 1 + hashes
                self._blank(index, index + marker + 1)
                index = self._scan_code(index + marker + 1, True)
                if index < len(text) and text[index] == ")":
                    self.is_code[index] = False
                    index += 1
                continue
            if hashes == 0 and text[index] == "\\":
                self.is_code[index] = False
                if index + 1 < len(text):
                    if text[index + 1] != "\n":
                        self.is_code[index + 1] = False
                    index += 2
                    line_is_blank = False
                    continue
            if multiline and text[index] == "\n":
                self.is_code[index] = False
                index += 1
                line_is_blank = True
                continue
            if multiline and line_is_blank and text[index] in " \t":
                self.is_code[index] = False
                index += 1
                continue
            if self._string_closes_at(index, hashes, multiline, line_is_blank):
                closer = (3 if multiline else 1) + hashes
                self.literals[quote if hashes == 0 else quote - hashes] = text[content_start:index]
                self._blank(index, index + closer)
                return index + closer
            line_is_blank = False
            self.is_code[index] = False
            index += 1
        self.literals[quote if hashes == 0 else quote - hashes] = text[content_start:]
        return index

    def _interpolation_at(self, index, hashes):
        marker = "\\" + ("#" * hashes) + "("
        return self.text.startswith(marker, index)

    def _string_closes_at(self, index, hashes, multiline, line_is_blank):
        text = self.text
        if multiline and not line_is_blank:
            return False
        delimiter = '"""' if multiline else '"'
        if not text.startswith(delimiter, index):
            return False
        after = index + len(delimiter)
        return text.startswith("#" * hashes, after)


def import_allowed(relative):
    return relative in ALLOWED_IMPORTS or relative.startswith("Packages/PreviewKit/Sources/")


def line_number(text, index):
    return text.count("\n", 0, index) + 1


def add(violations, relative, text, index, detail):
    violations.append(f"{relative}:{line_number(text, index)}: {detail}")


def inherits_webkit(clause):
    clause = re.split(r"\bwhere\b", clause, maxsplit=1)[0]
    for part in re.split(r"[,&]", clause):
        token = re.sub(r"\s+", "", part)
        token = re.sub(r"^WebKit\.", "", token)
        if token in {"WKWebView", "WKWebViewConfiguration"}:
            return True
    return False


def dynamic_name_is_webkit(scanned, index):
    while index < len(scanned.text) and scanned.text[index] in " \t\r\n":
        index += 1
    if index < len(scanned.text) and scanned.text[index] == "@":
        index += 1
        while index < len(scanned.text) and scanned.text[index] in " \t\r\n":
            index += 1
    content = scanned.literals.get(index)
    return content is not None and content.startswith("WK")


def read_project_spec(root):
    manifest = root / "project.yml"
    if not manifest.exists():
        return {"targets": {}}
    result = subprocess.run(
        ["xcodegen", "dump", "--type", "parsed-json", "--spec", str(manifest)],
        cwd=root, check=True, capture_output=True, text=True,
    )
    return json.loads(result.stdout)


def find_violations(root: Path, project_spec=None) -> list[str]:
    if project_spec is None:
        project_spec = read_project_spec(root)
    source_roots = [root / "App", root / "AppIOS"]
    for target in project_spec["targets"].values():
        if target["type"] in {"bundle.unit-test", "bundle.ui-testing"}:
            continue
        sources = target.get("sources", [])
        if isinstance(sources, str):
            sources = [sources]
        for source in sources:
            source_roots.append(root / (source if isinstance(source, str) else source["path"]))
    packages = root / "Packages"
    if packages.exists():
        source_roots.extend(sorted(path for path in packages.glob("*/Sources") if path.is_dir()))
    paths = set()
    for source_root in source_roots:
        if source_root.is_file() and source_root.suffix in SOURCE_SUFFIXES:
            paths.add(source_root)
        elif source_root.is_dir():
            paths.update(path for path in source_root.rglob("*")
                         if path.is_file() and path.suffix in SOURCE_SUFFIXES)
    violations = []
    for path in sorted(paths):
        relative = path.relative_to(root).as_posix()
        scan_source(relative, path.read_text(), violations)
    unique = []
    seen = set()
    for violation in sorted(violations, key=violation_key):
        if violation not in seen:
            seen.add(violation)
            unique.append(violation)
    return unique


def violation_key(message):
    relative, line, detail = message.split(":", 2)
    return relative, int(line), detail


def scan_source(relative, source, violations):
    scanned = ScannedSource(source)
    code = scanned.code_text()
    allowed = import_allowed(relative)
    if not allowed:
        for match in IMPORT_WEBKIT.finditer(code):
            add(violations, relative, source, match.start(), "import WebKit outside PreviewController")
        for match in IMPORT_WEBKIT_OBJC.finditer(source):
            if scanned.is_code[match.start()]:
                add(violations, relative, source, match.start(), "import WebKit outside PreviewController")
        for match in WEBKIT_TOKEN.finditer(code):
            add(violations, relative, source, match.start(),
                f"{match.group(0)} must be created by PreviewController")
    else:
        allowed_constructors = ALLOWED_CONSTRUCTORS.get(relative, set())
        for match in CONSTRUCTOR.finditer(code):
            name = match.group(1)
            if name not in allowed_constructors:
                add(violations, relative, source, match.start(),
                    f"{name} must be created by PreviewController")
        for match in METATYPE.finditer(code):
            if match.group(2) == "init" and re.match(r"\s*\(", code[match.end():]):
                continue
            add(violations, relative, source, match.start(),
                f"{match.group(1)} metatype bypasses the PreviewController constructor")
        for match in TYPEALIAS.finditer(code):
            add(violations, relative, source, match.start(),
                "WebKit alias bypasses the PreviewController constructor")
        for match in INFERRED_INIT.finditer(code):
            add(violations, relative, source, match.start(),
                f"{match.group(1)} inferred .init bypasses the PreviewController constructor")
        for match in CLASS_DECL.finditer(code):
            if inherits_webkit(match.group(1)):
                add(violations, relative, source, match.start(),
                    "WKWebView subclass bypasses the PreviewController constructor")
        for match in OBJC_INTERFACE.finditer(code):
            add(violations, relative, source, match.start(),
                "WKWebView subclass bypasses the PreviewController constructor")
        for match in OBJC_ALLOC.finditer(code):
            add(violations, relative, source, match.start(),
                f"{match.group(1)} must be created by PreviewController")
    for match in SWIFTUI_WEB.finditer(code):
        add(violations, relative, source, match.start(),
            f"SwiftUI {match.group(1)} bypasses the PreviewController constructor")
    for match in TYPEOF_INIT.finditer(code):
        add(violations, relative, source, match.start(),
            "type(of:).init bypasses the PreviewController constructor")
    for match in DYNAMIC_LOOKUP.finditer(source):
        if not scanned.is_code[match.start()]:
            continue
        if dynamic_name_is_webkit(scanned, match.end()):
            add(violations, relative, source, match.start(),
                f"{match.group(1)} of a WK class bypasses the PreviewController constructor")


def main() -> int:
    violations = find_violations(Path(__file__).resolve().parent.parent)
    if violations:
        print("\n".join(violations), file=sys.stderr)
        print("error: install the preview network policy before loading a page (agent.md section 7.1)",
              file=sys.stderr)
    return int(bool(violations))


if __name__ == "__main__":
    sys.exit(main())
