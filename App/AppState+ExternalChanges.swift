import Foundation
import MarkdownCore

@MainActor
extension AppState {
    func reloadExternallyChangedFile() {
        guard let prompt = externalChangePrompt else { return }
        let key = prompt.fileURL.standardizedFileURL
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
        lastKnownDiskHashes[key] = Self.contentHash(text)
        pendingExternalTexts[key] = nil
        externalChangePrompt = nil
    }

    func keepMineForExternallyChangedFile() {
        guard let prompt = externalChangePrompt else { return }
        let key = prompt.fileURL.standardizedFileURL
        pendingExternalTexts[key] = nil
        if let diskText = try? fileStore.load(url: prompt.fileURL).text {
            lastKnownDiskHashes[key] = Self.contentHash(diskText)
        }
        externalChangePrompt = nil
    }

    func handleCurrentDocumentExternalChange() {
        guard let url = currentDocument.fileURL?.standardizedFileURL else { return }
        guard let diskText = try? fileStore.load(url: url).text else { return }

        let diskHash = Self.contentHash(diskText)
        guard lastKnownDiskHashes[url] != diskHash else { return }

        if currentDocument.isDirty {
            pendingExternalTexts[url] = diskText
            externalChangePrompt = ExternalChangePrompt(fileURL: url)
            return
        }

        guard let fileKind = FileKind(url: url) else { return }
        currentDocument.reset(
            text: diskText,
            url: url,
            fileKind: fileKind,
            isDirty: false
        )
        lastKnownDiskHashes[url] = diskHash
    }

    static func contentHash(_ text: String) -> UInt64 {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return hash
    }
}
