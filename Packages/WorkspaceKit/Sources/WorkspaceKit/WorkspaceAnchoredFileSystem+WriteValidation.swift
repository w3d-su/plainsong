import Darwin

extension WorkspaceAnchoredFileSystem {
    static func revalidateTarget(
        _ target: WriteTarget,
        parentDescriptor: Int32,
        leaf: String
    ) throws {
        switch target {
        case let .existing(_, metadata, _, _):
            try validateNameStillReferencesDescriptor(
                parentDescriptor: parentDescriptor,
                leaf: leaf,
                metadata: metadata
            )
        case .missing:
            try validateMissingName(parentDescriptor: parentDescriptor, leaf: leaf)
        }
    }

    static func swapPreparedWrite(
        _ context: ExistingWriteContext
    ) throws {
        let commit = context.commit
        if let expectedDigest = context.expectedDigest {
            try validateExpectedContent(
                descriptor: context.originalDescriptor,
                metadata: context.originalMetadata,
                expectedDigest: expectedDigest
            )
        }
        try commit.chain.validateNamespace()
        try validateNameStillReferencesDescriptor(
            parentDescriptor: commit.parentDescriptor,
            leaf: commit.leaf,
            metadata: context.originalMetadata
        )
        try checkCancellation()
        commit.hooks.emit(.willCommit(.swap))
        try commit.hooks.check(.renameSwap)
        try commit.chain.validateNamespace()
        try validatePreparedWrite(
            commit.prepared,
            parentDescriptor: commit.parentDescriptor
        )
        try validateNameStillReferencesDescriptor(
            parentDescriptor: commit.parentDescriptor,
            leaf: commit.leaf,
            metadata: context.originalMetadata
        )
        guard secureRename(
            parentDescriptor: commit.parentDescriptor,
            from: commit.prepared.name,
            to: commit.leaf,
            flags: UInt32(RENAME_SWAP)
        ) == 0 else {
            throw WorkspaceAnchoredFileSystemError.unreadable
        }
    }

    static func validateAndSyncCommittedExistingWrite(
        _ context: ExistingWriteContext,
        displacedEntry: DirectoryEntryIdentity
    ) throws {
        let commit = context.commit
        try commit.hooks.check(.validateCommittedLeaf)
        try validateCommittedExistingWrite(context, displacedEntry: displacedEntry)
        try commit.hooks.check(.syncCommittedDirectory)
        try syncDirectory(commit.parentDescriptor)
        try validateCommittedExistingWrite(context, displacedEntry: displacedEntry)
    }

    static func validateCommittedExistingWrite(
        _ context: ExistingWriteContext,
        displacedEntry: DirectoryEntryIdentity
    ) throws {
        let commit = context.commit
        try checkCancellation()
        try commit.chain.validateNamespace()
        try validateNameStillReferencesDescriptor(
            parentDescriptor: commit.parentDescriptor,
            leaf: commit.leaf,
            metadata: commit.prepared.metadata
        )
        try validatePreparedContent(commit.prepared)
        try validateNameStillReferencesEntry(
            parentDescriptor: commit.parentDescriptor,
            leaf: commit.prepared.name,
            entry: displacedEntry
        )
        if let expectedDigest = context.expectedDigest {
            try validateExpectedContentAfterSwap(
                descriptor: context.originalDescriptor,
                originalMetadata: context.originalMetadata,
                expectedDigest: expectedDigest
            )
        }
        try commit.chain.validateNamespace()
    }

    static func validateCommittedLeaf(_ context: WriteCommitContext) throws {
        try checkCancellation()
        try context.chain.validateNamespace()
        try validateNameStillReferencesDescriptor(
            parentDescriptor: context.parentDescriptor,
            leaf: context.leaf,
            metadata: context.prepared.metadata
        )
        try validatePreparedContent(context.prepared)
        try context.chain.validateNamespace()
    }

    static func finalCommittedMetadata(
        context: WriteCommitContext
    ) throws -> WorkspaceCoherentFileMetadata {
        try validateCommittedDestination(context: context)
        try validatePreparedContent(context.prepared)
        let finalMetadata = try regularFileMetadata(descriptor: context.prepared.descriptor)
        try context.chain.validateNamespace()
        try validateNameStillReferencesDescriptor(
            parentDescriptor: context.parentDescriptor,
            leaf: context.leaf,
            metadata: finalMetadata
        )
        try validatePreparedContent(context.prepared)
        try context.chain.validateNamespace()
        return finalMetadata
    }

    static func validatePreparedWrite(
        _ prepared: PreparedWrite,
        parentDescriptor: Int32
    ) throws {
        try validateNameStillReferencesDescriptor(
            parentDescriptor: parentDescriptor,
            leaf: prepared.name,
            metadata: prepared.metadata
        )
        try validatePreparedContent(prepared)
    }

    static func errorForUnexpectedDisplacedEntry(
        _ entry: DirectoryEntryIdentity
    ) -> WorkspaceAnchoredFileSystemError {
        switch entry.fileType {
        case S_IFLNK: .symbolicLink
        case S_IFREG: .changedIdentity
        default: .notRegularFile
        }
    }

    static func isWriterOwnedOriginal(
        _ entry: DirectoryEntryIdentity,
        context: ExistingWriteContext
    ) -> Bool {
        entry.isRegularFile && entry.identity == context.originalMetadata.identity
    }

    static func injectedError(
        from hooks: Hooks,
        at call: InjectedCall
    ) -> WorkspaceAnchoredFileSystemError? {
        do {
            try hooks.check(call)
            return nil
        } catch {
            return normalizedError(error)
        }
    }
}
