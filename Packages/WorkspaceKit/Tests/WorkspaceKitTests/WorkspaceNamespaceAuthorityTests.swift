import Foundation
@testable import WorkspaceKit
import XCTest

extension WorkspaceAnchoredFileSystemTests {
    func testIntermediateSymlinkSubstitutionBeforeOpenFailsClosed() async throws {
        let parent = try makeTemporaryDirectory()
        let root = parent.appendingPathComponent("workspace", isDirectory: true)
        let nested = root.appendingPathComponent("nested", isDirectory: true)
        let moved = root.appendingPathComponent("moved", isDirectory: true)
        let outsideDirectory = parent.appendingPathComponent("outside", isDirectory: true)
        let outsideFile = outsideDirectory.appendingPathComponent("post.md")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outsideDirectory, withIntermediateDirectories: true)
        let original = nested.appendingPathComponent("post.md")
        try "original".write(to: original, atomically: true, encoding: .utf8)
        try "outside sentinel".write(to: outsideFile, atomically: true, encoding: .utf8)
        let originalIdentity = try fileIdentity(at: original)
        defer { try? FileManager.default.removeItem(at: parent) }

        let mutation = SynchronousMutation {
            try FileManager.default.moveItem(at: nested, to: moved)
            try FileManager.default.createSymbolicLink(at: nested, withDestinationURL: outsideDirectory)
        }
        let reader = WorkspaceCoherentFileReader { event in
            if event == .rootAnchored(0) { mutation.run() }
        }
        let location = try WorkspaceFileSystemRootAuthority(rootURL: root)
            .location(relativePath: "nested/post.md")

        let outcome = await reader.readCoherentFile(at: location)

        try mutation.rethrowIfFailed()
        XCTAssertEqual(outcome, .symbolicLink)
        XCTAssertEqual(try text(at: moved.appendingPathComponent("post.md")), "original")
        XCTAssertEqual(try fileIdentity(at: moved.appendingPathComponent("post.md")), originalIdentity)
        XCTAssertEqual(try text(at: outsideFile), "outside sentinel")
        try assertNoWriteTemporaryFiles(in: moved)
        try assertNoWriteTemporaryFiles(in: outsideDirectory)
    }

    func testIntermediateRenameReplacementAfterComponentOpenedCannotReturnDetachedBytes() async throws {
        let fixture = try makeNamespaceFixture(relativeParent: "nested")
        defer { try? FileManager.default.removeItem(at: fixture.parent) }
        let mutation = SynchronousMutation {
            try fixture.replaceOpenedParent()
        }
        let reader = WorkspaceCoherentFileReader { event in
            if event == .componentOpened(0, "nested") { mutation.run() }
        }
        let location = try WorkspaceFileSystemRootAuthority(rootURL: fixture.root)
            .location(relativePath: "nested/post.md")

        let outcome = await reader.readCoherentFile(at: location)

        try mutation.rethrowIfFailed()
        XCTAssertEqual(outcome, .namespaceChanged)
        try assertNamespaceFixtureAfterReplacement(fixture)
    }

    func testWorkspaceRootMoveReplacementAfterRootAnchoringFailsClosed() async throws {
        let parent = try makeTemporaryDirectory()
        let root = parent.appendingPathComponent("workspace", isDirectory: true)
        let movedRoot = parent.appendingPathComponent("moved-workspace", isDirectory: true)
        let outside = parent.appendingPathComponent("outside.md")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let original = root.appendingPathComponent("post.md")
        try "original".write(to: original, atomically: true, encoding: .utf8)
        try "outside sentinel".write(to: outside, atomically: true, encoding: .utf8)
        let originalIdentity = try fileIdentity(at: original)
        let authority = try WorkspaceFileSystemRootAuthority(rootURL: root)
        let mutation = SynchronousMutation {
            try FileManager.default.moveItem(at: root, to: movedRoot)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try "replacement".write(
                to: root.appendingPathComponent("post.md"),
                atomically: true,
                encoding: .utf8
            )
        }
        let reader = WorkspaceCoherentFileReader { event in
            if event == .rootAnchored(0) { mutation.run() }
        }
        defer { try? FileManager.default.removeItem(at: parent) }

        let outcome = try await reader.readCoherentFile(
            at: authority.location(relativePath: "post.md")
        )

        try mutation.rethrowIfFailed()
        XCTAssertEqual(outcome, .namespaceChanged)
        XCTAssertEqual(try text(at: root.appendingPathComponent("post.md")), "replacement")
        XCTAssertEqual(try text(at: movedRoot.appendingPathComponent("post.md")), "original")
        XCTAssertEqual(try fileIdentity(at: movedRoot.appendingPathComponent("post.md")), originalIdentity)
        XCTAssertNotEqual(try fileIdentity(at: root.appendingPathComponent("post.md")), originalIdentity)
        XCTAssertEqual(try text(at: outside), "outside sentinel")
        try assertNoWriteTemporaryFiles(in: root)
        try assertNoWriteTemporaryFiles(in: movedRoot)
    }

    func testFinalParentReplacementAfterItWasOpenedFailsClosed() async throws {
        let fixture = try makeNamespaceFixture(relativeParent: "outer/final")
        defer { try? FileManager.default.removeItem(at: fixture.parent) }
        let mutation = SynchronousMutation {
            try fixture.replaceOpenedParent()
        }
        let reader = WorkspaceCoherentFileReader { event in
            if event == .componentOpened(0, "final") { mutation.run() }
        }
        let location = try WorkspaceFileSystemRootAuthority(rootURL: fixture.root)
            .location(relativePath: "outer/final/post.md")

        let outcome = await reader.readCoherentFile(at: location)

        try mutation.rethrowIfFailed()
        XCTAssertEqual(outcome, .namespaceChanged)
        try assertNamespaceFixtureAfterReplacement(fixture)
    }

    func testLeafReplacementAfterDescriptorOpenDoesNotReturnMovedFileAsCanonical() async throws {
        let parent = try makeTemporaryDirectory()
        let root = parent.appendingPathComponent("workspace", isDirectory: true)
        let canonical = root.appendingPathComponent("post.md")
        let moved = root.appendingPathComponent("moved.md")
        let outside = parent.appendingPathComponent("outside.md")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "original".write(to: canonical, atomically: true, encoding: .utf8)
        try "outside sentinel".write(to: outside, atomically: true, encoding: .utf8)
        let originalIdentity = try fileIdentity(at: canonical)
        defer { try? FileManager.default.removeItem(at: parent) }

        let mutation = SynchronousMutation {
            try FileManager.default.moveItem(at: canonical, to: moved)
            try "replacement".write(to: canonical, atomically: true, encoding: .utf8)
        }
        let reader = WorkspaceCoherentFileReader { event in
            if event == .opened(0) { mutation.run() }
        }
        let location = try WorkspaceFileSystemRootAuthority(rootURL: root)
            .location(relativePath: "post.md")

        let outcome = await reader.readCoherentFile(at: location)

        try mutation.rethrowIfFailed()
        XCTAssertEqual(outcome, .namespaceChanged)
        XCTAssertEqual(try text(at: canonical), "replacement")
        XCTAssertEqual(try text(at: moved), "original")
        XCTAssertEqual(try fileIdentity(at: moved), originalIdentity)
        XCTAssertNotEqual(try fileIdentity(at: canonical), originalIdentity)
        XCTAssertEqual(try text(at: outside), "outside sentinel")
        try assertNoWriteTemporaryFiles(in: root)
    }

    func testNamespaceMoveBetweenPostReadChainAndLeafValidationCannotReturnDetachedBytes() throws {
        let fixture = try makeNamespaceFixture(relativeParent: "nested")
        defer { try? FileManager.default.removeItem(at: fixture.parent) }
        let mutation = SynchronousMutation {
            try fixture.replaceOpenedParent()
        }
        let secondValidation = EventOccurrenceTrigger(occurrence: 2) {
            mutation.run()
        }
        let location = try WorkspaceFileSystemRootAuthority(rootURL: fixture.root)
            .location(relativePath: "nested/post.md")

        XCTAssertThrowsError(
            try WorkspaceAnchoredFileSystem.withSecurityScopedAccess(to: location) {
                try WorkspaceAnchoredFileSystem.read(
                    location,
                    maximumByteCount: nil,
                    hooks: .init(eventHandler: { event in
                        if event == .namespaceValidated { secondValidation.observe() }
                    })
                )
            }
        ) { error in
            XCTAssertEqual(error as? WorkspaceAnchoredFileSystemError, .namespaceChanged)
        }

        try mutation.rethrowIfFailed()
        try assertNamespaceFixtureAfterReplacement(fixture)
    }
}

private extension WorkspaceAnchoredFileSystemTests {
    struct NamespaceFixture: @unchecked Sendable {
        let parent: URL
        let root: URL
        let openedParent: URL
        let movedParent: URL
        let canonicalFile: URL
        let movedFile: URL
        let outsideFile: URL
        let originalIdentity: WorkspaceFileSystemIdentity

        func replaceOpenedParent() throws {
            try FileManager.default.moveItem(at: openedParent, to: movedParent)
            try FileManager.default.createDirectory(at: openedParent, withIntermediateDirectories: true)
            try "replacement".write(to: canonicalFile, atomically: true, encoding: .utf8)
        }
    }

    func makeNamespaceFixture(relativeParent: String) throws -> NamespaceFixture {
        let parent = try makeTemporaryDirectory()
        let root = parent.appendingPathComponent("workspace", isDirectory: true)
        let openedParent = root.appendingPathComponent(relativeParent, isDirectory: true)
        let movedParent = openedParent.deletingLastPathComponent()
            .appendingPathComponent("moved-\(openedParent.lastPathComponent)", isDirectory: true)
        let canonicalFile = openedParent.appendingPathComponent("post.md")
        let movedFile = movedParent.appendingPathComponent("post.md")
        let outsideFile = parent.appendingPathComponent("outside.md")
        try FileManager.default.createDirectory(at: openedParent, withIntermediateDirectories: true)
        try "original".write(to: canonicalFile, atomically: true, encoding: .utf8)
        try "outside sentinel".write(to: outsideFile, atomically: true, encoding: .utf8)
        return try NamespaceFixture(
            parent: parent,
            root: root,
            openedParent: openedParent,
            movedParent: movedParent,
            canonicalFile: canonicalFile,
            movedFile: movedFile,
            outsideFile: outsideFile,
            originalIdentity: fileIdentity(at: canonicalFile)
        )
    }

    func assertNamespaceFixtureAfterReplacement(
        _ fixture: NamespaceFixture,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        XCTAssertEqual(try text(at: fixture.canonicalFile), "replacement", file: file, line: line)
        XCTAssertEqual(try text(at: fixture.movedFile), "original", file: file, line: line)
        XCTAssertEqual(
            try fileIdentity(at: fixture.movedFile),
            fixture.originalIdentity,
            file: file,
            line: line
        )
        XCTAssertNotEqual(
            try fileIdentity(at: fixture.canonicalFile),
            fixture.originalIdentity,
            file: file,
            line: line
        )
        XCTAssertEqual(try text(at: fixture.outsideFile), "outside sentinel", file: file, line: line)
        try assertNoWriteTemporaryFiles(in: fixture.openedParent, file: file, line: line)
        try assertNoWriteTemporaryFiles(in: fixture.movedParent, file: file, line: line)
    }

    func text(at url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    func fileIdentity(at url: URL) throws -> WorkspaceFileSystemIdentity {
        let status = try noFollowStatus(at: url)
        return WorkspaceFileSystemIdentity(
            device: UInt64(status.st_dev),
            inode: UInt64(status.st_ino)
        )
    }
}

private final class EventOccurrenceTrigger: @unchecked Sendable {
    private let lock = NSLock()
    private let occurrence: Int
    private let action: () -> Void
    private var count = 0

    init(occurrence: Int, action: @escaping () -> Void) {
        self.occurrence = occurrence
        self.action = action
    }

    func observe() {
        let shouldAct = lock.withLock {
            count += 1
            return count == occurrence
        }
        if shouldAct { action() }
    }
}
