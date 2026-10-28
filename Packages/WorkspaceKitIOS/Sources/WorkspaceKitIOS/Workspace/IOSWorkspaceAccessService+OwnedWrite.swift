import Foundation
import WorkspaceCore

enum IOSReclaimSettlement: Sendable {
    case removed
    case kept
    /// The caller already has a receipt. `finish` runs when the port returns.
    case handedOff
}

extension IOSWorkspaceAccessService {
    func ownedCreateFile(
        context: IOSDetachedAdmission,
        location: IOSFileLocation,
        data: Data,
        operationID: UUID
    ) async throws -> IOSWorkspaceFileItem {
        let timeout = ports.coordinationTimeoutNanoseconds
        return try await IOSCallerDeadline.raceDrained(
            timeoutNanoseconds: timeout,
            onDrain: { result in
                await self.settleLateCreate(
                    result,
                    context: context,
                    location: location,
                    byteCount: data.count,
                    operationID: operationID
                )
            },
            body: {
                try await context.files.createFile(
                    url: location.fileURL,
                    relativePath: location.relativePath,
                    data: data,
                    root: context.rootURL
                )
            }
        )
    }

    func reclaimBounded(
        _ leaf: IOSPersistedLeaf,
        ticket: IOSOperationTicket
    ) async -> IOSReclaimSettlement {
        guard let identity = leaf.providerIdentity else { return .kept }
        let timeout = ports.coordinationTimeoutNanoseconds
        let files = ports.files
        do {
            try await IOSCallerDeadline.raceDrained(
                timeoutNanoseconds: timeout,
                onDrain: { result in
                    await self.finishReclaim(ticket, result: result)
                },
                body: {
                    try await files.removeIfOwned(
                        url: leaf.url,
                        relativePath: leaf.relativePath,
                        root: leaf.root,
                        providerIdentity: identity
                    )
                }
            )
            return .removed
        } catch let failure as IOSWorkspaceFailure where failure == .notFound {
            return .removed
        } catch is IOSDrainingCoordinationFailure {
            return .handedOff
        } catch {
            return .kept
        }
    }

    func metadataForAdopt(
        url: URL,
        relativePath: String,
        admission: IOSScopeAdmission
    ) async throws -> IOSWorkspaceFileItem {
        try await boundedMetadata(url: url, relativePath: relativePath, root: url) { _ in
            await self.endStartedScope(url, admission: admission)
        }
    }

    func metadataForValidation(
        url: URL,
        relativePath: String,
        root: URL,
        workspaceID: IOSWorkspaceIdentity
    ) async throws -> IOSWorkspaceFileItem {
        let ticket = retainOperation(workspaceID: workspaceID)
        do {
            let item = try await boundedMetadata(url: url, relativePath: relativePath, root: root) { _ in
                await self.finishHeld(ticket)
            }
            await finishHeld(ticket)
            return item
        } catch let draining as IOSDrainingCoordinationFailure {
            try throwDraining(draining)
        } catch {
            await finishHeld(ticket)
            throw error
        }
    }

    func confirmStagedMetadata(
        asset: IOSStagedImageAsset,
        root: URL,
        lease: IOSRetainedAccessLease
    ) async throws -> IOSWorkspaceFileItem {
        do {
            return try await boundedMetadata(
                url: asset.targetLocation.fileURL,
                relativePath: asset.targetLocation.relativePath,
                root: root
            ) { _ in
                // Rollback can return while its remove is still parked. The remove holds its own ticket.
                _ = await self.rollback(asset)
                await MainActor.run { lease.release() }
            }
        } catch let draining as IOSDrainingCoordinationFailure {
            let reason: IOSWorkspaceFailure = draining.isCancellation ? .unavailable : .coordinationFailed
            throw IOSStageLeaseHandoff(failure: .retained(stagedReceipt(asset, reason: reason)))
        }
    }

    func removeOwnedLeaf(
        asset: IOSStagedImageAsset,
        relativePath: String,
        url: URL,
        root: URL,
        identity: Data
    ) async -> IOSAssetRollbackOutcome {
        let ticket = retainOperation(workspaceID: asset.targetLocation.workspaceID)
        let timeout = ports.coordinationTimeoutNanoseconds
        let files = ports.files
        do {
            try await IOSCallerDeadline.raceDrained(
                timeoutNanoseconds: timeout,
                onDrain: { [token = asset.ownershipToken] result in
                    if removalSucceeded(result) {
                        await self.markOwnedRemoved(token)
                    }
                    await self.finishHeld(ticket)
                },
                body: {
                    try await files.removeIfOwned(
                        url: url,
                        relativePath: relativePath,
                        root: root,
                        providerIdentity: identity
                    )
                }
            )
            markOwnedRemoved(asset.ownershipToken)
            await finishHeld(ticket)
            return .removed
        } catch let failure as IOSWorkspaceFailure where failure == .notFound {
            markOwnedRemoved(asset.ownershipToken)
            await finishHeld(ticket)
            return .removed
        } catch let draining as IOSDrainingCoordinationFailure {
            let reason: IOSWorkspaceFailure = draining.isCancellation ? .unavailable : .coordinationFailed
            return .retained(stagedReceipt(asset, reason: reason))
        } catch {
            await finishHeld(ticket)
            return .retained(stagedReceipt(asset, reason: IOSWorkspaceFailureMapping.map(error)))
        }
    }

    func markOwnedRemoved(_ token: UUID) {
        if var owned = ownedAssets[token] {
            owned.removed = true
            ownedAssets[token] = owned
        }
    }

    func unpublishedLeaf(
        _ leaf: IOSPersistedLeaf,
        context: IOSDetachedAdmission,
        operationID: UUID,
        reason: IOSWorkspaceFailure
    ) -> IOSUnpublishedLeaf {
        IOSUnpublishedLeaf(
            operationID: operationID,
            workspaceID: context.ticket.workspaceID,
            generation: context.ticket.generation,
            relativePath: leaf.relativePath,
            url: leaf.url,
            providerIdentity: leaf.providerIdentity,
            byteCount: leaf.byteCount,
            reason: reason
        )
    }

    /// The caller already holds a receipt. This waits for the create, then for a proved remove.
    /// It does not use another deadline race: that race would treat this cancelled drain as finished.
    private func settleLateCreate(
        _ result: Result<IOSWorkspaceFileItem, Error>,
        context: IOSDetachedAdmission,
        location: IOSFileLocation,
        byteCount: Int,
        operationID: UUID
    ) async {
        let leaf: IOSPersistedLeaf
        switch result {
        case let .success(item):
            leaf = IOSPersistedLeaf(
                url: item.url,
                relativePath: location.relativePath,
                byteCount: byteCount,
                providerIdentity: item.providerIdentity,
                root: context.rootURL
            )
        case let .failure(error as IOSFilePersistedButUnreadable):
            leaf = persistedLeaf(error, root: context.rootURL)
        default:
            await finishWork(context.ticket)
            return
        }
        await notePersisted(leaf, operationID: operationID)
        if let identity = leaf.providerIdentity {
            do {
                try await context.files.removeIfOwned(
                    url: leaf.url,
                    relativePath: leaf.relativePath,
                    root: leaf.root,
                    providerIdentity: identity
                )
            } catch {
                // The port has returned. A missing file is clean; any other error keeps the receipt.
                _ = error
            }
        }
        await clearPersisted(operationID)
        await finishWork(context.ticket)
    }

    private func finishHeld(_ ticket: IOSOperationTicket?) async {
        guard let ticket else { return }
        await finishWork(ticket)
    }

    private func finishReclaim(_ ticket: IOSOperationTicket, result: Result<Void, Error>) async {
        _ = result
        await clearPersisted(ticket.operationID)
        await finishWork(ticket)
    }

    private func endStartedScope(_ url: URL, admission: IOSScopeAdmission) {
        guard admission == .started else { return }
        ports.scope.end(url: url)
    }

    private func boundedMetadata(
        url: URL,
        relativePath: String,
        root: URL,
        onDrain: @escaping @Sendable (Result<IOSWorkspaceFileItem, Error>) async -> Void
    ) async throws -> IOSWorkspaceFileItem {
        let timeout = ports.coordinationTimeoutNanoseconds
        let files = ports.files
        return try await IOSCallerDeadline.raceDrained(
            timeoutNanoseconds: timeout,
            onDrain: onDrain,
            body: {
                try await files.metadata(url: url, relativePath: relativePath, root: root)
            }
        )
    }

    private func stagedReceipt(
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

private func removalSucceeded(_ result: Result<Void, Error>) -> Bool {
    switch result {
    case .success:
        true
    case let .failure(error):
        (error as? IOSWorkspaceFailure) == .notFound
    }
}
