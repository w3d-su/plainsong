import Foundation
import WorkspaceCore

protocol IOSSecurityScopePort: Sendable {
    func begin(url: URL, provenance: IOSAccessProvenance) -> IOSScopeAdmission
    func end(url: URL)
}

protocol IOSBookmarkPort: Sendable {
    func bookmark(for url: URL) throws -> Data
    func resolve(_ bookmark: Data) throws -> IOSBookmarkResolution
}

protocol IOSProviderIdentityPort: Sendable {
    /// Stable File Provider bytes, or nil when the system only offers an inode, document id, or URL.
    func identity(for url: URL, relativePath: String) -> Data?
}

protocol IOSWorkspaceFilePort: Sendable {
    func metadata(url: URL, relativePath: String, root: URL) async throws -> IOSWorkspaceFileItem
    func list(url: URL, relativePath: String, root: URL) async throws -> [IOSWorkspaceFileItem]
    func readFile(
        url: URL,
        relativePath: String,
        maximumByteCount: Int,
        root: URL
    ) async throws -> IOSWorkspaceFilePayload
    func createFile(url: URL, relativePath: String, data: Data, root: URL) async throws -> IOSWorkspaceFileItem
    /// Identity check and delete run inside one coordinated write. A nil or mismatched identity must not delete.
    func removeIfOwned(url: URL, relativePath: String, root: URL, providerIdentity: Data) async throws
}

protocol IOSRecentWorkspaceStoring: Sendable {
    func load() -> [IOSStoredRecentWorkspace]
    func save(_ items: [IOSStoredRecentWorkspace])
}

protocol IOSWorkspaceChangeWatching: Sendable {
    func start(
        root: URL,
        identity: IOSWorkspaceIdentity,
        sink: @escaping @Sendable (IOSExternalWorkspaceNotice) -> Void
    )
    func stop(identity: IOSWorkspaceIdentity)
}

struct IOSIdleWorkspaceWatcher: IOSWorkspaceChangeWatching {
    func start(
        root: URL,
        identity: IOSWorkspaceIdentity,
        sink: @escaping @Sendable (IOSExternalWorkspaceNotice) -> Void
    ) {
        _ = (root, identity, sink)
    }

    func stop(identity: IOSWorkspaceIdentity) {
        _ = identity
    }
}

struct IOSWorkspaceAccessPorts: Sendable {
    var scope: any IOSSecurityScopePort
    var bookmarks: any IOSBookmarkPort
    var identity: any IOSProviderIdentityPort
    var files: any IOSWorkspaceFilePort
    var recents: any IOSRecentWorkspaceStoring
    var watcher: any IOSWorkspaceChangeWatching
    var clock: @Sendable () -> Date
    var coordinationTimeoutNanoseconds: UInt64

    static let defaultTimeoutNanoseconds: UInt64 = 5_000_000_000
}
