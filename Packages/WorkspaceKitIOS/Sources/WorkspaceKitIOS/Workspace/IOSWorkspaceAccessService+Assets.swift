import Foundation
import WorkspaceCore

extension IOSWorkspaceAccessService: IOSWorkspaceAssetWriting {
    public nonisolated func stage(
        _ request: IOSImageAssetRequest,
        grant: IOSWorkspaceGrant
    ) async throws -> IOSStagedImageAsset {
        try Task.checkCancellation()
        // LANE06_GUARD_DIRECTORY_GRANT
        guard grant.scope == .directory else {
            throw IOSAssetStageFailure.failed(.requiresDirectoryGrant)
        }
        let lease = try await leaseForStage(grant)
        let ownershipToken = UUID()
        do {
            let asset = try await writeAsset(request, grant: grant, lease: lease, ownershipToken: ownershipToken)
            await MainActor.run { lease.release() }
            return asset
        } catch let failure as IOSAssetStageFailure {
            await MainActor.run { lease.release() }
            throw failure
        } catch is CancellationError {
            let retained = await cleanupCancelledStage(request, token: ownershipToken, grant: grant, lease: lease)
            await MainActor.run { lease.release() }
            if let retained {
                throw IOSAssetStageFailure.retained(retained)
            }
            throw CancellationError()
        } catch {
            await MainActor.run { lease.release() }
            throw IOSAssetStageFailure.failed(IOSWorkspaceFailureMapping.map(error))
        }
    }

    public nonisolated func validate(_ asset: IOSStagedImageAsset) async throws {
        try Task.checkCancellation()
        let record = try await requireOwned(asset)
        let files = await filePort()
        let item = try await files.metadata(
            url: asset.targetLocation.fileURL,
            relativePath: asset.targetLocation.relativePath
        )
        guard !item.isSymlink, !item.isDirectory else { throw IOSWorkspaceFailure.invalidPath }
        if let identity = item.providerIdentity, identity != asset.ownedFileIdentity.rawValue {
            throw IOSWorkspaceFailure.indeterminate
        }
        _ = record
    }

    public nonisolated func commit(_ asset: IOSStagedImageAsset) async -> IOSAssetCommitOutcome {
        await MainActor.run {
            guard var owned = ownedAssets[asset.ownershipToken], owned.operationID == asset.operationID else {
                return .retained(receipt(asset, reason: .indeterminate))
            }
            if owned.removed {
                return .retained(receipt(asset, reason: .notFound))
            }
            owned.committed = true
            ownedAssets[asset.ownershipToken] = owned
            return .committed
        }
    }

    public nonisolated func rollback(_ asset: IOSStagedImageAsset) async -> IOSAssetRollbackOutcome {
        let decision = await MainActor.run { rollbackDecision(asset) }
        switch decision {
        case let .keep(reason):
            return .retained(receipt(asset, reason: reason))
        case .alreadyRemoved:
            return .removed
        case let .delete(relativePath, url):
            let files = await filePort()
            do {
                let item = try await files.metadata(url: url, relativePath: relativePath)
                if item.isSymlink || item.isDirectory {
                    return .retained(receipt(asset, reason: .indeterminate))
                }
                if let identity = item.providerIdentity, identity != asset.ownedFileIdentity.rawValue {
                    return .retained(receipt(asset, reason: .indeterminate))
                }
                let ownedSize = await MainActor.run { ownedAssets[asset.ownershipToken]?.byteCount }
                if item.providerIdentity == nil, item.fileSize == nil || item.fileSize != ownedSize {
                    return .retained(receipt(asset, reason: .indeterminate))
                }
                try await files.removeFile(url: url, relativePath: relativePath)
                await MainActor.run {
                    if var owned = ownedAssets[asset.ownershipToken] {
                        owned.removed = true
                        ownedAssets[asset.ownershipToken] = owned
                    }
                }
                return .removed
            } catch let failure as IOSWorkspaceFailure where failure == .notFound {
                await MainActor.run {
                    if var owned = ownedAssets[asset.ownershipToken] {
                        owned.removed = true
                        ownedAssets[asset.ownershipToken] = owned
                    }
                }
                return .removed
            } catch {
                return .retained(receipt(asset, reason: IOSWorkspaceFailureMapping.map(error)))
            }
        }
    }
}

private enum IOSAssetRollbackDecision: Sendable {
    case delete(relativePath: String, url: URL)
    case alreadyRemoved
    case keep(IOSWorkspaceFailure)
}

private extension IOSWorkspaceAccessService {
    func leaseForStage(_ grant: IOSWorkspaceGrant) async throws -> IOSRetainedAccessLease {
        let lease = try acquireLease(for: grant)
        guard let retained = lease as? IOSRetainedAccessLease else {
            lease.release()
            throw IOSAssetStageFailure.failed(.permissionDenied)
        }
        return retained
    }

    func writeAsset(
        _ request: IOSImageAssetRequest,
        grant: IOSWorkspaceGrant,
        lease: IOSRetainedAccessLease,
        ownershipToken: UUID
    ) async throws -> IOSStagedImageAsset {
        guard request.destination.workspaceID == grant.workspaceID,
              request.destination.accessGeneration == grant.accessGeneration
        else {
            throw IOSAssetStageFailure.failed(.grantChanged)
        }
        guard let paths = await plannedPaths(request) else {
            throw IOSAssetStageFailure.failed(.invalidPath)
        }
        let written = try await createAssetLeaf(request, grant: grant, lease: lease, paths: paths)
        let asset = IOSStagedImageAsset(
            operationID: request.operationID,
            targetLocation: written.leaf.location,
            relativePath: written.markdownRelative,
            ownedFileIdentity: written.leaf.resourceID,
            ownershipToken: ownershipToken
        )
        await MainActor.run {
            ownedAssets[ownershipToken] = IOSOwnedAssetRecord(
                operationID: request.operationID,
                ownershipToken: ownershipToken,
                rootRelative: written.leaf.location.relativePath,
                url: written.leaf.location.fileURL,
                providerIdentity: written.leaf.location.resourceID?.rawValue,
                byteCount: request.bytes.count
            )
        }
        do {
            try Task.checkCancellation()
            let files = await filePort()
            let item = try await files.metadata(
                url: written.leaf.location.fileURL,
                relativePath: written.leaf.location.relativePath
            )
            guard !item.isSymlink, !item.isDirectory else { throw IOSWorkspaceFailure.invalidPath }
            if let identity = item.providerIdentity, identity != written.leaf.resourceID.rawValue {
                throw IOSWorkspaceFailure.indeterminate
            }
            if let size = item.fileSize, size != request.bytes.count {
                throw IOSWorkspaceFailure.indeterminate
            }
            await MainActor.run {
                if var owned = ownedAssets[ownershipToken] {
                    owned.providerIdentity = item.providerIdentity
                    ownedAssets[ownershipToken] = owned
                }
            }
            return asset
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            switch await rollback(asset) {
            case .removed:
                throw IOSAssetStageFailure.failed(IOSWorkspaceFailureMapping.map(error))
            case let .retained(receipt):
                throw IOSAssetStageFailure.retained(receipt)
            }
        }
    }

    func plannedPaths(
        _ request: IOSImageAssetRequest
    ) async -> (rootRelative: String, markdownRelative: String)? {
        await MainActor.run {
            IOSWorkspacePathAuthority.uniquedAssetPaths(
                documentRelativePath: request.destination.relativePath,
                preferredFilename: request.preferredFilename,
                operationID: request.operationID,
                exists: { _ in false }
            )
        }
    }

    func createAssetLeaf(
        _ request: IOSImageAssetRequest,
        grant: IOSWorkspaceGrant,
        lease: IOSRetainedAccessLease,
        paths: (rootRelative: String, markdownRelative: String)
    ) async throws -> (leaf: IOSCreatedLeaf, markdownRelative: String) {
        do {
            let leaf = try await createLeaf(request, grant: grant, lease: lease, rootRelative: paths.rootRelative)
            return (leaf, paths.markdownRelative)
        } catch let failure as IOSWorkspaceFailure where failure == .alreadyExists {
            let retry = await MainActor.run {
                IOSWorkspacePathAuthority.uniquedAssetPaths(
                    documentRelativePath: request.destination.relativePath,
                    preferredFilename: request.preferredFilename,
                    operationID: request.operationID,
                    exists: { $0 == paths.rootRelative }
                )
            }
            guard let retry, retry.rootRelative != paths.rootRelative else {
                throw IOSAssetStageFailure.failed(.alreadyExists)
            }
            let leaf = try await createLeaf(request, grant: grant, lease: lease, rootRelative: retry.rootRelative)
            return (leaf, retry.markdownRelative)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw IOSAssetStageFailure.failed(IOSWorkspaceFailureMapping.map(error))
        }
    }

    func createLeaf(
        _ request: IOSImageAssetRequest,
        grant: IOSWorkspaceGrant,
        lease: IOSRetainedAccessLease,
        rootRelative: String
    ) async throws -> IOSCreatedLeaf {
        let fileURL = await MainActor.run { () -> URL in
            guard let record = records[grant.workspaceID] else { return grant.rootURL }
            return self.fileURL(record: record, relativePath: rootRelative)
        }
        let location = IOSFileLocation(
            workspaceID: grant.workspaceID,
            accessGeneration: grant.accessGeneration,
            relativePath: rootRelative,
            fileURL: fileURL,
            resourceID: nil
        )
        return try await createNewLeaf(
            at: location,
            data: request.bytes,
            lease: lease,
            operationID: request.operationID
        )
    }

    func cleanupCancelledStage(
        _ request: IOSImageAssetRequest,
        token: UUID,
        grant: IOSWorkspaceGrant,
        lease: IOSRetainedAccessLease
    ) async -> IOSAssetRecoveryReceipt? {
        let owned = await MainActor.run { ownedAssets[token] }
        guard let owned else { return nil }
        let asset = IOSStagedImageAsset(
            operationID: request.operationID,
            targetLocation: IOSFileLocation(
                workspaceID: grant.workspaceID,
                accessGeneration: grant.accessGeneration,
                relativePath: owned.rootRelative,
                fileURL: owned.url,
                resourceID: owned.providerIdentity.map { IOSWorkspaceResourceIdentity(rawValue: $0) }
            ),
            relativePath: owned.rootRelative,
            ownedFileIdentity: IOSWorkspaceResourceIdentity(rawValue: owned.providerIdentity ?? Data()),
            ownershipToken: token
        )
        _ = lease
        switch await rollback(asset) {
        case .removed:
            return nil
        case let .retained(receipt):
            return receipt
        }
    }

    func requireOwned(_ asset: IOSStagedImageAsset) async throws -> IOSOwnedAssetRecord {
        try await MainActor.run {
            guard let owned = ownedAssets[asset.ownershipToken], owned.operationID == asset.operationID else {
                throw IOSWorkspaceFailure.indeterminate
            }
            guard !owned.removed else { throw IOSWorkspaceFailure.notFound }
            guard owned.rootRelative == asset.targetLocation.relativePath else {
                throw IOSWorkspaceFailure.indeterminate
            }
            return owned
        }
    }

    func rollbackDecision(_ asset: IOSStagedImageAsset) -> IOSAssetRollbackDecision {
        guard let owned = ownedAssets[asset.ownershipToken], owned.operationID == asset.operationID else {
            return .keep(.indeterminate)
        }
        if owned.committed {
            return .keep(.indeterminate)
        }
        if owned.removed {
            return .alreadyRemoved
        }
        if owned.rootRelative != asset.targetLocation.relativePath {
            return .keep(.indeterminate)
        }
        return .delete(relativePath: owned.rootRelative, url: owned.url)
    }

    nonisolated func receipt(
        _ asset: IOSStagedImageAsset,
        reason: IOSWorkspaceFailure
    ) -> IOSAssetRecoveryReceipt {
        IOSAssetRecoveryReceipt(
            operationID: asset.operationID,
            targetLocation: asset.targetLocation,
            ownershipToken: asset.ownershipToken,
            reason: reason
        )
    }

    func filePort() -> any IOSWorkspaceFilePort {
        ports.files
    }
}
