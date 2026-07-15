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
                let preparedRead = try prepareEditorImageAssetDocumentRead(
                    fileStore: fileStore,
                    at: context.location
                )
                let observed = preparedRead.result
                let destination = context.location.fileURL
                // A readable destination is still unaccepted until the user chooses Reload or
                // Keep Mine. Stop any queued write before publishing its pending version.
                cancelAutosave(for: session)
                detachedSessionURLs.remove(destination)
                pendingExternalTexts[destination] = observed.file.text
                pendingExternalFileVersions[destination] = ObservedRetainedFileVersion(
                    location: context.location,
                    result: observed,
                    preparedImageAssetAuthority: preparedRead.preparedAuthority
                )
                lastKnownDiskHashes[destination] = Self.contentHash(observed.file.text)
                lastKnownDiskModificationDates[destination] = nil
                // The indeterminate destination is observable, but it is not accepted yet.
                // Retain the session's old binding/proof until Reload or Keep Mine adopts this
                // exact observation; `observeRetainedFileVersion` prioritizes the context
                // while the indeterminate fence remains active.
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
            clearExternalChangeConflict(at: destination)
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
