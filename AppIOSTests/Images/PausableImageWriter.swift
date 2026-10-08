import Foundation
@testable import PlainsongIOS
import WorkspaceCore
import WorkspaceKitIOS

/// Same frozen `IOSWorkspaceAssetWriting` surface as lane 06. Barriers replace sleeps.
final class PausableImageWriter: IOSWorkspaceAssetWriting, @unchecked Sendable {
    private let lock = NSLock()
    private let probe: InsertionProbe
    private var callList: [String] = []
    private var stagedRequestsStorage: [IOSImageAssetRequest] = []
    private var commitCounter = 0
    private var rollbackCounter = 0
    private var removed: [UUID] = []
    private var stagedOperationID: UUID?

    var pauseStage = false
    var pauseValidate = false
    let stageEntered = AsyncSignal()
    let stageRelease = AsyncSignal()
    let validateEntered = AsyncSignal()
    let validateRelease = AsyncSignal()
    var stageFailure: Error?
    var validateFailure: Error?
    var relativePath = "assets/photo-2.png"
    var rootRelativePath = "notes/assets/photo-2.png"
    var workspaceOverride: IOSWorkspaceIdentity?
    var generationOverride: UInt64?
    var operationIDOverride: UUID?
    var forceRetainRollback = false
    var forceRetainCommit = false
    var retainReason: IOSWorkspaceFailure = .indeterminate
    let ownershipToken = UUID()
    let ownedIdentity = Data("owned-leaf".utf8)

    init(probe: InsertionProbe) {
        self.probe = probe
    }

    var calls: [String] {
        lock.lock()
        defer { lock.unlock() }
        return callList
    }

    var stagedRequests: [IOSImageAssetRequest] {
        lock.lock()
        defer { lock.unlock() }
        return stagedRequestsStorage
    }

    var commitCount: Int {
        value { commitCounter }
    }

    var rollbackCount: Int {
        value { rollbackCounter }
    }

    var removedTokens: [UUID] {
        value { removed }
    }

    func stage(_ request: IOSImageAssetRequest, grant _: IOSWorkspaceGrant) async throws -> IOSStagedImageAsset {
        record("stage")
        lock.lock()
        stagedRequestsStorage.append(request)
        stagedOperationID = request.operationID
        let failure = stageFailure
        lock.unlock()
        if pauseStage {
            stageEntered.signal()
            await stageRelease.wait()
        }
        if let failure {
            throw failure
        }
        return asset(for: request)
    }

    func validate(_ asset: IOSStagedImageAsset) async throws {
        record("validate")
        _ = asset
        if pauseValidate {
            validateEntered.signal()
            await validateRelease.wait()
        }
        if let validateFailure {
            throw validateFailure
        }
    }

    func commit(_ asset: IOSStagedImageAsset) async -> IOSAssetCommitOutcome {
        record("commit")
        lock.lock()
        commitCounter += 1
        let retain = forceRetainCommit
        lock.unlock()
        if retain {
            return .retained(receipt(asset, reason: retainReason))
        }
        return .committed
    }

    func rollback(_ asset: IOSStagedImageAsset) async -> IOSAssetRollbackOutcome {
        record("rollback")
        lock.lock()
        rollbackCounter += 1
        let retain = forceRetainRollback || asset.operationID != stagedOperationID
        if !retain {
            removed.append(asset.ownershipToken)
        }
        lock.unlock()
        if retain {
            return .retained(receipt(asset, reason: retainReason))
        }
        return .removed
    }

    private func asset(for request: IOSImageAssetRequest) -> IOSStagedImageAsset {
        lock.lock()
        let workspace = workspaceOverride ?? request.destination.workspaceID
        let generation = generationOverride ?? request.destination.accessGeneration
        let operationID = operationIDOverride ?? request.operationID
        let path = relativePath
        let rootPath = rootRelativePath
        let token = ownershipToken
        let identity = ownedIdentity
        lock.unlock()
        let location = IOSFileLocation(
            workspaceID: workspace,
            accessGeneration: generation,
            relativePath: rootPath,
            fileURL: URL(fileURLWithPath: "/staged/leaf.png"),
            resourceID: IOSWorkspaceResourceIdentity(rawValue: identity)
        )
        return IOSStagedImageAsset(
            operationID: operationID,
            targetLocation: location,
            relativePath: path,
            ownedFileIdentity: IOSWorkspaceResourceIdentity(rawValue: identity),
            ownershipToken: token
        )
    }

    private func receipt(_ asset: IOSStagedImageAsset, reason: IOSWorkspaceFailure) -> IOSAssetRecoveryReceipt {
        IOSAssetRecoveryReceipt(
            operationID: asset.operationID,
            targetLocation: asset.targetLocation,
            ownershipToken: asset.ownershipToken,
            reason: reason
        )
    }

    private func record(_ event: String) {
        probe.record(event)
        lock.lock()
        callList.append(event)
        lock.unlock()
    }

    private func value<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
