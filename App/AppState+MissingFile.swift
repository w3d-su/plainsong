import AppKit
import Foundation
import MarkdownCore
import WorkspaceKit

@MainActor
extension AppState {
    func saveMissingFileCopy() {
        guard let prompt = missingFilePrompt else { return }

        let panel = NSSavePanel()
        panel.nameFieldStringValue = prompt.fileURL.lastPathComponent
        panel.directoryURL = prompt.fileURL.deletingLastPathComponent()
        panel.allowedContentTypes = Self.supportedContentTypes

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try saveDetachedCurrentDocument(to: url)
        } catch {
            present(error, title: "Could Not Save Copy")
        }
    }

    func closeMissingFile() {
        guard let prompt = missingFilePrompt else { return }
        let key = prompt.fileURL
        guard let currentStateURL = sessionStateURL(for: currentDocument),
              exactFileURLSpellingMatches(currentStateURL, key)
        else {
            missingFilePrompt = nil
            return
        }

        let closingSession = currentDocument
        let sessionIdentity = ObjectIdentifier(closingSession)
        if let indeterminate = indeterminateSessionWrites[sessionIdentity] {
            let retainedURL = indeterminateSessionWriteContexts[sessionIdentity]?.location.fileURL
                ?? prompt.fileURL
            present(
                MarkdownFileStoreError.writeRequiresReconciliation(
                    retainedURL,
                    indeterminate
                ),
                title: "Could Not Close File"
            )
            return
        }
        discardRetiredEditorDocumentSession(closingSession, canonicalURL: key)
        clearSessionState(for: closingSession, fallbackURL: key)
        currentDocument = DocumentSession()
        observeCurrentDocument()
    }

    func restoreRecoveryPrompt(for session: DocumentSession) {
        guard session === currentDocument else { return }
        guard let stateURL = sessionStateURL(for: session) else {
            externalChangePrompt = nil
            missingFilePrompt = nil
            indeterminateFileWriteReconciliationPrompt = nil
            return
        }

        if indeterminateSessionWrites[ObjectIdentifier(session)] != nil {
            refreshIndeterminateFileWriteReconciliation(for: session)
        } else if detachedSessionURLs.contains(stateURL) {
            externalChangePrompt = nil
            indeterminateFileWriteReconciliationPrompt = nil
            missingFilePrompt = MissingFilePrompt(fileURL: stateURL)
        } else if pendingExternalTexts[stateURL] != nil ||
            pendingExternalFileVersions[stateURL] != nil
        {
            missingFilePrompt = nil
            indeterminateFileWriteReconciliationPrompt = nil
            externalChangePrompt = ExternalChangePrompt(fileURL: stateURL)
            resolveDeferredExternalChangeIfPossible(for: session)
        } else {
            externalChangePrompt = nil
            missingFilePrompt = nil
            indeterminateFileWriteReconciliationPrompt = nil
        }
    }

    func clearPromptsNotMatchingCurrentDocument() {
        guard let url = sessionStateURL(for: currentDocument) else {
            externalChangePrompt = nil
            missingFilePrompt = nil
            indeterminateFileWriteReconciliationPrompt = nil
            return
        }

        if let prompt = externalChangePrompt,
           !exactFileURLSpellingMatches(prompt.fileURL, url)
        {
            externalChangePrompt = nil
        }
        if let prompt = missingFilePrompt,
           !exactFileURLSpellingMatches(prompt.fileURL, url)
        {
            missingFilePrompt = nil
        }
        if let prompt = indeterminateFileWriteReconciliationPrompt,
           !exactFileURLSpellingMatches(prompt.fileURL, url)
        {
            indeterminateFileWriteReconciliationPrompt = nil
        }
    }

    func saveDetachedCurrentDocument(to destinationURL: URL) throws {
        guard let oldURL = missingFilePrompt?.fileURL,
              let currentStateURL = sessionStateURL(for: currentDocument),
              exactFileURLSpellingMatches(currentStateURL, oldURL)
        else {
            return
        }

        let session = currentDocument
        let sessionIdentity = ObjectIdentifier(session)
        guard !isExternalSourceMutationFenced(for: session),
              externalDiskInspectionTasks[sessionIdentity] == nil
        else {
            throw AppStateError.unresolvedExternalChange(oldURL)
        }
        guard !hasPendingEditorSource(for: session) else {
            throw AppStateError.pendingEditorSource(oldURL)
        }
        let retirement = try validatedRetirementForSaveCopy(
            session: session,
            oldURL: oldURL
        )
        let text = session.text
        let saveCopyLocation = try workspaceSaveCopyLocation(
            for: destinationURL,
            session: session
        )
        let destination = saveCopyLocation.fileURL
        if let existingSession = sessionCache[destination], existingSession !== session {
            throw AppStateError.invalidSessionIdentity(destination)
        }
        let saveCopyInspection = try validateWorkspaceSaveCopyDestinationOwnership(
            at: saveCopyLocation,
            excluding: session
        )
        let destinationImageAssetAuthority =
            try prepareEditorImageAssetDocumentDestinationAuthority(
                at: saveCopyLocation
            )

        let anchoredBinding: AnchoredWorkspaceSessionFileBinding
        let preparedImageAssetAuthority: PreparedEditorImageAssetDocumentAuthority
        let cleanupResult: WorkspaceDurableFileWrite?
        let expectation = try workspaceSaveCopyExpectation(
            for: session,
            at: saveCopyLocation,
            initialInspection: saveCopyInspection
        )
        try destinationImageAssetAuthority.validateParentNamespaceBinding()
        let outcome = try performAnchoredFileSave(
            text: text,
            at: saveCopyLocation,
            expecting: expectation
        )
        switch outcome {
        case let .committedAndDurable(result):
            cleanupResult = result.cleanupState == .none ? nil : result
            preparedImageAssetAuthority = try bindCommittedSaveCopyAuthorityOrQuarantine(
                destinationAuthority: destinationImageAssetAuthority,
                durableResult: result,
                session: session,
                text: text,
                oldURL: oldURL,
                location: saveCopyLocation,
                retirement: retirement
            )
            anchoredBinding = AnchoredWorkspaceSessionFileBinding(
                location: saveCopyLocation,
                identity: result.metadata.identity,
                sha256Digest: WorkspaceSearchContentFingerprint(text: text).sha256Digest
            )
        case let .notCommitted(result):
            throw notCommittedFileWriteError(result, destinationURL: destination)
        case let .committedButIndeterminate(result):
            quarantineIndeterminateSaveCopy(
                session: session,
                text: text,
                oldURL: oldURL,
                location: saveCopyLocation,
                result: result,
                retirement: retirement
            )
            throw MarkdownFileStoreError.writeRequiresReconciliation(destination, result)
        }

        completeDetachedSaveCopy(CompletedDetachedSaveCopy(
            session: session,
            text: text,
            oldURL: oldURL,
            retirement: retirement,
            binding: anchoredBinding,
            preparedImageAssetAuthority: preparedImageAssetAuthority,
            cleanupResult: cleanupResult
        ))
    }
}

private struct CompletedDetachedSaveCopy {
    let session: DocumentSession
    let text: String
    let oldURL: URL
    let retirement: RetiredEditorDocumentSession?
    let binding: AnchoredWorkspaceSessionFileBinding
    let preparedImageAssetAuthority: PreparedEditorImageAssetDocumentAuthority
    let cleanupResult: WorkspaceDurableFileWrite?
}

@MainActor
private extension AppState {
    func bindCommittedSaveCopyAuthorityOrQuarantine(
        destinationAuthority: PreparedImageAssetDestinationAuthority,
        durableResult: WorkspaceDurableFileWrite,
        session: DocumentSession,
        text: String,
        oldURL: URL,
        location: WorkspaceFileSystemLocation,
        retirement: RetiredEditorDocumentSession?
    ) throws -> PreparedEditorImageAssetDocumentAuthority {
        do {
            return try destinationAuthority.bindWrittenDocument(
                expectedIdentity: durableResult.metadata.identity
            )
        } catch {
            let result = WorkspaceIndeterminateFileWrite(
                reason: (error as? WorkspaceAnchoredFileSystemError) ?? .namespaceChanged,
                preparedMetadata: durableResult.metadata,
                recoveryArtifact: durableResult.cleanupState
            )
            retainCommittedFileWriteCleanupNotice(
                durableResult,
                destinationURL: location.fileURL
            )
            quarantineIndeterminateSaveCopy(
                session: session,
                text: text,
                oldURL: oldURL,
                location: location,
                result: result,
                retirement: retirement
            )
            throw MarkdownFileStoreError.writeRequiresReconciliation(location.fileURL, result)
        }
    }

    func completeDetachedSaveCopy(_ completed: CompletedDetachedSaveCopy) {
        let destination = completed.binding.location.fileURL
        clearSessionState(
            for: completed.session,
            fallbackURL: completed.oldURL,
            removesEditorBindingRegistration: false
        )
        rehomeRetirement(
            completed.retirement,
            session: completed.session,
            from: completed.oldURL,
            to: destination
        )
        _ = advanceSessionLifecycle(for: completed.session)
        completed.session.markSaved(text: completed.text, url: destination)
        sessionCache[destination] = completed.session
        adoptAnchoredFileBinding(
            completed.binding,
            for: completed.session,
            preparedImageAssetAuthority: completed.preparedImageAssetAuthority,
            allowsImageAssetAuthorityBootstrap: true
        )
        lastKnownDiskHashes[destination] = Self.contentHash(completed.text)
        lastKnownDiskModificationDates[destination] = nil
        handleSessionAccess(url: destination, isDirty: false)
        rememberRecentItem(destination)
        restoreRecoveryPrompt(for: completed.session)
        finishRetiredEditorDocumentSessionIfPossible(for: completed.session)
        if let cleanupResult = completed.cleanupResult {
            presentCommittedFileWriteCleanup(cleanupResult, destinationURL: destination)
        }
    }

    func validatedRetirementForSaveCopy(
        session: DocumentSession,
        oldURL: URL
    ) throws -> RetiredEditorDocumentSession? {
        let retirement = retiredEditorDocumentSessions[oldURL]
        if let retirement {
            guard retirement.canonicalURL == oldURL,
                  retirement.session === session
            else {
                throw AppStateError.duplicateSessionOwnership(oldURL)
            }
            let liveInstallations = liveEditorDocumentBindingInstallations(for: session)
            guard retirement.awaitingInstallations == liveInstallations,
                  liveInstallations.allSatisfy({ installation in
                      retirement.bindingIDs.contains(installation.bindingID) &&
                          editorBindingInstallations[installation] === session &&
                          editorDocumentBindingSessions[installation.bindingID] === session
                  })
            else {
                throw AppStateError.invalidSessionIdentity(oldURL)
            }
        }
        if retiredEditorDocumentSessions.contains(where: { url, owner in
            !exactFileURLSpellingMatches(url, oldURL) && owner.session === session
        }) {
            throw AppStateError.duplicateSessionOwnership(oldURL)
        }
        return retirement
    }

    func rehomeRetirement(
        _ retirement: RetiredEditorDocumentSession?,
        session: DocumentSession,
        from oldURL: URL,
        to destination: URL
    ) {
        guard let retirement else { return }
        retiredEditorDocumentSessions[oldURL] = nil
        retiredEditorDocumentSessions[destination] = RetiredEditorDocumentSession(
            canonicalURL: destination,
            session: session,
            bindingIDs: retirement.bindingIDs,
            awaitingInstallations: retirement.awaitingInstallations,
            securityScopedAuthorityOwners: retirement.securityScopedAuthorityOwners
        )
    }

    func validateWorkspaceSaveCopyDestinationOwnership(
        at location: WorkspaceFileSystemLocation,
        excluding sourceSession: DocumentSession
    ) throws -> WorkspaceNoFollowFileTargetInspection {
        let inspection = try WorkspaceNoFollowFileInspector.inspectFileTarget(at: location)
        guard inspection.canonicalLocation == location else {
            // Keeping the request spelling as App state would split this session from the
            // scanner's descriptor-derived spelling after a case/normalization alias write.
            throw AppStateError.invalidSessionIdentity(location.fileURL)
        }

        let destinationIdentity: WorkspaceFileSystemIdentity? = switch inspection.state {
        case let .regular(identity): identity
        case .missing: nil
        }
        var inspectedSessions: Set<ObjectIdentifier> = []
        for candidate in workspaceSaveCopyOwnershipCandidates() {
            let sessionIdentity = ObjectIdentifier(candidate)
            guard inspectedSessions.insert(sessionIdentity).inserted else { continue }

            let binding = anchoredSessionFileBinding(for: candidate)
            let context = indeterminateSessionWriteContexts[sessionIdentity]
            let unanchoredProof: UnanchoredManagedSessionOwnershipProof? = if binding == nil,
                                                                              context == nil
            {
                unanchoredManagedSessionOwnershipProofs[sessionIdentity]
            } else {
                nil
            }
            let unanchoredProofValue: UnanchoredManagedSessionFileProof?
            switch unanchoredProof {
            case let .proven(proof):
                unanchoredProofValue = proof
            case .unavailable:
                throw AppStateError.invalidSessionIdentity(location.fileURL)
            case .none:
                guard binding != nil || context != nil else {
                    throw AppStateError.invalidSessionIdentity(location.fileURL)
                }
                unanchoredProofValue = nil
            }

            var retainedLocations: [WorkspaceFileSystemLocation] = []
            if let binding {
                retainedLocations.append(binding.location)
            }
            if let context {
                retainedLocations.append(context.location)
            }
            if let unanchoredProofValue {
                retainedLocations.append(contentsOf: unanchoredProofValue.retainedLocations)
            }
            let isExactMissingSourceRecovery = candidate === sourceSession &&
                destinationIdentity == nil &&
                retainedLocations.contains(location)
            guard !isExactMissingSourceRecovery else { continue }

            let ownsDestinationByLocation = retainedLocations.contains { retainedLocation in
                workspaceSaveCopyLocationsMayAlias(
                    retainedLocation,
                    location,
                    parentIsCaseSensitive: inspection.parentIsCaseSensitive
                )
            }
            let ownsDestinationByIdentity = destinationIdentity.map { destinationIdentity in
                binding?.identity == destinationIdentity ||
                    indeterminateSessionWrites[sessionIdentity]?.preparedMetadata?.identity ==
                    destinationIdentity ||
                    unanchoredProofValue?.identity == destinationIdentity
            } == true
            if ownsDestinationByLocation || ownsDestinationByIdentity {
                throw AppStateError.invalidSessionIdentity(location.fileURL)
            }
        }
        return inspection
    }

    func workspaceSaveCopyOwnershipCandidates() -> [DocumentSession] {
        var candidates = Array(sessionCache.values)
        candidates.append(contentsOf: retiredEditorDocumentSessions.values.map(\.session))
        candidates.append(contentsOf: editorDocumentBindingSessions.values)
        candidates.append(contentsOf: editorBindingInstallations.values)
        candidates.append(currentDocument)
        return candidates
    }

    func workspaceSaveCopyLocationsMayAlias(
        _ lhs: WorkspaceFileSystemLocation,
        _ rhs: WorkspaceFileSystemLocation,
        parentIsCaseSensitive: Bool
    ) -> Bool {
        if lhs.rootAuthority != rhs.rootAuthority {
            return workspaceSaveCopyFileURLsMayAlias(
                lhs.fileURL,
                rhs.fileURL,
                parentIsCaseSensitive: parentIsCaseSensitive
            )
        }
        let lhsKey = workspaceSaveCopyAliasKey(
            lhs.relativePath,
            parentIsCaseSensitive: parentIsCaseSensitive
        )
        let rhsKey = workspaceSaveCopyAliasKey(
            rhs.relativePath,
            parentIsCaseSensitive: parentIsCaseSensitive
        )
        return lhsKey.utf8.elementsEqual(rhsKey.utf8)
    }

    func workspaceSaveCopyAliasKey(
        _ relativePath: String,
        parentIsCaseSensitive: Bool
    ) -> String {
        let canonicallyNormalized = relativePath.precomposedStringWithCanonicalMapping
        guard !parentIsCaseSensitive else { return canonicallyNormalized }
        return canonicallyNormalized
            .folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .precomposedStringWithCanonicalMapping
    }

    func workspaceSaveCopyFileURLsMayAlias(
        _ lhs: URL,
        _ rhs: URL,
        parentIsCaseSensitive: Bool
    ) -> Bool {
        let lhsKey = workspaceSaveCopyAliasKey(
            lhs.path(percentEncoded: false),
            parentIsCaseSensitive: parentIsCaseSensitive
        )
        let rhsKey = workspaceSaveCopyAliasKey(
            rhs.path(percentEncoded: false),
            parentIsCaseSensitive: parentIsCaseSensitive
        )
        return lhsKey.utf8.elementsEqual(rhsKey.utf8)
    }

    func workspaceSaveCopyExpectation(
        for session: DocumentSession,
        at location: WorkspaceFileSystemLocation,
        initialInspection: WorkspaceNoFollowFileTargetInspection?
    ) throws -> WorkspaceNoFollowFileWriteExpectation {
        let sessionIdentity = ObjectIdentifier(session)
        if let indeterminate = indeterminateSessionWrites[sessionIdentity] {
            guard indeterminateSessionWriteContexts[sessionIdentity]?.location == location,
                  case .missing = initialInspection?.state
            else {
                throw MarkdownFileStoreError.writeRequiresReconciliation(
                    location.fileURL,
                    indeterminate
                )
            }
            return .missing
        }
        guard let initialInspection else {
            throw WorkspaceAnchoredFileSystemError.unreadable
        }
        return switch initialInspection.state {
        case let .regular(identity): .existing(identity)
        case .missing: .missing
        }
    }

    func quarantineIndeterminateSaveCopy(
        session: DocumentSession,
        text: String,
        oldURL: URL,
        location: WorkspaceFileSystemLocation,
        result: WorkspaceIndeterminateFileWrite,
        retirement: RetiredEditorDocumentSession?
    ) {
        let context = IndeterminateSessionWriteContext(
            location: location,
            preparedSHA256Digest: WorkspaceSearchContentFingerprint(text: text).sha256Digest
        )
        let sessionIdentity = ObjectIdentifier(session)
        clearSessionState(
            for: session,
            fallbackURL: oldURL,
            removesEditorBindingRegistration: false
        )
        rehomeRetirement(
            retirement,
            session: session,
            from: oldURL,
            to: context.location.fileURL
        )
        _ = advanceSessionLifecycle(for: session)
        indeterminateSessionWrites[sessionIdentity] = result
        indeterminateSessionWriteContexts[sessionIdentity] = context
        sessionCache[context.location.fileURL] = session
        session.reset(
            text: text,
            url: context.location.fileURL,
            fileKind: session.fileKind,
            isDirty: true
        )
        handleSessionAccess(url: context.location.fileURL, isDirty: true)
        cancelAutosave(for: session)
        refreshIndeterminateFileWriteReconciliation(for: session)
    }

    func workspaceSaveCopyLocation(
        for destinationURL: URL,
        session: DocumentSession
    ) throws -> WorkspaceFileSystemLocation {
        let sessionIdentity = ObjectIdentifier(session)
        if let indeterminate = indeterminateSessionWrites[sessionIdentity] {
            guard let context = indeterminateSessionWriteContexts[sessionIdentity],
                  exactFileURLSpellingMatches(destinationURL, context.location.fileURL),
                  WorkspaceNoFollowFileInspector.status(at: context.location) == .missing
            else {
                refreshIndeterminateFileWriteReconciliation(for: session)
                let reconciliationURL = indeterminateSessionWriteContexts[sessionIdentity]?
                    .location.fileURL ?? destinationURL
                throw MarkdownFileStoreError.writeRequiresReconciliation(
                    reconciliationURL,
                    indeterminate
                )
            }
            return context.location
        }
        return try workspaceSaveCopyLocation(for: destinationURL)
    }

    func workspaceSaveCopyLocation(
        for destinationURL: URL
    ) throws -> WorkspaceFileSystemLocation {
        guard workspaceRootURL != nil else {
            return try WorkspaceFileSystemLocation(fileURL: destinationURL)
        }
        guard let rootAuthority = workspaceSearchRootAuthority,
              workspaceInstalledCaptureGeneration == workspaceGeneration
        else {
            throw WorkspaceAnchoredFileSystemError.namespaceChanged
        }
        guard let relativePath = try? rootAuthority.relativePath(forFileURL: destinationURL) else {
            return try WorkspaceFileSystemLocation(fileURL: destinationURL)
        }
        return try rootAuthority.location(relativePath: relativePath)
    }
}
