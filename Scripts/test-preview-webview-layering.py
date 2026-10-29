#!/usr/bin/env python3
"""Regression coverage for the production WebKit construction lint gate."""

from pathlib import Path
import runpy
import tempfile
import unittest


CHECKER = runpy.run_path(str(Path(__file__).with_name("check-preview-webview-layering.py")))


class PreviewWebViewLayeringTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="plainsong-webview-layering-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)

    def write_source(self, relative, source):
        path = self.root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(source)

    def violations(self):
        return CHECKER["find_violations"](self.root)

    def test_allows_only_the_existing_factory_files(self):
        self.write_source("Packages/PreviewKit/Sources/PreviewKit/PreviewController.swift",
                          "let view = WKWebView(frame: .zero, configuration: configuration)")
        self.write_source("Packages/PreviewKit/Sources/PreviewKit/PreviewController+Configuration.swift",
                          "let configuration = WKWebViewConfiguration()")
        self.assertEqual(self.violations(), [])

    def test_rejects_construction_in_each_production_layer(self):
        for path in ["App/QuickLook.swift", "AppIOS/Print.swift",
                     "Packages/Other/Sources/Other/Preview.swift",
                     "Packages/PreviewKit/Sources/PreviewKit/PreviewController+QuickLook.swift"]:
            with self.subTest(path=path):
                self.write_source(path, "let view = WKWebView()")
                self.assertTrue(any(message.startswith(path + ":1:") for message in self.violations()))

    def test_does_not_grant_both_constructors_to_either_factory_file(self):
        self.write_source("Packages/PreviewKit/Sources/PreviewKit/PreviewController.swift",
                          "let configuration = WKWebViewConfiguration()")
        self.write_source("Packages/PreviewKit/Sources/PreviewKit/PreviewController+Configuration.swift",
                          "let view = WKWebView()")
        self.assertEqual(len(self.violations()), 2)

    def test_catches_qualified_multiline_and_explicit_initializers(self):
        self.write_source("App/QuickLook.swift", """import WebKit
let view = WebKit.WKWebView
    (frame: .zero, configuration: configuration)
let configuration = WKWebViewConfiguration . init ()
""")
        violations = self.violations()
        self.assertEqual(len(violations), 2)
        self.assertIn("App/QuickLook.swift:2:", violations[0])
        self.assertIn("App/QuickLook.swift:4:", violations[1])

    def test_excludes_test_and_probe_sources(self):
        for path in ["AppTests/Export.swift", "AppIOSTests/Preview.swift",
                     "Packages/PreviewKit/Tests/PreviewKitTests/Probe.swift", "Scripts/Probe.swift"]:
            self.write_source(path, "let view = WKWebView(); let config = WKWebViewConfiguration()")
        self.assertEqual(self.violations(), [])


if __name__ == "__main__":
    unittest.main()
