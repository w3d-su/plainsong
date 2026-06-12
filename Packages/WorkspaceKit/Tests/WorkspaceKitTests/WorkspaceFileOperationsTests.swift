@testable import WorkspaceKit
import XCTest

final class WorkspaceFileOperationsTests: XCTestCase {
    func testCreateRenameAndMoveItems() throws {
        let root = try makeTemporaryDirectory()
        let operations = WorkspaceFileOperations()

        let folder = try operations.createFolder(named: "drafts", in: root)
        let file = try operations.createFile(named: "post.md", in: root)
        let renamed = try operations.rename(file, to: "renamed.md")
        let moved = try operations.move(renamed, toDirectory: folder)

        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: renamed.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: moved.path))
        XCTAssertEqual(moved, folder.appendingPathComponent("renamed.md"))
    }

    func testTrashUsesRecyclerWithoutHardDeleting() async throws {
        let root = try makeTemporaryDirectory()
        let file = root.appendingPathComponent("post.md")
        try "draft".write(to: file, atomically: true, encoding: .utf8)
        let recycler = SpyItemRecycler()
        let operations = WorkspaceFileOperations(recycler: recycler)

        try await operations.trash(file)

        XCTAssertEqual(recycler.recycledURLs, [file])
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkspaceFileOperationsTests")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private final class SpyItemRecycler: WorkspaceItemRecycling {
    private(set) var recycledURLs: [URL] = []

    func recycle(_ urls: [URL]) async throws {
        recycledURLs.append(contentsOf: urls)
    }
}
