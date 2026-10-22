import Foundation

public enum IOSRecoveryReason: String, Codable, Sendable {
    case externalConflict
    case backgroundDeadline
    case closeIncomplete
    case saveIndeterminate
}

public struct IOSRecoveryRecord: Codable, Sendable, Equatable {
    public let formatVersion: Int
    public let recordID: UUID
    public let operationID: UUID
    public let documentID: UUID
    public let revisionVersion: Int
    public let workspaceID: UUID
    public let accessGeneration: UInt64
    public let resourceID: Data?
    public let relativePathUTF8: Data
    public let fileURLPath: String
    public let source: String
    public let baseline: String
    public let reason: IOSRecoveryReason

    public init(
        formatVersion: Int = 1,
        recordID: UUID,
        operationID: UUID,
        documentID: UUID,
        revisionVersion: Int,
        workspaceID: UUID,
        accessGeneration: UInt64,
        resourceID: Data?,
        relativePathUTF8: Data,
        fileURLPath: String,
        source: String,
        baseline: String,
        reason: IOSRecoveryReason
    ) {
        self.formatVersion = formatVersion
        self.recordID = recordID
        self.operationID = operationID
        self.documentID = documentID
        self.revisionVersion = revisionVersion
        self.workspaceID = workspaceID
        self.accessGeneration = accessGeneration
        self.resourceID = resourceID
        self.relativePathUTF8 = relativePathUTF8
        self.fileURLPath = fileURLPath
        self.source = source
        self.baseline = baseline
        self.reason = reason
    }
}

public struct IOSRecoveryList: Sendable, Equatable {
    public var records: [IOSRecoveryRecord]
    public var corruptNames: [String]

    public init(records: [IOSRecoveryRecord], corruptNames: [String]) {
        self.records = records
        self.corruptNames = corruptNames
    }
}

public enum IOSRecoveryDiscardError: Error, Equatable {
    case missing
    case corrupt
    case contentNotConfirmed
    case newerLocalRevision
}

protocol IOSRecoveryPersisting: Sendable {
    func persist(_ record: IOSRecoveryRecord) async throws -> IOSRecoveryReceipt
    func list() async -> IOSRecoveryList
    func load(_ recordID: UUID) async throws -> IOSRecoveryRecord
    func discard(
        recordID: UUID,
        persistedText: String,
        liveText: String,
        liveVersion: Int
    ) async throws
}
