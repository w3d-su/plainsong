@testable import WorkspaceKit
import XCTest

final class WorkspaceKitTests: XCTestCase {
    func testModuleLoads() {
        XCTAssertFalse(WorkspaceKitInfo.version.isEmpty)
    }

    func testLoadReadsUTF8MarkdownFile() throws {
        let directory = try makeTemporaryDirectory()
        let url = directory.appendingPathComponent("post.md")
        try "Hello **M1**\n".write(to: url, atomically: true, encoding: .utf8)

        let file = try MarkdownFileStore().load(url: url)

        XCTAssertEqual(file.url, url)
        XCTAssertEqual(file.text, "Hello **M1**\n")
        XCTAssertEqual(file.fileKind.rawValue, "markdown")
    }

    func testSaveWritesUTF8MDXFile() throws {
        let directory = try makeTemporaryDirectory()
        let url = directory.appendingPathComponent("component.mdx")

        try MarkdownFileStore().save(text: "# Title\n\n<Component />\n", to: url)

        let savedText = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(savedText, "# Title\n\n<Component />\n")
    }

    func testRejectsUnsupportedExtensions() throws {
        let directory = try makeTemporaryDirectory()
        let url = directory.appendingPathComponent("notes.txt")

        XCTAssertThrowsError(try MarkdownFileStore().load(url: url)) { error in
            XCTAssertEqual(error as? MarkdownFileStoreError, .unsupportedExtension(url))
        }

        XCTAssertThrowsError(try MarkdownFileStore().save(text: "Nope", to: url)) { error in
            XCTAssertEqual(error as? MarkdownFileStoreError, .unsupportedExtension(url))
        }
    }

    func testLoadRejectsInvalidUTF8() throws {
        let directory = try makeTemporaryDirectory()
        let url = directory.appendingPathComponent("binary.md")
        try Data([0xFF, 0xFE, 0xFD]).write(to: url)

        XCTAssertThrowsError(try MarkdownFileStore().load(url: url)) { error in
            XCTAssertEqual(error as? MarkdownFileStoreError, .unreadable(url))
        }
    }

    func testFileStoreErrorsHaveUserReadableDescriptions() {
        let unsupportedURL = URL(fileURLWithPath: "/tmp/notes.txt")
        let unreadableURL = URL(fileURLWithPath: "/tmp/binary.md")
        let unwritableURL = URL(fileURLWithPath: "/tmp/locked.mdx")

        XCTAssertEqual(
            MarkdownFileStoreError.unsupportedExtension(unsupportedURL).localizedDescription,
            "notes.txt is not a supported Markdown or MDX file."
        )
        XCTAssertEqual(
            MarkdownFileStoreError.unreadable(unreadableURL).localizedDescription,
            "Could not read binary.md as UTF-8 Markdown."
        )
        XCTAssertEqual(
            MarkdownFileStoreError.unwritable(unwritableURL).localizedDescription,
            "Could not save changes to locked.mdx."
        )
    }

    func testLastOpenedFileStorePersistsRestoresAndClearsBookmark() throws {
        let directory = try makeTemporaryDirectory()
        let url = directory.appendingPathComponent("post.markdown")
        try "Restored".write(to: url, atomically: true, encoding: .utf8)
        let suiteName = "Plainsong.WorkspaceKitTests.\(UUID().uuidString)"
        let userDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        userDefaults.removePersistentDomain(forName: suiteName)
        defer {
            userDefaults.removePersistentDomain(forName: suiteName)
        }
        let store = LastOpenedFileStore(userDefaults: userDefaults, key: "lastOpened")

        do {
            try store.save(url)
        } catch {
            throw XCTSkip("Security-scoped bookmarks are unavailable in this test environment: \(error)")
        }

        let restoredURL = try XCTUnwrap(store.restore())
        XCTAssertEqual(restoredURL.standardizedFileURL, url.standardizedFileURL)

        store.clear()
        XCTAssertNil(try store.restore())
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkspaceKitTests")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
