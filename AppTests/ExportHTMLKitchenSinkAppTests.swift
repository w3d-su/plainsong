import AppKit
import MarkdownCore
@testable import Plainsong
@testable import PreviewKit
import WebKit
import XCTest

/// E3 (`docs/export-gates.md`): the real `Fixtures/kitchen-sink.md` goes through
/// File › Export as HTML…, and the written file, reopened in a fresh WebKit view, still
/// shows its GFM, math, highlighted code, task checkboxes and Mermaid diagrams under the
/// frozen light and dark styling.
@MainActor
final class ExportHTMLKitchenSinkAppTests: XCTestCase {
    /// The fixture's nine non-Mermaid fences, in document order.
    private static let fenceLanguages = [
        "swift", "javascript", "typescript", "python", "bash", "json", "yaml", "html", "css",
    ]

    /// `--hl-keyword` in `preview-src/src/styles/base.css`, per frozen theme.
    private static let keywordColors = ["light": "rgb(155, 35, 147)", "dark": "rgb(252, 95, 163)"]

    func testKitchenSinkMarkdownExportKeepsGFMMathCodeTasksAndMermaid() async throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "kitchen-sink", withExtension: "md"))
        let source = try String(contentsOf: url, encoding: .utf8)
        let support = ExportHTMLCommandAppTests()
        for theme in [PlainsongPreferences.PreviewTheme.light, .dark] {
            let fixture = try support.makeFixture(name: "kitchen-sink.md", text: source)
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            fixture.appState.preferences.setPreviewTheme(theme)
            let destination = fixture.exportsDirectory.appendingPathComponent("kitchen-sink-\(theme.rawValue).html")
            let recorder = fixture.record(returning: [destination])
            try await XCTUnwrap(fixture.appState.exportCurrentDocumentAsHTML()).value

            guard case let .exported(_, omissions, _) = recorder.results.first?.result else {
                return XCTFail("Expected the kitchen-sink export under \(theme): \(recorder.results)")
            }
            // `./assets/example-image.png` is the only image, and the fixture folder lacks it.
            XCTAssertEqual(omissions, 1, "\(theme)")
            XCTAssertEqual(recorder.requests.first?.defaultFileName, "Kitchen Sink Fixture.html")
            let html = try String(contentsOf: destination, encoding: .utf8)
            support.assertStandalone(html, fixture: fixture)
            XCTAssertTrue(html.contains("<title>Kitchen Sink Fixture</title>"), "\(theme)")
            let body = try XCTUnwrap(html.range(of: "<body").map { String(html[$0.lowerBound...]) })
            // Only frontmatter carries these; the H1's generated id is `kitchen-sink-fixture`.
            for value in ["slug:", "Markdown coverage for Plainsong", "hero.png"] {
                XCTAssertFalse(body.contains(value), "frontmatter \(value) leaked into the body")
            }

            let rendered = try await Self.renderedFeatures(of: destination)
            assertKitchenSink(rendered, theme: theme.rawValue)
        }
    }

    private func assertKitchenSink(_ rendered: [String: Any], theme: String) {
        let label = "kitchen-sink \(theme)"
        XCTAssertEqual(rendered["theme"] as? String, theme, label)
        // GFM: table with the right-aligned Syntax column, strikethrough, autolinks.
        XCTAssertEqual(rendered["tables"] as? Int, 1, label)
        XCTAssertEqual(rendered["tableRows"] as? Int, 4, label)
        // WebKit computes the cell's `align="right"` as `-webkit-right`.
        XCTAssertEqual(rendered["syntaxColumnAlign"] as? String, "-webkit-right", label)
        XCTAssertEqual(rendered["deleted"] as? [String], ["strikethrough"], label)
        let links = rendered["links"] as? [String] ?? []
        for href in ["https://example.com", "mailto:support@example.com", "https://example.com/blogeditor"] {
            XCTAssertTrue(links.contains(href), "\(label): missing link \(href) in \(links)")
        }
        // Task checkboxes: five, two checked, none writable, all laid out.
        XCTAssertEqual(rendered["tasks"] as? Int, 5, label)
        XCTAssertEqual(rendered["checkedTasks"] as? Int, 2, label)
        XCTAssertEqual(rendered["disabledTasks"] as? Int, 5, label)
        XCTAssertEqual(rendered["visibleTasks"] as? Int, 5, label)
        // Math: one inline formula plus two display blocks, all typeset by KaTeX.
        XCTAssertEqual(rendered["displayMath"] as? Int, 2, label)
        XCTAssertEqual(rendered["math"] as? Int, 3, label)
        XCTAssertGreaterThan(rendered["mathGlyphs"] as? Int ?? 0, 0, label)
        // Highlighted code: every fence keeps its language and token spans, and the
        // frozen stylesheet still colors keywords.
        XCTAssertEqual(rendered["languages"] as? [String], Self.fenceLanguages.map { "language-\($0)" }, label)
        XCTAssertEqual(rendered["highlightedBlocks"] as? Int, Self.fenceLanguages.count, label)
        XCTAssertEqual(rendered["keywordColor"] as? String, Self.keywordColors[theme], label)
        XCTAssertNotEqual(rendered["keywordColor"] as? String, rendered["bodyColor"] as? String, label)
        // Mermaid: both diagrams are rendered SVG carrying their own labels.
        let diagrams = rendered["mermaid"] as? [String] ?? []
        XCTAssertEqual(diagrams.count, 2, label)
        XCTAssertTrue(diagrams.first?.contains("Render With Unified Pipeline") ?? false, label)
        XCTAssertTrue(diagrams.last?.contains("renderComplete(version)") ?? false, label)
        XCTAssertEqual(rendered["mermaidSources"] as? Int, 0, "\(label): a Mermaid fence stayed raw source")
    }

    /// Loads the written file in a fresh non-persistent WebKit view, as a reader would
    /// open it, and reports what it actually renders.
    private static func renderedFeatures(of destination: URL) async throws -> [String: Any] {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let reopened = WKWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 700), configuration: configuration)
        let navigation = ExportOfflineNavigationWaiter()
        reopened.navigationDelegate = navigation
        reopened.loadFileURL(destination, allowingReadAccessTo: destination)
        let deadline = Date().addingTimeInterval(15)
        while !navigation.didFinish, Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(navigation.didFinish)
        XCTAssertNil(navigation.error)
        let json = try await reopened.evaluateJavaScriptReply(featureScript) as? String
        let data = try XCTUnwrap(json?.data(using: .utf8))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private static let featureScript = """
    (() => {
      const all = (selector) => [...document.querySelectorAll(selector)];
      const boxes = all('input[type="checkbox"]');
      const syntaxCell = document.querySelector('table tbody tr td:nth-child(2)');
      const keyword = document.querySelector('pre code.hljs .hljs-keyword');
      const codes = all('pre code.hljs');
      return JSON.stringify({
        theme: document.documentElement.dataset.theme,
        tables: all('table').length,
        tableRows: all('table tbody tr').length,
        syntaxColumnAlign: syntaxCell ? getComputedStyle(syntaxCell).textAlign : '',
        deleted: all('del').map((element) => element.textContent),
        links: all('a[href]').map((anchor) => anchor.getAttribute('href')),
        tasks: boxes.length,
        checkedTasks: boxes.filter((box) => box.checked).length,
        disabledTasks: boxes.filter((box) => box.disabled).length,
        visibleTasks: boxes.filter((box) => box.getBoundingClientRect().width > 0).length,
        math: all('.katex').length,
        displayMath: all('.katex-display').length,
        mathGlyphs: all('.katex-html .mord').length,
        languages: codes.map((code) => [...code.classList].find((name) => name.startsWith('language-')) || ''),
        highlightedBlocks: codes.filter((code) => code.querySelector('[class^="hljs-"]')).length,
        keywordColor: keyword ? getComputedStyle(keyword).color : '',
        bodyColor: getComputedStyle(document.body).color,
        mermaid: all('.mermaid-rendered svg').map((svg) => svg.textContent),
        mermaidSources: all('code.language-mermaid').length,
      });
    })()
    """
}
