import AppKit
import MarkdownCore
import PDFKit
@testable import Plainsong
@testable import PreviewKit
@testable import WorkspaceKit
import XCTest

/// E8 for the two new products (`docs/export-gates.md`): export-f-markdown.md,
/// export-f-mdx.mdx, and math.md through Export as PDF… and Print… under
/// light/dark/system. PDF freezes the invocation theme into the render; Print renders
/// the same snapshot in light whatever the preference says.
@MainActor
final class ExportPDFMatrixAppTests: XCTestCase {
    private let sentinels: [String: [String]] = [
        "export-f-markdown.md": ["Export F Matrix", "checked task", "alpha", "matrixValue"],
        "export-f-mdx.mdx": ["Export F Matrix", "checked task", "MDX placeholder body"],
        "math.md": ["Math Fixture", "Chinese text works inline too"],
    ]

    func testPDFAndPrintMatrixAcrossThemesAndFixtures() async throws {
        let previousAppearance = NSApp.appearance
        defer { NSApp.appearance = previousAppearance }
        NSApp.appearance = NSAppearance(named: .darkAqua)
        let support = ExportHTMLCommandAppTests()
        for (name, ext, kind) in [
            ("export-f-markdown", "md", FileKind.markdown),
            ("export-f-mdx", "mdx", FileKind.mdx),
            ("math", "md", FileKind.markdown),
        ] {
            let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: ext))
            let source = try String(contentsOf: url, encoding: .utf8)
            for theme in PlainsongPreferences.PreviewTheme.allCases {
                let resolved = ExportHTMLTheme.resolve(theme, appearance: NSApp.effectiveAppearance)
                try await runPDF(
                    support: support, name: "\(name).\(ext)", source: source,
                    fileKind: kind, theme: theme, expectedTheme: resolved.rawValue
                )
                try await runPrint(
                    support: support, name: "\(name).\(ext)", source: source,
                    fileKind: kind, theme: theme
                )
            }
        }
    }

    private func runPDF(
        support: ExportHTMLCommandAppTests,
        name: String,
        source: String,
        fileKind: FileKind,
        theme: PlainsongPreferences.PreviewTheme,
        expectedTheme: String
    ) async throws {
        let fixture = try support.makeFixture(
            name: "matrix.\(fileKind == .mdx ? "mdx" : "md")", text: source
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        fixture.appState.preferences.setPreviewTheme(theme)
        let destination = fixture.exportsDirectory
            .appendingPathComponent("\(name)-\(theme.rawValue).pdf")
        var results: [ExportHTMLOperationResult] = []
        var renderedTheme = ""
        fixture.appState.exportHTMLOperations.didFinishOperation = { _, result in
            results.append(result)
        }
        fixture.appState.exportHTMLOperations.didPrepareArtifact = {
            let value = try? await fixture.appState.exportHTMLOperations.offscreenController?
                .webView.evaluateJavaScript("document.documentElement.dataset.theme")
            renderedTheme = value as? String ?? ""
        }
        fixture.appState.exportHTMLOperations.destinationChooser = { _ in destination }
        try await XCTUnwrap(fixture.appState.exportCurrentDocumentAsPDF(), "PDF \(name) \(theme)").value
        guard case .exported = results.first else {
            return XCTFail("PDF export of \(name) under \(theme) failed: \(results)")
        }
        XCTAssertEqual(renderedTheme, expectedTheme, "PDF \(name) \(theme)")
        let data = try Data(contentsOf: destination)
        XCTAssertTrue(data.starts(with: Data("%PDF".utf8)), name)
        let text = Self.text(of: data)
        for marker in sentinels[name] ?? [] {
            XCTAssertTrue(text.contains(marker), "\(name) \(theme): missing \(marker)")
        }
    }

    private func runPrint(
        support: ExportHTMLCommandAppTests,
        name: String,
        source: String,
        fileKind: FileKind,
        theme: PlainsongPreferences.PreviewTheme
    ) async throws {
        let fixture = try support.makeFixture(
            name: "print-matrix.\(fileKind == .mdx ? "mdx" : "md")", text: source
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        fixture.appState.preferences.setPreviewTheme(theme)
        var results: [ExportHTMLOperationResult] = []
        var renderedTheme = ""
        var printed = false
        fixture.appState.exportHTMLOperations.didFinishOperation = { _, result in
            results.append(result)
        }
        fixture.appState.exportHTMLOperations.didPrepareArtifact = {
            let value = try? await fixture.appState.exportHTMLOperations.offscreenController?
                .webView.evaluateJavaScript("document.documentElement.dataset.theme")
            renderedTheme = value as? String ?? ""
        }
        fixture.appState.exportHTMLOperations.destinationChooser = { _ in
            XCTFail("Print must not open a save panel")
            return nil
        }
        fixture.appState.exportHTMLOperations.printOperationRunner = { _, _ in
            printed = true
            return true
        }
        try await XCTUnwrap(fixture.appState.printCurrentDocument(), "Print \(name) \(theme)").value
        XCTAssertEqual(results, [.printed], "Print \(name) \(theme)")
        XCTAssertTrue(printed)
        // B1: paper is white — the print render is light under every preference.
        XCTAssertEqual(renderedTheme, "light", "Print \(name) \(theme)")
        XCTAssertNil(fixture.appState.exportHTMLNotice)
    }

    private static func text(of data: Data) -> String {
        guard let document = PDFDocument(data: data) else { return "" }
        return (0 ..< document.pageCount).compactMap { document.page(at: $0)?.string }.joined(separator: "\n")
    }
}
