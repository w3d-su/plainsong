import EditorKit
import Foundation
import MarkdownCore
import WorkspaceKit

private struct ManagedSessionWriteContext {
    let sessionIdentity: ObjectIdentifier
    let stateURL: URL
    let location: WorkspaceFileSystemLocation
    let expectedIdentity: WorkspaceFileSystemIdentity
    let expectation: WorkspaceNoFollowFileWriteExpectation
}

extension AppState {
    /// `isSaving` is unpublished. A menu refresh during the write would see Save
    /// disabled, so the flag is cleared and the menu re-reads only after it returns.
    private func endSynchronousSave() {
        isSaving = false
        registry.noteMenuEnablementDidChange()
    }

    func save(session: DocumentSession) throws {
        try validateWorkspaceMutationRecoveryStoresLoaded(
            at: sessionStateURL(for: session) ?? session.fileURL
        )
        guard let writeContext = try managedSessionWriteContext(for: session) else { return }
        let sessionIdentity = writeContext.sessionIdentity
        let url = writeContext.stateURL
        guard !workspaceMutationWriteFences.contains(sessionIdentity),
              !indeterminateWorkspaceMutationSessions.contains(sessionIdentity)
        else {
            throw AppStateError.workspaceMutationInProgress(url)
        }
        guard !hasPendingEditorSource(for: session) else {
            throw AppStateError.pendingEditorSource(url)
        }
        if let indeterminate = indeterminateSessionWrites[sessionIdentity] {
            let reconciliationURL = indeterminateSessionWriteContexts[sessionIdentity]?.location.fileURL
                ?? url
            throw MarkdownFileStoreError.writeRequiresReconciliation(reconciliationURL, indeterminate)
        }
        let hasMatchingMissingPrompt = missingFilePrompt.map {
            exactFileURLSpellingMatches($0.fileURL, url)
        } ?? false
        guard !detachedSessionURLs.contains(url), !hasMatchingMissingPrompt else {
            throw AppStateError.missingFile(url)
        }
        let hasMatchingExternalChangePrompt = externalChangePrompt.map {
            exactFileURLSpellingMatches($0.fileURL, url)
        } ?? false
        guard pendingExternalTexts[url] == nil,
              pendingExternalFileVersions[url] == nil,
              !hasMatchingExternalChangePrompt,
              externalReloadTasks[sessionIdentity] == nil,
              pendingExternalReloadApplications[sessionIdentity] == nil,
              deferredExternalChangeResolutions[url] == nil,
              externalDiskInspectionTasks[sessionIdentity] == nil
        else {
            throw AppStateError.unresolvedExternalChange(url)
        }

        cancelAutosave(for: session)
        isSaving = true
        defer { endSynchronousSave() }

        let text = session.text
        // One digest for the binding, the indeterminate-write context and the disk-hash record.
        let textDigest = Self.contentHash(text)
        if hasConflictingPhysicalSessionOwnership(
            writeContext.expectedIdentity,
            excluding: session
        ) {
            throw AppStateError.duplicateSessionOwnership(url)
        }
        let destination = writeContext.location.fileURL
        let outcome = try performAnchoredFileSave(
            text: text,
            at: writeContext.location,
            expecting: writeContext.expectation
        )
        let cleanupResult: WorkspaceDurableFileWrite?
        switch outcome {
        case let .committedAndDurable(result):
            cleanupResult = result.cleanupState == .none ? nil : result
            indeterminateSessionWrites[sessionIdentity] = nil
            indeterminateSessionWriteContexts[sessionIdentity] = nil
            let preparedImageAssetAuthority =
                rebindEditorImageAssetDocumentAuthorityAfterSave(
                    for: session,
                    location: writeContext.location,
                    replacing: writeContext.expectedIdentity,
                    with: result.metadata.identity
                )
            adoptAnchoredFileBinding(
                AnchoredWorkspaceSessionFileBinding(
                    location: writeContext.location,
                    identity: result.metadata.identity,
                    sha256Digest: textDigest
                ),
                for: session,
                preparedImageAssetAuthority: preparedImageAssetAuthority
            )
        case let .notCommitted(result):
            handleExternalWritePreconditionFailure(result, for: session)
            throw notCommittedFileWriteError(result, destinationURL: destination)
        case let .committedButIndeterminate(result):
            indeterminateSessionWrites[sessionIdentity] = result
            indeterminateSessionWriteContexts[sessionIdentity] = IndeterminateSessionWriteContext(
                location: writeContext.location,
                preparedSHA256Digest: textDigest
            )
            cancelAutosave(for: session)
            refreshIndeterminateFileWriteReconciliation(for: session)
            throw MarkdownFileStoreError.writeRequiresReconciliation(destination, result)
        }
        session.markSaved(text: text, url: destination)
        _ = clearWorkspaceMutationTextRecovery(for: session)
        sessionPolicy.updateDirtyState(for: destination, isDirty: false)
        detachedSessionURLs.remove(destination)
        lastKnownDiskHashes[destination] = textDigest
        lastKnownDiskModificationDates[destination] = nil
        if let cleanupResult {
            presentCommittedFileWriteCleanup(cleanupResult, destinationURL: destination)
        }
    }

    private func managedSessionWriteContext(
        for session: DocumentSession
    ) throws -> ManagedSessionWriteContext? {
        guard session.fileURL != nil else { return nil }
        let sessionIdentity = ObjectIdentifier(session)
        if let binding = anchoredSessionFileBinding(for: session) {
            return ManagedSessionWriteContext(
                sessionIdentity: sessionIdentity,
                stateURL: binding.location.fileURL,
                location: binding.location,
                expectedIdentity: binding.identity,
                expectation: .existingContent(
                    binding.identity,
                    sha256Digest: binding.sha256Digest
                )
            )
        }
        if case let .proven(proof)? =
            unanchoredManagedSessionOwnershipProofs[sessionIdentity]
        {
            return ManagedSessionWriteContext(
                sessionIdentity: sessionIdentity,
                stateURL: proof.location.fileURL,
                location: proof.location,
                expectedIdentity: proof.identity,
                expectation: .existingContent(
                    proof.identity,
                    sha256Digest: proof.sha256Digest
                )
            )
        }
        guard let stateURL = sessionStateURL(for: session) else { return nil }
        throw AppStateError.invalidSessionIdentity(stateURL)
    }

    func performAnchoredFileSave(
        text: String,
        at location: WorkspaceFileSystemLocation,
        expecting expectation: WorkspaceNoFollowFileWriteExpectation
    ) throws -> WorkspaceFileWriteOutcome {
        if let anchoredFileSaveOverride {
            return try anchoredFileSaveOverride(text, location, expectation)
        }
        return try fileStore.save(text: text, at: location, expecting: expectation)
    }

    func notCommittedFileWriteError(
        _ result: WorkspaceNotCommittedFileWrite,
        destinationURL: URL
    ) -> MarkdownFileStoreError {
        if result.artifactState != .none {
            retainFileWriteArtifactNotice(
                destinationURL: destinationURL,
                destinationWasCommitted: false,
                artifactState: result.artifactState
            )
        }
        return .notCommitted(result, destinationURL: destinationURL)
    }

    /// A typed writer precondition can discover the same external B version before an FSEvent
    /// reaches `handleExternalChange`. Treat identity/content disagreement as the session-scoped
    /// arbitration event, not merely an unwritable save: one fresh retained-authority
    /// observation records the conflict and preserves A's proof.
    private func handleExternalWritePreconditionFailure(
        _ result: WorkspaceNotCommittedFileWrite,
        for session: DocumentSession
    ) {
        switch result.reason {
        case .changedIdentity, .changedContent:
            handleExternalChange(for: session)
        default:
            break
        }
    }

    func presentCommittedFileWriteCleanup(
        _ result: WorkspaceDurableFileWrite,
        destinationURL: URL
    ) {
        guard result.cleanupState != .none else { return }
        retainCommittedFileWriteCleanupNotice(
            result,
            destinationURL: destinationURL
        )
        present(
            MarkdownFileStoreError.committedWithCleanupRequired(destinationURL, result),
            title: "File Saved; Cleanup Required"
        )
    }

    func retainCommittedFileWriteCleanupNotice(
        _ result: WorkspaceDurableFileWrite,
        destinationURL: URL
    ) {
        guard result.cleanupState != .none else { return }
        retainFileWriteArtifactNotice(
            destinationURL: destinationURL,
            destinationWasCommitted: true,
            artifactState: result.cleanupState
        )
    }

    private func retainFileWriteArtifactNotice(
        destinationURL: URL,
        destinationWasCommitted: Bool,
        artifactState: WorkspaceFileWriteArtifactState
    ) {
        guard artifactState != .none else { return }
        let notice = FileWriteArtifactNotice(
            destinationURL: destinationURL.standardizedFileURL,
            destinationWasCommitted: destinationWasCommitted,
            artifactState: artifactState
        )
        guard !fileWriteArtifactNotices.contains(notice) else { return }
        fileWriteArtifactNotices.append(notice)
        KeyWindowRouter.shared.routeNotice(notice.id, owner: self)
    }

    /// Acknowledges one retained cleanup artifact without mutating the artifact itself. Removing
    /// the notice also releases the notice's exact filesystem authority when no other owner needs it.
    func acknowledgeFileWriteArtifactNotice(id: FileWriteArtifactNotice.ID) {
        fileWriteArtifactNotices.removeAll { $0.id == id }
        KeyWindowRouter.shared.forgetNotice(id)
    }

    func cancelForegroundDocumentTasks() {
        autosaveTask?.cancel()
        autosaveTask = nil
        statisticsTask?.cancel()
        statisticsTask = nil
    }

    func moveCurrentDocumentWorkToBackgroundBeforeSwitch() {
        let previousSession = shownSession
        moveCurrentAutosaveToBackground(for: previousSession)
        moveCurrentStatisticsToBackground(for: previousSession)
    }
}
