import EditorKit
import Foundation
import MarkdownCore

@MainActor
extension AppState {
    /// A descriptor-bound search activation observation is a disk ordering boundary just like
    /// a watcher event. Retire every older inspection/resolution before its observation is
    /// arbitrated, including when arbitration records a conflict and rejects the activation.
    func supersedeExternalWorkAfterWorkspaceSearchObservation(
        for session: DocumentSession,
        canonicalURL: URL
    ) {
        guard let stateURL = sessionStateURL(for: session),
              exactFileURLSpellingMatches(stateURL, canonicalURL)
        else {
            return
        }

        let sessionIdentity = ObjectIdentifier(session)
        let diskEventGeneration = advanceExternalDiskEventGeneration(for: session)
        externalDiskInspectionTasks.removeValue(forKey: sessionIdentity)?.task.cancel()

        guard let intent = deferredExternalChangeResolutions[canonicalURL] else {
            supersedeExternalResolutionRead(for: session)
            return
        }
        guard refreshExternalResolutionIntentCapture(
            for: session,
            canonicalURL: canonicalURL,
            intent: intent,
            diskEventGeneration: diskEventGeneration
        ) else {
            return
        }

        supersedeExternalResolutionRead(for: session)
        restartExternalResolutionIfNeeded(for: session)
        if session === currentDocument {
            restoreRecoveryPrompt(for: session)
        }
    }

    func refreshExternalResolutionIntentCapture(
        for session: DocumentSession,
        canonicalURL: URL,
        intent: DeferredExternalChangeResolution,
        diskEventGeneration: UInt64
    ) -> Bool {
        let sessionIdentity = ObjectIdentifier(session)
        let currentSourceSnapshot = EditorDocumentSourceSnapshot(
            source: session.text,
            revision: session.version
        )
        guard var intentCapture = externalResolutionIntentCaptures[canonicalURL],
              intentCapture.intent == intent
        else {
            abortExternalResolutionAfterUnexpectedSourceChange(for: session)
            return false
        }
        if intentCapture.sourceSnapshot.revision != session.version {
            guard let pendingApplication = pendingExternalReloadApplications[sessionIdentity],
                  pendingApplication.session === session,
                  pendingApplication.intent == intent,
                  pendingApplication.acceptedSourceSnapshot.revision == session.version
            else {
                abortExternalResolutionAfterUnexpectedSourceChange(for: session)
                return false
            }
            intentCapture = ExternalResolutionIntentCapture(
                intent: intent,
                sourceSnapshot: currentSourceSnapshot,
                diskEventGeneration: intentCapture.diskEventGeneration
            )
        }
        intentCapture.diskEventGeneration = diskEventGeneration
        externalResolutionIntentCaptures[canonicalURL] = intentCapture
        return true
    }

    func supersedeExternalResolutionRead(for session: DocumentSession) {
        let sessionIdentity = ObjectIdentifier(session)
        nextExternalReloadGeneration += 1
        externalReloadTasks.removeValue(forKey: sessionIdentity)?.task.cancel()
        pendingExternalReloadApplications[sessionIdentity] = nil
    }

    func abortExternalResolutionAfterUnexpectedSourceChange(for session: DocumentSession) {
        let sessionIdentity = ObjectIdentifier(session)
        externalReloadTasks.removeValue(forKey: sessionIdentity)?.task.cancel()
        pendingExternalReloadApplications[sessionIdentity] = nil
        guard let stateURL = sessionStateURL(for: session) else { return }
        deferredExternalChangeResolutions[stateURL] = nil
        externalResolutionIntentCaptures[stateURL] = nil
        restoreRecoveryPrompt(for: session)
    }
}
