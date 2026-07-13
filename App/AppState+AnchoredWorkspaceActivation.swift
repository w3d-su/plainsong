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
        at location: WorkspaceFileSystemLocation
    ) throws -> PreparedAnchoredFileSessionActivation {
        let key = location.fileURL
        guard file.url == key else {
            throw AppStateError.invalidSessionIdentity(key)
        }

        if let cachedSession = sessionCache[key] {
            guard cachedSession.fileURL?.standardizedFileURL == key else {
                throw AppStateError.invalidSessionIdentity(key)
            }
            guard !detachedSessionURLs.contains(key) else {
                throw AppStateError.missingFile(key)
            }
            return PreparedAnchoredFileSessionActivation(
                canonicalURL: key,
                file: file,
                session: cachedSession,
                source: .cached
            )
        }

        let retiredMatches = retiredEditorDocumentBindings.compactMap { bindingID, retirement in
            guard !retirement.isAwaitingBindingEnd,
                  retirement.session.fileURL?.standardizedFileURL == key
            else {
                return nil as (EditorDocumentBindingID, RetiredEditorDocumentBinding)?
            }
            return (bindingID, retirement)
        }
        if retiredMatches.count == 1, let match = retiredMatches.first {
            return PreparedAnchoredFileSessionActivation(
                canonicalURL: key,
                file: file,
                session: match.1.session,
                source: .retired(bindingID: match.0)
            )
        }

        return PreparedAnchoredFileSessionActivation(
            canonicalURL: key,
            file: file,
            session: DocumentSession(
                text: file.text,
                url: file.url,
                fileKind: file.fileKind,
                isDirty: false
            ),
            source: .loaded
        )
    }

    /// Applies a fully validated activation without further throwing filesystem work. Reload
    /// commits this and its snapshot/authority/tree as one uninterrupted main-actor transaction.
    func commitAnchoredFileSessionActivation(
        _ activation: PreparedAnchoredFileSessionActivation
    ) {
        let key = activation.canonicalURL
        let session = activation.session

        switch activation.source {
        case .cached:
            if session === currentDocument {
                handleSessionAccess(url: key, isDirty: session.isDirty)
                return
            }
            cancelForegroundDocumentTasks()
            setCurrentDocument(session, synchronizingWorkspaceTree: false)
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
                let file = try fileStore.load(at: location)
                try Task.checkCancellation()
                return PreparedWorkspaceReloadFile(location: location, file: file)
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
        if missingFilePrompt?.fileURL.standardizedFileURL == key {
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
}

struct PreparedAnchoredFileSessionActivation {
    enum Source {
        case cached
        case retired(bindingID: EditorDocumentBindingID)
        case loaded
    }

    let canonicalURL: URL
    let file: MarkdownFile
    let session: DocumentSession
    let source: Source
}

struct PreparedWorkspaceReloadFile {
    let location: WorkspaceFileSystemLocation
    let file: MarkdownFile
}
