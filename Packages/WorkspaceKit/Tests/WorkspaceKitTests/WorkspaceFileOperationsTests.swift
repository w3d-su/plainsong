@testable import WorkspaceKit
import XCTest

final class WorkspaceFileOperationsTests: XCTestCase {
    func testCreateRenameAndMoveItems() throws {
        let root = try makeTemporaryDirectory()
        let authority = try WorkspaceFileSystemRootAuthority(rootURL: root)
        let operations = WorkspaceFileOperations()

        let folder = try requireCreated(operations.createFolder(
            named: "drafts",
            inDirectoryRelativePath: "",
            rootAuthority: authority,
            expectingDirectory: authority.directoryMutationExpectation
        ))
        let file = try requireCreated(operations.createFile(
            named: "post.md",
            inDirectoryRelativePath: "",
            rootAuthority: authority,
            expectingDirectory: authority.directoryMutationExpectation
        ))
        let renamedLocation = try authority.location(relativePath: "renamed.md")
        let renamed = operations.rename(
            file.location,
            to: "renamed.md",
            expecting: file.expectation,
            sourceParentExpectation: authority.directoryMutationExpectation
        )
        guard case .movedAndDurable = renamed else {
            return XCTFail("Expected durable rename, got \(renamed)")
        }
        let movedLocation = try authority.location(relativePath: "drafts/renamed.md")
        let moved = operations.move(
            renamedLocation,
            to: movedLocation,
            expecting: file.expectation,
            sourceParentExpectation: authority.directoryMutationExpectation,
            destinationParentExpectation: folder.expectation
        )
        guard case .movedAndDurable = moved else {
            return XCTFail("Expected durable move, got \(moved)")
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.location.fileURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.location.fileURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: renamedLocation.fileURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: movedLocation.fileURL.path))
    }

    private func requireCreated(
        _ outcome: WorkspaceItemCreationOutcome,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> WorkspaceCreatedItem {
        guard case let .createdAndDurable(created) = outcome else {
            XCTFail("Expected createdAndDurable, got \(outcome)", file: file, line: line)
            throw TestFailure.unexpectedCreationOutcome
        }
        return created
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkspaceFileOperationsTests")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private enum TestFailure: Error {
        case unexpectedCreationOutcome
    }
}
