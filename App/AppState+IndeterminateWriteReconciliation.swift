import Foundation
import MarkdownCore
import WorkspaceKit

@MainActor
extension AppState {
    func refreshIndeterminateFileWriteReconciliation() {
        refreshIndeterminateFileWriteReconciliation(for: currentDocument)
    }

    func refreshIndeterminateFileWriteReconciliation(for session: DocumentSession) {
        let sessionIdentity = ObjectIdentifier(session)
        guard indeterminateSessionWrites[sessionIdentity] != nil,
              let context = indeterminateSessionWriteContexts[sessionIdentity]
        else {
            if session === currentDocument {
                indeterminateFileWriteReconciliationPrompt = nil
            }
            return
        }

        switch WorkspaceNoFollowFileInspector.status(at: context.location) {
        case .regular:
            do {
                let observed = try fileStore.loadResult(at: context.location)
                anchoredSessionFileBindings[sessionIdentity] = AnchoredWorkspaceSessionFileBinding(
                    location: context.location,
                    identity: observed.metadata.identity,
                    sha256Digest: observed.sha256Digest
                )
                unanchoredManagedSessionOwnershipProofs[sessionIdentity] = nil
                let destination = context.location.fileURL
                detachedSessionURLs.remove(destination)
                pendingExternalTexts[destination] = observed.file.text
                lastKnownDiskHashes[destination] = Self.contentHash(observed.file.text)
                lastKnownDiskModificationDates[destination] = nil
                if session === currentDocument {
                    indeterminateFileWriteReconciliationPrompt = nil
                    missingFilePrompt = nil
                    externalChangePrompt = ExternalChangePrompt(fileURL: destination)
                }
            } catch {
                exposeUnavailableIndeterminateFileWrite(
                    for: session,
                    context: context,
                    state: .unreadable
                )
            }
        case .missing:
            let destination = context.location.fileURL
            detachedSessionURLs.insert(destination)
            pendingExternalTexts[destination] = nil
            lastKnownDiskHashes[destination] = nil
            lastKnownDiskModificationDates[destination] = nil
            sessionPolicy.updateDirtyState(for: destination, isDirty: true)
            cancelAutosave(for: session)
            if session === currentDocument {
                indeterminateFileWriteReconciliationPrompt = nil
                externalChangePrompt = nil
                missingFilePrompt = MissingFilePrompt(fileURL: destination)
            }
        case .symbolicLink:
            exposeUnavailableIndeterminateFileWrite(
                for: session,
                context: context,
                state: .symbolicLink
            )
        case .notRegularFile:
            exposeUnavailableIndeterminateFileWrite(
                for: session,
                context: context,
                state: .notRegularFile
            )
        case .unreadable:
            exposeUnavailableIndeterminateFileWrite(
                for: session,
                context: context,
                state: .unreadable
            )
        }
    }

    private func exposeUnavailableIndeterminateFileWrite(
        for session: DocumentSession,
        context: IndeterminateSessionWriteContext,
        state: IndeterminateFileWriteReconciliationState
    ) {
        cancelAutosave(for: session)
        guard session === currentDocument else { return }
        externalChangePrompt = nil
        missingFilePrompt = nil
        indeterminateFileWriteReconciliationPrompt = IndeterminateFileWriteReconciliationPrompt(
            fileURL: context.location.fileURL,
            state: state
        )
    }
}
