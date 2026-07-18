@testable import WorkspaceKit
import XCTest

final class WorkspaceFileOperationsPathValidationTests: XCTestCase {
    func testCreateRejectsNamesThatAreNotSingleFilenameComponents() throws {
        let operations = WorkspaceFileOperations()

        for name in invalidNames {
            let fileRoot = try makeTemporaryDirectory()
            let fileAuthority = try WorkspaceFileSystemRootAuthority(rootURL: fileRoot)
            XCTAssertEqual(
                operations.createFile(
                    named: name,
                    inDirectoryRelativePath: "",
                    rootAuthority: fileAuthority,
                    expectingDirectory: fileAuthority.directoryMutationExpectation
                ),
                .notCreated(.invalidName)
            )
            assertTraversalDestinationsDoNotExist(relativeTo: fileRoot)

            let folderRoot = try makeTemporaryDirectory()
            let folderAuthority = try WorkspaceFileSystemRootAuthority(rootURL: folderRoot)
            XCTAssertEqual(
                operations.createFolder(
                    named: name,
                    inDirectoryRelativePath: "",
                    rootAuthority: folderAuthority,
                    expectingDirectory: folderAuthority.directoryMutationExpectation
                ),
                .notCreated(.invalidName)
            )
            assertTraversalDestinationsDoNotExist(relativeTo: folderRoot)
        }
    }

    func testRenameRejectsNamesThatAreNotSingleFilenameComponentsWithoutMovingSource() throws {
        let operations = WorkspaceFileOperations()

        for name in invalidNames {
            let root = try makeTemporaryDirectory()
            let source = root.appendingPathComponent("post.md")
            try "draft".write(to: source, atomically: true, encoding: .utf8)
            let authority = try WorkspaceFileSystemRootAuthority(rootURL: root)
            let sourceLocation = try authority.location(relativePath: "post.md")
            let sourceExpectation = try WorkspaceNoFollowItemInspector.inspect(
                at: sourceLocation
            )

            let outcome = operations.rename(
                sourceLocation,
                to: name,
                expecting: sourceExpectation,
                sourceParentExpectation: authority.directoryMutationExpectation
            )
            guard case .notMoved(.invalidName) = outcome else {
                return XCTFail("Expected invalidName for \(name), got \(outcome)")
            }
            XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
            XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), "draft")
            assertTraversalDestinationsDoNotExist(relativeTo: root)
        }
    }

    func testCreateRejectsWhitespaceOnlyNames() throws {
        let operations = WorkspaceFileOperations()

        for name in ["   ", "\t\n"] {
            let fileRoot = try makeTemporaryDirectory()
            let fileAuthority = try WorkspaceFileSystemRootAuthority(rootURL: fileRoot)
            XCTAssertEqual(
                operations.createFile(
                    named: name,
                    inDirectoryRelativePath: "",
                    rootAuthority: fileAuthority,
                    expectingDirectory: fileAuthority.directoryMutationExpectation
                ),
                .notCreated(.invalidName)
            )

            let folderRoot = try makeTemporaryDirectory()
            let folderAuthority = try WorkspaceFileSystemRootAuthority(rootURL: folderRoot)
            XCTAssertEqual(
                operations.createFolder(
                    named: name,
                    inDirectoryRelativePath: "",
                    rootAuthority: folderAuthority,
                    expectingDirectory: folderAuthority.directoryMutationExpectation
                ),
                .notCreated(.invalidName)
            )
        }
    }

    func testRenameRejectsWhitespaceOnlyNamesWithoutMovingSource() throws {
        let operations = WorkspaceFileOperations()

        for name in ["   ", "\t\n"] {
            let root = try makeTemporaryDirectory()
            let authority = try WorkspaceFileSystemRootAuthority(rootURL: root)
            let source = try authority.location(relativePath: "post.md")
            try "draft".write(to: source.fileURL, atomically: false, encoding: .utf8)
            let expectation = try WorkspaceNoFollowItemInspector.inspect(at: source)

            let outcome = operations.rename(
                source,
                to: name,
                expecting: expectation,
                sourceParentExpectation: authority.directoryMutationExpectation
            )

            guard case .notMoved(.invalidName) = outcome else {
                return XCTFail("Expected invalidName for \(name.debugDescription), got \(outcome)")
            }
            XCTAssertTrue(FileManager.default.fileExists(atPath: source.fileURL.path))
            XCTAssertEqual(
                try String(contentsOf: source.fileURL, encoding: .utf8),
                "draft"
            )
        }
    }

    func testCreatePreservesLiteralLeadingAndTrailingWhitespace() throws {
        for literalName in ["  post.md  ", "\tpost.md\n"] {
            let root = try makeTemporaryDirectory()
            let authority = try WorkspaceFileSystemRootAuthority(rootURL: root)

            let outcome = WorkspaceFileOperations().createFile(
                named: literalName,
                inDirectoryRelativePath: "",
                rootAuthority: authority,
                expectingDirectory: authority.directoryMutationExpectation
            )

            guard case .createdAndDurable = outcome else {
                return XCTFail("Expected literal whitespace name to be created, got \(outcome)")
            }
            let entryNameBytes = try FileManager.default.contentsOfDirectory(atPath: root.path)
                .map { Array($0.utf8) }
            XCTAssertTrue(entryNameBytes.contains(Array(literalName.utf8)))
            XCTAssertFalse(entryNameBytes.contains(Array("post.md".utf8)))
        }
    }

    func testRenamePreservesLiteralLeadingAndTrailingWhitespace() throws {
        let root = try makeTemporaryDirectory()
        let authority = try WorkspaceFileSystemRootAuthority(rootURL: root)
        let source = try authority.location(relativePath: "post.md")
        try "draft".write(to: source.fileURL, atomically: false, encoding: .utf8)
        let expectation = try WorkspaceNoFollowItemInspector.inspect(at: source)
        let literalName = "  renamed.md  "

        let outcome = WorkspaceFileOperations().rename(
            source,
            to: literalName,
            expecting: expectation,
            sourceParentExpectation: authority.directoryMutationExpectation
        )

        guard case .movedAndDurable = outcome else {
            return XCTFail("Expected literal whitespace rename to succeed, got \(outcome)")
        }
        let entryNameBytes = try FileManager.default.contentsOfDirectory(atPath: root.path)
            .map { Array($0.utf8) }
        XCTAssertTrue(entryNameBytes.contains(Array(literalName.utf8)))
        XCTAssertFalse(entryNameBytes.contains(Array("renamed.md".utf8)))
    }

    private var invalidNames: [String] {
        ["", "../outside.md", "child/post.md", ".", "..", "bad\0name.md"]
    }

    private func assertTraversalDestinationsDoNotExist(
        relativeTo root: URL,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: root.deletingLastPathComponent().appendingPathComponent("outside.md").path
            ),
            file: file,
            line: line
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: root.appendingPathComponent("child").path),
            file: file,
            line: line
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkspaceFileOperationsPathValidationTests")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let root = container.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: container)
        }
        return root
    }
}
