import Foundation
import MarkdownCore
import WorkspaceCore

public enum IOSWorkspaceScope: String, Codable, Sendable {
    case singleFile
    case directory
}

/// Only the access provider issues live grants. Constructing this value grants no I/O.
public struct IOSWorkspaceGrant: Sendable {
    public let workspaceID: IOSWorkspaceIdentity
    public let rootURL: URL
    public let accessGeneration: UInt64
    public let scope: IOSWorkspaceScope

    public init(workspaceID: IOSWorkspaceIdentity, rootURL: URL, accessGeneration: UInt64, scope: IOSWorkspaceScope) {
        self.workspaceID = workspaceID
        self.rootURL = rootURL
        self.accessGeneration = accessGeneration
        self.scope = scope
    }
}

public enum IOSWorkspaceFailure: Error, Equatable, Sendable {
    case unavailable
    case invalidPath
    case outsideGrant
    case grantChanged
    case permissionDenied
    case requiresDirectoryGrant
    case notFound
    case alreadyExists
    case readOnly
    case downloading
    case offline
    case unsupportedType
    case tooLarge
    case coordinationFailed
    case indeterminate
}

/// Keep the lease alive through provider completion, including safe drain on cancel.
/// release() is idempotent; it releases this consumer, not another operation's scope.
@MainActor
public protocol IOSWorkspaceAccessLease: AnyObject, Sendable {
    var grant: IOSWorkspaceGrant { get }
    var isReleased: Bool { get }
    func release()
}

public enum IOSWorkspaceEvent: Sendable {
    case snapshotChanged(IOSWorkspaceSnapshot)
    case invalidated(workspaceID: IOSWorkspaceIdentity, generation: UInt64)
    case resourceChanged(IOSFileLocation)
    case unavailable(workspaceID: IOSWorkspaceIdentity, reason: IOSWorkspaceFailure)
}

@MainActor
public protocol IOSWorkspaceAccessProviding: AnyObject {
    /// selectedURL must originate from an explicit picker grant, not a derived parent.
    func open(selectedURL: URL, scope: IOSWorkspaceScope) async throws -> IOSWorkspaceGrant
    func restore(bookmark: Data, scope: IOSWorkspaceScope) async throws -> IOSWorkspaceGrant
    func acquireLease(for grant: IOSWorkspaceGrant) throws -> any IOSWorkspaceAccessLease
    /// Synchronously fences consumers and publishes the new access generation.
    func invalidate(_ identity: IOSWorkspaceIdentity) -> UInt64
    func snapshot(for identity: IOSWorkspaceIdentity) -> IOSWorkspaceSnapshot?
    func refresh(_ grant: IOSWorkspaceGrant) async throws -> IOSWorkspaceSnapshot
    func observe(_ handler: @escaping @MainActor (IOSWorkspaceEvent) -> Void) -> any IOSObservation
}

public struct IOSCoordinatedRead: Sendable {
    public let operationID: UUID
    public let location: IOSFileLocation
    public let data: Data

    public init(operationID: UUID, location: IOSFileLocation, data: Data) {
        self.operationID = operationID
        self.location = location
        self.data = data
    }
}

public struct IOSCreatedLeaf: Sendable {
    public let operationID: UUID
    public let location: IOSFileLocation
    public let resourceID: IOSWorkspaceResourceIdentity

    public init(operationID: UUID, location: IOSFileLocation, resourceID: IOSWorkspaceResourceIdentity) {
        self.operationID = operationID
        self.location = location
        self.resourceID = resourceID
    }
}

/// Throws IOSWorkspaceFailure or CancellationError. Every operation revalidates
/// location/grant/generation before and after coordination; no overwrite seam.
/// UIDocument owns document writes; do not nest this coordinator in its callbacks.
public protocol IOSCoordinatedFileAccess: Sendable {
    func read(
        _ location: IOSFileLocation,
        lease: any IOSWorkspaceAccessLease,
        operationID: UUID,
        maximumByteCount: Int
    ) async throws -> IOSCoordinatedRead
    func createNewLeaf(
        at location: IOSFileLocation,
        data: Data,
        lease: any IOSWorkspaceAccessLease,
        operationID: UUID
    ) async throws -> IOSCreatedLeaf
    func directorySnapshot(
        for grant: IOSWorkspaceGrant,
        lease: any IOSWorkspaceAccessLease,
        requestID: UUID
    ) async throws -> IOSWorkspaceSnapshot
    /// Termination cancels observation, not the writer or a separately held lease.
    func events(
        for grant: IOSWorkspaceGrant,
        lease: any IOSWorkspaceAccessLease
    ) async -> AsyncStream<IOSWorkspaceEvent>
}
