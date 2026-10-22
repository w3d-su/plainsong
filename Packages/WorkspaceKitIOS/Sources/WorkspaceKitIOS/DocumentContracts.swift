import Foundation
import MarkdownCore
import WorkspaceCore

public enum IOSDocumentFailure: Error, Equatable, Sendable {
    case unavailable
    case access(IOSWorkspaceFailure)
    case documentChanged
    case sourceChanged
    case conflict
    case saveFailed
    case closeFailed
    case recoveryFailed
    case indeterminate
}

public struct IOSRecoveryReceipt: Sendable {
    public let operationID: UUID
    public let revision: IOSDocumentRevision
    /// Opaque app-private recovery identifier, never a user document/bookmark URL.
    public let recordID: UUID

    public init(operationID: UUID, revision: IOSDocumentRevision, recordID: UUID) {
        self.operationID = operationID
        self.revision = revision
        self.recordID = recordID
    }
}

public enum IOSDocumentState: Sendable {
    case opening(accessGeneration: UInt64)
    case ready(canWrite: Bool, accessGeneration: UInt64)
    case saving(canWrite: Bool, accessGeneration: UInt64, operationID: UUID)
    case conflict(accessGeneration: UInt64, recovery: IOSRecoveryReceipt?)
    case unavailable(accessGeneration: UInt64, reason: IOSDocumentFailure)
    case closed(accessGeneration: UInt64)

    public var canWrite: Bool {
        switch self {
        case let .ready(canWrite, _), let .saving(canWrite, _, _): canWrite
        case .opening, .conflict, .unavailable, .closed: false
        }
    }

    public var accessGeneration: UInt64 {
        switch self {
        case let .opening(generation), let .closed(generation): generation
        case let .ready(_, generation), let .saving(_, generation, _): generation
        case let .conflict(generation, _), let .unavailable(generation, _): generation
        }
    }
}

/// Returned only after a guarded provider persistence acknowledgement. It describes
/// the captured bytes, not whatever source happens to be live at callback time.
public struct IOSSaveAcknowledgement: Sendable {
    public let operationID: UUID
    public let revision: IOSDocumentRevision
    public let savedText: String
    public let location: IOSFileLocation

    public init(operationID: UUID, revision: IOSDocumentRevision, savedText: String, location: IOSFileLocation) {
        self.operationID = operationID
        self.revision = revision
        self.savedText = savedText
        self.location = location
    }
}

@MainActor
public struct IOSDocumentHandle {
    public let identity: IOSDocumentIdentity
    public let session: DocumentSession
    public let location: IOSFileLocation

    public init(identity: IOSDocumentIdentity, session: DocumentSession, location: IOSFileLocation) {
        self.identity = identity
        self.session = session
        self.location = location
    }
}

public struct IOSStoredDocumentSnapshot: Sendable {
    public let revision: IOSDocumentRevision
    public let document: DocumentSnapshot
    public let location: IOSFileLocation
    public let state: IOSDocumentState

    public init(
        revision: IOSDocumentRevision,
        document: DocumentSnapshot,
        location: IOSFileLocation,
        state: IOSDocumentState
    ) {
        self.revision = revision
        self.document = document
        self.location = location
        self.state = state
    }
}

public enum IOSExternalResolution: Sendable {
    case reload
    case saveCopy(destination: IOSFileLocation, lease: any IOSWorkspaceAccessLease)
}

public enum IOSDocumentCloseOutcome: Sendable {
    case closed
    case retained(recovery: IOSRecoveryReceipt?)
}

public enum IOSDocumentFlushOutcome: Sendable {
    case saved(IOSSaveAcknowledgement)
    case recovered(IOSRecoveryReceipt)
    case retained(IOSDocumentIdentity, IOSDocumentFailure)
}

public enum IOSDocumentEvent: Sendable {
    /// Opening/unavailable can be observed without inventing an empty source.
    case stateChanged(identity: IOSDocumentIdentity, location: IOSFileLocation, state: IOSDocumentState)
    case snapshotChanged(IOSStoredDocumentSnapshot)
    case saveCompleted(IOSSaveAcknowledgement)
    case failed(IOSDocumentIdentity, operationID: UUID, reason: IOSDocumentFailure)
    case externalReloadRequested(IOSDocumentReloadProposal)
    case recoveryPersisted(IOSRecoveryReceipt)
    case closed(IOSDocumentIdentity)
}

/// Facade implemented by 05's UIDocument store. Same-resource opens share one entry,
/// session and serialized writer. Async cancellation must not discard dirty source.
/// Throws IOSDocumentFailure or CancellationError; failure never implies clean state.
@MainActor
public protocol IOSDocumentStore: AnyObject {
    func open(_ location: IOSFileLocation, lease: any IOSWorkspaceAccessLease) async throws -> IOSDocumentHandle
    func create(
        at location: IOSFileLocation,
        initialText: String,
        lease: any IOSWorkspaceAccessLease
    ) async throws -> IOSDocumentHandle
    func save(_ identity: IOSDocumentIdentity) async throws -> IOSSaveAcknowledgement
    func close(_ identity: IOSDocumentIdentity) async throws -> IOSDocumentCloseOutcome
    func saveCopy(
        _ identity: IOSDocumentIdentity,
        destination: IOSFileLocation,
        lease: any IOSWorkspaceAccessLease
    ) async throws -> IOSSaveAcknowledgement
    func resolveExternal(_ identity: IOSDocumentIdentity, choice: IOSExternalResolution) async throws
    /// 13 calls after the editor's synchronous reconciliation guard, without await.
    func acknowledgeExternalReload(operationID: UUID, outcome: IOSDocumentReloadOutcome)
    func state(for identity: IOSDocumentIdentity) -> IOSDocumentState?
    func snapshot(for identity: IOSDocumentIdentity) -> IOSStoredDocumentSnapshot?
    func observe(_ handler: @escaping @MainActor (IOSDocumentEvent) -> Void) -> any IOSObservation
    func flushForBackground() async -> [IOSDocumentFlushOutcome]
}
