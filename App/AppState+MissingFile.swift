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
        let key = prompt.fileURL.standardizedFileURL
        guard currentDocument.fileURL?.standardizedFileURL == key else {
            missingFilePrompt = nil
            return
        }

        let closingSession = currentDocument
        clearSessionState(for: closingSession, fallbackURL: key)
        currentDocument = DocumentSession()
        observeCurrentDocument()
    }

    func clearPromptsNotMatchingCurrentDocument() {
        guard let url = currentDocument.fileURL?.standardizedFileURL else {
            externalChangePrompt = nil
            missingFilePrompt = nil
            return
        }

        if externalChangePrompt?.fileURL.standardizedFileURL != url {
            externalChangePrompt = nil
        }
        if missingFilePrompt?.fileURL.standardizedFileURL != url {
            missingFilePrompt = nil
        }
    }

    func saveDetachedCurrentDocument(to destinationURL: URL) throws {
        guard let oldURL = missingFilePrompt?.fileURL.standardizedFileURL,
              currentDocument.fileURL?.standardizedFileURL == oldURL
        else {
            return
        }

        let session = currentDocument
        let text = session.text
        let workspaceLocation = try workspaceSaveCopyLocation(
            for: destinationURL,
            session: session
        )
        let destination = workspaceLocation?.fileURL
            ?? destinationURL.standardizedFileURL.resolvingSymlinksInPath()
        if let existingSession = sessionCache[destination], existingSession !== session {
            throw AppStateError.invalidSessionIdentity(destination)
        }
        if let workspaceLocation {
            try validateWorkspaceSaveCopyDestinationOwnership(
                for: session,
                at: workspaceLocation
            )
        }

        let anchoredBinding: AnchoredWorkspaceSessionFileBinding?
        let cleanupResult: WorkspaceDurableFileWrite?
        if let workspaceLocation {
            let expectation = try workspaceSaveCopyExpectation(
                for: session,
                text: text,
                oldURL: oldURL,
                at: workspaceLocation
            )
            let outcome = try performAnchoredFileSave(
                text: text,
                at: workspaceLocation,
                expecting: expectation
            )
            switch outcome {
            case let .committedAndDurable(result):
                cleanupResult = result.cleanupState == .none ? nil : result
                anchoredBinding = AnchoredWorkspaceSessionFileBinding(
                    location: workspaceLocation,
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
                    location: workspaceLocation,
                    result: result
                )
                throw MarkdownFileStoreError.writeRequiresReconciliation(destination, result)
            }
        } else {
            cleanupResult = try performLegacyFileSave(text: text, to: destination)
            anchoredBinding = nil
        }

        clearSessionState(
            for: session,
            fallbackURL: oldURL,
            removesEditorBindingRegistration: false
        )
        session.markSaved(text: text, url: destination)
        sessionCache[destination] = session
        if let anchoredBinding {
            anchoredSessionFileBindings[ObjectIdentifier(session)] = anchoredBinding
            lastKnownDiskHashes[destination] = Self.contentHash(text)
            lastKnownDiskModificationDates[destination] = nil
        } else {
            recordKnownDiskText(text, for: destination)
        }
        handleSessionAccess(url: destination, isDirty: false)
        rememberRecentItem(destination)
        if let cleanupResult {
            presentCommittedFileWriteCleanup(cleanupResult, destinationURL: destination)
        }
    }

    private func validateWorkspaceSaveCopyDestinationOwnership(
        for sourceSession: DocumentSession,
        at location: WorkspaceFileSystemLocation
    ) throws {
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
        for candidate in workspaceSaveCopyOwnershipCandidates() where candidate !== sourceSession {
            let sessionIdentity = ObjectIdentifier(candidate)
            guard inspectedSessions.insert(sessionIdentity).inserted else { continue }

            let binding = anchoredSessionFileBinding(for: candidate)
            let context = indeterminateSessionWriteContexts[sessionIdentity]
            let ownsDestinationByLocation = binding.map { binding in
                workspaceSaveCopyLocationsMayAlias(
                    binding.location,
                    location,
                    parentIsCaseSensitive: inspection.parentIsCaseSensitive
                )
            } == true || context.map { context in
                workspaceSaveCopyLocationsMayAlias(
                    context.location,
                    location,
                    parentIsCaseSensitive: inspection.parentIsCaseSensitive
                )
            } == true
            let ownsDestinationByIdentity = destinationIdentity.map { destinationIdentity in
                binding?.identity == destinationIdentity
                    || indeterminateSessionWrites[sessionIdentity]?.preparedMetadata?.identity
                    == destinationIdentity
            } == true
            let unanchoredURLMayAlias = binding == nil && context == nil
                && workspaceSaveCopySessionURL(
                    candidate,
                    mayAlias: location,
                    parentIsCaseSensitive: inspection.parentIsCaseSensitive
                )
            let ownsDestination = ownsDestinationByLocation
                || ownsDestinationByIdentity
                || unanchoredURLMayAlias
            if ownsDestination {
                throw AppStateError.invalidSessionIdentity(location.fileURL)
            }
        }
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

    private func workspaceSaveCopySessionURL(
        _ session: DocumentSession,
        mayAlias location: WorkspaceFileSystemLocation,
        parentIsCaseSensitive: Bool
    ) -> Bool {
        guard let fileURL = session.fileURL?.standardizedFileURL,
              let relativePath = try? location.rootAuthority.relativePath(forFileURL: fileURL),
              let sessionLocation = try? location.rootAuthority.location(relativePath: relativePath)
        else {
            return false
        }
        return workspaceSaveCopyLocationsMayAlias(
            sessionLocation,
            location,
            parentIsCaseSensitive: parentIsCaseSensitive
        )
    }

    private func workspaceSaveCopyLocationsMayAlias(
        _ lhs: WorkspaceFileSystemLocation,
        _ rhs: WorkspaceFileSystemLocation,
        parentIsCaseSensitive: Bool
    ) -> Bool {
        guard lhs.rootAuthority == rhs.rootAuthority else { return false }
        return workspaceSaveCopyAliasKey(
            lhs.relativePath,
            parentIsCaseSensitive: parentIsCaseSensitive
        ) == workspaceSaveCopyAliasKey(
            rhs.relativePath,
            parentIsCaseSensitive: parentIsCaseSensitive
        )
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

    private func workspaceSaveCopyExpectation(
        for session: DocumentSession,
        text: String,
        oldURL: URL,
        at location: WorkspaceFileSystemLocation
    ) throws -> WorkspaceNoFollowFileWriteExpectation {
        let sessionIdentity = ObjectIdentifier(session)
        guard let indeterminate = indeterminateSessionWrites[sessionIdentity] else {
            return .existingOrMissing
        }
        guard let context = indeterminateSessionWriteContexts[sessionIdentity],
              context.location == location
        else {
            throw MarkdownFileStoreError.writeRequiresReconciliation(
                location.fileURL,
                indeterminate
            )
        }

        switch WorkspaceNoFollowFileInspector.status(at: location) {
        case .missing:
            // A deliberate retry remains exclusive. If the uncertain first commit appears before
            // publish, the writer reports non-commit instead of replacing it.
            return .missing
        case .regular:
            if let observed = try? fileStore.loadResult(at: location) {
                rehomeIndeterminateSaveCopy(
                    session: session,
                    text: text,
                    oldURL: oldURL,
                    observed: observed,
                    context: context,
                    result: indeterminate
                )
                throw MarkdownFileStoreError.writeRequiresReconciliation(
                    location.fileURL,
                    indeterminate
                )
            }
            return try exactPreparedSaveCopyExpectation(
                result: indeterminate,
                context: context,
                destination: location.fileURL
            )
        case .symbolicLink, .notRegularFile, .unreadable:
            return try exactPreparedSaveCopyExpectation(
                result: indeterminate,
                context: context,
                destination: location.fileURL
            )
        }
    }

    private func exactPreparedSaveCopyExpectation(
        result: WorkspaceIndeterminateFileWrite,
        context: IndeterminateSessionWriteContext,
        destination: URL
    ) throws -> WorkspaceNoFollowFileWriteExpectation {
        guard let preparedMetadata = result.preparedMetadata else {
            throw MarkdownFileStoreError.writeRequiresReconciliation(destination, result)
        }
        return .existingContent(
            preparedMetadata.identity,
            sha256Digest: context.preparedSHA256Digest
        )
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
        if let observed = try? fileStore.loadResult(at: location) {
            rehomeIndeterminateSaveCopy(
                session: session,
                text: text,
                oldURL: oldURL,
                observed: observed,
                context: context,
                result: result
            )
            return
        }

        if WorkspaceNoFollowFileInspector.status(at: location) == .missing {
            rehomeMissingIndeterminateSaveCopy(
                session: session,
                text: text,
                oldURL: oldURL,
                context: context,
                result: result
            )
            return
        }

        let sessionIdentity = ObjectIdentifier(session)
        indeterminateSessionWrites[sessionIdentity] = result
        indeterminateSessionWriteContexts[sessionIdentity] = context
        cancelAutosave(for: session)
    }

    private func rehomeIndeterminateSaveCopy(
        session: DocumentSession,
        text: String,
        oldURL: URL,
        observed: MarkdownFileReadResult,
        context: IndeterminateSessionWriteContext,
        result: WorkspaceIndeterminateFileWrite
    ) {
        let destination = context.location.fileURL
        let sessionIdentity = ObjectIdentifier(session)
        clearSessionState(
            for: session,
            fallbackURL: oldURL,
            removesEditorBindingRegistration: false
        )
        indeterminateSessionWrites[sessionIdentity] = result
        indeterminateSessionWriteContexts[sessionIdentity] = context
        anchoredSessionFileBindings[sessionIdentity] = AnchoredWorkspaceSessionFileBinding(
            location: context.location,
            identity: observed.metadata.identity,
            sha256Digest: observed.sha256Digest
        )
        sessionCache[destination] = session
        detachedSessionURLs.remove(destination)
        pendingExternalTexts[destination] = observed.file.text
        lastKnownDiskHashes[destination] = Self.contentHash(observed.file.text)
        lastKnownDiskModificationDates[destination] = nil
        session.reset(
            text: text,
            url: destination,
            fileKind: observed.file.fileKind,
            isDirty: true
        )
        handleSessionAccess(url: destination, isDirty: true)
        cancelAutosave(for: session)
        if session === currentDocument {
            missingFilePrompt = nil
            externalChangePrompt = ExternalChangePrompt(fileURL: destination)
        }
    }

    private func rehomeMissingIndeterminateSaveCopy(
        session: DocumentSession,
        text: String,
        oldURL: URL,
        context: IndeterminateSessionWriteContext,
        result: WorkspaceIndeterminateFileWrite
    ) {
        let destination = context.location.fileURL
        let sessionIdentity = ObjectIdentifier(session)
        clearSessionState(
            for: session,
            fallbackURL: oldURL,
            removesEditorBindingRegistration: false
        )
        indeterminateSessionWrites[sessionIdentity] = result
        indeterminateSessionWriteContexts[sessionIdentity] = context
        sessionCache[destination] = session
        session.reset(
            text: text,
            url: destination,
            fileKind: session.fileKind,
            isDirty: true
        )
        handleSessionAccess(url: destination, isDirty: true)
        markSessionDetachedFromMissingFile(session, url: destination)
    }

    private func workspaceSaveCopyLocation(
        for destinationURL: URL,
        session: DocumentSession
    ) throws -> WorkspaceFileSystemLocation? {
        let sessionIdentity = ObjectIdentifier(session)
        if let indeterminate = indeterminateSessionWrites[sessionIdentity] {
            guard let context = indeterminateSessionWriteContexts[sessionIdentity] else {
                throw MarkdownFileStoreError.writeRequiresReconciliation(
                    destinationURL.standardizedFileURL,
                    indeterminate
                )
            }
            let destinationURL = destinationURL.standardizedFileURL
            let denotesQuarantinedDestination = context.location.fileURL == destinationURL
                || (try? context.location.rootAuthority.relativePath(
                    forFileURL: destinationURL
                )) == context.location.relativePath
            if denotesQuarantinedDestination {
                return context.location
            }
            // A different spelling can still denote the same directory entry on a
            // case-insensitive or normalization-insensitive volume. Until reconciliation
            // clears the exact quarantine, never downgrade a Save Copy to a broad write.
            throw MarkdownFileStoreError.writeRequiresReconciliation(
                context.location.fileURL,
                indeterminate
            )
        }
        return try workspaceSaveCopyLocation(for: destinationURL)
    }

    private func workspaceSaveCopyLocation(
        for destinationURL: URL
    ) throws -> WorkspaceFileSystemLocation? {
        guard workspaceRootURL != nil else { return nil }
        guard let rootAuthority = workspaceSearchRootAuthority,
              workspaceInstalledCaptureGeneration == workspaceGeneration
        else {
            throw WorkspaceAnchoredFileSystemError.namespaceChanged
        }
        guard let relativePath = try? rootAuthority.relativePath(forFileURL: destinationURL) else {
            return nil
        }
        return try rootAuthority.location(relativePath: relativePath)
    }
}
