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
        let effect = await IOSCallerDeadline.awaitEffect(timeoutNanoseconds: timeout) {
            try await context.files.createFile(
                url: location.fileURL,
                relativePath: location.relativePath,
                data: data,
                root: context.rootURL
            )
        }
        if let abandon = effect.abandon {
            try await settleAbandonedCreate(
                effect.result,
                abandon: abandon,
                context: context,
                location: location,
                byteCount: data.count,
                operationID: operationID
            )
        }
        return try effect.result.get()
    }

    /// Settlement already has the caller. Wait for the delete instead of treating task cancellation as a handoff.
    func reclaimWaiting(_ leaf: IOSPersistedLeaf) async -> IOSReclaimSettlement {
        guard let identity = leaf.providerIdentity else { return .kept }
        let files = ports.files
        let operation = Task.detached {
            try await files.removeIfOwned(
                url: leaf.url,
                relativePath: leaf.relativePath,
                root: leaf.root,
                providerIdentity: identity
            )
        }
        switch await operation.result {
        case .success:
            return .removed
        case let .failure(error):
            if (error as? IOSWorkspaceFailure) == .notFound {
                return .removed
            }
            return .kept
        }
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

    func metadataForValidation(url: URL, relativePath: String, root: URL) async throws -> IOSWorkspaceFileItem {
        do {
            return try await boundedMetadata(url: url, relativePath: relativePath, root: root) { _ in }
        } catch let draining as IOSDrainingCoordinationFailure {
            try throwDraining(draining)
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
        let timeout = ports.coordinationTimeoutNanoseconds
        let files = ports.files
        do {
            try await IOSCallerDeadline.raceDrained(
                timeoutNanoseconds: timeout,
                onDrain: { [token = asset.ownershipToken] result in
                    if removalSucceeded(result) {
                        await self.markOwnedRemoved(token)
                    }
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
            await markOwnedRemoved(asset.ownershipToken)
            return .removed
        } catch let failure as IOSWorkspaceFailure where failure == .notFound {
            await markOwnedRemoved(asset.ownershipToken)
            return .removed
        } catch let draining as IOSDrainingCoordinationFailure {
            let reason: IOSWorkspaceFailure = draining.isCancellation ? .unavailable : .coordinationFailed
            return .retained(stagedReceipt(asset, reason: reason))
        } catch {
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

    private func settleAbandonedCreate(
        _ result: Result<IOSWorkspaceFileItem, Error>,
        abandon: IOSEffectAbandon,
        context: IOSDetachedAdmission,
        location: IOSFileLocation,
        byteCount: Int,
        operationID: UUID
    ) async throws -> Never {
        switch result {
        case let .success(item):
            let leaf = IOSPersistedLeaf(
                url: item.url,
                relativePath: location.relativePath,
                byteCount: byteCount,
                providerIdentity: item.providerIdentity,
                root: context.rootURL
            )
            await notePersisted(leaf, operationID: operationID)
            try await finishAbandonedLeaf(
                leaf,
                context: context,
                operationID: operationID,
                abandon: abandon,
                reason: abandonReason(abandon, persisted: nil)
            )
        case let .failure(error):
            if let persisted = error as? IOSFilePersistedButUnreadable {
                let leaf = persistedLeaf(persisted, root: context.rootURL)
                await notePersisted(leaf, operationID: operationID)
                try await finishAbandonedLeaf(
                    leaf,
                    context: context,
                    operationID: operationID,
                    abandon: abandon,
                    reason: abandonReason(abandon, persisted: persisted.reason)
                )
            }
            await finishWork(context.ticket)
            if abandon == .cancelled || error is CancellationError {
                throw IOSSettledWriteFailure(error: CancellationError())
            }
            throw IOSSettledWriteFailure(error: workspaceFailure(error) ?? .coordinationFailed)
        }
    }

    private func finishAbandonedLeaf(
        _ leaf: IOSPersistedLeaf,
        context: IOSDetachedAdmission,
        operationID: UUID,
        abandon: IOSEffectAbandon,
        reason: IOSWorkspaceFailure
    ) async throws -> Never {
        switch await reclaimWaiting(leaf) {
        case .removed:
            await clearPersisted(operationID)
            await finishWork(context.ticket)
            if abandon == .cancelled {
                throw IOSSettledWriteFailure(error: CancellationError())
            }
            throw IOSSettledWriteFailure(error: reason)
        case .kept:
            await clearPersisted(operationID)
            await finishWork(context.ticket)
            throw IOSSettledWriteFailure(
                error: unpublishedLeaf(leaf, context: context, operationID: operationID, reason: reason)
            )
        case .handedOff:
            throw IOSSettledWriteFailure(
                error: unpublishedLeaf(leaf, context: context, operationID: operationID, reason: reason)
            )
        }
    }

    private func abandonReason(
        _ abandon: IOSEffectAbandon,
        persisted: IOSWorkspaceFailure?
    ) -> IOSWorkspaceFailure {
        switch abandon {
        case .cancelled:
            .unavailable
        case .deadline:
            persisted ?? .coordinationFailed
        }
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
