import Foundation
import WorkspaceCore
@testable import WorkspaceKitIOS

final class ScriptedWorkspaceWatcher: IOSWorkspaceChangeWatching, @unchecked Sendable {
    private let lock = NSLock()
    private var sinks: [IOSWorkspaceIdentity: @Sendable (IOSExternalWorkspaceNotice) -> Void] = [:]

    func start(
        root: URL,
        identity: IOSWorkspaceIdentity,
        sink: @escaping @Sendable (IOSExternalWorkspaceNotice) -> Void
    ) {
        lock.lock()
        sinks[identity] = sink
        lock.unlock()
        _ = root
    }

    func stop(identity: IOSWorkspaceIdentity) {
        lock.lock()
        sinks[identity] = nil
        lock.unlock()
    }

    func emit(_ notice: IOSExternalWorkspaceNotice, identity: IOSWorkspaceIdentity) {
        lock.lock()
        let sink = sinks[identity]
        lock.unlock()
        sink?(notice)
    }

    func sink(for identity: IOSWorkspaceIdentity) -> (@Sendable (IOSExternalWorkspaceNotice) -> Void)? {
        lock.lock()
        defer { lock.unlock() }
        return sinks[identity]
    }
}

@MainActor
struct AccessHarness {
    let scope = ScriptedScopePort()
    let bookmarks = ScriptedBookmarkPort()
    let identity = ScriptedIdentityPort()
    let files = ScriptedWorkspaceFiles()
    let recents = ScriptedRecentStore()
    let watcher: any IOSWorkspaceChangeWatching
    let service: IOSWorkspaceAccessService
    var events: [IOSWorkspaceEvent] = []

    init(
        coordinationTimeoutNanoseconds: UInt64 = 5_000_000_000,
        watcher: any IOSWorkspaceChangeWatching = IOSIdleWorkspaceWatcher()
    ) {
        self.watcher = watcher
        service = IOSWorkspaceAccessService(
            ports: IOSWorkspaceAccessPorts(
                scope: scope,
                bookmarks: bookmarks,
                identity: identity,
                files: files,
                recents: recents,
                watcher: watcher,
                clock: { Date(timeIntervalSince1970: 1_700_000_000) },
                coordinationTimeoutNanoseconds: coordinationTimeoutNanoseconds
            )
        )
    }

    func openDirectory(_ path: String = "/tmp/plainsong-lane06/Folder") async throws -> IOSWorkspaceGrant {
        files.rootIsDirectory = true
        return try await service.open(
            selectedURL: IOSWorkspacePathAuthority.fileURL(path: path),
            scope: .directory
        )
    }

    func openFile(_ path: String = "/tmp/plainsong-lane06/Folder/Note.md") async throws -> IOSWorkspaceGrant {
        files.rootIsDirectory = false
        return try await service.open(
            selectedURL: IOSWorkspacePathAuthority.fileURL(path: path),
            scope: .singleFile
        )
    }

    func location(
        grant: IOSWorkspaceGrant,
        relativePath: String,
        identityData: Data? = nil
    ) -> IOSFileLocation {
        IOSFileLocation(
            workspaceID: grant.workspaceID,
            accessGeneration: grant.accessGeneration,
            relativePath: relativePath,
            fileURL: IOSWorkspacePathAuthority.fileURL(
                path: IOSWorkspacePathAuthority.joined(root: grant.rootURL, relativePath: relativePath)
            ),
            resourceID: identityData.map { IOSWorkspaceResourceIdentity(rawValue: $0) }
        )
    }
}

func waitUntil(_ predicate: @escaping () -> Bool) async {
    for _ in 0 ..< 50 {
        if predicate() {
            return
        }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
}
