import AppKit
import MarkdownCore
import PDFKit
@testable import Plainsong
@testable import PreviewKit
import UniformTypeIdentifiers
@testable import WorkspaceKit
import XCTest

/// File › Export as PDF… and Print… through the production snapshot, panel, and writer seams.
@MainActor
final class ExportPDFCommandAppTests: XCTestCase {
    func testExportPDFWritesAValidFileAndPrintWritesNothing() async throws {
        let support = ExportHTMLCommandAppTests()
        let fixture = try support.makeFixture(text: "# PDF command heading\n\nA paragraph.\n")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let destination = fixture.exportsDirectory.appendingPathComponent("post.pdf")
        let recorder = fixture.record(returning: [destination])
        let before = ExportHTMLCommandAppTests.DocumentState(fixture.session)
        try await XCTUnwrap(fixture.appState.exportCurrentDocumentAsPDF()).value
        guard case let .exported(commit, _) = try XCTUnwrap(recorder.results.first?.result) else {
            return XCTFail("Expected a committed PDF, got \(recorder.results)")
        }
        XCTAssertEqual(commit.selectedURL, destination)
        XCTAssertEqual(recorder.requests.first?.allowedExtension, "pdf")
        let data = try Data(contentsOf: destination)
        XCTAssertTrue(data.starts(with: Data("%PDF".utf8)))
        XCTAssertTrue(Self.text(of: data).contains("PDF command heading"))
        XCTAssertEqual(fixture.appState.exportHTMLNotice?.title, "Exported as PDF")
        XCTAssertEqual(ExportHTMLCommandAppTests.DocumentState(fixture.session), before)
        XCTAssertTrue(try XCTUnwrap(recorder.controllers.first).isInvalidated)

        var savePanelCalls = 0
        var printed = false
        fixture.appState.exportHTMLOperations.destinationChooser = { _ in
            savePanelCalls += 1
            return nil
        }
        fixture.appState.exportHTMLOperations.printOperationRunner = { operation, _ in
            printed = true
            XCTAssertTrue(operation.showsPrintPanel)
            XCTAssertEqual(operation.printInfo.horizontalPagination, .fit)
            XCTAssertTrue(operation.printPanel.options.contains(.showsScaling))
            XCTAssertNil(fixture.appState.exportHTMLOperations.offscreenController?.webView.window)
            return true
        }
        try await XCTUnwrap(fixture.appState.printCurrentDocument()).value
        XCTAssertEqual(savePanelCalls, 0)
        XCTAssertTrue(printed)
        XCTAssertEqual(fixture.appState.exportHTMLNotice?.title, "Sent to Print")
        XCTAssertEqual(ExportHTMLCommandAppTests.DocumentState(fixture.session), before)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(
            at: fixture.exportsDirectory, includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "pdf" }.count, 1)
    }

    func testPDFCancelAndPrintCancelWriteNothing() async throws {
        let support = ExportHTMLCommandAppTests()
        let fixture = try support.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let destination = fixture.exportsDirectory.appendingPathComponent("cancelled.pdf")
        _ = fixture.record(returning: [nil])
        try await XCTUnwrap(fixture.appState.exportCurrentDocumentAsPDF()).value
        XCTAssertNil(fixture.appState.exportHTMLNotice)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        fixture.appState.exportHTMLOperations.printOperationRunner = { _, _ in false }
        fixture.appState.exportHTMLOperations.destinationChooser = { _ in
            XCTFail("A cancelled print must not open a save panel")
            return destination
        }
        try await XCTUnwrap(fixture.appState.printCurrentDocument()).value
        XCTAssertNil(fixture.appState.exportHTMLNotice)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testPDFPanelDefaultsUseTheSanitizedTitleAndAFreshPanel() async throws {
        let support = ExportHTMLCommandAppTests()
        let fixture = try support.makeFixture(text: "---\ntitle: 'PDF Title'\n---\n# Body\n")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var panels: [NSSavePanel] = []
        fixture.appState.exportHTMLOperations.savePanelPresenter = { panel, _ in
            panels.append(panel)
            return nil
        }
        try await XCTUnwrap(fixture.appState.exportCurrentDocumentAsPDF()).value
        try await XCTUnwrap(fixture.appState.exportCurrentDocumentAsPDF()).value
        XCTAssertEqual(panels.count, 2)
        XCTAssertFalse(panels[0] === panels[1])
        let panel = panels[0]
        XCTAssertEqual(panel.title, "Export as PDF")
        XCTAssertEqual(panel.nameFieldStringValue, "PDF Title.pdf")
        XCTAssertEqual(panel.allowedContentTypes, [UTType.pdf])
        XCTAssertTrue(panel.canCreateDirectories)
        XCTAssertEqual(panel.accessibilityLabel(), "Export as PDF. Choose a destination for PDF Title.pdf.")
        XCTAssertEqual(panels[0].directoryURL?.standardizedFileURL, fixture.root.standardizedFileURL)
    }

    func testPDFExtensionRefusalAndFreshURLWriteNothingElse() async throws {
        let support = ExportHTMLCommandAppTests()
        let fixture = try support.makeFixture(text: "# Fresh\n")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let rejected = fixture.exportsDirectory.appendingPathComponent("note.html")
        let accepted = fixture.exportsDirectory.appendingPathComponent("fresh.pdf")
        var urls: [URL?] = [rejected, nil, accepted]
        fixture.appState.exportHTMLOperations.destinationChooser = { request in
            XCTAssertEqual(request.allowedExtension, "pdf")
            return urls.isEmpty ? nil : urls.removeFirst()
        }
        try await XCTUnwrap(fixture.appState.exportCurrentDocumentAsPDF()).value
        XCTAssertEqual(fixture.appState.exportHTMLNotice?.group, .invalidName)
        XCTAssertFalse(FileManager.default.fileExists(atPath: rejected.path))
        try await XCTUnwrap(fixture.appState.exportCurrentDocumentAsPDF()).value
        XCTAssertNil(fixture.appState.exportHTMLNotice)
        try await XCTUnwrap(fixture.appState.exportCurrentDocumentAsPDF()).value
        XCTAssertTrue(FileManager.default.fileExists(atPath: accepted.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(
            at: fixture.exportsDirectory, includingPropertiesForKeys: nil
        ).map(\.lastPathComponent).sorted(), ["fresh.pdf"])
    }

    func testAvailabilityMatchesHTMLAndUntitledRefusesBeforeAPanel() {
        let appState = AppState(shouldRestoreLastOpenedFile: false)
        var calls = 0
        appState.exportHTMLOperations.destinationChooser = { _ in calls += 1; return nil }
        appState.exportHTMLOperations.printOperationRunner = { _, _ in calls += 1; return true }
        XCTAssertFalse(appState.canExportCurrentDocumentAsHTML)
        XCTAssertNil(appState.exportCurrentDocumentAsPDF())
        XCTAssertNil(appState.printCurrentDocument())
        XCTAssertEqual(calls, 0)
        XCTAssertEqual(appState.exportHTMLNotice?.group, .saveDocumentFirst)
        XCTAssertNotEqual(ExportPDFAccessibility.command, ExportHTMLAccessibility.command)
        XCTAssertNotEqual(ExportPDFAccessibility.printCommand, ExportPDFAccessibility.command)
        XCTAssertNotEqual(ExportPDFAccessibility.printCommand, ExportHTMLAccessibility.progress)
    }

    func testFileMenuContainsPDFAndPrintWithoutShortcuts() async throws {
        for _ in 0 ..< 100 {
            let file = NSApp.mainMenu?.items.first { $0.title == "File" }?.submenu
            if file?.items.contains(where: { $0.title == "Export as PDF…" }) == true {
                break
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let items = try XCTUnwrap(NSApp.mainMenu?.items.first { $0.title == "File" }?.submenu).items
        let html = try XCTUnwrap(items.firstIndex { $0.title == "Export as HTML…" })
        let pdf = try XCTUnwrap(items.firstIndex { $0.title == "Export as PDF…" })
        XCTAssertEqual(pdf, html + 1)
        XCTAssertEqual(items[pdf].keyEquivalent, "")
        XCTAssertEqual(items.filter { $0.title == "Export as PDF…" }.count, 1)
        let prints = items.filter { $0.title == "Print…" && $0.keyEquivalent.isEmpty }
        XCTAssertEqual(prints.count, 1)
        XCTAssertEqual(items.firstIndex { $0.title == "Print…" && $0.keyEquivalent.isEmpty }, pdf + 1)
    }

    func testThemesAndLayoutsProduceTheSamePDFText() async throws {
        let support = ExportHTMLCommandAppTests()
        let fixture = try support.makeFixture(text: "# Layout theme sentinel\n\nSame words.\n")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var texts: [String] = []
        for theme in [PlainsongPreferences.PreviewTheme.light, .dark, .system] {
            fixture.appState.preferences.setPreviewTheme(theme)
            for mode in [EditorLayoutMode.sourceOnly, .sourcePreview, .wysiwyg] {
                fixture.appState.setLayoutMode(mode)
                let destination = fixture.exportsDirectory
                    .appendingPathComponent("\(theme.rawValue)-\(mode.rawValue).pdf")
                var recordedTheme = ""
                fixture.appState.exportHTMLOperations.destinationChooser = { _ in destination }
                fixture.appState.exportHTMLOperations.didPrepareArtifact = {
                    let value = try? await fixture.appState.exportHTMLOperations.offscreenController?
                        .webView.evaluateJavaScript("document.documentElement.dataset.theme")
                    recordedTheme = value as? String ?? ""
                }
                try await XCTUnwrap(fixture.appState.exportCurrentDocumentAsPDF()).value
                try texts.append(Self.text(of: Data(contentsOf: destination)))
                XCTAssertTrue(recordedTheme == "light" || recordedTheme == "dark")
                if theme != .system {
                    XCTAssertEqual(recordedTheme, theme.rawValue)
                }
            }
        }
        XCTAssertEqual(Set(texts).count, 1)
        XCTAssertTrue(texts[0].contains("Layout theme sentinel"))
    }

    func testPrintFocusDoesNotFlushTheDirtyBaseline() async throws {
        let support = ExportHTMLCommandAppTests()
        let fixture = try support.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let baseline = fixture.session.text
        fixture.session.replaceText(baseline + "Unsaved addition")
        let before = ExportHTMLCommandAppTests.DocumentState(fixture.session)
        fixture.appState.exportHTMLOperations.printOperationRunner = { _, _ in
            XCTAssertNotNil(fixture.appState.exportHTMLOperations.panelOperationID)
            fixture.appState.flushAutosaveAfterWindowResignedKey()
            return false
        }
        try await XCTUnwrap(fixture.appState.printCurrentDocument()).value
        XCTAssertEqual(ExportHTMLCommandAppTests.DocumentState(fixture.session), before)
        XCTAssertEqual(try String(contentsOf: XCTUnwrap(fixture.session.fileURL), encoding: .utf8), baseline)
        XCTAssertNil(fixture.appState.exportHTMLOperations.panelOperationID)
        fixture.appState.flushAutosaveAfterWindowResignedKey()
        XCTAssertFalse(fixture.session.isDirty)
    }

    private static func text(of data: Data) -> String {
        guard let document = PDFDocument(data: data) else { return "" }
        return (0 ..< document.pageCount).compactMap { document.page(at: $0)?.string }.joined(separator: "\n")
    }
}
