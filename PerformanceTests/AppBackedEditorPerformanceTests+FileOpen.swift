import AppKit
import Combine
@testable import EditorKit
import MarkdownCore
@testable import Plainsong
import SwiftUI
import WorkspaceKit
import XCTest

@MainActor
extension AppBackedEditorPerformanceTests {
    func testLargeFileOpenToHostedDisplayAndFirstEdit() async throws {
        let english = try Self.fixtureText("Fixtures/large-1mb.md")
        let paragraph = "## 草稿\n\n我們在寫一份繁體中文的技術文件，內容包含 Unicode、標點與數字 123。\n\n"
        let chinese = String(repeating: paragraph, count: english.utf8.count / paragraph.utf8.count)
        for sidebar in [false, true] {
            for (label, source) in [("english", english), ("chinese", chinese)] {
                try await measureFileOpen(source: source, label: label, sidebar: sidebar)
            }
        }
    }

    func testTenMiBFileOpenToHostedDisplayAndFirstEdit() async throws {
        let source = try Self.fixtureText("Fixtures/large-1mb.md")
        try await measureFileOpen(source: String(repeating: source, count: 10), label: "english-10MiB", sidebar: false)
    }

    private func measureFileOpen(source: String, label: String, sidebar: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try "small".write(to: directory.appendingPathComponent("0-start.md"), atomically: true, encoding: .utf8)
        let file = directory.appendingPathComponent("1-\(label).md")
        try source.write(to: file, atomically: true, encoding: .utf8)
        let app = try EditorFindPerformanceSupport.makeAppHarness(fixtureText: "", opensFind: false)
        defer { app.cleanUp() }
        let root = WorkspaceWindow(inspectorIntentOverride: .constant(false)).environmentObject(app.appState)
        let host = NSHostingController(rootView: root)
        let window = NSWindow(contentViewController: host)
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 1100, height: 720))
        window.makeKeyAndOrderFront(nil)
        defer {
            window.contentViewController = nil
            window.close()
            app.appState.closeWorkspace()
        }
        _ = try await waitForTextView(in: host.view)
        if sidebar {
            try app.appState.openWorkspace(url: directory, rememberAsLastOpened: false)
            try await waitForOpenCondition { app.appState.shownSession.fileURL?.lastPathComponent == "0-start.md" }
        }
        try await timeOpenAndEdit(file: file, source: source, sidebar: sidebar,
                                  appState: app.appState, window: window)
    }

    private func timeOpenAndEdit(
        file: URL, source: String, sidebar: Bool, appState: AppState, window: NSWindow
    ) async throws {
        let hostingView = try XCTUnwrap(window.contentViewController?.view)
        let length = source.utf16.count
        var installedWithPendingCounts = false
        let installation = appState.windowState.$currentDocument.sink { session in
            if session.fileURL?.lastPathComponent == file.lastPathComponent {
                installedWithPendingCounts = session.availableStatistics == nil
            }
        }
        defer { installation.cancel() }
        let pick = FilesSelectionDeferral()
        let start = DispatchTime.now().uptimeNanoseconds
        if sidebar {
            let node = try XCTUnwrap(appState.workspaceTree?.root.children
                .first { $0.name == file.lastPathComponent })
            pick.open(id: node.id, requestingEditorFocus: true, pickWindow: window, appState: appState) {
                XCTFail("Sidebar selection dropped")
            }
        } else {
            try appState.open(url: file, rememberAsLastOpened: false, preserveWorkspace: false)
        }
        try await waitForOpenCondition {
            hostingView.layoutSubtreeIfNeeded()
            guard let editor = self.findTextView(in: hostingView) else { return false }
            return MarkdownTextView.textStorage(of: editor)?.length == length && editor.isEditable
        }
        window.displayIfNeeded()
        let display = DispatchTime.now().uptimeNanoseconds
        let editor = try XCTUnwrap(findTextView(in: hostingView))
        XCTAssertTrue(window.makeFirstResponder(editor))
        editor.insertText("Z", replacementRange: NSRange(location: 0, length: 0))
        hostingView.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        let edit = DispatchTime.now().uptimeNanoseconds
        XCTAssertTrue(installedWithPendingCounts, "A large file must reach the window before counting completes")
        XCTAssertEqual(appState.shownSession.fileURL?.lastPathComponent, file.lastPathComponent)
        XCTAssertEqual(MarkdownTextView.textStorage(of: editor)?.length, length + 1)
        let expected = "Z" + source
        XCTAssertEqual(appState.shownSession.text, expected)
        // SwiftUI can release the editor after the temporary directory is removed.
        // Persist the native edit while the file still exists, outside the timed interval.
        try appState.saveCurrentDocument()
        XCTAssertEqual(try Data(contentsOf: file), Data(expected.utf8))
        print(String(format: "OPEN PERF %@ %@ display %.2f ms first edit %.2f ms", file.lastPathComponent,
                     sidebar ? "sidebar" : "open", Double(display - start) / 1e6, Double(edit - start) / 1e6))
    }

    func testSwitchAfterFirstEditPublishesCountsOnlyToTheirOwningDocument() async throws {
        let app = try EditorFindPerformanceSupport.makeAppHarness(fixtureText: "", opensFind: false)
        defer { app.cleanUp() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let large = directory.appendingPathComponent("large.md")
        let small = directory.appendingPathComponent("small.md")
        let source = try Self.fixtureText("Fixtures/large-1mb.md")
        try source.write(to: large, atomically: true, encoding: .utf8)
        try "small".write(to: small, atomically: true, encoding: .utf8)

        try app.appState.activateFileSession(url: large)
        let first = app.appState.shownSession
        XCTAssertNil(first.availableStatistics)
        let edited = source + "\nnew words"
        app.appState.applyAuthorizedEditorText(edited, to: first)
        try app.appState.activateFileSession(url: small)
        let second = app.appState.shownSession
        let expected = TextStatistics(text: edited)
        try await waitForOpenCondition { first.availableStatistics == expected }
        XCTAssertTrue(app.appState.shownSession === second)
        XCTAssertEqual(second.availableStatistics, TextStatistics(text: "small"))
        XCTAssertEqual(first.text, edited)
    }

    func testEditedLargeFileFinishesCountingAfterAnchoredCacheHit() async throws {
        try await withOpenFiles { app, small, large, source in
            let cached = try WorkspaceFileSystemLocation(fileURL: small)
            let active = try WorkspaceFileSystemLocation(fileURL: large)
            try app.activateAnchoredFileSession(at: cached)
            let other = app.shownSession
            try app.activateAnchoredFileSession(at: active)
            let edited = app.shownSession
            XCTAssertNil(edited.availableStatistics)
            app.applyAuthorizedEditorText(source + "a", to: edited)
            try app.activateAnchoredFileSession(at: cached)
            XCTAssertTrue(app.shownSession === other)
            try app.activateAnchoredFileSession(at: active)
            XCTAssertTrue(app.shownSession === edited)
            let expected = TextStatistics(text: source + "a")
            try await self.waitForOpenCondition { edited.availableStatistics == expected }
        }
    }

    func testEditsInTwoWindowsFinishCountingTheirOwnSources() async throws {
        try await withOpenFiles { app, small, large, source in
            let sibling = app.makeSiblingFacade(admitsFileOperations: true)
            try sibling.activateFileSession(url: small)
            try app.activateFileSession(url: large)
            let edited = app.shownSession
            XCTAssertNil(edited.availableStatistics)
            app.applyAuthorizedEditorText(source + "a", to: edited)
            sibling.applyAuthorizedEditorText("another document", to: sibling.shownSession)
            let expected = TextStatistics(text: source + "a")
            let other = TextStatistics(text: "another document")
            try await self.waitForOpenCondition {
                edited.availableStatistics == expected && sibling.shownSession.availableStatistics == other
            }
        }
    }

    func testSaveAsKeepsCountingTheEditedSource() async throws {
        try await withOpenFiles { app, _, large, source in
            try app.activateFileSession(url: large)
            let edited = app.shownSession
            XCTAssertNil(edited.availableStatistics)
            let text = source + "new word"
            app.applyAuthorizedEditorText(text, to: edited)
            let copy = large.deletingLastPathComponent().appendingPathComponent("copy.mdx")
            try app.saveCurrentDocumentAs(to: copy)
            XCTAssertTrue(app.shownSession === edited)
            XCTAssertEqual(try String(contentsOf: copy, encoding: .utf8), text)
            XCTAssertEqual(try String(contentsOf: large, encoding: .utf8), source)
            let expected = TextStatistics(text: text)
            try await self.waitForOpenCondition { edited.availableStatistics == expected }
        }
    }

    private func withOpenFiles(_ run: (AppState, URL, URL, String) async throws -> Void) async throws {
        let app = try EditorFindPerformanceSupport.makeAppHarness(fixtureText: "", opensFind: false)
        defer { app.cleanUp() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let small = directory.appendingPathComponent("small.md")
        let large = directory.appendingPathComponent("large.md")
        let source = String(repeating: "一份繁體中文文件\n", count: 4000)
        try "small".write(to: small, atomically: true, encoding: .utf8)
        try source.write(to: large, atomically: true, encoding: .utf8)
        try await run(app.appState, small, large, source)
    }

    private func waitForOpenCondition(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !condition() {
            guard ContinuousClock.now < deadline else { throw FileOpenMeasurementError.timedOut }
            try await Task.sleep(for: .milliseconds(1))
        }
    }
}

private enum FileOpenMeasurementError: Error {
    case timedOut
}
