import Foundation
import MarkdownCore

@MainActor
extension AppState {
    func reloadExternallyChangedFile() {
        guard let prompt = externalChangePrompt else { return }
        let key = prompt.fileURL
        guard let stateURL = sessionStateURL(for: currentDocument),
              exactFileURLSpellingMatches(stateURL, key)
        else {
            externalChangePrompt = nil
            return
        }
        guard pendingExternalTexts[key] != nil || pendingExternalFileVersions[key] != nil else {
            externalChangePrompt = nil
            return
        }

        // Do not restore the earlier pending text and then refresh a proof in a second read.
        // The file can change from B to C while the prompt is visible; both the restored text
        // and adopted proof must come from this one, fresh descriptor-bound observation.
        guard let observation = try? observeRetainedFileVersion(for: currentDocument),
              exactFileURLSpellingMatches(observation.location.fileURL, key),
              adoptObservedRetainedFileVersion(observation, for: currentDocument)
        else {
            // Fail closed. The prior proof and conflict fence remain in force until a later
            // explicit Reload or Keep Mine can read and verify the retained authority.
            return
        }

        indeterminateSessionWrites[ObjectIdentifier(currentDocument)] = nil
        indeterminateSessionWriteContexts[ObjectIdentifier(currentDocument)] = nil
        indeterminateFileWriteReconciliationPrompt = nil
        currentDocument.reset(
            text: observation.file.text,
            url: key,
            fileKind: observation.file.fileKind,
            isDirty: false
        )
        detachedSessionURLs.remove(key)
        recordKnownSessionDiskText(
            observation.file.text,
            for: currentDocument,
            canonicalURL: key
        )
        clearExternalChangeConflict(at: key)
        externalChangePrompt = nil
        sessionPolicy.updateDirtyState(for: key, isDirty: false)
        cancelAutosave(for: currentDocument)
        finishRetiredEditorDocumentBindingsIfPossible(for: currentDocument)
    }

    func keepMineForExternallyChangedFile() {
        guard let prompt = externalChangePrompt else { return }
        let key = prompt.fileURL
        guard let stateURL = sessionStateURL(for: currentDocument),
              exactFileURLSpellingMatches(stateURL, key)
        else {
            externalChangePrompt = nil
            return
        }
        guard pendingExternalTexts[key] != nil || pendingExternalFileVersions[key] != nil else {
            externalChangePrompt = nil
            return
        }

        // Keeping local edits is still an explicit resolution, but it may only authorize the
        // next write after a fresh observation of the retained location has supplied its exact
        // identity and SHA-256. If the file changed from B to C while the prompt was open, resolve
        // against C rather than authorizing local content with B's stale proof.
        guard let observation = try? observeRetainedFileVersion(for: currentDocument),
              exactFileURLSpellingMatches(observation.location.fileURL, key),
              adoptObservedRetainedFileVersion(observation, for: currentDocument)
        else {
            return
        }
        let localTextDiffersFromObservedDisk = !ExactSourceText.matches(
            currentDocument.text,
            observation.file.text
        )
        recordKnownSessionDiskText(
            observation.file.text,
            for: currentDocument,
            canonicalURL: key
        )
        clearExternalChangeConflict(at: key)
        indeterminateSessionWrites[ObjectIdentifier(currentDocument)] = nil
        indeterminateSessionWriteContexts[ObjectIdentifier(currentDocument)] = nil
        indeterminateFileWriteReconciliationPrompt = nil
        detachedSessionURLs.remove(key)
        if let prompt = missingFilePrompt,
           exactFileURLSpellingMatches(prompt.fileURL, key)
        {
            missingFilePrompt = nil
        }
        if localTextDiffersFromObservedDisk, !currentDocument.isDirty {
            currentDocument.reset(
                text: currentDocument.text,
                url: currentDocument.fileURL,
                fileKind: currentDocument.fileKind,
                isDirty: true
            )
        }
        sessionPolicy.updateDirtyState(for: key, isDirty: currentDocument.isDirty)
        externalChangePrompt = nil
        scheduleAutosave(for: currentDocument)
        finishRetiredEditorDocumentBindingsIfPossible(for: currentDocument)
    }

    func handleCurrentDocumentExternalChange() {
        handleExternalChange(for: currentDocument)
    }

    func handleExternalChange(for session: DocumentSession) {
        // An indeterminate write owns a distinct retained destination. Do not let the old
        // anchored proof (if any) redirect this arbitration back to its pre-write source.
        if indeterminateSessionWrites[ObjectIdentifier(session)] != nil {
            refreshIndeterminateFileWriteReconciliation(for: session)
            return
        }
        if let binding = anchoredSessionFileBinding(for: session) {
            handleAnchoredExternalChange(for: session, binding: binding)
            return
        }
        handleUnanchoredExternalChange(for: session)
    }

    func recordKnownDiskText(_ text: String, for url: URL, modificationDate: Date? = nil) {
        let key = url
        lastKnownDiskHashes[key] = Self.contentHash(text)
        recordKnownDiskModificationDate(modificationDate ?? Self.contentModificationDate(for: key), for: key)
    }

    func clearSessionState(
        for session: DocumentSession,
        fallbackURL: URL? = nil,
        removesEditorBindingRegistration: Bool = true
    ) {
        let sessionIdentity = ObjectIdentifier(session)
        var stateKeys = Set(sessionCache.compactMap { key, cachedSession in
            cachedSession === session ? key : nil
        })
        if let stateURL = sessionStateURL(for: session) {
            stateKeys.insert(stateURL)
        }
        if let fallbackURL {
            stateKeys.insert(fallbackURL)
        }

        cancelAutosave(for: session)
        cancelStatisticsRefresh(for: session)
        if removesEditorBindingRegistration {
            removeEditorDocumentBindingRegistration(for: session)
        }
        anchoredSessionFileBindings[sessionIdentity] = nil
        unanchoredManagedSessionOwnershipProofs[sessionIdentity] = nil
        indeterminateSessionWrites[sessionIdentity] = nil
        indeterminateSessionWriteContexts[sessionIdentity] = nil

        for key in stateKeys {
            if sessionCache[key] === session {
                sessionCache[key] = nil
            }
            sessionPolicy.remove(key)
            lastKnownDiskHashes[key] = nil
            lastKnownDiskModificationDates[key] = nil
            clearExternalChangeConflict(at: key)
            detachedSessionURLs.remove(key)
            if let prompt = externalChangePrompt,
               exactFileURLSpellingMatches(prompt.fileURL, key)
            {
                externalChangePrompt = nil
            }
            if let prompt = missingFilePrompt,
               exactFileURLSpellingMatches(prompt.fileURL, key)
            {
                missingFilePrompt = nil
            }
            if let prompt = indeterminateFileWriteReconciliationPrompt,
               exactFileURLSpellingMatches(prompt.fileURL, key)
            {
                indeterminateFileWriteReconciliationPrompt = nil
            }
        }
    }

    func markSessionDetachedFromMissingFile(_ session: DocumentSession, url: URL) {
        detachedSessionURLs.insert(url)
        clearExternalChangeConflict(at: url)
        lastKnownDiskHashes[url] = nil
        lastKnownDiskModificationDates[url] = nil
        sessionPolicy.updateDirtyState(for: url, isDirty: true)
        cancelAutosave(for: session)

        if !session.isDirty {
            session.reset(
                text: session.text,
                url: session.fileURL,
                fileKind: session.fileKind,
                isDirty: true
            )
        }

        guard session === currentDocument else { return }
        externalChangePrompt = nil
        missingFilePrompt = MissingFilePrompt(fileURL: url)
    }

    static func contentHash(_ text: String) -> UInt64 {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return hash
    }

    static func contentModificationDate(for url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }
}

private extension AppState {
    func recordKnownDiskModificationDate(_ modificationDate: Date?, for url: URL) {
        if let modificationDate {
            lastKnownDiskModificationDates[url] = modificationDate
        } else {
            lastKnownDiskModificationDates[url] = nil
        }
    }
}
