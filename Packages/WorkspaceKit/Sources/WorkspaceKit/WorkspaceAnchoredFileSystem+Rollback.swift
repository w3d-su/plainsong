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
        hooks.emit(.willRollback)
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
            guard secureRename(
                parentDescriptor: parentDescriptor,
                from: prepared.name,
                to: leaf,
                flags: UInt32(RENAME_SWAP)
            ) == 0 else {
                throw WorkspaceAnchoredFileSystemError.unreadable
            }
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
            return indeterminate(
                reason: normalizedError(error),
                preparedMetadata: prepared.metadata,
                artifactState: .retained(prepared.location)
            )
        }

        let artifactState = removeArtifact(
            named: prepared.name,
            location: prepared.location,
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
        do {
            try context.chain.validateNamespace()
            try validateNameStillReferencesDescriptor(
                parentDescriptor: context.parentDescriptor,
                leaf: context.leaf,
                metadata: context.prepared.metadata
            )
            try context.hooks.check(.unlinkCreatedDestination)
            try context.chain.validateNamespace()
            try validateNameStillReferencesDescriptor(
                parentDescriptor: context.parentDescriptor,
                leaf: context.leaf,
                metadata: context.prepared.metadata
            )
            try context.chain.validateNamespace()
            guard unlink(parentDescriptor: context.parentDescriptor, name: context.leaf) == 0 else {
                throw WorkspaceAnchoredFileSystemError.cleanupFailed
            }
            context.hooks.emit(.didRollback)
            try context.chain.validateNamespace()
            try context.hooks.check(.syncRollbackDirectory)
            try syncDirectory(context.parentDescriptor)
            try context.chain.validateNamespace()
            try validateMissingName(parentDescriptor: context.parentDescriptor, leaf: context.leaf)
            try context.chain.validateNamespace()
            return notCommitted(reason: reason, artifactState: .none)
        } catch {
            return indeterminate(
                reason: normalizedError(error),
                preparedMetadata: context.prepared.metadata,
                artifactState: .none
            )
        }
    }

    static func finishDurableExistingWrite(
        displacedEntry: DirectoryEntryIdentity,
        context: ExistingWriteContext
    ) -> WorkspaceFileWriteOutcome {
        let prepared = context.commit.prepared
        let parentDescriptor = context.commit.parentDescriptor
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

        do {
            try hooks.check(.unlinkRollbackArtifact)
            try validateExistingCommit(displacedEntry: displacedEntry, context: context)
            guard unlink(parentDescriptor: parentDescriptor, name: prepared.name) == 0 else {
                throw WorkspaceAnchoredFileSystemError.cleanupFailed
            }
        } catch {
            do {
                try validateCommittedDestination(context: context.commit)
                hooks.emit(.postflight)
                try validateCommittedDestination(context: context.commit)
                return durable(
                    metadata: prepared.metadata,
                    cleanupState: .retained(prepared.location)
                )
            } catch {
                return rollbackExistingWrite(
                    reason: normalizedError(error),
                    displacedEntry: displacedEntry,
                    context: context
                )
            }
        }

        do {
            try hooks.check(.syncCleanupDirectory)
            try validateCommittedDestination(context: context.commit)
            try syncDirectory(parentDescriptor)
        } catch {
            do {
                try validateCommittedDestination(context: context.commit)
                hooks.emit(.postflight)
                try validateCommittedDestination(context: context.commit)
                return durable(
                    metadata: prepared.metadata,
                    cleanupState: .removalIndeterminate(prepared.location)
                )
            } catch {
                return indeterminate(
                    reason: normalizedError(error),
                    preparedMetadata: prepared.metadata,
                    artifactState: .removalIndeterminate(prepared.location)
                )
            }
        }

        do {
            try validateCommittedDestination(context: context.commit)
            hooks.emit(.postflight)
            try validateCommittedDestination(context: context.commit)
            return durable(metadata: prepared.metadata, cleanupState: .none)
        } catch {
            return indeterminate(
                reason: normalizedError(error),
                preparedMetadata: prepared.metadata,
                artifactState: .none
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

    static func removeArtifact(
        named name: String,
        location: WorkspaceFileSystemLocation,
        context: ArtifactRemovalContext,
        unlinkCall: InjectedCall
    ) -> WorkspaceFileWriteArtifactState {
        do {
            try context.chain.validateNamespace()
            try context.hooks.check(unlinkCall)
            try context.chain.validateNamespace()
            guard unlink(parentDescriptor: context.parentDescriptor, name: name) == 0 else {
                return .retained(location)
            }
        } catch {
            return .retained(location)
        }

        do {
            try context.chain.validateNamespace()
            try context.hooks.check(.syncCleanupDirectory)
            try syncDirectory(context.parentDescriptor)
            try context.chain.validateNamespace()
            return .none
        } catch {
            return .removalIndeterminate(location)
        }
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
