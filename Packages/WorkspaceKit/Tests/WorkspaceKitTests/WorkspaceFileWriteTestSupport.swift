import Darwin
import Foundation
@testable import WorkspaceKit
import XCTest

struct WorkspaceWriteFixture: @unchecked Sendable {
    let parent: URL
    let root: URL
    let destination: URL
    let outsideFile: URL
    let location: WorkspaceFileSystemLocation
    let originalIdentity: WorkspaceFileSystemIdentity?
}

final class WorkspaceInjectedCallRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private let failures: [WorkspaceAnchoredFileSystem.InjectedCall: WorkspaceAnchoredFileSystemError]
    private var storage: [WorkspaceAnchoredFileSystem.InjectedCall] = []

    init(
        failures: [WorkspaceAnchoredFileSystem.InjectedCall: WorkspaceAnchoredFileSystemError]
    ) {
        self.failures = failures
    }

    var calls: [WorkspaceAnchoredFileSystem.InjectedCall] {
        lock.withLock { storage }
    }

    func hooks(
        eventHandler: (@Sendable (WorkspaceAnchoredFileSystem.Event) -> Void)? = nil
    ) -> WorkspaceAnchoredFileSystem.Hooks {
        WorkspaceAnchoredFileSystem.Hooks(
            eventHandler: eventHandler,
            injectedFailure: { [self] call in
                lock.withLock {
                    storage.append(call)
                    return failures[call]
                }
            }
        )
    }
}

extension WorkspaceAnchoredFileSystemTests {
    func makeWriteFixture(
        relativePath: String = "post.md",
        originalText: String? = "original"
    ) throws -> WorkspaceWriteFixture {
        let parent = try makeTemporaryDirectory()
        let root = parent.appendingPathComponent("workspace", isDirectory: true)
        let destination = root.appendingPathComponent(relativePath)
        let outsideFile = parent.appendingPathComponent("outside.md")
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if let originalText {
            try originalText.write(to: destination, atomically: true, encoding: .utf8)
        }
        try "outside sentinel".write(to: outsideFile, atomically: true, encoding: .utf8)
        let authority = try WorkspaceFileSystemRootAuthority(rootURL: root)
        let originalIdentity: WorkspaceFileSystemIdentity? = if originalText == nil {
            nil
        } else {
            try writeFileIdentity(at: destination)
        }
        return try WorkspaceWriteFixture(
            parent: parent,
            root: root,
            destination: destination,
            outsideFile: outsideFile,
            location: authority.location(relativePath: relativePath),
            originalIdentity: originalIdentity
        )
    }

    func write(
        _ text: String = "replacement bytes",
        to fixture: WorkspaceWriteFixture,
        expecting expectation: WorkspaceNoFollowFileWriteExpectation,
        hooks: WorkspaceAnchoredFileSystem.Hooks = .production
    ) -> WorkspaceFileWriteOutcome {
        WorkspaceNoFollowFileWriter.write(
            Data(text.utf8),
            to: fixture.location,
            expecting: expectation,
            hooks: hooks
        )
    }

    func requireNotCommitted(
        _ outcome: WorkspaceFileWriteOutcome,
        reason: WorkspaceAnchoredFileSystemError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> WorkspaceNotCommittedFileWrite? {
        guard case let .notCommitted(result) = outcome else {
            XCTFail("Expected notCommitted, got \(outcome)", file: file, line: line)
            return nil
        }
        XCTAssertEqual(result.reason, reason, file: file, line: line)
        return result
    }

    func requireDurable(
        _ outcome: WorkspaceFileWriteOutcome,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> WorkspaceDurableFileWrite? {
        guard case let .committedAndDurable(result) = outcome else {
            XCTFail("Expected committedAndDurable, got \(outcome)", file: file, line: line)
            return nil
        }
        return result
    }

    func requireIndeterminate(
        _ outcome: WorkspaceFileWriteOutcome,
        reason: WorkspaceAnchoredFileSystemError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> WorkspaceIndeterminateFileWrite? {
        guard case let .committedButIndeterminate(result) = outcome else {
            XCTFail("Expected committedButIndeterminate, got \(outcome)", file: file, line: line)
            return nil
        }
        XCTAssertEqual(result.reason, reason, file: file, line: line)
        return result
    }

    func assertFixtureSentinel(
        _ fixture: WorkspaceWriteFixture,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        XCTAssertEqual(
            try writeText(at: fixture.outsideFile),
            "outside sentinel",
            file: file,
            line: line
        )
    }

    func assertNoWriteArtifacts(
        for fixture: WorkspaceWriteFixture,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        try assertNoWriteTemporaryFiles(
            in: fixture.destination.deletingLastPathComponent(),
            file: file,
            line: line
        )
        XCTAssertTrue(
            try writeCleanupURLs(
                in: fixture.destination.deletingLastPathComponent()
            ).isEmpty,
            file: file,
            line: line
        )
    }

    func writeTemporaryURLs(in directory: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix(".plainsong-write-") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    func writeCleanupURLs(in directory: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix(".plainsong-cleanup-") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    func writeText(at url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    func writeFileIdentity(at url: URL) throws -> WorkspaceFileSystemIdentity {
        let status = try noFollowStatus(at: url)
        return WorkspaceFileSystemIdentity(
            device: UInt64(status.st_dev),
            inode: UInt64(status.st_ino)
        )
    }
}
