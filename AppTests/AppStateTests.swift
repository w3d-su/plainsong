@testable import BlogEditor
import MarkdownCore
import XCTest

@MainActor
final class AppStateTests: XCTestCase {
    func testEmptyStateCannotSaveAndUsesDefaultTitle() {
        let appState = AppState()

        XCTAssertFalse(appState.hasOpenDocument)
        XCTAssertFalse(appState.canSave)
        XCTAssertEqual(appState.windowTitle, "BlogEditor")
    }

    func testReplaceDocumentTextDoesNotRegisterAppLevelTypingUndo() {
        let appState = AppState()

        appState.replaceDocumentText("Typed text")

        XCTAssertEqual(appState.currentDocument.text, "Typed text")
    }

    func testSavingOpenDocumentDoesNotRewriteLastOpenedBookmark() throws {
        let directory = try makeTemporaryDirectory()
        let url = directory.appendingPathComponent("post.md")
        try "Original".write(to: url, atomically: true, encoding: .utf8)
        let lastOpenedFileStore = SpyLastOpenedFileStore()
        let appState = AppState(lastOpenedFileStore: lastOpenedFileStore)

        appState.openExternalFile(url)
        appState.replaceDocumentText("Changed")
        appState.save()

        XCTAssertEqual(lastOpenedFileStore.savedURLs, [url])
    }

    func testPreviewCheckboxWritebackUpdatesOnlyRequestedTaskLine() {
        let appState = AppState(
            currentDocument: DocumentSession(
                text: """
                - [ ] first
                plain text
                - [x] third
                """,
                fileKind: .markdown
            )
        )

        appState.setTaskCheckbox(line: 3, checked: false)

        XCTAssertEqual(
            appState.currentDocument.text,
            """
            - [ ] first
            plain text
            - [ ] third
            """
        )
    }

    func testPreviewVisibilityPersistsThroughUserDefaults() throws {
        let suiteName = "BlogEditorTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)

        let first = AppState(userDefaults: defaults)
        XCTAssertFalse(first.isPreviewVisible)

        first.togglePreview()

        let second = AppState(userDefaults: defaults)
        XCTAssertTrue(second.isPreviewVisible)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("BlogEditorAppStateTests")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private final class SpyLastOpenedFileStore: LastOpenedFilePersisting {
    private(set) var savedURLs: [URL] = []
    var restoredURL: URL?

    func save(_ url: URL) throws {
        savedURLs.append(url)
    }

    func restore() throws -> URL? {
        restoredURL
    }
}
