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
        guard let text = pendingExternalTexts[key],
              let fileKind = FileKind(url: prompt.fileURL)
        else {
            externalChangePrompt = nil
            return
        }

        indeterminateSessionWrites[ObjectIdentifier(currentDocument)] = nil
        indeterminateSessionWriteContexts[ObjectIdentifier(currentDocument)] = nil
        indeterminateFileWriteReconciliationPrompt = nil
        currentDocument.reset(
            text: text,
            url: prompt.fileURL,
            fileKind: fileKind,
            isDirty: false
        )
        detachedSessionURLs.remove(key)
        recordKnownSessionDiskText(text, for: currentDocument, canonicalURL: key)
        pendingExternalTexts[key] = nil
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
        let pendingDiskText = pendingExternalTexts[key]
        pendingExternalTexts[key] = nil
        if let pendingDiskText {
            recordKnownSessionDiskText(
                pendingDiskText,
                for: currentDocument,
                canonicalURL: key
            )
        }
        indeterminateSessionWrites[ObjectIdentifier(currentDocument)] = nil
        indeterminateSessionWriteContexts[ObjectIdentifier(currentDocument)] = nil
        indeterminateFileWriteReconciliationPrompt = nil
        externalChangePrompt = nil
        scheduleAutosave(for: currentDocument)
        finishRetiredEditorDocumentBindingsIfPossible(for: currentDocument)
    }

    func handleCurrentDocumentExternalChange() {
        handleExternalChange(for: currentDocument)
    }

    func handleExternalChange(for session: DocumentSession) {
        if let binding = anchoredSessionFileBinding(for: session) {
            handleAnchoredExternalChange(for: session, binding: binding)
            return
        }
        refreshUnanchoredManagedSessionOwnershipFromDisk(for: session)
        guard let url = sessionStateURL(for: session) else { return }

        switch diskDocumentState(for: url) {
        case .missing:
            markSessionDetachedFromMissingFile(session, url: url)
        case .unchanged:
            return
        case let .changed(diskText, diskHash, modificationDate):
            if session.isDirty {
                pendingExternalTexts[url] = diskText
                cancelAutosave(for: session)
                if session === currentDocument {
                    missingFilePrompt = nil
                    externalChangePrompt = ExternalChangePrompt(fileURL: url)
                }
                return
            }

            guard let fileKind = FileKind(url: url) else { return }
            pendingExternalTexts[url] = nil
            session.reset(
                text: diskText,
                url: url,
                fileKind: fileKind,
                isDirty: false
            )
            detachedSessionURLs.remove(url)
            if session === currentDocument {
                missingFilePrompt = nil
            }
            lastKnownDiskHashes[url] = diskHash
            recordKnownDiskModificationDate(modificationDate, for: url)
        }
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
            pendingExternalTexts[key] = nil
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
        pendingExternalTexts[url] = nil
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
    enum DiskDocumentState {
        case missing
        case unchanged
        case changed(text: String, hash: UInt64, modificationDate: Date?)
    }

    func diskDocumentState(for url: URL) -> DiskDocumentState {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .missing
        }

        let modificationDate = Self.contentModificationDate(for: url)
        let modificationDateUnchanged = modificationDate.map {
            lastKnownDiskModificationDates[url] == $0
        } ?? false
        if modificationDateUnchanged, lastKnownDiskHashes[url] != nil {
            return .unchanged
        }

        guard let diskText = try? fileStore.load(url: url).text else {
            return .unchanged
        }

        let diskHash = Self.contentHash(diskText)
        if lastKnownDiskHashes[url] == diskHash {
            recordKnownDiskModificationDate(modificationDate, for: url)
            return .unchanged
        }

        return .changed(text: diskText, hash: diskHash, modificationDate: modificationDate)
    }

    func recordKnownDiskModificationDate(_ modificationDate: Date?, for url: URL) {
        if let modificationDate {
            lastKnownDiskModificationDates[url] = modificationDate
        } else {
            lastKnownDiskModificationDates[url] = nil
        }
    }
}
