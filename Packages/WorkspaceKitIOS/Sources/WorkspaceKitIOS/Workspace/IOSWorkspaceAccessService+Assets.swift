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
        } catch let handoff as IOSStageLeaseHandoff {
            throw handoff.failure
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
        let root = await MainActor.run { ownedAssets[asset.ownershipToken]?.rootURL ?? asset.targetLocation.fileURL }
        let item = try await metadataForValidation(
            url: asset.targetLocation.fileURL,
            relativePath: asset.targetLocation.relativePath,
            root: root,
            workspaceID: asset.targetLocation.workspaceID
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
        case let .delete(relativePath, url, root, identity):
            guard let identity else {
                return .retained(receipt(asset, reason: .indeterminate))
            }
            return await removeOwnedLeaf(
                asset: asset,
                relativePath: relativePath,
                url: url,
                root: root,
                identity: identity
            )
        }
    }
}

private enum IOSAssetRollbackDecision: Sendable {
    case delete(relativePath: String, url: URL, root: URL, identity: Data?)
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
        let written: (leaf: IOSCreatedLeaf, markdownRelative: String)
        do {
            written = try await createAssetLeaf(request, grant: grant, lease: lease, paths: paths)
        } catch let unpublished as IOSUnpublishedLeaf {
            throw IOSAssetStageFailure.retained(receipt(unpublished))
        }
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
                rootURL: grant.rootURL,
                providerIdentity: written.leaf.location.resourceID?.rawValue,
                byteCount: request.bytes.count
            )
        }
        do {
            try Task.checkCancellation()
            let item = try await confirmStagedMetadata(asset: asset, root: grant.rootURL, lease: lease)
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
        } catch let handoff as IOSStageLeaseHandoff {
            throw handoff
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
                exists: { _ in false },
                assetFolder: assetDirectoryName
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
                    exists: { $0 == paths.rootRelative },
                    assetFolder: assetDirectoryName
                )
            }
            guard let retry, retry.rootRelative != paths.rootRelative else {
                throw IOSAssetStageFailure.failed(.alreadyExists)
            }
            let leaf = try await createLeaf(request, grant: grant, lease: lease, rootRelative: retry.rootRelative)
            return (leaf, retry.markdownRelative)
        } catch let unpublished as IOSUnpublishedLeaf {
            throw unpublished
        } catch is CancellationError {
            throw CancellationError()
        } catch let failure as IOSAssetStageFailure {
            throw failure
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
        return .delete(
            relativePath: owned.rootRelative,
            url: owned.url,
            root: owned.rootURL,
            identity: owned.providerIdentity
        )
    }

    func markRemoved(_ token: UUID) async {
        await MainActor.run { self.markOwnedRemoved(token) }
    }

    func receipt(_ unpublished: IOSUnpublishedLeaf) -> IOSAssetRecoveryReceipt {
        IOSAssetRecoveryReceipt(
            operationID: unpublished.operationID,
            targetLocation: IOSFileLocation(
                workspaceID: unpublished.workspaceID,
                accessGeneration: unpublished.generation,
                relativePath: unpublished.relativePath,
                fileURL: unpublished.url,
                resourceID: unpublished.providerIdentity.map { IOSWorkspaceResourceIdentity(rawValue: $0) }
            ),
            ownershipToken: UUID(),
            reason: unpublished.reason
        )
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
}
