import EditorKit
import Foundation
import MarkdownCore
import SwiftUI

@MainActor
extension AppState {
    func editorDocumentBinding(for session: DocumentSession) -> AppEditorDocumentBinding {
        let sessionIdentity = ObjectIdentifier(session)
        let bindingID: EditorDocumentBindingID
        if let existing = registeredEditorDocumentBindingID(for: session) {
            bindingID = existing
        } else {
            if let staleID = editorDocumentBindingIDs[sessionIdentity] {
                editorDocumentBindingSessions[staleID] = nil
            }
            bindingID = EditorDocumentBindingID()
            editorDocumentBindingIDs[sessionIdentity] = bindingID
            editorDocumentBindingSessions[bindingID] = session
        }

        let lifecycle: (EditorDocumentBindingLifecycleEvent) -> Void = { [weak self, weak session] event in
            guard let self, let session else { return }
            handleEditorDocumentBindingLifecycle(
                event,
                session: session,
                bindingID: bindingID
            )
        }
        let sourceContract = EditorDocumentSourceContract(
            bindingID: bindingID,
            snapshot: { [weak session] in
                guard let session else {
                    return EditorDocumentSourceSnapshot(source: "", revision: -1)
                }
                return EditorDocumentSourceSnapshot(
                    source: session.text,
                    revision: session.version
                )
            },
            lifecycle: lifecycle,
            writer: { [weak self, weak session] event in
                guard let self, let session else {
                    return .rejected(EditorDocumentSourceSnapshot(
                        source: "",
                        revision: -1
                    ))
                }
                return handleEditorDocumentWriter(
                    event,
                    session: session,
                    bindingID: bindingID
                )
            },
            pendingSource: { [weak self, weak session] event in
                guard let self, let session else { return }
                handleEditorPendingSource(
                    event,
                    session: session,
                    bindingID: bindingID
                )
            },
            publish: { [weak self, weak session] publication in
                guard let self, let session else {
                    return .rejected(EditorDocumentSourceSnapshot(source: "", revision: -1))
                }
                return publishEditorDocumentSource(
                    publication,
                    session: session,
                    bindingID: bindingID
                )
            },
            recordFullSourceComparison: { [weak self] kind in
                guard let self else { return }
                editorDocumentSourceFullComparisonCounts[kind, default: 0] += 1
            },
            registerSourceSynchronizer: { [weak self, weak session] installation, synchronizer in
                guard let self, let session else { return }
                registerEditorDocumentSourceSynchronizer(
                    synchronizer,
                    installation: installation,
                    session: session,
                    expectedBindingID: bindingID
                )
            },
            unregisterSourceSynchronizer: { [weak self, weak session] installation in
                guard let self, let session else { return }
                unregisterEditorDocumentSourceSynchronizer(
                    installation: installation,
                    session: session
                )
            }
        )

        return AppEditorDocumentBinding(
            id: bindingID,
            // The setter intentionally carries no mutation authority. EditorKit invokes
            // it only after the exact publication callback succeeds so its local
            // highlight revision advances; the App model was already updated above.
            text: Binding(get: { session.text }, set: { _ in }),
            onLifecycle: lifecycle,
            sourceContract: sourceContract
        )
    }

    func publishEditorDocumentSource(
        _ publication: EditorDocumentSourcePublication,
        session: DocumentSession,
        bindingID: EditorDocumentBindingID
    ) -> EditorDocumentSourcePublicationResult {
        let currentSnapshot = EditorDocumentSourceSnapshot(
            source: session.text,
            revision: session.version
        )
        let sessionIdentity = ObjectIdentifier(session)
        guard publication.installation.bindingID == bindingID,
              editorBindingInstallations[publication.installation] === session,
              editorWriterInstallations[sessionIdentity] == publication.installation,
              isAuthorizedEditorDocumentBinding(
                  publication.installation,
                  session: session
              ),
              canPublishEditorSourceDuringExternalResolution(
                  publication.installation,
                  session: session
              ),
              publication.base.revision <= session.version
        else {
            return .rejected(currentSnapshot)
        }

        let acceptedSource: String
        let sourceWasReconciled: Bool
        if publication.base.revision == session.version {
            acceptedSource = publication.source
            sourceWasReconciled = false
            applyAuthorizedEditorText(acceptedSource, to: session)
        } else {
            editorDocumentSourceFullComparisonCounts[.applicationSource, default: 0] += 1
            guard let reconciled = ExactSourceText.reconciling(
                base: publication.base.source,
                current: session.text,
                proposed: publication.source
            ) else {
                return .rejected(currentSnapshot)
            }
            acceptedSource = reconciled
            sourceWasReconciled = true
            if !ExactSourceText.matches(acceptedSource, session.text) {
                applyDocumentText(acceptedSource, to: session)
            }
        }
        return .accepted(
            EditorDocumentSourceSnapshot(
                source: session.text,
                revision: session.version
            ),
            sourceWasReconciled: sourceWasReconciled
        )
    }

    func handleEditorDocumentBindingLifecycle(
        _ event: EditorDocumentBindingLifecycleEvent,
        session: DocumentSession,
        bindingID: EditorDocumentBindingID
    ) {
        switch event {
        case let .installed(installation):
            installEditorDocumentBinding(
                installation,
                session: session,
                expectedBindingID: bindingID
            )
        case let .revoked(installation):
            revokeEditorDocumentBinding(
                installation,
                session: session,
                expectedBindingID: bindingID
            )
        }
    }

    func handleEditorDocumentWriter(
        _ event: EditorDocumentWriterEvent,
        session: DocumentSession,
        bindingID: EditorDocumentBindingID
    ) -> EditorDocumentWriterEventResult {
        switch event {
        case let .activate(installation, baseSnapshot):
            activateEditorDocumentWriter(
                installation,
                baseSnapshot: baseSnapshot,
                session: session,
                expectedBindingID: bindingID
            )
        case let .release(installation):
            if releaseEditorDocumentWriter(
                installation,
                session: session,
                expectedBindingID: bindingID
            ) {
                .released
            } else {
                .releaseRejected
            }
        }
    }

    func handleEditorPendingSource(
        _ event: EditorDocumentPendingSourceEvent,
        session: DocumentSession,
        bindingID: EditorDocumentBindingID
    ) {
        switch event {
        case let .began(installation):
            beginEditorPendingSource(
                installation,
                session: session,
                expectedBindingID: bindingID
            )
        case let .synchronized(installation), let .abandoned(installation):
            endEditorPendingSource(
                installation,
                session: session,
                expectedBindingID: bindingID
            )
        }
    }

    func isManagedEditorSession(_ session: DocumentSession) -> Bool {
        // A missing current document remains an App-owned recovery surface: native
        // input may continue changing its in-memory source even though every disk
        // write stays fenced. Non-current detached sessions still require an exact
        // retirement lease before an editor installation can publish.
        if session === currentDocument { return true }
        guard let fileURL = sessionStateURL(for: session) else { return false }
        guard !detachedSessionURLs.contains(fileURL) else { return false }
        return sessionCache[fileURL] === session
    }

    func removeEditorDocumentBindingRegistration(for session: DocumentSession) {
        guard let bindingID = registeredEditorDocumentBindingID(for: session) else { return }
        removeEditorDocumentBindingRegistration(for: session, bindingID: bindingID)
    }

    func removeEditorDocumentBindingRegistration(
        for session: DocumentSession,
        bindingID: EditorDocumentBindingID
    ) {
        let sessionIdentity = ObjectIdentifier(session)
        guard editorDocumentBindingIDs[sessionIdentity] == bindingID,
              editorDocumentBindingSessions[bindingID] === session
        else {
            return
        }

        editorDocumentBindingIDs[sessionIdentity] = nil
        editorDocumentBindingSessions[bindingID] = nil
        editorDocumentSourceSynchronizers = editorDocumentSourceSynchronizers.filter { installation, _ in
            installation.bindingID != bindingID
        }
    }

    func isRetiredEditorSession(_ session: DocumentSession) -> Bool {
        retiredEditorDocumentSessions.values.contains { $0.session === session }
    }

    func finishRetiredEditorDocumentSessionIfPossible(for session: DocumentSession) {
        guard let canonicalURL = retiredCanonicalURL(for: session) else { return }
        finishRetiredEditorDocumentSessionIfPossible(canonicalURL)
    }

    func liveEditorDocumentBindingInstallations(
        for session: DocumentSession
    ) -> Set<EditorDocumentBindingInstallation> {
        Set(editorBindingInstallations.compactMap { installation, owner in
            owner === session ? installation : nil
        })
    }

    func isEditorDocumentBindingInstalled(
        _ bindingID: EditorDocumentBindingID,
        session: DocumentSession
    ) -> Bool {
        editorBindingInstallations.contains { installation, owner in
            owner === session && installation.bindingID == bindingID
        }
    }

    func hasPendingEditorSource(for session: DocumentSession) -> Bool {
        pendingEditorSourceInstallations.values.contains { $0 === session }
    }

    func registerEditorDocumentSourceSynchronizer(
        _ synchronizer: @escaping EditorDocumentSourceSynchronizer,
        installation: EditorDocumentBindingInstallation,
        session: DocumentSession,
        expectedBindingID: EditorDocumentBindingID
    ) {
        guard installation.bindingID == expectedBindingID,
              editorBindingInstallations[installation] === session,
              isRegisteredEditorDocumentBinding(expectedBindingID, session: session)
        else {
            return
        }
        editorDocumentSourceSynchronizers[installation] = synchronizer
        synchronizePendingExternalReloadIfPossible(for: session)
    }

    func unregisterEditorDocumentSourceSynchronizer(
        installation: EditorDocumentBindingInstallation,
        session: DocumentSession
    ) {
        guard editorBindingInstallations[installation] === session else { return }
        editorDocumentSourceSynchronizers[installation] = nil
        synchronizePendingExternalReloadIfPossible(for: session)
    }
}

@MainActor
private extension AppState {
    func installEditorDocumentBinding(
        _ installation: EditorDocumentBindingInstallation,
        session: DocumentSession,
        expectedBindingID: EditorDocumentBindingID
    ) {
        guard installation.bindingID == expectedBindingID,
              isRegisteredEditorDocumentBinding(expectedBindingID, session: session),
              isManagedEditorSession(session) || retirementOwnsBinding(
                  expectedBindingID,
                  session: session
              )
        else {
            return
        }

        if let existingOwner = editorBindingInstallations[installation] {
            guard existingOwner === session else {
                assertionFailure("One exact editor installation cannot own two sessions")
                return
            }
            return
        }

        editorBindingInstallations[installation] = session
        let sessionIdentity = ObjectIdentifier(session)
        if editorWriterInstallations[sessionIdentity] == nil {
            editorWriterInstallations[sessionIdentity] = installation
        }
        if let canonicalURL = retiredCanonicalURL(for: session),
           var retirement = retiredEditorDocumentSessions[canonicalURL]
        {
            retirement.bindingIDs.insert(expectedBindingID)
            retirement.awaitingInstallations.insert(installation)
            retiredEditorDocumentSessions[canonicalURL] = retirement
        }
        reconcileSessionPolicyAfterEditorLeaseChange()
    }

    func revokeEditorDocumentBinding(
        _ installation: EditorDocumentBindingInstallation,
        session: DocumentSession,
        expectedBindingID: EditorDocumentBindingID
    ) {
        guard installation.bindingID == expectedBindingID,
              editorBindingInstallations[installation] === session
        else {
            return
        }

        let sessionIdentity = ObjectIdentifier(session)
        let endedPendingSource = pendingEditorSourceInstallations.removeValue(
            forKey: installation
        ) === session
        if editorWriterInstallations[sessionIdentity] == installation {
            editorWriterInstallations[sessionIdentity] = nil
        }
        editorDocumentSourceSynchronizers[installation] = nil
        editorBindingInstallations[installation] = nil
        if !isEditorDocumentBindingInstalled(expectedBindingID, session: session),
           let canonicalURL = retiredCanonicalURL(for: session),
           sessionCache[canonicalURL] !== session
        {
            removeEditorDocumentBindingRegistration(
                for: session,
                bindingID: expectedBindingID
            )
        }
        if let canonicalURL = retiredCanonicalURL(for: session),
           var retirement = retiredEditorDocumentSessions[canonicalURL]
        {
            retirement.awaitingInstallations.remove(installation)
            retiredEditorDocumentSessions[canonicalURL] = retirement
        }
        reconcileSessionPolicyAfterEditorLeaseChange()
        synchronizePendingExternalReloadIfPossible(for: session)
        finishRetiredEditorDocumentSessionIfPossible(for: session)
        if endedPendingSource {
            resolveDeferredExternalChangeIfPossible(for: session)
            if session.isDirty, canAutosave(session: session) {
                scheduleAutosave(for: session)
            }
        }
    }

    func activateEditorDocumentWriter(
        _ installation: EditorDocumentBindingInstallation,
        baseSnapshot: EditorDocumentSourceSnapshot,
        session: DocumentSession,
        expectedBindingID: EditorDocumentBindingID
    ) -> EditorDocumentWriterEventResult {
        let currentSnapshot = EditorDocumentSourceSnapshot(
            source: session.text,
            revision: session.version
        )
        guard installation.bindingID == expectedBindingID,
              isAuthorizedEditorDocumentBinding(installation, session: session)
        else {
            return .rejected(currentSnapshot)
        }

        let sessionIdentity = ObjectIdentifier(session)
        guard !isExternalSourceMutationFenced(for: session) ||
            canPublishEditorSourceDuringExternalResolution(installation, session: session)
        else {
            return .rejected(currentSnapshot)
        }
        // `DocumentSession.version` advances for every literal source change. Together
        // with exact installation ownership, an equal revision is the App-owned opaque
        // proof that the coordinator still has the current source. Do not scan either
        // full String on this ordinary pre-mutation path.
        guard baseSnapshot.revision == currentSnapshot.revision else {
            // A stale caller must not retain writer authority merely because it owned
            // the previous revision. The synchronized retry will acquire it again.
            if editorWriterInstallations[sessionIdentity] == installation,
               pendingEditorSourceInstallations[installation] == nil
            {
                editorWriterInstallations[sessionIdentity] = nil
            }
            return .synchronize(currentSnapshot)
        }

        if let previousWriter = editorWriterInstallations[sessionIdentity],
           previousWriter != installation,
           pendingEditorSourceInstallations[previousWriter] === session
        {
            return .rejected(currentSnapshot)
        }
        editorWriterInstallations[sessionIdentity] = installation
        return .activated(currentSnapshot)
    }

    func releaseEditorDocumentWriter(
        _ installation: EditorDocumentBindingInstallation,
        session: DocumentSession,
        expectedBindingID: EditorDocumentBindingID
    ) -> Bool {
        guard installation.bindingID == expectedBindingID else { return false }
        let sessionIdentity = ObjectIdentifier(session)
        guard editorWriterInstallations[sessionIdentity] == installation,
              pendingEditorSourceInstallations[installation] == nil
        else {
            return false
        }
        editorWriterInstallations[sessionIdentity] = nil
        return true
    }

    func beginEditorPendingSource(
        _ installation: EditorDocumentBindingInstallation,
        session: DocumentSession,
        expectedBindingID: EditorDocumentBindingID
    ) {
        let sessionIdentity = ObjectIdentifier(session)
        guard installation.bindingID == expectedBindingID,
              isAuthorizedEditorDocumentBinding(installation, session: session),
              editorWriterInstallations[sessionIdentity] == installation
        else {
            return
        }
        if let existingOwner = pendingEditorSourceInstallations[installation] {
            guard existingOwner === session else {
                assertionFailure("One exact editor installation cannot defer two sessions")
                return
            }
            return
        }
        pendingEditorSourceInstallations[installation] = session
        cancelAutosave(for: session)
    }

    func endEditorPendingSource(
        _ installation: EditorDocumentBindingInstallation,
        session: DocumentSession,
        expectedBindingID: EditorDocumentBindingID
    ) {
        guard installation.bindingID == expectedBindingID,
              pendingEditorSourceInstallations[installation] === session
        else {
            return
        }
        pendingEditorSourceInstallations[installation] = nil
        resolveDeferredExternalChangeIfPossible(for: session)
        if session.isDirty, canAutosave(session: session) {
            scheduleAutosave(for: session)
        }
    }

    func isAuthorizedEditorDocumentBinding(
        _ installation: EditorDocumentBindingInstallation,
        session: DocumentSession
    ) -> Bool {
        guard editorBindingInstallations[installation] === session,
              isRegisteredEditorDocumentBinding(installation.bindingID, session: session)
        else {
            return false
        }
        return isManagedEditorSession(session) || retirementOwnsBinding(
            installation.bindingID,
            session: session
        )
    }

    func registeredEditorDocumentBindingID(
        for session: DocumentSession
    ) -> EditorDocumentBindingID? {
        let sessionIdentity = ObjectIdentifier(session)
        guard let bindingID = editorDocumentBindingIDs[sessionIdentity] else { return nil }
        guard editorDocumentBindingSessions[bindingID] === session else {
            if editorDocumentBindingSessions[bindingID] == nil {
                editorDocumentBindingIDs[sessionIdentity] = nil
            }
            return nil
        }
        return bindingID
    }

    func isRegisteredEditorDocumentBinding(
        _ bindingID: EditorDocumentBindingID,
        session: DocumentSession
    ) -> Bool {
        registeredEditorDocumentBindingID(for: session) == bindingID
    }

    func retirementOwnsBinding(
        _ bindingID: EditorDocumentBindingID,
        session: DocumentSession
    ) -> Bool {
        retiredEditorDocumentSessions.values.contains { retirement in
            retirement.session === session && retirement.bindingIDs.contains(bindingID)
        }
    }

    func retiredCanonicalURL(for session: DocumentSession) -> URL? {
        let matches = retiredEditorDocumentSessions.compactMap { canonicalURL, retirement in
            retirement.session === session ? canonicalURL : nil
        }
        guard matches.count <= 1 else {
            assertionFailure("One session cannot have multiple retirement identities")
            return nil
        }
        return matches.first
    }

    func finishRetiredEditorDocumentSessionIfPossible(_ canonicalURL: URL) {
        guard let retirement = retiredEditorDocumentSessions[canonicalURL],
              retirement.awaitingInstallations.isEmpty
        else {
            return
        }

        let session = retirement.session
        let sessionIdentity = ObjectIdentifier(session)
        if externalDiskInspectionTasks[sessionIdentity] != nil ||
            externalReloadTasks[sessionIdentity] != nil ||
            pendingExternalReloadApplications[sessionIdentity] != nil ||
            deferredExternalChangeResolutions[canonicalURL] != nil ||
            indeterminateSessionWrites[sessionIdentity] != nil ||
            indeterminateWorkspaceMutationSessions.contains(sessionIdentity) ||
            workspaceMutationWriteFences.contains(sessionIdentity)
        {
            cancelAutosave(for: session)
            return
        }
        if pendingExternalTexts[canonicalURL] != nil ||
            pendingExternalFileVersions[canonicalURL] != nil ||
            detachedSessionURLs.contains(canonicalURL)
        {
            cancelAutosave(for: session)
            restoreRecoveryPrompt(for: session)
            return
        }

        if session.isDirty {
            do {
                try save(session: session)
            } catch {
                restoreRecoveryPrompt(for: session)
                present(error, title: "Could Not Save Retired File")
                return
            }
        }

        retiredEditorDocumentSessions[canonicalURL] = nil
        for owner in retirement.securityScopedAuthorityOwners {
            owner.release(session)
        }

        if liveEditorDocumentBindingInstallations(for: session).isEmpty {
            removeEditorDocumentBindingRegistration(for: session)
        }

        if !isManagedEditorSession(session) {
            cancelAutosave(for: session)
            cancelStatisticsRefresh(for: session)
            removeEditorDocumentBindingRegistration(for: session)
        }
        clearRetiredSessionMetadataIfUnreferenced(
            for: canonicalURL,
            session: session
        )
    }

    func clearRetiredSessionMetadataIfUnreferenced(
        for canonicalURL: URL,
        session: DocumentSession
    ) {
        let sessionIdentity = ObjectIdentifier(session)
        guard indeterminateSessionWrites[sessionIdentity] == nil,
              !indeterminateWorkspaceMutationSessions.contains(sessionIdentity),
              !workspaceMutationWriteFences.contains(sessionIdentity)
        else {
            return
        }
        guard currentDocument !== session,
              sessionCache[canonicalURL] !== session,
              !retiredEditorDocumentSessions.values.contains(where: { $0.session === session })
        else {
            return
        }

        lastKnownDiskHashes[canonicalURL] = nil
        lastKnownDiskModificationDates[canonicalURL] = nil
        clearExternalChangeConflict(at: canonicalURL)
        deferredExternalChangeResolutions[canonicalURL] = nil
        externalResolutionIntentCaptures[canonicalURL] = nil
        detachedSessionURLs.remove(canonicalURL)
        externalReloadTasks.removeValue(forKey: sessionIdentity)?.task.cancel()
        externalDiskInspectionTasks.removeValue(forKey: sessionIdentity)?.task.cancel()
        pendingExternalReloadApplications[sessionIdentity] = nil
        anchoredSessionFileBindings[sessionIdentity] = nil
        unanchoredManagedSessionOwnershipProofs[sessionIdentity] = nil
        discardEditorImageAssetDocumentAuthority(for: session)
        indeterminateSessionWrites[sessionIdentity] = nil
        indeterminateSessionWriteContexts[sessionIdentity] = nil
        indeterminateWorkspaceMutationSessions.remove(sessionIdentity)
    }
}

struct AppEditorDocumentBinding {
    let id: EditorDocumentBindingID
    let text: Binding<String>
    let onLifecycle: (EditorDocumentBindingLifecycleEvent) -> Void
    let sourceContract: EditorDocumentSourceContract
}
