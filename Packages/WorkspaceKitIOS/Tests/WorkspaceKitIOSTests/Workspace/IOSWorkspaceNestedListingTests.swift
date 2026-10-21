import Foundation
import WorkspaceCore
@testable import WorkspaceKitIOS
import XCTest

@MainActor
final class IOSWorkspaceNestedListingTests: XCTestCase {
    func testNestedListingUsesEachDirectoryURL() async throws {
        let harness = AccessHarness()
        let grant = try await harness.openDirectory("/tmp/plainsong-lane06/Nested")
        let notes = joined(grant.rootURL, "notes")
        let deep = joined(grant.rootURL, "notes/deep")
        harness.files.nestedListing = { url, relativePath in
            switch url.path(percentEncoded: false) {
            case grant.rootURL.path(percentEncoded: false):
                [listingEntry(url: notes, relativePath: "notes", directory: true)]
            case notes.path(percentEncoded: false):
                [listingEntry(url: deep, relativePath: "notes/deep", directory: true)]
            case deep.path(percentEncoded: false):
                [listingEntry(
                    url: joined(grant.rootURL, "notes/deep/page.md"),
                    relativePath: "notes/deep/page.md",
                    directory: false
                )]
            default:
                [listingEntry(url: url, relativePath: relativePath + "/notes", directory: true)]
            }
        }
        let snapshot = try await harness.service.refresh(grant)
        XCTAssertEqual(
            harness.files.listedPaths(),
            [
                grant.rootURL.path(percentEncoded: false),
                notes.path(percentEncoded: false),
                deep.path(percentEncoded: false),
            ]
        )
        XCTAssertEqual(harness.files.listCalls, 3)
        XCTAssertTrue(Self.paths(snapshot.entries).contains("notes/deep/page.md"))
        XCTAssertFalse(Self.paths(snapshot.entries).contains { $0.contains("notes/notes") })
    }

    func testCancelledNestedListingDrainsAfterThePortReturns() async throws {
        let harness = AccessHarness()
        let grant = try await harness.openDirectory("/tmp/plainsong-lane06/NestedCancel")
        harness.files.parkLists = true
        let refresh = Task { try await harness.service.refresh(grant) }
        await waitUntil { harness.files.parkedListCount == 1 }
        let notes = joined(grant.rootURL, "notes")
        harness.files.resumeList(.success([
            listingEntry(url: notes, relativePath: "notes", directory: true),
        ]))
        await waitUntil { harness.files.parkedListCount == 1 }
        XCTAssertEqual(harness.files.listCalls, 2)
        XCTAssertNotEqual(harness.files.listedPaths().first, harness.files.listedPaths().last)
        _ = harness.service.invalidate(grant.workspaceID)
        XCTAssertEqual(harness.scope.endCount, 0)
        XCTAssertEqual(harness.service.records[grant.workspaceID]?.operationCount, 1)
        refresh.cancel()
        do {
            _ = try await refresh.value
            XCTFail("cancelled refresh published a snapshot")
        } catch is CancellationError {
            XCTAssertEqual(harness.scope.endCount, 0)
            XCTAssertEqual(harness.service.records[grant.workspaceID]?.operationCount, 1)
        }
        harness.files.resumeList(.success([]))
        await waitUntil { harness.scope.endCount == 1 }
        XCTAssertEqual(harness.service.records[grant.workspaceID]?.operationCount, 0)
        XCTAssertLessThanOrEqual(harness.files.listCalls, 3)
    }

    func testProductionTwoLevelFolderListsFiniteChildURLs() async throws {
        let root = try makeRoot("two-level")
        defer { try? FileManager.default.removeItem(at: root) }
        let notes = IOSWorkspacePathAuthority.fileURL(
            path: IOSWorkspacePathAuthority.joined(root: root, relativePath: "notes")
        )
        let deep = IOSWorkspacePathAuthority.fileURL(
            path: IOSWorkspacePathAuthority.joined(root: root, relativePath: "notes/deep")
        )
        try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
        try Data("page".utf8).write(to: deep.appendingPathComponent("page.md"))
        try Data("local".utf8).write(to: root.appendingPathComponent("local.md"))
        let outside = try makeRoot("two-level-outside")
        defer { try? FileManager.default.removeItem(at: outside) }
        try Data("secret".utf8).write(to: outside.appendingPathComponent("secret.md"))
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("escape"),
            withDestinationURL: outside
        )
        let files = RecordingFilePort(timeoutNanoseconds: 5_000_000_000)
        let service = makeService(files: files)
        let grant = try await service.open(selectedURL: root, scope: .directory)
        let snapshot = try await service.refresh(grant)
        let listed = files.listedPaths()
        XCTAssertEqual(listed.count, 3)
        XCTAssertEqual(
            Set(listed),
            Set([
                root.path(percentEncoded: false),
                notes.path(percentEncoded: false),
                deep.path(percentEncoded: false),
            ])
        )
        let paths = Self.paths(snapshot.entries)
        XCTAssertTrue(paths.contains("notes/deep/page.md"))
        XCTAssertTrue(paths.contains("local.md"))
        XCTAssertFalse(paths.contains { $0.contains("secret") || $0.contains("notes/notes") })
    }

    private static func paths(_ entries: [IOSWorkspaceEntry]) -> [String] {
        entries.flatMap { [$0.location.relativePath] + paths($0.children) }
    }
}

private func listingEntry(url: URL, relativePath: String, directory: Bool) -> IOSWorkspaceFileItem {
    IOSWorkspaceFileItem(
        relativePath: relativePath,
        url: url,
        isDirectory: directory,
        isSymlink: false,
        fileSize: directory ? nil : 4,
        availability: .available(canWrite: true),
        providerIdentity: nil,
        bytes: nil
    )
}

private func joined(_ root: URL, _ relativePath: String) -> URL {
    IOSWorkspacePathAuthority.fileURL(
        path: IOSWorkspacePathAuthority.joined(root: root, relativePath: relativePath)
    )
}

private func makeRoot(_ name: String) throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("plainsong-lane06-\(name)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

@MainActor
private func makeService(files: RecordingFilePort) -> IOSWorkspaceAccessService {
    IOSWorkspaceAccessService(
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
}

private final class RecordingFilePort: IOSWorkspaceFilePort, @unchecked Sendable {
    private let base: IOSSystemWorkspaceFilePort
    private let lock = NSLock()
    private var listed: [String] = []

    init(timeoutNanoseconds: UInt64) {
        base = IOSSystemWorkspaceFilePort(timeoutNanoseconds: timeoutNanoseconds)
    }

    func listedPaths() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return listed
    }

    func metadata(url: URL, relativePath: String, root: URL) async throws -> IOSWorkspaceFileItem {
        try await base.metadata(url: url, relativePath: relativePath, root: root)
    }

    func list(url: URL, relativePath: String, root: URL) async throws -> [IOSWorkspaceFileItem] {
        lock.lock()
        listed.append(url.path(percentEncoded: false))
        let count = listed.count
        lock.unlock()
        if count > 8 {
            throw IOSWorkspaceFailure.coordinationFailed
        }
        return try await base.list(url: url, relativePath: relativePath, root: root)
    }

    func readFile(
        url: URL,
        relativePath: String,
        maximumByteCount: Int,
        root: URL
    ) async throws -> IOSWorkspaceFilePayload {
        try await base.readFile(
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
