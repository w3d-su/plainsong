import Foundation
import MarkdownCore
import WorkspaceCore

struct IOSDocumentSaveOperation: Sendable {
    let sequence: UInt64
    let operationID: UUID
    let snapshotText: String
    let capturedVersion: Int
    let accessGeneration: UInt64
    let identity: IOSDocumentIdentity
}

@MainActor
final class IOSDocumentEntry {
    let identity: IOSDocumentIdentity
    let resourceKey: IOSDocumentResourceKey
    let queue = IOSDocumentWriteQueue()
    var session: DocumentSession?
    var location: IOSFileLocation
    var accessGeneration: UInt64
    var lease: any IOSWorkspaceAccessLease
    var filePort: any IOSDocumentFilePort
    var state: IOSDocumentState
    var superseded = false
    var fenced = false
    var allowsProviderWrite: Bool
    var closed = false
    var lastPersistedText: String?
    var inFlightText: String?
    var lastAcknowledgedSequence: UInt64 = 0
    var nextSequence: UInt64 = 0
    var openWaiters: [CheckedContinuation<IOSDocumentHandle, Error>] = []
    var openFinished = false
    var openFailure: Error?
    var textTask: Task<Void, Never>?
    var autosaveTask: Task<Void, Never>?
    var autosaveGeneration: UInt64 = 0
    var externalToken: UUID?
    var pendingProposal: IOSDocumentReloadProposal?
    var recoveryReceipt: IOSRecoveryReceipt?
    var lastAcknowledgement: IOSSaveAcknowledgement?

    init(
        identity: IOSDocumentIdentity,
        resourceKey: IOSDocumentResourceKey,
        location: IOSFileLocation,
        lease: any IOSWorkspaceAccessLease,
        filePort: any IOSDocumentFilePort,
        allowsProviderWrite: Bool
    ) {
        self.identity = identity
        self.resourceKey = resourceKey
        self.location = location
        accessGeneration = location.accessGeneration
        self.lease = lease
        self.filePort = filePort
        self.allowsProviderWrite = allowsProviderWrite
        state = .opening(accessGeneration: location.accessGeneration)
    }

    func handle() -> IOSDocumentHandle? {
        guard let session else { return nil }
        return IOSDocumentHandle(identity: identity, session: session, location: location)
    }

    func awaitReady() async throws -> IOSDocumentHandle {
        if openFinished {
            if let handle = handle() {
                return handle
            }
            throw openFailure ?? IOSDocumentFailure.unavailable
        }
        return try await withCheckedThrowingContinuation { continuation in
            openWaiters.append(continuation)
        }
    }
}
