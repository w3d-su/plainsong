import Foundation

@MainActor
extension AppState {
    func flushAutosaveIfNeeded() {
        guard currentDocument.isDirty, canAutosaveCurrentDocument else { return }

        do {
            try saveCurrentDocument()
        } catch {
            present(error, title: "Could Not Save Changes")
        }
    }

    func scheduleAutosave() {
        autosaveTask?.cancel()
        guard canAutosaveCurrentDocument else { return }

        let delayNanoseconds = UInt64(preferences.autosaveIntervalSeconds * 1_000_000_000)
        autosaveTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: delayNanoseconds)
                guard !Task.isCancelled else { return }
                self?.autosaveIfNeeded()
            } catch {
                return
            }
        }
    }

    /// Synchronous by design: a background write can race an explicit ⌘S or a
    /// terminate flush and land *older* content last. The write happens after 1 s of
    /// idle, so it is off the typing hot path; a proper serialized background writer
    /// can come with M3's file coordination if profiling ever shows this hitch.
    private func autosaveIfNeeded() {
        guard currentDocument.isDirty, canAutosaveCurrentDocument else { return }

        do {
            try saveCurrentDocument()
        } catch {
            present(error, title: "Autosave Failed")
        }
    }

    private var canAutosaveCurrentDocument: Bool {
        guard let url = currentDocument.fileURL?.standardizedFileURL else { return false }
        return !detachedSessionURLs.contains(url) &&
            externalChangePrompt?.fileURL.standardizedFileURL != url &&
            missingFilePrompt?.fileURL.standardizedFileURL != url
    }
}
