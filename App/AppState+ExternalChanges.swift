import Foundation
import MarkdownCore

@MainActor
extension AppState {
    func reloadExternallyChangedFile() {
        guard let prompt = externalChangePrompt else { return }
        let key = prompt.fileURL.standardizedFileURL
        guard currentDocument.fileURL?.standardizedFileURL == key else {
            pendingExternalTexts[key] = nil
            externalChangePrompt = nil
            return
        }
        guard let text = pendingExternalTexts[key],
              let fileKind = FileKind(url: prompt.fileURL)
        else {
            externalChangePrompt = nil
            return
        }

        currentDocument.reset(
            text: text,
            url: prompt.fileURL,
            fileKind: fileKind,
            isDirty: false
        )
        detachedSessionURLs.remove(key)
        recordKnownDiskText(text, for: key)
        pendingExternalTexts[key] = nil
        externalChangePrompt = nil
    }

    func keepMineForExternallyChangedFile() {
        guard let prompt = externalChangePrompt else { return }
        let key = prompt.fileURL.standardizedFileURL
        pendingExternalTexts[key] = nil
        if let diskText = try? fileStore.load(url: prompt.fileURL).text {
            recordKnownDiskText(diskText, for: key)
        }
        externalChangePrompt = nil
    }

    func handleCurrentDocumentExternalChange() {
        handleExternalChange(for: currentDocument)
    }

    func handleExternalChange(for session: DocumentSession) {
        guard let url = session.fileURL?.standardizedFileURL else { return }

        switch diskDocumentState(for: url) {
        case .missing:
            markSessionDetachedFromMissingFile(session, url: url)
        case .unchanged:
            return
        case let .changed(diskText, diskHash, modificationDate):
            if session.isDirty {
                pendingExternalTexts[url] = diskText
                if session === currentDocument {
                    autosaveTask?.cancel()
                    missingFilePrompt = nil
                    externalChangePrompt = ExternalChangePrompt(fileURL: url)
                }
                return
            }

            guard let fileKind = FileKind(url: url) else { return }
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
        let key = url.standardizedFileURL
        lastKnownDiskHashes[key] = Self.contentHash(text)
        recordKnownDiskModificationDate(modificationDate ?? Self.contentModificationDate(for: key), for: key)
    }

    func clearSessionState(for url: URL) {
        let key = url.standardizedFileURL
        if let session = sessionCache[key] {
            cancelAutosave(for: session)
            cancelStatisticsRefresh(for: session)
            removeEditorDocumentBindingRegistration(for: session)
        }
        sessionCache[key] = nil
        sessionPolicy.remove(key)
        lastKnownDiskHashes[key] = nil
        lastKnownDiskModificationDates[key] = nil
        pendingExternalTexts[key] = nil
        detachedSessionURLs.remove(key)
        if externalChangePrompt?.fileURL.standardizedFileURL == key {
            externalChangePrompt = nil
        }
        if missingFilePrompt?.fileURL.standardizedFileURL == key {
            missingFilePrompt = nil
        }
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

    func markSessionDetachedFromMissingFile(_ session: DocumentSession, url: URL) {
        detachedSessionURLs.insert(url)
        pendingExternalTexts[url] = nil
        lastKnownDiskHashes[url] = nil
        lastKnownDiskModificationDates[url] = nil
        sessionPolicy.updateDirtyState(for: url, isDirty: true)

        if !session.isDirty {
            session.reset(
                text: session.text,
                url: session.fileURL,
                fileKind: session.fileKind,
                isDirty: true
            )
        }

        guard session === currentDocument else { return }
        autosaveTask?.cancel()
        externalChangePrompt = nil
        missingFilePrompt = MissingFilePrompt(fileURL: url)
    }

    func recordKnownDiskModificationDate(_ modificationDate: Date?, for url: URL) {
        let key = url.standardizedFileURL
        if let modificationDate {
            lastKnownDiskModificationDates[key] = modificationDate
        } else {
            lastKnownDiskModificationDates[key] = nil
        }
    }
}
