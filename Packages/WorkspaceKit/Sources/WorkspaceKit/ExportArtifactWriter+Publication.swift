import Darwin
import Foundation

/// What one publication attempt proved about the two names it may have exchanged.
enum ExportArtifactPublication {
    /// `renameatx_np` did not run or failed atomically; the leaf was never changed.
    case notPublished(ExportArtifactFailure)
    /// Postflight proved the leaf holds the writer identity and bytes count, and the staged name
    /// holds the approved displaced identity (swap) or no entry (exclusive).
    case verified(stat)
    /// A postflight mismatch was reversed after an exact two-name proof, and the reversal was
    /// proven: the leaf holds the approved identity and the staged name the writer's bytes.
    case reversed
    /// Neither verified nor provably reversed; both identities are preserved where they are.
    case unverified
}

/// One operation's fixed facts after staging, used to publish, clean up, and report.
struct ExportArtifactOperation {
    let selection: ExportArtifactSelection
    let directory: ExportArtifactStagingDirectory
    let approved: WorkspaceNoFollowFileTargetState
    let parentIdentity: WorkspaceFileSystemIdentity
    let hooks: ExportArtifactWriterHooks

    var approvedIdentity: WorkspaceFileSystemIdentity? {
        if case let .regular(identity) = approved {
            return identity
        }
        return nil
    }

    var isExclusive: Bool {
        approved == .missing
    }

    func classifier(writer: WorkspaceFileSystemIdentity?) -> ExportArtifactResidueClassifier {
        ExportArtifactResidueClassifier(approvedIdentity: approvedIdentity, writerIdentity: writer)
    }
}

extension ExportArtifactWriter {
    static func performWrite(
        _ bytes: Data,
        selection: ExportArtifactSelection,
        disposition: ExportArtifactDisposition,
        ownership: ExportArtifactOwnershipCheck,
        hooks: ExportArtifactWriterHooks
    ) -> ExportArtifactWriteOutcome {
        guard !Task.isCancelled else { return .notCommitted(.cancelled) }
        let preflight: ExportArtifactPreflight
        let approved: WorkspaceNoFollowFileTargetState
        switch approvedPreflight(selection, disposition: disposition, ownership: ownership, hooks: hooks) {
        case let .success(value): (preflight, approved) = value
        case let .failure(failure): return .notCommitted(failure)
        }
        hooks.afterPreflight?()

        let directory: ExportArtifactStagingDirectory
        switch establishStagingDirectory(selection, preflight: preflight, hooks: hooks) {
        case let .success(value): directory = value
        case let .failure(refusal): return refusalOutcome(refusal, selection: selection, hooks: hooks)
        }
        let operation = ExportArtifactOperation(
            selection: selection,
            directory: directory,
            approved: approved,
            parentIdentity: preflight.proof.parentIdentity,
            hooks: hooks
        )
        // Q3: a confirmed overwrite keeps the displaced file's mode bits, as the retained Save
        // path does; a new leaf keeps the `0666 & ~umask` create mode.
        let displacedMode = preflight.proof.leafStatus.map { $0.st_mode & mode_t(0o7777) }
        let staged: ExportArtifactStagedFile
        switch createStagedFile(bytes, in: directory, displacedMode: displacedMode, hooks: hooks) {
        case let .success(value): staged = value
        case let .failure(failure): return abandon(operation, failure: failure.failure, entry: failure.entry)
        }
        guard !Task.isCancelled else {
            return abandon(operation, failure: .cancelled, entry: .file(staged))
        }
        let publication = coordinatedIfUbiquitous(operation) {
            publish(operation, staged: staged)
        }
        hooks.afterPublication?()
        return finish(operation, publication: publication, staged: staged)
    }

    /// Leaf proof, disposition match, volume capabilities, then the injected ownership answer.
    /// The App inventory answers synchronously on the caller's thread, so no App state change
    /// can interleave before publication; the leaf itself is re-proven before publishing.
    private static func approvedPreflight(
        _ selection: ExportArtifactSelection,
        disposition: ExportArtifactDisposition,
        ownership: ExportArtifactOwnershipCheck,
        hooks: ExportArtifactWriterHooks
    ) -> Result<(ExportArtifactPreflight, WorkspaceNoFollowFileTargetState), ExportArtifactFailure> {
        inspect(selection, hooks: hooks).flatMap { preflight in
            approvedState(for: disposition, observed: preflight.proof.state).flatMap { approved in
                if let failure = volumeCapabilityFailure(selection, proof: preflight.proof, hooks: hooks) {
                    return .failure(failure)
                }
                guard ownership(preflight.inspection) == .permitted else {
                    return .failure(.ownedDestination)
                }
                return .success((preflight, approved))
            }
        }
    }

    /// A refused staging directory is removed (only while empty and identity-matched) or
    /// reported by exact path.
    private static func refusalOutcome(
        _ refusal: ExportArtifactStagingRefusal,
        selection: ExportArtifactSelection,
        hooks: ExportArtifactWriterHooks
    ) -> ExportArtifactWriteOutcome {
        guard let removable = refusal.removableDirectory,
              !removeStagingDirectory(removable, hooks: hooks)
        else {
            return .notCommitted(refusal.failure)
        }
        return .indeterminate(ExportArtifactIndeterminateWrite(
            reason: .cleanupFailed,
            selectedURL: selection.destinationURL,
            destinationState: .provenUnchanged,
            residue: .none,
            stagingURL: nil,
            itemReplacementDirectoryURL: removable.url,
            residueIsInPurgeableTemporaryFolder: false
        ))
    }

    /// Q1: a ubiquitous destination (the leaf or its parent URL) publishes inside
    /// `NSFileCoordinator.coordinate(writingItemAt:options: .forReplacing)`. Coordination is an
    /// addition only: it grants no authority, and the accessor must receive the same leaf.
    static func coordinatedIfUbiquitous(
        _ operation: ExportArtifactOperation,
        _ publish: () -> ExportArtifactPublication
    ) -> ExportArtifactPublication {
        let selection = operation.selection
        let hooks = operation.hooks
        guard hooks.ubiquitous(selection.leafURL) || hooks.ubiquitous(selection.parentURL) else {
            return publish()
        }
        guard case .success = hooks.perform(.coordinate, .coordinate, path: selection.leafPath, { 0 }) else {
            return .notPublished(.coordinationFailed)
        }
        var publication: ExportArtifactPublication?
        var coordinationError: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(
            writingItemAt: selection.destinationURL,
            options: .forReplacing,
            error: &coordinationError
        ) { coordinatedURL in
            let coordinatedPath = coordinatedURL.path(percentEncoded: false).precomposedStringWithCanonicalMapping
            guard coordinatedPath == selection.leafPath.precomposedStringWithCanonicalMapping else {
                publication = .notPublished(.namespaceChanged)
                return
            }
            publication = publish()
        }
        return publication ?? .notPublished(.coordinationFailed)
    }

    /// D5 steps 3–5: re-prove the leaf, publish by exact path, then postflight.
    static func publish(
        _ operation: ExportArtifactOperation,
        staged: ExportArtifactStagedFile
    ) -> ExportArtifactPublication {
        let selection = operation.selection
        let hooks = operation.hooks
        if let failure = reproveLeaf(
            selection,
            approved: operation.approved,
            parentIdentity: operation.parentIdentity,
            hooks: hooks
        ) {
            return .notPublished(failure)
        }
        let leafPath = selection.leafPath
        let flags = UInt32((operation.isExclusive ? RENAME_EXCL : RENAME_SWAP) | RENAME_NOFOLLOW_ANY)
        switch hooks.perform(.publish, .rename, path: leafPath, {
            Darwin.renameatx_np(AT_FDCWD, staged.path, AT_FDCWD, leafPath, flags)
        }) {
        case let .failure(failure):
            return .notPublished(publicationFailure(failure.code, exclusive: operation.isExclusive))
        case .success:
            return postflight(operation, staged: staged)
        }
    }

    private static func publicationFailure(_ code: Int32, exclusive: Bool) -> ExportArtifactFailure {
        switch code {
        case EEXIST: .destinationAlreadyExists
        case ENOENT: exclusive ? .namespaceChanged : .destinationMissing
        case ELOOP: .symbolicLinkInParentPath
        case ENOTSUP: .unsupportedVolumeSemantics
        case EXDEV: .stagingDirectoryOnDifferentDevice
        case EPERM, EACCES: .publicationNotPermitted(code: code)
        default: .writeFailed(.unreadable)
        }
    }

    /// The leaf must hold the staged identity and byte count. After `RENAME_EXCL` the staged
    /// name must hold no entry; after `RENAME_SWAP` it must hold the exact approved displaced
    /// identity. A swap mismatch reverses only after an exact two-name proof.
    private static func postflight(
        _ operation: ExportArtifactOperation,
        staged: ExportArtifactStagedFile
    ) -> ExportArtifactPublication {
        let hooks = operation.hooks
        let leaf = hooks.noFollowStatus(operation.selection.leafPath, step: .postflight)
        let displaced = hooks.noFollowStatus(staged.path, step: .postflight)
        let stagedNameProven: Bool = if operation.isExclusive {
            if case let .failure(failure) = displaced {
                failure.code == ENOENT
            } else {
                false
            }
        } else {
            holds(displaced, operation.approvedIdentity)
        }
        if case let .success(status) = leaf, holds(leaf, staged.identity),
           Int64(status.st_size) == staged.byteCount, stagedNameProven
        {
            return .verified(status)
        }
        return operation.isExclusive ? .unverified : reverseAfterMismatch(operation, staged: staged)
    }

    private static func reverseAfterMismatch(
        _ operation: ExportArtifactOperation,
        staged: ExportArtifactStagedFile
    ) -> ExportArtifactPublication {
        let hooks = operation.hooks
        let leafPath = operation.selection.leafPath
        guard holds(hooks.noFollowStatus(leafPath, step: .twoNameProof), staged.identity),
              holds(hooks.noFollowStatus(staged.path, step: .twoNameProof), operation.approvedIdentity)
        else {
            return .unverified
        }
        let flags = UInt32(RENAME_SWAP | RENAME_NOFOLLOW_ANY)
        guard case .success = hooks.perform(.reverseSwap, .rename, path: leafPath, {
            Darwin.renameatx_np(AT_FDCWD, staged.path, AT_FDCWD, leafPath, flags)
        }) else {
            return .unverified
        }
        guard holds(hooks.noFollowStatus(leafPath, step: .reversalProof), operation.approvedIdentity),
              holds(hooks.noFollowStatus(staged.path, step: .reversalProof), staged.identity)
        else {
            return .unverified
        }
        return .reversed
    }

    private static func holds(
        _ observation: Result<stat, ExportArtifactSyscallFailure>,
        _ identity: WorkspaceFileSystemIdentity?
    ) -> Bool {
        guard let identity, case let .success(status) = observation else { return false }
        return status.exportFileType == S_IFREG && WorkspaceFileSystemIdentity(exportStatus: status) == identity
    }
}
