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
        clearSessionState(for: closingSession, fallbackURL: key)
        currentDocument = DocumentSession()
        observeCurrentDocument()
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

        let anchoredBinding: AnchoredWorkspaceSessionFileBinding
        let cleanupResult: WorkspaceDurableFileWrite?
        let expectation = try workspaceSaveCopyExpectation(
            for: session,
            at: saveCopyLocation,
            initialInspection: saveCopyInspection
        )
        let outcome = try performAnchoredFileSave(
            text: text,
            at: saveCopyLocation,
            expecting: expectation
        )
        switch outcome {
        case let .committedAndDurable(result):
            cleanupResult = result.cleanupState == .none ? nil : result
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
                result: result
            )
            throw MarkdownFileStoreError.writeRequiresReconciliation(destination, result)
        }

        clearSessionState(
            for: session,
            fallbackURL: oldURL,
            removesEditorBindingRegistration: false
        )
        session.markSaved(text: text, url: destination)
        sessionCache[destination] = session
        anchoredSessionFileBindings[ObjectIdentifier(session)] = anchoredBinding
        unanchoredManagedSessionOwnershipProofs[ObjectIdentifier(session)] = nil
        lastKnownDiskHashes[destination] = Self.contentHash(text)
        lastKnownDiskModificationDates[destination] = nil
        handleSessionAccess(url: destination, isDirty: false)
        rememberRecentItem(destination)
        if let cleanupResult {
            presentCommittedFileWriteCleanup(cleanupResult, destinationURL: destination)
        }
    }

    private func validateWorkspaceSaveCopyDestinationOwnership(
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
            let isExactMissingSourceRecovery = candidate === sourceSession
                && destinationIdentity == nil
                && retainedLocations.contains(location)
            guard !isExactMissingSourceRecovery else { continue }

            let ownsDestinationByLocation = retainedLocations.contains { retainedLocation in
                workspaceSaveCopyLocationsMayAlias(
                    retainedLocation,
                    location,
                    parentIsCaseSensitive: inspection.parentIsCaseSensitive
                )
            }
            let ownsDestinationByIdentity = destinationIdentity.map { destinationIdentity in
                binding?.identity == destinationIdentity
                    || indeterminateSessionWrites[sessionIdentity]?.preparedMetadata?.identity
                    == destinationIdentity
                    || unanchoredProofValue?.identity == destinationIdentity
            } == true
            let ownsDestination = ownsDestinationByLocation
                || ownsDestinationByIdentity
            if ownsDestination {
                throw AppStateError.invalidSessionIdentity(location.fileURL)
            }
        }
        return inspection
    }

    private func workspaceSaveCopyOwnershipCandidates() -> [DocumentSession] {
        var candidates = Array(sessionCache.values)
        candidates.append(contentsOf: retiredEditorDocumentBindings.values.map(\.session))
        candidates.append(contentsOf: editorDocumentBindingSessions.values)
        candidates.append(currentDocument)
        if let installedSession = installedEditorDocumentBindingLease?.session {
            candidates.append(installedSession)
        }
        return candidates
    }

    private func workspaceSaveCopyLocationsMayAlias(
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

    private func workspaceSaveCopyAliasKey(
        _ relativePath: String,
        parentIsCaseSensitive: Bool
    ) -> String {
        let canonicallyNormalized = relativePath.precomposedStringWithCanonicalMapping
        guard !parentIsCaseSensitive else { return canonicallyNormalized }
        return canonicallyNormalized
            .folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .precomposedStringWithCanonicalMapping
    }

    private func workspaceSaveCopyFileURLsMayAlias(
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

    private func workspaceSaveCopyExpectation(
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

    private func quarantineIndeterminateSaveCopy(
        session: DocumentSession,
        text: String,
        oldURL: URL,
        location: WorkspaceFileSystemLocation,
        result: WorkspaceIndeterminateFileWrite
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

    private func workspaceSaveCopyLocation(
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

    private func workspaceSaveCopyLocation(
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
