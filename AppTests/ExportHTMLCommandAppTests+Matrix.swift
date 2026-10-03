import AppKit
import MarkdownCore
@testable import Plainsong
@testable import PreviewKit
@testable import WorkspaceKit
import XCTest

@MainActor
extension ExportHTMLCommandAppTests {
    func testNamedMarkdownAndMDXFixturesAreEquivalentAcrossLayoutsAndFreezeAllThemes() async throws {
        let previousAppearance = NSApp.appearance
        defer { NSApp.appearance = previousAppearance }
        NSApp.appearance = NSAppearance(named: .darkAqua)
        XCTAssertEqual(NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]), .darkAqua)
        for (name, ext) in [("export-f-markdown", "md"), ("export-f-mdx", "mdx")] {
            let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: ext))
            let source = try String(contentsOf: url, encoding: .utf8)
            let fixture = try makeFixture(name: "post.\(ext)", text: source)
            fixture.appState.preferences.setExperimentalWYSIWYGEnabled(true)
            fixture.appState.preferences.setAllowsRemoteImages(true)
            for theme in PlainsongPreferences.PreviewTheme.allCases {
                var expectedContent: String?
                fixture.appState.preferences.setPreviewTheme(theme)
                let resolved = ExportHTMLTheme.resolve(theme, appearance: NSApp.effectiveAppearance)
                for mode in [EditorLayoutMode.sourceOnly, .sourcePreview, .wysiwyg] {
                    fixture.appState.setLayoutMode(mode)
                    XCTAssertEqual(fixture.appState.layoutMode, mode)
                    let destination = fixture.exportsDirectory
                        .appendingPathComponent("\(theme.rawValue)-\(mode.rawValue).html")
                    let recorder = fixture.record(returning: [destination])
                    try await XCTUnwrap(fixture.appState.exportCurrentDocumentAsHTML()).value
                    guard case let .exported(_, omissions) = recorder.results.first?.result else {
                        return XCTFail("Expected matrix export: \(recorder.results)")
                    }
                    XCTAssertEqual(recorder.requests.first?.defaultFileName, "Export F Matrix.html")
                    XCTAssertEqual(omissions, 2)
                    XCTAssertEqual(fixture.appState.exportHTMLNotice?.group, .exportedWithPlaceholders)
                    let html = try String(contentsOf: destination, encoding: .utf8)
                    XCTAssertTrue(html.contains("<html data-theme=\"\(resolved.rawValue)\">"))
                    for marker in ["<table", "katex", "hljs", "mermaid-rendered", "<input", "data:image/png;base64,"] {
                        XCTAssertTrue(html.contains(marker), "Missing \(marker) from \(name)")
                    }
                    if ext == "mdx" { XCTAssertTrue(html.contains("MDX placeholder body")) }
                    assertStandalone(html, fixture: fixture)
                    // Mermaid emits generated SVG IDs; compare semantic structure after removing
                    // only those incidental IDs, not content, theme, styles, or resources.
                    let comparable = html.replacingOccurrences(
                        of: #"mermaid-[0-9]+"#, with: "mermaid-ID", options: .regularExpression
                    )
                    if let expectedContent { XCTAssertEqual(comparable, expectedContent) }
                    else { expectedContent = comparable }
                }
            }
        }
    }

    func testMathFixtureExportsThroughTheProductCommand() async throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "math", withExtension: "md"))
        let fixture = try makeFixture(text: String(contentsOf: url, encoding: .utf8))
        let destination = fixture.exportsDirectory.appendingPathComponent("math.html")
        let recorder = fixture.record(returning: [destination])
        try await XCTUnwrap(fixture.appState.exportCurrentDocumentAsHTML()).value
        guard case .exported = recorder.results.first?.result else { return XCTFail("Expected math export") }
        let html = try String(contentsOf: destination, encoding: .utf8)
        XCTAssertTrue(html.contains("katex"))
        XCTAssertTrue(html.contains("data:font/"))
        assertStandalone(html, fixture: fixture)
    }

    func testPanelDefaultsSanitizeTitlesAndFallBackForInvalidOrEmptyFrontmatter() {
        let document = URL(fileURLWithPath: "/Workspace/my post.mdx")
        let cases = [
            ("---\ntitle: 'Title/A: B'\n---\n", "Title-A- B.html"),
            ("---\ntitle: ''\n---\n", "my post.html"),
            ("---\ntitle: [a, b]\n---\n", "my post.html"),
            ("---\ntitle: [unclosed\n---\n", "my post.html"),
            ("# Heading does not override filename", "my post.html"),
        ]
        for (source, expected) in cases {
            XCTAssertEqual(ExportHTMLOperationSnapshot.defaultFileName(for: document, source: source), expected)
        }
        let request = ExportHTMLDestinationRequest(
            defaultFileName: "Title.html",
            directoryURL: document.deletingLastPathComponent()
        )
        XCTAssertEqual(request.allowedExtension, "html")
        XCTAssertTrue(request.accessibilityLabel.contains("Title.html"))
        XCTAssertEqual(ExportHTMLOperationSnapshot.defaultFileName(for: nil), "Untitled.html")
    }

    func testThemeChangesWhilePanelIsOpenDoNotChangeTheInvocationTheme() async throws {
        let fixture = try makeFixture()
        fixture.appState.preferences.setPreviewTheme(.dark)
        let destination = fixture.exportsDirectory.appendingPathComponent("dark.html")
        _ = fixture.record(returning: [destination]) { fixture.appState.preferences.setPreviewTheme(.light) }
        try await XCTUnwrap(fixture.appState.exportCurrentDocumentAsHTML()).value
        XCTAssertTrue(try String(contentsOf: destination, encoding: .utf8).contains("<html data-theme=\"dark\">"))
    }

    func testSwitchAwayAndBackStillFencesTheExport() async throws {
        for workspace in [false, true] {
            let fixture = try makeFixture()
            let destination = fixture.exportsDirectory.appendingPathComponent("aba.html")
            let recorder = fixture.record(returning: [destination]) {
                if workspace {
                    fixture.appState.workspaceRootURL = nil
                    fixture.appState.workspaceRootURL = fixture.root
                } else {
                    fixture.appState.currentDocument = DocumentSession()
                    fixture.appState.currentDocument = fixture.session
                }
            }
            try await XCTUnwrap(fixture.appState.exportCurrentDocumentAsHTML()).value
            XCTAssertEqual(recorder.results.map(\.result), [.stopped(workspace ? .workspaceChanged : .documentChanged)])
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        }
    }

    func testInjectedWriterOutcomesTravelThroughTheCommandWithoutPublishing() async throws {
        for (failure, group) in ExportHTMLFeedbackAppTests.failures {
            let fixture = try makeFixture()
            let destination = fixture.exportsDirectory.appendingPathComponent("injected.html")
            let recorder = fixture.record(returning: [destination])
            fixture.appState.exportHTMLOperations.injectedWriteOutcome = .notCommitted(failure)
            try await XCTUnwrap(fixture.appState.exportCurrentDocumentAsHTML()).value
            XCTAssertEqual(recorder.results.map(\.result), [.written(.notCommitted(failure))])
            XCTAssertEqual(fixture.appState.exportHTMLNotice?.group, group)
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
            XCTAssertTrue(recorder.controllers.allSatisfy(\.isInvalidated))
        }
    }
}
