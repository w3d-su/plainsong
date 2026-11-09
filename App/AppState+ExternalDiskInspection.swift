import EditorKit
import Foundation
import MarkdownCore
import WorkspaceKit

/// Watcher-driven disk inspections of managed sessions, and the M2 rules that keep a racing
/// read or a briefly missing file from turning a clean document into a conflict.
@MainActor
extension AppState {
    /// Delays before each re-read of a transient outcome (M2). A read that lands while
    /// another tool replaces the file (an atomic save, `git`, a sync client) sees it change
    /// identity, change size or briefly become unreadable; looking again for about 1.7 s
    /// before detaching keeps a clean document from turning into a Reload/Keep Mine conflict.
    static let externalInspectionTransientRetryDelays: [UInt64] = [
        200_000_000, 500_000_000, 1_000_000_000,
    ]

    func startExternalDiskInspection(
        for session: DocumentSession,
        canonicalURL stateURL: URL,
        location: WorkspaceFileSystemLocation,
        diskEventGeneration: UInt64,
        transientRetry: Int = 0
    ) {
        let sessionIdentity = ObjectIdentifier(session)
        let token = UUID()
        let lifecycleGeneration = currentSessionLifecycleGeneration(for: session)
        let sourceSnapshot = EditorDocumentSourceSnapshot(
            source: session.text,
            revision: session.version
        )
        let reader = coherentFileReader
        let applicationPreparer = externalReloadApplicationPreparer
        let completionContext = ExternalDiskInspectionReadContext(
            canonicalURL: stateURL,
            location: location,
            token: token,
            lifecycleGeneration: lifecycleGeneration,
            diskEventGeneration: diskEventGeneration,
            transientRetry: transientRetry
        )
        let delay = transientRetry > 0
            ? Self.externalInspectionTransientRetryDelays[transientRetry - 1]
            : 0
        let task = Task { @MainActor [weak self, weak session] in
            if delay > 0 {
                try? await Task.sleep(nanoseconds: delay)
                guard !Task.isCancelled else { return }
            }
            let prepared = await prepareExternalFileRead(
                at: location,
                reader: reader,
                applicationPreparer: applicationPreparer,
                sourceSnapshot: sourceSnapshot
            )
            guard !Task.isCancelled else { return }
            guard let self, let session else { return }
            completeExternalDiskInspection(prepared, session: session, context: completionContext)
        }
        externalDiskInspectionTasks[sessionIdentity] = ExternalDiskInspectionTask(
            token: token,
            session: session,
            canonicalURL: stateURL,
            location: location,
            lifecycleGeneration: lifecycleGeneration,
            diskEventGeneration: diskEventGeneration,
            sourceSnapshot: sourceSnapshot,
            task: task,
            transientRetry: transientRetry
        )
    }

    /// Whether `session` was detached from `url` while clean and has not changed since (M2).
    /// It holds no edits a reload could lose, so when the file reads back it reloads like a
    /// clean document. It stays marked dirty while detached because the editor copy is then
    /// the only copy.
    func isUneditedSinceCleanDetach(_ session: DocumentSession, at url: URL) -> Bool {
        guard let record = cleanDetachedSessionRecords[ObjectIdentifier(session)] else { return false }
        return record.revision == session.version
            && exactFileURLSpellingMatches(record.stateURL, url)
            && !hasPendingEditorSource(for: session)
    }

    /// Outcomes a read can see while another tool is replacing the file. A missing file is
    /// not one of them: it detaches at once so a deletion is reported promptly.
    static func isTransientExternalReadOutcome(_ outcome: WorkspaceCoherentFileReadOutcome) -> Bool {
        switch outcome {
        case .namespaceChanged, .unstable, .unreadable:
            true
        case .loaded, .missing, .symbolicLink, .notRegularFile, .invalidUTF8, .cancelled:
            false
        }
    }
}
