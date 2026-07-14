import EditorKit
import Foundation
import MarkdownCore
import WorkspaceKit

@MainActor
extension AppState {
    /// Validates an already-loaded, authority-anchored file against every reusable App session
    /// without resolving either the workspace root or a cached session URL again.
    func prepareAnchoredFileSessionActivation(
        file: MarkdownFile,
        at location: WorkspaceFileSystemLocation,
        metadata: WorkspaceCoherentFileMetadata,
        sha256Digest: String
    ) throws -> PreparedAnchoredFileSessionActivation {
        let key = location.fileURL
        guard file.url == key else {
            throw AppStateError.invalidSessionIdentity(key)
        }
        let binding = AnchoredWorkspaceSessionFileBinding(
            location: location,
            identity: metadata.identity,
            sha256Digest: sha256Digest
        )

        if let cachedSession = sessionCache[key] {
            guard let cachedStateURL = sessionStateURL(for: cachedSession),
                  exactFileURLSpellingMatches(cachedStateURL, key)
            else {
                throw AppStateError.invalidSessionIdentity(key)
            }
            try validateReusableAnchoredSession(cachedSession, at: location)
            guard !detachedSessionURLs.contains(key) else {
                throw AppStateError.missingFile(key)
            }
            return PreparedAnchoredFileSessionActivation(
                canonicalURL: key,
                file: file,
                binding: binding,
                session: cachedSession,
                source: .cached
            )
        }

        let retiredMatches = retiredEditorDocumentBindings.compactMap { bindingID, retirement in
            guard !retirement.isAwaitingBindingEnd,
                  let retiredStateURL = sessionStateURL(for: retirement.session),
                  exactFileURLSpellingMatches(retiredStateURL, key)
            else {
                return nil as (EditorDocumentBindingID, RetiredEditorDocumentBinding)?
            }
            return (bindingID, retirement)
        }
        if retiredMatches.count == 1, let match = retiredMatches.first {
            try validateReusableAnchoredSession(match.1.session, at: location)
            return PreparedAnchoredFileSessionActivation(
                canonicalURL: key,
                file: file,
                binding: binding,
                session: match.1.session,
                source: .retired(bindingID: match.0)
            )
        }

        return PreparedAnchoredFileSessionActivation(
            canonicalURL: key,
            file: file,
            binding: binding,
            session: DocumentSession(
                text: file.text,
                url: file.url,
                fileKind: file.fileKind,
                isDirty: false
            ),
            source: .loaded
        )
    }

    private func validateReusableAnchoredSession(
        _ session: DocumentSession,
        at location: WorkspaceFileSystemLocation
    ) throws {
        let sessionIdentity = ObjectIdentifier(session)
        if let retainedBinding = anchoredSessionFileBindings[sessionIdentity],
           retainedBinding.location != location
        {
            throw AppStateError.invalidSessionIdentity(location.fileURL)
        }
        if let retainedContext = indeterminateSessionWriteContexts[sessionIdentity],
           retainedContext.location != location
        {
            throw AppStateError.invalidSessionIdentity(location.fileURL)
        }
    }

    /// Applies a fully validated activation without further throwing filesystem work. Reload
    /// commits this and its snapshot/authority/tree as one uninterrupted main-actor transaction.
    func commitAnchoredFileSessionActivation(
        _ activation: PreparedAnchoredFileSessionActivation
    ) {
        let key = activation.canonicalURL
        let session = activation.session
        anchoredSessionFileBindings[ObjectIdentifier(session)] = activation.binding
        unanchoredManagedSessionOwnershipProofs[ObjectIdentifier(session)] = nil

        switch activation.source {
        case .cached:
            if session !== currentDocument {
                cancelForegroundDocumentTasks()
                setCurrentDocument(session, synchronizingWorkspaceTree: false)
            }
            reconcileSession(session, withAnchoredFile: activation.file, canonicalURL: key)
            handleSessionAccess(url: key, isDirty: session.isDirty)

        case let .retired(bindingID):
            guard let retirement = retiredEditorDocumentBindings[bindingID],
                  retirement.session === session,
                  !retirement.isAwaitingBindingEnd
            else {
                preconditionFailure("Prepared retired reload activation changed before commit")
            }
            retiredEditorDocumentBindings[bindingID] = nil
            retirement.securityScopedAuthority?.stop()
            installAnchoredFileSession(
                session,
                activation: activation,
                recordsLoadedText: false,
                reconcilesExternalChange: true
            )

        case .loaded:
            installAnchoredFileSession(
                session,
                activation: activation,
                recordsLoadedText: true,
                reconcilesExternalChange: false
            )
        }
    }

    func activateAnchoredFileSession(
        at location: WorkspaceFileSystemLocation,
        expecting expectedIdentity: WorkspaceFileSystemIdentity? = nil
    ) throws {
        let result: MarkdownFileReadResult = if let expectedIdentity {
            try fileStore.load(at: location, expecting: expectedIdentity)
        } else {
            try fileStore.loadResult(at: location)
        }
        let activation = try prepareAnchoredFileSessionActivation(
            file: result.file,
            at: location,
            metadata: result.metadata,
            sha256Digest: result.sha256Digest
        )
        commitAnchoredFileSessionActivation(activation)
    }

    func proveSelectedRootStillNamesCapture(
        selectedRoot: URL,
        rootAuthority: WorkspaceFileSystemRootAuthority
    ) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask(priority: .utility) {
                try rootAuthority.proveSelectedSpellingNamesCapturedIdentity(
                    selectedRootURL: selectedRoot
                )
            }
            try await group.next()
        }
    }

    func prepareAnchoredWorkspaceReloadFile(
        rootAuthority: WorkspaceFileSystemRootAuthority,
        candidateURL: URL
    ) async throws -> PreparedWorkspaceReloadFile {
        let fileStore = fileStore
        return try await withThrowingTaskGroup(of: PreparedWorkspaceReloadFile.self) { group in
            group.addTask(priority: .utility) {
                try Task.checkCancellation()
                let location = try rootAuthority.canonicalizedLocation(
                    forFileURL: candidateURL
                )
                let result = try fileStore.loadResult(at: location)
                try Task.checkCancellation()
                return PreparedWorkspaceReloadFile(
                    location: location,
                    file: result.file,
                    metadata: result.metadata,
                    sha256Digest: result.sha256Digest
                )
            }
            defer { group.cancelAll() }
            guard let preparedFile = try await group.next() else {
                throw CancellationError()
            }
            return preparedFile
        }
    }

    private func installAnchoredFileSession(
        _ session: DocumentSession,
        activation: PreparedAnchoredFileSessionActivation,
        recordsLoadedText: Bool,
        reconcilesExternalChange: Bool
    ) {
        let key = activation.canonicalURL
        cancelForegroundDocumentTasks()
        sessionCache[key] = session
        detachedSessionURLs.remove(key)
        if let prompt = missingFilePrompt,
           exactFileURLSpellingMatches(prompt.fileURL, key)
        {
            missingFilePrompt = nil
        }
        if recordsLoadedText {
            recordKnownAnchoredDiskText(activation.file.text, canonicalURL: key)
        }
        setCurrentDocument(session, synchronizingWorkspaceTree: false)
        if reconcilesExternalChange {
            reconcileSession(session, withAnchoredFile: activation.file, canonicalURL: key)
        }
        handleSessionAccess(url: key, isDirty: session.isDirty)
    }

    private func reconcileSession(
        _ session: DocumentSession,
        withAnchoredFile file: MarkdownFile,
        canonicalURL: URL
    ) {
        let diskHash = Self.contentHash(file.text)
        if indeterminateSessionWrites[ObjectIdentifier(session)] != nil {
            pendingExternalTexts[canonicalURL] = file.text
            lastKnownDiskHashes[canonicalURL] = diskHash
            lastKnownDiskModificationDates[canonicalURL] = nil
            cancelAutosave(for: session)
            if session === currentDocument {
                missingFilePrompt = nil
                externalChangePrompt = ExternalChangePrompt(fileURL: canonicalURL)
            }
            return
        }
        guard lastKnownDiskHashes[canonicalURL] != diskHash else { return }

        if session.isDirty {
            pendingExternalTexts[canonicalURL] = file.text
            cancelAutosave(for: session)
            if session === currentDocument {
                missingFilePrompt = nil
                externalChangePrompt = ExternalChangePrompt(fileURL: canonicalURL)
            }
            return
        }

        pendingExternalTexts[canonicalURL] = nil
        session.reset(
            text: file.text,
            url: canonicalURL,
            fileKind: file.fileKind,
            isDirty: false
        )
        detachedSessionURLs.remove(canonicalURL)
        if session === currentDocument {
            missingFilePrompt = nil
        }
        lastKnownDiskHashes[canonicalURL] = diskHash
        lastKnownDiskModificationDates[canonicalURL] = nil
    }

    private func recordKnownAnchoredDiskText(_ text: String, canonicalURL: URL) {
        lastKnownDiskHashes[canonicalURL] = Self.contentHash(text)
        lastKnownDiskModificationDates[canonicalURL] = nil
    }

    func anchoredSessionFileBinding(
        for session: DocumentSession
    ) -> AnchoredWorkspaceSessionFileBinding? {
        anchoredSessionFileBindings[ObjectIdentifier(session)]
    }

    /// Authority retained for one session even when an indeterminate missing Save Copy has no
    /// readable destination from which to install a normal anchored binding. The context only
    /// identifies the session after it has been rehomed to that exact destination URL.
    func retainedAnchoredSessionLocation(
        for session: DocumentSession
    ) -> WorkspaceFileSystemLocation? {
        let sessionIdentity = ObjectIdentifier(session)
        if indeterminateSessionWrites[sessionIdentity] != nil,
           let context = indeterminateSessionWriteContexts[sessionIdentity]
        {
            return context.location
        }
        return anchoredSessionFileBindings[sessionIdentity]?.location
    }

    /// Exact App-state key for one session. Managed sessions use retained authority spelling and
    /// never resolve or standardize their mutable display URL again.
    func sessionStateURL(for session: DocumentSession) -> URL? {
        if let location = retainedAnchoredSessionLocation(for: session) {
            return location.fileURL
        }
        switch unanchoredManagedSessionOwnershipProofs[ObjectIdentifier(session)] {
        case let .proven(proof):
            return proof.location.fileURL
        case let .unavailable(fileURL):
            return fileURL
        case nil:
            return session.fileURL
        }
    }

    func recordKnownSessionDiskText(
        _ text: String,
        for session: DocumentSession,
        canonicalURL: URL
    ) {
        if anchoredSessionFileBinding(for: session) != nil {
            lastKnownDiskHashes[canonicalURL] = Self.contentHash(text)
            lastKnownDiskModificationDates[canonicalURL] = nil
        } else {
            recordKnownDiskText(text, for: canonicalURL)
        }
    }

    func handleAnchoredExternalChange(
        for session: DocumentSession,
        binding: AnchoredWorkspaceSessionFileBinding
    ) {
        let key = binding.location.fileURL
        switch WorkspaceNoFollowFileInspector.status(at: binding.location) {
        case .missing:
            markSessionDetachedFromMissingFile(session, url: key)
        case .regular:
            guard let result = try? fileStore.loadResult(at: binding.location) else { return }
            anchoredSessionFileBindings[ObjectIdentifier(session)] = AnchoredWorkspaceSessionFileBinding(
                location: binding.location,
                identity: result.metadata.identity,
                sha256Digest: result.sha256Digest
            )
            unanchoredManagedSessionOwnershipProofs[ObjectIdentifier(session)] = nil
            reconcileSession(session, withAnchoredFile: result.file, canonicalURL: key)
        case .symbolicLink, .notRegularFile, .unreadable:
            return
        }
    }
}

struct PreparedAnchoredFileSessionActivation {
    enum Source {
        case cached
        case retired(bindingID: EditorDocumentBindingID)
        case loaded
    }

    let canonicalURL: URL
    let file: MarkdownFile
    let binding: AnchoredWorkspaceSessionFileBinding
    let session: DocumentSession
    let source: Source
}

struct PreparedWorkspaceReloadFile {
    let location: WorkspaceFileSystemLocation
    let file: MarkdownFile
    let metadata: WorkspaceCoherentFileMetadata
    let sha256Digest: String
}

struct AnchoredWorkspaceSessionFileBinding: Equatable {
    let location: WorkspaceFileSystemLocation
    let identity: WorkspaceFileSystemIdentity
    let sha256Digest: String
}

struct IndeterminateSessionWriteContext: Equatable {
    let location: WorkspaceFileSystemLocation
    let preparedSHA256Digest: String
}
