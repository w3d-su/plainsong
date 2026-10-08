import Foundation

/// Opaque identity of one open instance. A URL or source version is not an identity.
public struct IOSDocumentIdentity: Hashable, Codable, Sendable {
    public let rawValue: UUID

    public init(rawValue: UUID) {
        self.rawValue = rawValue
    }
}

public struct IOSDocumentRevision: Hashable, Codable, Sendable {
    public let documentID: IOSDocumentIdentity
    public let version: Int

    public init(documentID: IOSDocumentIdentity, version: Int) {
        self.documentID = documentID
        self.version = version
    }
}

/// The subscriber retains this token and cancels it before switching or detaching.
/// Cancellation is idempotent and synchronously fences subsequent callbacks.
@MainActor
public protocol IOSObservation: AnyObject {
    func cancel()
}

/// An external read is only a proposal until the native editor checks this capture.
/// Installing it is reconciliation, not a user command or a new Undo entry.
public struct IOSDocumentReloadProposal: Sendable {
    public let operationID: UUID
    public let capturedRevision: IOSDocumentRevision
    public let accessGeneration: UInt64
    public let text: String
    public let fileURL: URL
    public let fileKind: FileKind
    public let statistics: TextStatistics

    public init(
        operationID: UUID,
        capturedRevision: IOSDocumentRevision,
        accessGeneration: UInt64,
        text: String,
        fileURL: URL,
        fileKind: FileKind,
        statistics: TextStatistics
    ) {
        self.operationID = operationID
        self.capturedRevision = capturedRevision
        self.accessGeneration = accessGeneration
        self.text = text
        self.fileURL = fileURL
        self.fileKind = fileKind
        self.statistics = statistics
    }
}

public enum IOSDocumentReloadOutcome: Equatable, Sendable {
    case installed(IOSDocumentRevision)
    case deferred
    case refused(IOSDocumentReloadRefusal)
}

public enum IOSDocumentReloadRefusal: Equatable, Sendable {
    case documentChanged
    case sourceChanged
    case accessChanged
    case unavailable
}
