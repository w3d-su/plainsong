import Foundation
import MarkdownCore

struct WorkspaceMutationTextRecoveryContext {
    let recoveryID: UUID
    var originalURL: URL
    var fileKind: FileKind
    let reason: WorkspaceMutationTextRecoveryRecord.Reason
    var persistedRevision: Int?
    var requiresExplicitStopTracking = false
    let sessionRevisionBaseline: Int
    let logicalRevisionBaseline: Int

    init(
        recoveryID: UUID,
        originalURL: URL,
        fileKind: FileKind,
        reason: WorkspaceMutationTextRecoveryRecord.Reason,
        persistedRevision: Int?,
        sessionRevisionBaseline: Int = 0,
        logicalRevisionBaseline: Int = 0
    ) {
        self.recoveryID = recoveryID
        self.originalURL = originalURL
        self.fileKind = fileKind
        self.reason = reason
        self.persistedRevision = persistedRevision
        self.sessionRevisionBaseline = sessionRevisionBaseline
        self.logicalRevisionBaseline = logicalRevisionBaseline
    }
}

@MainActor
extension AppState {
    func installWorkspaceMutationTextRecovery(
        for records: [WorkspaceTrashSessionRecord],
        reason: WorkspaceMutationTextRecoveryRecord.Reason
    ) {
        for record in records {
            installWorkspaceMutationTextRecovery(
                for: record.session,
                originalURL: record.oldURL,
                reason: reason
            )
        }
    }

    func installWorkspaceMutationTextRecovery(
        for records: [WorkspaceSessionRelocationRecord],
        reason: WorkspaceMutationTextRecoveryRecord.Reason
    ) {
        for record in records {
            installWorkspaceMutationTextRecovery(
                for: record.session,
                originalURL: record.oldURL,
                reason: reason
            )
        }
    }

    func scheduleWorkspaceMutationTextRecovery(for session: DocumentSession) {
        let sessionIdentity = ObjectIdentifier(session)
        guard let context = workspaceMutationTextRecoveryContexts[sessionIdentity] else { return }
        workspaceMutationTextRecoveryTasks[sessionIdentity]?.cancel()
        if context.reason == .trash, workspaceMutationNamespaceDepth > 0 {
            do {
                try persistWorkspaceMutationTextRecovery(for: session)
            } catch {
                present(error, title: "Could Not Preserve Recovery Copy")
                scheduleWorkspaceMutationTextRecoveryRetry(for: session)
            }
            return
        }
        scheduleWorkspaceMutationTextRecoveryRetry(for: session)
    }

    private func scheduleWorkspaceMutationTextRecoveryRetry(
        for session: DocumentSession
    ) {
        let sessionIdentity = ObjectIdentifier(session)
        workspaceMutationTextRecoveryTasks[sessionIdentity] = Task { @MainActor [weak self, weak session] in
            do {
                try await Task.sleep(nanoseconds: 200_000_000)
            } catch {
                return
            }
            guard let self, let session, !Task.isCancelled else { return }
            workspaceMutationTextRecoveryTasks[sessionIdentity] = nil
            do {
                try persistWorkspaceMutationTextRecovery(for: session)
            } catch {
                present(error, title: "Could Not Preserve Recovery Copy")
            }
        }
    }

    func persistWorkspaceMutationTextRecovery(for session: DocumentSession) throws {
        let sessionIdentity = ObjectIdentifier(session)
        guard var context = workspaceMutationTextRecoveryContexts[sessionIdentity] else {
            return
        }
        guard !workspaceMutationTextRecoveryLoadFailed else {
            throw WorkspaceMutationOperationRecoveryError.textRecoveryUnavailable(
                context.originalURL
            )
        }
        let record = WorkspaceMutationTextRecoveryRecord(
            id: context.recoveryID,
            originalURL: context.originalURL,
            fileKind: context.fileKind,
            source: session.text,
            revision: workspaceMutationTextRecoveryLogicalRevision(
                for: session,
                context: context
            ),
            reason: context.reason
        )
        do {
            try workspaceMutationTextRecoveryStore.upsert(record)
        } catch {
            let standaloneError = error
            do {
                let backedUpInOperationJournal =
                    try persistWorkspaceMutationTextRecoveryInOperationBundle(
                        for: session,
                        latestRecord: record
                    )
                guard backedUpInOperationJournal else {
                    throw standaloneError
                }
            } catch {
                throw error
            }
            throw standaloneError
        }
        context.persistedRevision = record.revision
        workspaceMutationTextRecoveryContexts[sessionIdentity] = context
    }

    @discardableResult
    func clearWorkspaceMutationTextRecovery(for session: DocumentSession) -> Bool {
        let sessionIdentity = ObjectIdentifier(session)
        guard var context = workspaceMutationTextRecoveryContexts[sessionIdentity] else {
            return true
        }
        guard !context.requiresExplicitStopTracking else {
            refreshWorkspaceMutationReconciliationPrompt()
            return false
        }
        do {
            try workspaceMutationTextRecoveryStore.remove(id: context.recoveryID)
            workspaceMutationTextRecoveryTasks.removeValue(forKey: sessionIdentity)?.cancel()
            workspaceMutationTextRecoveryContexts[sessionIdentity] = nil
            workspaceMutationTextRecoverySessions[context.recoveryID] = nil
            return true
        } catch {
            let removalError = error
            context.requiresExplicitStopTracking = true
            workspaceMutationTextRecoveryContexts[sessionIdentity] = context
            do {
                // `remove` unlinks before synchronizing the directory. Any thrown error can
                // therefore mean the record is already absent even when this exact revision
                // had previously been durable. Recreate the latest record unconditionally.
                try persistWorkspaceMutationTextRecovery(for: session)
                workspaceMutationTextRecoveryTasks.removeValue(
                    forKey: sessionIdentity
                )?.cancel()
            } catch {
                scheduleWorkspaceMutationTextRecovery(for: session)
            }
            refreshWorkspaceMutationReconciliationPrompt()
            present(removalError, title: "Recovery Cleanup Needs Attention")
            return false
        }
    }

    func stopTrackingWorkspaceMutationTextRecovery(for session: DocumentSession) {
        let sessionIdentity = ObjectIdentifier(session)
        guard let context = workspaceMutationTextRecoveryContexts[sessionIdentity],
              context.requiresExplicitStopTracking
        else {
            refreshWorkspaceMutationReconciliationPrompt()
            return
        }

        do {
            try persistWorkspaceMutationTextRecovery(for: session)
            try workspaceMutationTextRecoveryStore.quarantine(id: context.recoveryID)
        } catch {
            present(error, title: "Could Not Stop Tracking Editor Recovery")
            refreshWorkspaceMutationReconciliationPrompt()
            return
        }

        workspaceMutationTextRecoveryTasks.removeValue(forKey: sessionIdentity)?.cancel()
        workspaceMutationTextRecoveryContexts[sessionIdentity] = nil
        workspaceMutationTextRecoverySessions[context.recoveryID] = nil
        if workspaceMutationReconciliationPrompt?.recoveryID == context.recoveryID {
            workspaceMutationReconciliationPrompt = nil
        }
        promoteNextWorkspaceMutationRecoverySessionIfNeeded()
    }

    func persistWorkspaceMutationTextRecovery(
        for sessions: [DocumentSession]
    ) throws {
        var seen: Set<ObjectIdentifier> = []
        for session in sessions where seen.insert(ObjectIdentifier(session)).inserted {
            try persistWorkspaceMutationTextRecovery(for: session)
        }
    }

    func relocateWorkspaceMutationTextRecovery(
        for session: DocumentSession,
        to newURL: URL
    ) {
        let sessionIdentity = ObjectIdentifier(session)
        guard var context = workspaceMutationTextRecoveryContexts[sessionIdentity] else {
            return
        }
        context.originalURL = newURL
        context.fileKind = FileKind(url: newURL) ?? session.fileKind
        context.persistedRevision = nil
        workspaceMutationTextRecoveryContexts[sessionIdentity] = context
        do {
            try persistWorkspaceMutationTextRecovery(for: session)
        } catch {
            present(error, title: "Could Not Preserve Recovery Copy")
        }
    }

    func finishWorkspaceMutationTextRecoveryAfterNotTrashed(
        _ records: [WorkspaceTrashSessionRecord]
    ) {
        for record in records {
            let session = record.session
            if session.version != record.initialVersion ||
                session.isDirty ||
                hasPendingEditorSource(for: session)
            {
                do {
                    try persistWorkspaceMutationTextRecovery(for: session)
                } catch {
                    present(error, title: "Could Not Preserve Recovery Copy")
                }
            } else {
                _ = clearWorkspaceMutationTextRecovery(for: session)
            }
        }
    }

    func clearResolvedWorkspaceMutationTextRecovery(
        for sessions: [DocumentSession]
    ) {
        var seen: Set<ObjectIdentifier> = []
        for session in sessions where seen.insert(ObjectIdentifier(session)).inserted {
            if !session.isDirty, !hasPendingEditorSource(for: session) {
                _ = clearWorkspaceMutationTextRecovery(for: session)
            }
        }
    }

    func restoreWorkspaceMutationTextRecoveryIfNeeded() {
        let currentIdentity = ObjectIdentifier(currentDocument)
        guard workspaceMutationRecoveryIDBySession[currentIdentity] == nil,
              workspaceMutationTextRecoveryContexts[currentIdentity] == nil,
              let record = pendingWorkspaceMutationTextRecoveryRecords.first
        else {
            return
        }
        pendingWorkspaceMutationTextRecoveryRecords.removeFirst()
        let session = DocumentSession(
            text: record.source,
            url: record.originalURL,
            fileKind: record.fileKind,
            isDirty: true
        )
        let sessionIdentity = ObjectIdentifier(session)
        workspaceMutationTextRecoveryContexts[sessionIdentity] =
            WorkspaceMutationTextRecoveryContext(
                recoveryID: record.id,
                originalURL: record.originalURL,
                fileKind: record.fileKind,
                reason: record.reason,
                persistedRevision: record.revision,
                sessionRevisionBaseline: session.version,
                logicalRevisionBaseline: record.revision
            )
        workspaceMutationTextRecoverySessions[record.id] = session
        unanchoredManagedSessionOwnershipProofs[sessionIdentity] =
            .unavailable(fileURL: record.originalURL)
        detachedSessionURLs.insert(record.originalURL)
        handleSessionEvictions(
            sessionPolicy.access(record.originalURL, isDirty: true)
        )
        setCurrentDocument(session, synchronizingWorkspaceTree: false)
        restoreRecoveryPrompt(for: session)
    }

    func prepareForTermination() -> Bool {
        do {
            try validateWorkspaceMutationRecoveryStoresLoaded()
        } catch {
            present(error, title: "Could Not Quit")
            return false
        }
        let sessions = workspaceMutationTerminationSessions()
        if let pending = sessions.first(where: { hasPendingEditorSource(for: $0) }) {
            present(
                AppStateError.pendingEditorSource(
                    sessionStateURL(for: pending)
                        ?? pending.fileURL
                        ?? URL(fileURLWithPath: "/")
                ),
                title: "Could Not Quit"
            )
            return false
        }
        guard imageAssetInsertionAllowsTermination() else { return false }

        do {
            for session in sessions {
                let sessionIdentity = ObjectIdentifier(session)
                guard workspaceMutationTextRecoveryContexts[sessionIdentity] != nil else {
                    continue
                }
                if session.isDirty {
                    try persistWorkspaceMutationTextRecovery(for: session)
                } else if workspaceMutationNamespaceDepth == 0,
                          workspaceMutationRecoveryIDBySession[sessionIdentity] == nil,
                          !clearWorkspaceMutationTextRecovery(for: session)
                {
                    return false
                }
            }
        } catch {
            present(error, title: "Could Not Preserve Recovery Copy")
            return false
        }

        guard workspaceMutationNamespaceDepth == 0 else {
            present(
                AppStateError.workspaceMutationInProgress(
                    workspaceRootURL
                        ?? sessionStateURL(for: currentDocument)
                        ?? currentDocument.fileURL
                        ?? URL(fileURLWithPath: "/")
                ),
                title: "Could Not Quit"
            )
            return false
        }
        guard workspaceMutationRecoveries.isEmpty else {
            present(
                WorkspaceMutationError.indeterminateSession(
                    workspaceMutationRecoveries.values.first?.sourceURL
                        ?? URL(fileURLWithPath: "/")
                ),
                title: "Could Not Quit"
            )
            return false
        }

        flushAutosaveIfNeeded()
        for session in sessions {
            let sessionIdentity = ObjectIdentifier(session)
            if session.isDirty {
                guard let context = workspaceMutationTextRecoveryContexts[sessionIdentity],
                      context.persistedRevision ==
                      workspaceMutationTextRecoveryLogicalRevision(
                          for: session,
                          context: context
                      )
                else {
                    present(
                        AppStateError.unsavedChangesPreventTermination(
                            sessionStateURL(for: session)
                                ?? session.fileURL
                                ?? URL(fileURLWithPath: "/")
                        ),
                        title: "Could Not Quit"
                    )
                    return false
                }
            } else if workspaceMutationTextRecoveryContexts[sessionIdentity] != nil,
                      !clearWorkspaceMutationTextRecovery(for: session)
            {
                present(
                    AppStateError.unsavedChangesPreventTermination(
                        sessionStateURL(for: session)
                            ?? session.fileURL
                            ?? URL(fileURLWithPath: "/")
                    ),
                    title: "Could Not Quit"
                )
                return false
            }
        }
        return true
    }

    private func imageAssetInsertionAllowsTermination() -> Bool {
        guard workspaceImageAssetInsertionCount == 0 else {
            present(
                AppStateError.workspaceMutationInProgress(
                    workspaceRootURL
                        ?? sessionStateURL(for: currentDocument)
                        ?? currentDocument.fileURL
                        ?? URL(fileURLWithPath: "/")
                ),
                title: "Could Not Quit"
            )
            return false
        }
        return true
    }
}

@MainActor
extension AppState {
    func installWorkspaceMutationTextRecovery(
        for session: DocumentSession,
        originalURL: URL,
        reason: WorkspaceMutationTextRecoveryRecord.Reason
    ) {
        let sessionIdentity = ObjectIdentifier(session)
        guard workspaceMutationTextRecoveryContexts[sessionIdentity] == nil else { return }
        let recoveryID = UUID()
        workspaceMutationTextRecoveryContexts[sessionIdentity] =
            WorkspaceMutationTextRecoveryContext(
                recoveryID: recoveryID,
                originalURL: originalURL,
                fileKind: session.fileKind,
                reason: reason,
                persistedRevision: nil,
                sessionRevisionBaseline: session.version,
                logicalRevisionBaseline: session.version
            )
        workspaceMutationTextRecoverySessions[recoveryID] = session
    }

    func workspaceMutationTerminationSessions() -> [DocumentSession] {
        var sessions = workspaceMutationManagedSessions()
        sessions.append(contentsOf: workspaceMutationTextRecoverySessions.values)
        if currentDocument.fileURL != nil {
            sessions.append(currentDocument)
        }
        var seen: Set<ObjectIdentifier> = []
        return sessions.filter { seen.insert(ObjectIdentifier($0)).inserted }
    }

    func workspaceMutationTextRecoveryLogicalRevision(
        for session: DocumentSession,
        context: WorkspaceMutationTextRecoveryContext
    ) -> Int {
        context.logicalRevisionBaseline +
            max(0, session.version - context.sessionRevisionBaseline)
    }
}
