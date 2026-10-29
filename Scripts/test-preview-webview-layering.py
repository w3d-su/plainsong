#!/usr/bin/env python3
"""Regression coverage for the production WebKit construction lint gate."""

from pathlib import Path
import json
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

    def violations(self, project_spec=None):
        return CHECKER["find_violations"](self.root, project_spec)

    def test_allows_only_the_existing_factory_files(self):
        self.write_source(
            "Packages/PreviewKit/Sources/PreviewKit/PreviewController.swift",
            "\n".join([
                "import WebKit",
                "public let webView: WKWebView",
                "webView = WKWebView(frame: .zero, configuration: configuration)",
                "private extension WKWebView {}",
            ]),
        )
        self.write_source(
            "Packages/PreviewKit/Sources/PreviewKit/PreviewController+Configuration.swift",
            "\n".join([
                "import WebKit",
                "let configuration = WKWebViewConfiguration()",
                "func make() -> WKWebViewConfiguration { configuration }",
            ]),
        )
        self.write_source(
            "App/AppState+ExportHTML.swift",
            "import WebKit\ncontroller.webView.frame = .zero\n",
        )
        self.write_source(
            "App/ExportHTMLOperation.swift",
            "import WebKit\nvar provider: (() -> WKWebsiteDataStore)?\n",
        )
        self.assertEqual(self.violations(), [])

    def test_rejects_construction_in_each_production_layer(self):
        for path in ["App/QuickLook.swift", "AppIOS/Print.swift",
                     "Packages/Other/Sources/Other/Preview.swift",
                     "Packages/PreviewKit/Sources/PreviewKit/PreviewController+QuickLook.swift"]:
            with self.subTest(path=path):
                self.write_source(path, "let view = WKWebView()")
                self.assertTrue(any(message.startswith(path + ":1:") for message in self.violations()))

    def test_does_not_grant_both_constructors_to_either_factory_file(self):
        self.write_source(
            "Packages/PreviewKit/Sources/PreviewKit/PreviewController.swift",
            "let configuration = WKWebViewConfiguration()",
        )
        self.write_source(
            "Packages/PreviewKit/Sources/PreviewKit/PreviewController+Configuration.swift",
            "let view = WKWebView()",
        )
        self.assertEqual(len(self.violations()), 2)

    def test_catches_qualified_multiline_and_explicit_initializers(self):
        self.write_source(
            "App/QuickLook.swift",
            "\n".join([
                "import WebKit",
                "let view = WebKit.WKWebView",
                "    (frame: .zero, configuration: configuration)",
                "let configuration = WKWebViewConfiguration . init ()",
            ]),
        )
        self.assertEqual(self.violations(), [
            "App/QuickLook.swift:1: import WebKit outside PreviewController",
            "App/QuickLook.swift:2: WKWebView must be created by PreviewController",
            "App/QuickLook.swift:4: WKWebViewConfiguration must be created by PreviewController",
        ])

    def test_excludes_test_probe_and_vendored_header_sources(self):
        for path in ["AppTests/Export.swift", "AppIOSTests/Preview.swift",
                     "Packages/PreviewKit/Tests/PreviewKitTests/Probe.swift", "Scripts/Probe.swift"]:
            self.write_source(path, "import WebKit\nlet view = WKWebView()\n")
        self.write_source(
            "Packages/SyntaxKit/Sources/TreeSitter/include/webkit.h",
            "#import <WebKit/WebKit.h>\nWKWebView *view;\n",
        )
        self.write_source("Packages/SyntaxKit/Sources/TreeSitter/src/probe.c", "WKWebView *view;\n")
        self.assertEqual(self.violations(), [])

    def test_rejects_aliases_subclasses_and_inferred_initializers_inside_previewkit(self):
        path = "Packages/PreviewKit/Sources/PreviewKit/PreviewController+QuickLook.swift"
        self.write_source(path, "\n".join([
            "typealias WV = WKWebView",
            "typealias Config = WebKit.WKWebViewConfiguration",
            "final class MyWebView: WebKit.WKWebView {}",
            "let view: WKWebView = .init(frame: .zero, configuration: configuration)",
            "let configuration: WKWebViewConfiguration =",
            "    .init()",
            "let optional: WKWebView?",
            "    = .init(frame: .zero, configuration: configuration)",
        ]))
        violations = self.violations()
        self.assertIn(f"{path}:1: WebKit alias bypasses the PreviewController constructor", violations)
        self.assertIn(f"{path}:2: WebKit alias bypasses the PreviewController constructor", violations)
        self.assertIn(f"{path}:3: WKWebView subclass bypasses the PreviewController constructor", violations)
        self.assertIn(f"{path}:4: WKWebView inferred .init bypasses the PreviewController constructor", violations)
        self.assertIn(f"{path}:5: WKWebViewConfiguration inferred .init bypasses the PreviewController constructor", violations)
        self.assertIn(f"{path}:7: WKWebView inferred .init bypasses the PreviewController constructor", violations)

    def test_rejects_metatypes_dynamic_lookup_and_typeof_init(self):
        self.write_source(
            "Packages/PreviewKit/Sources/PreviewKit/PreviewController.swift",
            "\n".join([
                "let webView = WKWebView(frame: .zero, configuration: configuration)",
                "let type = WKWebView.self",
                "let make = WKWebView.init",
                "let copy = type(of: webView).init(frame: .zero, configuration: configuration)",
                'let dynamic = NSClassFromString("WKWebView")',
                'let other = NSClassFromString("NSView")',
            ]),
        )
        self.write_source(
            "App/QuickLook.swift",
            "\n".join([
                'let dynamic = objc_getClass("WKWebViewConfiguration")',
                "let copy = type(of: preview.webView).init()",
            ]),
        )
        violations = self.violations()
        prefix = "Packages/PreviewKit/Sources/PreviewKit/PreviewController.swift"
        self.assertIn(f"{prefix}:2: WKWebView metatype bypasses the PreviewController constructor", violations)
        self.assertIn(f"{prefix}:3: WKWebView metatype bypasses the PreviewController constructor", violations)
        self.assertIn(f"{prefix}:4: type(of:).init bypasses the PreviewController constructor", violations)
        self.assertIn(f"{prefix}:5: NSClassFromString of a WK class bypasses the PreviewController constructor", violations)
        self.assertNotIn(f"{prefix}:6: NSClassFromString of a WK class bypasses the PreviewController constructor", violations)
        self.assertIn("App/QuickLook.swift:1: objc_getClass of a WK class bypasses the PreviewController constructor", violations)
        self.assertIn("App/QuickLook.swift:2: type(of:).init bypasses the PreviewController constructor", violations)

    def test_rejects_swiftui_web_views_without_flagging_the_appkit_host(self):
        self.write_source(
            "AppIOS/Print.swift",
            "import SwiftUI\nlet page = WebView(url: url)\nlet modern = WebPage()\n",
        )
        self.write_source(
            "App/Views/WorkspaceDetail.swift",
            "import SwiftUI\nMarkdownPreviewWebView(controller: controller)\n",
        )
        self.assertEqual(self.violations(), [
            "AppIOS/Print.swift:2: SwiftUI WebView bypasses the PreviewController constructor",
            "AppIOS/Print.swift:3: SwiftUI WebPage bypasses the PreviewController constructor",
        ])

    def test_ignores_comments_and_string_literals_but_not_interpolation(self):
        self.write_source("App/QuickLook.swift", "\n".join([
            "/// Calls WKWebView(frame:)",
            'let label = "WKWebViewConfiguration()"',
            "/* outer /* WKWebView() */ still WKWebViewConfiguration() */",
            'let raw = #"WKWebView()"#',
            'let prose = """',
            "WKWebView()",
            '"""',
            'let built = "\\(WKWebView())"',
            'let rawBuilt = #"\\#(WKWebViewConfiguration())"#',
        ]))
        self.write_source("App/Legacy.m", "\n".join([
            "// [[WKWebView alloc] init]",
            'NSString *label = @"WKWebViewConfiguration()";',
            'id type = NSClassFromString(@"WKWebView");',
        ]))
        self.assertEqual(self.violations(), [
            "App/Legacy.m:3: NSClassFromString of a WK class bypasses the PreviewController constructor",
            "App/QuickLook.swift:8: WKWebView must be created by PreviewController",
            "App/QuickLook.swift:9: WKWebViewConfiguration must be created by PreviewController",
        ])

    def test_scans_objective_c_construction_outside_the_allowlist(self):
        self.write_source("App/Legacy.m", "\n".join([
            "#import <WebKit/WebKit.h>",
            "static void make(void) {",
            "    WKWebView *view = [[WKWebView alloc] initWithFrame:CGRectZero "
            "configuration:[WKWebViewConfiguration new]];",
            "}",
        ]))
        self.write_source("Packages/PreviewKit/Sources/PreviewKit/Legacy.mm", "\n".join([
            "@import WebKit;",
            "@interface MyWebView : WKWebView",
            "@end",
            "static WKWebView *make(void) { return [[WKWebView alloc] init]; }",
        ]))
        violations = self.violations()
        self.assertIn("App/Legacy.m:1: import WebKit outside PreviewController", violations)
        self.assertIn("App/Legacy.m:3: WKWebView must be created by PreviewController", violations)
        self.assertIn("App/Legacy.m:3: WKWebViewConfiguration must be created by PreviewController", violations)
        self.assertIn(
            "Packages/PreviewKit/Sources/PreviewKit/Legacy.mm:2: "
            "WKWebView subclass bypasses the PreviewController constructor",
            violations,
        )
        self.assertIn(
            "Packages/PreviewKit/Sources/PreviewKit/Legacy.mm:4: "
            "WKWebView must be created by PreviewController",
            violations,
        )

    def test_rejects_quoted_objective_c_imports_without_flagging_prose(self):
        self.write_source("App/Legacy.mm", "\n".join([
            '#import "WebKit/WebKit.h"',
            '// #import "WebKit/WebKit.h"',
            '/*',
            '#import "WebKit/WebKit.h"',
            '*/',
        ]))
        self.assertEqual(self.violations(), [
            "App/Legacy.mm:1: import WebKit outside PreviewController",
        ])

    def test_scans_new_non_test_targets_including_individual_source_files(self):
        self.write_source("QuickLookPreview/Preview.swift", "import WebKit\n")
        self.write_source("SharedPrint/Page.swift", "WebPage()\n")
        self.write_source("Helpers/Host.mm", "@import WebKit;\n")
        self.write_source("NewUnitTests/Preview.swift", "WKWebView()\n")
        self.write_source("NewUITests/Preview.swift", "WKWebView()\n")
        spec = {"targets": {
            "QuickLook": {"type": "app-extension", "sources": [{"path": "QuickLookPreview"}]},
            "Print": {"type": "framework", "sources": ["SharedPrint/Page.swift"]},
            "Host": {"type": "application", "sources": "Helpers"},
            "Unit": {"type": "bundle.unit-test", "sources": ["NewUnitTests"]},
            "UI": {"type": "bundle.ui-testing", "sources": [{"path": "NewUITests"}]},
        }}
        self.assertEqual(self.violations(spec), [
            "Helpers/Host.mm:1: import WebKit outside PreviewController",
            "QuickLookPreview/Preview.swift:1: import WebKit outside PreviewController",
            "SharedPrint/Page.swift:1: SwiftUI WebPage bypasses the PreviewController constructor",
        ])

    def test_reads_target_templates_through_the_resolved_xcodegen_spec(self):
        self.write_source("QuickLookPreview/Preview.swift", "import WebKit\n")
        self.write_source("project.yml", json.dumps({
            "name": "Fixture",
            "targetTemplates": {"Extension": {
                "type": "app-extension", "platform": "macOS",
                "sources": [{"path": "QuickLookPreview"}],
            }},
            "targets": {"QuickLook": {"templates": ["Extension"]}},
        }))
        self.assertEqual(self.violations(), [
            "QuickLookPreview/Preview.swift:1: import WebKit outside PreviewController",
        ])

    def test_single_line_quotes_do_not_hide_code_after_a_newline(self):
        self.write_source("App/Regex.swift", "\n".join([
            'let expression = /"/',
            'WKWebView()',
            'let rawExpression = #/"/#',
            'WKWebViewConfiguration()',
        ]))
        self.write_source("App/Legacy.m", "\n".join([
            "int quote = '\"';",
            '[[WKWebView alloc] init];',
        ]))
        self.assertEqual(self.violations(), [
            "App/Legacy.m:2: WKWebView must be created by PreviewController",
            "App/Regex.swift:2: WKWebView must be created by PreviewController",
            "App/Regex.swift:4: WKWebViewConfiguration must be created by PreviewController",
        ])

    def test_rejects_access_level_and_same_line_swift_imports(self):
        imports = [
            "public import WebKit", "package import WebKit", "internal import WebKit",
            "fileprivate import WebKit", "private import WebKit",
            "@_exported public import WebKit", "import Foundation; import WebKit",
            "import Foundation; internal import class WebKit.WKNavigationDelegate",
        ]
        for index, source in enumerate(imports):
            path = f"App/Imports{index}.swift"
            self.write_source(path, source)
        self.assertEqual(self.violations(), [
            f"App/Imports{index}.swift:1: import WebKit outside PreviewController"
            for index in range(len(imports))
        ])

    def test_rejects_objective_c_includes_without_flagging_comments(self):
        self.write_source("App/Legacy.mm", "\n".join([
            '#include <WebKit/WebKit.h>',
            '# include "WebKit/WKNavigationDelegate.h"',
            '// #include <WebKit/WebKit.h>',
            '/*',
            '#include "WebKit/WebKit.h"',
            '*/',
        ]))
        self.assertEqual(self.violations(), [
            "App/Legacy.mm:1: import WebKit outside PreviewController",
            "App/Legacy.mm:2: import WebKit outside PreviewController",
        ])

    def test_current_repository_has_no_violations(self):
        root = Path(__file__).resolve().parent.parent
        self.assertEqual(CHECKER["find_violations"](root), [])


if __name__ == "__main__":
    unittest.main()
