import Foundation
import MarkdownCore
import WorkspaceKit

/// Export PR E adapter: the injected ownership capability for `ExportArtifactWriter`.
///
/// It reuses the authoritative inventory that Save Copy and workspace mutations already
/// consult (current, warm/cached, retired, editor-bound, quarantined/detached, context-only,
/// recovery, and indeterminate owners; hard links, case/canonical aliases, and component
/// overlap) instead of building an export-specific URL list. It adds no command or UI and
/// mutates no App state.
@MainActor
extension AppState {
    /// Answers the writer's synchronous ownership query for one inspected destination.
    ///
    /// An export never overwrites or shadows any owned identity, including the exported
    /// document's own file. The export source is exempt only when it owns no file at all
    /// (an untitled session), which is the one case where Save Copy's source exception
    /// cannot hide an owned identity.
    func exportArtifactDestinationOwnership(
        for inspection: WorkspaceNoFollowFileTargetInspection,
        exportSource: DocumentSession?
    ) -> ExportArtifactOwnershipDecision {
        let location = inspection.canonicalLocation
        do {
            try validateWorkspaceMutationRecoveryStoresLoaded(at: location.fileURL)
            let inventoryInspection = try validateWorkspaceSaveCopyDestinationOwnership(
                at: location,
                excluding: exportSource.flatMap(exportSourceOwningNoFile)
            )
            // The App's own inspection must agree with the writer's; any identity, type, or
            // case-policy change between the two fails closed.
            guard inventoryInspection == inspection else { return .refused }
            try validateWorkspaceMutationDestinationOwnership(location)
            return .permitted
        } catch {
            return .refused
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
