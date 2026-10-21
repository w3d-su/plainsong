import Foundation
import WorkspaceCore

public struct IOSImageAssetRequest: Sendable {
    public let operationID: UUID
    public let bytes: Data
    public let contentType: String
    public let preferredFilename: String
    /// The Markdown document location; 06 persists assets relative to its parent.
    public let destination: IOSFileLocation

    public init(
        operationID: UUID,
        bytes: Data,
        contentType: String,
        preferredFilename: String,
        destination: IOSFileLocation
    ) {
        self.operationID = operationID
        self.bytes = bytes
        self.contentType = contentType
        self.preferredFilename = preferredFilename
        self.destination = destination
    }
}

/// stage has already persisted this final image leaf before returning its path.
/// The opaque token and resource identity prove operation-owned terminal cleanup.
public struct IOSStagedImageAsset: Sendable {
    public let operationID: UUID
    public let targetLocation: IOSFileLocation
    /// Document-parent-relative Markdown path; targetLocation is root-relative.
    public let relativePath: String
    public let ownedFileIdentity: IOSWorkspaceResourceIdentity
    public let ownershipToken: UUID

    public var accessGeneration: UInt64 {
        targetLocation.accessGeneration
    }

    public init(
        operationID: UUID,
        targetLocation: IOSFileLocation,
        relativePath: String,
        ownedFileIdentity: IOSWorkspaceResourceIdentity,
        ownershipToken: UUID
    ) {
        self.operationID = operationID
        self.targetLocation = targetLocation
        self.relativePath = relativePath
        self.ownedFileIdentity = ownedFileIdentity
        self.ownershipToken = ownershipToken
    }
}

public struct IOSAssetRecoveryReceipt: Sendable {
    public let operationID: UUID
    public let targetLocation: IOSFileLocation
    public let ownershipToken: UUID
    public let reason: IOSWorkspaceFailure

    public init(
        operationID: UUID,
        targetLocation: IOSFileLocation,
        ownershipToken: UUID,
        reason: IOSWorkspaceFailure
    ) {
        self.operationID = operationID
        self.targetLocation = targetLocation
        self.ownershipToken = ownershipToken
        self.reason = reason
    }
}

/// A failed/cancelled stage with possible persisted bytes must retain a receipt.
/// CancellationError is legal only when no operation-owned leaf remains.
public enum IOSAssetStageFailure: Error, Sendable {
    case failed(IOSWorkspaceFailure)
    case retained(IOSAssetRecoveryReceipt)
}

public enum IOSAssetCommitOutcome: Sendable {
    case committed
    case retained(IOSAssetRecoveryReceipt)
}

public enum IOSAssetRollbackOutcome: Sendable {
    case removed
    case retained(IOSAssetRecoveryReceipt)
}

/// Implemented by 06. stage throws IOSAssetStageFailure or CancellationError; validate throws IOSWorkspaceFailure or
/// CancellationError.
/// Terminal actions are idempotent and safe-drain even when the caller is cancelled.
/// commit transfers ownership after accepted source insertion; it cannot publish later.
/// rollback removes only a still-proven operation-owned leaf, otherwise retains it.
public protocol IOSWorkspaceAssetWriting: Sendable {
    func stage(_ request: IOSImageAssetRequest, grant: IOSWorkspaceGrant) async throws -> IOSStagedImageAsset
    func validate(_ asset: IOSStagedImageAsset) async throws
    func commit(_ asset: IOSStagedImageAsset) async -> IOSAssetCommitOutcome
    func rollback(_ asset: IOSStagedImageAsset) async -> IOSAssetRollbackOutcome
}
