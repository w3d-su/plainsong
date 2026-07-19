import Darwin
import Foundation

extension WorkspaceAnchoredFileSystem {
    struct TemporaryPreparationError: Error {
        let reason: WorkspaceAnchoredFileSystemError
        let name: String
        let location: WorkspaceFileSystemLocation
        let descriptor: Int32
        let expectedIdentity: WorkspaceFileSystemIdentity?
        let expectedByteCount: Int64
        let expectedSHA256Digest: String
    }

    enum ArtifactIdentityObservation {
        case matchesExpected
        case missingOrDifferent
        case inspectionFailed(WorkspaceAnchoredFileSystemError)
    }

    struct PreparedRecoveryMaterial {
        let descriptor: Int32
        let expectedIdentity: WorkspaceFileSystemIdentity?
        let expectedByteCount: Int64
        let expectedSHA256Digest: String

        init(_ prepared: PreparedWrite) {
            descriptor = prepared.descriptor
            expectedIdentity = prepared.metadata.identity
            expectedByteCount = prepared.expectedByteCount
            expectedSHA256Digest = prepared.expectedSHA256Digest
        }

        init(_ error: TemporaryPreparationError) {
            descriptor = error.descriptor
            expectedIdentity = error.expectedIdentity
            expectedByteCount = error.expectedByteCount
            expectedSHA256Digest = error.expectedSHA256Digest
        }
    }

    enum PostCleanupDestinationExpectation {
        case existing(descriptor: Int32, metadata: WorkspaceCoherentFileMetadata)
        case missing
    }

    struct PostCleanupDestinationContext {
        let expectation: PostCleanupDestinationExpectation
        let location: WorkspaceFileSystemLocation
        let chain: DirectoryDescriptorChain
        let parentDescriptor: Int32
        let leaf: String

        init(
            target: WriteTarget,
            location: WorkspaceFileSystemLocation,
            chain: DirectoryDescriptorChain,
            parentDescriptor: Int32,
            leaf: String
        ) {
            expectation = switch target {
            case let .existing(descriptor, metadata, _, _):
                .existing(descriptor: descriptor, metadata: metadata)
            case .missing:
                .missing
            }
            self.location = location
            self.chain = chain
            self.parentDescriptor = parentDescriptor
            self.leaf = leaf
        }

        init(existing context: ExistingWriteContext) {
            expectation = .existing(
                descriptor: context.originalDescriptor,
                metadata: context.originalMetadata
            )
            location = context.commit.location
            chain = context.commit.chain
            parentDescriptor = context.commit.parentDescriptor
            leaf = context.commit.leaf
        }

        init(missing context: WriteCommitContext) {
            expectation = .missing
            location = context.location
            chain = context.chain
            parentDescriptor = context.parentDescriptor
            leaf = context.leaf
        }
    }

    enum PostCleanupDestinationObservation {
        case entry(DirectoryEntryIdentity)
        case missing
    }

    struct PreparedRecoveryEvidence {
        let identity: WorkspaceFileSystemIdentity?
        let metadata: WorkspaceCoherentFileMetadata?
    }

    static func write(
        _ data: Data,
        to location: WorkspaceFileSystemLocation,
        expecting expectation: WorkspaceNoFollowFileWriteExpectation,
        hooks: Hooks
    ) -> WorkspaceFileWriteOutcome {
        write(
            data,
            to: location,
            expecting: expectation,
            parentExpectation: nil,
            hooks: hooks
        )
    }

    static func write(
        _ data: Data,
        to location: WorkspaceFileSystemLocation,
        expecting expectation: WorkspaceNoFollowFileWriteExpectation,
        parentExpectation: WorkspaceItemMutationExpectation?,
        hooks: Hooks
    ) -> WorkspaceFileWriteOutcome {
        do {
            return try withAnchoredParent(at: location, hooks: hooks) { chain, parentDescriptor, leaf in
                if let parentExpectation {
                    try validateDirectoryMutationExpectation(
                        parentDescriptor: parentDescriptor,
                        expectation: parentExpectation
                    )
                    try chain.validateNamespace()
                }
                return try performWrite(
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
        let postCleanupContext = PostCleanupDestinationContext(
            target: target,
            location: location,
            chain: chain,
            parentDescriptor: parentDescriptor,
            leaf: leaf
        )

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
            defer { Darwin.close(error.descriptor) }
            let artifactState = removeArtifact(
                named: error.name,
                location: error.location,
                expectedIdentity: error.expectedIdentity,
                borrowedDescriptor: error.descriptor,
                context: artifactRemovalContext,
                unlinkCall: .cleanupTemporary
            )
            return postCleanupOutcome(
                reason: error.reason,
                artifactState: artifactState,
                prepared: PreparedRecoveryMaterial(error),
                context: postCleanupContext
            )
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
                borrowedDescriptor: prepared.descriptor,
                context: artifactRemovalContext,
                unlinkCall: .cleanupTemporary
            )
            return postCleanupOutcome(
                reason: normalizedError(error),
                artifactState: artifactState,
                prepared: PreparedRecoveryMaterial(prepared),
                context: postCleanupContext
            )
        }

        let commit = WriteCommitContext(
            prepared: prepared,
            location: location,
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
                borrowedDescriptor: commit.prepared.descriptor,
                context: commit.artifactRemovalContext,
                unlinkCall: .cleanupTemporary
            )
            return postCleanupOutcome(
                reason: normalizedError(error),
                artifactState: artifactState,
                prepared: PreparedRecoveryMaterial(commit.prepared),
                context: PostCleanupDestinationContext(existing: context)
            )
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
                artifactState: artifactState(
                    named: commit.prepared.name,
                    location: commit.prepared.location,
                    expectedIdentity: context.originalMetadata.identity,
                    context: commit.artifactRemovalContext
                )
            )
        }

        guard isWriterOwnedOriginal(displacedEntry, context: context) else {
            // The name at the temporary slot is not writer-owned original material. Do not
            // reverse-swap, unlink, or otherwise mutate through that unrelated entry.
            return indeterminate(
                reason: afterRenameFailure ?? errorForUnexpectedDisplacedEntry(displacedEntry),
                preparedMetadata: commit.prepared.metadata,
                artifactState: .removalIndeterminate(commit.prepared.location)
            )
        }

        if let afterRenameFailure {
            return rollbackExistingWrite(
                reason: afterRenameFailure,
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
                borrowedDescriptor: context.prepared.descriptor,
                context: context.artifactRemovalContext,
                unlinkCall: .cleanupTemporary
            )
            return postCleanupOutcome(
                reason: normalizedError(error),
                artifactState: artifactState,
                prepared: PreparedRecoveryMaterial(context.prepared),
                context: PostCleanupDestinationContext(missing: context)
            )
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
