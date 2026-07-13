import Darwin
import Foundation

extension WorkspaceAnchoredFileSystem {
    static func write(
        _ data: Data,
        to location: WorkspaceFileSystemLocation,
        expecting expectation: WorkspaceNoFollowFileWriteExpectation,
        hooks: Hooks
    ) -> WorkspaceFileWriteOutcome {
        do {
            return try withAnchoredParent(at: location, hooks: hooks) { chain, parentDescriptor, leaf in
                try performWrite(
                    data,
                    to: location,
                    expectation: expectation,
                    chain: chain,
                    parentDescriptor: parentDescriptor,
                    leaf: leaf,
                    hooks: hooks
                )
            }
        } catch {
            return notCommitted(reason: normalizedError(error), artifactState: .none)
        }
    }

    private static func performWrite(
        _ data: Data,
        to location: WorkspaceFileSystemLocation,
        expectation: WorkspaceNoFollowFileWriteExpectation,
        chain: DirectoryDescriptorChain,
        parentDescriptor: Int32,
        leaf: String,
        hooks: Hooks
    ) throws -> WorkspaceFileWriteOutcome {
        let artifactRemovalContext = ArtifactRemovalContext(
            chain: chain,
            parentDescriptor: parentDescriptor,
            hooks: hooks
        )
        let target: WriteTarget
        do {
            target = try openWriteTarget(
                parentDescriptor: parentDescriptor,
                leaf: leaf,
                expectation: expectation
            )
        } catch {
            return notCommitted(reason: normalizedError(error), artifactState: .none)
        }
        defer { closeWriteTarget(target) }

        let prepared: PreparedWrite
        do {
            prepared = try prepareTemporaryWrite(
                data,
                target: target,
                location: location,
                parentDescriptor: parentDescriptor,
                hooks: hooks
            )
        } catch let error as TemporaryPreparationError {
            let artifactState = removeArtifact(
                named: error.name,
                location: error.location,
                expectedIdentity: error.expectedIdentity,
                context: artifactRemovalContext,
                unlinkCall: .cleanupTemporary
            )
            return notCommitted(reason: error.reason, artifactState: artifactState)
        } catch {
            return notCommitted(reason: normalizedError(error), artifactState: .none)
        }
        defer { Darwin.close(prepared.descriptor) }

        do {
            try chain.validateNamespace()
            hooks.emit(.namespaceValidated)
            try validatePreparedWrite(prepared, parentDescriptor: parentDescriptor)
            try revalidateTarget(
                target,
                parentDescriptor: parentDescriptor,
                leaf: leaf
            )
            try chain.validateNamespace()
            try checkCancellation()
        } catch {
            let artifactState = removeArtifact(
                named: prepared.name,
                location: prepared.location,
                expectedIdentity: prepared.metadata.identity,
                context: artifactRemovalContext,
                unlinkCall: .cleanupTemporary
            )
            return notCommitted(
                reason: normalizedError(error),
                artifactState: artifactState
            )
        }

        let commit = WriteCommitContext(
            prepared: prepared,
            chain: chain,
            parentDescriptor: parentDescriptor,
            leaf: leaf,
            hooks: hooks
        )
        switch target {
        case let .existing(descriptor, metadata, _, expectedDigest):
            return commitExistingWrite(ExistingWriteContext(
                originalDescriptor: descriptor,
                originalMetadata: metadata,
                expectedDigest: expectedDigest,
                commit: commit
            ))
        case .missing:
            return commitMissingWrite(commit)
        }
    }

    private static func commitExistingWrite(
        _ context: ExistingWriteContext
    ) -> WorkspaceFileWriteOutcome {
        let commit = context.commit
        do {
            try swapPreparedWrite(context)
        } catch {
            let artifactState = removeArtifact(
                named: commit.prepared.name,
                location: commit.prepared.location,
                expectedIdentity: commit.prepared.metadata.identity,
                context: commit.artifactRemovalContext,
                unlinkCall: .cleanupTemporary
            )
            return notCommitted(reason: normalizedError(error), artifactState: artifactState)
        }

        commit.hooks.emit(.didCommit(.swap))
        let afterRenameFailure = injectedError(from: commit.hooks, at: .afterRenameSwap)
        let displacedEntry: DirectoryEntryIdentity
        do {
            try commit.hooks.check(.captureDisplacedEntry)
            displacedEntry = try directoryEntryIdentity(
                parentDescriptor: commit.parentDescriptor,
                component: commit.prepared.name
            )
            try validateNameStillReferencesEntry(
                parentDescriptor: commit.parentDescriptor,
                leaf: commit.prepared.name,
                entry: displacedEntry
            )
            commit.hooks.emit(.displacedEntryCaptured)
        } catch {
            return indeterminate(
                reason: afterRenameFailure ?? normalizedError(error),
                preparedMetadata: commit.prepared.metadata,
                artifactState: .retained(commit.prepared.location)
            )
        }

        if let afterRenameFailure {
            return rollbackExistingWrite(
                reason: afterRenameFailure,
                displacedEntry: displacedEntry,
                context: context
            )
        }
        guard displacedEntry.isRegularFile,
              displacedEntry.identity == context.originalMetadata.identity
        else {
            return rollbackExistingWrite(
                reason: errorForUnexpectedDisplacedEntry(displacedEntry),
                displacedEntry: displacedEntry,
                context: context
            )
        }

        do {
            try validatePreparedContent(commit.prepared)
        } catch {
            return rollbackExistingWrite(
                reason: normalizedError(error),
                displacedEntry: displacedEntry,
                context: context
            )
        }

        do {
            try validateAndSyncCommittedExistingWrite(context, displacedEntry: displacedEntry)
        } catch {
            return rollbackExistingWrite(
                reason: normalizedError(error),
                displacedEntry: displacedEntry,
                context: context
            )
        }

        return finishDurableExistingWrite(
            displacedEntry: displacedEntry,
            context: context
        )
    }

    private static func commitMissingWrite(
        _ context: WriteCommitContext
    ) -> WorkspaceFileWriteOutcome {
        do {
            try validateMissingName(parentDescriptor: context.parentDescriptor, leaf: context.leaf)
            try context.chain.validateNamespace()
            try checkCancellation()
            context.hooks.emit(.willCommit(.exclusiveCreate))
            try context.hooks.check(.renameExclusive)
            try context.chain.validateNamespace()
            try validatePreparedWrite(
                context.prepared,
                parentDescriptor: context.parentDescriptor
            )
            try validateMissingName(
                parentDescriptor: context.parentDescriptor,
                leaf: context.leaf
            )
            guard secureRename(
                parentDescriptor: context.parentDescriptor,
                from: context.prepared.name,
                to: context.leaf,
                flags: UInt32(RENAME_EXCL)
            ) == 0 else {
                throw errno == EEXIST
                    ? WorkspaceAnchoredFileSystemError.changedIdentity
                    : WorkspaceAnchoredFileSystemError.unreadable
            }
        } catch {
            let artifactState = removeArtifact(
                named: context.prepared.name,
                location: context.prepared.location,
                expectedIdentity: context.prepared.metadata.identity,
                context: context.artifactRemovalContext,
                unlinkCall: .cleanupTemporary
            )
            return notCommitted(reason: normalizedError(error), artifactState: artifactState)
        }

        context.hooks.emit(.didCommit(.exclusiveCreate))
        do {
            try context.hooks.check(.afterRenameExclusive)
            try context.hooks.check(.validateCommittedLeaf)
            try validateCommittedLeaf(context)
            try validatePreparedContent(context.prepared)
            try context.hooks.check(.syncCommittedDirectory)
            try syncDirectory(context.parentDescriptor)
            try validateCommittedLeaf(context)
            try validatePreparedContent(context.prepared)
            context.hooks.emit(.postflight)
            let finalMetadata = try finalCommittedMetadata(context: context)
            return durable(metadata: finalMetadata, cleanupState: .none)
        } catch {
            return rollbackMissingWrite(
                reason: normalizedError(error),
                context: context
            )
        }
    }
}
