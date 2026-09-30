import Darwin
import Foundation

/// What cleanup of the item-replacement directory proved.
private struct ExportArtifactCleanup {
    let residue: ExportArtifactResidue
    /// The staged-file path while it may still hold an entry.
    let stagingURL: URL?
    /// The directory while it was not proven removed.
    let directoryURL: URL?

    var isClean: Bool {
        residue == .none && directoryURL == nil
    }
}

extension ExportArtifactWriter {
    /// Nothing was published. Removes the writer's own staged file (only while it holds the
    /// staged identity) and the directory; `.notCommitted` requires both proven absent.
    static func abandon(
        _ operation: ExportArtifactOperation,
        failure: ExportArtifactFailure,
        entry: ExportArtifactStagedEntry
    ) -> ExportArtifactWriteOutcome {
        let residue: ExportArtifactResidue
        let stagingURL: URL?
        switch entry {
        case .none:
            residue = .none
            stagingURL = nil
        case let .file(staged):
            residue = removeEntry(
                staged.path,
                expected: staged.identity,
                step: .unlinkStaged,
                classifier: operation.classifier(writer: staged.identity),
                hooks: operation.hooks
            )
            stagingURL = staged.url
        case let .unproven(path):
            let url = WorkspaceLiteralFileURL.fileURL(path: path, isDirectory: false)
            residue = .removalIndeterminate(url)
            stagingURL = url
        }
        let cleanup = cleanUp(operation, residue: residue, stagingURL: stagingURL)
        guard cleanup.isClean else {
            return indeterminate(operation, reason: .cleanupFailed, destinationState: .provenUnchanged, cleanup)
        }
        return .notCommitted(failure)
    }

    /// D5 step 5 cleanup: only a verified publication unlinks the displaced original, and success
    /// requires the staged name and the directory proven absent. A verified reversal cleans up the
    /// writer's own bytes and is a non-commit. An unverified publication preserves both
    /// identities and is always indeterminate.
    static func finish(
        _ operation: ExportArtifactOperation,
        publication: ExportArtifactPublication,
        staged: ExportArtifactStagedFile
    ) -> ExportArtifactWriteOutcome {
        let classifier = operation.classifier(writer: staged.identity)
        switch publication {
        case let .notPublished(failure):
            return abandon(operation, failure: failure, entry: .file(staged))
        case let .verified(status):
            var residue = ExportArtifactResidue.none
            if let approved = operation.approvedIdentity {
                residue = removeEntry(
                    staged.path,
                    expected: approved,
                    step: .unlinkDisplaced,
                    classifier: classifier,
                    hooks: operation.hooks
                )
            }
            let cleanup = cleanUp(operation, residue: residue, stagingURL: staged.url)
            guard cleanup.isClean else {
                return indeterminate(operation, reason: .cleanupFailed, destinationState: .holdsWriterBytes, cleanup)
            }
            return .committed(ExportArtifactCommit(
                selectedURL: operation.selection.destinationURL,
                metadata: WorkspaceCoherentFileReader.metadata(from: status)
            ))
        case .reversed:
            let residue = removeEntry(
                staged.path,
                expected: staged.identity,
                step: .unlinkStaged,
                classifier: classifier,
                hooks: operation.hooks
            )
            let cleanup = cleanUp(operation, residue: residue, stagingURL: staged.url)
            guard cleanup.isClean else {
                return indeterminate(operation, reason: .cleanupFailed, destinationState: .provenUnchanged, cleanup)
            }
            return .notCommitted(.namespaceChanged)
        case .unverified:
            let residue = observeResidue(staged.path, classifier: classifier, hooks: operation.hooks)
            let cleanup = cleanUp(operation, residue: residue, stagingURL: staged.url)
            return indeterminate(operation, reason: .namespaceChanged, destinationState: .unknown, cleanup)
        }
    }

    /// Removes the directory only once the staged name is proven empty.
    private static func cleanUp(
        _ operation: ExportArtifactOperation,
        residue: ExportArtifactResidue,
        stagingURL: URL?
    ) -> ExportArtifactCleanup {
        let removed = residue == .none && removeStagingDirectory(operation.directory, hooks: operation.hooks)
        return ExportArtifactCleanup(
            residue: residue,
            stagingURL: residue == .none ? nil : stagingURL,
            directoryURL: removed ? nil : operation.directory.url
        )
    }

    private static func indeterminate(
        _ operation: ExportArtifactOperation,
        reason: WorkspaceAnchoredFileSystemError,
        destinationState: ExportArtifactDestinationState,
        _ cleanup: ExportArtifactCleanup
    ) -> ExportArtifactWriteOutcome {
        .indeterminate(ExportArtifactIndeterminateWrite(
            reason: reason,
            selectedURL: operation.selection.destinationURL,
            destinationState: destinationState,
            residue: cleanup.residue,
            stagingURL: cleanup.stagingURL,
            itemReplacementDirectoryURL: cleanup.directoryURL,
            residueIsInPurgeableTemporaryFolder: cleanup.residue != .none
        ))
    }
}
