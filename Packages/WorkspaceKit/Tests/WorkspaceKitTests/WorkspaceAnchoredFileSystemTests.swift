import Darwin
import Foundation
@testable import WorkspaceKit
import XCTest

final class WorkspaceAnchoredFileSystemTests: XCTestCase {
    func testLocationRejectsEmbeddedNULBeforeCallingPOSIXAPIs() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        XCTAssertThrowsError(
            try WorkspaceFileSystemRootAuthority(rootURL: root)
                .location(relativePath: "visible\0hidden.md")
        ) { error in
            XCTAssertEqual(
                error as? WorkspaceRootContainmentError,
                .traversal("visible\0hidden.md")
            )
        }
    }

    func testAnchoredReaderRejectsLeafSymlinksToInsideAndOutsideRoot() async throws {
        let parent = try makeTemporaryDirectory()
        let root = parent.appendingPathComponent("workspace", isDirectory: true)
        let outside = parent.appendingPathComponent("outside.md")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let inside = root.appendingPathComponent("inside.md")
        try "inside".write(to: inside, atomically: true, encoding: .utf8)
        try "outside".write(to: outside, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("inside-alias.md"),
            withDestinationURL: inside
        )
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("outside-alias.md"),
            withDestinationURL: outside
        )
        defer { try? FileManager.default.removeItem(at: parent) }

        let authority = try WorkspaceFileSystemRootAuthority(rootURL: root)
        let reader = WorkspaceCoherentFileReader()
        let insideOutcome = try await reader.readCoherentFile(
            at: authority.location(relativePath: "inside-alias.md")
        )
        let outsideOutcome = try await reader.readCoherentFile(
            at: authority.location(relativePath: "outside-alias.md")
        )

        XCTAssertEqual(insideOutcome, .symbolicLink)
        XCTAssertEqual(outsideOutcome, .symbolicLink)
    }

    func testAnchoredInspectionRejectsFIFOWithoutBlocking() async throws {
        let root = try makeTemporaryDirectory()
        let fifo = root.appendingPathComponent("pipe.md")
        let result = fifo.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.mkfifo(path, mode_t(S_IRUSR | S_IWUSR))
        }
        guard result == 0 else { return XCTFail("Could not create FIFO") }
        defer { try? FileManager.default.removeItem(at: root) }
        let location = try WorkspaceFileSystemRootAuthority(rootURL: root)
            .location(relativePath: "pipe.md")

        XCTAssertEqual(WorkspaceNoFollowFileInspector.status(at: location), .notRegularFile)
        let outcome = await WorkspaceCoherentFileReader().readCoherentFile(at: location)
        XCTAssertEqual(outcome, .notRegularFile)
    }

    func testAnchoredInspectorRejectsEveryIntermediateSymlinkComponent() throws {
        let parent = try makeTemporaryDirectory()
        let root = parent.appendingPathComponent("workspace", isDirectory: true)
        let insideDirectory = root.appendingPathComponent("inside", isDirectory: true)
        let outsideDirectory = parent.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: insideDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outsideDirectory, withIntermediateDirectories: true)
        try "inside".write(
            to: insideDirectory.appendingPathComponent("post.md"),
            atomically: true,
            encoding: .utf8
        )
        try "outside".write(
            to: outsideDirectory.appendingPathComponent("post.md"),
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("inside-link"),
            withDestinationURL: insideDirectory
        )
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("outside-link"),
            withDestinationURL: outsideDirectory
        )
        defer { try? FileManager.default.removeItem(at: parent) }

        let authority = try WorkspaceFileSystemRootAuthority(rootURL: root)
        let insideLocation = try authority.location(relativePath: "inside-link/post.md")
        let outsideLocation = try authority.location(relativePath: "outside-link/post.md")
        XCTAssertEqual(
            WorkspaceNoFollowFileInspector.status(at: insideLocation),
            .symbolicLink
        )
        XCTAssertEqual(
            WorkspaceNoFollowFileInspector.status(at: outsideLocation),
            .symbolicLink
        )
        XCTAssertThrowsError(try MarkdownFileStore().load(at: insideLocation))
        XCTAssertThrowsError(try MarkdownFileStore().load(at: outsideLocation))
    }

    func testTargetInspectionSupportsWriteOnlyAndNoAccessExistingFile() throws {
        let root = try makeTemporaryDirectory()
        let file = root.appendingPathComponent("post.md")
        let unrelatedHardLink = root.appendingPathComponent("unrelated-hard-link.md")
        try "original".write(to: unrelatedHardLink, atomically: true, encoding: .utf8)
        try FileManager.default.linkItem(at: unrelatedHardLink, to: file)
        defer { try? FileManager.default.removeItem(at: root) }
        defer { _ = Darwin.chmod(file.path, mode_t(S_IRUSR | S_IWUSR)) }

        let location = try WorkspaceFileSystemRootAuthority(rootURL: root)
            .location(relativePath: "post.md")
        let expectedParentIsCaseSensitive = try caseSensitivity(at: root)
        let fileStatus = try noFollowStatus(at: file)
        let expectedIdentity = WorkspaceFileSystemIdentity(
            device: UInt64(fileStatus.st_dev),
            inode: UInt64(fileStatus.st_ino)
        )

        for mode in [mode_t(S_IWUSR), mode_t(0)] {
            XCTAssertEqual(Darwin.chmod(file.path, mode), 0)

            let inspection = try WorkspaceNoFollowFileInspector.inspectFileTarget(at: location)

            XCTAssertEqual(inspection.state, .regular(expectedIdentity))
            XCTAssertEqual(inspection.canonicalLocation, location)
            XCTAssertEqual(
                inspection.parentIsCaseSensitive,
                expectedParentIsCaseSensitive
            )
        }
    }

    func testMissingTargetInspectionReturnsDescriptorCanonicalCaseAliasParent() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let canonicalDirectory = root.appendingPathComponent("Folder", isDirectory: true)
        let aliasDirectory = root.appendingPathComponent("folder", isDirectory: true)
        try FileManager.default.createDirectory(
            at: canonicalDirectory,
            withIntermediateDirectories: true
        )
        guard FileManager.default.fileExists(atPath: aliasDirectory.path) else {
            throw XCTSkip("Case-sensitive volume has no case-alias directory")
        }

        let authority = try WorkspaceFileSystemRootAuthority(rootURL: root)
        let aliasLocation = try authority.location(relativePath: "folder/recovered.md")
        let expectedLocation = try authority.location(relativePath: "Folder/recovered.md")

        let inspection = try WorkspaceNoFollowFileInspector.inspectFileTarget(at: aliasLocation)

        XCTAssertEqual(inspection.state, .missing)
        XCTAssertEqual(inspection.canonicalLocation, expectedLocation)
        XCTAssertNotEqual(inspection.canonicalLocation, aliasLocation)
        XCTAssertFalse(inspection.parentIsCaseSensitive)
    }

    func testLeafReplacementAfterParentIsAnchoredCannotRedirectRead() async throws {
        let parent = try makeTemporaryDirectory()
        let root = parent.appendingPathComponent("workspace", isDirectory: true)
        let file = root.appendingPathComponent("post.md")
        let outside = parent.appendingPathComponent("outside.md")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "original".write(to: file, atomically: true, encoding: .utf8)
        try "outside sentinel".write(to: outside, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: parent) }

        let mutation = SynchronousMutation {
            try FileManager.default.removeItem(at: file)
            try FileManager.default.createSymbolicLink(at: file, withDestinationURL: outside)
        }
        let reader = WorkspaceCoherentFileReader { event in
            if event == .parentAnchored(0) {
                mutation.run()
            }
        }
        let location = try WorkspaceFileSystemRootAuthority(rootURL: root)
            .location(relativePath: "post.md")

        let outcome = await reader.readCoherentFile(at: location)
        try mutation.rethrowIfFailed()

        XCTAssertEqual(outcome, .symbolicLink)
        XCTAssertEqual(try String(contentsOf: outside, encoding: .utf8), "outside sentinel")
    }

    func testIntermediateReplacementAfterRootIsAnchoredCannotRedirectReadInsideRoot() async throws {
        let root = try makeTemporaryDirectory()
        let nested = root.appendingPathComponent("nested", isDirectory: true)
        let target = root.appendingPathComponent("target", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try "original".write(
            to: nested.appendingPathComponent("post.md"),
            atomically: true,
            encoding: .utf8
        )
        try "redirected".write(
            to: target.appendingPathComponent("post.md"),
            atomically: true,
            encoding: .utf8
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let mutation = SynchronousMutation {
            try FileManager.default.removeItem(at: nested)
            try FileManager.default.createSymbolicLink(at: nested, withDestinationURL: target)
        }
        let reader = WorkspaceCoherentFileReader { event in
            if event == .rootAnchored(0) {
                mutation.run()
            }
        }
        let location = try WorkspaceFileSystemRootAuthority(rootURL: root)
            .location(relativePath: "nested/post.md")

        let outcome = await reader.readCoherentFile(at: location)
        try mutation.rethrowIfFailed()

        XCTAssertEqual(outcome, .symbolicLink)
    }

    func testRootAuthorityRejectsPhysicalRootReplacement() async throws {
        let parent = try makeTemporaryDirectory()
        let root = parent.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "original".write(
            to: root.appendingPathComponent("post.md"),
            atomically: true,
            encoding: .utf8
        )
        defer { try? FileManager.default.removeItem(at: parent) }
        let authority = try WorkspaceFileSystemRootAuthority(rootURL: root)
        let location = try authority.location(relativePath: "post.md")

        try FileManager.default.moveItem(
            at: root,
            to: parent.appendingPathComponent("displaced", isDirectory: true)
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "replacement".write(
            to: root.appendingPathComponent("post.md"),
            atomically: true,
            encoding: .utf8
        )

        let outcome = await WorkspaceCoherentFileReader().readCoherentFile(at: location)

        XCTAssertEqual(outcome, .namespaceChanged)
    }
}

extension WorkspaceAnchoredFileSystemTests {
    func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkspaceAnchoredFileSystemTests")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func noFollowStatus(at url: URL) throws -> stat {
        var fileStatus = stat()
        let result = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.lstat(path, &fileStatus)
        }
        guard result == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        return fileStatus
    }

    func caseSensitivity(at directory: URL) throws -> Bool {
        let descriptor = Darwin.open(
            directory.path,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard descriptor >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        defer { Darwin.close(descriptor) }
        errno = 0
        let value = Darwin.fpathconf(descriptor, _PC_CASE_SENSITIVE)
        guard value >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        return value != 0
    }

    func assertNoWriteTemporaryFiles(
        in directory: URL,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        XCTAssertFalse(
            try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .contains { $0.lastPathComponent.hasPrefix(".plainsong-write-") },
            file: file,
            line: line
        )
    }

    func assertRestoredSymlink(
        at url: URL,
        matches expectedStatus: stat,
        destination: URL,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let restoredStatus = try noFollowStatus(at: url)
        XCTAssertEqual(restoredStatus.st_mode & S_IFMT, S_IFLNK, file: file, line: line)
        XCTAssertEqual(restoredStatus.st_dev, expectedStatus.st_dev, file: file, line: line)
        XCTAssertEqual(restoredStatus.st_ino, expectedStatus.st_ino, file: file, line: line)
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: url.path),
            destination.path,
            file: file,
            line: line
        )
    }
}

final class SynchronousMutation: @unchecked Sendable {
    private let lock = NSLock()
    private let operation: () throws -> Void
    private var didRun = false
    private var failure: Error?

    init(operation: @escaping () throws -> Void) {
        self.operation = operation
    }

    func run() {
        lock.withLock {
            guard !didRun else { return }
            didRun = true
            do {
                try operation()
            } catch {
                failure = error
            }
        }
    }

    func rethrowIfFailed() throws {
        try lock.withLock {
            if let failure {
                throw failure
            }
        }
    }
}
