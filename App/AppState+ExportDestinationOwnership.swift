import Foundation
import MarkdownCore
import WorkspaceKit

/// Export adapter: the injected ownership capability for `ExportArtifactWriter`.
///
/// It reuses the authoritative inventory that Save Copy and workspace mutations already
/// consult (current, warm/cached, retired, editor-bound, quarantined/detached, context-only,
/// recovery, and indeterminate owners; hard links, case/canonical aliases, and component
/// overlap) instead of building an export-specific URL list. The destination is known only by
/// the writer's leaf-path inspection (D5, amended 2026-09-29): its identity, exact spelling, and
/// volume case sensitivity come from leaf-path metadata, so a leaf-only save-panel grant never
/// needs a parent descriptor here. It adds no command or UI and mutates no App state.
@MainActor
extension AppState {
    /// Answers the writer's synchronous ownership query for one inspected destination.
    ///
    /// An export never overwrites or shadows any owned identity, including the exported
    /// document's own file. The export source is exempt only when it owns no file at all
    /// (an untitled session), which is the one case where Save Copy's source exception
    /// cannot hide an owned identity.
    func exportArtifactDestinationOwnership(
        for inspection: ExportArtifactLeafInspection,
        exportSource: DocumentSession?
    ) -> ExportArtifactOwnershipDecision {
        do {
            try validateExportArtifactDestinationOwnership(inspection, exportSource: exportSource)
            return .permitted
        } catch {
            return .refused
        }
    }

    /// Export entry point over the recovery fence and both authoritative inventories.
    func validateExportArtifactDestinationOwnership(
        _ inspection: ExportArtifactLeafInspection,
        exportSource: DocumentSession?
    ) throws {
        let leafURL = inspection.leafURL
        try validateWorkspaceMutationRecoveryStoresLoaded(at: leafURL)
        // The App's own leaf-path inspection must agree with the writer's; any identity, type,
        // spelling, parent, or case-policy change between the two fails closed.
        guard case let .success(appInspection) = ExportArtifactWriter.inspectLeaf(at: leafURL),
              appInspection == inspection
        else {
            throw AppStateError.invalidSessionIdentity(leafURL)
        }
        if isWorkspaceMutationRecoveryCandidate(fileURL: leafURL) {
            throw AppStateError.invalidSessionIdentity(leafURL)
        }
        try validateExportArtifactSaveCopyInventory(inspection, exportSource: exportSource)
        try validateExportArtifactMutationInventory(inspection)
    }

    /// The Save Copy owner walk. Hard links match by `st_dev`/`st_ino`; case and normalization
    /// aliases match by full-path alias keys under the destination volume's case policy.
    func validateExportArtifactSaveCopyInventory(
        _ inspection: ExportArtifactLeafInspection,
        exportSource: DocumentSession?
    ) throws {
        let leafPath = inspection.leafURL.path(percentEncoded: false)
        let destinationIdentity: WorkspaceFileSystemIdentity? = switch inspection.state {
        case let .regular(identity): identity
        case .missing: nil
        }
        try validateWorkspaceSaveCopyInventoryOwnership(
            destinationIdentity: destinationIdentity,
            refusalURL: inspection.leafURL,
            excluding: exportSource.flatMap(exportSourceOwningNoFile),
            // A file-less source retains no location, so no exact-missing-source exemption applies.
            isExactDestination: { _ in false },
            overlapsDestination: { retainedLocation in
                workspaceSaveCopyPathsOverlap(
                    retainedLocation.fileURL.path(percentEncoded: false),
                    leafPath,
                    parentIsCaseSensitive: inspection.volumeIsCaseSensitive
                )
            }
        )
    }

    /// The workspace-mutation owner inventory: every managed session's state URL and every owned
    /// state URL, compared by full-path alias keys with the same symmetric component overlap.
    func validateExportArtifactMutationInventory(_ inspection: ExportArtifactLeafInspection) throws {
        let leafPath = inspection.leafURL.path(percentEncoded: false)
        var ownedURLs = workspaceMutationManagedSessions().compactMap { sessionStateURL(for: $0) }
        ownedURLs.append(contentsOf: workspaceMutationOwnedStateURLs())
        for ownedURL in ownedURLs where workspaceSaveCopyPathsOverlap(
            ownedURL.path(percentEncoded: false),
            leafPath,
            parentIsCaseSensitive: inspection.volumeIsCaseSensitive
        ) {
            throw WorkspaceMutationError.sessionDestinationConflict(inspection.leafURL)
        }
    }

    /// Runs one export write with this App's ownership inventory as its injected capability.
    /// The writer runs synchronously here, so no App ownership change can interleave between
    /// the inventory answer and publication.
    func writeExportArtifact(
        _ request: consuming ExportArtifactWriteRequest,
        exportSource: DocumentSession?
    ) -> ExportArtifactWriteOutcome {
        ExportArtifactWriter.write(request) { inspection in
            exportArtifactDestinationOwnership(for: inspection, exportSource: exportSource)
        }
    }

    private func exportSourceOwningNoFile(_ session: DocumentSession) -> DocumentSession? {
        let sessionIdentity = ObjectIdentifier(session)
        guard session.fileURL == nil,
              sessionStateURL(for: session) == nil,
              anchoredSessionFileBinding(for: session) == nil,
              indeterminateSessionWriteContexts[sessionIdentity] == nil,
              indeterminateSessionWrites[sessionIdentity] == nil
        else {
            return nil
        }
        return session
    }
}
