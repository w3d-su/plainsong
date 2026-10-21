import Foundation
import WorkspaceCore
@testable import WorkspaceKitIOS
import XCTest

@MainActor
final class IOSWorkspaceAliasRootTests: XCTestCase {
    func testAliasRootListReadAndRepeatReadUseTheLogicalGrantLocation() async throws {
        let real = try makeRoot("alias-real")
        let linkParent = try makeRoot("alias-link")
        defer {
            try? FileManager.default.removeItem(at: real)
            try? FileManager.default.removeItem(at: linkParent)
        }
        try Data("note-body".utf8).write(to: real.appendingPathComponent("Note.md"))
        try Data("secret".utf8).write(to: linkParent.appendingPathComponent("secret.md"))
        let alias = linkParent.appendingPathComponent("Grant")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: real)
        let aliasURL = IOSWorkspacePathAuthority.fileURL(path: alias.path(percentEncoded: false))
        let files = CountingFilePort(timeoutNanoseconds: 5_000_000_000)
        let service = IOSWorkspaceAccessService(
            ports: IOSWorkspaceAccessPorts(
                scope: ScriptedScopePort(),
                bookmarks: ScriptedBookmarkPort(),
                identity: ScriptedIdentityPort(),
                files: files,
                recents: ScriptedRecentStore(),
                watcher: IOSIdleWorkspaceWatcher(),
                clock: { Date(timeIntervalSince1970: 1_700_000_000) },
                coordinationTimeoutNanoseconds: 5_000_000_000
            )
        )
        let grant = try await service.open(selectedURL: aliasURL, scope: .directory)
        XCTAssertEqual(
            grant.rootURL.path(percentEncoded: false),
            aliasURL.path(percentEncoded: false)
        )
        let snapshot = try await service.refresh(grant)
        let entry = try XCTUnwrap(snapshot.entries.first { $0.location.relativePath == "Note.md" })
        let logical = IOSWorkspacePathAuthority.fileURL(
            path: IOSWorkspacePathAuthority.joined(root: grant.rootURL, relativePath: "Note.md")
        )
        XCTAssertEqual(entry.location.fileURL.path(percentEncoded: false), logical.path(percentEncoded: false))
        XCTAssertTrue(IOSWorkspacePathAuthority.directoryContains(
            root: grant.rootURL,
            file: entry.location.fileURL,
            relativePath: entry.location.relativePath
        ))
        XCTAssertFalse(snapshot.entries.contains { $0.location.relativePath.contains("secret") })

        let proved = try await files.metadata(url: logical, relativePath: "Note.md", root: grant.rootURL)
        let provedPath = try XCTUnwrap(proved.provedURL).path(percentEncoded: false)
        XCTAssertNotEqual(provedPath, logical.path(percentEncoded: false))
        XCTAssertEqual(proved.url.path(percentEncoded: false), logical.path(percentEncoded: false))
        let canonical = IOSWorkspacePathAuthority.fileURL(path: provedPath)
        XCTAssertFalse(IOSWorkspacePathAuthority.directoryContains(
            root: grant.rootURL,
            file: canonical,
            relativePath: "Note.md"
        ))

        let lease = try service.acquireLease(for: grant)
        let first = try await service.read(
            entry.location,
            lease: lease,
            operationID: UUID(),
            maximumByteCount: 64
        )
        XCTAssertEqual(first.data, Data("note-body".utf8))
        XCTAssertEqual(first.location.fileURL.path(percentEncoded: false), logical.path(percentEncoded: false))
        let second = try await service.read(
            first.location,
            lease: lease,
            operationID: UUID(),
            maximumByteCount: 64
        )
        XCTAssertEqual(second.data, first.data)
        XCTAssertEqual(second.location.fileURL.path(percentEncoded: false), logical.path(percentEncoded: false))
        let readsAfterLogical = files.readCount

        let provedLocation = IOSFileLocation(
            workspaceID: grant.workspaceID,
            accessGeneration: grant.accessGeneration,
            relativePath: "Note.md",
            fileURL: canonical,
            resourceID: nil
        )
        do {
            _ = try await service.read(provedLocation, lease: lease, operationID: UUID(), maximumByteCount: 64)
            XCTFail("canonical location passed literal authorize")
        } catch let failure as IOSWorkspaceFailure {
            XCTAssertEqual(failure, .outsideGrant)
        }
        let sibling = IOSFileLocation(
            workspaceID: grant.workspaceID,
            accessGeneration: grant.accessGeneration,
            relativePath: "secret.md",
            fileURL: IOSWorkspacePathAuthority.fileURL(
                path: linkParent.appendingPathComponent("secret.md").path(percentEncoded: false)
            ),
            resourceID: nil
        )
        do {
            _ = try await service.read(sibling, lease: lease, operationID: UUID(), maximumByteCount: 64)
            XCTFail("sibling of the alias root was authorized")
        } catch let failure as IOSWorkspaceFailure {
            XCTAssertEqual(failure, .outsideGrant)
        }
        XCTAssertEqual(files.readCount, readsAfterLogical)
        lease.release()
    }
}

private func makeRoot(_ name: String) throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("plainsong-lane06-\(name)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private final class CountingFilePort: IOSWorkspaceFilePort, @unchecked Sendable {
    private let base: IOSSystemWorkspaceFilePort
    private let lock = NSLock()
    private var reads = 0

    init(timeoutNanoseconds: UInt64) {
        base = IOSSystemWorkspaceFilePort(timeoutNanoseconds: timeoutNanoseconds)
    }

    var readCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return reads
    }

    func metadata(url: URL, relativePath: String, root: URL) async throws -> IOSWorkspaceFileItem {
        try await base.metadata(url: url, relativePath: relativePath, root: root)
    }

    func list(url: URL, relativePath: String, root: URL) async throws -> [IOSWorkspaceFileItem] {
        try await base.list(url: url, relativePath: relativePath, root: root)
    }

    func readFile(
        url: URL,
        relativePath: String,
        maximumByteCount: Int,
        root: URL
    ) async throws -> IOSWorkspaceFilePayload {
        lock.lock()
        reads += 1
        lock.unlock()
        return try await base.readFile(
            url: url,
            relativePath: relativePath,
            maximumByteCount: maximumByteCount,
            root: root
        )
    }

    func createFile(url: URL, relativePath: String, data: Data, root: URL) async throws -> IOSWorkspaceFileItem {
        try await base.createFile(url: url, relativePath: relativePath, data: data, root: root)
    }

    func removeIfOwned(url: URL, relativePath: String, root: URL, providerIdentity: Data) async throws {
        try await base.removeIfOwned(
            url: url,
            relativePath: relativePath,
            root: root,
            providerIdentity: providerIdentity
        )
    }
}
