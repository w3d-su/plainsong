import Darwin
import Foundation

extension WorkspaceAnchoredFileSystem {
    static func rollbackExistingWrite(
        reason: WorkspaceAnchoredFileSystemError,
        displacedEntry: DirectoryEntryIdentity,
        context: ExistingWriteContext
    ) -> WorkspaceFileWriteOutcome {
        let prepared = context.commit.prepared
        let chain = context.commit.chain
        let parentDescriptor = context.commit.parentDescriptor
        let leaf = context.commit.leaf
        let hooks = context.commit.hooks
        guard isWriterOwnedOriginal(displacedEntry, context: context) else {
            return indeterminate(
                reason: reason,
                preparedMetadata: prepared.metadata,
                artifactState: .removalIndeterminate(prepared.location)
            )
        }

        hooks.emit(.willRollback)
        var didReverseSwap = false
        do {
            try chain.validateNamespace()
            try validateNameStillReferencesEntry(
                parentDescriptor: parentDescriptor,
                leaf: prepared.name,
                entry: displacedEntry
            )
            try validateNameStillReferencesDescriptor(
                parentDescriptor: parentDescriptor,
                leaf: leaf,
                metadata: prepared.metadata
            )
            try hooks.check(.renameRollback)
            try chain.validateNamespace()
            try validateNameStillReferencesEntry(
                parentDescriptor: parentDescriptor,
                leaf: prepared.name,
                entry: displacedEntry
            )
            try validateNameStillReferencesDescriptor(
                parentDescriptor: parentDescriptor,
                leaf: leaf,
                metadata: prepared.metadata
            )
            try chain.validateNamespace()
            // macOS cannot condition RENAME_SWAP on the two validated inode identities. This
            // hook is the final instrumented boundary; an injected race fails before the swap.
            // Production still has an honest residual last-check-to-syscall name race.
            try hooks.check(.renameRollbackAfterValidation)
            guard secureRename(
                parentDescriptor: parentDescriptor,
                from: prepared.name,
                to: leaf,
                flags: UInt32(RENAME_SWAP)
            ) == 0 else {
                throw WorkspaceAnchoredFileSystemError.unreadable
            }
            didReverseSwap = true
            hooks.emit(.didRollback)
            try chain.validateNamespace()
            try validateNameStillReferencesEntry(
                parentDescriptor: parentDescriptor,
                leaf: leaf,
                entry: displacedEntry
            )
            try chain.validateNamespace()
            try validateNameStillReferencesDescriptor(
                parentDescriptor: parentDescriptor,
                leaf: prepared.name,
                metadata: prepared.metadata
            )
            try chain.validateNamespace()
            try hooks.check(.syncRollbackDirectory)
            try syncDirectory(parentDescriptor)
            try chain.validateNamespace()
            try validateNameStillReferencesEntry(
                parentDescriptor: parentDescriptor,
                leaf: leaf,
                entry: displacedEntry
            )
            try chain.validateNamespace()
        } catch {
            let expectedArtifactIdentity = didReverseSwap
                ? prepared.metadata.identity
                : displacedEntry.identity
            return indeterminate(
                reason: normalizedError(error),
                preparedMetadata: prepared.metadata,
                artifactState: artifactState(
                    named: prepared.name,
                    location: prepared.location,
                    expectedIdentity: expectedArtifactIdentity,
                    context: context.commit.artifactRemovalContext
                )
            )
        }

        let artifactState = removeArtifact(
            named: prepared.name,
            location: prepared.location,
            expectedIdentity: prepared.metadata.identity,
            context: context.commit.artifactRemovalContext,
            unlinkCall: .cleanupTemporary
        )
        return notCommitted(reason: reason, artifactState: artifactState)
    }

    static func rollbackMissingWrite(
        reason: WorkspaceAnchoredFileSystemError,
        context: WriteCommitContext
    ) -> WorkspaceFileWriteOutcome {
        context.hooks.emit(.willRollback)
        guard let destinationLocation = context.prepared.location.sibling(named: context.leaf) else {
            return indeterminate(
                reason: .cleanupFailed,
                preparedMetadata: context.prepared.metadata,
                artifactState: .removalIndeterminate(context.prepared.location)
            )
        }
        let removal = removeArtifactResult(
            named: context.leaf,
            location: destinationLocation,
            expectedIdentity: context.prepared.metadata.identity,
            context: context.artifactRemovalContext,
            unlinkCall: .unlinkCreatedDestination,
            syncCall: .syncRollbackDirectory
        )
        if removal.state == .none {
            context.hooks.emit(.didRollback)
            return notCommitted(reason: reason, artifactState: .none)
        }
        return indeterminate(
            reason: removal.failureReason ?? .cleanupFailed,
            preparedMetadata: context.prepared.metadata,
            artifactState: removal.state
        )
    }

    static func finishDurableExistingWrite(
        displacedEntry: DirectoryEntryIdentity,
        context: ExistingWriteContext
    ) -> WorkspaceFileWriteOutcome {
        let prepared = context.commit.prepared
        let hooks = context.commit.hooks
        do {
            try validateExistingCommit(displacedEntry: displacedEntry, context: context)
        } catch {
            return rollbackExistingWrite(
                reason: normalizedError(error),
                displacedEntry: displacedEntry,
                context: context
            )
        }

        let cleanup = removeArtifactResult(
            named: prepared.name,
            location: prepared.location,
            expectedIdentity: displacedEntry.identity,
            context: context.commit.artifactRemovalContext,
            unlinkCall: .unlinkRollbackArtifact,
            syncCall: .syncCleanupDirectory
        )

        do {
            try validateCommittedDestination(context: context.commit)
            hooks.emit(.postflight)
            let finalMetadata = try finalCommittedMetadata(context: context.commit)
            return durable(metadata: finalMetadata, cleanupState: cleanup.state)
        } catch {
            return indeterminate(
                reason: normalizedError(error),
                preparedMetadata: prepared.metadata,
                artifactState: cleanup.state
            )
        }
    }

    static func validateExistingCommit(
        displacedEntry: DirectoryEntryIdentity,
        context: ExistingWriteContext
    ) throws {
        let commit = context.commit
        try commit.chain.validateNamespace()
        try validateNameStillReferencesDescriptor(
            parentDescriptor: commit.parentDescriptor,
            leaf: commit.leaf,
            metadata: commit.prepared.metadata
        )
        try validateNameStillReferencesEntry(
            parentDescriptor: commit.parentDescriptor,
            leaf: commit.prepared.name,
            entry: displacedEntry
        )
        try commit.chain.validateNamespace()
    }

    static func validateCommittedDestination(context: WriteCommitContext) throws {
        try context.chain.validateNamespace()
        try validateNameStillReferencesDescriptor(
            parentDescriptor: context.parentDescriptor,
            leaf: context.leaf,
            metadata: context.prepared.metadata
        )
        try context.chain.validateNamespace()
    }
}

extension WorkspaceAnchoredFileSystem {
    static func notCommitted(
        reason: WorkspaceAnchoredFileSystemError,
        artifactState: WorkspaceFileWriteArtifactState
    ) -> WorkspaceFileWriteOutcome {
        .notCommitted(WorkspaceNotCommittedFileWrite(
            reason: reason,
            artifactState: artifactState
        ))
    }

    static func durable(
        metadata: WorkspaceCoherentFileMetadata,
        cleanupState: WorkspaceFileWriteArtifactState
    ) -> WorkspaceFileWriteOutcome {
        .committedAndDurable(WorkspaceDurableFileWrite(
            metadata: metadata,
            cleanupState: cleanupState
        ))
    }

    static func indeterminate(
        reason: WorkspaceAnchoredFileSystemError,
        preparedMetadata: WorkspaceCoherentFileMetadata?,
        artifactState: WorkspaceFileWriteArtifactState
    ) -> WorkspaceFileWriteOutcome {
        .committedButIndeterminate(WorkspaceIndeterminateFileWrite(
            reason: reason,
            preparedMetadata: preparedMetadata,
            recoveryArtifact: artifactState
        ))
    }
}
