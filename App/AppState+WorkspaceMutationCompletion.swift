import EditorKit
import Foundation
import MarkdownCore
import WorkspaceKit

@MainActor
extension AppState {
    func resumeWorkspaceRelocationWork(
        _ records: [WorkspaceSessionRelocationRecord]
    ) {
        for record in records {
            let session = record.session
            let sessionIdentity = ObjectIdentifier(session)
            guard !indeterminateWorkspaceMutationSessions.contains(sessionIdentity),
                  let stateURL = sessionStateURL(for: session)
            else {
                continue
            }
            if let resolution = exactURLValue(
                in: deferredExternalChangeResolutions,
                at: stateURL
            ) ?? record.deferredExternalResolution {
                externalResolutionIntentCaptures[stateURL] = ExternalResolutionIntentCapture(
                    intent: resolution,
                    sourceSnapshot: EditorDocumentSourceSnapshot(
                        source: session.text,
                        revision: session.version
                    ),
                    diskEventGeneration: currentExternalDiskEventGeneration(for: session)
                )
                restartExternalResolutionIfNeeded(for: session)
            } else if record.hadExternalDiskInspection {
                handleExternalChange(for: session, advancingDiskEvent: false)
            }
            if session.isDirty {
                scheduleAutosave(for: session)
            }
        }
        restoreRecoveryPrompt(for: shownSession)
    }

    func finishWorkspaceTrash(_ records: [WorkspaceTrashSessionRecord]) {
        var detachedRecords: [WorkspaceTrashSessionRecord] = []
        var removedCurrentSession = false

        for record in records {
            let session = record.session
            let changedDuringTrash = session.version != record.initialVersion
                || session.isDirty
                || hasPendingEditorSource(for: session)
            discardEditorImageAssetDocumentAuthority(for: session)
            if changedDuringTrash {
                do {
                    try persistWorkspaceMutationTextRecovery(for: session)
                } catch {
                    present(error, title: "Could Not Preserve Recovery Copy")
                }
                markSessionDetachedFromMissingFile(session, url: record.oldURL)
                detachedRecords.append(record)
                continue
            }

            _ = clearWorkspaceMutationTextRecovery(for: session)
            removedCurrentSession = removedCurrentSession || session === shownSession
            discardRetiredEditorDocumentSession(session, canonicalURL: record.oldURL)
            clearSessionState(for: session, fallbackURL: record.oldURL)
        }

        if let currentDetached = detachedRecords.first(where: {
            $0.session === shownSession
        }) {
            markSessionDetachedFromMissingFile(
                currentDetached.session,
                url: currentDetached.oldURL
            )
        } else if let recovery = detachedRecords.first(where: {
            // WD1: a copy another window shows stays there.
            otherWindowShowingFile(location: nil, fileURL: nil, identity: nil, session: $0.session) == nil
        }) {
            setCurrentDocument(recovery.session)
            markSessionDetachedFromMissingFile(recovery.session, url: recovery.oldURL)
        } else if removedCurrentSession {
            setCurrentDocument(DocumentSession())
        }
    }

    func resumeWorkspaceTrashWork(
        _ records: [WorkspaceTrashSessionRecord]
    ) {
        for record in records {
            let session = record.session
            let sessionIdentity = ObjectIdentifier(session)
            guard !indeterminateWorkspaceMutationSessions.contains(sessionIdentity),
                  let stateURL = sessionStateURL(for: session),
                  !detachedSessionURLs.contains(where: {
                      exactFileURLSpellingMatches($0, stateURL)
                  })
            else {
                continue
            }
            if let resolution = exactURLValue(
                in: deferredExternalChangeResolutions,
                at: stateURL
            ) ?? record.deferredExternalResolution {
                externalResolutionIntentCaptures[stateURL] = ExternalResolutionIntentCapture(
                    intent: resolution,
                    sourceSnapshot: EditorDocumentSourceSnapshot(
                        source: session.text,
                        revision: session.version
                    ),
                    diskEventGeneration: currentExternalDiskEventGeneration(for: session)
                )
                restartExternalResolutionIfNeeded(for: session)
            } else if record.hadExternalDiskInspection {
                handleExternalChange(for: session, advancingDiskEvent: false)
            }
            if session.isDirty {
                scheduleAutosave(for: session)
            }
            finishRetiredEditorDocumentSessionIfPossible(for: session)
        }
        restoreRecoveryPrompt(for: shownSession)
    }

    func recordWorkspaceTrashCleanupState(
        _ cleanupState: WorkspaceTrashStagingCleanupState
    ) {
        guard case let .removalIndeterminate(location) = cleanupState else { return }
        if !workspaceTrashCleanupNotices.contains(where: {
            $0.stagingLocation == location
        }) {
            let notice = WorkspaceTrashCleanupNotice(stagingLocation: location)
            workspaceTrashCleanupNotices.append(notice)
            KeyWindowRouter.shared.routeNotice(notice.id, owner: self)
        }
        present(
            WorkspaceMutationError.trashStagingCleanupRequired(location.fileURL),
            title: "Trash Cleanup Needs Attention",
            for: shownSession
        )
    }
}
