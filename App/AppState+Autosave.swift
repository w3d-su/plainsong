import Foundation
import MarkdownCore

@MainActor
extension AppState {
    func flushAutosaveIfNeeded() {
        var sessions = registry.sessions(from: [.windowDocuments, .warmCache, .retired])
        sessions.sort { first, second in
            let firstURL = first.fileURL?.absoluteString ?? ""
            let secondURL = second.fileURL?.absoluteString ?? ""
            return firstURL.utf8.lexicographicallyPrecedes(secondURL.utf8)
        }

        for session in sessions where session.isDirty && canAutosave(session: session) {
            do {
                try save(session: session)
            } catch {
                present(error, title: "Could Not Save Changes", for: session)
            }
        }
    }

    func scheduleAutosave() {
        let session = shownSession
        // The shared foreground task belongs to the home façade. Other windows use the
        // per-session background task so they cannot cancel the home document's timer.
        guard KeyWindowRouter.shared.isHome(self) else {
            scheduleBackgroundAutosave(for: session)
            return
        }
        cancelBackgroundAutosave(for: session)
        autosaveTask?.cancel()
        guard canAutosaveCurrentDocument else { return }

        let delayNanoseconds = UInt64(preferences.autosaveIntervalSeconds * 1_000_000_000)
        autosaveTask = Task { @MainActor [weak self, weak session] in
            do {
                try await Task.sleep(nanoseconds: delayNanoseconds)
                guard !Task.isCancelled, let self, let session,
                      shownSession === session
                else {
                    return
                }
                autosaveTask = nil
                autosaveIfNeeded()
            } catch {
                return
            }
        }
    }

    func scheduleAutosave(for session: DocumentSession) {
        guard session === shownSession, KeyWindowRouter.shared.isHome(self) else {
            scheduleBackgroundAutosave(for: session)
            return
        }
        scheduleAutosave()
    }

    func moveCurrentAutosaveToBackground(for session: DocumentSession) {
        guard session === shownSession else { return }
        guard KeyWindowRouter.shared.isHome(self) else {
            scheduleBackgroundAutosave(for: session)
            return
        }
        let shouldReschedule = autosaveTask != nil && session.isDirty
        autosaveTask?.cancel()
        autosaveTask = nil
        guard shouldReschedule else { return }
        scheduleBackgroundAutosave(for: session)
    }

    private func scheduleBackgroundAutosave(for session: DocumentSession) {
        cancelBackgroundAutosave(for: session)
        guard canAutosave(session: session) else { return }

        let sessionIdentity = ObjectIdentifier(session)
        let token = UUID()
        let delayNanoseconds = UInt64(preferences.autosaveIntervalSeconds * 1_000_000_000)
        let task = Task { @MainActor [weak self, weak session] in
            do {
                try await Task.sleep(nanoseconds: delayNanoseconds)
            } catch {
                return
            }
            guard let self, let session,
                  !Task.isCancelled,
                  sessionAutosaveTasks[sessionIdentity]?.token == token
            else {
                return
            }

            sessionAutosaveTasks[sessionIdentity] = nil
            guard session.isDirty, canAutosave(session: session) else { return }
            do {
                try save(session: session)
            } catch {
                present(error, title: "Autosave Failed", for: session)
            }
        }
        sessionAutosaveTasks[sessionIdentity] = SessionBackgroundTask(token: token, task: task)
    }

    /// Any window may cancel: the shared foreground task always belongs to the home façade's
    /// document, which a sibling's watcher or reload can be acting on.
    func cancelAutosave(for session: DocumentSession) {
        let home = KeyWindowRouter.shared.home(for: registry) ?? self
        if home.shownSession === session {
            autosaveTask?.cancel()
            autosaveTask = nil
        }
        cancelBackgroundAutosave(for: session)
    }

    func cancelBackgroundAutosave(for session: DocumentSession) {
        let sessionIdentity = ObjectIdentifier(session)
        sessionAutosaveTasks[sessionIdentity]?.task.cancel()
        sessionAutosaveTasks[sessionIdentity] = nil
    }

    /// Synchronous by design: a background write can race an explicit ⌘S or a
    /// terminate flush and land *older* content last. The write happens after 1 s of
    /// idle, so it is off the typing hot path; a proper serialized background writer
    /// can come with M3's file coordination if profiling ever shows this hitch.
    private func autosaveIfNeeded() {
        // The anchored writer now checks cooperative cancellation throughout the
        // operation. Remove the handle before `save` cancels any pending autosave so
        // the currently firing task does not cancel itself and abort its own write.
        autosaveTask = nil
        guard shownSession.isDirty, canAutosaveCurrentDocument else { return }

        do {
            try saveCurrentDocument()
        } catch {
            present(error, title: "Autosave Failed")
        }
    }

    private var canAutosaveCurrentDocument: Bool {
        canAutosave(session: shownSession)
    }

    func canAutosave(session: DocumentSession) -> Bool {
        guard let url = sessionStateURL(for: session) else { return false }
        let sessionIdentity = ObjectIdentifier(session)
        guard !hasWorkspaceMutationRecoveryLoadFailure,
              indeterminateSessionWrites[sessionIdentity] == nil,
              !workspaceMutationWriteFences.contains(sessionIdentity),
              !indeterminateWorkspaceMutationSessions.contains(sessionIdentity)
        else {
            return false
        }
        guard registry.isShownByAnyWindow(session) || registry.isWarmSession(session, at: url)
            || isRetiredEditorSession(session)
        else {
            return false
        }
        return !detachedSessionURLs.contains(url) &&
            !hasPendingEditorSource(for: session) &&
            externalReloadTasks[sessionIdentity] == nil &&
            externalDiskInspectionTasks[sessionIdentity] == nil &&
            pendingExternalTexts[url] == nil &&
            pendingExternalFileVersions[url] == nil &&
            !isSaveBlockedByWindowPrompt(at: url)
    }

    /// Whether any connected window's external-change or missing-file prompt names `url`.
    /// A prompt blocks that file's save and autosave from every window (§3.4 I3).
    func isSaveBlockedByWindowPrompt(at url: URL) -> Bool {
        registry.connectedWindows.contains { window in
            window.saveBlockingPromptURLs.contains { exactFileURLSpellingMatches($0, url) }
        }
    }
}

struct SessionBackgroundTask {
    let token: UUID
    let task: Task<Void, Never>
}
