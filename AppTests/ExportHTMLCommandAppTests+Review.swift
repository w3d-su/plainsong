import AppKit
import MarkdownCore
@testable import Plainsong
import UniformTypeIdentifiers
import XCTest

@MainActor
extension ExportHTMLCommandAppTests {
    func testAvailabilityRequiresMarkdownOrMDXAndADocumentWindow() throws {
        let fixture = try makeFixture()
        let app = fixture.appState
        for (name, expected) in [("post.md", true), ("post.mdx", true), ("post.MD", true),
                                 ("post.markdown", false), ("post.txt", false), ("post.html", false),
                                 ("post.pdf", false), ("", false)]
        {
            app.currentDocument = DocumentSession(text: "# Availability",
                                                  url: name.isEmpty ? nil : fixture.root.appendingPathComponent(name))
            XCTAssertEqual(app.canExportCurrentDocumentAsHTML, expected, name)
            XCTAssertEqual(MenuBarSnapshot(appState: app).canExportHTML, expected, name)
        }
        app.currentDocument = fixture.session
        app.exportHTMLOperations.panelWindowProvider = { nil }
        XCTAssertFalse(app.canExportCurrentDocumentAsHTML)
        XCTAssertFalse(MenuBarSnapshot(appState: app).canExportHTML)
        var calls = 0
        app.exportHTMLOperations.destinationChooser = { _ in calls += 1; return nil }
        XCTAssertNil(app.exportCurrentDocumentAsHTML())
        XCTAssertEqual(calls, 0)
        XCTAssertNil(app.exportHTMLOperations.offscreenController)
    }

    func testMenuAvailabilityRefreshesWhenDocumentWindowEligibilityChanges() async throws {
        let fixture = try makeFixture()
        let app = fixture.appState
        let window = try XCTUnwrap(app.exportHTMLDocumentWindow)
        var available = false
        app.exportHTMLOperations.panelWindowProvider = { available ? window : nil }
        let menu = MenuBarState(appState: app)
        XCTAssertFalse(menu.snapshot.canExportHTML)
        available = true
        NotificationCenter.default.post(name: AppState.exportHTMLWindowRegistered, object: window)
        for _ in 0 ..< 100 {
            if menu.snapshot.canExportHTML { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertTrue(menu.snapshot.canExportHTML)
        available = false
        NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: window)
        for _ in 0 ..< 100 {
            if !menu.snapshot.canExportHTML { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertFalse(menu.snapshot.canExportHTML)
    }

    func testSettingsAndAboutCannotBecomeExportSheetParents() throws {
        let fixture = try makeFixture()
        let workspace = try XCTUnwrap(fixture.appState.exportHTMLDocumentWindow)
        workspace.identifier = AppState.exportHTMLWorkspaceWindowIdentifier
        let otherWorkspace = NSWindow()
        otherWorkspace.identifier = AppState.exportHTMLWorkspaceWindowIdentifier
        for identifier in ["settings", "about"] {
            let auxiliary = NSWindow()
            auxiliary.identifier = NSUserInterfaceItemIdentifier(identifier)
            XCTAssertTrue(AppState.exportHTMLDocumentWindow(key: auxiliary, main: workspace) === workspace)
            XCTAssertTrue(AppState.exportHTMLDocumentWindow(key: otherWorkspace, main: workspace) === otherWorkspace)
            XCTAssertNil(AppState.exportHTMLDocumentWindow(key: auxiliary, main: auxiliary))
            XCTAssertNil(AppState.exportHTMLDocumentWindow(key: auxiliary, main: nil))
        }
        XCTAssertTrue(AppState.exportHTMLDocumentWindow(key: nil, main: workspace) === workspace)
        XCTAssertNil(AppState.exportHTMLDocumentWindow(key: nil, main: nil))
    }

    func testConfiguredFreshSavePanelsReadRequestDefaultsAndCancelWithoutRetainingDestination() async throws {
        let fixture = try makeFixture()
        let app = fixture.appState
        let window = try XCTUnwrap(app.exportHTMLDocumentWindow)
        let before = DocumentState(fixture.session)
        let recents = app.recentItemURLs
        let request = ExportHTMLDestinationRequest(defaultFileName: "Panel Title.html", directoryURL: fixture.root)
        var panels: [NSSavePanel] = []
        app.exportHTMLOperations.savePanelPresenter = { panel, parent in
            XCTAssertTrue(parent === window)
            XCTAssertTrue(app.exportHTMLOperations.presentedPanel === panel)
            XCTAssertEqual(panel.allowedContentTypes, [UTType.html])
            XCTAssertEqual(panel.nameFieldStringValue, request.defaultFileName)
            XCTAssertEqual(panel.directoryURL?.resolvingSymlinksInPath(), fixture.root)
            XCTAssertTrue(panel.canCreateDirectories)
            XCTAssertFalse(panel.isExtensionHidden)
            XCTAssertEqual(panel.accessibilityIdentifier(), ExportHTMLAccessibility.savePanel)
            XCTAssertEqual(panel.accessibilityLabel(), request.accessibilityLabel)
            panels.append(panel)
            return nil
        }
        for _ in 0 ..< 2 {
            let result = await app.presentExportHTMLSavePanel(request, window: window)
            XCTAssertNil(result)
            XCTAssertNil(app.exportHTMLOperations.presentedPanel)
        }
        XCTAssertEqual(panels.count, 2)
        XCTAssertFalse(panels[0] === panels[1])
        XCTAssertEqual(DocumentState(fixture.session), before)
        XCTAssertEqual(app.recentItemURLs, recents)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.exportsDirectory.path), [])
    }

    func testFileMenuContainsExportInTheImportExportSlotWithoutAShortcut() async throws {
        // The hosted app builds its real SwiftUI command menu on the main run loop.
        for _ in 0 ..< 100 {
            if NSApp.mainMenu?.items.first(where: { $0.title == "File" })?.submenu?
                .items.contains(where: { $0.title == "Export as HTML…" }) == true { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let menu = try XCTUnwrap(NSApp.mainMenu?.items.first(where: { $0.title == "File" })?.submenu)
        let items = menu.items
        let exportIndex = try XCTUnwrap(items.firstIndex(where: { $0.title == "Export as HTML…" }))
        let saveIndex = try XCTUnwrap(items.firstIndex(where: { $0.title == "Save" }))
        XCTAssertGreaterThan(exportIndex, saveIndex)
        if let printIndex = items.firstIndex(where: { $0.title.hasPrefix("Print") }) {
            XCTAssertLessThan(exportIndex, printIndex)
        }
        XCTAssertEqual(items.filter { $0.title == "Export as HTML…" }.count, 1)
        XCTAssertEqual(items[exportIndex].keyEquivalent, "")
        XCTAssertFalse(NSApp.mainMenu?.items.contains { $0.title == "Export" } ?? true)
    }

    func testFilenameSanitizerRemovesLeadingDotsAndBoundsUTF8WithoutSplittingCharacters() {
        let url = URL(fileURLWithPath: "/Workspace/.hidden.md")
        XCTAssertEqual(ExportHTMLOperationSnapshot.defaultFileName(for: url), "hidden.html")
        for (title, expected) in [("...private", "private"), ("..", "hidden"),
                                  (String(repeating: "a", count: 250), String(repeating: "a", count: 200)),
                                  (String(repeating: "界", count: 100), String(repeating: "界", count: 66)),
                                  (String(repeating: "é", count: 100), String(repeating: "é", count: 66)),
                                  (String(repeating: "🧪", count: 100), String(repeating: "🧪", count: 50))]
        {
            let result = ExportHTMLOperationSnapshot.defaultFileName(for: url, source: "---\ntitle: '\(title)'\n---\n")
            XCTAssertEqual(result, "\(expected).html")
            XCTAssertLessThanOrEqual(result.dropLast(5).utf8.count, 200)
            XCTAssertFalse(result.hasPrefix("."))
        }
        XCTAssertEqual(ExportHTMLOperationSnapshot.defaultFileName(
            for: URL(fileURLWithPath: "/Workspace/....md")
        ), "Untitled.html")
    }

    func testProgressResultAndErrorAreAnnouncedOnceAndCancelIsSilent() throws {
        let fixture = try makeFixture()
        let app = fixture.appState
        var messages: [String] = []
        app.exportHTMLOperations.announcementPoster = { messages.append($0) }
        app.exportHTMLStatus = .exporting(operationID: 1, fileName: "post.html")
        app.exportHTMLStatus = .exporting(operationID: 1, fileName: "Title.html")
        XCTAssertEqual(messages, [ExportHTMLAccessibility.progressLabel(fileName: "post.html")])
        app.presentExportHTMLResult(.written(.notCommitted(.ownedDestination)), operationID: 1)
        XCTAssertEqual(messages.last, app.exportHTMLNotice?.accessibilityLabel)
        XCTAssertEqual(messages.count, 2)
        let error = app.exportHTMLStatus
        app.exportHTMLStatus = error
        app.cancelExportHTML()
        XCTAssertEqual(messages.count, 2)
        app.exportHTMLStatus = .exporting(operationID: 2, fileName: "next.html")
        let notice = ExportHTMLNotice(operationID: 2, group: .exported, severity: .success,
                                      title: "Exported as HTML", message: "Export complete", revealURL: nil)
        app.exportHTMLStatus = .notice(notice)
        XCTAssertEqual(messages.count, 4)
        XCTAssertEqual(messages.last, notice.accessibilityLabel)
    }
}
