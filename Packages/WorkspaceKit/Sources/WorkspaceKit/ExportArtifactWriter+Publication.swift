import Darwin
import Foundation

/// Records the primitive's exact staging name, or the `errno` of a failed staging create.
final class ExportArtifactStagingRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var createdName: String?
    private var failureCode: Int32?

    var stagingName: String? {
        lock.withLock { createdName }
    }

    var creationFailureCode: Int32? {
        lock.withLock { failureCode }
    }

    func record(_ observation: WorkspaceAnchoredFileSystem.TemporaryArtifactObservation) {
        lock.withLock {
            switch observation {
            case let .created(name): createdName = name
            case let .creationFailed(code): failureCode = code
            }
        }
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
        let preflight: ExportArtifactPreflight
        switch self.preflight(selection, hooks: hooks) {
        case let .success(value): preflight = value
        case let .failure(failure): return .notCommitted(failure)
        }

        let expectation: WorkspaceNoFollowFileWriteExpectation
        switch (disposition, preflight.inspection.state) {
        case (.createNew, .missing):
            expectation = .missing
        case (.createNew, .regular):
            return .notCommitted(.destinationAlreadyExists)
        case let (.replaceConfirmed(approved), .regular(observed)):
            guard approved == observed else { return .notCommitted(.destinationIdentityChanged) }
            expectation = .existing(approved)
        case (.replaceConfirmed, .missing):
            return .notCommitted(.destinationMissing)
        }

        // The App inventory answers synchronously on the caller's thread, so no App state change
        // can interleave before publication; filesystem identity is re-proven by the primitive.
        guard ownership(preflight.inspection) == .permitted else {
            return .notCommitted(.ownedDestination)
        }
        hooks.afterPreflight?()

        let recorder = ExportArtifactStagingRecorder()
        let base = hooks.fileSystem
        let fileSystemHooks = WorkspaceAnchoredFileSystem.Hooks(
            eventHandler: base.eventHandler,
            injectedFailure: base.injectedFailure,
            temporaryArtifactObserver: { observation in
                recorder.record(observation)
                base.temporaryArtifactObserver?(observation)
            }
        )
        let outcome = WorkspaceAnchoredFileSystem.write(
            bytes,
            to: preflight.location,
            expecting: expectation,
            hooks: fileSystemHooks
        )
        hooks.afterPublication?()
        return exportOutcome(
            outcome,
            selection: selection,
            context: indeterminateContext(
                selection: selection,
                preflight: preflight,
                expectation: expectation,
                recorder: recorder
            ),
            recorder: recorder
        )
    }

    private static func indeterminateContext(
        selection: ExportArtifactSelection,
        preflight: ExportArtifactPreflight,
        expectation: WorkspaceNoFollowFileWriteExpectation,
        recorder: ExportArtifactStagingRecorder
    ) -> IndeterminateContext {
        let approvedIdentity: WorkspaceFileSystemIdentity? = if case let .existing(identity) = expectation {
            identity
        } else {
            nil
        }
        return IndeterminateContext(
            selectedURL: selection.destinationURL,
            destination: preflight.location,
            stagingLocation: recorder.stagingName.flatMap { preflight.location.sibling(named: $0) },
            approvedIdentity: approvedIdentity
        )
    }

    private static func exportOutcome(
        _ outcome: WorkspaceFileWriteOutcome,
        selection: ExportArtifactSelection,
        context: IndeterminateContext,
        recorder: ExportArtifactStagingRecorder
    ) -> ExportArtifactWriteOutcome {
        let destination = context.destination
        switch outcome {
        case let .committedAndDurable(result):
            guard result.cleanupState == .none else {
                return context.indeterminate(
                    reason: .cleanupFailed,
                    destinationState: .holdsWriterBytes,
                    artifactState: result.cleanupState,
                    writerIdentity: result.metadata.identity
                )
            }
            guard proveCommittedNamespace(
                destination: destination,
                committedIdentity: result.metadata.identity,
                stagingName: recorder.stagingName
            ) else {
                return context.indeterminate(
                    reason: .namespaceChanged,
                    destinationState: .unknown,
                    artifactState: context.stagingLocation.map { .removalIndeterminate($0) } ?? .none,
                    writerIdentity: result.metadata.identity
                )
            }
            return .committed(ExportArtifactCommit(
                selectedURL: selection.destinationURL,
                metadata: result.metadata
            ))
        case let .notCommitted(result):
            guard result.artifactState == .none else {
                return context.indeterminate(
                    reason: result.reason,
                    destinationState: .provenUnchanged,
                    artifactState: result.artifactState,
                    writerIdentity: result.retainedArtifactIdentity
                )
            }
            if let code = recorder.creationFailureCode {
                return .notCommitted(code == EPERM || code == EACCES
                    ? .stagingNotPermitted(code: code)
                    : .stagingUnavailable(code: code))
            }
            return .notCommitted(failure(forNonCommit: result.reason))
        case let .committedButIndeterminate(result):
            return context.indeterminate(
                reason: result.reason,
                destinationState: .unknown,
                artifactState: result.recoveryArtifact,
                writerIdentity: result.preparedMetadata?.identity
            )
        }
    }

    /// Success requires the staging name proven absent. `RENAME_SWAP` cleanup proves the
    /// displaced identity absent from its tracked names; `RENAME_EXCL` moves the staging name,
    /// so both paths re-prove here that the name holds no entry while the selected leaf still
    /// names the published identity under the same held namespace.
    private static func proveCommittedNamespace(
        destination: WorkspaceFileSystemLocation,
        committedIdentity: WorkspaceFileSystemIdentity,
        stagingName: String?
    ) -> Bool {
        guard let stagingName else { return false }
        return WorkspaceAnchoredFileSystem.$ignoresInheritedTaskCancellation.withValue(true) {
            do {
                return try WorkspaceAnchoredFileSystem.withAnchoredParent(
                    at: destination,
                    hooks: .production
                ) { chain, parentDescriptor, leaf in
                    let entry = try WorkspaceAnchoredFileSystem.directoryEntryIdentity(
                        parentDescriptor: parentDescriptor,
                        component: leaf
                    )
                    try WorkspaceAnchoredFileSystem.validateMissingName(
                        parentDescriptor: parentDescriptor,
                        leaf: stagingName
                    )
                    try chain.validateNamespace()
                    return entry.isRegularFile && entry.identity == committedIdentity
                }
            } catch {
                return false
            }
        }
    }

    private static func failure(
        forNonCommit reason: WorkspaceAnchoredFileSystemError
    ) -> ExportArtifactFailure {
        switch reason {
        case .changedIdentity: .destinationIdentityChanged
        case .missing: .destinationMissing
        case .symbolicLink: .symbolicLinkDestination
        case .notRegularFile: .nonRegularDestination
        case .namespaceChanged: .namespaceChanged
        case .cancelled: .cancelled
        case .unreadable, .changedContent, .unstable, .durabilityFailed, .cleanupFailed:
            .writeFailed(reason)
        }
    }
}

private struct IndeterminateContext {
    let selectedURL: URL
    let destination: WorkspaceFileSystemLocation
    let stagingLocation: WorkspaceFileSystemLocation?
    /// The panel-approved identity a replacement may displace; `nil` for a new leaf.
    let approvedIdentity: WorkspaceFileSystemIdentity?

    /// Converts the primitive's retained location into plain URLs, so the outcome retains no
    /// descriptor-backed authority after the operation.
    func indeterminate(
        reason: WorkspaceAnchoredFileSystemError,
        destinationState: ExportArtifactDestinationState,
        artifactState: WorkspaceFileWriteArtifactState,
        writerIdentity: WorkspaceFileSystemIdentity?
    ) -> ExportArtifactWriteOutcome {
        let residue: ExportArtifactResidue
        let residueLocation: WorkspaceFileSystemLocation?
        switch artifactState {
        case .none:
            residue = .none
            residueLocation = nil
        case let .retained(location):
            residue = .retained(location.fileURL, holding: contents(at: location, writerIdentity: writerIdentity))
            residueLocation = location
        case let .removalIndeterminate(location):
            residue = .removalIndeterminate(location.fileURL)
            residueLocation = location
        }
        // A sibling residue is the exact staging/cleanup path. A residue at the selected leaf
        // leaves the staging name unproven, so report the operation's exact staging path.
        let stagingURL: URL? = if let residueLocation, residueLocation != destination {
            residueLocation.fileURL
        } else if residueLocation == destination {
            stagingLocation?.fileURL
        } else {
            nil
        }
        return .indeterminate(ExportArtifactIndeterminateWrite(
            reason: reason,
            selectedURL: selectedURL,
            destinationState: destinationState,
            residue: residue,
            stagingURL: stagingURL
        ))
    }

    /// Tells PR F where the user's original file is: one anchored no-follow re-observation of
    /// the retained entry compared with the approved and writer identities.
    private func contents(
        at location: WorkspaceFileSystemLocation,
        writerIdentity: WorkspaceFileSystemIdentity?
    ) -> ExportArtifactResidueContents {
        let observed: WorkspaceFileSystemIdentity? = WorkspaceAnchoredFileSystem
            .$ignoresInheritedTaskCancellation.withValue(true) {
                try? WorkspaceAnchoredFileSystem.withAnchoredParent(
                    at: location,
                    hooks: .production
                ) { chain, parentDescriptor, leaf in
                    let entry = try WorkspaceAnchoredFileSystem.directoryEntryIdentity(
                        parentDescriptor: parentDescriptor,
                        component: leaf
                    )
                    try chain.validateNamespace()
                    return entry.isRegularFile ? entry.identity : nil
                }
            }
        guard let observed else { return .unknown }
        if observed == approvedIdentity { return .displacedOriginal }
        if observed == writerIdentity { return .writerBytes }
        return .unknown
    }
}
