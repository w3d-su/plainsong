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
        sha256Digest: String,
        preparedImageAssetAuthority: PreparedEditorImageAssetDocumentAuthority? = nil,
        excludingRecoveryID: UUID? = nil
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

        // A URL-keyed conflict/detachment fence remains owned by its retained A authority. A
        // candidate B that merely reuses A's lexical spelling must fail before it can fall
        // through to a newly loaded session and erase or inherit that state.
        guard !hasStatefulRetainedAuthorityCollision(
            at: key,
            candidateLocation: location,
            excludingRecoveryID: excludingRecoveryID
        ) else {
            throw AppStateError.invalidSessionIdentity(key)
        }

        if let cachedSession = sessionCache[key] {
            guard let cachedStateURL = sessionStateURL(for: cachedSession),
                  exactFileURLSpellingMatches(cachedStateURL, key)
            else {
                throw AppStateError.invalidSessionIdentity(key)
            }
            try validateReusableAnchoredSession(cachedSession, at: location)
            return PreparedAnchoredFileSessionActivation(
                canonicalURL: key,
                file: file,
                binding: binding,
                session: cachedSession,
                source: .cached,
                preparedImageAssetAuthority: preparedImageAssetAuthority
            )
        }

        let retiredMatches = retiredEditorDocumentSessions.compactMap { canonicalURL, retirement in
            guard let retiredStateURL = sessionStateURL(for: retirement.session),
                  exactFileURLSpellingMatches(retiredStateURL, key)
            else {
                return nil as (URL, RetiredEditorDocumentSession)?
            }
            return (canonicalURL, retirement)
        }
        if retiredMatches.count == 1, let match = retiredMatches.first {
            try validateReusableAnchoredSession(match.1.session, at: location)
            return PreparedAnchoredFileSessionActivation(
                canonicalURL: key,
                file: file,
                binding: binding,
                session: match.1.session,
                source: .retired(canonicalURL: match.0),
                preparedImageAssetAuthority: preparedImageAssetAuthority
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
            source: .loaded,
            preparedImageAssetAuthority: preparedImageAssetAuthority
        )
    }

    private func validateReusableAnchoredSession(
        _ session: DocumentSession,
        at location: WorkspaceFileSystemLocation
    ) throws {
        let sessionIdentity = ObjectIdentifier(session)
        guard !indeterminateWorkspaceMutationSessions.contains(sessionIdentity) else {
            throw AppStateError.invalidSessionIdentity(location.fileURL)
        }
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
        let observation = ObservedRetainedFileVersion(
            location: activation.binding.location,
            file: activation.file,
            identity: activation.binding.identity,
            sha256Digest: activation.binding.sha256Digest,
            preparedImageAssetAuthority: activation.preparedImageAssetAuthority
        )

        switch activation.source {
        case .cached:
            if session !== currentDocument {
                cancelForegroundDocumentTasks()
                setCurrentDocument(session, synchronizingWorkspaceTree: false)
            }
            guard reconcileObservedRetainedFileVersion(
                observation,
                for: session,
                canonicalURL: key
            ) else {
                handleSessionAccess(url: key, isDirty: session.isDirty)
                return
            }
            adoptAnchoredFileBinding(
                activation.binding,
                for: session,
                preparedImageAssetAuthority: activation.preparedImageAssetAuthority
            )
            handleSessionAccess(url: key, isDirty: session.isDirty)

        case let .retired(canonicalURL):
            guard let retirement = retiredEditorDocumentSessions[canonicalURL],
                  retirement.session === session
            else {
                preconditionFailure("Prepared retired reload activation changed before commit")
            }
            let sessionIdentity = ObjectIdentifier(session)
            let shouldRestartInspection = externalDiskInspectionTasks[sessionIdentity] != nil
            _ = advanceSessionLifecycle(for: session)
            let accepted = installAnchoredFileSession(
                session,
                activation: activation,
                recordsLoadedText: false,
                reconcilesExternalChange: true
            )
            guard accepted else {
                if shouldRestartInspection {
                    externalDiskInspectionTasks.removeValue(
                        forKey: sessionIdentity
                    )?.task.cancel()
                }
                return
            }
            if shouldRestartInspection ||
                deferredExternalChangeResolutions[key] != nil
            {
                handleExternalChange(for: session, advancingDiskEvent: false)
            }
            finishRetiredEditorDocumentSessionIfPossible(for: session)

        case .loaded:
            _ = installAnchoredFileSession(
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
        let preparedRead = try prepareEditorImageAssetDocumentRead(
            fileStore: fileStore,
            at: location,
            expecting: expectedIdentity
        )
        let result = preparedRead.result
        let activation = try prepareAnchoredFileSessionActivation(
            file: result.file,
            at: location,
            metadata: result.metadata,
            sha256Digest: result.sha256Digest,
            preparedImageAssetAuthority: preparedRead.preparedAuthority
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
                let preparedRead = try prepareEditorImageAssetDocumentRead(
                    fileStore: fileStore,
                    at: location
                )
                let result = preparedRead.result
                try Task.checkCancellation()
                return PreparedWorkspaceReloadFile(
                    location: location,
                    file: result.file,
                    metadata: result.metadata,
                    sha256Digest: result.sha256Digest,
                    preparedImageAssetAuthority: preparedRead.preparedAuthority
                )
            }
            defer { group.cancelAll() }
            guard let preparedFile = try await group.next() else {
                throw CancellationError()
            }
            return preparedFile
        }
    }

    @discardableResult
    private func installAnchoredFileSession(
        _ session: DocumentSession,
        activation: PreparedAnchoredFileSessionActivation,
        recordsLoadedText: Bool,
        reconcilesExternalChange: Bool
    ) -> Bool {
        let key = activation.canonicalURL
        moveCurrentDocumentWorkToBackgroundForAnchoredActivation(session)
        sessionCache[key] = session
        if !reconcilesExternalChange {
            clearMissingFileActivationFence(at: key)
        }
        if recordsLoadedText {
            recordKnownAnchoredDiskText(activation.file.text, canonicalURL: key)
        }
        setCurrentDocument(session, synchronizingWorkspaceTree: false)
        let observation = ObservedRetainedFileVersion(
            location: activation.binding.location,
            file: activation.file,
            identity: activation.binding.identity,
            sha256Digest: activation.binding.sha256Digest,
            preparedImageAssetAuthority: activation.preparedImageAssetAuthority
        )
        if reconcilesExternalChange {
            guard reconcileObservedRetainedFileVersion(
                observation,
                for: session,
                canonicalURL: key
            ) else {
                handleSessionAccess(url: key, isDirty: session.isDirty)
                return false
            }
            clearMissingFileActivationFence(at: key)
        }
        adoptAnchoredFileBinding(
            activation.binding,
            for: session,
            preparedImageAssetAuthority: activation.preparedImageAssetAuthority
        )
        handleSessionAccess(url: key, isDirty: session.isDirty)
        return true
    }

    private func moveCurrentDocumentWorkToBackgroundForAnchoredActivation(
        _ destinationSession: DocumentSession
    ) {
        guard currentDocument !== destinationSession else { return }
        let previousSession = currentDocument
        moveCurrentAutosaveToBackground(for: previousSession)
        moveCurrentStatisticsToBackground(for: previousSession)
    }

    private func clearMissingFileActivationFence(at key: URL) {
        detachedSessionURLs.remove(key)
        if let prompt = missingFilePrompt,
           exactFileURLSpellingMatches(prompt.fileURL, key)
        {
            missingFilePrompt = nil
        }
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

    /// Handles a background-observed possible external change to an anchored session.
    ///
    /// Performs one coherent authority-bound read and only advances the retained binding once
    /// identity/SHA-256 arbitration accepts the observed version. A dirty conflict keeps the
    /// previous proof until Reload or Keep Mine explicitly resolves it.
    func handleAnchoredExternalChange(
        for session: DocumentSession,
        binding: AnchoredWorkspaceSessionFileBinding
    ) {
        let key = binding.location.fileURL
        do {
            let preparedRead = try prepareEditorImageAssetDocumentRead(
                fileStore: fileStore,
                at: binding.location
            )
            let observation = ObservedRetainedFileVersion(
                location: binding.location,
                result: preparedRead.result,
                preparedImageAssetAuthority: preparedRead.preparedAuthority
            )
            let changed = observedRetainedFileVersionDiffers(observation, for: session)
            guard reconcileObservedRetainedFileVersion(
                observation,
                for: session,
                canonicalURL: key
            ) else {
                return
            }
            if changed {
                adoptAnchoredFileBinding(
                    AnchoredWorkspaceSessionFileBinding(
                        location: binding.location,
                        identity: observation.identity,
                        sha256Digest: observation.sha256Digest
                    ),
                    for: session,
                    preparedImageAssetAuthority: observation.preparedImageAssetAuthority
                )
            }
        } catch WorkspaceAnchoredFileSystemError.missing {
            markSessionDetachedFromMissingFile(session, url: key)
        } catch {
            // An unreadable/symlink/replaced namespace cannot authorize a binding update.
        }
    }
}

struct PreparedAnchoredFileSessionActivation {
    enum Source {
        case cached
        case retired(canonicalURL: URL)
        case loaded
    }

    let canonicalURL: URL
    let file: MarkdownFile
    let binding: AnchoredWorkspaceSessionFileBinding
    let session: DocumentSession
    let source: Source
    let preparedImageAssetAuthority: PreparedEditorImageAssetDocumentAuthority?
}

struct PreparedWorkspaceReloadFile {
    let location: WorkspaceFileSystemLocation
    let file: MarkdownFile
    let metadata: WorkspaceCoherentFileMetadata
    let sha256Digest: String
    let preparedImageAssetAuthority: PreparedEditorImageAssetDocumentAuthority?
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
