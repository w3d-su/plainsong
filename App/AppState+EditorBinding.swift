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
        if registry.isShownByAnyWindow(session) { return true }
        guard let fileURL = sessionStateURL(for: session) else { return false }
        guard !detachedSessionURLs.contains(fileURL) else { return false }
        return registry.isWarmSession(session, at: fileURL)
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
        releaseUnreferencedSessionOwnership(for: session)
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

struct AppEditorDocumentBinding {
    let id: EditorDocumentBindingID
    let text: Binding<String>
    let onLifecycle: (EditorDocumentBindingLifecycleEvent) -> Void
    let sourceContract: EditorDocumentSourceContract
}
